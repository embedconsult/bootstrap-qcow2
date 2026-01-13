require "./spec_helper"
require "../src/cli"

describe Bootstrap::CLI do
  it "dispatches by subcommand argument when executable name is not mapped" do
    command, args = Bootstrap::CLI.dispatch(["sysroot-builder", "--flag"], ["sysroot-builder", "other"])
    command.should eq "sysroot-builder"
    args.should eq ["--flag"]
  end

  it "returns help flag when -h is provided" do
    parser, remaining, help = Bootstrap::CLI.parse(["-h"], "usage") { |_| }
    help.should be_true
    remaining.should eq [] of String
  end
end
