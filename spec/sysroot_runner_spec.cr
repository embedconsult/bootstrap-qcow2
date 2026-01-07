require "./spec_helper"
require "json"

class RecordingRunner
  include Bootstrap::SysrootRunner::CommandRunner

  getter calls = [] of NamedTuple(name: String, workdir: String, strategy: String)
  property status : Bool = true
  property exit_code : Int32 = 0

  def initialize(@status : Bool = true, @exit_code : Int32 = 0)
  end

  def run(step : Bootstrap::SysrootRunner::BuildStep)
    @calls << {name: step.name, workdir: step.workdir, strategy: step.strategy}
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
    steps = [
      Bootstrap::SysrootRunner::BuildStep.new(name: "a", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String, sysroot_prefix: "/opt/sysroot"),
      Bootstrap::SysrootRunner::BuildStep.new(name: "b", strategy: "cmake", workdir: "/var", configure_flags: [] of String, patches: [] of String, sysroot_prefix: "/opt/sysroot"),
    ]

    runner = RecordingRunner.new
    Bootstrap::SysrootRunner.run_steps(steps, runner)

    runner.calls.size.should eq 2
    runner.calls.first[:workdir].should eq "/tmp"
    runner.calls.last[:strategy].should eq "cmake"
  end

  it "raises when a command fails" do
    steps = [Bootstrap::SysrootRunner::BuildStep.new(name: "fail", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String, sysroot_prefix: "/opt/sysroot")]
    runner = RecordingRunner.new(false, 2)

    expect_raises(Exception) do
      Bootstrap::SysrootRunner.run_steps(steps, runner)
    end
  end

  it "loads a plan file and executes steps" do
    steps = [Bootstrap::SysrootRunner::BuildStep.new(name: "file", strategy: "autotools", workdir: "/opt", configure_flags: [] of String, patches: [] of String, sysroot_prefix: "/opt/sysroot")]
    runner = RecordingRunner.new

    plan_file = File.tempfile("plan")
    plan_file.print(steps.to_json)
    plan_file.flush
    plan_path = plan_file.path
    plan_file.close

    Bootstrap::SysrootRunner.run_plan(plan_path, runner)
    runner.calls.size.should eq 1
    runner.calls.first[:workdir].should eq "/opt"
  end
end
