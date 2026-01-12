require "log"
require "option_parser"
require "process"
require "./sysroot_namespace"

module Bootstrap
  # Entrypoint that sets up user/mount namespaces and then execs the
  # provided command inside the new rootfs.
  class SysrootNamespaceMain
    # Parse CLI flags, enter the namespace-backed rootfs, and exec the command.
    def self.run
      rootfs : String = "data/sysroot/rootfs"
      command : Array(String) = [] of String

      OptionParser.parse do |parser|
        parser.banner = "Usage: crystal run src/sysroot_namespace_main.cr -- [options] command..."
        parser.on("--rootfs=PATH", "Path to the sysroot rootfs (default: #{rootfs})") { |val| rootfs = val }
        parser.on("-h", "--help", "Show this help") { puts parser; exit }
      end

      command = ARGV.dup
      if command.empty?
        command = ["/bin/sh"]
        Log.debug { "No command provided; defaulting to #{command.join(" ")}" }
      end

      Log.debug { "Entering namespace with rootfs=#{rootfs} cwd=#{Dir.current}" }
      Log.debug { "rootfs/bin/sh present? #{File.exists?(Path[rootfs] / "bin/sh")}" }

      SysrootNamespace.enter_rootfs(rootfs)

      Log.debug { "Inside namespace cwd=#{Dir.current} command=#{command.join(" ")}" }
      Log.debug { "/bin/sh present? #{File.exists?(Path["/bin/sh"])}" }

      Process.exec(command.first, command[1..])
    end
  end
end

# Entry-point invoked on the host to enter a user/mount namespace before
# handing off to the provided command.
Log.setup_from_env
Bootstrap::SysrootNamespaceMain.run
