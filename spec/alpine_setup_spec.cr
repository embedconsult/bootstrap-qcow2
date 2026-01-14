require "./spec_helper"
require "../src/alpine_setup"

describe Bootstrap::AlpineSetup do
  it "writes resolv.conf into a rootfs tree" do
    with_tempdir do |dir|
      Bootstrap::AlpineSetup.write_resolv_conf(dir, nameserver: "1.1.1.1")
      File.read(dir / "etc/resolv.conf").should eq "nameserver 1.1.1.1\n"
    end
  end
end
