require "./spec_helper"
require "file_utils"

class RecordingRunner < Bootstrap::StepRunner
  getter calls = [] of NamedTuple(phase: String, name: String, workdir: String, strategy: String, configure_flags: Array(String), env: Hash(String, String))
  property status : Bool = true
  property exit_code : Int32 = 0

  def initialize(@status : Bool = true, @exit_code : Int32 = 0)
    super(clean_build_dirs: true, workspace: nil)
  end

  def run(phase : Bootstrap::BuildPhase, step : Bootstrap::BuildStep)
    @calls << {phase: phase.name, name: step.name, workdir: step.workdir, strategy: step.strategy, configure_flags: step.configure_flags, env: step.env}
    raise Bootstrap::CommandFailedError.new(["false"], @exit_code, "Command failed (#{@exit_code})") unless @status
  end
end

describe Bootstrap::SysrootRunner do
  it "runs steps with a custom runner" do
    phase = Bootstrap::BuildPhase.new(
      name: "phase-a",
      description: "test phase",
      workspace: "/workspace",
      environment: "test",
      install_prefix: "/opt/sysroot",
      destdir: nil,
      env: {} of String => String,
      steps: [] of Bootstrap::BuildStep,
    )
    steps = [
      Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String),
      Bootstrap::BuildStep.new(name: "b", strategy: "cmake", workdir: "/var", configure_flags: [] of String, patches: [] of String),
    ]

    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.create(dir)
      runner = RecordingRunner.new
      sysroot_runner = Bootstrap::SysrootRunner.new(workspace: workspace, report: false, resume: false, dry_run: false, step_runner: runner)
      sysroot_runner.run_steps(phase, steps)

      runner.calls.size.should eq 2
      runner.calls.first[:workdir].should eq "/tmp"
      runner.calls.last[:strategy].should eq "cmake"
    end
  end

  it "raises when a command fails" do
    phase = Bootstrap::BuildPhase.new(
      name: "phase-fail",
      description: "test phase",
      workspace: "/workspace",
      environment: "test",
      install_prefix: "/opt/sysroot",
      steps: [] of Bootstrap::BuildStep,
    )
    steps = [Bootstrap::BuildStep.new(name: "fail", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]

    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.create(dir)
      runner = RecordingRunner.new(false, 2)
      sysroot_runner = Bootstrap::SysrootRunner.new(workspace: workspace, report: false, resume: false, dry_run: false, step_runner: runner)

      expect_raises(Bootstrap::CommandFailedError) do
        sysroot_runner.run_steps(phase, steps)
      end
    end
  end

  it "runs the selected phase from a plan" do
    phase_a_steps = [Bootstrap::BuildStep.new(name: "file-a", strategy: "autotools", workdir: "/opt", configure_flags: [] of String, patches: [] of String)]
    phase_b_steps = [Bootstrap::BuildStep.new(name: "file-b", strategy: "autotools", workdir: "/var", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "phase-a",
        description: "phase a",
        workspace: "/workspace",
        environment: "test",
        install_prefix: "/opt/sysroot",
        steps: phase_a_steps,
      ),
      Bootstrap::BuildPhase.new(
        name: "phase-b",
        description: "phase b",
        workspace: "/workspace",
        environment: "test",
        install_prefix: "/usr",
        destdir: "/tmp/rootfs",
        steps: phase_b_steps,
      ),
    ])

    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.create(dir)
      build_state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      FileUtils.mkdir_p(build_state.plan_path.parent)
      File.write(build_state.plan_path, plan.to_json)
      runner = RecordingRunner.new
      sysroot_runner = Bootstrap::SysrootRunner.new(workspace: workspace, start_phase: "phase-a", report: false, resume: false, dry_run: false, step_runner: runner)
      sysroot_runner.run_plan
      runner.calls.size.should eq 1
      runner.calls.first[:workdir].should eq "/opt"
      runner.calls.first[:name].should eq "file-a"
    end
  end

  it "runs all phases when requested" do
    steps = [Bootstrap::BuildStep.new(name: "step", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", workspace: "/workspace", environment: "test", install_prefix: "/opt/sysroot", steps: steps),
      Bootstrap::BuildPhase.new(name: "two", description: "b", workspace: "/workspace", environment: "test", install_prefix: "/usr", destdir: "/tmp/rootfs", steps: steps),
    ])

    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.create(dir)
      build_state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      FileUtils.mkdir_p(build_state.plan_path.parent)
      File.write(build_state.plan_path, plan.to_json)
      runner = RecordingRunner.new
      sysroot_runner = Bootstrap::SysrootRunner.new(workspace: workspace, start_phase: "all", report: false, resume: false, dry_run: false, step_runner: runner)
      sysroot_runner.run_plan
      runner.calls.size.should eq 2
      runner.calls.map(&.[:phase]).should eq ["one", "two"]
    end
  end

  it "filters to selected packages when requested" do
    steps = [
      Bootstrap::BuildStep.new(name: "one", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String),
      Bootstrap::BuildStep.new(name: "two", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String),
    ]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "phase", description: "a", workspace: "/workspace", environment: "test", install_prefix: "/opt/sysroot", steps: steps),
    ])

    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.create(dir)
      build_state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      FileUtils.mkdir_p(build_state.plan_path.parent)
      File.write(build_state.plan_path, plan.to_json)
      runner = RecordingRunner.new
      sysroot_runner = Bootstrap::SysrootRunner.new(workspace: workspace, start_phase: "all", packages: ["two"], report: false, resume: false, dry_run: false, step_runner: runner)
      sysroot_runner.run_plan
      runner.calls.size.should eq 1
      runner.calls.first[:name].should eq "two"
    end
  end
end
