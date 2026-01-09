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
      Bootstrap::SysrootNamespace.unprivileged_userns_clone_enabled?("/missing/does/not/exist").should be_true
    end

    it "rejects unexpected toggle values" do
      file = File.tempfile("userns")
      begin
        file.print("maybe\n")
        file.flush

        expect_raises(Bootstrap::SysrootNamespace::NamespaceError) do
          Bootstrap::SysrootNamespace.unprivileged_userns_clone_enabled?(file.path)
        end
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

  it "unshares namespaces in a child process when enabled" do
    unless Bootstrap::SysrootNamespace.unprivileged_userns_clone_enabled?
      pending "Kernel does not allow unprivileged user namespaces"
    end

    status = Process.run(
      "crystal",
      ["eval", "require \"./src/sysroot_namespace\"; Bootstrap::SysrootNamespace.unshare_namespaces"],
      chdir: Path[__DIR__] / ".."
    )

    status.success?.should be_true
  end

  pending "enters a rootfs with namespaces when supported (requires unprivileged user namespaces plus mount/pivot_root support)" do
  end
end
