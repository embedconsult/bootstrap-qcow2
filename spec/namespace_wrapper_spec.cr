require "./spec_helper"
require "../src/namespace_wrapper"

private def user_namespace_available? : Bool
  pid = Process.fork do
    begin
      Bootstrap::Syscalls.unshare(Bootstrap::Syscalls::CLONE_NEWUSER)
      exit 0
    rescue ex : Errno
      exit ex.errno == Errno::EPERM ? 1 : 2
    rescue
      exit 2
    end
  end

  status = Process.wait(pid)
  case status.exit_code
  when 0
    true
  when 1
    false
  else
    raise "Unexpected failure probing user namespaces (exit #{status.exit_code})"
  end
end

describe Bootstrap::NamespaceWrapper do
  describe ".unshare_user_and_mount" do
    it "unshares and writes proc maps when user namespaces are available" do
      pending "requires unprivileged user namespaces (see README)" unless user_namespace_available?

      pid = Process.fork do
        Bootstrap::NamespaceWrapper.unshare_user_and_mount(Process.uid, Process.gid)
        exit 0
      rescue
        exit 1
      end

      status = Process.wait(pid)
      status.exit_code.should eq 0
    end
  end
end
