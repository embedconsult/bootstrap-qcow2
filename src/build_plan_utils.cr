require "./build_plan"
require "./sysroot_workspace"

module Bootstrap
  # Helpers for adjusting serialized build plans without regenerating the
  # underlying rootfs.
  module BuildPlanUtils
    DEFAULT_WORKSPACE_ROOT = SysrootWorkspace::ROOTFS_WORKSPACE.to_s

    # Returns a copy of *plan* with its workspace-root rewritten.
    #
    # This updates the phase workspace, phase destdir (when present), and each
    # step workdir (plus any step-level install prefix/destdir fields) when they
    # are rooted at `from_root`.
    def self.rewrite_workspace_root(plan : BuildPlan, to_root : String, from_root : String = DEFAULT_WORKSPACE_ROOT) : BuildPlan
      phases = plan.phases.map do |phase|
        steps = phase.steps.map do |step|
          BuildStep.new(
            name: step.name,
            strategy: step.strategy,
            workdir: rewrite_root(step.workdir, from_root, to_root),
            configure_flags: step.configure_flags,
            patches: step.patches,
            install_prefix: step.install_prefix,
            destdir: step.destdir ? rewrite_root(step.destdir.not_nil!, from_root, to_root) : nil,
            env: step.env,
            build_dir: step.build_dir ? rewrite_root(step.build_dir.not_nil!, from_root, to_root) : nil,
            clean_build: step.clean_build,
          )
        end

        BuildPhase.new(
          name: phase.name,
          description: phase.description,
          workspace: rewrite_root(phase.workspace, from_root, to_root),
          environment: phase.environment,
          install_prefix: phase.install_prefix,
          destdir: phase.destdir ? rewrite_root(phase.destdir.not_nil!, from_root, to_root) : nil,
          env: phase.env,
          steps: steps,
        )
      end

      BuildPlan.new(phases: phases, format_version: plan.format_version)
    end

    private def self.rewrite_root(value : String, from_root : String, to_root : String) : String
      return value unless value == from_root || value.starts_with?("#{from_root}/")
      return to_root if value == from_root
      suffix = value[from_root.size..]
      "#{to_root}#{suffix}"
    end
  end
end
