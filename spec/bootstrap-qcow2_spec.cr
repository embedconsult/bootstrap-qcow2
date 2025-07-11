require "./spec_helper"
require "log"

Log.setup_from_env

describe Bootstrap::Qcow2 do
  it "can be instantiated" do
    qcow2 = Bootstrap::Qcow2.new("blabl-space-20250612.qcow2")
    qcow2.should be_a(Bootstrap::Qcow2)
  end

  it "can check if it has dependencies" do
    qcow2 = Bootstrap::Qcow2.new("blabl-space-20250612.qcow2")
    qcow2.checkDeps.should be_true
  end

  it "has a helper to find executables" do
    qimg = Bootstrap::Qcow2.findExe?("qemu-img")
    qimg.should be_a(Bool)
  end

  it "can generate a qcow2 file" do
    qcow2 = Bootstrap::Qcow2.new("blabl-space-20250612.qcow2")
    qcow2.genQcow2.should be_true
  end

  it "has a method used for testing ideas" do
    Bootstrap::Qcow2.test.should be_true
  end
end
