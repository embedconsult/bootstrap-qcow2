require "option_parser"
require "./sysroot_namespace"

module Bootstrap
  # Entrypoint that reports potential namespace restrictions for proc/sys/dev mounts.
  class SysrootNamespaceCheckMain
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
      exit 1
    end
  end
end

Bootstrap::SysrootNamespaceCheckMain.run
