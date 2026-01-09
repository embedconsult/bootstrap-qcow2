require "file_utils"
require "log"
require "path"
require "process"

lib LibC
  fun unshare(flags : Int32) : Int32
  fun pivot_root(new_root : UInt8*, put_old : UInt8*) : Int32
  fun mount(source : UInt8*, target : UInt8*, filesystemtype : UInt8*, mountflags : UInt64, data : Void*) : Int32
  fun umount2(target : UInt8*, flags : Int32) : Int32
  fun getuid : UInt32
  fun getgid : UInt32
end

module Bootstrap
  # SysrootNamespace encapsulates user/mount namespaces and optional rootfs
  # mounting to provide a sudo-less entrypoint into the sysroot when supported
  # by the kernel.
  class SysrootNamespace
    USERNS_TOGGLE_PATH  = "/proc/sys/kernel/unprivileged_userns_clone"
    DEFAULT_COORDINATOR = "/usr/local/bin/sysroot_runner_main.cr"

    CLONE_NEWNS     = 0x00020000
    CLONE_NEWCGROUP = 0x02000000
    CLONE_NEWUTS    = 0x04000000
    CLONE_NEWIPC    = 0x08000000
    CLONE_NEWUSER   = 0x10000000
    CLONE_NEWNET    = 0x40000000

    MS_BIND    =  4096_u64
    MS_REC     = 16384_u64
    MS_PRIVATE = (1_u64 << 18)
    MNT_DETACH = 2

    class NamespaceError < RuntimeError
    end

    def self.unprivileged_userns_clone_enabled?(path : String = USERNS_TOGGLE_PATH) : Bool
      return true unless File.exists?(path)
      parse_kernel_toggle(File.read(path))
    end

    def self.ensure_unprivileged_userns_clone_enabled!(path : String = USERNS_TOGGLE_PATH)
      return if unprivileged_userns_clone_enabled?(path)
      raise NamespaceError.new(<<-MSG)
        Unprivileged user namespaces are disabled (unprivileged_userns_clone=0).
        Enable them by running:
          sudo sysctl -w kernel.unprivileged_userns_clone=1
        or run this entrypoint with sudo to use the existing chroot flow.
      MSG
    end

    def self.parse_kernel_toggle(contents : String) : Bool
      value = contents.strip
      case value
      when "1"
        true
      when "0"
        false
      else
        raise NamespaceError.new("Unexpected value for unprivileged_userns_clone: #{value.inspect}")
      end
    end

    def self.unshare_namespaces(use_cgroup : Bool = false, uid : Int32 = LibC.getuid.to_i32, gid : Int32 = LibC.getgid.to_i32)
      ensure_unprivileged_userns_clone_enabled!
      flags = CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWNET
      flags |= CLONE_NEWCGROUP if use_cgroup
      unshare!(flags)
      setup_user_mapping(uid, gid)
      make_mounts_private
    end

    def self.enter_rootfs(rootfs : String, bind_proc : Bool = false, bind_dev : Bool = false, bind_sys : Bool = false, use_cgroup : Bool = false, prefer_pivot_root : Bool = true)
      unshare_namespaces(use_cgroup: use_cgroup)
      root_path = Path[rootfs].expand
      bind_mount_rootfs(root_path)
      bind_mounts(root_path, bind_proc: bind_proc, bind_dev: bind_dev, bind_sys: bind_sys)

      unless prefer_pivot_root && pivot_root(root_path)
        Log.warn { "pivot_root unavailable; falling back to chroot" }
        Process.chroot(root_path.to_s)
        Dir.cd("/")
      end
    end

    private def self.bind_mount_rootfs(rootfs : Path)
      mount_call(rootfs.to_s, rootfs.to_s, nil, MS_BIND | MS_REC, nil)
    end

    private def self.bind_mounts(rootfs : Path, bind_proc : Bool, bind_dev : Bool, bind_sys : Bool)
      bind_mount("/proc", rootfs / "proc") if bind_proc
      bind_mount("/dev", rootfs / "dev") if bind_dev
      bind_mount("/sys", rootfs / "sys") if bind_sys
    end

    private def self.bind_mount(source : String, target : Path)
      FileUtils.mkdir_p(target)
      mount_call(source, target.to_s, nil, MS_BIND | MS_REC, nil)
    end

    private def self.pivot_root(rootfs : Path) : Bool
      put_old = rootfs / ".pivot_root"
      FileUtils.mkdir_p(put_old)
      if LibC.pivot_root(rootfs.to_s.to_unsafe, put_old.to_s.to_unsafe) != 0
        errno = Errno.value
        Log.warn { "pivot_root failed: #{errno} #{errno.message}" }
        return false
      end
      Dir.cd("/")
      if LibC.umount2("/.pivot_root".to_unsafe, MNT_DETACH) != 0
        errno = Errno.value
        raise NamespaceError.new("Failed to unmount old root: #{errno} #{errno.message}")
      end
      Dir.rmdir("/.pivot_root") if Dir.exists?("/.pivot_root")
      true
    end

    private def self.make_mounts_private
      mount_call(nil, "/", nil, MS_REC | MS_PRIVATE, nil)
    end

    private def self.setup_user_mapping(uid : Int32, gid : Int32)
      setgroups_path = "/proc/self/setgroups"
      if File.exists?(setgroups_path)
        File.write(setgroups_path, "deny\n")
      end
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
          unshare failed with EPERM. Ensure your kernel allows unprivileged user namespaces
          (check #{USERNS_TOGGLE_PATH}) or run this entrypoint with sudo.
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
  end
end
