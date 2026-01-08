require "./syscalls"

module Bootstrap
  class NamespaceWrapper
    # Unshare user/mount namespaces and install UID/GID maps for the caller.
    def self.unshare_user_and_mount(uid : Int32, gid : Int32)
      Syscalls.unshare(Syscalls::CLONE_NEWUSER | Syscalls::CLONE_NEWNS)
      Syscalls.write_proc_self_map("setgroups", "deny")
      Syscalls.write_proc_self_map("uid_map", "0 #{uid} 1")
      Syscalls.write_proc_self_map("gid_map", "0 #{gid} 1")
    end

    # Enter a new user+mount namespace, pivot into the provided rootfs, and run a block.
    # The old root is detached during ensure to avoid leaving stale mount points.
    def self.with_updated_root(rootfs : String, uid : Int32 = Syscalls.euid.to_i, gid : Int32 = Syscalls.egid.to_i, &block)
      unshare_user_and_mount(uid, gid)
      Syscalls.mount(nil, "/", nil, Syscalls::MS_PRIVATE | Syscalls::MS_REC)
      Syscalls.mount(rootfs, rootfs, nil, Syscalls::MS_BIND | Syscalls::MS_REC)

      put_old = File.join(rootfs, ".pivot_root")
      Dir.mkdir(put_old) unless Dir.exists?(put_old)

      pivoted = false
      begin
        Syscalls.pivot_root(rootfs, put_old)
        pivoted = true
        Syscalls.chdir("/")
        yield
      ensure
        if pivoted
          Syscalls.umount2("/.pivot_root", Syscalls::MNT_DETACH)
          Dir.delete("/.pivot_root") if Dir.exists?("/.pivot_root")
        end
      end
    end

    # Kernel capability probes for specs that can run privileged paths when supported.
    def self.userns_available? : Bool
      (Syscalls.euid == 0_u32 && cap_sys_admin?) || (unprivileged_userns_enabled? && max_user_namespaces? > 0)
    end

    def self.mount_namespace_available? : Bool
      cap_sys_admin? && File.exists?("/proc/self/ns/mnt")
    end

    def self.uts_namespace_available? : Bool
      cap_sys_admin? && File.exists?("/proc/self/ns/uts")
    end

    def self.proc_self_maps_available? : Bool
      File.exists?("#{Syscalls::PROC_SELF_ROOT}/uid_map") &&
        File.exists?("#{Syscalls::PROC_SELF_ROOT}/gid_map") &&
        File.exists?("#{Syscalls::PROC_SELF_ROOT}/setgroups")
    end

    private def self.unprivileged_userns_enabled? : Bool
      path = "/proc/sys/kernel/unprivileged_userns_clone"
      return false unless File.exists?(path)
      File.read(path).strip == "1"
    end

    private def self.max_user_namespaces? : Int32
      path = "/proc/sys/user/max_user_namespaces"
      return 0 unless File.exists?(path)
      File.read(path).strip.to_i
    end

    private def self.cap_sys_admin? : Bool
      path = "/proc/self/status"
      return false unless File.exists?(path)
      caps_line = File.read(path).lines.find(&.starts_with?("CapEff:"))
      return false unless caps_line
      caps_hex = caps_line.split.last?
      return false unless caps_hex
      caps = caps_hex.to_u64(16)
      (caps & (1_u64 << 21)) != 0
    end
  end
end
