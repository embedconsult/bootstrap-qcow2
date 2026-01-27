require "file_utils"
require "log"
require "path"
require "./alpine_setup"
require "./cli"

lib LibC
  # Linux syscalls documented in https://docs.kernel.org/:
  # - unshare: https://docs.kernel.org/userspace-api/feature-test-macros.html
  # - pivot_root: https://docs.kernel.org/filesystems/sharedsubtree.html
  # - mount: https://docs.kernel.org/filesystems/mount_api.html
  # - umount2: https://man7.org/linux/man-pages/man2/umount.2.html
  # - getuid/getgid: https://docs.kernel.org/userspace-api/uidgid.html
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
  class SysrootNamespace < CLI
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

    MS_BIND      =  4096_u64
    MS_REC       = 16384_u64
    MS_RDONLY    = (1_u64 << 0)
    MS_NOSUID    = (1_u64 << 1)
    MS_NODEV     = (1_u64 << 2)
    MS_NOEXEC    = (1_u64 << 3)
    MS_REMOUNT   = (1_u64 << 5)
    MS_PRIVATE   = (1_u64 << 18)
    MNT_DETACH   = 2
    DEFAULT_PATH = "/opt/sysroot/bin:/opt/sysroot/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

    class NamespaceError < RuntimeError
    end

    # Summarize the sysroot namespace CLI behavior for help output.
    def self.summary : String
      "Enter a namespaced rootfs and exec a command"
    end

    # Return additional command aliases for sysroot namespace tooling.
    def self.aliases : Array(String)
      ["sysroot-namespace-check"]
    end

    # Describe help output entries for sysroot namespace commands.
    def self.help_entries : Array(Tuple(String, String))
      [
        {"sysroot-namespace", "Enter a namespaced rootfs and exec a command"},
        {"sysroot-namespace-check", "Check host namespace prerequisites"},
      ]
    end

    # Dispatch sysroot namespace subcommands by command name.
    def self.run(args : Array(String), command_name : String) : Int32
      case command_name
      when "sysroot-namespace"
        run_namespace(args)
      when "sysroot-namespace-check"
        run_namespace_check(args)
      else
        raise "Unknown sysroot namespace command #{command_name}"
      end
    end

    # Enter the rootfs namespace and exec the requested command.
    private def self.run_namespace(args : Array(String)) : Int32
      rootfs = "data/sysroot/rootfs"
      extra_binds = [] of Tuple(Path, Path)
      command = [] of String
      codex_mode = false
      run_alpine_setup = false
      parser, remaining, help = CLI.parse(args, "Usage: bq2 sysroot-namespace [options] [-- command...]") do |p|
        p.on("--rootfs=PATH", "Path to the sysroot rootfs (default: #{rootfs})") { |val| rootfs = val }
        p.on("--bind=SRC:DST", "Bind-mount SRC into DST inside the rootfs (repeatable; DST is inside rootfs)") do |val|
          parts = val.split(":", 2)
          raise "Expected --bind=SRC:DST" unless parts.size == 2
          src = Path[parts[0]].expand
          dst = normalize_bind_target(parts[1])
          extra_binds << {src, dst}
        end
        p.on("--alpine-setup", "Install Alpine packages needed to replay the sysroot build plan") do
          run_alpine_setup = true
        end
        p.on("--codex", "Bind ./codex/work to /work and default to /work/bin/codex") do
          codex_mode = true
        end
      end
      return CLI.print_help(parser) if help

      home = codex_mode ? "/work" : "/root"
      extra_env = {} of String => String
      if codex_mode
        # TODO: if there isn't a git checkout in codex/work/bootstrap-qcow2, make one
        FileUtils.mkdir_p("codex/work/bootstrap-qcow2")
        extra_binds << {Path["codex/work"], Path["/work"]}
        command = ["/bin/sh", "--login", "-c", "/work/bin/codex --add-dir /var --add-dir /opt --add-dir /workspace -C /work/bootstrap-qcow2 -s workspace-write"]
        unless remaining.empty?
          command[-1] = [command[-1], remaining.join(" ")].join(" ")
        end
        extra_env["CODEX_HOME"] = "/work/.codex"
        STDERR.puts "codex-mode: command=#{command.join(" ")}"
      else
        if remaining.empty?
          command = ["/bin/sh", "--login"]
        else
          command = remaining.not_nil!
        end
      end
      rootfs_value = rootfs.not_nil!
      unless Dir.exists?(rootfs_value)
        STDERR.puts "Workspace rootfs missing at #{rootfs_value}."
        STDERR.puts "Run ./bin/bq2 --all to generate it."
        return 1
      end
      Log.info do
        bind_summary = extra_binds.map { |(src, dst)| "#{src}:#{dst}" }.join(", ")
        "Entering namespace with rootfs=#{rootfs_value} command=#{command.join(" ")} binds=[#{bind_summary}]"
      end
      STDERR.puts "Entering namespace with rootfs=#{rootfs_value}"
      STDERR.puts "Bind mounts: #{extra_binds.map { |(src, dst)| "#{src}:#{dst}" }.join(", ")}"
      STDERR.puts "Command: #{command.join(" ")}"
      unless Dir.exists?(rootfs_value)
        Log.error { "Rootfs path does not exist: #{rootfs_value}" }
        STDERR.puts "Rootfs path does not exist: #{rootfs_value}"
        return 1
      end

      SysrootNamespace.enter_rootfs(rootfs_value, extra_binds: extra_binds)
      reset_environment(home, extra_env)
      apply_toolchain_env_defaults
      AlpineSetup.install_sysroot_runner_packages if run_alpine_setup
      Log.info { "Executing command: #{command.join(" ")}" }
      STDERR.puts "Executing command: #{command.join(" ")}"
      Process.exec(command.first, command[1..])
    rescue ex : File::Error
      cmd = command || [] of String
      executable = cmd.first?
      cwd = Dir.current
      exec_exists = executable ? File.exists?(executable) : false
      Log.error do
        "Process exec failed for #{cmd.join(" ")} (cwd=#{cwd}, rootfs=#{rootfs}, executable=#{executable}, exists=#{exec_exists}): #{ex.message}"
      end
      STDERR.puts "Process exec failed for #{cmd.join(" ")}"
      STDERR.puts "cwd=#{cwd} rootfs=#{rootfs} executable=#{executable} exists=#{exec_exists}"
      STDERR.puts "error=#{ex.message}"
      raise ex
    end

    # Report namespace preflight checks and hint at host fixes.
    private def self.run_namespace_check(args : Array(String)) : Int32
      proc_root = Path["/proc"]
      filesystems_path = Path["/proc/filesystems"]

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-namespace-check [options]") do |p|
        p.on("--proc-root=PATH", "Override proc root (default: #{proc_root})") { |val| proc_root = Path[val] }
        p.on("--filesystems=PATH", "Override /proc/filesystems path (default: #{filesystems_path})") { |val| filesystems_path = Path[val] }
      end
      return CLI.print_help(parser) if help

      restrictions = SysrootNamespace.collect_restrictions(
        proc_root: proc_root,
        filesystems_path: filesystems_path,
      )

      if restrictions.empty?
        puts "Namespace checks: OK (no obvious restrictions detected)"
        return 0
      end

      userns_toggle = File.exists?(SysrootNamespace::USERNS_TOGGLE_PATH) ? File.read(SysrootNamespace::USERNS_TOGGLE_PATH).strip : "missing"
      apparmor_toggle = File.exists?(SysrootNamespace::APPARMOR_USERNS_SYSCTL_PATH) ? File.read(SysrootNamespace::APPARMOR_USERNS_SYSCTL_PATH).strip : "missing"
      puts "Kernel userns toggles: kernel.unprivileged_userns_clone=#{userns_toggle}, kernel.apparmor_restrict_unprivileged_userns=#{apparmor_toggle}"

      puts "Namespace checks: detected potential restrictions:"
      restrictions.each { |restriction| puts "- #{restriction}" }

      puts
      puts "Suggested fixes:"
      restrictions.each do |restriction|
        case restriction
        when .includes?("kernel.unprivileged_userns_clone")
          puts "- Enable user namespaces: sudo sysctl -w kernel.unprivileged_userns_clone=1"
        when .includes?("missing filesystem support")
          puts "- Ensure proc/sysfs/tmpfs are enabled in the kernel (CONFIG_PROC_FS/CONFIG_SYSFS/CONFIG_TMPFS)"
        when .includes?("no_new_privs")
          puts "- Run without NoNewPrivs (container runtime security profile may need adjustment)"
        when .includes?("seccomp")
          puts "- Disable or relax the seccomp profile (e.g., --security-opt seccomp=unconfined) to allow userns mapping and sockets"
        when .includes?("user namespace setgroups mapping failed")
          puts "- Allow setgroups/uid_map writes inside user namespaces (adjust seccomp/LSM or run privileged)"
        when .includes?("setgroups")
          puts "- Ensure /proc/self/setgroups is present and writable (AppArmor/LSM/seccomp may be blocking it); consider running without seccomp/NoNewPrivs"
        end
      end
      1
    end

    # Normalize a bind-mount target path inside a rootfs.
    private def self.normalize_bind_target(value : String) : Path
      cleaned = value.starts_with?("/") ? value[1..] : value
      Path[cleaned]
    end

    # Reset the environment to a minimal expected set before entering the rootfs.
    private def self.reset_environment(home : String, extra_env : Hash(String, String) = {} of String => String) : Nil
      ENV.clear
      ENV["HOME"] = home
      ENV["PATH"] = DEFAULT_PATH
      extra_env.each { |key, value| ENV[key] = value }
    end

    # Ensure the sysroot toolchain defaults are available inside the namespace.
    private def self.apply_toolchain_env_defaults : Nil
      ENV["CRYSTAL_CACHE_DIR"] = "/tmp/crystal_cache"
      ENV["SSL_CERT_FILE"] = "/etc/ssl/certs/ca-certificates.crt"
      ENV["CC"] = "clang -fuse-ld=lld"
      ENV["CXX"] = "clang++ -fuse-ld=lld"
      ENV["LD"] = "ld.lld"
      ENV["PATH"] = DEFAULT_PATH
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

      dev_flags = mount_info_flags("/dev")
      if dev_flags.includes?("nodev")
        restrictions << "/dev is mounted with nodev; provide a dev-enabled /dev (devtmpfs or tmpfs,dev) so device binds work inside user namespaces."
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
      if privileged_mount_only?
        unshare!(CLONE_NEWNS)
        make_mounts_private
        return
      end

      ensure_unprivileged_userns_clone_enabled!
      unshare!(CLONE_NEWUSER)
      setup_user_mapping(uid, gid)
      unshare!(CLONE_NEWNS)
      make_mounts_private
    end

    # Enter the provided rootfs by unsharing namespaces, bind-mounting the
    # rootfs, mounting /proc, /dev, and /sys, then pivoting into the new root.
    # When *bind_host_dev* is true, /dev is bind-mounted recursively from the
    # host (Linux From Scratch kernfs style) to avoid relying on dev-enabled
    # tmpfs inside user namespaces.
    # When *unmount_old_root* is true, the old root is detached after pivot_root.
    def self.enter_rootfs(rootfs : String,
                          extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path),
                          bind_host_dev : Bool = true,
                          unmount_old_root : Bool = true)
      unshare_namespaces
      root_path = Path[rootfs].expand
      bind_mount_rootfs(root_path)
      extra_binds.each do |(source, target)|
        bind_mount(source, root_path / target)
      end
      mount_virtual_fs(root_path, bind_host_dev: bind_host_dev)

      pivot_root!(root_path, unmount_old_root: unmount_old_root)
    end

    # pivot_root requires the new root to be a mount point. A bind mount creates
    # a dedicated mount point without depending on a specific filesystem type.
    private def self.bind_mount_rootfs(rootfs : Path)
      mount_call(rootfs.to_s, rootfs.to_s, nil, MS_BIND | MS_REC, nil)
    end

    # Mount kernel-provided virtual filesystems inside the new rootfs.
    private def self.mount_virtual_fs(rootfs : Path, bind_host_dev : Bool = true)
      mount_proc(rootfs / "proc")
      mount_sys(rootfs / "sys")
      mount_dev(rootfs / "dev", rootfs / "proc", bind_host_dev: bind_host_dev)
      mount_tmpfs(rootfs / "tmp")
      mount_tmpfs(rootfs / "dev" / "shm") unless bind_host_dev
    end

    # Performs pivot_root with an `.pivot_root` directory inside *rootfs*.
    # Raises NamespaceError if pivot_root fails. When *unmount_old_root* is
    # true, detaches the old root mount after switching to `/`.
    private def self.pivot_root!(rootfs : Path, unmount_old_root : Bool = true)
      put_old = rootfs / ".pivot_root"
      FileUtils.mkdir_p(put_old)
      if LibC.pivot_root(rootfs.to_s.to_unsafe, put_old.to_s.to_unsafe) != 0
        errno = Errno.value
        raise NamespaceError.new("pivot_root failed: #{errno} #{errno.message}")
      end
      Dir.cd("/")
      return unless unmount_old_root
      unmount_old_root!
    end

    # Detaches the old root mount created by pivot_root.
    private def self.unmount_old_root!(mount_point : Path = Path["/.pivot_root"])
      if LibC.umount2(mount_point.to_s.to_unsafe, MNT_DETACH) != 0
        errno = Errno.value
        raise NamespaceError.new("umount2 #{mount_point} failed: #{errno} #{errno.message}")
      end
      FileUtils.rm_rf(mount_point)
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
          # Privileged callers (uid 0 in the parent namespace) can still write
          # gid_map without disabling setgroups. Allow the flow to continue for
          # uid 0 so seccomp/NoNewPrivs filters on setgroups do not block the
          # user namespace setup. Unprivileged callers must still disable
          # setgroups.
          unless uid == 0
            raise NamespaceError.new("Failed to write #{setgroups_path}: #{error.message}. This can be caused by LSM policies (e.g., AppArmor).")
          end
        end
      elsif LibC.getuid != 0
        raise NamespaceError.new("Missing #{setgroups_path}; unprivileged user namespaces are not available without uid 0.")
      end
      # Mapping uid/gid is required so the process gains CAP_SYS_ADMIN in the
      # new user namespace, which is needed for mount and pivot_root calls.
      write_id_map("/proc/self/uid_map", uid)
      write_id_map("/proc/self/gid_map", gid)
    end

    # Returns true when the current process already has CAP_SYS_ADMIN.
    # In that case we can skip creating a user namespace, which preserves
    # host capabilities such as CAP_NET_RAW (needed for ping) while still
    # isolating mounts.
    private def self.privileged_mount_only? : Bool
      cap_sys_admin?
    end

    private def self.no_new_privs?(proc_status_path : Path = Path["/proc/self/status"]) : Bool
      status_value("NoNewPrivs", proc_status_path) == "1"
    end

    private def self.seccomp_enforced?(proc_status_path : Path = Path["/proc/self/status"]) : Bool
      status_value("Seccomp", proc_status_path) == "2"
    end

    private def self.cap_sys_admin? : Bool
      hex = status_value("CapEff", Path["/proc/self/status"])
      return false unless hex
      value = hex.to_u64(16)
      # CAP_SYS_ADMIN is bit 21
      (value & (1_u64 << 21)) != 0
    rescue
      false
    end

    private def self.status_value(key : String, path : Path) : String?
      File.each_line(path) do |line|
        if line.starts_with?("#{key}:")
          return line.split(":")[1]?.try &.strip
        end
      end
      nil
    rescue
      nil
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

    # Mounts /dev on the provided target. When *bind_host_dev* is true, bind the
    # host /dev recursively (LFS kernfs style). Otherwise, create a fresh tmpfs
    # with essential device nodes bind-mounted from the host.
    private def self.mount_dev(target : Path, proc_root : Path, bind_host_dev : Bool = true)
      if bind_host_dev
        bind_mount("/dev", target)
        return
      end

      FileUtils.mkdir_p(target)
      ensure_device_node(target / "null", "/dev/null")
      ensure_device_node(target / "zero", "/dev/zero")
      ensure_device_node(target / "random", "/dev/random")
      ensure_device_node(target / "urandom", "/dev/urandom")
      if File.exists?("/dev/tty")
        ensure_device_node(target / "tty", "/dev/tty")
      end
      bind_mount(proc_root / "self" / "fd", target / "fd")
      {target / "stdin", target / "stdout", target / "stderr"}.each { |link| File.delete?(link) }
      FileUtils.ln_s("/proc/self/fd/0", target / "stdin")
      FileUtils.ln_s("/proc/self/fd/1", target / "stdout")
      FileUtils.ln_s("/proc/self/fd/2", target / "stderr")
    end

    # Mounts a tmpfs at the target path with safe defaults (including MS_NODEV),
    # optionally overriding mount flags and allowing device nodes when requested.
    private def self.mount_tmpfs(target : Path, flags : UInt64 = MS_NOSUID | MS_NODEV, allow_devices : Bool = false)
      unless filesystem_available?("tmpfs")
        raise NamespaceError.new("Filesystem type tmpfs is not available; check /proc/filesystems.")
      end
      FileUtils.mkdir_p(target)
      mount_flags = allow_devices ? (flags & ~MS_NODEV) : flags
      mount_data = allow_devices ? "mode=755" : nil
      mount_call("tmpfs", target.to_s, "tmpfs", mount_flags, mount_data)

      unless allow_devices
        remount_flags = MS_REMOUNT | mount_flags
        mount_call(nil, target.to_s, nil, remount_flags, nil)
      end

      if allow_devices
        opts = mount_info_flags(target.to_s)
        if opts.includes?("nodev")
          raise NamespaceError.new("Mounted #{target} still has nodev; ensure /dev is provided with dev-enabled tmpfs or run the container with /dev:rw,exec,dev,nosuid and no seccomp/no-new-privs blocking remounts.")
        end
      end
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
      flags |= MS_NOEXEC if preserved.includes?("noexec")
      mount_call(nil, target.to_s, nil, flags, nil)
    end

    # Ensure a usable device node is available at the target by bind-mounting
    # the host device. Raises NamespaceError with guidance when binding or
    # writing the device fails so callers surface clear requirements.
    private def self.ensure_device_node(target : Path, source : String)
      FileUtils.mkdir_p(target.parent)
      begin
        bind_mount_device(source, target)
        # Only write-probe devices that are expected to be writable without extra caps.
        if ["/dev/null", "/dev/zero"].includes?(source)
          File.open(target, "w") { |io| io.write Bytes.empty }
        else
          # /dev/tty may legitimately return ENXIO/ENOTTY when no controlling TTY exists.
          begin
            File.open(target, "r") { |_| }
          rescue ex : File::Error
            unless source == "/dev/tty" && (ex.os_error == Errno::ENXIO || ex.os_error == Errno::ENOTTY)
              raise ex
            end
          end
        end
        return
      rescue ex
        raise NamespaceError.new("Device bind failed for #{source} -> #{target}: #{ex.message}. Ensure host /dev allows dev-enabled bind mounts and the node is writable inside user namespaces (e.g., provide /dev as tmpfs with dev,nosuid,exec).")
      end
    end

    # Returns true if the filesystem type appears in /proc/filesystems.
    private def self.filesystem_available?(fstype : String) : Bool
      File.read_lines("/proc/filesystems").any? do |line|
        line.split.last? == fstype
      end
    end
  end
end
