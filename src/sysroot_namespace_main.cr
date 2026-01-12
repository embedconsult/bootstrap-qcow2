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
      Log.debug { "/bin/sh info: #{safe_file_info(Path["/bin/sh"])}" }
      Log.debug { "ld-musl candidates: #{safe_glob("/lib/ld-musl-*").join(", ")}" }

      begin
        Process.exec(command.first, command[1..])
      rescue ex : File::Error
        Log.error { "Process exec failed for #{command.join(" ")}: #{ex.message}" }
        Log.error { "/bin/sh info: #{safe_file_info(Path["/bin/sh"])}" }
        Log.error { "ld-musl candidates: #{safe_glob("/lib/ld-musl-*").join(", ")}" }
        raise ex
      end
    end

    private def self.safe_file_info(path : Path) : String
      info = File.info?(path)
      return "missing" unless info
      "type=#{info.type} size=#{info.size} mode=#{info.permissions} uid=#{info.owner_id} gid=#{info.group_id}"
    rescue ex
      "error reading info: #{ex.message}"
    end

    private def self.safe_glob(pattern : String) : Array(String)
      Dir.glob(pattern)
    rescue
      [] of String
    end
  end
end

# Entry-point invoked on the host to enter a user/mount namespace before
# handing off to the provided command.
Log.setup_from_env
Bootstrap::SysrootNamespaceMain.run
