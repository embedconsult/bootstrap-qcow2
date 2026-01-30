require "json"
require "./build_plan"

module Bootstrap
  # Loads and parses serialized build plans written into the sysroot.
  #
  # The canonical on-disk format is `Bootstrap::BuildPlan` (an object with
  # `format_version` and `phases`).
  module BuildPlanReader
    def self.load(path : String) : BuildPlan
      parse(File.read(path))
    end

    def self.parse(json : String) : BuildPlan
      stripped = json.lstrip
      if stripped.starts_with?("[")
        raise "Legacy build plan format is not supported; regenerate the plan with sysroot-builder"
      end
      BuildPlan.from_json(json)
    end
  end
end
