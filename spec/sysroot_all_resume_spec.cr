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

private def populate_sources(builder : Bootstrap::SysrootBuilder) : Nil
  builder.expected_source_archives.each do |path|
    FileUtils.mkdir_p(path.parent)
    File.write(path, "x")
  end
end

private def write_state(path : Path, plan_path : Path, plan : Bootstrap::BuildPlan, completed_steps : Array(Tuple(String, String))) : Bootstrap::SysrootBuildState
  state = Bootstrap::SysrootBuildState.new(plan_path: plan_path.to_s, overrides_path: nil, report_dir: nil)
  completed_steps.each do |(phase, step)|
    state.mark_success(phase, step)
  end
  state.plan_digest = Bootstrap::SysrootBuildState.digest_for?(plan_path.to_s)
  FileUtils.mkdir_p(path.parent)
  state.save(path.to_s)
  state
end

describe Bootstrap::SysrootAllResume do
  it "selects download-sources when the source cache is missing" do
    with_tempdir do |dir|
      builder = Bootstrap::SysrootBuilder.new(host_workdir: dir)
      decision = Bootstrap::SysrootAllResume.new(builder).decide
      decision.stage.should eq("download-sources")
    end
  end

  it "starts sysroot-runner when plan exists but state is missing" do
    with_tempdir do |dir|
      builder = Bootstrap::SysrootBuilder.new(host_workdir: dir)
      populate_sources(builder)
      plan_path = builder.plan_path
      write_plan(plan_path)

      decision = Bootstrap::SysrootAllResume.new(builder).decide
      decision.stage.should eq("sysroot-runner")
      decision.reason.should contain("state is missing")
    end
  end

  it "resumes sysroot-runner when state matches the plan" do
    with_tempdir do |dir|
      builder = Bootstrap::SysrootBuilder.new(host_workdir: dir)
      populate_sources(builder)
      plan_path = builder.plan_path
      plan = write_plan(plan_path)
      state_path = builder.inner_rootfs_var_lib_dir / "sysroot-build-state.json"
      write_state(state_path, plan_path, plan, [{"phase-a", "step-a"}])

      decision = Bootstrap::SysrootAllResume.new(builder).decide
      decision.stage.should eq("sysroot-runner")
      decision.resume_phase.should eq("phase-b")
      decision.resume_step.should eq("step-b")
    end
  end

  it "selects rootfs-tarball when the plan is complete but tarball is missing" do
    with_tempdir do |dir|
      builder = Bootstrap::SysrootBuilder.new(host_workdir: dir)
      populate_sources(builder)
      plan_path = builder.plan_path
      plan = write_plan(plan_path)
      state_path = builder.inner_rootfs_var_lib_dir / "sysroot-build-state.json"
      write_state(state_path, plan_path, plan, [{"phase-a", "step-a"}, {"phase-b", "step-b"}])

      decision = Bootstrap::SysrootAllResume.new(builder).decide
      decision.stage.should eq("rootfs-tarball")
    end
  end

  it "ignores state when the plan digest does not match" do
    with_tempdir do |dir|
      builder = Bootstrap::SysrootBuilder.new(host_workdir: dir)
      populate_sources(builder)
      plan_path = builder.plan_path
      plan = write_plan(plan_path)
      state_path = builder.inner_rootfs_var_lib_dir / "sysroot-build-state.json"
      state = write_state(state_path, plan_path, plan, [{"phase-a", "step-a"}])
      state.plan_digest = "deadbeef"
      state.save(state_path.to_s)

      decision = Bootstrap::SysrootAllResume.new(builder).decide
      decision.stage.should eq("sysroot-runner")
      decision.state_path.should be_nil
      decision.plan_path.should eq(plan_path)
    end
  end

  it "refuses to resume when state exists without a plan" do
    with_tempdir do |dir|
      builder = Bootstrap::SysrootBuilder.new(host_workdir: dir)
      populate_sources(builder)
      state_path = builder.inner_rootfs_var_lib_dir / "sysroot-build-state.json"
      write_state(state_path, builder.plan_path, Bootstrap::BuildPlan.new([] of Bootstrap::BuildPhase), [] of Tuple(String, String))
      File.delete(builder.plan_path) if File.exists?(builder.plan_path)

      expect_raises(Exception, /plan is missing/) do
        Bootstrap::SysrootAllResume.new(builder).decide
      end
    end
  end
end
