require "json"
require "log"
require "file_utils"
require "process"

module Bootstrap
  # SysrootRunner houses the logic that replays build steps inside the chroot.
  # It is kept in a regular source file so it benefits from formatting, linting,
  # and specs. The small main entrypoint simply requires this library and calls
  # `run_plan`.
  class SysrootRunner
    # Serializable representation of a single package build step, mirroring
    # the plan written by SysrootBuilder.
    struct BuildStep
      include JSON::Serializable
      property name : String
      property strategy : String
      property workdir : String
      property configure_flags : Array(String)
      property patches : Array(String)
      property sysroot_prefix : String

      # Initialize a build-step record for JSON serialization.
      def initialize(@name : String, @strategy : String, @workdir : String, @configure_flags : Array(String), @patches : Array(String), @sysroot_prefix : String)
      end
    end

    # Abstraction for running build strategies; enables fast unit tests by
    # supplying a fake runner instead of invoking processes.
    module CommandRunner
      abstract def run(step : BuildStep)
    end

    # Default runner that shells out via Process.run using strategy metadata.
    struct SystemRunner
      include CommandRunner

      # Run a build step using the selected strategy.
      def run(step : BuildStep)
        Dir.cd(step.workdir) do
          cpus = (System.cpu_count || 1).to_i32
          Log.info { "Starting #{step.strategy} build for #{step.name} in #{step.workdir} (cpus=#{cpus})" }
          apply_patches(step.patches)
          case step.strategy
          when "cmake"
            run_cmd(["./bootstrap", "--prefix=#{step.sysroot_prefix}"])
            run_cmd(["make", "-j#{cpus}"])
            run_cmd(["make", "install"])
          when "busybox"
            run_cmd(["make", "defconfig"])
            run_cmd(["make", "-j#{cpus}"])
            run_cmd(["make", "CONFIG_PREFIX=#{step.sysroot_prefix}", "install"])
          when "llvm"
            run_cmd(["cmake", "-S", ".", "-B", "build", "-DCMAKE_INSTALL_PREFIX=#{step.sysroot_prefix}"] + step.configure_flags)
            run_cmd(["cmake", "--build", "build", "-j#{cpus}"])
            run_cmd(["cmake", "--install", "build"])
          when "crystal"
            run_cmd(["shards", "build"])
            run_cmd(["install", "-d", "#{step.sysroot_prefix}/bin"])
            run_cmd(["install", "-m", "0755", "bin/bq2", "#{step.sysroot_prefix}/bin/bq2"])
          else # autotools/default
            run_cmd(["./configure", "--prefix=#{step.sysroot_prefix}"] + step.configure_flags)
            run_cmd(["make", "-j#{cpus}"])
            run_cmd(["make", "install"])
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
      private def run_cmd(argv : Array(String))
        Log.info { "Running in #{Dir.current}: #{argv.join(" ")}" }
        status = Process.run(argv[0], argv[1..])
        unless status.success?
          Log.error { "Command failed (#{status.exit_code}): #{argv.join(" ")}" }
          raise "Command failed (#{status.exit_code}): #{argv.join(" ")}"
        end
        Log.debug { "Completed #{argv.first} with exit #{status.exit_code}" }
      end
    end

    # Load a JSON build plan from disk and replay it using the provided runner.
    def self.run_plan(path : String = "/var/lib/sysroot-build-plan.json", runner : CommandRunner = SystemRunner.new)
      raise "Missing build plan #{path}" unless File.exists?(path)
      Log.info { "Loading build plan from #{path}" }
      steps = Array(BuildStep).from_json(File.read(path))
      run_steps(steps, runner)
    end

    # Execute a list of BuildStep entries, stopping immediately on failure.
    def self.run_steps(steps : Array(BuildStep), runner : CommandRunner = SystemRunner.new)
      Log.info { "Executing #{steps.size} build steps" }
      steps.each do |step|
        Log.info { "Building #{step.name} in #{step.workdir}" }
        runner.run(step)
      end
      Log.info { "All sysroot components rebuilt" }
    end
  end
end
