require "./spec_helper"
require "../src/namespace_wrapper"
require "random/secure"

private def with_tmpdir(&)
  dir = File.join(Dir.tempdir, "namespace-wrapper-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Bootstrap::NamespaceWrapper do
  describe ".unshare_user_and_mount" do
    if Bootstrap::NamespaceWrapper.userns_available? && Bootstrap::NamespaceWrapper.proc_self_maps_available?
      it "unshares and writes proc maps when user namespaces are available" do
        Bootstrap::NamespaceWrapper.unshare_user_and_mount(Bootstrap::Syscalls.euid.to_i, Bootstrap::Syscalls.egid.to_i)
      end
    else
      pending "requires unprivileged user namespaces and writable /proc/self maps (see README)" do
        Bootstrap::NamespaceWrapper.unshare_user_and_mount(0, 0)
      end
    end
  end

  describe ".with_updated_root" do
    if Bootstrap::Syscalls.euid == 0_u32 && Bootstrap::NamespaceWrapper.mount_namespace_available?
      pending "requires an isolated process to pivot root without affecting the spec runner" do
        Bootstrap::NamespaceWrapper.with_updated_root("/tmp") { }
      end
    else
      pending "requires root, mount namespaces, and a pivot-ready rootfs (see README)" do
        Bootstrap::NamespaceWrapper.with_updated_root("/tmp") { }
      end
    end
  end
end
