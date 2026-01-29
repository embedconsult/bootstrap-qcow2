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

    # Returns overrides that transform *base_plan* into *target_plan*.
    #
    # Raises if differences cannot be represented via runtime overrides.
    def self.from_diff(base_plan : BuildPlan, target_plan : BuildPlan) : BuildPlanOverrides
      ensure_format_version(base_plan, target_plan)
      base_phases = index_phases(base_plan)
      target_phases = index_phases(target_plan)
      ensure_phase_sets_match(base_phases, target_phases)
      overrides = {} of String => PhaseOverride
      target_plan.phases.each do |target_phase|
        base_phase = base_phases[target_phase.name]
        override = diff_phase(base_phase, target_phase)
        overrides[target_phase.name] = override if override
      end
      BuildPlanOverrides.new(phases: overrides)
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
      allow = packages.to_set
      missing = packages.reject { |name| steps.any? { |step| step.name == name } }
      raise "Unknown package(s) #{missing.join(", ")} in overrides allowlist" unless missing.empty?
      steps.select { |step| allow.includes?(step.name) }
    end

    private def apply_step(phase_name : String, step : BuildStep, overrides : Hash(String, StepOverride)?) : BuildStep
      return step unless overrides
      override = overrides[step.name]?
      return step unless override

      workdir = override.workdir || step.workdir
      build_dir = override.build_dir || step.build_dir
      install_prefix = override.install_prefix || step.install_prefix
      destdir = override.destdir || step.destdir
      env = merge_env(step.env, override.env)
      configure_flags = (override.configure_flags || step.configure_flags) + override.configure_flags_add
      patches = (override.patches || step.patches) + override.patches_add
      clean_build = override.clean_build.nil? ? step.clean_build : override.clean_build.not_nil!
      BuildStep.new(
        name: step.name,
        strategy: step.strategy,
        workdir: workdir,
        configure_flags: configure_flags,
        patches: patches,
        install_prefix: install_prefix,
        destdir: destdir,
        env: env,
        build_dir: build_dir,
        clean_build: clean_build,
      )
    end

    private def merge_env(base : Hash(String, String), extra : Hash(String, String)?) : Hash(String, String)
      return base unless extra
      merged = base.dup
      extra.each { |key, value| merged[key] = value }
      merged
    end

    # Ensure the plan format versions match before diffing.
    private def self.ensure_format_version(base_plan : BuildPlan, target_plan : BuildPlan)
      return if base_plan.format_version == target_plan.format_version
      raise "Build plan format version mismatch (base #{base_plan.format_version}, target #{target_plan.format_version})"
    end

    # Index plan phases by name for fast lookup.
    private def self.index_phases(plan : BuildPlan) : Hash(String, BuildPhase)
      plan.phases.to_h { |phase| {phase.name, phase} }
    end

    # Ensure the base/target plan phase sets are identical.
    private def self.ensure_phase_sets_match(base_phases : Hash(String, BuildPhase), target_phases : Hash(String, BuildPhase))
      missing = target_phases.keys.reject { |name| base_phases.has_key?(name) }
      raise "Target plan introduces new phase(s): #{missing.join(", ")}" unless missing.empty?
      removed = base_phases.keys.reject { |name| target_phases.has_key?(name) }
      raise "Target plan removes phase(s): #{removed.join(", ")}" unless removed.empty?
    end

    # Compute overrides for a single phase, returning nil if no changes exist.
    private def self.diff_phase(base_phase : BuildPhase, target_phase : BuildPhase) : PhaseOverride?
      install_prefix = base_phase.install_prefix == target_phase.install_prefix ? nil : target_phase.install_prefix
      destdir = diff_nullable_path("phase #{base_phase.name} destdir", base_phase.destdir, target_phase.destdir)
      env = diff_env("phase #{base_phase.name} env", base_phase.env, target_phase.env)
      packages = diff_phase_packages(base_phase, target_phase)
      steps = diff_phase_steps(base_phase, target_phase)
      return nil if install_prefix.nil? && destdir.nil? && env.nil? && packages.nil? && steps.nil?

      PhaseOverride.new(
        install_prefix: install_prefix,
        destdir: destdir,
        env: env,
        packages: packages,
        steps: steps,
      )
    end

    # Compute step overrides for a phase, or nil if none are needed.
    private def self.diff_phase_steps(base_phase : BuildPhase, target_phase : BuildPhase) : Hash(String, StepOverride)?
      base_steps = index_steps(base_phase)
      overrides = {} of String => StepOverride
      target_phase.steps.each do |target_step|
        base_step = base_steps[target_step.name]? || raise "Target plan introduces new step #{target_step.name} in phase #{target_phase.name}"
        override = diff_step(base_phase.name, base_step, target_step)
        overrides[target_step.name] = override if override
      end
      return nil if overrides.empty?
      overrides
    end

    # Compute a phase packages allowlist if steps were removed.
    private def self.diff_phase_packages(base_phase : BuildPhase, target_phase : BuildPhase) : Array(String)?
      base_steps = base_phase.steps.map(&.name)
      target_steps = target_phase.steps.map(&.name)
      return nil if base_steps == target_steps

      base_indexed = base_steps.to_set
      missing = target_steps.reject { |name| base_indexed.includes?(name) }
      raise "Target plan introduces new step(s) in phase #{base_phase.name}: #{missing.join(", ")}" unless missing.empty?

      base_ordered_target = base_steps.select { |name| target_steps.includes?(name) }
      if base_ordered_target != target_steps
        raise "Target plan reorders steps in phase #{base_phase.name}; overrides cannot reorder steps"
      end
      target_steps
    end

    # Index phase steps by name for fast lookup.
    private def self.index_steps(phase : BuildPhase) : Hash(String, BuildStep)
      phase.steps.to_h { |step| {step.name, step} }
    end

    # Compute overrides for a single step, returning nil if no changes exist.
    private def self.diff_step(phase_name : String, base_step : BuildStep, target_step : BuildStep) : StepOverride?
      workdir = base_step.workdir == target_step.workdir ? nil : target_step.workdir
      build_dir = diff_nullable_path("phase #{phase_name} step #{base_step.name} build_dir", base_step.build_dir, target_step.build_dir)
      install_prefix = diff_nullable_path("phase #{phase_name} step #{base_step.name} install_prefix", base_step.install_prefix, target_step.install_prefix)
      destdir = diff_nullable_path("phase #{phase_name} step #{base_step.name} destdir", base_step.destdir, target_step.destdir)
      env = diff_env("phase #{phase_name} step #{base_step.name} env", base_step.env, target_step.env)
      clean_build = base_step.clean_build == target_step.clean_build ? nil : target_step.clean_build
      configure_flags_add = diff_appended_list("phase #{phase_name} step #{base_step.name} configure_flags", base_step.configure_flags, target_step.configure_flags)
      patches_add = diff_appended_list("phase #{phase_name} step #{base_step.name} patches", base_step.patches, target_step.patches)
      return nil if workdir.nil? && build_dir.nil? && install_prefix.nil? && destdir.nil? && env.nil? && clean_build.nil? && configure_flags_add.empty? && patches_add.empty?

      StepOverride.new(
        workdir: workdir,
        build_dir: build_dir,
        install_prefix: install_prefix,
        destdir: destdir,
        env: env,
        clean_build: clean_build,
        configure_flags_add: configure_flags_add,
        patches_add: patches_add,
      )
    end

    # Compute changes for append-only lists, raising if removal/reordering occurs.
    private def self.diff_appended_list(context : String, base : Array(String), target : Array(String)) : Array(String)
      if target.size < base.size
        raise "Target plan removes entries from #{context}"
      end
      if target[0, base.size] != base
        raise "Target plan reorders or edits existing entries in #{context}"
      end
      target[base.size..] || [] of String
    end

    # Compute env additions/changes, raising if keys are removed.
    private def self.diff_env(context : String, base : Hash(String, String), target : Hash(String, String)) : Hash(String, String)?
      removed = base.keys.reject { |key| target.has_key?(key) }
      raise "Target plan removes env keys from #{context}: #{removed.join(", ")}" unless removed.empty?
      diff = {} of String => String
      target.each do |key, value|
        diff[key] = value if base[key]? != value
      end
      return nil if diff.empty?
      diff
    end

    # Return override value for nullable paths, raising if a value is removed.
    private def self.diff_nullable_path(context : String, base : String?, target : String?) : String?
      return nil if base == target
      raise "Target plan clears #{context}, which overrides cannot remove" if base && target.nil?
      target
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

    getter workdir : String?
    getter build_dir : String?
    getter install_prefix : String?
    getter destdir : String?
    getter env : Hash(String, String)?
    getter clean_build : Bool?
    # Replace configure flags entirely for a step.
    getter configure_flags : Array(String)?
    # Replace patches entirely for a step.
    getter patches : Array(String)?
    # Append configure flags to the existing (or replaced) list.
    getter configure_flags_add : Array(String) = [] of String
    # Append patches to the existing (or replaced) list.
    getter patches_add : Array(String) = [] of String

    def initialize(@workdir : String? = nil,
                   @build_dir : String? = nil,
                   @install_prefix : String? = nil,
                   @destdir : String? = nil,
                   @env : Hash(String, String)? = nil,
                   @clean_build : Bool? = nil,
                   @configure_flags : Array(String)? = nil,
                   @patches : Array(String)? = nil,
                   @configure_flags_add : Array(String) = [] of String,
                   @patches_add : Array(String) = [] of String)
    end
  end
end
