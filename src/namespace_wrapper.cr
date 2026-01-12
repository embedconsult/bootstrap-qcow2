require "log"
require "./syscalls"

module Bootstrap
  class NamespaceWrapper
    def self.namespace_maps_available?(require_mount : Bool = false, logger : Log = Log.for(self)) : Bool
      flags = Syscalls::CLONE_NEWUSER
      flags |= Syscalls::CLONE_NEWNS if require_mount
      begin
        Syscalls.unshare(flags)
        Syscalls.write_proc_self_map("setgroups", "deny")
        Syscalls.write_proc_self_map("uid_map", "0 #{Syscalls.uid} 1")
        Syscalls.write_proc_self_map("gid_map", "0 #{Syscalls.gid} 1")
      rescue ex : RuntimeError
        if ex.os_error == Errno::EPERM
          logger.warn { "Unprivileged namespaces are disabled (EPERM). See README kernel/sysctl setup." }
          return false
        end
        raise
      rescue ex : Exception
        logger.warn { "Namespace probe failed: #{ex.message}" }
        return false
      end
      true
    end

    def self.unshare_user_and_mount(uid : Int32, gid : Int32, logger : Log = Log.for(self))
      begin
        Syscalls.unshare(Syscalls::CLONE_NEWUSER | Syscalls::CLONE_NEWNS)
      rescue ex : RuntimeError
        if ex.os_error == Errno::EPERM
          logger.warn { "Unshare denied (EPERM). Enable CONFIG_USER_NS and kernel.unprivileged_userns_clone=1." }
        end
        raise
      end
      Syscalls.write_proc_self_map("setgroups", "deny")
      Syscalls.write_proc_self_map("uid_map", "0 #{uid} 1")
      Syscalls.write_proc_self_map("gid_map", "0 #{gid} 1")
    end

    def self.with_new_namespace(uid : Int32, gid : Int32, rootfs : String, logger : Log = Log.for(self), &)
      unshare_user_and_mount(uid, gid, logger)
      Syscalls.mount(nil, "/", nil, Syscalls::MS_PRIVATE | Syscalls::MS_REC)
      Syscalls.mount(rootfs, rootfs, nil, Syscalls::MS_BIND | Syscalls::MS_REC)
      begin
        yield
      ensure
        begin
          Syscalls.umount2(rootfs, Syscalls::MNT_DETACH)
        rescue ex : RuntimeError
          logger.warn { "Failed to detach mount #{rootfs}: #{ex.message}" }
        end
      end
    end
  end
end
