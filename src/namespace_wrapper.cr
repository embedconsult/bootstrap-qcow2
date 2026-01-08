require "./syscalls"

module Bootstrap
  class NamespaceWrapper
    def self.unshare_user_and_mount(uid : Int32, gid : Int32)
      Syscalls.unshare(Syscalls::CLONE_NEWUSER | Syscalls::CLONE_NEWNS)
      Syscalls.write_proc_self_map("setgroups", "deny")
      Syscalls.write_proc_self_map("uid_map", "0 #{uid} 1")
      Syscalls.write_proc_self_map("gid_map", "0 #{gid} 1")
    end
  end
end
