require "./spec_helper"
require "json"
require "file_utils"
require "random/secure"

class RecordingRunner
  include Bootstrap::SysrootRunner::CommandRunner

  getter calls = [] of NamedTuple(phase: String, name: String, workdir: String, strategy: String)
  property status : Bool = true
  property exit_code : Int32 = 0

  def initialize(@status : Bool = true, @exit_code : Int32 = 0)
  end

  def run(phase : Bootstrap::BuildPhase, step : Bootstrap::BuildStep)
    @calls << {phase: phase.name, name: step.name, workdir: step.workdir, strategy: step.strategy}
    raise "Command failed (#{@exit_code})" unless @status
    FakeStatus.new(@status, @exit_code)
  end

  struct FakeStatus
    def initialize(@success : Bool, @exit_code : Int32)
    end

    def success? : Bool
      @success
    end

    def exit_code : Int32
      @exit_code
    end
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

    runner = RecordingRunner.new
    Bootstrap::SysrootRunner.run_steps(phase, steps, runner)

    runner.calls.size.should eq 2
    runner.calls.first[:workdir].should eq "/tmp"
    runner.calls.last[:strategy].should eq "cmake"
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
    runner = RecordingRunner.new(false, 2)

    expect_raises(Exception) do
      Bootstrap::SysrootRunner.run_steps(phase, steps, runner)
    end
  end

  it "loads a plan file and executes only the default phase" do
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
    runner = RecordingRunner.new

    plan_file = File.tempfile("plan")
    plan_file.print(plan.to_json)
    plan_file.flush
    plan_path = plan_file.path
    plan_file.close

    Bootstrap::SysrootRunner.run_plan(plan_path, runner)
    runner.calls.size.should eq 1
    runner.calls.first[:workdir].should eq "/opt"
    runner.calls.first[:name].should eq "file-a"
  end

  it "runs all phases when requested" do
    steps = [Bootstrap::BuildStep.new(name: "step", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", workspace: "/workspace", environment: "test", install_prefix: "/opt/sysroot", steps: steps),
      Bootstrap::BuildPhase.new(name: "two", description: "b", workspace: "/workspace", environment: "test", install_prefix: "/usr", destdir: "/tmp/rootfs", steps: steps),
    ])

    runner = RecordingRunner.new
    Bootstrap::SysrootRunner.run_plan(plan, runner, phase: "all")
    runner.calls.size.should eq 2
    runner.calls.map(&.[:phase]).should eq ["one", "two"]
  end

  it "runs only the selected phase when requested" do
    steps = [Bootstrap::BuildStep.new(name: "step", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", workspace: "/workspace", environment: "test", install_prefix: "/opt/sysroot", steps: steps),
      Bootstrap::BuildPhase.new(name: "two", description: "b", workspace: "/workspace", environment: "test", install_prefix: "/usr", destdir: "/tmp/rootfs", steps: steps),
    ])

    runner = RecordingRunner.new
    Bootstrap::SysrootRunner.run_plan(plan, runner, phase: "two")
    runner.calls.size.should eq 1
    runner.calls.first[:phase].should eq "two"
  end

  it "raises when a requested phase does not exist" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", workspace: "/workspace", environment: "test", install_prefix: "/opt/sysroot", steps: [] of Bootstrap::BuildStep),
    ])
    runner = RecordingRunner.new

    expect_raises(Exception, /Unknown build phase/) do
      Bootstrap::SysrootRunner.run_plan(plan, runner, phase: "missing")
    end
  end

  it "prepares a destdir rootfs skeleton" do
    destdir = Path[Dir.tempdir] / "bq2-rootfs-spec-#{Random::Secure.hex(8)}"
    begin
      plan = Bootstrap::BuildPlan.new([
        Bootstrap::BuildPhase.new(
          name: "rootfs",
          description: "rootfs phase",
          workspace: "/workspace",
          environment: "test",
          install_prefix: "/usr",
          destdir: destdir.to_s,
          steps: [] of Bootstrap::BuildStep,
        ),
      ])

      runner = RecordingRunner.new
      Bootstrap::SysrootRunner.run_plan(plan, runner, phase: "all")

      File.directory?(destdir / "usr/bin").should be_true
      File.directory?(destdir / "var/lib").should be_true
    ensure
      FileUtils.rm_rf(destdir)
    end
  end
end
