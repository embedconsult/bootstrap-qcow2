require "./spec_helper"
require "../src/build_plan_utils"

describe Bootstrap::BuildPlanUtils do
  it "rewrites phase workspaces, step workdirs, and destdir roots" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        workspace: "/workspace",
        environment: "test",
        install_prefix: "/opt/sysroot",
        destdir: "/workspace/rootfs",
        steps: [
          Bootstrap::BuildStep.new(
            name: "m4",
            strategy: "autotools",
            workdir: "/workspace/m4-1.4.19",
            configure_flags: [] of String,
            patches: [] of String,
          ),
        ],
      ),
    ])

    rewritten = Bootstrap::BuildPlanUtils.rewrite_workspace_root(plan, "/work/ws")
    rewritten.phases.first.workspace.should eq "/work/ws"
    rewritten.phases.first.destdir.should eq "/work/ws/rootfs"
    rewritten.phases.first.steps.first.workdir.should eq "/work/ws/m4-1.4.19"
  end
end
