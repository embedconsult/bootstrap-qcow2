require "option_parser"
require "file_utils"
require "./sysroot_namespace"

module Bootstrap
  # CLI entrypoint to run a command inside a fresh user/mount namespace with
  # proc/sys/dev/tmp set up. Defaults to running `npx codex` in the current
  # directory.
  class CodexNamespaceMain
    def self.run
      workdir = Path["."]
      command = [] of String

      OptionParser.parse do |parser|
        parser.banner = "Usage: crystal run src/codex_namespace_main.cr -- [options] [-- cmd ...]"
        parser.on("-C DIR", "Working directory for the command (default: .)") { |dir| workdir = Path[dir].expand }
        parser.on("-h", "--help", "Show this help") { puts parser; exit }
      end

      # Capture remaining ARGV after option parsing for the command; default to npx codex.
      command = ARGV.dup
      command = ["npx", "codex"] if command.empty?

      status = SysrootNamespace.run_in_namespace(command, chdir: workdir)
      exit status.exit_code
    rescue ex : SysrootNamespace::NamespaceError
      STDERR.puts "Namespace setup failed: #{ex.message}"
      exit 1
    end
  end
end

Bootstrap::CodexNamespaceMain.run
