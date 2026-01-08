require "spec"
require "log"
require "path"
require "../src/bootstrap-qcow2"
require "../src/sysroot_builder"
require "../src/sysroot_runner_lib"
require "../src/syscalls"
# require "../src/hello-efi"
require "../src/inproc_llvm"

Log.setup_from_env

def namespace_maps_available?(require_mount : Bool = false) : Bool
  pid = Process.fork do
    begin
      flags = Bootstrap::Syscalls::CLONE_NEWUSER
      flags |= Bootstrap::Syscalls::CLONE_NEWNS if require_mount
      Bootstrap::Syscalls.unshare(flags)
      Bootstrap::Syscalls.write_proc_self_map("setgroups", "deny")
      Bootstrap::Syscalls.write_proc_self_map("uid_map", "0 #{Process.uid} 1")
      Bootstrap::Syscalls.write_proc_self_map("gid_map", "0 #{Process.gid} 1")
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
