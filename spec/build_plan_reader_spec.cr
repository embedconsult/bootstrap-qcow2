require "./spec_helper"
require "../src/build_plan_reader"

describe Bootstrap::BuildPlanReader do
  it "parses the legacy unphased plan format" do
    json = <<-JSON
    [
      {
        "name": "musl",
        "strategy": "autotools",
        "workdir": "/workspace/musl-1.2.5",
        "configure_flags": ["--disable-shared"],
        "patches": [],
        "sysroot_prefix": "/opt/sysroot"
      },
      {
        "name": "busybox",
        "strategy": "busybox",
        "workdir": "/workspace/busybox-1_36_1",
        "configure_flags": [],
        "patches": ["patches/busybox.patch"],
        "sysroot_prefix": "/opt/sysroot"
      }
    ]
    JSON

    plan = Bootstrap::BuildPlanReader.parse(json)
    plan.format_version.should eq 0
    plan.phases.size.should eq 1
    plan.phases.first.name.should eq "sysroot-from-alpine"
    plan.phases.first.install_prefix.should eq "/opt/sysroot"
    plan.phases.first.steps.map(&.name).should eq ["musl", "busybox"]
    plan.phases.first.steps.first.configure_flags.should eq ["--disable-shared"]
    plan.phases.first.steps.last.patches.should eq ["patches/busybox.patch"]
  end

  it "parses the phased plan format" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "phase-a",
        description: "phase a",
        workspace: "/workspace",
        environment: "test",
        install_prefix: "/opt/sysroot",
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

    parsed = Bootstrap::BuildPlanReader.parse(plan.to_json)
    parsed.format_version.should eq 1
    parsed.phases.size.should eq 1
    parsed.phases.first.name.should eq "phase-a"
    parsed.phases.first.steps.first.name.should eq "m4"
  end
end
