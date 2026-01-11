require "spec"
require "log"
require "path"
require "../src/bootstrap-qcow2"
require "../src/sysroot_builder"
require "../src/sysroot_namespace"
require "../src/sysroot_runner_lib"
# require "../src/hello-efi"
require "../src/inproc_llvm"

Log.setup_from_env
