require "./spec_helper"
require "../src/syscalls"
require "random/secure"

private def with_tmpdir(&)
  dir = File.join(Dir.tempdir, "syscalls-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def user_namespace_available? : Bool
  pid = Process.fork do
    begin
      Bootstrap::Syscalls.unshare(Bootstrap::Syscalls::CLONE_NEWUSER)
      exit 0
    rescue ex : Errno
      exit ex.errno == Errno::EPERM ? 1 : 2
    rescue
      exit 2
    end
  end

  status = Process.wait(pid)
  case status.exit_code
  when 0
    true
  when 1
    false
  else
    raise "Unexpected failure probing user namespaces (exit #{status.exit_code})"
  end
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
      pending "requires unprivileged user namespaces (see README)" unless user_namespace_available?

      pid = Process.fork do
        Bootstrap::Syscalls.unshare(Bootstrap::Syscalls::CLONE_NEWUSER)
        Bootstrap::Syscalls.write_proc_self_map("setgroups", "deny")
        Bootstrap::Syscalls.write_proc_self_map("uid_map", "0 #{Process.uid} 1")
        Bootstrap::Syscalls.write_proc_self_map("gid_map", "0 #{Process.gid} 1")
        exit 0
      rescue
        exit 1
      end

      status = Process.wait(pid)
      status.exit_code.should eq 0
    end
  end
end
