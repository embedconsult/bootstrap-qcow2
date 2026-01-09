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
  child = Process.fork do
    begin
      flags = Bootstrap::Syscalls::CLONE_NEWUSER
      flags |= Bootstrap::Syscalls::CLONE_NEWNS if require_mount
      Bootstrap::Syscalls.unshare(flags)
      Bootstrap::Syscalls.write_proc_self_map("setgroups", "deny")
      uid = Bootstrap::Syscalls.uid
      gid = Bootstrap::Syscalls.gid
      Bootstrap::Syscalls.write_proc_self_map("uid_map", "0 #{uid} 1")
      Bootstrap::Syscalls.write_proc_self_map("gid_map", "0 #{gid} 1")
      exit 0
    rescue ex : RuntimeError
      exit ex.os_error == Errno::EPERM ? 1 : 2
    rescue
      exit 2
    end
  end

  status = child.wait
  case status.exit_code
  when 0
    true
  else
    false
  end
end
