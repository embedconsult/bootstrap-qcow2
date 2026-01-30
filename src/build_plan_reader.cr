require "json"
require "./build_plan"
require "./sysroot_workspace"

module Bootstrap
  # Loads and parses serialized build plans written into the sysroot.
  #
  # The canonical on-disk format is `Bootstrap::BuildPlan` (an object with
  # `format_version` and `phases`). Earlier sysroot images used an array of step
  # objects; we continue to accept that legacy schema so older rootfs builds can
  # still be iterated on via `sysroot-runner`.
  module BuildPlanReader
    struct LegacyStep
      include JSON::Serializable

      getter name : String
      getter strategy : String
      getter workdir : String
      getter configure_flags : Array(String)
      getter patches : Array(String)

      @[JSON::Field(key: "sysroot_prefix")]
      getter sysroot_prefix : String
    end

    def self.load(path : String) : BuildPlan
      parse(File.read(path))
    end

    def self.parse(json : String) : BuildPlan
      stripped = json.lstrip
      return parse_legacy_steps(json) if stripped.starts_with?("[")
      BuildPlan.from_json(json)
    end

    private def self.parse_legacy_steps(json : String) : BuildPlan
      legacy_steps = Array(LegacyStep).from_json(json)
      install_prefix = legacy_steps.first?.try(&.sysroot_prefix) || "/opt/sysroot"
      steps = legacy_steps.map do |step|
        BuildStep.new(
          name: step.name,
          strategy: step.strategy,
          workdir: step.workdir,
          configure_flags: step.configure_flags,
          patches: step.patches,
        )
      end

      phase = BuildPhase.new(
        name: "sysroot-from-alpine",
        description: "Legacy plan (unphased)",
        workspace: SysrootWorkspace::ROOTFS_WORKSPACE_PATH.to_s,
        environment: "legacy",
        install_prefix: install_prefix,
        steps: steps,
      )

      BuildPlan.new(phases: [phase], format_version: 0)
    end
  end
end
