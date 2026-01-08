require "./spec_helper"
require "../src/syscalls"
require "lib_c"
require "random/secure"

lib LibC
  fun geteuid : UInt32
end

private def with_tmpdir(&)
  dir = File.join(Dir.tempdir, "syscalls-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Bootstrap::Syscalls do
  describe ".unshare" do
    if ENV["BOOTSTRAP_QCOW2_PRIVILEGED_SPECS"]? == "1"
      it "unshares user namespaces when enabled" do
        Bootstrap::Syscalls.unshare(Bootstrap::Syscalls::CLONE_NEWUSER)
      end
    else
      pending "requires unprivileged user namespaces (set BOOTSTRAP_QCOW2_PRIVILEGED_SPECS=1; see README)" do
        Bootstrap::Syscalls.unshare(Bootstrap::Syscalls::CLONE_NEWUSER)
      end
    end
  end

  describe ".mount" do
    if ENV["BOOTSTRAP_QCOW2_PRIVILEGED_SPECS"]? == "1"
      it "mounts tmpfs when enabled" do
        Bootstrap::Syscalls.mount("tmpfs", "/tmp", "tmpfs", Bootstrap::Syscalls::MS_NODEV)
      end
    else
      pending "requires mount namespace privileges (set BOOTSTRAP_QCOW2_PRIVILEGED_SPECS=1; see README)" do
        Bootstrap::Syscalls.mount("tmpfs", "/tmp", "tmpfs", Bootstrap::Syscalls::MS_NODEV)
      end
    end
  end

  describe ".umount2" do
    if ENV["BOOTSTRAP_QCOW2_PRIVILEGED_SPECS"]? == "1"
      it "unmounts a target when enabled" do
        Bootstrap::Syscalls.umount2("/tmp", Bootstrap::Syscalls::MNT_DETACH)
      end
    else
      pending "requires mount namespace privileges (set BOOTSTRAP_QCOW2_PRIVILEGED_SPECS=1; see README)" do
        Bootstrap::Syscalls.umount2("/tmp", Bootstrap::Syscalls::MNT_DETACH)
      end
    end
  end

  describe ".pivot_root" do
    if ENV["BOOTSTRAP_QCOW2_PRIVILEGED_SPECS"]? == "1"
      pending "requires a prepared pivot root even when privileged" do
        Bootstrap::Syscalls.pivot_root("/new-root", "/new-root/old-root")
      end
    else
      pending "requires mount namespace privileges and a prepared pivot root (set BOOTSTRAP_QCOW2_PRIVILEGED_SPECS=1; see README)" do
        Bootstrap::Syscalls.pivot_root("/new-root", "/new-root/old-root")
      end
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
    if LibC.geteuid == 0
      pending "requires a prepared rootfs even when running as root" do
        Bootstrap::Syscalls.chroot("/new-root")
      end
    else
      pending "requires root privileges and a prepared rootfs" do
        Bootstrap::Syscalls.chroot("/new-root")
      end
    end
  end

  describe ".sethostname" do
    if ENV["BOOTSTRAP_QCOW2_PRIVILEGED_SPECS"]? == "1"
      pending "requires UTS namespace setup even when privileged" do
        Bootstrap::Syscalls.sethostname("bootstrap-qcow2")
      end
    else
      pending "requires UTS namespace privileges (set BOOTSTRAP_QCOW2_PRIVILEGED_SPECS=1; see README)" do
        Bootstrap::Syscalls.sethostname("bootstrap-qcow2")
      end
    end
  end

  describe ".write_proc_self_map" do
    if ENV["BOOTSTRAP_QCOW2_PRIVILEGED_SPECS"]? == "1"
      pending "requires a user namespace with writable /proc/self maps" do
        Bootstrap::Syscalls.write_proc_self_map("uid_map", "0 1000 1")
      end
    else
      pending "requires a user namespace with writable /proc/self maps (set BOOTSTRAP_QCOW2_PRIVILEGED_SPECS=1; see README)" do
        Bootstrap::Syscalls.write_proc_self_map("uid_map", "0 1000 1")
      end
    end

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
