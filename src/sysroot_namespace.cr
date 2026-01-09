require "file_utils"
require "path"

lib LibC
  # Linux syscalls documented in https://docs.kernel.org/:
  # - unshare: https://docs.kernel.org/userspace-api/feature-test-macros.html
  # - pivot_root: https://docs.kernel.org/filesystems/sharedsubtree.html
  # - mount: https://docs.kernel.org/filesystems/mount_api.html
  # - getuid/getgid: https://docs.kernel.org/userspace-api/uidgid.html
  fun unshare(flags : Int32) : Int32
  fun pivot_root(new_root : UInt8*, put_old : UInt8*) : Int32
  fun mount(source : UInt8*, target : UInt8*, filesystemtype : UInt8*, mountflags : UInt64, data : Void*) : Int32
  fun getuid : UInt32
  fun getgid : UInt32
end

module Bootstrap
  # SysrootNamespace encapsulates user/mount namespaces and optional rootfs
  # mounting to provide a sudo-less entrypoint into the sysroot when supported
  # by the kernel.
  class SysrootNamespace
    USERNS_TOGGLE_PATH = "/proc/sys/kernel/unprivileged_userns_clone"

    # Namespace and mount constants from Linux headers:
    # - linux/sched.h (CLONE_NEW*)
    # - linux/mount.h (MS_*)
    CLONE_NEWNS   = 0x00020000
    CLONE_NEWUTS  = 0x04000000
    CLONE_NEWIPC  = 0x08000000
    CLONE_NEWUSER = 0x10000000
    CLONE_NEWNET  = 0x40000000

    MS_BIND    =  4096_u64
    MS_REC     = 16384_u64
    MS_PRIVATE = (1_u64 << 18)

    class NamespaceError < RuntimeError
    end

    # Returns true when unprivileged user namespace cloning is enabled.
    # If the toggle path does not exist or contains an unexpected value,
    # default to false for safety.
    def self.unprivileged_userns_clone_enabled?(path : String = USERNS_TOGGLE_PATH) : Bool
      return false unless File.exists?(path)
      value = File.read(path).strip
      case value
      when "1"
        true
      when "0"
        false
      else
        false
      end
    end

    # Raises a NamespaceError with a clear diagnostic when user namespaces are
    # disabled via the kernel toggle.
    def self.ensure_unprivileged_userns_clone_enabled!(path : String = USERNS_TOGGLE_PATH)
      return if unprivileged_userns_clone_enabled?(path)
      raise NamespaceError.new(<<-MSG)
        Unprivileged user namespaces are disabled (unprivileged_userns_clone=0).
        Enable them by running:
          sudo sysctl -w kernel.unprivileged_userns_clone=1
      MSG
    end

    # Create a new user namespace, map the current uid/gid, and then unshare
    # the remaining namespaces. This preserves the common unprivileged flow:
    # unshare(CLONE_NEWUSER) -> write uid/gid maps -> unshare remaining flags.
    def self.unshare_namespaces(uid : Int32 = LibC.getuid.to_i32, gid : Int32 = LibC.getgid.to_i32)
      ensure_unprivileged_userns_clone_enabled!
      unshare!(CLONE_NEWUSER)
      setup_user_mapping(uid, gid)
      unshare!(CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWNET)
      make_mounts_private
    end

    # Enter the provided rootfs by unsharing namespaces, bind-mounting the
    # rootfs, mounting /proc, /dev, and /sys, then pivoting
    # into the new root.
    def self.enter_rootfs(rootfs : String)
      unshare_namespaces
      root_path = Path[rootfs].expand
      bind_mount_rootfs(root_path)
      mount_virtual_fs(root_path)

      pivot_root!(root_path)
    end

    # pivot_root requires the new root to be a mount point. A bind mount creates
    # a dedicated mount point without depending on a specific filesystem type.
    private def self.bind_mount_rootfs(rootfs : Path)
      mount_call(rootfs.to_s, rootfs.to_s, nil, MS_BIND | MS_REC, nil)
    end

    # Mount kernel-provided virtual filesystems inside the new rootfs.
    private def self.mount_virtual_fs(rootfs : Path)
      mount_fs("proc", rootfs / "proc", "proc")
      mount_fs("sysfs", rootfs / "sys", "sysfs")
      mount_fs("devtmpfs", rootfs / "dev", "devtmpfs")
      mount_fs("tmpfs", rootfs / "tmp", "tmpfs")
    end

    private def self.pivot_root!(rootfs : Path)
      put_old = rootfs / ".pivot_root"
      FileUtils.mkdir_p(put_old)
      if LibC.pivot_root(rootfs.to_s.to_unsafe, put_old.to_s.to_unsafe) != 0
        errno = Errno.value
        raise NamespaceError.new("pivot_root failed: #{errno} #{errno.message}")
      end
      Dir.cd("/")
    end

    # Ensure mount propagation is private so the rootfs bind mount does not
    # propagate back into the host mount namespace.
    private def self.make_mounts_private
      mount_call(nil, "/", nil, MS_REC | MS_PRIVATE, nil)
    end

    private def self.setup_user_mapping(uid : Int32, gid : Int32)
      setgroups_path = "/proc/self/setgroups"
      if File.exists?(setgroups_path)
        begin
          File.write(setgroups_path, "deny\n")
        rescue error : File::AccessDeniedError
          raise NamespaceError.new("Failed to write #{setgroups_path}: #{error.message}. This can be caused by LSM policies (e.g., AppArmor).")
        end
      elsif LibC.getuid != 0
        raise NamespaceError.new("Missing #{setgroups_path}; unprivileged user namespaces are not available without uid 0.")
      end
      # Mapping uid/gid is required so the process gains CAP_SYS_ADMIN in the
      # new user namespace, which is needed for mount and pivot_root calls.
      write_id_map("/proc/self/uid_map", uid)
      write_id_map("/proc/self/gid_map", gid)
    end

    private def self.write_id_map(path : String, outside_id : Int32)
      File.write(path, "0 #{outside_id} 1\n")
    end

    private def self.unshare!(flags : Int32)
      if LibC.unshare(flags) != 0
        errno = Errno.value
        message = unshare_error_message(errno)
        raise NamespaceError.new(message)
      end
    end

    private def self.unshare_error_message(errno : Errno) : String
      case errno
      when Errno::EPERM
        <<-MSG
          unshare failed with EPERM. This usually means unprivileged user namespaces
          are disabled (check #{USERNS_TOGGLE_PATH}) or the kernel restricts
          namespace creation for the current user.
        MSG
      else
        "unshare failed: #{errno} #{errno.message}"
      end
    end

    private def self.mount_call(source : String?, target : String, fstype : String?, flags : UInt64, data : String?)
      source_ptr = source ? source.to_unsafe : Pointer(UInt8).null
      fstype_ptr = fstype ? fstype.to_unsafe : Pointer(UInt8).null
      data_ptr = data ? data.to_unsafe.as(Void*) : Pointer(Void).null
      if LibC.mount(source_ptr, target.to_unsafe, fstype_ptr, flags, data_ptr) != 0
        errno = Errno.value
        raise NamespaceError.new("mount failed for #{target}: #{errno} #{errno.message}")
      end
    end

    private def self.mount_fs(source : String, target : Path, fstype : String)
      unless filesystem_available?(fstype)
        raise NamespaceError.new("Filesystem type #{fstype} is not available; check /proc/filesystems.")
      end
      FileUtils.mkdir_p(target)
      mount_call(source, target.to_s, fstype, 0_u64, nil)
    end

    private def self.filesystem_available?(fstype : String) : Bool
      File.read_lines("/proc/filesystems").any? do |line|
        line.split.last? == fstype
      end
    end
  end
end
