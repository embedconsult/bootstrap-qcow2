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

describe Bootstrap::Syscalls do
  describe ".unshare" do
    pending "requires unprivileged user namespaces on the host kernel" do
      Bootstrap::Syscalls.unshare(Bootstrap::Syscalls::CLONE_NEWUSER)
    end
  end

  describe ".mount" do
    pending "requires mount namespace privileges on the host kernel" do
      Bootstrap::Syscalls.mount("tmpfs", "/tmp", "tmpfs", Bootstrap::Syscalls::MS_NODEV)
    end
  end

  describe ".umount2" do
    pending "requires mount namespace privileges on the host kernel" do
      Bootstrap::Syscalls.umount2("/tmp", Bootstrap::Syscalls::MNT_DETACH)
    end
  end

  describe ".pivot_root" do
    pending "requires mount namespace privileges and a prepared pivot root" do
      Bootstrap::Syscalls.pivot_root("/new-root", "/new-root/old-root")
    end
  end

  describe ".chdir" do
    it "changes the working directory" do
      with_tmpdir do |dir|
        original = Dir.current
        begin
          Bootstrap::Syscalls.chdir(dir)
          Dir.current.should eq(dir)
        ensure
          Bootstrap::Syscalls.chdir(original)
        end
      end
    end
  end

  describe ".chroot" do
    pending "requires root privileges and a prepared rootfs" do
      Bootstrap::Syscalls.chroot("/new-root")
    end
  end

  describe ".sethostname" do
    pending "requires UTS namespace privileges on the host kernel" do
      Bootstrap::Syscalls.sethostname("bootstrap-qcow2")
    end
  end

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
  end
end
