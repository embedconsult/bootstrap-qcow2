require "option_parser"
require "./sysroot_namespace"

module Bootstrap
  # Entrypoint that reports potential namespace restrictions for proc/sys/dev mounts.
  class SysrootNamespaceCheckMain
    # Parse CLI flags, then print namespace restriction diagnostics.
    def self.run
      proc_root = Path["/proc"]
      filesystems_path = Path["/proc/filesystems"]
      setgroups_path = "/proc/self/setgroups"

      OptionParser.parse do |parser|
        parser.banner = "Usage: crystal run src/sysroot_namespace_check_main.cr -- [options]"
        parser.on("--proc-root=PATH", "Override proc root (default: #{proc_root})") { |val| proc_root = Path[val] }
        parser.on("--filesystems=PATH", "Override /proc/filesystems path (default: #{filesystems_path})") { |val| filesystems_path = Path[val] }
        parser.on("--setgroups=PATH", "Override /proc/self/setgroups path (default: #{setgroups_path})") { |val| setgroups_path = val }
        parser.on("-h", "--help", "Show this help") { puts parser; exit }
      end

      restrictions = SysrootNamespace.collect_restrictions(
        proc_root: proc_root,
        filesystems_path: filesystems_path,
        setgroups_path: setgroups_path
      )

      if restrictions.empty?
        puts "Namespace checks: OK (no obvious restrictions detected)"
        exit 0
      end

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
        when .includes?("proc path")
          puts "- Ensure /proc is not masked (mount_too_revealing will block procfs mounts)"
        when .includes?("setgroups")
          puts "- Ensure /proc/self/setgroups is present and writable (AppArmor/LSM may be blocking it)"
        end
      end
      exit 1
    end
  end
end

Bootstrap::SysrootNamespaceCheckMain.run
