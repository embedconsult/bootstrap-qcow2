require "./spec_helper"

describe Bootstrap::Qcow2 do
  it "can be instantiated" do
    qcow2 = Bootstrap::Qcow2.new("blabl-space-20250612.qcow2")
    qcow2.should be_a(Bootstrap::Qcow2)
  end

  it "can check if it has dependencies" do
    qcow2 = Bootstrap::Qcow2.new("blabl-space-20250612.qcow2")
    qcow2.checkDeps.should be_true
  end
end
