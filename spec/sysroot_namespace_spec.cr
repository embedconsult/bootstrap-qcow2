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

  describe ".apparmor_restriction" do
    it "returns nil for unconfined labels" do
      file = File.tempfile("apparmor")
      sysctl = File.tempfile("apparmor-userns")
      begin
        file.print("unconfined\n")
        file.flush
        sysctl.print("0\n")
        sysctl.flush

        restriction = Bootstrap::SysrootNamespace.apparmor_restriction(
          Path[file.path],
          Path[sysctl.path]
        )
        restriction.should be_nil
      ensure
        sysctl.close
        file.close
      end
    end

    it "reports confinement when a label is present" do
      file = File.tempfile("apparmor")
      sysctl = File.tempfile("apparmor-userns")
      begin
        file.print("profile://container\n")
        file.flush
        sysctl.print("0\n")
        sysctl.flush

        restriction = Bootstrap::SysrootNamespace.apparmor_restriction(
          Path[file.path],
          Path[sysctl.path]
        )
        restriction.should_not be_nil
      ensure
        sysctl.close
        file.close
      end
    end

    it "reports restriction when the AppArmor userns sysctl is enabled" do
      file = File.tempfile("apparmor")
      sysctl = File.tempfile("apparmor-userns")
      begin
        file.print("unconfined\n")
        file.flush
        sysctl.print("1\n")
        sysctl.flush

        restriction = Bootstrap::SysrootNamespace.apparmor_restriction(
          Path[file.path],
          Path[sysctl.path]
        )
        restriction.should_not be_nil
      ensure
        sysctl.close
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
          userns_toggle_path: "/missing/userns"
        )

        restrictions.any? { |entry| entry.includes?("missing filesystem support") }.should be_true
        restrictions.any? { |entry| entry.includes?("kernel.unprivileged_userns_clone") }.should be_true
      ensure
        filesystems.close
      end
    end

    it "reports no_new_privs and seccomp from /proc/self/status" do
      status = File.tempfile("status")
      filesystems = File.tempfile("filesystems")
      begin
        filesystems.print("nodev\tproc\nnodev\tsysfs\nnodev\ttmpfs\n")
        filesystems.flush

        status.print("Name:\tproc\n")
        status.print("NoNewPrivs:\t1\n")
        status.print("Seccomp:\t2\n")
        status.flush

        restrictions = Bootstrap::SysrootNamespace.collect_restrictions(
          proc_root: Path["/proc"],
          filesystems_path: Path[filesystems.path],
          proc_status_path: Path[status.path],
          userns_toggle_path: "/missing/userns"
        )

        restrictions.any? { |entry| entry.includes?("no_new_privs") }.should be_true
        restrictions.any? { |entry| entry.includes?("seccomp") }.should be_true
      ensure
        filesystems.close
        status.close
      end
    end
  end

  describe ".bind_mount_file" do
    it "creates a target file for bind-mounting" do
      source = File.tempfile("source")
      begin
        source.print("data")
        source.flush

        target_root = Path[File.tempname("bind-mount-root")]
        File.delete(target_root) if File.exists?(target_root)
        FileUtils.mkdir_p(target_root)
        target = target_root / "file"

        begin
          Bootstrap::SysrootNamespace.bind_mount_file(source.path, target)
        rescue Bootstrap::SysrootNamespace::NamespaceError
          # Ignore mount failures in constrained environments; we only validate
          # that the target file is created for the bind mount.
        end

        File.exists?(target).should be_true
      ensure
        source.close
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

  describe ".ensure_unprivileged_userns_clone_enabled!" do
    it "fails when unprivileged user namespaces are disabled" do
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
  end

  restrictions = Bootstrap::SysrootNamespace.collect_restrictions
  if restrictions.empty?
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
    reason = restrictions.join("; ")
    pending "unshares namespaces in a subprocess when enabled (#{reason})" do
    end
  end

  if restrictions.empty?
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

      # Ensure device nodes inside the namespace are usable for write.
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(
        "crystal",
        [
          "eval",
          <<-CR
            require "./src/sysroot_namespace"
            rootfs = #{rootfs.inspect}
            Bootstrap::SysrootNamespace.enter_rootfs(rootfs)
            File.write("/dev/null", "")
          CR
        ],
        chdir: Path[__DIR__] / "..",
        output: stdout,
        error: stderr
      )

      unless status.success?
        raise "Namespace device usability failed (exit=#{status.exit_code}). stdout=#{stdout} stderr=#{stderr}"
      end

      # Ensure /dev/std* symlinks exist and point to fds.
      symlink_status = Process.run(
        "crystal",
        [
          "eval",
          <<-CR
            require "./src/sysroot_namespace"
            rootfs = #{rootfs.inspect}
            Bootstrap::SysrootNamespace.enter_rootfs(rootfs)
            %w(/dev/stdin /dev/stdout /dev/stderr).each do |path|
              raise "missing symlink \#{path}" unless File.symlink?(path)
            end
          CR
        ],
        chdir: Path[__DIR__] / "..",
      )
      unless symlink_status.success?
        raise "Namespace stdio symlinks missing (exit=#{symlink_status.exit_code})"
      end
    end
  else
    reason = restrictions.join("; ")
    pending "enters a rootfs with namespaces when supported (#{reason})" do
    end
  end
end
