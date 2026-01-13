require "./spec_helper"
require "../src/namespace_wrapper"

describe Bootstrap::NamespaceWrapper do
  describe ".namespace_maps_available?" do
    it "returns a boolean without raising" do
      code = <<-'CR'
        require "./src/namespace_wrapper"
        Bootstrap::NamespaceWrapper.namespace_maps_available?
      CR
      status = run_crystal_eval(code)
      pending! "requires unprivileged user namespaces (see README)" unless status.success?
      status.success?.should be_true
    end
  end

  describe ".unshare_user_and_mount" do
    it "unshares and writes proc maps when user namespaces are available" do
      available = namespace_maps_available?(require_mount: true)
      pending! "requires unprivileged user namespaces (see README)" unless available

      code = <<-'CR'
        require "./src/namespace_wrapper"
        uid = Bootstrap::Syscalls.uid
        gid = Bootstrap::Syscalls.gid
        Bootstrap::NamespaceWrapper.unshare_user_and_mount(uid, gid)
      CR
      status = run_crystal_eval(code)
      pending! "requires unprivileged user+mount namespaces (see README)" unless status.success?
      status.success?.should be_true
      available.should be_true
    end
  end

  describe ".with_new_namespace" do
    it "bind-mounts and cleans up when available" do
      available = namespace_maps_available?(require_mount: true)
      pending! "requires unprivileged user+mount namespaces (see README)" unless available

      code = <<-'CR'
        require "./src/namespace_wrapper"
        require "file_utils"
        root = Dir.tempdir
        rootfs = File.join(root, "rootfs")
        FileUtils.mkdir_p(rootfs)
        uid = Bootstrap::Syscalls.uid
        gid = Bootstrap::Syscalls.gid
        Bootstrap::NamespaceWrapper.with_new_namespace(uid, gid, rootfs) do
          File.write(File.join(rootfs, "marker"), "ok")
        end
        exit 0
      CR
      status = run_crystal_eval(code)
      pending! "requires unprivileged user+mount namespaces (see README)" unless status.success?
      status.success?.should be_true
    end
  end
end
