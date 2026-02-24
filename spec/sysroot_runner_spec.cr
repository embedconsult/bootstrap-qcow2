require "./spec_helper"
require "json"
require "file_utils"
require "random/secure"

describe Bootstrap::SysrootRunner do
  it "runs steps with a custom runner" do
    Log.debug { "This is the first test that fails" }
    phase = Bootstrap::BuildPhase.new(
      name: "phase-a",
      description: "test phase",
      namespace: "host",
      install_prefix: "/opt/sysroot",
      destdir: nil,
      env: {} of String => String,
      steps: [
        Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String),
        Bootstrap::BuildStep.new(name: "b", strategy: "cmake", workdir: "/var", configure_flags: [] of String, patches: [] of String),
      ]
    )

    with_recording_runner(plan: Bootstrap::BuildPlan.new([phase])) do |build_state, step_runner|
      plan_runner = Bootstrap::SysrootRunner.new(state: build_state, step_runner: step_runner)
      Log.debug { build_state.plan }
      plan_runner.run_plan

      step_runner.calls.size.should eq 2
      step_runner.calls.first[:workdir].should eq "/tmp"
      step_runner.calls.last[:strategy].should eq "cmake"
    end
  end

  it "raises when a command fails" do
    plan = Bootstrap::BuildPlan.new([Bootstrap::BuildPhase.new(
      name: "phase-fail",
      description: "test phase",
      namespace: "host",
      install_prefix: "/opt/sysroot",
      steps: [Bootstrap::BuildStep.new(name: "fail", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    )])

    with_recording_runner(plan: plan) do |build_state, step_runner|
      step_runner.status = false
      step_runner.exit_code = 2
      plan_runner = Bootstrap::SysrootRunner.new(state: build_state, step_runner: step_runner)
      expect_raises(Exception) do
        plan_runner.run_plan
      end
    end
  end

  it "loads a plan file and executes all phases by default" do
    phase_a_steps = [Bootstrap::BuildStep.new(name: "file-a", strategy: "autotools", workdir: "/opt", configure_flags: [] of String, patches: [] of String)]
    phase_b_steps = [Bootstrap::BuildStep.new(name: "file-b", strategy: "autotools", workdir: "/var", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "phase-a",
        description: "phase a",
        namespace: "host",
        install_prefix: "/opt/sysroot",
        steps: phase_a_steps,
      ),
      Bootstrap::BuildPhase.new(
        name: "phase-b",
        description: "phase b",
        namespace: "host",
        install_prefix: "/usr",
        destdir: "/tmp/rootfs",
        steps: phase_b_steps,
      ),
    ])

    with_recording_runner(plan: plan) do |build_state, step_runner|
      plan_runner = Bootstrap::SysrootRunner.new(state: build_state, step_runner: step_runner)
      plan_runner.run_plan

      step_runner.calls.size.should eq 2
      step_runner.calls.map(&.[:name]).should eq ["file-a", "file-b"]
    end
  end

  it "runs all phases when requested" do
    steps = [Bootstrap::BuildStep.new(name: "step", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", steps: steps),
      Bootstrap::BuildPhase.new(name: "two", description: "b", namespace: "host", install_prefix: "/usr", destdir: "/tmp/rootfs", steps: steps),
    ])

    with_recording_runner(plan: plan) do |build_state, step_runner|
      plan_runner = Bootstrap::SysrootRunner.new(state: build_state, step_runner: step_runner)
      plan_runner.phase = "all"
      plan_runner.run_plan

      step_runner.calls.size.should eq 2
      step_runner.calls.map(&.[:phase]).should eq ["one", "two"]
    end
  end

  it "sets up phase environment for each phase" do
    steps = [Bootstrap::BuildStep.new(name: "step", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", env: {"BQ2_PHASE_MARKER" => "phase-one"}, steps: steps),
      Bootstrap::BuildPhase.new(name: "two", description: "b", namespace: "host", install_prefix: "/usr", env: {"BQ2_PHASE_MARKER" => "phase-two"}, steps: steps),
    ])

    with_recording_runner(plan: plan) do |build_state, step_runner|
      plan_runner = Bootstrap::SysrootRunner.new(state: build_state, step_runner: step_runner)
      plan_runner.run_plan

      inside_calls = step_runner.phase_environment_calls.select { |entry| entry[:value] }
      inside_calls.should eq [
        {phase: "one", value: "phase-one"},
        {phase: "two", value: "phase-two"},
      ]
    end
  end

  it "runs only the selected phase when requested" do
    steps = [Bootstrap::BuildStep.new(name: "step", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", steps: steps),
      Bootstrap::BuildPhase.new(name: "two", description: "b", namespace: "host", install_prefix: "/usr", destdir: "/tmp/rootfs", steps: steps),
    ])

    with_recording_runner(plan: plan) do |build_state, step_runner|
      build_state = Bootstrap::SysrootBuildState.new(workspace: step_runner.workspace)
      plan_runner = Bootstrap::SysrootRunner.new(state: build_state, step_runner: step_runner)
      plan_runner.phase = "two"
      plan_runner.run_plan

      step_runner.calls.size.should eq 1
      step_runner.calls.first[:phase].should eq "two"
    end
  end

  it "raises when a requested phase does not exist" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", steps: [] of Bootstrap::BuildStep),
    ])

    with_recording_runner(plan: plan) do |build_state, step_runner|
      plan_runner = Bootstrap::SysrootRunner.new(state: build_state, step_runner: step_runner)

      expect_raises(Exception, /Unknown build phase/) do
        plan_runner.phase = "missing"
        plan_runner.run_plan
      end
    end
  end

  pending "prepares a destdir root directory"

  it "writes a failure report when a step fails" do
    steps = [Bootstrap::BuildStep.new(name: "fail", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    phase = Bootstrap::BuildPhase.new(
      name: "phase-fail",
      description: "test phase",
      namespace: "host",
      install_prefix: "/opt/sysroot",
      steps: steps
    )

    with_recording_runner(plan: Bootstrap::BuildPlan.new([phase])) do |build_state, step_runner|
      step_runner.status = false
      step_runner.exit_code = 23
      plan_runner = Bootstrap::SysrootRunner.new(state: build_state, step_runner: step_runner)

      expect_raises(Exception) do
        plan_runner.report = true
        plan_runner.run_plan
      end

      Dir.glob("#{build_state.report_dir}/*.json").size.should be > 0
    end
  end

  it "filters packages when requested" do
    steps_a = [Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/a", configure_flags: [] of String, patches: [] of String)]
    steps_b = [Bootstrap::BuildStep.new(name: "b", strategy: "autotools", workdir: "/b", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", steps: steps_a),
      Bootstrap::BuildPhase.new(name: "two", description: "b", namespace: "host", install_prefix: "/usr", destdir: "/tmp/rootfs", steps: steps_b),
    ])

    with_recording_runner(plan: plan) do |build_state, step_runner|
      plan_runner = Bootstrap::SysrootRunner.new(state: build_state, step_runner: step_runner)
      plan_runner.phase = "all"
      plan_runner.packages = ["b"]
      plan_runner.run_plan
      step_runner.calls.size.should eq 1
      step_runner.calls.first[:phase].should eq "two"
      step_runner.calls.first[:name].should eq "b"
    end
  end

  it "raises when any requested package filter is missing" do
    steps = [Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/a", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", steps: steps),
    ])

    with_recording_runner(plan: plan) do |build_state, step_runner|
      plan_runner = Bootstrap::SysrootRunner.new(state: build_state, step_runner: step_runner)
      plan_runner.phase = "all"
      plan_runner.packages = ["a", "missing"]
      expect_raises(Exception, /not found/) do
        plan_runner.run_plan
      end
    end
  end

  it "applies overrides from a file when requested" do
    steps = [Bootstrap::BuildStep.new(name: "pkg", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", steps: steps),
    ])

    overrides = Bootstrap::BuildPlanOverrides.new(
      {"one" => Bootstrap::PhaseOverride.new(
        steps: {"pkg" => Bootstrap::StepOverride.new(
          configure_flags_add: ["--with-foo"],
          env: {"CC" => "clang"},
        )},
      ),
      })

    with_recording_runner(plan: plan, overrides: overrides) do |build_state, step_runner|
      plan_runner = Bootstrap::SysrootRunner.new(state: build_state, step_runner: step_runner)
      plan_runner.run_plan
      step_runner.calls.size.should eq 1
      step_runner.calls.first[:configure_flags].should eq ["--with-foo"]
      step_runner.calls.first[:env]["CC"].should eq "clang"
    end
  end

  it "supports dry-run without executing steps" do
    steps = [Bootstrap::BuildStep.new(name: "pkg", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", steps: steps),
    ])

    with_recording_runner(plan: plan) do |build_state, step_runner|
      plan_runner = Bootstrap::SysrootRunner.new(state: build_state, step_runner: step_runner)
      plan_runner.dry_run = true
      plan_runner.dry_run_io = IO::Memory.new
      plan_runner.run_plan
      step_runner.calls.should be_empty
    end
  end

  it "skips completed steps when a state file is present" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "a",
        namespace: "host",
        install_prefix: "/opt/sysroot",
        steps: [
          Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/a", configure_flags: [] of String, patches: [] of String),
          Bootstrap::BuildStep.new(name: "b", strategy: "autotools", workdir: "/b", configure_flags: [] of String, patches: [] of String),
        ],
      ),
    ])

    with_recording_runner(plan: plan) do |build_state, step_runner|
      build_state.mark_success("one", "a")
      plan_runner = Bootstrap::SysrootRunner.new(state: build_state, step_runner: step_runner)
      plan_runner.run_plan
      step_runner.calls.map { |call| call[:name] }.should eq ["b"]
      updated = Bootstrap::SysrootBuildState.new(workspace: step_runner.workspace)
      updated.completed?("one", "a").should be_true
      updated.completed?("one", "b").should be_true
    end
  end

  it "honors resume=false by running completed steps when a state file is present" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "a",
        namespace: "host",
        install_prefix: "/opt/sysroot",
        steps: [
          Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/a", configure_flags: [] of String, patches: [] of String),
          Bootstrap::BuildStep.new(name: "b", strategy: "autotools", workdir: "/b", configure_flags: [] of String, patches: [] of String),
        ],
      ),
    ])

    with_recording_runner(plan: plan) do |build_state, step_runner|
      build_state.mark_success("one", "a")
      plan_runner = Bootstrap::SysrootRunner.new(state: build_state, step_runner: step_runner)
      plan_runner.resume = false
      plan_runner.run_plan
      step_runner.calls.map { |call| call[:name] }.should eq ["a", "b"]
    end
  end

  it "honors --workdir when printing sysroot status" do
    with_tempdir("bq2-status-workdir") do |workspace_root|
      workspace = Bootstrap::SysrootWorkspace.create(host_workdir: workspace_root)
      phase = Bootstrap::BuildPhase.new(
        name: "phase-a",
        description: "status phase",
        namespace: "host",
        install_prefix: "/opt/sysroot",
        steps: [Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
      )
      File.write(workspace.log_path / Bootstrap::SysrootBuildState::PLAN_FILE, Bootstrap::BuildPlan.new([phase]).to_json)

      with_tempdir("bq2-status-cwd") do |isolated_cwd|
        Dir.cd(isolated_cwd) do
          Bootstrap::SysrootRunner.run(["--workdir=#{workspace_root}"], "sysroot-status").should eq(0)
        end
      end
    end
  end
end
