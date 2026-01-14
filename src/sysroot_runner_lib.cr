require "json"
require "log"
require "file_utils"
require "process"
require "./build_plan"

module Bootstrap
  # SysrootRunner houses the logic that replays build steps inside the chroot.
  # It is kept in a regular source file so it benefits from formatting, linting,
  # and specs. The small main entrypoint simply requires this library and calls
  # `run_plan`.
  class SysrootRunner
    # Abstraction for running build strategies; enables fast unit tests by
    # supplying a fake runner instead of invoking processes.
    module CommandRunner
      # Executes a single *step* within the context of its containing *phase*.
      abstract def run(phase : BuildPhase, step : BuildStep)
    end

    # Default runner that shells out via Process.run using strategy metadata.
    struct SystemRunner
      include CommandRunner

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
            run_cmd(["./bootstrap", "--prefix=#{install_prefix}"], env: env)
            run_cmd(["make", "-j#{cpus}"], env: env)
            run_make_install(destdir, env)
          when "busybox"
            run_cmd(["make", "defconfig"], env: env)
            run_cmd(["make", "-j#{cpus}"], env: env)
            install_root = destdir || install_prefix
            run_cmd(["make", "CONFIG_PREFIX=#{install_root}", "install"], env: env)
          when "llvm"
            run_cmd(["cmake", "-S", ".", "-B", "build", "-DCMAKE_INSTALL_PREFIX=#{install_prefix}"] + step.configure_flags, env: env)
            run_cmd(["cmake", "--build", "build", "-j#{cpus}"], env: env)
            install_env = destdir ? env.merge({"DESTDIR" => destdir}) : env
            run_cmd(["cmake", "--install", "build"], env: install_env)
          when "crystal"
            run_cmd(["shards", "build"], env: env)
            bin_prefix = destdir ? "#{destdir}#{install_prefix}" : install_prefix
            run_cmd(["install", "-d", "#{bin_prefix}/bin"], env: env)
            Dir.glob("bin/*").each do |artifact|
              run_cmd(["install", "-m", "0755", artifact, "#{bin_prefix}/bin/"], env: env)
            end
          else # autotools/default
            run_cmd(["./configure", "--prefix=#{install_prefix}"] + step.configure_flags, env: env)
            run_cmd(["make", "-j#{cpus}"], env: env)
            run_make_install(destdir, env)
          end
          Log.info { "Finished #{step.name}" }
        end
      end

      # Apply patch files before invoking build commands.
      private def apply_patches(patches : Array(String))
        patches.each do |patch|
          Log.info { "Applying patch #{patch}" }
          status = Process.run("patch", ["-p1", "-i", patch])
          raise "Patch failed (#{status.exit_code}): #{patch}" unless status.success?
        end
      end

      # Run a command array and raise if it fails.
      private def run_cmd(argv : Array(String), env : Hash(String, String) = {} of String => String)
        Log.info { "Running in #{Dir.current}: #{argv.join(" ")}" }
        status = Process.run(argv[0], argv[1..], env: env)
        unless status.success?
          Log.error { "Command failed (#{status.exit_code}): #{argv.join(" ")}" }
          raise "Command failed (#{status.exit_code}): #{argv.join(" ")}"
        end
        Log.debug { "Completed #{argv.first} with exit #{status.exit_code}" }
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
        merged
      end
    end

    # Load a JSON build plan from disk and replay it using the provided runner.
    # By default only the first phase is executed; pass `phase: "all"` or a
    # specific phase name to override.
    def self.run_plan(path : String = "/var/lib/sysroot-build-plan.json", runner : CommandRunner = SystemRunner.new, phase : String? = nil)
      raise "Missing build plan #{path}" unless File.exists?(path)
      Log.info { "Loading build plan from #{path}" }
      plan = BuildPlan.from_json(File.read(path))
      run_plan(plan, runner, phase)
    end

    # Execute an in-memory plan without requiring it to be read from disk.
    # By default only the first phase is executed; pass `phase: "all"` or a
    # specific phase name to override.
    def self.run_plan(plan : BuildPlan, runner : CommandRunner = SystemRunner.new, phase : String? = nil)
      phases = selected_phases(plan, phase)
      phases.each do |phase_plan|
        run_phase(phase_plan, runner)
      end
    end

    # Run a single phase from the plan.
    def self.run_phase(phase : BuildPhase, runner : CommandRunner = SystemRunner.new)
      Log.info { "Executing phase #{phase.name} (env=#{phase.environment}, workspace=#{phase.workspace})" }
      if destdir = phase.destdir
        prepare_destdir(destdir)
      end
      run_steps(phase, phase.steps, runner)
      Log.info { "Completed phase #{phase.name}" }
    end

    # Execute a list of BuildStep entries, stopping immediately on failure.
    def self.run_steps(phase : BuildPhase, steps : Array(BuildStep), runner : CommandRunner = SystemRunner.new)
      Log.info { "Executing #{steps.size} build steps" }
      steps.each do |step|
        Log.info { "Building #{step.name} in #{step.workdir}" }
        runner.run(phase, step)
      end
      Log.info { "All build steps completed" }
    end

    # Select phases for execution based on the optional phase selector.
    private def self.selected_phases(plan : BuildPlan, requested : String?) : Array(BuildPhase)
      raise "Build plan is empty" if plan.phases.empty?
      return [plan.phases.first] unless requested
      return plan.phases if requested == "all"
      matching = plan.phases.select { |phase| phase.name == requested }
      raise "Unknown build phase #{requested}" if matching.empty?
      matching
    end

    # Creates a minimal directory skeleton for `DESTDIR` installs. The intent is
    # to keep packages with hard-coded expectations (e.g., `/usr/bin`) from
    # failing when the destdir tree is initially empty.
    private def self.prepare_destdir(destdir : String)
      FileUtils.mkdir_p(destdir)
      %w[bin dev etc lib proc sys tmp usr var].each do |subdir|
        FileUtils.mkdir_p(File.join(destdir, subdir))
      end
      FileUtils.mkdir_p(File.join(destdir, "usr/bin"))
      FileUtils.mkdir_p(File.join(destdir, "usr/sbin"))
      FileUtils.mkdir_p(File.join(destdir, "usr/lib"))
      FileUtils.mkdir_p(File.join(destdir, "var/lib"))
    end
  end
end
