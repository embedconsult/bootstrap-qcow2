require "spec"
require "log"
require "path"
require "http/server"

# We are following a pattern of including all the source files for testing here and
# not in the individual spec files. Please add the `require` here and not in the spec
# file.
require "../src/bootstrap_qcow2"
require "../src/github_utils"
require "../src/github_cli"
require "../src/process_runner"
require "../src/sysroot_builder"
require "../src/sysroot_namespace"
require "../src/sysroot_workspace"
require "../src/sysroot_build_state"
require "../src/sysroot_runner"
require "../src/tarball"
require "../src/tar_writer"
require "../src/patch_applier"
# require "../src/hello-efi"
require "../src/inproc_llvm"

Log.setup_from_env

class ServerUnavailable < Exception
end

def tcp_server_available? : Tuple(Bool, String?)
  begin
    server = TCPServer.new("127.0.0.1", 0)
    server.close
    {true, nil}
  rescue ex : Socket::Error
    {false, ex.message}
  end
end

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

# SysrootWorkspace.new probes for a marker at
# data/sysroot/seed-rootfs/bq2-rootfs/.bq2-rootfs when running on the host
# (see SysrootWorkspace::PROBE_PATHS_FOR_MARKER). Ensure that marker exists
# so specs that intentionally exercise default workspace discovery remain
# deterministic in CI and local runs. This is done using the `create` method
# and changing to the appropriate directory.
def with_bq2_workspace(prefix : String = "bq2-spec", &)
  path = Path[File.tempname(prefix)].expand
  File.delete?(path.to_s)
  FileUtils.mkdir_p(path)
  begin
    Dir.cd(path) do
      Bootstrap::SysrootWorkspace.create
      yield
    end
  ensure
    FileUtils.rm_rf(path)
  end
end

def with_server(status_code, message, &block : Int32 ->)
  server = HTTP::Server.new do |context|
    context.response.status_code = status_code
    context.response.print(message)
  end
  begin
    address = server.bind_tcp("127.0.0.1", 0)
  rescue ex : Socket::Error
    raise ServerUnavailable.new("HTTP server unavailable: #{ex.message}")
  end
  done = Channel(Nil).new
  spawn do
    server.listen
  ensure
    done.send(nil)
  end

  begin
    yield address.port
  ensure
    server.close
    done.receive
  end
end
