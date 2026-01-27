require "./spec_helper"

describe Bootstrap::ProcessRunner do
  it "runs a command and captures output" do
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    result = Bootstrap::ProcessRunner.run(
      ["/bin/sh", "-c", "printf '%s' hello"],
      stdout: stdout,
      stderr: stderr
    )

    result.status.success?.should be_true
    stdout.to_s.should eq "hello"
    stderr.to_s.should eq ""
    result.elapsed.should be >= 0.seconds
  end

  it "passes environment variables to the process" do
    stdout = IO::Memory.new
    result = Bootstrap::ProcessRunner.run(
      ["/bin/sh", "-c", "printf '%s' \"$FOO\""],
      env: {"FOO" => "bar"},
      stdout: stdout,
      stderr: IO::Memory.new
    )

    result.status.success?.should be_true
    stdout.to_s.should eq "bar"
  end
end
