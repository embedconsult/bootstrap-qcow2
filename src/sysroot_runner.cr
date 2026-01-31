require "json"
require "log"
require "file_utils"
require "process"
require "random/secure"
require "set"
require "time"
require "./build_plan"
require "./build_plan_overrides"
require "./alpine_setup"
require "./cli"
require "./process_runner"
require "./sysroot_builder"
require "./sysroot_namespace"
require "./sysroot_build_state"
require "./sysroot_workspace"

module Bootstrap
  # SysrootRunner houses the logic that replays build steps inside the chroot.
  # It is kept in a regular source file so it benefits from formatting, linting,
  # and specs. The main entrypoint registers the CLI class and dispatches into
  # the `run` helpers below.
  class SysrootRunner < CLI
    DEFAULT_ROOTFS = SysrootWorkspace::DEFAULT_HOST_WORKDIR / SysrootWorkspace::OUTER_ROOTFS_DIR

    # Returns true when running inside the inner rootfs.
    def self.rootfs_marker_present? : Bool
      SysrootWorkspace.inner_rootfs_marker_present?
    end

    # Returns true when the inner rootfs marker is visible from the outer rootfs.
    def self.outer_rootfs_marker_present? : Bool
      SysrootWorkspace.outer_rootfs_marker_present?
    end

    # Resolved workspace paths used by sysroot-status and resume logic.
    struct StatusPaths
      getter workspace : SysrootWorkspace
      getter build_state : SysrootBuildState
      getter state_path : Path

      def initialize(@workspace : SysrootWorkspace, @build_state : SysrootBuildState, state_path : Path? = nil)
        @state_path = state_path || @build_state.state_path
      end
    end

    # Resolve the workspace and build state using the same logic as sysroot-status.
    def self.resolve_status_paths(workspace : String?,
                                  rootfs : String?,
                                  state_path : String?) : StatusPaths
      if state_path
        resolved_state = Path[state_path].expand
        inner_rootfs = resolved_state.parent.parent.parent
        workspace_instance = SysrootWorkspace.from_inner_rootfs(inner_rootfs)
        build_state = SysrootBuildState.new(workspace: workspace_instance)
        return StatusPaths.new(workspace_instance, build_state, resolved_state)
      end

      if workspace
        workspace_instance = SysrootWorkspace.from_host_workdir(Path[workspace].expand)
        build_state = SysrootBuildState.new(workspace: workspace_instance)
        return StatusPaths.new(workspace_instance, build_state)
      end

      if rootfs
        workspace_instance = SysrootWorkspace.from_outer_rootfs(Path[rootfs].expand)
        build_state = SysrootBuildState.new(workspace: workspace_instance)
        return StatusPaths.new(workspace_instance, build_state)
      end

      workspace_instance = SysrootWorkspace.detect
      build_state = SysrootBuildState.new(workspace: workspace_instance)
      StatusPaths.new(workspace_instance, build_state)
    end

    private def self.workspace_for_plan(path : String) : SysrootWorkspace
      plan_path = Path[path].expand
      inner_rootfs = plan_path.parent.parent.parent
      SysrootWorkspace.from_inner_rootfs(inner_rootfs)
    end

    # Enter the inner rootfs when running inside the outer rootfs.
    def self.enter_inner_rootfs! : Nil
      workspace = SysrootWorkspace.detect
      Log.info { "Entering inner rootfs at #{workspace.inner_rootfs_path}" }
      SysrootNamespace.enter_rootfs(workspace.inner_rootfs_path.to_s)
    end

    # Enter the outer rootfs when running on the host.
    def self.enter_outer_rootfs! : Nil
      workspace = SysrootWorkspace.detect
      Log.info { "Entering outer rootfs at #{workspace.outer_rootfs_path}" }
      SysrootNamespace.enter_rootfs(workspace.outer_rootfs_path.to_s)
    end

    # Returns true when running in the host context (not outer/inner rootfs).
    def self.host_context? : Bool
      !rootfs_marker_present? && !outer_rootfs_marker_present?
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
          when "makefile-classic"
            makefile = "Makefile.bq2"
            raise "Missing #{makefile} in #{step.workdir}" unless File.exists?(makefile)
            run_cmd(["make", "-f", makefile, "-j#{cpus}"], env: env)
            if destdir
              run_cmd(["make", "-f", makefile, "DESTDIR=#{destdir}", "install"], env: env)
            else
              run_cmd(["make", "-f", makefile, "install"], env: env)
            end
          when "copy-tree"
            raise "copy-tree requires step.install_prefix (destination path)" unless step.install_prefix
            install_root = destdir ? "#{destdir}#{install_prefix}" : install_prefix
            FileUtils.mkdir_p(install_root)
            run_cmd(["cp", "-a", ".", install_root], env: env)
          when "write-file"
            raise "write-file requires step.install_prefix (file path)" unless step.install_prefix
            content = step.content || step.env["CONTENT"]?
            raise "write-file requires env CONTENT" unless content
            target = destdir ? "#{destdir}#{install_prefix}" : install_prefix
            FileUtils.mkdir_p(File.dirname(target))
            File.write(target, content)
          when "apk-add"
            packages = step.packages
            raise "apk-add requires step.packages" unless packages
            AlpineSetup.apk_add(packages)
          when "download-sources"
            host_setup_builder(phase) do |builder|
              builder.download_sources
            end
          when "extract-sources"
            host_setup_builder(phase) do |builder|
              builder.stage_sources(skip_existing: true)
            end
          when "populate-seed"
            host_setup_builder(phase) do |builder|
              builder.populate_seed_rootfs
            end
          when "alpine-setup"
            AlpineSetup.install_sysroot_runner_packages
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
            tar_excludes = [
              "--exclude=var/lib",
              "--exclude=var/lib/**",
              "--exclude=.bq2-rootfs",
            ]
            run_cmd(["tar", "-czf", output] + tar_excludes + ["-C", source_root, "."], env: env)
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
            if File.exists?("shard.yml") && run_shards_install?(env)
              run_cmd(["shards", "install"], env: env)
            elsif File.exists?("shard.yml")
              Log.info { "Skipping shards install for #{step.name} (prefetched during download phase)" }
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
              if step.clean_build && File.exists?("Makefile")
                status = run_cmd_status(["make", "distclean"], env: env)
                unless status.success?
                  Log.warn { "make distclean failed (#{status.exit_code}); attempting make clean" }
                  status = run_cmd_status(["make", "clean"], env: env)
                  Log.warn { "make clean failed (#{status.exit_code}); continuing" } unless status.success?
                end
              end
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

      # Returns true when shards install should be performed during build steps.
      private def run_shards_install?(env : Hash(String, String)) : Bool
        truthy_env?(env["BQ2_FORCE_SHARDS_INSTALL"]?)
      end

      private def host_setup_builder(phase : BuildPhase, &block : SysrootBuilder ->) : Nil
        builder = build_host_setup_builder(phase)
        with_source_branch(phase.env) do
          yield builder
        end
      end

      private def build_host_setup_builder(phase : BuildPhase) : SysrootBuilder
        arch = phase.env["BQ2_ARCH"]? || SysrootBuilder::DEFAULT_ARCH
        branch = phase.env["BQ2_BRANCH"]? || SysrootBuilder::DEFAULT_BRANCH
        base_version = phase.env["BQ2_BASE_VERSION"]? || SysrootBuilder::DEFAULT_BASE_VERSION
        base_rootfs_path = phase.env["BQ2_BASE_ROOTFS_PATH"]?.try { |path| Path[path].expand }
        use_system_tar_for_sources = truthy_env?(phase.env["BQ2_USE_SYSTEM_TAR_SOURCES"]?)
        use_system_tar_for_rootfs = truthy_env?(phase.env["BQ2_USE_SYSTEM_TAR_ROOTFS"]?)
        preserve_ownership_for_sources = truthy_env?(phase.env["BQ2_PRESERVE_OWNERSHIP_SOURCES"]?)
        preserve_ownership_for_rootfs = truthy_env?(phase.env["BQ2_PRESERVE_OWNERSHIP_ROOTFS"]?)
        owner_uid = phase.env["BQ2_OWNER_UID"]?.try(&.to_i?)
        owner_gid = phase.env["BQ2_OWNER_GID"]?.try(&.to_i?)
        SysrootBuilder.new(
          architecture: arch,
          branch: branch,
          base_version: base_version,
          base_rootfs_path: base_rootfs_path,
          use_system_tar_for_sources: use_system_tar_for_sources,
          use_system_tar_for_rootfs: use_system_tar_for_rootfs,
          preserve_ownership_for_sources: preserve_ownership_for_sources,
          preserve_ownership_for_rootfs: preserve_ownership_for_rootfs,
          owner_uid: owner_uid,
          owner_gid: owner_gid,
        )
      end

      private def with_source_branch(env : Hash(String, String), &block : -> T) : T forall T
        override = env["BQ2_SOURCE_BRANCH"]?
        previous = ENV["BQ2_SOURCE_BRANCH"]?
        if override
          ENV["BQ2_SOURCE_BRANCH"] = override
        end
        yield
      ensure
        if previous
          ENV["BQ2_SOURCE_BRANCH"] = previous
        else
          ENV.delete("BQ2_SOURCE_BRANCH")
        end
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
          env["LD_LIBRARY_PATH"] = "#{current}:#{sysroot_lib}"
        else
          env["LD_LIBRARY_PATH"] = sysroot_lib
        end
        env
      end

      # Returns true when a string environment value should be treated as true.
      private def truthy_env?(value : String?) : Bool
        return false unless value
        normalized = value.strip.downcase
        return false if normalized.empty?
        !(%w[0 false no].includes?(normalized))
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
    # When running inside the inner rootfs, the runner uses the state bookmark
    # under `/var/lib` to skip previously completed steps and to persist progress
    # for fast, iterative retries.
    def self.run_plan(path : String? = nil,
                      runner = SystemRunner.new,
                      phase : String? = nil,
                      packages : Array(String)? = nil,
                      overrides_path : String? = nil,
                      use_default_overrides : Bool = true,
                      report_dir : String? = nil,
                      dry_run : Bool = false,
                      state_path : String? = nil,
                      resume : Bool = true,
                      allow_outside_rootfs : Bool = false)
      workspace =
        if path
          workspace_for_plan(path)
        else
          SysrootWorkspace.detect
        end
      build_state = SysrootBuildState.new(workspace: workspace)
      plan_path = path || build_state.plan_path_path.to_s
      raise "Missing build plan #{plan_path}" unless File.exists?(plan_path)
      Log.info { "Loading build plan from #{plan_path}" }
      plan = BuildPlan.load(plan_path)
      effective_report_dir = report_dir || build_state.report_dir_path.to_s
      effective_overrides_path =
        if overrides_path
          overrides_path
        elsif use_default_overrides
          build_state.overrides_path_path.to_s
        end
      plan = apply_overrides(plan, effective_overrides_path) if effective_overrides_path
      stage_report_dirs_for_destdirs(plan, workspace)
      effective_state_path =
        if state_path
          state_path
        elsif resume
          build_state.state_path.to_s
        end
      state_path_obj = effective_state_path ? Path[effective_state_path] : nil
      overrides_path_obj = effective_overrides_path ? Path[effective_overrides_path] : nil
      report_dir_obj = effective_report_dir ? Path[effective_report_dir] : nil
      state = state_path_obj ? SysrootBuildState.load_or_init(workspace, state_path_obj, overrides_path: overrides_path_obj, report_dir: report_dir_obj) : nil
      state.try(&.save(state_path_obj.not_nil!)) if state_path_obj
      effective_runner = runner
      if runner.is_a?(SystemRunner) && effective_report_dir && runner.report_dir.nil?
        effective_runner = runner.with_report_dir(effective_report_dir)
      end
      run_plan(plan,
        effective_runner,
        phase: phase,
        packages: packages,
        report_dir: effective_report_dir,
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
                      report_dir : String? = nil,
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
      phases.each_with_index do |phase_plan, idx|
        if state
          state.progress.current_phase = phase_plan.name
          state.save(state_path ? Path[state_path] : nil)
        end
        run_phase(phase_plan, effective_runner, report_dir: report_dir, state: state, state_path: state_path, resume: resume, allow_outside_rootfs: allow_outside_rootfs)
        if state
          next_phase = phases[idx + 1]?.try(&.name)
          state.progress.current_phase = next_phase
          state.save(state_path ? Path[state_path] : nil)
        end
      end
    end

    # Run a single phase from the plan.
    def self.run_phase(phase : BuildPhase,
                       runner = SystemRunner.new,
                       report_dir : String? = nil,
                       state : SysrootBuildState? = nil,
                       state_path : String? = nil,
                       resume : Bool = true,
                       allow_outside_rootfs : Bool = false)
      effective_phase = phase
      if effective_phase.environment.starts_with?("host-")
        if rootfs_marker_present? || outer_rootfs_marker_present?
          raise "Refusing to run #{effective_phase.name} (env=#{effective_phase.environment}) outside the host"
        end
      elsif effective_phase.environment.in?({"alpine-seed", "sysroot-toolchain"})
        if rootfs_marker_present?
          raise "Refusing to run #{effective_phase.name} (env=#{effective_phase.environment}) inside the inner rootfs"
        elsif !outer_rootfs_marker_present?
          enter_outer_rootfs!
        end
      elsif effective_phase.environment.starts_with?("rootfs-")
        if !rootfs_marker_present?
          enter_outer_rootfs! unless outer_rootfs_marker_present?
          enter_inner_rootfs! if outer_rootfs_marker_present?
        end
        if rootfs_marker_present?
          effective_phase = apply_rootfs_env_override(effective_phase)
        elsif !allow_outside_rootfs
          raise "Refusing to run #{effective_phase.name} (env=#{effective_phase.environment}) outside the produced rootfs (missing #{SysrootWorkspace::ROOTFS_MARKER_NAME})"
        end
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
                       report_dir : String? = nil,
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
            state.save(state_path ? Path[state_path] : nil)
          end
        rescue ex
          report_path = report_dir ? write_failure_report(report_dir, phase, step, ex) : nil
          if state
            state.mark_failure(phase.name, step.name, ex.message, report_path)
            state.save(state_path ? Path[state_path] : nil)
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
      if outer_rootfs_marker_present?
        non_host = plan.phases.find { |phase| !phase.environment.starts_with?("host-") }
        return non_host if non_host
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
      return "inner-BQ2" if rootfs_marker_present?
      return "outer-Alpine" if outer_rootfs_marker_present?
      "Alpine"
    end

    private def self.apply_overrides(plan : BuildPlan, path : String) : BuildPlan
      return plan unless File.exists?(path)
      Log.info { "Applying build plan overrides from #{path}" }
      overrides = BuildPlanOverrides.from_json(File.read(path))
      overrides.apply(plan)
    end

    # Ensure report directories exist for phases that stage into a destdir
    # rootfs. The build plan and overrides are treated as immutable and must
    # be staged by the builder or plan writer rather than by sysroot-runner.
    private def self.stage_report_dirs_for_destdirs(plan : BuildPlan, workspace : SysrootWorkspace) : Nil
      rootfs_workspace = SysrootWorkspace::ROOTFS_WORKSPACE_PATH.to_s
      plan.phases.each do |phase|
        next unless destdir = phase.destdir
        destdir_path = Path[destdir]
        if workspace.host_workdir
          destdir_string = destdir_path.to_s
          if destdir_string == rootfs_workspace || destdir_string.starts_with?(rootfs_workspace + "/")
            suffix = destdir_string[rootfs_workspace.size..-1] || ""
            suffix = suffix.lstrip('/')
            destdir_path = workspace.rootfs_workspace_path / suffix
          end
        end
        report_stage = destdir_path / SysrootBuildState.rootfs_report_dir.lchop('/')
        FileUtils.mkdir_p(report_stage)
      end
    rescue ex
      Log.warn { "Failed to stage iteration report directories into destdir rootfs: #{ex.message}" }
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
      phase : String? = nil
      packages = [] of String
      overrides_path : String? = nil
      use_default_overrides = true
      report_dir : String? = nil
      report_explicit = false
      dry_run = false
      resume = true
      allow_outside_rootfs = false
      rootfs : String? = nil
      extra_binds = [] of Tuple(Path, Path)
      run_alpine_setup = false
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-runner [options]") do |p|
        p.on("--phase NAME", "Select build phase to run (default: all phases)") { |name| phase = name }
        p.on("--package NAME", "Only run the named package(s); repeatable") { |name| packages << name }
        p.on("--overrides PATH", "Apply runtime overrides JSON (default: sysroot-build-overrides.json in the inner rootfs var/lib)") do |path|
          overrides_path = path
          use_default_overrides = false
        end
        p.on("--no-overrides", "Disable runtime overrides") do
          overrides_path = nil
          use_default_overrides = false
        end
        p.on("--report-dir PATH", "Write failure reports to PATH (default: inner rootfs var/lib/sysroot-build-reports)") do |path|
          report_dir = path
          report_explicit = true
        end
        p.on("--no-report", "Disable failure report writing") { report_dir = nil }
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

      phase ||= "all"

      if rootfs
        rootfs_value = rootfs.not_nil!
        raise "Rootfs path does not exist: #{rootfs_value}" unless Dir.exists?(rootfs_value)
        Log.info { "Entering outer rootfs at #{rootfs_value} (explicit --rootfs)" }
        SysrootNamespace.enter_rootfs_with_setup(rootfs_value,
          extra_binds: extra_binds,
          run_alpine_setup: run_alpine_setup)
      end

      resolved = resolve_status_paths(nil, rootfs, nil)
      build_state = resolved.build_state
      plan_path = build_state.plan_path_path.to_s
      state_path = build_state.state_path.to_s
      if report_dir.nil? && !report_explicit
        report_dir = build_state.report_dir_path.to_s
      end
      if overrides_path.nil? && use_default_overrides
        overrides_path = build_state.overrides_path_path.to_s
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
      workspace : String? = nil
      rootfs : String? = nil
      state_path : String? = nil
      report_dir : String? = nil
      show_latest_report = false
      show_latest_log = false

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-status [options]") do |p|
        p.on("-w DIR", "--workspace=DIR", "Host workspace directory (debug only)") { |val| workspace = val }
        p.on("--rootfs=PATH", "Prepared rootfs directory (debug only)") { |val| rootfs = val }
        p.on("--state=PATH", "Explicit sysroot build state JSON path") { |val| state_path = val }
        p.on("--report-dir=PATH", "Override sysroot build report directory") { |val| report_dir = val }
        p.on("--latest-report", "Print the latest failure report JSON") { show_latest_report = true }
        p.on("--latest-log", "Print the output log from the latest failure report") { show_latest_log = true }
      end
      return CLI.print_help(parser) if help

      resolved = resolve_status_paths(workspace, rootfs, state_path)
      build_state = resolved.build_state
      state = SysrootBuildState.load(resolved.workspace, resolved.state_path)
      if build_state.plan_exists?
        plan = BuildPlan.parse(File.read(build_state.plan_path_path))
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
      puts(state.progress.current_phase || "(none)")

      if (success = state.progress.last_success)
        puts("last_success=#{success.phase}/#{success.step}")
      end
      if (failure = state.progress.last_failure)
        puts("last_failure=#{failure.phase}/#{failure.step}")
      end

      if show_latest_report || show_latest_log
        report_root = report_dir || build_state.report_dir_path.to_s
        report_root_value = report_root.not_nil!
        report_path = resolve_latest_report_path(state, report_root_value, resolved.state_path.to_s)
        log_path = report_path ? output_log_for_report(report_path) || report_log_path(report_path) : nil
        if report_path
          puts("latest_report=#{report_path}")
          puts(File.read(report_path)) if show_latest_report
        else
          puts("latest_report=(missing)")
        end
        if show_latest_log
          if log_path
            puts("latest_log=#{log_path}")
            puts(File.read(log_path)) if File.exists?(log_path)
          else
            puts("latest_log=(missing)")
          end
        end
      end
      0
    end

    private def self.resolve_latest_report_path(state : SysrootBuildState, _report_dir : String?, state_path : String?) : String?
      report_path = state.progress.last_failure.try(&.report_path)
      return nil unless report_path
      resolved = state.resolve_rootfs_path(report_path, state_path)
      return resolved if File.exists?(resolved)
      nil
    end

    private def self.latest_report_path(report_dir : String) : String?
      return nil unless Dir.exists?(report_dir)
      files = Dir.glob(File.join(report_dir, "*.json"))
      return nil if files.empty?
      files.sort.last
    end

    private def self.report_log_path(report_path : String) : String?
      return nil unless report_path.ends_with?(".json")
      candidate = report_path.sub(/\.json$/, ".log")
      File.exists?(candidate) ? candidate : nil
    end

    private def self.output_log_for_report(report_path : String) : String?
      json = JSON.parse(File.read(report_path))
      json["output_log"]?.try(&.as_s?)
    rescue ex
      Log.warn { "Failed to parse report #{report_path}: #{ex.message}" }
      nil
    end

    private def self.slugify(value : String) : String
      value.gsub(/[^A-Za-z0-9]+/, "_").gsub(/^_+|_+$/, "").downcase
    end
  end
end
