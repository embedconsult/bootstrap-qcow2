require "json"
require "digest/sha256"
require "file_utils"
require "random/secure"
require "time"
require "./sysroot_workspace"

module Bootstrap
  # Persistent, human-readable state for in-container sysroot/rootfs iterations.
  #
  # The build plan JSON is treated as immutable during iterations. Instead, the
  # runner records progress into this state file so subsequent runs can pick up
  # where they left off without re-running already successful steps.
  class SysrootBuildState
    include JSON::Serializable

    PLAN_FILE       = "sysroot-build-plan.json"
    STATE_FILE      = "sysroot-build-state.json"
    OVERRIDES_FILE  = "sysroot-build-overrides.json"
    REPORT_DIR_NAME = "sysroot-build-reports"
    FORMAT_VERSION  = 1

    # Schema version for forward-compatible upgrades.
    getter format_version : Int32 = FORMAT_VERSION

    @[JSON::Field(ignore: true)]
    @workspace : SysrootWorkspace = SysrootWorkspace.new(host_workdir: Path[SysrootWorkspace::DEFAULT_HOST_WORKDIR])
    @[JSON::Field(ignore: true)]
    @state_path : Path? = nil

    # Identifier for the prepared rootfs. This changes whenever the rootfs is
    # regenerated from scratch.
    getter rootfs_id : String

    # Timestamp for when this state file was initially created (UTC, ISO8601).
    getter created_at : String

    # Timestamp for the most recent update (UTC, ISO8601).
    property updated_at : String?

    # SHA256 digest (hex) of the build plan file used to produce this state.
    property plan_digest : String?

    # SHA256 digest (hex) of the overrides file used to produce this state.
    property overrides_digest : String?

    # Timestamp (UTC, ISO8601) for the most recent state invalidation.
    property invalidated_at : String?

    # Human-readable reason for invalidating runner progress.
    property invalidation_reason : String?

    # Runner progress tracked per phase/package.
    getter progress : Progress = Progress.new

    def initialize(@workspace : SysrootWorkspace = SysrootWorkspace.new(host_workdir: Path[SysrootWorkspace::DEFAULT_HOST_WORKDIR]),
                   @state_path : Path? = nil,
                   @rootfs_id : String = Random::Secure.hex(8),
                   @created_at : String = Time.utc.to_s,
                   @updated_at : String? = nil,
                   @plan_digest : String? = nil,
                   @overrides_digest : String? = nil,
                   @invalidated_at : String? = nil,
                   @invalidation_reason : String? = nil,
                   @progress : Progress = Progress.new,
                   @format_version : Int32 = FORMAT_VERSION)
    end

    # Load state from a JSON file.
    def self.load(workspace : SysrootWorkspace, state_path : Path = workspace.log_path / STATE_FILE) : SysrootBuildState
      state = from_json(File.read(state_path))
      state.assign_workspace(workspace, state_path)
      state
    end

    # Load or initialize a state file with plan/override digest reconciliation.
    def self.load_or_init(workspace : SysrootWorkspace,
                          state_path : Path = workspace.log_path / STATE_FILE,
                          overrides_path : Path? = nil) : SysrootBuildState
      if File.exists?(state_path)
        state = load(workspace, state_path)
      else
        state = SysrootBuildState.new(workspace: workspace)
      end

      plan_digest = digest_for?(state.plan_path_path)
      overrides_path_path = overrides_path || state.overrides_path_path
      overrides_digest = overrides_path_path ? digest_for?(overrides_path_path) : nil

      changed = false
      if state.plan_digest && plan_digest && state.plan_digest != plan_digest
        changed = true
      end
      if state.overrides_digest && overrides_digest && state.overrides_digest != overrides_digest
        changed = true
      end

      state.plan_digest = plan_digest
      state.overrides_digest = overrides_digest

      if changed && !state.progress.completed_steps.empty?
        state.progress.completed_steps.clear
        state.progress.current_phase = nil
        state.progress.last_success = nil
        state.progress.last_failure = nil
        state.invalidated_at = Time.utc.to_s
        state.invalidation_reason = "Build plan/overrides changed"
      end

      state.save(state_path)
      state
    end

    # Current rootfs-relative state path
    def state_path : Path
      @state_path || (@workspace.log_path / STATE_FILE)
    end

    # Resolve the plan path into the active namespace.
    def plan_path_path : Path
      @workspace.log_path / PLAN_FILE
    end

    # Resolve overrides path into the active namespace.
    def overrides_path_path : Path
      @workspace.log_path / OVERRIDES_FILE
    end

    # Resolve report directory path into the active namespace.
    def report_dir_path : Path
      @workspace.log_path / REPORT_DIR_NAME
    end

    # Returns true when the build plan file exists for this workspace.
    def plan_exists? : Bool
      File.exists?(plan_path_path)
    end

    # Returns true when the build state file exists for this workspace.
    def state_exists? : Bool
      File.exists?(state_path)
    end

    # Return the SHA256 hex digest for *path*, or nil when the file is missing.
    def self.digest_for?(path : Path) : String?
      return nil unless File.exists?(path)
      digest = Digest::SHA256.new
      File.open(path) do |file|
        buffer = Bytes.new(8192)
        while (read = file.read(buffer)) > 0
          digest.update(buffer[0, read])
        end
      end
      digest.final.hexstring
    end

    # Persist the state JSON to disk.
    def save(path : Path = state_path)
      FileUtils.mkdir_p(path.parent)
      File.write(path, to_pretty_json)
    end

    # Returns true when the given *step_name* has already completed successfully
    # within *phase_name*.
    def completed?(phase_name : String, step_name : String) : Bool
      @progress.completed_steps[phase_name]?.try(&.includes?(step_name)) || false
    end

    # Record that *step_name* finished successfully within *phase_name*.
    def mark_success(phase_name : String, step_name : String) : Nil
      @progress.current_phase = phase_name
      steps = (@progress.completed_steps[phase_name]? || [] of String)
      unless steps.includes?(step_name)
        steps << step_name
        @progress.completed_steps[phase_name] = steps
      end
      @progress.last_success = StepRef.new(phase: phase_name, step: step_name, occurred_at: Time.utc.to_s)
      touch
      save
    end

    # Record that *step_name* failed within *phase_name*.
    def mark_failure(phase_name : String, step_name : String, error : String?, report_path : String?) : Nil
      progress.current_phase = phase_name
      progress.last_failure = FailureRef.new(
        phase: phase_name,
        step: step_name,
        occurred_at: Time.utc.to_s,
        error: error,
        report_path: report_path
      )
      touch
      save
    end

    # Update the current phase tracking marker.
    def mark_current_phase(phase_name : String?) : Nil
      @progress.current_phase = phase_name
      touch
      save
    end

    # Update `updated_at` to the current UTC time.
    def touch : Nil
      @updated_at = Time.utc.to_s
    end

    # Return the selected build phases from the current plan.
    def selected_phases(requested : String = "all") : Array(BuildPhase)
      plan = BuildPlan.parse(File.read(plan_path_path))
      plan.selected_phases(requested)
    end

    def assign_workspace(workspace : SysrootWorkspace, state_path : Path? = nil) : Nil
      @workspace = workspace
      @state_path = state_path
    end

    # Minimal step reference used for progress tracking.
    struct StepRef
      include JSON::Serializable

      getter phase : String
      getter step : String
      getter occurred_at : String

      def initialize(@phase : String, @step : String, @occurred_at : String)
      end
    end

    # Failure reference that can link back to a report JSON.
    struct FailureRef
      include JSON::Serializable

      getter phase : String
      getter step : String
      getter occurred_at : String
      getter error : String?
      getter report_path : String?

      def initialize(@phase : String,
                     @step : String,
                     @occurred_at : String,
                     @error : String? = nil,
                     @report_path : String? = nil)
      end
    end

    # Container for per-runner progress state.
    struct Progress
      include JSON::Serializable

      property current_phase : String?
      property completed_steps : Hash(String, Array(String)) = {} of String => Array(String)
      property last_success : StepRef?
      property last_failure : FailureRef?

      def initialize(@current_phase : String? = nil,
                     @completed_steps : Hash(String, Array(String)) = {} of String => Array(String),
                     @last_success : StepRef? = nil,
                     @last_failure : FailureRef? = nil)
      end
    end
  end
end
