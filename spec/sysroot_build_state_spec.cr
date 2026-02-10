require "./spec_helper"
require "../src/sysroot_build_state"

describe Bootstrap::SysrootBuildState do
  it "round-trips JSON and preserves completed step markers" do
    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.new(host_workdir: dir)
      state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      state.mark_success("phase-a", "musl")
      encoded = state.to_json
      decoded = Bootstrap::SysrootBuildState.from_json(encoded)
      decoded.completed?("phase-a", "musl").should be_true
      decoded.completed?("phase-a", "busybox").should be_false
    end
  end

  it "exposes plan, overrides, and report paths under the workspace log path" do
    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.new(host_workdir: dir)
      state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      state.plan_path.should eq workspace.log_path / Bootstrap::SysrootBuildState::PLAN_FILE
      state.overrides_path.should eq workspace.log_path / Bootstrap::SysrootBuildState::OVERRIDES_FILE
      state.report_dir.should eq workspace.log_path / Bootstrap::SysrootBuildState::REPORT_DIR_NAME
      state.state_path.should eq workspace.log_path / Bootstrap::SysrootBuildState::STATE_FILE
    end
  end

  it "restores completed steps from a persisted state file" do
    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.new(host_workdir: dir)
      state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      state.mark_success("phase-a", "musl")
      state.save

      reloaded = Bootstrap::SysrootBuildState.new(workspace: workspace)
      reloaded.completed?("phase-a", "musl").should be_true
      reloaded.invalidated_at.should be_nil
      reloaded.invalidation_reason.should be_nil
    end
  end

  it "records failure metadata for the most recent failed step" do
    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.new(host_workdir: dir)
      state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      state.mark_failure("phase-b", "busybox", "compile failed", "/tmp/report.json")

      failure = state.progress.last_failure
      failure.should_not be_nil
      failure.not_nil!.phase.should eq "phase-b"
      failure.not_nil!.step.should eq "busybox"
      failure.not_nil!.error.should eq "compile failed"
      failure.not_nil!.report_path.should eq "/tmp/report.json"
    end
  end
end
