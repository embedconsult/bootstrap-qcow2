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

# Run a block with temporary environment variable overrides.
#
# This is useful for specs that need deterministic executable lookup
# (for example, when Process.new resolves argv[0] from PATH before
# applying the child process environment).
def with_env(overrides : Hash(String, String?), &)
  previous = Hash(String, String?).new
  begin
    overrides.each do |key, value|
      previous[key] = ENV[key]?
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    yield
  ensure
    previous.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
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

# SysrootBuildState includes a workspace property default that probes marker
# paths relative to the current directory before initialize arguments are
# applied. Wrap specs in this helper when they instantiate SysrootBuildState
# with an explicit workspace so that implicit probe behavior stays deterministic.
def with_default_workspace_probe(prefix : String = "bq2-spec", &)
  with_tempdir(prefix) do |dir|
    Dir.cd(dir) do
      Bootstrap::SysrootWorkspace.create(host_workdir: Path["data/sysroot"])
      yield
    end
  end
end

def with_server(status_code, message, &block : Int32 ->)
  server = HTTP::Server.new do |context|
    context.response.status_code = status_code
    context.response.print(message)
  end
  begin
    address = server.bind_tcp("127.0.0.1", 0)
    Log.debug { "Started sever at 127.0.0.1:#{address.port}" }
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

class RecordingRunner < Bootstrap::StepRunner
  getter calls = [] of NamedTuple(phase: String, name: String, workdir: String?, strategy: String, configure_flags: Array(String), env: Hash(String, String))
  property status : Bool = true
  property exit_code : Int32 = 0
  getter workdir : Path

  def initialize(@status : Bool = true, @exit_code : Int32 = 0)
    @workdir = Path[Dir.tempdir] / "bq2-runner-spec-#{Random::Secure.hex(8)}"
    host_workdir = @workdir
    Log.debug { "Initializing RecordingRunner and creating workspace in #{@workdir}" }
    super(Bootstrap::SysrootWorkspace.create(host_workdir: host_workdir))
  end

  def run(phase : Bootstrap::BuildPhase, step : Bootstrap::BuildStep)
    Log.debug { "Running #{phase.name} / #{step.name} in #{@workspace.host_workdir}" }
    @calls << {phase: phase.name, name: step.name, workdir: step.workdir, strategy: step.strategy, configure_flags: step.configure_flags, env: step.env}
    raise "Command failed (#{@exit_code})" unless @status
    FakeStatus.new(@status, @exit_code)
  end

  struct FakeStatus
    def initialize(@success : Bool, @exit_code : Int32)
    end

    def success? : Bool
      @success
    end

    def exit_code : Int32
      @exit_code
    end
  end
end

def with_recording_runner(plan : Bootstrap::BuildPlan, overrides : Bootstrap::BuildPlanOverrides? = nil, &block : Bootstrap::SysrootBuildState, RecordingRunner ->)
  # RecordingRunner always creates an explicit workspace, but SysrootBuildState
  # still has a default workspace property initializer that probes marker paths
  # relative to cwd before initialize arguments are applied. Keep the probe
  # marker available for the entire block because specs may instantiate
  # additional SysrootBuildState objects while asserting runner behavior.
  with_default_workspace_probe do
    step_runner = RecordingRunner.new
    begin
      plan_path = step_runner.workspace.log_path / Bootstrap::SysrootBuildState::PLAN_FILE
      overrides_path = step_runner.workspace.log_path / Bootstrap::SysrootBuildState::OVERRIDES_FILE
      File.write(plan_path, plan.to_json)
      Log.debug { "Wrote plan to #{plan_path}" }
      unless overrides.nil?
        File.write(overrides_path, overrides.to_json)
        Log.debug { "Wrote plan to #{overrides_path}" }
      end
      build_state = Bootstrap::SysrootBuildState.new(workspace: step_runner.workspace)
      yield build_state, step_runner
    ensure
      FileUtils.rm_rf(step_runner.workdir)
    end
  end
end
