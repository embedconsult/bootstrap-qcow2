require "json"
require "log"
require "file_utils"
require "process"
require "random/secure"
require "set"
require "time"
require "./build_plan"
require "./build_plan_reader"
require "./build_plan_overrides"
require "./cli"
require "./process_runner"
require "./sysroot_namespace"
require "./sysroot_build_state"
require "./sysroot_workspace"

module Bootstrap
  # SysrootRunner houses the logic that replays build steps inside the chroot.
  # It is kept in a regular source file so it benefits from formatting, linting,
  # and specs. The main entrypoint registers the CLI class and dispatches into
  # the `run` helpers below.
  class SysrootRunner < CLI
    DEFAULT_PLAN_PATH      = "/var/lib/sysroot-build-plan.json"
    DEFAULT_OVERRIDES_PATH = "/var/lib/sysroot-build-overrides.json"
    DEFAULT_REPORT_DIR     = "/var/lib/sysroot-build-reports"
    DEFAULT_STATE_PATH     = SysrootBuildState::DEFAULT_PATH
    # Default rootfs output directory from SysrootBuilder.phase_specs.
    WORKSPACE_ROOTFS_PATH        = "/workspace/rootfs"
    WORKSPACE_ROOTFS_MARKER_PATH = "#{WORKSPACE_ROOTFS_PATH}#{SysrootWorkspace::ROOTFS_MARKER_PATH}"

    # Returns true when a rootfs marker is present (env override or marker file).
    def self.rootfs_marker_present? : Bool
      SysrootWorkspace.rootfs_marker_present?
    end

    # Returns true when the workspace rootfs has been created.
    def self.workspace_rootfs_present? : Bool
      File.exists?(WORKSPACE_ROOTFS_MARKER_PATH)
    end

    # Resolved paths used by sysroot-status and resume logic.
    struct StatusPaths
      getter rootfs_dir : String
      getter state_path : String
      getter plan_path : String

      def initialize(@rootfs_dir : String, @state_path : String, @plan_path : String)
      end
    end

    # Resolve the rootfs, state, and plan paths using the same logic as sysroot-status.
    def self.resolve_status_paths(workspace : String,
                                  rootfs : String?,
                                  state_path : String?,
                                  rootfs_explicit : Bool,
                                  allow_workspace_rootfs : Bool) : StatusPaths
      rootfs_dir = rootfs
      if rootfs_dir.nil? && rootfs_marker_present?
        rootfs_dir = "/"
      end
      rootfs_dir ||= File.join(workspace, "rootfs")
      resolved_state_path = state_path
      if resolved_state_path.nil?
        candidates = [] of String
        if rootfs_marker_present?
          candidates << "/"
        else
          if rootfs_explicit
            candidates << rootfs_dir.not_nil! if rootfs_dir
          end
          if rootfs_dir
            nested_rootfs = File.join(rootfs_dir.not_nil!, "workspace/rootfs")
            candidates << nested_rootfs
          end
          candidates << rootfs_dir.not_nil! if rootfs_dir
        end
        candidates = candidates.uniq
        candidates.each do |candidate|
          candidate_state = File.join(candidate, "var/lib/sysroot-build-state.json")
          if File.exists?(candidate_state)
            rootfs_dir = candidate
            resolved_state_path = candidate_state
            break
          end
        end
      end
      resolved_state_path ||= File.join(rootfs_dir, "var/lib/sysroot-build-state.json")
      unless File.exists?(resolved_state_path)
        if rootfs_marker_present? && File.exists?(SysrootBuildState::DEFAULT_PATH)
          resolved_state_path = SysrootBuildState::DEFAULT_PATH
        end
      end
      plan_path = File.join(rootfs_dir, "var/lib/sysroot-build-plan.json")
      StatusPaths.new(rootfs_dir, resolved_state_path, plan_path)
    end

    # Enter the workspace rootfs when the marker is present.
    def self.enter_workspace_rootfs! : Nil
      return unless workspace_rootfs_present?
      Log.info { "Entering workspace rootfs at #{WORKSPACE_ROOTFS_PATH}" }
      extra_binds = [] of Tuple(Path, Path)
      workspace_path = Path["/workspace"]
      if Dir.exists?(workspace_path)
        extra_binds << {workspace_path, workspace_path}
      end
      SysrootNamespace.enter_rootfs(WORKSPACE_ROOTFS_PATH, extra_binds: extra_binds)
    end

    # Raised when a command fails during a SystemRunner invocation.
    class CommandFailedError < Exception
      getter argv : Array(String)
      getter exit_code : Int32
      getter output_path : String?

      def initialize(@argv : Array(String), @exit_code : Int32, message : String, @output_path : String? = nil)
        super(message)
      end
    end

    # Default runner that shells out via Process.run using strategy metadata.
    struct SystemRunner
      getter clean_build_dirs : Bool
      getter report_dir : String?
      @command_log_prefix : String?

      def initialize(@clean_build_dirs : Bool = true, @report_dir : String? = nil)
        @command_log_prefix = nil
      end

      def with_report_dir(report_dir : String?) : SystemRunner
        SystemRunner.new(clean_build_dirs: @clean_build_dirs, report_dir: report_dir)
      end

      # Run a build step using the selected strategy.
      #
      # The effective install destination is computed from the phase defaults
      # and optional step overrides:
      # - `install_prefix` selects the prefix used by configure/CMake.
      # - `destdir` (when present) is passed to install commands to stage files
      #   into a rootfs directory without needing chroot/pivot_root.
      # - `env` combines phase env with step env, with step keys overriding.
      def run(phase : BuildPhase, step : BuildStep)
        Dir.cd(step.workdir) do
          cpus = (System.cpu_count || 1).to_i32
          Log.info { "Starting #{step.strategy} build for #{step.name} in #{step.workdir} (cpus=#{cpus})" }
          @command_log_prefix = log_prefix_for(phase, step)
          apply_patches(step.patches)
          env = effective_env(phase, step)
          install_prefix = step.install_prefix || phase.install_prefix
          destdir = step.destdir || phase.destdir
          case step.strategy
          when "cmake"
            build_dir = step.build_dir || step.workdir
            bootstrap_path = File.join(step.workdir, "bootstrap")
            had_build_files = File.exists?(File.join(build_dir, "CMakeCache.txt")) ||
                              File.exists?(File.join(build_dir, "Makefile")) ||
                              Dir.exists?(File.join(build_dir, "CMakeFiles"))
            FileUtils.mkdir_p(build_dir)
            Dir.cd(build_dir) do
              # CMake's bootstrap script only parallelizes when --parallel is set.
              bootstrap_argv = [bootstrap_path, "--parallel=#{cpus}", "--prefix=#{install_prefix}"]
              if step.configure_flags.size > 0
                bootstrap_argv << "--"
                bootstrap_argv.concat(step.configure_flags)
              end
              run_cmd(bootstrap_argv, env: env)
              if (step.clean_build || had_build_files) && File.exists?("Makefile")
                run_cmd(["make", "clean"], env: env)
              end
              run_cmd(["make", "-j#{cpus}"], env: env)
              run_make_install(destdir, env)
            end
          when "busybox"
            run_cmd(["make", "defconfig"], env: env)
            run_cmd(["make", "-j#{cpus}"], env: env)
            install_root = destdir || install_prefix
            run_cmd(["make", "CONFIG_PREFIX=#{install_root}", "install"], env: env)
          when "copy-tree"
            raise "copy-tree requires step.install_prefix (destination path)" unless step.install_prefix
            install_root = destdir ? "#{destdir}#{install_prefix}" : install_prefix
            FileUtils.mkdir_p(install_root)
            run_cmd(["cp", "-a", ".", install_root], env: env)
          when "write-file"
            raise "write-file requires step.install_prefix (file path)" unless step.install_prefix
            content = step.env["CONTENT"]?
            raise "write-file requires env CONTENT" unless content
            target = destdir ? "#{destdir}#{install_prefix}" : install_prefix
            FileUtils.mkdir_p(File.dirname(target))
            File.write(target, content)
          when "prepare-rootfs"
            idx = 0
            wrote = false
            loop do
              path_key = "FILE_#{idx}_PATH"
              content_key = "FILE_#{idx}_CONTENT"
              path = step.env[path_key]?
              content = step.env[content_key]?
              break unless path || content
              raise "prepare-rootfs requires #{path_key}" unless path
              raise "prepare-rootfs requires #{content_key}" unless content
              target = destdir ? "#{destdir}#{path}" : path
              FileUtils.mkdir_p(File.dirname(target))
              File.write(target, content)
              wrote = true
              idx += 1
            end
            raise "prepare-rootfs wrote no files" unless wrote
          when "symlink"
            idx = 0
            linked = false
            loop do
              src_key = "LINK_#{idx}_SRC"
              dest_key = "LINK_#{idx}_DEST"
              source = step.env[src_key]?
              dest = step.env[dest_key]?
              break unless source || dest
              raise "symlink requires #{src_key}" unless source
              raise "symlink requires #{dest_key}" unless dest
              target = destdir ? "#{destdir}#{dest}" : dest
              FileUtils.mkdir_p(File.dirname(target))
              FileUtils.rm_rf(target) if File.exists?(target) || File.symlink?(target)
              File.symlink(source, target)
              linked = true
              idx += 1
            end
            raise "symlink wrote no links" unless linked
          when "remove-tree"
            raise "remove-tree requires step.install_prefix (path to remove)" unless step.install_prefix
            remove_root = destdir ? "#{destdir}#{install_prefix}" : install_prefix
            raise "Refusing to remove #{remove_root}" if remove_root == "/" || remove_root.empty?
            FileUtils.rm_rf(remove_root)
          when "tarball"
            output = step.install_prefix
            raise "tarball requires step.install_prefix (output path)" unless output
            output = output.not_nil!
            source_root = step.workdir
            if destdir
              if source_root.starts_with?(destdir)
                # Already rooted at the destdir.
              elsif source_root == "/"
                source_root = destdir
              elsif source_root.starts_with?("/")
                source_root = "#{destdir}#{source_root}"
              else
                source_root = File.join(destdir, source_root)
              end
            end
            raise "Missing tarball source #{source_root}" unless Dir.exists?(source_root)
            FileUtils.mkdir_p(File.dirname(output))
            run_cmd(["tar", "-czf", output, "-C", source_root, "."], env: env)
          when "linux-headers"
            install_root = destdir ? "#{destdir}#{install_prefix}" : install_prefix
            run_cmd(["make"] + step.configure_flags + ["headers"], env: env)
            include_dest = File.join(install_root, "include")
            FileUtils.mkdir_p(include_dest)
            run_cmd(["cp", "-a", "usr/include/.", include_dest], env: env)
          when "cmake-project"
            run_cmake_project(step, env, install_prefix, destdir, cpus)
          when "crystal"
            run_cmd(["shards", "build"], env: env)
            bin_prefix = destdir ? "#{destdir}#{install_prefix}" : install_prefix
            run_cmd(["install", "-d", "#{bin_prefix}/bin"], env: env)
            Dir.glob("bin/*").each do |artifact|
              run_cmd(["install", "-m", "0755", artifact, "#{bin_prefix}/bin/"], env: env)
            end
          when "crystal-build"
            if File.exists?("shard.yml")
              if skip_shards_install?(step, env)
                Log.info { "Skipping shards install for #{step.name} (#{shards_install_skip_reason(step, env)})" }
              else
                run_cmd(["shards", "install"], env: env)
              end
            end
            run_cmd(["crystal", "build"] + step.configure_flags, env: env)
            bin_prefix = destdir ? "#{destdir}#{install_prefix}" : install_prefix
            run_cmd(["install", "-d", "#{bin_prefix}/bin"], env: env)
            Dir.glob("bin/*").each do |artifact|
              run_cmd(["install", "-m", "0755", artifact, "#{bin_prefix}/bin/"], env: env)
            end
          when "crystal-compiler"
            FileUtils.rm_rf(".build") if Dir.exists?(".build")
            run_cmd(["make", "-j#{cpus}", "crystal"], env: env)
            install_env = destdir ? env.merge({"DESTDIR" => destdir}) : env
            run_cmd(["make", "install", "PREFIX=#{install_prefix}"], env: install_env)
          else # autotools/default
            if File.exists?("configure")
              normalize_autotools_timestamps
              run_cmd(["./configure", "--prefix=#{install_prefix}"] + step.configure_flags, env: env)
              run_cmd(["make", "-j#{cpus}"], env: env)
              run_make_install(destdir, env)
            elsif cmake_lists_present?(step)
              run_cmake_project(step, env, install_prefix, destdir, cpus)
            else
              raise "Unknown build strategy #{step.strategy} and missing ./configure in #{step.workdir}"
            end
          end
          Log.info { "Finished #{step.name}" }
        end
      end

      # Returns true when shards install should be skipped.
      private def skip_shards_install?(step : BuildStep, env : Hash(String, String)) : Bool
        # Shards itself is built from a release tarball and should not run
        # `shards install` by default; it adds unnecessary dependency churn.
        return true if step.name == "shards" && !force_shards_install?(env)
        skip_shards_install_env?(env)
      end

      private def shards_install_skip_reason(step : BuildStep, env : Hash(String, String)) : String
        return "default for shards" if step.name == "shards" && !force_shards_install?(env)
        return "BQ2_SKIP_SHARDS_INSTALL=1" if skip_shards_install_env?(env)
        "unspecified"
      end

      private def force_shards_install?(env : Hash(String, String)) : Bool
        value = env["BQ2_FORCE_SHARDS_INSTALL"]?.try(&.strip.downcase)
        return false unless value
        !(value.empty? || value == "0" || value == "false" || value == "no")
      end

      private def skip_shards_install_env?(env : Hash(String, String)) : Bool
        value = env["BQ2_SKIP_SHARDS_INSTALL"]?.try(&.strip.downcase)
        return false unless value
        !(value.empty? || value == "0" || value == "false" || value == "no")
      end

      # Many release tarballs include pre-generated autotools artifacts
      # (`configure`, `aclocal.m4`, etc.) that should not be regenerated during
      # a normal build. If an extractor fails to preserve mtimes, those artifacts
      # can appear older than `configure.ac` and trigger automake/autoconf
      # rebuild rules, which breaks minimal bootstrap environments.
      private def normalize_autotools_timestamps
        return unless File.exists?("configure.ac")
        reference = File.info("configure.ac").modification_time
        bump = reference + 1.second
        %w[
          aclocal.m4
          configure
          config.h.in
          config.hin
          Makefile.in
          lib/config.hin
          src/config.h.in
          src/config.hin
          include/config.h.in
          include/config.hin
        ].each do |candidate|
          next unless File.exists?(candidate)
          info = File.info(candidate, follow_symlinks: false)
          next if info.modification_time > reference
          File.utime(bump, bump, candidate)
        rescue ex
          Log.warn { "Failed to bump autotools timestamp for #{candidate}: #{ex.message}" }
        end
      end

      # Apply patch files before invoking build commands.
      private def apply_patches(patches : Array(String))
        patches.each do |patch|
          Log.info { "Applying patch #{patch}" }
          dry_run = ["patch", "-p1", "--forward", "-N", "--dry-run", "-i", patch]
          dry_status = run_cmd_status(dry_run)
          if dry_status.success?
            argv = ["patch", "-p1", "--forward", "-N", "-i", patch]
            status = run_cmd_status(argv)
            raise CommandFailedError.new(argv, status.exit_code, "Patch failed (#{status.exit_code}): #{patch}") unless status.success?
            next
          end

          reverse_dry_run = ["patch", "-p1", "--reverse", "--dry-run", "-i", patch]
          reverse_status = run_cmd_status(reverse_dry_run)
          if reverse_status.success?
            Log.info { "Patch already applied; skipping #{patch}" }
            next
          end

          raise CommandFailedError.new(dry_run, dry_status.exit_code, "Patch failed (#{dry_status.exit_code}): #{patch}")
        end
      end

      # Run a command array and raise if it fails.
      private def run_cmd(argv : Array(String), env : Hash(String, String) = {} of String => String)
        result = run_cmd_result(argv, env: env)
        unless result.status.success?
          Log.error { "Command failed (#{result.status.exit_code}): #{argv.join(" ")}" }
          raise CommandFailedError.new(argv, result.status.exit_code, "Command failed (#{result.status.exit_code}): #{argv.join(" ")}", result.output_path)
        end
        Log.debug { "Completed #{argv.first} with exit #{result.status.exit_code}" }
      end

      # Run a command array and return its Process::Status while throttling output.
      private def run_cmd_status(argv : Array(String), env : Hash(String, String) = {} of String => String) : Process::Status
        run_cmd_result(argv, env: env).status
      end

      private def run_cmd_result(argv : Array(String), env : Hash(String, String) = {} of String => String) : ProcessRunner::Result
        Log.info { "Running in #{Dir.current}: #{argv.join(" ")}" }
        result = ProcessRunner.run(argv, env: env, capture_path: capture_path_for(argv), capture_on_error: true)
        Log.info { "Finished in #{result.elapsed.total_seconds.round(3)}s (exit=#{result.status.exit_code}): #{argv.join(" ")}" }
        result
      end

      private def capture_path_for(argv : Array(String)) : String?
        report_dir = @report_dir
        return nil unless report_dir
        FileUtils.mkdir_p(report_dir)
        timestamp = Time.utc.to_s("%Y%m%dT%H%M%S.%LZ")
        base = @command_log_prefix || argv.first? || "command"
        slug = slugify(base)
        disambiguator = Random::Secure.hex(4)
        File.join(report_dir, "#{timestamp}-#{slug}-#{disambiguator}.log")
      end

      private def log_prefix_for(phase : BuildPhase, step : BuildStep) : String
        "#{phase.name}-#{step.name}"
      end

      private def slugify(value : String) : String
        value.gsub(/[^A-Za-z0-9]+/, "_").gsub(/^_+|_+$/, "").downcase
      end

      # Runs `make install`, optionally staging through `DESTDIR`.
      private def run_make_install(destdir : String?, env : Hash(String, String))
        if destdir
          run_cmd(["make", "DESTDIR=#{destdir}", "install"], env: env)
        else
          run_cmd(["make", "install"], env: env)
        end
      end

      # Merge phase and step environment variables. Step keys override phase keys.
      private def effective_env(phase : BuildPhase, step : BuildStep) : Hash(String, String)
        merged = phase.env.dup
        step.env.each { |key, value| merged[key] = value }
        ensure_sysroot_ld_library_path(merged)
      end

      private def ensure_sysroot_ld_library_path(env : Hash(String, String)) : Hash(String, String)
        sysroot_bin = "/opt/sysroot/bin"
        sysroot_lib = "/opt/sysroot/lib"
        path = env["PATH"]?
        return env unless path && path.includes?(sysroot_bin)
        current = env["LD_LIBRARY_PATH"]?
        if current
          parts = current.split(':')
          return env if parts.includes?(sysroot_lib)
          env["LD_LIBRARY_PATH"] = "#{sysroot_lib}:#{current}"
        else
          env["LD_LIBRARY_PATH"] = sysroot_lib
        end
        env
      end

      # Returns true when a CMakeLists.txt file exists for the step.
      private def cmake_lists_present?(step : BuildStep) : Bool
        source_dir = cmake_source_dir_for(step)
        File.exists?("CMakeLists.txt") || File.exists?(File.join(source_dir, "CMakeLists.txt"))
      end

      # Resolve the CMake source directory for a build step.
      private def cmake_source_dir_for(step : BuildStep) : String
        step.env["CMAKE_SOURCE_DIR"]? || "."
      end

      # Resolve the CMake build directory for a build step.
      private def cmake_build_dir_for(step : BuildStep) : String
        step.build_dir || "build"
      end

      # Run a standard CMake configure/build/install cycle.
      private def run_cmake_project(step : BuildStep,
                                    env : Hash(String, String),
                                    install_prefix : String,
                                    destdir : String?,
                                    cpus : Int32) : Nil
        source_dir = cmake_source_dir_for(step)
        build_dir = cmake_build_dir_for(step)
        FileUtils.rm_rf(build_dir) if clean_build_dirs && Dir.exists?(build_dir)
        run_cmd(["cmake", "-S", source_dir, "-B", build_dir, "-DCMAKE_INSTALL_PREFIX=#{install_prefix}"] + step.configure_flags, env: env)
        run_cmd(["cmake", "--build", build_dir, "-j#{cpus}"], env: env)
        install_env = destdir ? env.merge({"DESTDIR" => destdir}) : env
        run_cmd(["cmake", "--install", build_dir], env: install_env)
      end
    end

    # Load a JSON build plan from disk and replay it using the provided runner.
    #
    # By default only the first phase is executed; pass `phase: "all"` or a
    # specific phase name to override.
    #
    # Use `allow_outside_rootfs` to replay rootfs phases without the marker
    # present (for example, when staging into a destdir from outside a chroot).
    #
    # When running inside the sysroot (default plan path), the runner uses the
    # state bookmark at `/var/lib/sysroot-build-state.json` to skip previously
    # completed steps and to persist progress for fast, iterative retries.
    def self.run_plan(path : String = DEFAULT_PLAN_PATH,
                      runner = SystemRunner.new,
                      phase : String? = nil,
                      packages : Array(String)? = nil,
                      overrides_path : String? = nil,
                      use_default_overrides : Bool = true,
                      report_dir : String? = DEFAULT_REPORT_DIR,
                      dry_run : Bool = false,
                      state_path : String? = nil,
                      resume : Bool = true,
                      allow_outside_rootfs : Bool = false)
      raise "Missing build plan #{path}" unless File.exists?(path)
      Log.info { "Loading build plan from #{path}" }
      plan = BuildPlanReader.load(path)
      effective_overrides_path =
        if overrides_path
          overrides_path
        elsif use_default_overrides
          default_overrides_path_for_plan(path)
        end
      plan = apply_overrides(plan, effective_overrides_path) if effective_overrides_path
      stage_iteration_files_for_destdirs(plan, effective_overrides_path)
      effective_state_path = state_path || (resume && path == DEFAULT_PLAN_PATH ? DEFAULT_STATE_PATH : nil)
      state = effective_state_path ? SysrootBuildState.load_or_init(effective_state_path, plan_path: path, overrides_path: effective_overrides_path, report_dir: report_dir) : nil
      state.try(&.save(effective_state_path.not_nil!)) if effective_state_path
      effective_runner = runner
      if runner.is_a?(SystemRunner) && report_dir && runner.report_dir.nil?
        effective_runner = runner.with_report_dir(report_dir)
      end
      run_plan(plan,
        effective_runner,
        phase: phase,
        packages: packages,
        report_dir: report_dir,
        dry_run: dry_run,
        state: state,
        state_path: effective_state_path,
        resume: resume,
        allow_outside_rootfs: allow_outside_rootfs)
    end

    # Execute an in-memory plan without requiring it to be read from disk.
    # By default only the first phase is executed; pass `phase: "all"` or a
    # specific phase name to override.
    def self.run_plan(plan : BuildPlan,
                      runner = SystemRunner.new,
                      phase : String? = nil,
                      packages : Array(String)? = nil,
                      report_dir : String? = DEFAULT_REPORT_DIR,
                      dry_run : Bool = false,
                      state : SysrootBuildState? = nil,
                      state_path : String? = nil,
                      resume : Bool = true,
                      allow_outside_rootfs : Bool = false)
      phases = selected_phases(plan, phase)
      phases = apply_rootfs_env_overrides(phases) if rootfs_marker_present?
      phases = filter_phases_by_packages(phases, packages) if packages
      phases = filter_phases_by_state(phases, state) if resume && state
      if dry_run
        Log.info { describe_phases(phases) }
        return
      end
      effective_runner = runner
      if runner.is_a?(SystemRunner) && report_dir && runner.report_dir.nil?
        effective_runner = runner.with_report_dir(report_dir)
      end
      phases.each do |phase_plan|
        run_phase(phase_plan, effective_runner, report_dir: report_dir, state: state, state_path: state_path, resume: resume, allow_outside_rootfs: allow_outside_rootfs)
      end
    end

    # Run a single phase from the plan.
    def self.run_phase(phase : BuildPhase,
                       runner = SystemRunner.new,
                       report_dir : String? = DEFAULT_REPORT_DIR,
                       state : SysrootBuildState? = nil,
                       state_path : String? = nil,
                       resume : Bool = true,
                       allow_outside_rootfs : Bool = false)
      effective_phase = phase
      if phase.environment.starts_with?("rootfs-") && !rootfs_marker_present? && workspace_rootfs_present?
        effective_phase = apply_rootfs_env_override(phase)
      end
      if !allow_outside_rootfs && effective_phase.environment.starts_with?("rootfs-") && !rootfs_marker_present?
        enter_workspace_rootfs! if workspace_rootfs_present?
      end
      if !allow_outside_rootfs && effective_phase.environment.starts_with?("rootfs-") && !rootfs_marker_present?
        raise "Refusing to run #{effective_phase.name} (env=#{effective_phase.environment}) outside the produced rootfs (missing #{SysrootWorkspace::ROOTFS_MARKER_PATH})"
      end
      Log.info { "Executing phase #{effective_phase.name} (env=#{effective_phase.environment}, workspace=#{effective_phase.workspace})" }
      Log.info { "**** #{effective_phase.description} ****" }
      if destdir = effective_phase.destdir
        prepare_destdir(destdir)
      end
      run_steps(effective_phase, effective_phase.steps, runner, report_dir: report_dir, state: state, state_path: state_path, resume: resume)
      Log.info { "Completed phase #{effective_phase.name}" }
    end

    # Execute a list of BuildStep entries, stopping immediately on failure.
    def self.run_steps(phase : BuildPhase,
                       steps : Array(BuildStep),
                       runner = SystemRunner.new,
                       report_dir : String? = DEFAULT_REPORT_DIR,
                       state : SysrootBuildState? = nil,
                       state_path : String? = nil,
                       resume : Bool = true)
      Log.info { "Executing #{steps.size} build steps" }
      steps.each do |step|
        if resume && state && state.completed?(phase.name, step.name)
          Log.info { "Skipping previously completed #{phase.name}/#{step.name}" }
          next
        end
        rootfs_label = rootfs_context_label
        Log.info { "Building #{step.name} in #{step.workdir} (phase=#{phase.name}, rootfs=#{rootfs_label})" }
        begin
          effective_runner = runner
          if resume && state && retrying_step?(phase.name, step.name, state)
            effective_runner = SystemRunner.new(clean_build_dirs: false)
          end
          effective_runner.run(phase, step)
          if state
            state.mark_success(phase.name, step.name)
            state.save(state_path.not_nil!) if state_path
          end
        rescue ex
          report_path = report_dir ? write_failure_report(report_dir, phase, step, ex) : nil
          if state
            state.mark_failure(phase.name, step.name, ex.message, report_path)
            state.save(state_path.not_nil!) if state_path
          end
          raise ex
        end
      end
      Log.info { "All build steps completed" }
    end

    private def self.retrying_step?(phase_name : String, step_name : String, state : SysrootBuildState) : Bool
      failure = state.progress.last_failure
      return false unless failure
      failure.phase == phase_name && failure.step == step_name
    end

    private def self.filter_phases_by_state(phases : Array(BuildPhase), state : SysrootBuildState) : Array(BuildPhase)
      phases.compact_map do |phase|
        remaining = phase.steps.reject { |step| state.completed?(phase.name, step.name) }
        next nil if remaining.empty?
        BuildPhase.new(
          name: phase.name,
          description: phase.description,
          workspace: phase.workspace,
          environment: phase.environment,
          install_prefix: phase.install_prefix,
          destdir: phase.destdir,
          env: phase.env,
          steps: remaining,
        )
      end
    end

    # Select phases for execution based on the optional phase selector.
    private def self.selected_phases(plan : BuildPlan, requested : String?) : Array(BuildPhase)
      raise "Build plan is empty" if plan.phases.empty?
      unless requested
        return [default_phase(plan)]
      end
      return plan.phases if requested == "all"
      matching = plan.phases.select { |phase| phase.name == requested }
      raise "Unknown build phase #{requested}" if matching.empty?
      matching
    end

    private def self.default_phase(plan : BuildPlan) : BuildPhase
      if rootfs_marker_present?
        rootfs_phase = plan.phases.find { |phase| phase.environment.starts_with?("rootfs-") }
        return rootfs_phase if rootfs_phase
      end
      plan.phases.first
    end

    private def self.apply_rootfs_env_overrides(phases : Array(BuildPhase)) : Array(BuildPhase)
      phases.map do |phase|
        apply_rootfs_env_override(phase)
      end
    end

    private def self.apply_rootfs_env_override(phase : BuildPhase) : BuildPhase
      return phase unless phase.environment.starts_with?("rootfs-")
      overrides = native_rootfs_env
      merged = phase.env.dup
      overrides.each { |key, value| merged[key] = value }
      BuildPhase.new(
        name: phase.name,
        description: phase.description,
        workspace: phase.workspace,
        environment: phase.environment,
        install_prefix: phase.install_prefix,
        destdir: phase.destdir,
        env: merged,
        steps: phase.steps,
      )
    end

    private def self.native_rootfs_env : Hash(String, String)
      return {} of String => String unless File.exists?("/usr/bin/clang") && File.exists?("/usr/bin/clang++")
      {
        # Prefer prefix-free /usr tools but keep /opt/sysroot on PATH for the toolchain.
        "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin:/opt/sysroot/bin:/opt/sysroot/sbin",
      }
    end

    private def self.rootfs_context_label : String
      return "Alpine" unless rootfs_marker_present?
      return "workspace-BQ2" if File.exists?(WORKSPACE_ROOTFS_MARKER_PATH)
      "seed-BQ2"
    end

    private def self.apply_overrides(plan : BuildPlan, path : String) : BuildPlan
      return plan unless File.exists?(path)
      Log.info { "Applying build plan overrides from #{path}" }
      overrides = BuildPlanOverrides.from_json(File.read(path))
      overrides.apply(plan)
    end

    private def self.stage_iteration_files_for_destdirs(plan : BuildPlan, overrides_path : String?) : Nil
      plan_json = plan.to_pretty_json
      overrides_json = overrides_path && File.exists?(overrides_path) ? File.read(overrides_path) : nil
      plan.phases.each do |phase|
        next unless destdir = phase.destdir
        stage_path = File.join(destdir, DEFAULT_PLAN_PATH.lchop('/'))
        overrides_stage = File.join(destdir, DEFAULT_OVERRIDES_PATH.lchop('/'))
        report_stage = File.join(destdir, DEFAULT_REPORT_DIR.lchop('/'))

        FileUtils.mkdir_p(File.dirname(stage_path))
        File.write(stage_path, plan_json)
        File.write(overrides_stage, overrides_json || "{}\n")
        FileUtils.mkdir_p(report_stage)
      end
    rescue ex
      Log.warn { "Failed to stage iteration files into destdir rootfs: #{ex.message}" }
    end

    private def self.filter_phases_by_packages(phases : Array(BuildPhase), packages : Array(String)) : Array(BuildPhase)
      matched = Set(String).new
      phases.each do |phase|
        phase.steps.each do |step|
          matched << step.name if packages.includes?(step.name)
        end
      end
      missing = packages.uniq.reject { |name| matched.includes?(name) }
      raise "Requested package(s) not found in selected phases: #{missing.join(", ")}" unless missing.empty?

      selected = phases.compact_map do |phase|
        steps = phase.steps.select { |step| packages.includes?(step.name) }
        next nil if steps.empty?
        BuildPhase.new(
          name: phase.name,
          description: phase.description,
          workspace: phase.workspace,
          environment: phase.environment,
          install_prefix: phase.install_prefix,
          destdir: phase.destdir,
          env: phase.env,
          steps: steps,
        )
      end
      raise "No matching packages found in selected phases: #{packages.join(", ")}" if selected.empty?
      selected
    end

    private def self.describe_phases(phases : Array(BuildPhase)) : String
      phases.map do |phase|
        steps = phase.steps.map(&.name).join(", ")
        "#{phase.name} (#{phase.steps.size} steps): #{steps}"
      end.join(" | ")
    end

    private def self.default_overrides_path_for_plan(plan_path : String) : String?
      return DEFAULT_OVERRIDES_PATH if plan_path == DEFAULT_PLAN_PATH
      overrides_candidate = File.join(File.dirname(plan_path), File.basename(DEFAULT_OVERRIDES_PATH))
      return overrides_candidate if File.exists?(overrides_candidate)
      nil
    end

    # Creates a minimal directory skeleton for `DESTDIR` installs. The intent is
    # to keep packages with hard-coded expectations (e.g., `/usr/bin`) from
    # failing when the destdir tree is initially empty.
    private def self.prepare_destdir(destdir : String)
      FileUtils.mkdir_p(destdir)
      %w[bin dev etc lib opt proc sys tmp usr var workspace].each do |subdir|
        FileUtils.mkdir_p(File.join(destdir, subdir))
      end
      FileUtils.mkdir_p(File.join(destdir, "usr/bin"))
      FileUtils.mkdir_p(File.join(destdir, "usr/sbin"))
      FileUtils.mkdir_p(File.join(destdir, "usr/lib"))
      FileUtils.mkdir_p(File.join(destdir, "var/lib"))
    end

    private def self.write_failure_report(report_dir : String, phase : BuildPhase, step : BuildStep, ex : Exception) : String?
      FileUtils.mkdir_p(report_dir)
      timestamp = Time.utc.to_s("%Y%m%dT%H%M%S.%LZ")
      phase_slug = slugify(phase.name)
      step_slug = slugify(step.name)
      disambiguator = Random::Secure.hex(4)
      report_path = File.join(report_dir, "#{timestamp}-#{phase_slug}-#{step_slug}-#{disambiguator}.json")

      argv = nil
      exit_code = nil
      output_log = nil
      if ex.is_a?(CommandFailedError)
        argv = ex.argv
        exit_code = ex.exit_code
        output_log = ex.output_path
      end
      effective_env = phase.env.dup
      step.env.each { |key, value| effective_env[key] = value }

      report = {
        "format_version" => 1,
        "occurred_at"    => timestamp,
        "phase"          => {
          "name"           => phase.name,
          "environment"    => phase.environment,
          "workspace"      => phase.workspace,
          "install_prefix" => phase.install_prefix,
          "destdir"        => phase.destdir,
          "env"            => phase.env,
        },
        "step" => {
          "name"            => step.name,
          "strategy"        => step.strategy,
          "workdir"         => step.workdir,
          "install_prefix"  => step.install_prefix,
          "destdir"         => step.destdir,
          "env"             => step.env,
          "effective_env"   => effective_env,
          "configure_flags" => step.configure_flags,
          "patches"         => step.patches,
        },
        "command"    => argv,
        "exit_code"  => exit_code,
        "output_log" => output_log,
        "error"      => ex.message,
      }.to_pretty_json

      File.write(report_path, report)
      Log.error { "Wrote build failure report to #{report_path}" }
      report_path
    rescue report_ex
      Log.warn { "Failed to write build failure report: #{report_ex.message}" }
      nil
    end

    # Summarize the sysroot runner CLI behavior for help output.
    def self.summary : String
      "Replay build plan inside the sysroot"
    end

    # Return additional command aliases handled by the sysroot runner.
    def self.aliases : Array(String)
      ["sysroot-status"]
    end

    # Describe help output entries for sysroot runner commands.
    def self.help_entries : Array(Tuple(String, String))
      [
        {"sysroot-runner", "Replay build plan inside the sysroot"},
        {"sysroot-status", "Print current sysroot build phase"},
      ]
    end

    # Dispatch sysroot runner subcommands by command name.
    def self.run(args : Array(String), command_name : String) : Int32
      case command_name
      when "sysroot-runner"
        run_runner(args)
      when "sysroot-status"
        run_status(args)
      else
        raise "Unknown sysroot runner command #{command_name}"
      end
    end

    # Run build plan phases/steps inside the sysroot.
    private def self.run_runner(args : Array(String)) : Int32
      plan_path = SysrootRunner::DEFAULT_PLAN_PATH
      plan_explicit = false
      phase : String? = nil
      packages = [] of String
      overrides_path : String? = nil
      use_default_overrides = true
      report_dir : String? = SysrootRunner::DEFAULT_REPORT_DIR
      state_path : String? = nil
      dry_run = false
      resume = true
      allow_outside_rootfs = false
      rootfs : String? = nil
      extra_binds = [] of Tuple(Path, Path)
      run_alpine_setup = false
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-runner [options]") do |p|
        p.on("--plan PATH", "Read the build plan from PATH (default: #{SysrootRunner::DEFAULT_PLAN_PATH})") do |path|
          plan_path = path
          plan_explicit = true
        end
        p.on("--phase NAME", "Select build phase to run (default: first phase; use 'all' for every phase)") { |name| phase = name }
        p.on("--package NAME", "Only run the named package(s); repeatable") { |name| packages << name }
        p.on("--overrides PATH", "Apply runtime overrides JSON (default: #{SysrootRunner::DEFAULT_OVERRIDES_PATH} when using the default plan path)") do |path|
          overrides_path = path
          use_default_overrides = false
        end
        p.on("--no-overrides", "Disable runtime overrides") do
          overrides_path = nil
          use_default_overrides = false
        end
        p.on("--report-dir PATH", "Write failure reports to PATH (default: #{SysrootRunner::DEFAULT_REPORT_DIR})") { |path| report_dir = path }
        p.on("--no-report", "Disable failure report writing") { report_dir = nil }
        p.on("--state-path PATH", "Write runner state/bookmarks to PATH (default: #{SysrootRunner::DEFAULT_STATE_PATH} when using the default plan path)") { |path| state_path = path }
        p.on("--no-resume", "Disable resume/state tracking (useful when the default state path is not writable)") { resume = false }
        p.on("--allow-outside-rootfs", "Allow running rootfs-* phases outside the produced rootfs (requires destdir overrides)") { allow_outside_rootfs = true }
        p.on("--dry-run", "List selected phases/steps and exit") { dry_run = true }
        p.on("--rootfs=PATH", "Enter the rootfs namespace before running (default: none)") { |path| rootfs = path }
        p.on("--bind=SRC:DST", "Bind-mount SRC into DST inside the rootfs (repeatable)") do |val|
          extra_binds << parse_bind_spec(val)
        end
        p.on("--alpine-setup", "Install Alpine packages needed to replay the sysroot build plan") do
          run_alpine_setup = true
        end
      end
      return CLI.print_help(parser) if help

      rootfs_requested = !rootfs.nil?
      if rootfs
        rootfs_value = rootfs.not_nil!
        raise "Rootfs path does not exist: #{rootfs_value}" unless Dir.exists?(rootfs_value)
        SysrootNamespace.enter_rootfs_with_setup(rootfs_value,
          extra_binds: extra_binds,
          run_alpine_setup: run_alpine_setup)
      end

      if !rootfs_requested && plan_path == SysrootRunner::DEFAULT_PLAN_PATH && !plan_explicit
        resolved = resolve_status_paths(
          SysrootWorkspace.default_workspace.to_s,
          nil,
          state_path,
          false,
          false
        )
        plan_path = resolved.plan_path
        state_path ||= resolved.state_path
      end

      SysrootRunner.run_plan(
        plan_path,
        phase: phase,
        packages: packages.empty? ? nil : packages,
        overrides_path: overrides_path,
        use_default_overrides: use_default_overrides,
        report_dir: report_dir,
        dry_run: dry_run,
        state_path: state_path,
        resume: resume,
        allow_outside_rootfs: allow_outside_rootfs,
      )
      0
    end

    private def self.parse_bind_spec(value : String) : Tuple(Path, Path)
      parts = value.split(":", 2)
      raise "Expected --bind=SRC:DST" unless parts.size == 2
      src = Path[parts[0]].expand
      dst_raw = parts[1]
      dst_clean = dst_raw.starts_with?("/") ? dst_raw[1..] : dst_raw
      {src, Path[dst_clean]}
    end

    # Print the current build status and next phase/step.
    private def self.run_status(args : Array(String)) : Int32
      workspace = SysrootWorkspace.default_workspace.to_s
      rootfs : String? = nil
      state_path : String? = nil
      rootfs_explicit = false

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-status [options]") do |p|
        p.on("-w DIR", "--workspace=DIR", "Sysroot workspace directory (default: #{workspace})") { |val| workspace = val }
        p.on("--rootfs=PATH", "Prepared rootfs directory (default: <workspace>/rootfs)") do |val|
          rootfs = val
          rootfs_explicit = true
        end
        p.on("--state=PATH", "Explicit sysroot build state JSON path") { |val| state_path = val }
      end
      return CLI.print_help(parser) if help

      resolved = resolve_status_paths(workspace, rootfs, state_path, rootfs_explicit, false)
      rootfs_dir = resolved.rootfs_dir
      resolved_state_path = resolved.state_path
      raise "Missing sysroot build state at #{resolved_state_path}" unless File.exists?(resolved_state_path)

      state = SysrootBuildState.load(resolved_state_path)
      puts(state.progress.current_phase || "(none)")

      plan_path = resolved.plan_path
      plan_path = state.plan_path unless File.exists?(plan_path)
      if File.exists?(plan_path)
        plan = BuildPlan.from_json(File.read(plan_path))
        next_phase = plan.phases.find do |phase|
          phase.steps.any? { |step| !state.completed?(phase.name, step.name) }
        end
        if next_phase
          next_step = next_phase.steps.find { |step| !state.completed?(next_phase.name, step.name) }
          puts("next_phase=#{next_phase.name}")
          puts("next_step=#{next_step.not_nil!.name}") if next_step
        else
          puts("next_phase=(none)")
        end
      end

      if (success = state.progress.last_success)
        puts("last_success=#{success.phase}/#{success.step}")
      end
      if (failure = state.progress.last_failure)
        puts("last_failure=#{failure.phase}/#{failure.step}")
      end
      0
    end

    private def self.slugify(value : String) : String
      value.gsub(/[^A-Za-z0-9]+/, "_").gsub(/^_+|_+$/, "").downcase
    end
  end
end
