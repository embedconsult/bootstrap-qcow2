require "json"
require "log"
require "file_utils"
require "process"

module Bootstrap
  # SysrootRunner houses the logic that replays build steps inside the chroot.
  # It is kept in a regular source file so it benefits from formatting, linting,
  # and specs. The small main entrypoint simply requires this library and calls
  # `run_plan`.
  module SysrootRunner
    Log.setup("*", Log::Severity::Info)

    # Serializable representation of a single package build step, mirroring
    # the plan written by SysrootBuilder.
    struct BuildStep
      include JSON::Serializable
      property name : String
      property commands : Array(Array(String))
      property workdir : String

      def initialize(@name : String, @commands : Array(Array(String)), @workdir : String)
      end
    end

    # Abstraction for running commands; enables fast unit tests by supplying a
    # fake runner instead of invoking processes.
    module CommandRunner
      abstract def run(argv : Array(String), chdir : String? = nil)
    end

    # Default runner that shells out via Process.run.
    struct SystemRunner
      include CommandRunner

      def run(argv : Array(String), chdir : String? = nil)
        Process.run(argv[0], argv[1..], chdir: chdir)
      end
    end

    # Load a JSON build plan from disk and replay it using the provided runner.
    def self.run_plan(path : String = "/var/lib/sysroot-build-plan.json", runner : CommandRunner = SystemRunner.new)
      raise "Missing build plan #{path}" unless File.exists?(path)
      steps = Array(BuildStep).from_json(File.read(path))
      run_steps(steps, runner)
    end

    # Execute a list of BuildStep entries, stopping immediately on failure.
    def self.run_steps(steps : Array(BuildStep), runner : CommandRunner = SystemRunner.new)
      steps.each do |step|
        Log.info { "Building #{step.name} in #{step.workdir}" }
        step.commands.each do |argv|
          status = runner.run(argv, step.workdir)
          raise "Command failed (#{status.exit_code}): #{argv.join(" ")}" unless status.success?
        end
      end
      Log.info { "All sysroot components rebuilt" }
    end
  end
end
