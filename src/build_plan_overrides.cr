require "json"
require "set"
require "./build_plan"

module Bootstrap
  # Represents user-supplied, runtime-only overrides that can be applied to an
  # embedded `BuildPlan` JSON without recompiling the tooling.
  #
  # Intended workflow:
  # 1. Run `bq2 sysroot-runner` and observe a failure.
  # 2. Edit an overrides JSON (default: `/var/lib/sysroot-build-overrides.json`)
  #    to add flags/env for the failing phase/package.
  # 3. Re-run the runner for just the affected phase/package.
  # 4. Once stable, back-port the overrides into `SysrootBuilder.phase_specs` so
  #    the build becomes reproducible from scratch.
  struct BuildPlanOverrides
    include JSON::Serializable

    getter phases : Hash(String, PhaseOverride) = {} of String => PhaseOverride

    def initialize(@phases : Hash(String, PhaseOverride) = {} of String => PhaseOverride)
    end

    # Apply the overrides to *plan* and return a new plan.
    #
    # Raises when the overrides reference unknown phases or unknown packages in
    # a phase package allowlist.
    def apply(plan : BuildPlan) : BuildPlan
      validate_phases_exist(plan)
      phases = plan.phases.map { |phase| apply_phase(phase) }
      BuildPlan.new(phases: phases, format_version: plan.format_version)
    end

    private def validate_phases_exist(plan : BuildPlan)
      known = plan.phases.map(&.name).to_set
      missing = @phases.keys.reject { |name| known.includes?(name) }
      raise "Unknown build phases in overrides: #{missing.join(", ")}" unless missing.empty?
    end

    private def apply_phase(phase : BuildPhase) : BuildPhase
      override = @phases[phase.name]?
      return phase unless override

      install_prefix = override.install_prefix || phase.install_prefix
      destdir = override.destdir || phase.destdir
      env = merge_env(phase.env, override.env)
      steps = apply_phase_packages(phase.steps, override.packages)
      steps = steps.map { |step| apply_step(phase.name, step, override.steps) }
      BuildPhase.new(
        name: phase.name,
        description: phase.description,
        workspace: phase.workspace,
        environment: phase.environment,
        install_prefix: install_prefix,
        destdir: destdir,
        env: env,
        steps: steps,
      )
    end

    private def apply_phase_packages(steps : Array(BuildStep), packages : Array(String)?) : Array(BuildStep)
      return steps unless packages
      steps_by_name = steps.to_h { |step| {step.name, step} }
      packages.map do |name|
        step = steps_by_name[name]?
        raise "Unknown package #{name} in overrides allowlist" unless step
        step
      end
    end

    private def apply_step(phase_name : String, step : BuildStep, overrides : Hash(String, StepOverride)?) : BuildStep
      return step unless overrides
      override = overrides[step.name]?
      return step unless override

      install_prefix = override.install_prefix || step.install_prefix
      destdir = override.destdir || step.destdir
      env = merge_env(step.env, override.env)
      configure_flags = step.configure_flags + override.configure_flags_add
      patches = step.patches + override.patches_add
      BuildStep.new(
        name: step.name,
        strategy: step.strategy,
        workdir: step.workdir,
        configure_flags: configure_flags,
        patches: patches,
        install_prefix: install_prefix,
        destdir: destdir,
        env: env,
      )
    end

    private def merge_env(base : Hash(String, String), extra : Hash(String, String)?) : Hash(String, String)
      return base unless extra
      merged = base.dup
      extra.each { |key, value| merged[key] = value }
      merged
    end
  end

  struct PhaseOverride
    include JSON::Serializable

    getter install_prefix : String?
    getter destdir : String?
    getter env : Hash(String, String)?
    getter packages : Array(String)?
    getter steps : Hash(String, StepOverride)?

    def initialize(@install_prefix : String? = nil,
                   @destdir : String? = nil,
                   @env : Hash(String, String)? = nil,
                   @packages : Array(String)? = nil,
                   @steps : Hash(String, StepOverride)? = nil)
    end
  end

  struct StepOverride
    include JSON::Serializable

    getter install_prefix : String?
    getter destdir : String?
    getter env : Hash(String, String)?
    getter configure_flags_add : Array(String) = [] of String
    getter patches_add : Array(String) = [] of String

    def initialize(@install_prefix : String? = nil,
                   @destdir : String? = nil,
                   @env : Hash(String, String)? = nil,
                   @configure_flags_add : Array(String) = [] of String,
                   @patches_add : Array(String) = [] of String)
    end
  end
end
