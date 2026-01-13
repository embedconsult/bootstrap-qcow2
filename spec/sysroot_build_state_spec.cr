require "./spec_helper"
require "../src/sysroot_build_state"

describe Bootstrap::SysrootBuildState do
  it "round-trips JSON and preserves completed step markers" do
    state = Bootstrap::SysrootBuildState.new(plan_path: "/var/lib/sysroot-build-plan.json")
    state.mark_success("phase-a", "musl")
    encoded = state.to_json
    decoded = Bootstrap::SysrootBuildState.from_json(encoded)
    decoded.completed?("phase-a", "musl").should be_true
    decoded.completed?("phase-a", "busybox").should be_false
  end

  it "loads or initializes state and updates metadata" do
    tempfile : String? = nil
    tempfile = File.tempname("bq2-state").not_nil!
    File.delete?(tempfile)
    state = Bootstrap::SysrootBuildState.load_or_init(tempfile, plan_path: "/p", overrides_path: "/o", report_dir: "/r")
    state.plan_path.should eq "/p"
    state.overrides_path.should eq "/o"
    state.report_dir.should eq "/r"
    state.save(tempfile)
    loaded = Bootstrap::SysrootBuildState.load(tempfile)
    loaded.plan_path.should eq "/p"
  ensure
    File.delete?(tempfile) if tempfile
  end
end
