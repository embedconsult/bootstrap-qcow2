require "log"
require "option_parser"
require "process"
require "./sysroot_namespace"

module Bootstrap
  # Entrypoint that sets up user/mount namespaces and then execs the
  # provided command inside the new rootfs.
  class SysrootNamespaceMain
    def self.run
      rootfs : String? = nil
      command : Array(String) = [] of String

      OptionParser.parse do |parser|
        parser.banner = "Usage: crystal run src/sysroot_namespace_main.cr -- [options] [command...]"
        parser.on("--rootfs=PATH", "Path to the sysroot rootfs") { |val| rootfs = val }
        parser.on("-h", "--help", "Show this help") { puts parser; exit }
      end

      command = ARGV.dup
      raise "Missing command to exec inside the namespace" if command.empty?

      resolved_rootfs = rootfs || raise "Missing --rootfs"
      SysrootNamespace.enter_rootfs(resolved_rootfs)

      Process.exec(command.first, command[1..])
    end
  end
end

# Entry-point invoked on the host to enter a user/mount namespace before
# handing off to the provided command.
Log.setup_from_env
Bootstrap::SysrootNamespaceMain.run
