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

    it "treats missing files as enabled" do
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

  if Bootstrap::SysrootNamespace.unprivileged_userns_clone_enabled?
    it "unshares namespaces in a subprocess when enabled" do
      status = Process.run(
        "crystal",
        ["eval", "require \"./src/sysroot_namespace\"; Bootstrap::SysrootNamespace.unshare_namespaces"],
        chdir: Path[__DIR__] / ".."
      )

      status.success?.should be_true
    end

    it "enters a rootfs with namespaces when supported" do
      rootfs = File.tempname("sysroot-namespace")
      FileUtils.mkdir_p(rootfs)

      status = Process.run(
        "crystal",
        ["eval", "require \"./src/sysroot_namespace\"; Bootstrap::SysrootNamespace.enter_rootfs(#{rootfs.inspect})"],
        chdir: Path[__DIR__] / ".."
      )

      status.success?.should be_true
    end
  else
    pending "unshares namespaces in a subprocess when enabled (kernel does not allow unprivileged user namespaces)" do
    end

    pending "enters a rootfs with namespaces when supported (kernel does not allow unprivileged user namespaces)" do
    end
  end
end
