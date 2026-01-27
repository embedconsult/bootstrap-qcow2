require "spec"
require "log"
require "path"
require "../src/bootstrap-qcow2"
require "../src/github_utils"
require "../src/github_cli"
require "../src/sysroot_builder"
require "../src/sysroot_all_resume"
require "../src/sysroot_namespace"
require "../src/sysroot_runner_lib"
require "../src/tarball"
# require "../src/hello-efi"
require "../src/inproc_llvm"

Log.setup_from_env

def with_tempdir(prefix : String = "bq2-spec", &block : Path ->)
  path = Path[File.tempname(prefix)].expand
  File.delete?(path.to_s)
  FileUtils.mkdir_p(path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end
