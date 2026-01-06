require "./spec_helper"
require "../src/sysroot_runner_lib"
require "json"

class RecordingRunner
  include Bootstrap::SysrootRunner::CommandRunner

  getter calls = [] of NamedTuple(argv: Array(String), chdir: String?)
  property status : Bool = true
  property exit_code : Int32 = 0

  def initialize(@status : Bool = true, @exit_code : Int32 = 0)
  end

  def run(argv : Array(String), chdir : String? = nil)
    @calls << {argv: argv, chdir: chdir}
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
      Bootstrap::SysrootRunner::BuildStep.new(name: "a", commands: [["echo", "hi"]], workdir: "/tmp"),
      Bootstrap::SysrootRunner::BuildStep.new(name: "b", commands: [["true"]], workdir: "/var"),
    ]

    runner = RecordingRunner.new
    Bootstrap::SysrootRunner.run_steps(steps, runner)

    runner.calls.size.should eq 2
    runner.calls.first[:argv].should eq ["echo", "hi"]
    runner.calls.first[:chdir].should eq "/tmp"
  end

  it "raises when a command fails" do
    steps = [Bootstrap::SysrootRunner::BuildStep.new(name: "fail", commands: [["false"]], workdir: "/tmp")]
    runner = RecordingRunner.new(false, 2)

    expect_raises(Exception) do
      Bootstrap::SysrootRunner.run_steps(steps, runner)
    end
  end

  it "loads a plan file and executes steps" do
    steps = [Bootstrap::SysrootRunner::BuildStep.new(name: "file", commands: [["echo", "file"]], workdir: "/opt")]
    runner = RecordingRunner.new

    plan_file = File.tempfile("plan")
    plan_file.print(steps.to_json)
    plan_file.flush
    plan_path = plan_file.path
    plan_file.close

    Bootstrap::SysrootRunner.run_plan(plan_path, runner)
    runner.calls.size.should eq 1
    runner.calls.first[:argv].should eq ["echo", "file"]
    runner.calls.first[:chdir].should eq "/opt"
  end
end
