require "file_utils"
require "./spec_helper"

describe Bootstrap::SysrootNamespace do
  describe ".missing_filesystems" do
    it "returns missing filesystem types" do
      file = File.tempfile("filesystems")
      begin
        file.print("nodev\tproc\nnodev\tsysfs\nnodev\ttmpfs\n")
        file.flush

        missing = Bootstrap::SysrootNamespace.missing_filesystems(Path[file.path], ["proc", "sysfs", "tmpfs", "devtmpfs"])
        missing.should eq ["devtmpfs"]
      ensure
        file.close
      end
    end
  end

  describe ".proc_mask_restrictions" do
    it "reports unreadable proc paths" do
      temp = File.tempfile("proc-root")
      proc_root = Path[temp.path]
      temp.close
      File.delete(proc_root) if File.exists?(proc_root)
      FileUtils.mkdir_p(proc_root)
      FileUtils.mkdir_p(proc_root / "sys")

      restrictions = Bootstrap::SysrootNamespace.proc_mask_restrictions(proc_root)
      restrictions.any? { |entry| entry.includes?("sysrq-trigger") }.should be_true
    end
  end

  describe ".setgroups_restriction" do
    it "returns nil when setgroups is readable and writable" do
      file = File.tempfile("setgroups")
      begin
        file.print("allow\n")
        file.flush

        restriction = Bootstrap::SysrootNamespace.setgroups_restriction(file.path)
        restriction.should be_nil
      ensure
        file.close
      end
    end
  end

  describe ".collect_restrictions" do
    it "aggregates filesystem and proc mask restrictions" do
      proc_root_temp = File.tempfile("proc-root")
      proc_root = Path[proc_root_temp.path]
      proc_root_temp.close
      File.delete(proc_root) if File.exists?(proc_root)
      FileUtils.mkdir_p(proc_root / "sys")

      filesystems = File.tempfile("filesystems")
      begin
        filesystems.print("nodev\tproc\nnodev\tsysfs\n")
        filesystems.flush

        restrictions = Bootstrap::SysrootNamespace.collect_restrictions(
          proc_root: proc_root,
          filesystems_path: Path[filesystems.path],
          setgroups_path: "/missing/setgroups",
          userns_toggle_path: "/missing/userns"
        )

        restrictions.any? { |entry| entry.includes?("missing filesystem support") }.should be_true
        restrictions.any? { |entry| entry.includes?("proc path") }.should be_true
        restrictions.any? { |entry| entry.includes?("kernel.unprivileged_userns_clone") }.should be_true
      ensure
        filesystems.close
      end
    end
  end

  describe ".unprivileged_userns_clone_enabled?" do
    it "returns true when the toggle is enabled" do
      file = File.tempfile("userns")
      begin
        file.print("1\n")
        file.flush

        Bootstrap::SysrootNamespace.unprivileged_userns_clone_enabled?(file.path).should be_true
      ensure
        file.close
      end
    end

    it "returns false when the toggle is disabled" do
      file = File.tempfile("userns")
      begin
        file.print("0\n")
        file.flush

        Bootstrap::SysrootNamespace.unprivileged_userns_clone_enabled?(file.path).should be_false
      ensure
        file.close
      end
    end

    it "treats missing files as disabled" do
      Bootstrap::SysrootNamespace.unprivileged_userns_clone_enabled?("/missing/does/not/exist").should be_false
    end

    it "rejects unexpected toggle values" do
      file = File.tempfile("userns")
      begin
        file.print("maybe\n")
        file.flush

        Bootstrap::SysrootNamespace.unprivileged_userns_clone_enabled?(file.path).should be_false
      ensure
        file.close
      end
    end
  end

  it "fails when unprivileged user namespaces are disabled (ensure helper)" do
    file = File.tempfile("userns")
    begin
      file.print("0\n")
      file.flush

      expect_raises(Bootstrap::SysrootNamespace::NamespaceError) do
        Bootstrap::SysrootNamespace.ensure_unprivileged_userns_clone_enabled!(file.path)
      end
    ensure
      file.close
    end
  end

  setgroups_issue = Bootstrap::SysrootNamespace.setgroups_restriction("/proc/self/setgroups")
  if Bootstrap::SysrootNamespace.unprivileged_userns_clone_enabled? && setgroups_issue.nil?
    it "unshares namespaces in a subprocess when enabled" do
      # Run in a subprocess to avoid mutating the namespace state of the spec runner.
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(
        "crystal",
        ["eval", "require \"./src/sysroot_namespace\"; Bootstrap::SysrootNamespace.unshare_namespaces"],
        chdir: Path[__DIR__] / "..",
        output: stdout,
        error: stderr
      )

      unless status.success?
        raise "Namespace unshare failed (exit=#{status.exit_code}). stdout=#{stdout} stderr=#{stderr}"
      end
    end
  else
    reason = if !Bootstrap::SysrootNamespace.unprivileged_userns_clone_enabled?
               "kernel does not allow unprivileged user namespaces"
             else
               "setgroups is not writable; LSM restrictions likely"
             end
    pending "unshares namespaces in a subprocess when enabled (#{reason})" do
    end
  end

  proc_masked = !Bootstrap::SysrootNamespace.proc_mask_restrictions(Path["/proc"]).empty?
  if Bootstrap::SysrootNamespace.unprivileged_userns_clone_enabled? && !proc_masked
    it "enters a rootfs with namespaces when supported" do
      # Run in a subprocess to avoid mutating the namespace state of the spec runner.
      rootfs = File.tempname("sysroot-namespace")
      FileUtils.mkdir_p(rootfs)

      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(
        "crystal",
        ["eval", "require \"./src/sysroot_namespace\"; Bootstrap::SysrootNamespace.enter_rootfs(#{rootfs.inspect})"],
        chdir: Path[__DIR__] / "..",
        output: stdout,
        error: stderr
      )

      unless status.success?
        raise "Namespace rootfs entry failed (exit=#{status.exit_code}). stdout=#{stdout} stderr=#{stderr}"
      end
    end
  else
    reason = if !Bootstrap::SysrootNamespace.unprivileged_userns_clone_enabled?
               "kernel does not allow unprivileged user namespaces"
             else
               "proc is masked; mount_too_revealing likely"
             end
    pending "enters a rootfs with namespaces when supported (#{reason})" do
    end
  end
end
