require "file_utils"
require "./spec_helper"

describe Bootstrap::SysrootNamespace do
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

  if Bootstrap::SysrootNamespace.unprivileged_userns_clone_enabled?
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
    pending "unshares namespaces in a subprocess when enabled (kernel does not allow unprivileged user namespaces)" do
    end
  end

  if Bootstrap::SysrootNamespace.unprivileged_userns_clone_enabled?
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
    pending "enters a rootfs with namespaces when supported (kernel does not allow unprivileged user namespaces)" do
    end
  end
end
