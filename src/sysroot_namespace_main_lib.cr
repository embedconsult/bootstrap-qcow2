require "log"
require "option_parser"
require "process"
require "./sysroot_namespace"

module Bootstrap
  # Entrypoint that sets up user/mount namespaces and then execs the
  # sysroot coordinator inside the new rootfs.
  class SysrootNamespaceMain
    def self.run
      rootfs : String? = nil
      bind_proc = false
      bind_dev = false
      bind_sys = false
      use_cgroup = false
      prefer_pivot_root = true
      command : Array(String) = [] of String

      OptionParser.parse do |parser|
        parser.banner = "Usage: crystal run src/sysroot_namespace_main.cr -- [options] [command...]"
        parser.on("--rootfs=PATH", "Path to the sysroot rootfs") { |val| rootfs = val }
        parser.on("--bind-proc", "Bind-mount /proc into the rootfs") { bind_proc = true }
        parser.on("--bind-dev", "Bind-mount /dev into the rootfs") { bind_dev = true }
        parser.on("--bind-sys", "Bind-mount /sys into the rootfs") { bind_sys = true }
        parser.on("--cgroup", "Include CLONE_NEWCGROUP in the namespace set") { use_cgroup = true }
        parser.on("--no-pivot-root", "Skip pivot_root and use chroot instead") { prefer_pivot_root = false }
        parser.on("-h", "--help", "Show this help") { puts parser; exit }
      end

      command = ARGV.dup
      if command.empty?
        command = [SysrootNamespace::DEFAULT_COORDINATOR]
      end

      resolved_rootfs = rootfs || raise "Missing --rootfs"
      SysrootNamespace.enter_rootfs(
        resolved_rootfs,
        bind_proc: bind_proc,
        bind_dev: bind_dev,
        bind_sys: bind_sys,
        use_cgroup: use_cgroup,
        prefer_pivot_root: prefer_pivot_root
      )

      Process.exec(command.first, command[1..])
    end
  end
end
