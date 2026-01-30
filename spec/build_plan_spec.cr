require "./spec_helper"
require "../src/build_plan"

describe Bootstrap::BuildPlan do
  it "rejects the legacy unphased plan format" do
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

    expect_raises(Exception, /Legacy build plan format is not supported/) do
      Bootstrap::BuildPlan.parse(json)
    end
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

    parsed = Bootstrap::BuildPlan.parse(plan.to_json)
    parsed.format_version.should eq 1
    parsed.phases.size.should eq 1
    parsed.phases.first.name.should eq "phase-a"
    parsed.phases.first.steps.first.name.should eq "m4"
  end
end
