require "./spec_helper"
require "random/secure"

private def with_tmpdir(&)
  dir = File.join(Dir.tempdir, "syscalls-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Bootstrap::Syscalls do
  describe ".write_proc_self_map" do
    it "rejects unsupported entries" do
      expect_raises(ArgumentError, "Unsupported proc entry") do
        Bootstrap::Syscalls.write_proc_self_map("nope", "0 0 1", "/tmp")
      end
    end

    it "rejects null bytes in content" do
      with_tmpdir do |dir|
        path = File.join(dir, "uid_map")
        File.write(path, "")
        expect_raises(ArgumentError, "null bytes") do
          Bootstrap::Syscalls.write_proc_self_map("uid_map", "0\0 0 1", dir)
        end
      end
    end

    it "appends a newline when missing" do
      with_tmpdir do |dir|
        Bootstrap::Syscalls.write_proc_self_map("uid_map", "0 1000 1", dir)
        content = File.read(File.join(dir, "uid_map"))
        content.should eq("0 1000 1\n")
      end
    end

    it "writes mappings after unsharing a user namespace" do
      available = namespace_maps_available?
      pending! "requires unprivileged user namespaces (see README)" unless available

      child = Process.fork do
        Bootstrap::Syscalls.unshare(Bootstrap::Syscalls::CLONE_NEWUSER)
        Bootstrap::Syscalls.write_proc_self_map("setgroups", "deny")
        uid = Bootstrap::Syscalls.uid
        gid = Bootstrap::Syscalls.gid
        Bootstrap::Syscalls.write_proc_self_map("uid_map", "0 #{uid} 1")
        Bootstrap::Syscalls.write_proc_self_map("gid_map", "0 #{gid} 1")
        exit 0
      rescue
        exit 1
      end

      status = child.wait
      status.exit_code.should eq 0
      available.should be_true
    end
  end
end
