require "./spec_helper"
require "../src/namespace_wrapper"

describe Bootstrap::NamespaceWrapper do
  describe ".unshare_user_and_mount" do
    it "unshares and writes proc maps when user namespaces are available" do
      available = namespace_maps_available?(require_mount: true)
      pending "requires unprivileged user namespaces (see README)" unless available

      pid = Process.fork do
        Bootstrap::NamespaceWrapper.unshare_user_and_mount(Process.uid, Process.gid)
        exit 0
      rescue
        exit 1
      end

      status = Process.wait(pid)
      status.exit_code.should eq 0
      available.should be_true
    end
  end
end
