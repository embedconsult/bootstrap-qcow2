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

      code = <<-'CR'
        require "./src/syscalls"
        Bootstrap::Syscalls.unshare(Bootstrap::Syscalls::CLONE_NEWUSER)
        Bootstrap::Syscalls.write_proc_self_map("setgroups", "deny")
        uid = Bootstrap::Syscalls.uid
        gid = Bootstrap::Syscalls.gid
        Bootstrap::Syscalls.write_proc_self_map("uid_map", "0 #{uid} 1")
        Bootstrap::Syscalls.write_proc_self_map("gid_map", "0 #{gid} 1")
      CR
      status = run_crystal_eval(code)
      pending! "requires unprivileged user namespaces (see README)" unless status.success?
      status.success?.should be_true
      available.should be_true
    end
  end

  describe ".uid/.gid" do
    it "returns non-negative ids" do
      Bootstrap::Syscalls.uid.should be >= 0
      Bootstrap::Syscalls.gid.should be >= 0
    end
  end

  describe ".chdir" do
    it "changes the working directory" do
      previous = Dir.current
      with_tmpdir do |dir|
        begin
          Bootstrap::Syscalls.chdir(dir)
          Dir.current.should eq(dir)
        ensure
          Bootstrap::Syscalls.chdir(previous)
        end
      end
    end
  end

  describe ".unshare" do
    it "unshares a user namespace when available" do
      available = namespace_maps_available?
      pending! "requires unprivileged user namespaces (see README)" unless available
      code = <<-'CR'
        require "./src/syscalls"
        Bootstrap::Syscalls.unshare(Bootstrap::Syscalls::CLONE_NEWUSER)
      CR
      status = run_crystal_eval(code)
      pending! "requires unprivileged user namespaces (see README)" unless status.success?
      status.success?.should be_true
    end
  end

  describe ".mount/.umount2" do
    it "bind-mounts and detaches within a mount namespace when available" do
      available = namespace_maps_available?(require_mount: true)
      pending! "requires unprivileged user+mount namespaces (see README)" unless available
      code = <<-'CR'
        require "./src/syscalls"
        require "file_utils"
        root = Dir.tempdir
        src = File.join(root, "src")
        dst = File.join(root, "dst")
        FileUtils.mkdir_p(src)
        FileUtils.mkdir_p(dst)
        Bootstrap::Syscalls.unshare(Bootstrap::Syscalls::CLONE_NEWUSER | Bootstrap::Syscalls::CLONE_NEWNS)
        Bootstrap::Syscalls.write_proc_self_map("setgroups", "deny")
        uid = Bootstrap::Syscalls.uid
        gid = Bootstrap::Syscalls.gid
        Bootstrap::Syscalls.write_proc_self_map("uid_map", "0 #{uid} 1")
        Bootstrap::Syscalls.write_proc_self_map("gid_map", "0 #{gid} 1")
        Bootstrap::Syscalls.mount(nil, "/", nil, Bootstrap::Syscalls::MS_PRIVATE | Bootstrap::Syscalls::MS_REC)
        Bootstrap::Syscalls.mount(src, dst, nil, Bootstrap::Syscalls::MS_BIND | Bootstrap::Syscalls::MS_REC)
        Bootstrap::Syscalls.umount2(dst, Bootstrap::Syscalls::MNT_DETACH)
      CR
      status = run_crystal_eval(code)
      pending! "requires unprivileged user+mount namespaces (see README)" unless status.success?
      status.success?.should be_true
    end
  end

  describe ".chroot" do
    it "chroots within a user+mount namespace when available" do
      available = namespace_maps_available?(require_mount: true)
      pending! "requires unprivileged user+mount namespaces (see README)" unless available
      code = <<-'CR'
        require "./src/syscalls"
        require "file_utils"
        root = Dir.tempdir
        new_root = File.join(root, "root")
        FileUtils.mkdir_p(File.join(new_root, "proc"))
        Bootstrap::Syscalls.unshare(Bootstrap::Syscalls::CLONE_NEWUSER | Bootstrap::Syscalls::CLONE_NEWNS)
        Bootstrap::Syscalls.write_proc_self_map("setgroups", "deny")
        uid = Bootstrap::Syscalls.uid
        gid = Bootstrap::Syscalls.gid
        Bootstrap::Syscalls.write_proc_self_map("uid_map", "0 #{uid} 1")
        Bootstrap::Syscalls.write_proc_self_map("gid_map", "0 #{gid} 1")
        Bootstrap::Syscalls.mount(nil, "/", nil, Bootstrap::Syscalls::MS_PRIVATE | Bootstrap::Syscalls::MS_REC)
        Bootstrap::Syscalls.mount(new_root, new_root, nil, Bootstrap::Syscalls::MS_BIND | Bootstrap::Syscalls::MS_REC)
        Bootstrap::Syscalls.chroot(new_root)
        Bootstrap::Syscalls.chdir("/")
      CR
      status = run_crystal_eval(code)
      pending! "requires unprivileged user+mount namespaces (see README)" unless status.success?
      status.success?.should be_true
    end
  end

  describe ".pivot_root" do
    it "pivots to a prepared root when available" do
      available = namespace_maps_available?(require_mount: true)
      pending! "requires unprivileged user+mount namespaces (see README)" unless available
      code = <<-'CR'
        require "./src/syscalls"
        require "file_utils"
        root = Dir.tempdir
        new_root = File.join(root, "new_root")
        old_root = File.join(new_root, "old_root")
        FileUtils.mkdir_p(old_root)
        Bootstrap::Syscalls.unshare(Bootstrap::Syscalls::CLONE_NEWUSER | Bootstrap::Syscalls::CLONE_NEWNS)
        Bootstrap::Syscalls.write_proc_self_map("setgroups", "deny")
        uid = Bootstrap::Syscalls.uid
        gid = Bootstrap::Syscalls.gid
        Bootstrap::Syscalls.write_proc_self_map("uid_map", "0 #{uid} 1")
        Bootstrap::Syscalls.write_proc_self_map("gid_map", "0 #{gid} 1")
        Bootstrap::Syscalls.mount(nil, "/", nil, Bootstrap::Syscalls::MS_PRIVATE | Bootstrap::Syscalls::MS_REC)
        Bootstrap::Syscalls.mount(new_root, new_root, nil, Bootstrap::Syscalls::MS_BIND | Bootstrap::Syscalls::MS_REC)
        Bootstrap::Syscalls.pivot_root(new_root, old_root)
        Bootstrap::Syscalls.chdir("/")
      CR
      status = run_crystal_eval(code)
      pending! "requires unprivileged user+mount namespaces (see README)" unless status.success?
      status.success?.should be_true
    end
  end

  describe ".sethostname" do
    it "sets the hostname in a UTS namespace when available" do
      available = namespace_maps_available?
      pending! "requires unprivileged user namespaces (see README)" unless available
      code = <<-'CR'
        require "./src/syscalls"
        Bootstrap::Syscalls.unshare(Bootstrap::Syscalls::CLONE_NEWUSER | Bootstrap::Syscalls::CLONE_NEWUTS)
        Bootstrap::Syscalls.write_proc_self_map("setgroups", "deny")
        uid = Bootstrap::Syscalls.uid
        gid = Bootstrap::Syscalls.gid
        Bootstrap::Syscalls.write_proc_self_map("uid_map", "0 #{uid} 1")
        Bootstrap::Syscalls.write_proc_self_map("gid_map", "0 #{gid} 1")
        Bootstrap::Syscalls.sethostname("bootstrap-qcow2")
      CR
      status = run_crystal_eval(code)
      pending! "requires UTS namespace permissions (see README)" unless status.success?
      status.success?.should be_true
    end
  end
end
