require "json"
require "log"
require "file_utils"
require "process"

module Bootstrap
  module SysrootRunner
    Log.setup("*", Log::Severity::Info)

    struct BuildStep
      include JSON::Serializable
      property name : String
      property commands : Array(Array(String))
      property workdir : String

      def initialize(@name : String, @commands : Array(Array(String)), @workdir : String)
      end
    end

    module CommandRunner
      abstract def run(argv : Array(String), chdir : String? = nil)
    end

    struct SystemRunner
      include CommandRunner

      def run(argv : Array(String), chdir : String? = nil)
        Process.run(argv[0], argv[1..], chdir: chdir)
      end
    end

    def self.run_plan(path : String = "/var/lib/sysroot-build-plan.json", runner : CommandRunner = SystemRunner.new)
      raise "Missing build plan #{path}" unless File.exists?(path)
      steps = Array(BuildStep).from_json(File.read(path))
      run_steps(steps, runner)
    end

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
