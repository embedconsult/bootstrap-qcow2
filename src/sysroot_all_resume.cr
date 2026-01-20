require "./build_plan"
require "./sysroot_build_state"
require "./sysroot_builder"

module Bootstrap
  # Determines the earliest resume stage for `bq2 --all --resume`.
  class SysrootAllResume
    # Ordered stage list for the --all workflow.
    STAGE_ORDER = [
      "download-sources",
      "plan-write",
      "sysroot-runner",
      "rootfs-tarball",
    ]

    # Result describing the stage to resume and its supporting details.
    struct Decision
      getter stage : String
      getter reason : String
      getter resume_phase : String?
      getter resume_step : String?
      getter plan_path : Path?
      getter state_path : Path?

      # Create a new resume decision.
      def initialize(@stage : String,
                     @reason : String,
                     @resume_phase : String? = nil,
                     @resume_step : String? = nil,
                     @plan_path : Path? = nil,
                     @state_path : Path? = nil)
      end

      # Return a log message summarizing the decision.
      def log_message : String
        message = "Resume decision:\n stage=#{stage} (#{reason})"
        if resume_phase
          message = "#{message}\n phase=#{resume_phase}"
        end
        if resume_step
          message = "#{message}\n step=#{resume_step}"
        end
        if state_path
          message = "#{message}\n state=#{state_path}"
        end
        if plan_path
          message = "#{message}\n plan=#{plan_path}"
        end
        message
      end
    end

    getter builder : SysrootBuilder
    getter plan_path : Path
    getter state_path : Path
    getter rootfs_tarball_path : Path
    getter output_tarball_path : Path

    # Create a resume inspector for the provided *builder* and workspace paths.
    def initialize(@builder : SysrootBuilder,
                   @plan_path : Path = builder.plan_path,
                   @state_path : Path = builder.rootfs_dir / "var/lib/sysroot-build-state.json",
                   @rootfs_tarball_path : Path = builder.rootfs_dir / "workspace" / "bq-rootfs.tar.gz",
                   @output_tarball_path : Path = builder.sources_dir / "bq2-rootfs-#{Bootstrap::VERSION}.tar.gz")
    end

    # Determine the earliest incomplete stage for `--all --resume`.
    def decide : Decision
      missing_sources = builder.missing_source_archives
      unless missing_sources.empty?
        reason = "missing #{missing_sources.size} cached source archive(s)"
        return Decision.new("download-sources", reason)
      end

      plan_exists = File.exists?(plan_path)
      state_exists = File.exists?(state_path)
      if state_exists && !plan_exists
        raise "Ambiguous resume state: state exists at #{state_path} but plan is missing at #{plan_path}"
      end

      unless plan_exists
        return Decision.new("plan-write", "missing build plan at #{plan_path}")
      end

      plan = BuildPlan.from_json(File.read(plan_path))
      if state_exists
        state = SysrootBuildState.load(state_path.to_s)
        plan_digest = SysrootBuildState.digest_for?(plan_path.to_s)
        if plan_digest.nil? || state.plan_digest != plan_digest
          raise "Ambiguous resume state: plan digest mismatch between #{plan_path} and #{state_path}"
        end

        next_phase, next_step = next_incomplete_step(plan, state)
        if next_phase.nil?
          return Decision.new("rootfs-tarball", "build complete but rootfs tarball is missing", plan_path: plan_path, state_path: state_path) unless tarball_present?
          return Decision.new("complete", "build complete and rootfs tarball present", plan_path: plan_path, state_path: state_path)
        end

        resume_phase = next_phase
        reason = "state present and plan digest matches"
        return Decision.new("sysroot-runner", reason, resume_phase: resume_phase, resume_step: next_step, plan_path: plan_path, state_path: state_path)
      end

      Decision.new("sysroot-runner", "plan present but state is missing", plan_path: plan_path)
    end

    # Return true when the cached rootfs tarball exists in the sources directory.
    def tarball_present? : Bool
      File.exists?(output_tarball_path)
    end

    # Find the next incomplete step in the build plan for the given *state*.
    def next_incomplete_step(plan : BuildPlan, state : SysrootBuildState) : Tuple(String?, String?)
      plan.phases.each do |phase|
        phase.steps.each do |step|
          next if state.completed?(phase.name, step.name)
          return {phase.name, step.name}
        end
      end
      {nil, nil}
    end
  end
end
