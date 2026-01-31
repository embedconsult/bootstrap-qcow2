require "./spec_helper"
require "../src/sysroot_build_state"

describe Bootstrap::SysrootBuildState do
  it "round-trips JSON and preserves completed step markers" do
    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.from_host_workdir(dir)
      state = Bootstrap::SysrootBuildState.new(workspace: workspace, plan_path: "/var/lib/sysroot-build-plan.json")
      state.mark_success("phase-a", "musl")
      encoded = state.to_json
      decoded = Bootstrap::SysrootBuildState.from_json(encoded)
      decoded.completed?("phase-a", "musl").should be_true
      decoded.completed?("phase-a", "busybox").should be_false
    end
  end

  it "loads or initializes state and updates metadata" do
    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.from_host_workdir(dir)
      state = Bootstrap::SysrootBuildState.load_or_init(workspace)
      state.plan_path.should eq Bootstrap::SysrootBuildState::DEFAULT_PLAN
      state.overrides_path.should eq Bootstrap::SysrootBuildState::DEFAULT_OVERRIDES
      state.report_dir.should eq Bootstrap::SysrootBuildState::DEFAULT_REPORTS
      state.save
      loaded = Bootstrap::SysrootBuildState.load(workspace)
      loaded.plan_path.should eq Bootstrap::SysrootBuildState::DEFAULT_PLAN
    end
  ensure
    # tempdir cleanup handled by helper
  end

  it "clears completed steps when overrides content changes" do
    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.from_host_workdir(dir)
      plan_path = workspace.var_lib_dir / Bootstrap::SysrootBuildState::PLAN_FILE
      overrides_path = workspace.var_lib_dir / Bootstrap::SysrootBuildState::OVERRIDES_FILE
      state_path = workspace.var_lib_dir / Bootstrap::SysrootBuildState::STATE_FILE

      FileUtils.mkdir_p(plan_path.parent)
      File.write(plan_path, "[]")
      File.write(overrides_path, %({"phases":{}}))

      state = Bootstrap::SysrootBuildState.load_or_init(workspace, state_path, overrides_path: overrides_path)
      state.mark_success("phase-a", "musl")
      state.save(state_path)

      File.write(overrides_path, %({"phases":{"phase-a":{"steps":{}}}}))

      reloaded = Bootstrap::SysrootBuildState.load_or_init(workspace, state_path, overrides_path: overrides_path)
      reloaded.completed?("phase-a", "musl").should be_false
      reloaded.invalidated_at.should_not be_nil
      reloaded.invalidation_reason.should_not be_nil
    end
  end
end
