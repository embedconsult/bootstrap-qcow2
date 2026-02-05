require "./spec_helper"
require "../src/sysroot_build_state"

describe Bootstrap::SysrootBuildState do
  it "round-trips JSON and preserves completed step markers" do
    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.create(dir)
      state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      state.mark_success("phase-a", "musl")
      encoded = state.to_json
      decoded = Bootstrap::SysrootBuildState.from_json(encoded)
      decoded.completed?("phase-a", "musl").should be_true
      decoded.completed?("phase-a", "busybox").should be_false
    end
  end

  it "invalidates completed steps when the plan digest changes" do
    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.create(dir)
      state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      FileUtils.mkdir_p(state.plan_path.parent)
      File.write(state.plan_path, "plan-a")
      state.plan_digest = Bootstrap::SysrootBuildState.digest_for?(state.plan_path)
      state.mark_success("phase-a", "musl")

      File.write(state.plan_path, "plan-b")
      reloaded = Bootstrap::SysrootBuildState.new(workspace: workspace)
      reloaded.completed?("phase-a", "musl").should be_false
      reloaded.invalidated_at.should_not be_nil
      reloaded.invalidation_reason.should_not be_nil
    end
  end
end
