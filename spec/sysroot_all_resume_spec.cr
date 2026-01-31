require "./spec_helper"
require "../src/sysroot_all_resume"

private def write_plan(path : Path) : Bootstrap::BuildPlan
  phases = [
    Bootstrap::BuildPhase.new(
      "phase-a",
      "Phase A",
      "/workspace",
      "env",
      "/opt/sysroot",
      steps: [
        Bootstrap::BuildStep.new("step-a", "noop", "/workspace/phase-a", [] of String, [] of String),
      ],
    ),
    Bootstrap::BuildPhase.new(
      "phase-b",
      "Phase B",
      "/workspace",
      "env",
      "/opt/sysroot",
      steps: [
        Bootstrap::BuildStep.new("step-b", "noop", "/workspace/phase-b", [] of String, [] of String),
      ],
    ),
  ]
  plan = Bootstrap::BuildPlan.new(phases)
  FileUtils.mkdir_p(path.parent)
  File.write(path, plan.to_json)
  plan
end

private def write_state(path : Path,
                        workspace : Bootstrap::SysrootWorkspace,
                        plan_path : Path,
                        plan : Bootstrap::BuildPlan,
                        completed_steps : Array(Tuple(String, String))) : Bootstrap::SysrootBuildState
  state = Bootstrap::SysrootBuildState.new(workspace: workspace)
  state.plan_path = state.rootfs_plan_path
  state.overrides_path = nil
  state.report_dir = nil
  completed_steps.each do |(phase, step)|
    state.mark_success(phase, step)
  end
  state.plan_digest = Bootstrap::SysrootBuildState.digest_for?(plan_path.to_s)
  FileUtils.mkdir_p(path.parent)
  state.save(path)
  state
end

private def resume_for(workspace : Bootstrap::SysrootWorkspace) : Bootstrap::SysrootAllResume
  Bootstrap::SysrootAllResume.new(workspace)
end

private def with_temp_workdir(&block : Path ->)
  with_tempdir do |dir|
    Dir.cd(dir) do
      yield dir
    end
  end
end

describe Bootstrap::SysrootAllResume do
  it "starts plan-write when the build plan is missing" do
    with_temp_workdir do |_dir|
      workspace = Bootstrap::SysrootWorkspace.create(Bootstrap::SysrootBuilder::DEFAULT_HOST_WORKDIR)
      decision = resume_for(workspace).decide
      decision.stage.should eq("plan-write")
    end
  end

  it "starts sysroot-runner when plan exists but state is missing" do
    with_temp_workdir do |_dir|
      workspace = Bootstrap::SysrootWorkspace.create(Bootstrap::SysrootBuilder::DEFAULT_HOST_WORKDIR)
      build_state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      plan_path = build_state.plan_path_path
      write_plan(plan_path)

      decision = resume_for(workspace).decide
      decision.stage.should eq("sysroot-runner")
      decision.reason.should contain("state is missing")
    end
  end

  it "resumes sysroot-runner when state matches the plan" do
    with_temp_workdir do |_dir|
      workspace = Bootstrap::SysrootWorkspace.create(Bootstrap::SysrootBuilder::DEFAULT_HOST_WORKDIR)
      build_state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      plan_path = build_state.plan_path_path
      plan = write_plan(plan_path)
      state_path = build_state.state_path
      write_state(state_path, workspace, plan_path, plan, [{"phase-a", "step-a"}])

      decision = resume_for(workspace).decide
      decision.stage.should eq("sysroot-runner")
      decision.resume_phase.should eq("phase-b")
      decision.resume_step.should eq("step-b")
    end
  end

  it "reports completion when the plan is complete" do
    with_temp_workdir do |_dir|
      workspace = Bootstrap::SysrootWorkspace.create(Bootstrap::SysrootBuilder::DEFAULT_HOST_WORKDIR)
      build_state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      plan_path = build_state.plan_path_path
      plan = write_plan(plan_path)
      state_path = build_state.state_path
      write_state(state_path, workspace, plan_path, plan, [{"phase-a", "step-a"}, {"phase-b", "step-b"}])

      decision = resume_for(workspace).decide
      decision.stage.should eq("complete")
    end
  end

  it "ignores state when the plan digest does not match" do
    with_temp_workdir do |_dir|
      workspace = Bootstrap::SysrootWorkspace.create(Bootstrap::SysrootBuilder::DEFAULT_HOST_WORKDIR)
      build_state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      plan_path = build_state.plan_path_path
      plan = write_plan(plan_path)
      state_path = build_state.state_path
      state = write_state(state_path, workspace, plan_path, plan, [{"phase-a", "step-a"}])
      state.plan_digest = "deadbeef"
      state.save(state_path)

      decision = resume_for(workspace).decide
      decision.stage.should eq("sysroot-runner")
      decision.state_path.should be_nil
      decision.plan_path.should eq(plan_path)
    end
  end

  it "refuses to resume when state exists without a plan" do
    with_temp_workdir do |_dir|
      workspace = Bootstrap::SysrootWorkspace.create(Bootstrap::SysrootBuilder::DEFAULT_HOST_WORKDIR)
      build_state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      state_path = build_state.state_path
      plan_path = build_state.plan_path_path
      write_state(state_path, workspace, plan_path, Bootstrap::BuildPlan.new([] of Bootstrap::BuildPhase), [] of Tuple(String, String))
      File.delete(plan_path) if File.exists?(plan_path)

      expect_raises(Exception, /plan is missing/) do
        resume_for(workspace).decide
      end
    end
  end
end
