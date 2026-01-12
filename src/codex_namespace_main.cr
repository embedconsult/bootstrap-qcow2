require "option_parser"
require "file_utils"
require "./codex_namespace"

module Bootstrap
  # CLI entrypoint to run a command inside a fresh user/mount namespace with
  # proc/sys/dev/tmp set up. Defaults to running `npx codex` in the current
  # directory.
  class CodexNamespaceMain
    def self.run
      workdir = Path["data/sysroot/rootfs"]
      bind_codex_work = true
      alpine_setup = false
      command = [] of String

      OptionParser.parse do |parser|
        parser.banner = "Usage: crystal run src/codex_namespace_main.cr -- [options] [-- cmd ...]"
        parser.on("-C DIR", "Rootfs directory for the command (default: data/sysroot/rootfs)") { |dir| workdir = Path[dir].expand }
        parser.on("--no-bind-codex-work", "Do not bind host ./codex/work into /work") { bind_codex_work = false }
        parser.on("--alpine", "Assume rootfs is Alpine and install runtime deps for npx codex (node/npm)") { alpine_setup = true }
        parser.on("-h", "--help", "Show this help") { puts parser; exit }
      end

      # Capture remaining ARGV after option parsing for the command; default to npx codex.
      command = ARGV.dup
      command = ["npx", "codex"] if command.empty?

      status = CodexNamespace.run(command, rootfs: workdir, bind_codex_work: bind_codex_work, alpine_setup: alpine_setup)
      exit status.exit_code
    rescue ex : SysrootNamespace::NamespaceError
      STDERR.puts "Namespace setup failed: #{ex.message}"
      exit 1
    end
  end
end

Bootstrap::CodexNamespaceMain.run
