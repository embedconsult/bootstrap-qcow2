require "spec"
require "log"
require "path"
require "../src/bootstrap-qcow2"
require "../src/codex_utils"
require "../src/codex_namespace"
require "../src/sysroot_builder"
require "../src/sysroot_namespace"
require "../src/sysroot_runner_lib"
require "../src/syscalls"
# require "../src/hello-efi"
require "../src/inproc_llvm"

Log.setup_from_env

def run_crystal_eval(code : String) : Process::Status
  Process.run("crystal", ["eval", code], output: IO::Memory.new, error: IO::Memory.new, chdir: Dir.current)
end

def namespace_maps_available?(require_mount : Bool = false) : Bool
  code = <<-CR
    require "./src/namespace_wrapper"
    logger = Log.for("NamespaceProbe")
    Log.setup(:warn)
    exit(Bootstrap::NamespaceWrapper.namespace_maps_available?(require_mount: #{require_mount}, logger: logger) ? 0 : 1)
  CR
  run_crystal_eval(code).success?
end
