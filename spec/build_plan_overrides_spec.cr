require "./spec_helper"
require "../src/build_plan_overrides"

describe Bootstrap::BuildPlanOverrides do
  it "preserves step order when applying package allowlist" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        workspace: "/workspace",
        environment: "test",
        install_prefix: "/opt/sysroot",
        steps: [
          Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/a", configure_flags: [] of String, patches: [] of String),
          Bootstrap::BuildStep.new(name: "b", strategy: "autotools", workdir: "/b", configure_flags: [] of String, patches: [] of String),
          Bootstrap::BuildStep.new(name: "c", strategy: "autotools", workdir: "/c", configure_flags: [] of String, patches: [] of String),
        ],
      ),
    ])

    overrides = Bootstrap::BuildPlanOverrides.new(
      phases: {
        "one" => Bootstrap::PhaseOverride.new(packages: ["c", "a"]),
      },
    )

    updated = overrides.apply(plan)
    updated.phases.first.steps.map(&.name).should eq ["a", "c"]
  end

  it "applies phase and step overrides" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        workspace: "/workspace",
        environment: "test",
        install_prefix: "/opt/sysroot",
        env: {"PATH" => "/bin"} of String => String,
        steps: [
          Bootstrap::BuildStep.new(name: "pkg", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String),
        ],
      ),
    ])

    overrides = Bootstrap::BuildPlanOverrides.new(
      phases: {
        "one" => Bootstrap::PhaseOverride.new(
          install_prefix: "/usr",
          env: {"CC" => "clang"} of String => String,
          steps: {
            "pkg" => Bootstrap::StepOverride.new(configure_flags_add: ["--with-foo"]),
          },
        ),
      },
    )

    updated = overrides.apply(plan)
    updated.phases.first.install_prefix.should eq "/usr"
    updated.phases.first.env["PATH"].should eq "/bin"
    updated.phases.first.env["CC"].should eq "clang"
    updated.phases.first.steps.first.configure_flags.should eq ["--with-foo"]
  end

  it "raises when overrides reference an unknown phase" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "phase", workspace: "/workspace", environment: "test", install_prefix: "/opt/sysroot"),
    ])

    overrides = Bootstrap::BuildPlanOverrides.new(
      phases: {"missing" => Bootstrap::PhaseOverride.new} of String => Bootstrap::PhaseOverride,
    )

    expect_raises(Exception, /Unknown build phases/) do
      overrides.apply(plan)
    end
  end
end
