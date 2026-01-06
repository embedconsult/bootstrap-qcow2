require "json"
require "log"
require "file_utils"
require "process"

Log.setup("*", Log::Severity::Info)

struct BuildStep
  include JSON::Serializable
  property name : String
  property commands : Array(Array(String))
  property workdir : String
end

steps_file = "/var/lib/sysroot-build-plan.json"
raise "Missing build plan #{steps_file}" unless File.exists?(steps_file)

steps = Array(BuildStep).from_json(File.read(steps_file))
steps.each do |step|
  Log.info { "Building #{step.name} in #{step.workdir}" }
  step.commands.each do |argv|
    status = Process.run(argv[0], argv[1..], chdir: step.workdir)
    raise "Command failed (#{status.exit_status}): #{argv.join(" ")}" unless status.success?
  end
end

Log.info { "All sysroot components rebuilt" }
