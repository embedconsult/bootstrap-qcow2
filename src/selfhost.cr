require "log"
require "file_utils"

module Bootstrap
  module SelfHost
    DEFAULT_ROOT = File.expand_path("..", __DIR__)

    class Runner
      getter root

      def initialize(@root : String = DEFAULT_ROOT)
      end

      def rebuild
        Log.info { "Starting self-host rebuild in #{@root}" }
        in_root do
          run_step("shards install", ["shards", "install"])
          run_step(
            "build bootstrap-qcow2 (release)",
            ["crystal", "build", "--release", "src/bootstrap-qcow2.cr", "-o", "bin/bootstrap-qcow2"]
          )
          run_step(
            "build bootstrap-selfhost (release)",
            ["crystal", "build", "--release", "src/selfhost.cr", "-o", "bin/bootstrap-selfhost"]
          )
        end
        Log.info { "Rebuild completed; binaries are in #{File.join(root, "bin")}" }
      end

      def verify
        Log.info { "Verifying toolchain availability inside container" }
        check_tool("clang")
        check_tool("lld")
        check_tool("crystal")
        check_tool("shards")
        Log.info { "Verification succeeded" }
      end

      private def in_root(&)
        Dir.cd(@root) { yield }
      end

      private def check_tool(name : String)
        in_root do
          found = Process.find_executable(name)
          unless found
            raise "Required tool '#{name}' not found in PATH"
          end
          Log.info { "Found #{name} at #{found}" }
        end
      end

      private def run_step(label : String, args : Array(String))
        Log.info { label }
        status = Process.run(args[0], args: args[1..], chdir: @root, output: STDOUT, error: STDERR)
        unless status.success?
          raise "Step failed: #{label} (exit #{status.exit_status})"
        end
      end
    end
  end
end

def usage
  puts <<-TEXT
Usage: bootstrap-selfhost [command]

Commands:
  rebuild   Install shards and rebuild all binaries from source (default)
  verify    Check that required build tools are available in PATH
  help      Show this message
  TEXT
end

runner = Bootstrap::SelfHost::Runner.new(ENV.fetch("BOOTSTRAP_ROOT", Bootstrap::SelfHost::DEFAULT_ROOT))
command = ARGV.shift? || "rebuild"

case command
when "rebuild"
  runner.rebuild
when "verify"
  runner.verify
when "help", "--help", "-h"
  usage
else
  STDERR.puts "Unknown command: #{command}"
  usage
  exit 1
end
