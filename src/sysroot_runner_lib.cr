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
require "./sysroot_namespace"
require "./sysroot_build_state"

module Bootstrap
  # SysrootRunner houses the logic that replays build steps inside the chroot.
  # It is kept in a regular source file so it benefits from formatting, linting,
  # and specs. The small main entrypoint simply requires this library and calls
  # `run_plan`.
  class SysrootRunner
    DEFAULT_PLAN_PATH      = "/var/lib/sysroot-build-plan.json"
    DEFAULT_OVERRIDES_PATH = "/var/lib/sysroot-build-overrides.json"
    DEFAULT_REPORT_DIR     = "/var/lib/sysroot-build-reports"
    DEFAULT_STATE_PATH     = SysrootBuildState::DEFAULT_PATH
    ROOTFS_MARKER_PATH     = "/.bq2-rootfs"
    ROOTFS_ENV_FLAG        = "BQ2_ROOTFS"
    # Default rootfs output directory from SysrootBuilder.phase_specs.
    WORKSPACE_ROOTFS_PATH        = "/workspace/rootfs"
    WORKSPACE_ROOTFS_MARKER_PATH = "#{WORKSPACE_ROOTFS_PATH}#{ROOTFS_MARKER_PATH}"

    # Returns true when a rootfs marker is present (env override or marker file).
    def self.rootfs_marker_present? : Bool
      if value = ENV[ROOTFS_ENV_FLAG]?
        normalized = value.strip.downcase
        return false if normalized.empty? || normalized == "0" || normalized == "false" || normalized == "no"
        return true
      end
      File.exists?(ROOTFS_MARKER_PATH)
    end

    # Returns true when the workspace rootfs has been created.
    def self.workspace_rootfs_present? : Bool
      File.exists?(WORKSPACE_ROOTFS_MARKER_PATH)
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

      def initialize(@argv : Array(String), @exit_code : Int32, message : String)
        super(message)
      end
    end

    # Default runner that shells out via Process.run using strategy metadata.
    struct SystemRunner
      getter clean_build_dirs : Bool

      def initialize(@clean_build_dirs : Bool = true)
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
              bootstrap_argv = [bootstrap_path, "--prefix=#{install_prefix}"]
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
          when "llvm"
            source_dir = "."
            unless File.exists?("CMakeLists.txt")
              source_dir = "llvm" if File.exists?(File.join("llvm", "CMakeLists.txt"))
            end
            FileUtils.rm_rf("build") if clean_build_dirs && Dir.exists?("build")
            run_cmd(["cmake", "-S", source_dir, "-B", "build", "-DCMAKE_INSTALL_PREFIX=#{install_prefix}"] + step.configure_flags, env: env)
            run_cmd(["cmake", "--build", "build", "-j#{cpus}"], env: env)
            install_env = destdir ? env.merge({"DESTDIR" => destdir}) : env
            run_cmd(["cmake", "--install", "build"], env: install_env)
          when "llvm-libcxx"
            source_dir = "."
            unless File.exists?("CMakeLists.txt")
              source_dir = "llvm" if File.exists?(File.join("llvm", "CMakeLists.txt"))
            end

            stage1_build_dir = "build-stage1"
            stage2_build_dir = "build-stage2"
            if clean_build_dirs
              FileUtils.rm_rf(stage1_build_dir) if Dir.exists?(stage1_build_dir)
              FileUtils.rm_rf(stage2_build_dir) if Dir.exists?(stage2_build_dir)
            end

            stage1_cc = env["CC"]? || Process.find_executable("clang") || "clang"
            stage1_cxx = env["CXX"]? || Process.find_executable("clang++") || "clang++"
            stage1_flags = step.configure_flags.reject { |flag| flag.starts_with?("-DLLVM_ENABLE_LIBCXX=") } + [
              "-DCMAKE_C_COMPILER=#{stage1_cc}",
              "-DCMAKE_CXX_COMPILER=#{stage1_cxx}",
            ]
            run_cmd(["cmake", "-S", source_dir, "-B", stage1_build_dir, "-DCMAKE_INSTALL_PREFIX=#{install_prefix}"] + stage1_flags, env: env)
            run_cmd(["cmake", "--build", stage1_build_dir, "-j#{cpus}"], env: env)
            install_env = destdir ? env.merge({"DESTDIR" => destdir}) : env
            run_cmd(["cmake", "--install", stage1_build_dir], env: install_env)

            install_root = destdir ? "#{destdir}#{install_prefix}" : install_prefix
            stage2_cc = "#{install_root}/bin/clang"
            stage2_cxx = "#{install_root}/bin/clang++"
            raise "llvm-libcxx stage2 requires #{stage2_cc}" unless File.exists?(stage2_cc)
            raise "llvm-libcxx stage2 requires #{stage2_cxx}" unless File.exists?(stage2_cxx)
            triple = detect_clang_target_triple(stage2_cc, env: env)
            libcxx_include = "#{install_root}/include/c++/v1"
            libcxx_target_include = "#{install_root}/include/#{triple}/c++/v1"
            libcxx_libdir = "#{install_root}/lib/#{triple}"
            libcxx_archive = "#{libcxx_libdir}/libc++.a"
            libcxxabi_archive = "#{libcxx_libdir}/libc++abi.a"
            libunwind_archive = "#{libcxx_libdir}/libunwind.a"
            cxx_standard_libs = "-Wl,--start-group #{libcxx_archive} #{libcxxabi_archive} #{libunwind_archive} -Wl,--end-group"

            stage2_flags = step.configure_flags.reject { |flag| flag.starts_with?("-DLLVM_ENABLE_RUNTIMES=") } + [
              "-DCMAKE_C_COMPILER=#{stage2_cc}",
              "-DCMAKE_CXX_COMPILER=#{stage2_cxx}",
              "-DCMAKE_C_FLAGS=--rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld",
              "-DCMAKE_CXX_FLAGS=-nostdinc++ -isystem #{libcxx_include} -isystem #{libcxx_target_include} -nostdlib++ -stdlib=libc++ --rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld -L#{libcxx_libdir} -L#{install_root}/lib",
              "-DCMAKE_CXX_STANDARD_LIBRARIES=#{cxx_standard_libs}",
              "-DCMAKE_EXE_LINKER_FLAGS=--rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld -L#{libcxx_libdir} -L#{install_root}/lib",
              "-DCMAKE_SHARED_LINKER_FLAGS=--rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld -L#{libcxx_libdir} -L#{install_root}/lib",
              "-DCMAKE_MODULE_LINKER_FLAGS=--rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld -L#{libcxx_libdir} -L#{install_root}/lib",
            ]
            run_cmd(["cmake", "-S", source_dir, "-B", stage2_build_dir, "-DCMAKE_INSTALL_PREFIX=#{install_prefix}"] + stage2_flags, env: env)
            run_cmd(["cmake", "--build", stage2_build_dir, "-j#{cpus}"], env: env)
            run_cmd(["cmake", "--install", stage2_build_dir], env: install_env)
          when "crystal"
            run_cmd(["shards", "build"], env: env)
            bin_prefix = destdir ? "#{destdir}#{install_prefix}" : install_prefix
            run_cmd(["install", "-d", "#{bin_prefix}/bin"], env: env)
            Dir.glob("bin/*").each do |artifact|
              run_cmd(["install", "-m", "0755", artifact, "#{bin_prefix}/bin/"], env: env)
            end
          when "crystal-build"
            if File.exists?("shard.yml")
              if skip_shards_install?(env)
                Log.info { "Skipping shards install for #{step.name} (BQ2_SKIP_SHARDS_INSTALL=1)" }
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
            elsif File.exists?("CMakeLists.txt")
              FileUtils.rm_rf("build") if clean_build_dirs && Dir.exists?("build")
              run_cmd(["cmake", "-S", ".", "-B", "build", "-DCMAKE_INSTALL_PREFIX=#{install_prefix}"] + step.configure_flags, env: env)
              run_cmd(["cmake", "--build", "build", "-j#{cpus}"], env: env)
              install_env = destdir ? env.merge({"DESTDIR" => destdir}) : env
              run_cmd(["cmake", "--install", "build"], env: install_env)
            else
              raise "Unknown build strategy #{step.strategy} and missing ./configure in #{step.workdir}"
            end
          end
          Log.info { "Finished #{step.name}" }
        end
      end

      # Many release tarballs include pre-generated autotools artifacts
      # (`configure`, `aclocal.m4`, etc.) that should not be regenerated during
      # a normal build. If an extractor fails to preserve mtimes, those artifacts
      # can appear older than `configure.ac` and trigger automake/autoconf
      # rebuild rules, which breaks minimal bootstrap environments.
      private def skip_shards_install?(env : Hash(String, String)) : Bool
        value = env["BQ2_SKIP_SHARDS_INSTALL"]?.try(&.strip.downcase)
        return false unless value
        !(value.empty? || value == "0" || value == "false" || value == "no")
      end

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
          dry_status = Process.run(dry_run[0], dry_run[1..], output: STDOUT, error: STDERR)
          if dry_status.success?
            argv = ["patch", "-p1", "--forward", "-N", "-i", patch]
            status = Process.run(argv[0], argv[1..], output: STDOUT, error: STDERR)
            raise CommandFailedError.new(argv, status.exit_code, "Patch failed (#{status.exit_code}): #{patch}") unless status.success?
            next
          end

          reverse_dry_run = ["patch", "-p1", "--reverse", "--dry-run", "-i", patch]
          reverse_status = Process.run(reverse_dry_run[0], reverse_dry_run[1..], output: STDOUT, error: STDERR)
          if reverse_status.success?
            Log.info { "Patch already applied; skipping #{patch}" }
            next
          end

          raise CommandFailedError.new(dry_run, dry_status.exit_code, "Patch failed (#{dry_status.exit_code}): #{patch}")
        end
      end

      # Run a command array and raise if it fails.
      private def run_cmd(argv : Array(String), env : Hash(String, String) = {} of String => String)
        Log.info { "Running in #{Dir.current}: #{argv.join(" ")}" }
        status = Process.run(argv[0], argv[1..], env: env, output: STDOUT, error: STDERR)
        unless status.success?
          Log.error { "Command failed (#{status.exit_code}): #{argv.join(" ")}" }
          raise CommandFailedError.new(argv, status.exit_code, "Command failed (#{status.exit_code}): #{argv.join(" ")}")
        end
        Log.debug { "Completed #{argv.first} with exit #{status.exit_code}" }
      end

      private def detect_clang_target_triple(clang_path : String, env : Hash(String, String)) : String
        output = IO::Memory.new
        status = Process.run(clang_path, ["-dumpmachine"], env: env, output: output, error: STDERR)
        unless status.success?
          raise CommandFailedError.new([clang_path, "-dumpmachine"], status.exit_code, "Failed to detect target triple via #{clang_path} -dumpmachine")
        end
        triple = output.to_s.strip
        raise "Empty target triple from #{clang_path} -dumpmachine" if triple.empty?
        triple
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
        elsif use_default_overrides && path == DEFAULT_PLAN_PATH
          DEFAULT_OVERRIDES_PATH
        end
      plan = apply_overrides(plan, effective_overrides_path) if effective_overrides_path
      stage_iteration_files_for_destdirs(plan, effective_overrides_path)
      effective_state_path = state_path || (resume && path == DEFAULT_PLAN_PATH ? DEFAULT_STATE_PATH : nil)
      state = effective_state_path ? SysrootBuildState.load_or_init(effective_state_path, plan_path: path, overrides_path: effective_overrides_path, report_dir: report_dir) : nil
      state.try(&.save(effective_state_path.not_nil!)) if effective_state_path
      run_plan(plan,
        runner,
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
      phases.each do |phase_plan|
        run_phase(phase_plan, runner, report_dir: report_dir, state: state, state_path: state_path, resume: resume, allow_outside_rootfs: allow_outside_rootfs)
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
        raise "Refusing to run #{effective_phase.name} (env=#{effective_phase.environment}) outside the produced rootfs (missing #{ROOTFS_MARKER_PATH})"
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
      {
        # Prefer prefix-free /usr tools but keep /opt/sysroot on PATH for the toolchain.
        "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin:/opt/sysroot/bin:/opt/sysroot/sbin",
        "CC"   => "clang --rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld",
        "CXX"  => "clang++ --rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld -stdlib=libc++",
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
      plan_json = plan.to_json
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
      if ex.is_a?(CommandFailedError)
        argv = ex.argv
        exit_code = ex.exit_code
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
        "command"   => argv,
        "exit_code" => exit_code,
        "error"     => ex.message,
      }.to_json

      File.write(report_path, report)
      Log.error { "Wrote build failure report to #{report_path}" }
      report_path
    rescue report_ex
      Log.warn { "Failed to write build failure report: #{report_ex.message}" }
      nil
    end

    private def self.slugify(value : String) : String
      value.gsub(/[^A-Za-z0-9]+/, "_").gsub(/^_+|_+$/, "").downcase
    end
  end
end
