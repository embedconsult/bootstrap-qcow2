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
require "../src/efi_app_builder"

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
      Log.debug { "Using workspace rooted at #{path}" }
      Bootstrap::SysrootWorkspace.create
      yield
    end
  ensure
    FileUtils.rm_rf(path)
  end
end

def with_modified_env(key : String, value : String, &block : ->)
  previous = ENV[key]?
  ENV[key] = value
  yield
ensure
  if previous
    ENV[key] = previous
  else
    ENV.delete(key)
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
  getter phase_environment_calls = [] of NamedTuple(phase: String, value: String?)
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

  # Record phase environment setup calls while preserving base behavior.
  def with_phase_environment(phase : Bootstrap::BuildPhase, &block : ->)
    @phase_environment_calls << {phase: phase.name, value: ENV["BQ2_PHASE_MARKER"]?}
    super(phase) do
      @phase_environment_calls << {phase: phase.name, value: ENV["BQ2_PHASE_MARKER"]?}
      yield
    end
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
  step_runner = RecordingRunner.new
  begin
    plan_path = step_runner.workspace.log_path / Bootstrap::SysrootBuildState::PLAN_FILE
    overrides_path = step_runner.workspace.log_path / Bootstrap::SysrootBuildState::OVERRIDES_FILE
    File.write(plan_path, plan.to_json)
    Log.debug { "Wrote plan to #{plan_path}" }
    unless overrides.nil?
      File.write(overrides_path, overrides.to_json)
      Log.debug { "Wrote overrides to #{overrides_path}" }
    end
    build_state = Bootstrap::SysrootBuildState.new(workspace: step_runner.workspace)
    yield build_state, step_runner
  ensure
    FileUtils.rm_rf(step_runner.workdir)
  end
end
