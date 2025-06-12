require "./spec_helper"

describe Bootstrap::Qcow2 do
  it "can be instantiated" do
    qcow2 = Bootstrap::Qcow2.new("blabl-space-20250612.qcow2")
  end
end
