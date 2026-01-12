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
    # Linux kernel sysctl: Documentation/admin-guide/sysctl/kernel.rst
    USERNS_TOGGLE_ENABLED_VALUE  = "1"
    USERNS_TOGGLE_DISABLED_VALUE = "0"
    APPARMOR_USERNS_SYSCTL_PATH  = "/proc/sys/kernel/apparmor_restrict_unprivileged_userns"
    # Linux kernel sysctl: Documentation/admin-guide/LSM/apparmor.rst
    APPARMOR_USERNS_RESTRICTED_VALUE = "1"

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
    MS_RDONLY  = (1_u64 << 0)
    MS_NOSUID  = (1_u64 << 1)
    MS_NODEV   = (1_u64 << 2)
    MS_NOEXEC  = (1_u64 << 3)
    MS_REMOUNT = (1_u64 << 5)
    MS_PRIVATE = (1_u64 << 18)

    class NamespaceError < RuntimeError
    end

    # Collects restriction messages that can prevent user-namespace mounts of
    # proc/sys/dev from succeeding on the current host.
    def self.collect_restrictions(proc_root : Path = Path["/proc"],
                                  filesystems_path : Path = Path["/proc/filesystems"],
                                  proc_status_path : Path = Path["/proc/self/status"],
                                  userns_toggle_path : String = USERNS_TOGGLE_PATH) : Array(String)
      restrictions = [] of String
      restrictions << "kernel.unprivileged_userns_clone is disabled" unless unprivileged_userns_clone_enabled?(userns_toggle_path)

      missing_fs = missing_filesystems(filesystems_path, %w(proc sysfs tmpfs))
      unless missing_fs.empty?
        restrictions << "missing filesystem support: #{missing_fs.join(", ")}"
      end

      if no_new_privs?(proc_status_path)
        restrictions << "no_new_privs is set; user namespace uid/gid mappings may be blocked by the container runtime"
      end

      if (seccomp = seccomp_mode(proc_status_path)) && seccomp != "0"
        restrictions << "seccomp is enforced (mode #{seccomp}); setgroups/uid_map writes or sockets may be blocked"
      end

      if (error = userns_setgroups_probe_error)
        restrictions << "user namespace setgroups mapping failed: #{error}"
      end

      if (device_error = device_bind_probe_error)
        restrictions << "device bind/remount failed inside user namespace: #{device_error}"
      end

      if (apparmor_note = apparmor_restriction)
        restrictions << apparmor_note
      end
      restrictions
    end

    # Returns a list of filesystem types that are missing from /proc/filesystems.
    def self.missing_filesystems(path : Path, required : Array(String)) : Array(String)
      return required unless File.exists?(path)
      available = File.read_lines(path).map { |line| line.split.last? }.compact
      required.reject { |fs| available.includes?(fs) }
    end

    # Returns true when NoNewPrivs is set on the current process.
    def self.no_new_privs?(status_path : Path = Path["/proc/self/status"]) : Bool
      value = proc_status_value(status_path, "NoNewPrivs")
      value == "1"
    end

    # Returns the seccomp mode from /proc/self/status, or nil when absent.
    def self.seccomp_mode(status_path : Path = Path["/proc/self/status"]) : String?
      proc_status_value(status_path, "Seccomp")
    end

    # Attempts to unshare a user namespace and write /proc/self/setgroups in a
    # subprocess to detect seccomp/LSM restrictions. Returns an error string
    # when the probe fails, or nil when it succeeds.
    def self.userns_setgroups_probe_error : String?
      reader, writer = IO.pipe
      pid = LibC.fork
      return "unshare probe not available: fork failed" if pid < 0

      if pid == 0
        reader.close
        begin
          unshare_namespaces
          writer.puts "ok"
          LibC._exit(0)
        rescue ex
          writer.puts ex.message
          LibC._exit(1)
        end
      end

      writer.close
      status_code = uninitialized Int32
      waited = LibC.waitpid(pid, pointerof(status_code), 0)
      output = reader.gets_to_end.to_s.strip
      reader.close

      return "unshare probe failed: waitpid errno=#{Errno.value}" if waited < 0

      # Decode wait status per POSIX: lower 7 bits for signal, next 8 for exit code.
      signaled = (status_code & 0x7f) != 0
      exit_status = (status_code & 0xff00) >> 8
      return nil if !signaled && exit_status == 0

      detail = signaled ? "signaled" : "exit=#{exit_status}"
      detail = "#{detail} #{output}".strip unless output.empty?
      "unshare probe failed #{detail}".strip
    end

    # Reads a single value from /proc/self/status.
    private def self.proc_status_value(path : Path, key : String) : String?
      return nil unless File.exists?(path)
      line = File.read_lines(path).find { |entry| entry.starts_with?("#{key}:") }
      return nil unless line
      line.split(/\s+/)[1]?
    rescue
      nil
    end

    # Returns a restriction message if AppArmor confinement is detected.
    # This checks the current label and the sysctl that restricts unprivileged
    # user namespaces.
    def self.apparmor_restriction(current_path : Path = Path["/proc/self/attr/current"],
                                  userns_sysctl_path : Path = Path[APPARMOR_USERNS_SYSCTL_PATH]) : String?
      if File.exists?(userns_sysctl_path)
        value = File.read(userns_sysctl_path).strip
        if value == APPARMOR_USERNS_RESTRICTED_VALUE
          return "AppArmor restricts unprivileged user namespaces (kernel.apparmor_restrict_unprivileged_userns=1)"
        end
      end
      return nil unless File.exists?(current_path)
      status = File.read(current_path).strip
      return nil if status.empty? || status == "unconfined"
      "AppArmor confinement detected (#{status}); process must be unconfined"
    rescue
      nil
    end

    # Returns true when unprivileged user namespace cloning is enabled.
    # If the toggle path does not exist or contains an unexpected value,
    # default to false for safety.
    def self.unprivileged_userns_clone_enabled?(path : String = USERNS_TOGGLE_PATH) : Bool
      return false unless File.exists?(path)
      value = File.read(path).strip
      case value
      when USERNS_TOGGLE_ENABLED_VALUE
        true
      when USERNS_TOGGLE_DISABLED_VALUE
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
    # the mount namespace. This preserves the common unprivileged flow:
    # unshare(CLONE_NEWUSER) -> write uid/gid maps -> unshare(CLONE_NEWNS).
    def self.unshare_namespaces(uid : Int32 = LibC.getuid.to_i32, gid : Int32 = LibC.getgid.to_i32)
      ensure_unprivileged_userns_clone_enabled!
      unshare!(CLONE_NEWUSER)
      setup_user_mapping(uid, gid)
      unshare!(CLONE_NEWNS)
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
      mount_proc(rootfs / "proc")
      mount_sys(rootfs / "sys")
      mount_dev(rootfs / "dev", rootfs / "proc")
      mount_tmpfs(rootfs / "tmp")
      mount_tmpfs(rootfs / "dev" / "shm")
    end

    # Performs pivot_root with an `.pivot_root` directory inside *rootfs*.
    # Raises NamespaceError if pivot_root fails.
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

    # Writes uid/gid mappings for the current process in the user namespace.
    # Raises NamespaceError when mappings cannot be applied.
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

    # Writes a single-id mapping to the provided uid/gid map file.
    private def self.write_id_map(path : String, outside_id : Int32)
      File.write(path, "0 #{outside_id} 1\n")
    end

    # Calls unshare(2) and raises NamespaceError on failure.
    private def self.unshare!(flags : Int32)
      if LibC.unshare(flags) != 0
        errno = Errno.value
        message = unshare_error_message(errno)
        raise NamespaceError.new(message)
      end
    end

    # Returns a user-facing error message for unshare failures.
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

    # Calls mount(2) with the provided parameters and raises on failure.
    private def self.mount_call(source : String?, target : String, fstype : String?, flags : UInt64, data : String?)
      source_ptr = source ? source.to_unsafe : Pointer(UInt8).null
      fstype_ptr = fstype ? fstype.to_unsafe : Pointer(UInt8).null
      data_ptr = data ? data.to_unsafe.as(Void*) : Pointer(Void).null
      if LibC.mount(source_ptr, target.to_unsafe, fstype_ptr, flags, data_ptr) != 0
        errno = Errno.value
        raise NamespaceError.new("mount failed for #{target}: #{errno} #{errno.message}")
      end
    end

    # Mounts a filesystem by type after verifying it appears in /proc/filesystems.
    private def self.mount_fs(source : String, target : Path, fstype : String)
      unless filesystem_available?(fstype)
        raise NamespaceError.new("Filesystem type #{fstype} is not available; check /proc/filesystems.")
      end
      FileUtils.mkdir_p(target)
      mount_call(source, target.to_s, fstype, 0_u64, nil)
    end

    # Bind-mounts /proc into the new root and remounts it with safe flags.
    # We avoid a read-only remount because EPERM was observed during the
    # remount attempt on some kernels.
    private def self.mount_proc(target : Path)
      FileUtils.mkdir_p(target)
      bind_mount("/proc", target)
      mount_call(nil, target.to_s, nil, MS_REMOUNT | MS_NOSUID | MS_NODEV | MS_NOEXEC | MS_BIND, nil)
    end

    # Bind-mounts /sys into the new root.
    private def self.mount_sys(target : Path)
      unless filesystem_available?("sysfs")
        raise NamespaceError.new("Filesystem type sysfs is not available; check /proc/filesystems.")
      end
      FileUtils.mkdir_p(target)
      bind_mount("/sys", target)
    end

    # Creates a tmpfs-backed /dev and bind-mounts a small set of device nodes.
    # The minimal device set supports basic process I/O, entropy, and dynamic
    # linking without exposing full host /dev or pseudo-terminals. /dev stays
    # MS_NODEV so new device nodes cannot be created; the curated bind mounts
    # are remounted as device-enabled entries instead.
    private def self.mount_dev(target : Path, proc_root : Path)
      mount_tmpfs(target)
      bind_mount_device("/dev/null", target / "null")
      bind_mount_device("/dev/zero", target / "zero")
      bind_mount_device("/dev/random", target / "random")
      bind_mount_device("/dev/urandom", target / "urandom")
      if File.exists?("/dev/tty")
        bind_mount_device("/dev/tty", target / "tty")
      end
      bind_mount(proc_root / "self" / "fd", target / "fd")
      FileUtils.ln_s("/proc/self/fd/0", target / "stdin")
      FileUtils.ln_s("/proc/self/fd/1", target / "stdout")
      FileUtils.ln_s("/proc/self/fd/2", target / "stderr")
    end

    # Mounts a tmpfs at the target path with safe defaults (including MS_NODEV),
    # optionally overriding mount flags for special cases (like /dev needing
    # device nodes during bootstrap).
    private def self.mount_tmpfs(target : Path, flags : UInt64 = MS_NOSUID | MS_NODEV)
      unless filesystem_available?("tmpfs")
        raise NamespaceError.new("Filesystem type tmpfs is not available; check /proc/filesystems.")
      end
      FileUtils.mkdir_p(target)
      mount_call("tmpfs", target.to_s, "tmpfs", flags, nil)
      mount_call(nil, target.to_s, nil, MS_REMOUNT | flags, nil)
    end

    # Bind-mounts a source path to the target path.
    private def self.bind_mount(source : String | Path, target : Path)
      FileUtils.mkdir_p(target)
      mount_call(source.to_s, target.to_s, nil, MS_BIND | MS_REC, nil)
    end

    # Bind-mounts a source file to a file target.
    def self.bind_mount_file(source : String | Path, target : Path)
      FileUtils.mkdir_p(target.parent)
      FileUtils.touch(target)
      mount_call(source.to_s, target.to_s, nil, MS_BIND, nil)
    end

    # Attempts to bind a device node inside a fresh user namespace to detect
    # environments that block device remounts under MS_NODEV. Returns an error
    # string when the probe fails, or nil when it succeeds.
    private def self.device_bind_probe_error : String?
      reader, writer = IO.pipe
      pid = LibC.fork
      return "device probe not available: fork failed" if pid < 0

      if pid == 0
        reader.close
        begin
          unshare_namespaces
          dir = Path[Dir.tempdir] / "ns-device-probe-#{Random::Secure.hex(4)}"
          FileUtils.mkdir_p(dir)
          mount_tmpfs(dir)
          bind_mount_device("/dev/null", dir / "null")
          writer.puts "ok"
          LibC._exit(0)
        rescue ex
          writer.puts ex.message
          LibC._exit(1)
        end
      end

      writer.close
      status_code = uninitialized Int32
      waited = LibC.waitpid(pid, pointerof(status_code), 0)
      output = reader.gets_to_end.to_s.strip
      reader.close

      return "device probe failed: waitpid errno=#{Errno.value}" if waited < 0

      signaled = (status_code & 0x7f) != 0
      exit_status = (status_code & 0xff00) >> 8
      return nil if !signaled && exit_status == 0

      detail = signaled ? "signaled" : "exit=#{exit_status}"
      detail = "#{detail} #{output}".strip unless output.empty?
      "device probe failed #{detail}".strip
    end

    # Parses /proc/self/mountinfo to extract mount flags for a given mount point.
    # Returns an empty array when the mount point is not found.
    private def self.mount_info_flags(mount_point : String) : Array(String)
      abs_target = File.realpath(mount_point)
      File.read_lines("/proc/self/mountinfo").each do |line|
        fields = line.split
        target = fields[4]?
        opts = fields[5]?
        next unless target && opts
        return opts.split(",") if File.realpath(target) == abs_target
      end
      [] of String
    rescue
      [] of String
    end

    # Bind-mounts a device node and remounts it without MS_NODEV so the device
    # remains usable even though /dev itself is MS_NODEV.
    private def self.bind_mount_device(source : String | Path, target : Path)
      bind_mount_file(source, target)
      preserved = mount_info_flags(source.to_s)
      flags = MS_REMOUNT | MS_BIND | MS_NOSUID
      flags |= MS_RDONLY if preserved.includes?("ro")
      flags |= MS_NOEXEC if preserved.includes?("noexec")
      mount_call(nil, target.to_s, nil, flags, nil)
    end

    # Returns true if the filesystem type appears in /proc/filesystems.
    private def self.filesystem_available?(fstype : String) : Bool
      File.read_lines("/proc/filesystems").any? do |line|
        line.split.last? == fstype
      end
    end
  end
end
