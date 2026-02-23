require "./spec_helper"
require "../src/build_plan_overrides"

describe Bootstrap::BuildPlanOverrides do
  it "preserves step order when applying package allowlist" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        namespace: "test",
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
        namespace: "test",
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
          namespace: "updated",
          install_prefix: "/usr",
          env: {"CC" => "clang"} of String => String,
          steps: {
            "pkg" => Bootstrap::StepOverride.new(workdir: "/w/pkg", build_dir: "/w/pkg-build", clean_build: true, configure_flags_add: ["--with-foo"]),
          },
        ),
      },
    )

    updated = overrides.apply(plan)
    updated.phases.first.namespace.should eq "updated"
    updated.phases.first.install_prefix.should eq "/usr"
    updated.phases.first.env["PATH"].should eq "/bin"
    updated.phases.first.env["CC"].should eq "clang"
    updated.phases.first.steps.first.workdir.should eq "/w/pkg"
    updated.phases.first.steps.first.build_dir.should eq "/w/pkg-build"
    updated.phases.first.steps.first.clean_build.should eq true
    updated.phases.first.steps.first.configure_flags.should eq ["--with-foo"]
  end

  it "clears phase destdir when overrides request removal" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        namespace: "test",
        install_prefix: "/opt/sysroot",
        destdir: "/bq2-rootfs",
      ),
    ])

    overrides = Bootstrap::BuildPlanOverrides.new(
      phases: {
        "one" => Bootstrap::PhaseOverride.new(destdir_clear: true),
      },
    )

    updated = overrides.apply(plan)
    updated.phases.first.destdir.should be_nil
  end

  it "replaces configure flags when overrides provide a full list" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        namespace: "test",
        install_prefix: "/opt/sysroot",
        steps: [
          Bootstrap::BuildStep.new(
            name: "pkg",
            strategy: "autotools",
            workdir: "/tmp",
            configure_flags: ["--one", "--two"],
            patches: [] of String,
          ),
        ],
      ),
    ])

    overrides = Bootstrap::BuildPlanOverrides.new(
      phases: {
        "one" => Bootstrap::PhaseOverride.new(
          steps: {
            "pkg" => Bootstrap::StepOverride.new(configure_flags: ["--two", "--three"]),
          },
        ),
      },
    )

    updated = overrides.apply(plan)
    updated.phases.first.steps.first.configure_flags.should eq ["--two", "--three"]
  end

  it "builds overrides that replace configure flags when the plan changes" do
    base = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        namespace: "test",
        install_prefix: "/opt/sysroot",
        steps: [
          Bootstrap::BuildStep.new(
            name: "pkg",
            strategy: "autotools",
            workdir: "/tmp",
            configure_flags: ["--one", "--two"],
            patches: [] of String,
          ),
        ],
      ),
    ])

    target = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        namespace: "test",
        install_prefix: "/opt/sysroot",
        steps: [
          Bootstrap::BuildStep.new(
            name: "pkg",
            strategy: "autotools",
            workdir: "/tmp",
            configure_flags: ["--two", "--three"],
            patches: [] of String,
          ),
        ],
      ),
    ])

    overrides = Bootstrap::BuildPlanOverrides.from_diff(base, target)
    updated = overrides.apply(base)
    updated.phases.first.steps.first.configure_flags.should eq ["--two", "--three"]
  end

  it "builds overrides that clear destdir when the plan changes" do
    base = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        namespace: "test",
        install_prefix: "/opt/sysroot",
        destdir: "/bq2-rootfs",
      ),
    ])

    target = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        namespace: "test",
        install_prefix: "/opt/sysroot",
      ),
    ])

    overrides = Bootstrap::BuildPlanOverrides.from_diff(base, target)
    overrides.phases["one"].destdir_clear.should be_true
    updated = overrides.apply(base)
    updated.phases.first.destdir.should be_nil
  end

  it "builds overrides that replace namespace when the plan changes" do
    base = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        namespace: "seed",
        install_prefix: "/opt/sysroot",
      ),
    ])

    target = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        namespace: "bq2",
        install_prefix: "/opt/sysroot",
      ),
    ])

    overrides = Bootstrap::BuildPlanOverrides.from_diff(base, target)
    overrides.phases["one"].namespace.should eq "bq2"
    updated = overrides.apply(base)
    updated.phases.first.namespace.should eq "bq2"
  end

  it "builds overrides that replace step content when the plan changes" do
    base = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        namespace: "test",
        install_prefix: "/opt/sysroot",
        steps: [
          Bootstrap::BuildStep.new(
            name: "file",
            strategy: "write-file",
            workdir: "/tmp",
            configure_flags: [] of String,
            patches: [] of String,
            content: "alpha",
          ),
        ],
      ),
    ])

    target = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        namespace: "test",
        install_prefix: "/opt/sysroot",
        steps: [
          Bootstrap::BuildStep.new(
            name: "file",
            strategy: "write-file",
            workdir: "/tmp",
            configure_flags: [] of String,
            patches: [] of String,
            content: "beta",
          ),
        ],
      ),
    ])

    overrides = Bootstrap::BuildPlanOverrides.from_diff(base, target)
    updated = overrides.apply(base)
    updated.phases.first.steps.first.content.should eq "beta"
  end

  it "appends extra steps from overrides" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        namespace: "test",
        install_prefix: "/opt/sysroot",
        steps: [
          Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/a", configure_flags: [] of String, patches: [] of String),
        ],
      ),
    ])

    overrides = Bootstrap::BuildPlanOverrides.new(
      phases: {
        "one" => Bootstrap::PhaseOverride.new(
          extra_steps: [
            Bootstrap::BuildStep.new(name: "b", strategy: "noop", workdir: "/b", configure_flags: [] of String, patches: [] of String),
          ],
        ),
      },
    )

    updated = overrides.apply(plan)
    updated.phases.first.steps.map(&.name).should eq ["a", "b"]
  end

  it "builds overrides that append new steps when the plan changes" do
    base = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        namespace: "test",
        install_prefix: "/opt/sysroot",
        steps: [
          Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/a", configure_flags: [] of String, patches: [] of String),
        ],
      ),
    ])

    target = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "phase",
        namespace: "test",
        install_prefix: "/opt/sysroot",
        steps: [
          Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/a", configure_flags: [] of String, patches: [] of String),
          Bootstrap::BuildStep.new(name: "b", strategy: "noop", workdir: "/b", configure_flags: [] of String, patches: [] of String),
        ],
      ),
    ])

    overrides = Bootstrap::BuildPlanOverrides.from_diff(base, target)
    updated = overrides.apply(base)
    updated.phases.first.steps.map(&.name).should eq ["a", "b"]
  end

  it "raises when overrides reference an unknown phase" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "phase", namespace: "test", install_prefix: "/opt/sysroot"),
    ])

    overrides = Bootstrap::BuildPlanOverrides.new(
      phases: {"missing" => Bootstrap::PhaseOverride.new} of String => Bootstrap::PhaseOverride,
    )

    expect_raises(Exception, /Unknown build phases/) do
      overrides.apply(plan)
    end
  end
end
