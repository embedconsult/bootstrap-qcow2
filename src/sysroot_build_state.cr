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
    property workspace : SysrootWorkspace?

    # Identifier for the prepared rootfs. This changes whenever the rootfs is
    # regenerated from scratch.
    getter rootfs_id : String

    # Timestamp for when this state file was initially created (UTC, ISO8601).
    getter created_at : String

    # Timestamp for the most recent update (UTC, ISO8601).
    property updated_at : String?

    # SHA256 digest (hex) of the build plan file used to produce this state.
    #
    # When this digest changes, the runner should treat the plan inputs as
    # different and should avoid skipping completed steps from a prior run.
    property plan_digest : String?

    # SHA256 digest (hex) of the overrides file used to produce this state.
    #
    # When this digest changes, the runner should treat overrides as different
    # and should avoid skipping completed steps from a prior run.
    property overrides_digest : String?

    # Timestamp (UTC, ISO8601) for the most recent state invalidation.
    property invalidated_at : String?

    # Human-readable reason for invalidating runner progress.
    property invalidation_reason : String?

    # Runner progress tracked per phase/package.
    getter progress : Progress = Progress.new

    def self.new(workspace : SysrootWorkspace? = nil,
                 rootfs_id : String = Random::Secure.hex(8),
                 created_at : String = Time.utc.to_s,
                 updated_at : String? = nil,
                 plan_digest : String? = nil,
                 overrides_digest : String? = nil,
                 invalidated_at : String? = nil,
                 invalidation_reason : String? = nil,
                 progress : Progress = Progress.new,
                 format_version : Int32 = FORMAT_VERSION,
                 raise_on_invalid_state : Bool = false)
      workspace ||= SysrootWorkspace.new
      new_workspace = workspace.not_nil!
      new_state_path = new_workspace.log_path / STATE_FILE
      if File.exists?(new_state_path)
        state = SysrootBuildState.from_json(File.open(new_state_path))
        state.workspace = new_workspace

        # Ensure stored digests match the current plan/overrides files.
        #
        # When the plan or overrides inputs change, this clears completed steps so
        # the runner does not incorrectly skip work based on stale state.
        previous_plan = state.plan_digest
        previous_overrides = state.overrides_digest
        current_plan = state.class.digest_for?(state.plan_path)
        current_overrides = state.class.digest_for?(state.overrides_path)

        state.plan_digest = current_plan
        state.overrides_digest = current_overrides

        unless state.progress.completed_steps.empty?
          changed = false
          changed ||= previous_plan != current_plan
          changed ||= previous_overrides != current_overrides

          if changed
            raise "State file does not reconcile with plan" if raise_on_invalid_state
            state.progress.completed_steps.clear
            state.progress.current_phase = nil
            state.progress.last_success = nil
            state.progress.last_failure = nil
            state.invalidated_at = Time.utc.to_s
            state.invalidation_reason = "Build plan/overrides changed"
          end
        end
        return state
      end

      state = SysrootBuildState.allocate
      current_plan = plan_digest || SysrootBuildState.digest_for?(new_workspace.log_path / PLAN_FILE)
      current_overrides = overrides_digest || SysrootBuildState.digest_for?(new_workspace.log_path / OVERRIDES_FILE)
      state.initialize_fields(
        rootfs_id: rootfs_id,
        created_at: created_at,
        updated_at: updated_at,
        plan_digest: current_plan,
        overrides_digest: current_overrides,
        invalidated_at: invalidated_at,
        invalidation_reason: invalidation_reason,
        progress: progress,
        format_version: format_version,
      )
      state.workspace = new_workspace
      state.touch if updated_at.nil?
      state
    end

    protected def initialize_fields(rootfs_id : String,
                                    created_at : String,
                                    updated_at : String?,
                                    plan_digest : String?,
                                    overrides_digest : String?,
                                    invalidated_at : String?,
                                    invalidation_reason : String?,
                                    progress : Progress,
                                    format_version : Int32) : Nil
      @rootfs_id = rootfs_id
      @created_at = created_at
      @updated_at = updated_at
      @plan_digest = plan_digest
      @overrides_digest = overrides_digest
      @invalidated_at = invalidated_at
      @invalidation_reason = invalidation_reason
      @progress = progress
      @format_version = format_version
    end

    # Current rootfs-relative plan path
    def plan_path : Path
      w = @workspace.nil? ? SysrootWorkspace.new : @workspace.not_nil!
      w.log_path / PLAN_FILE
    end

    # Rootfs-relative report directory string.
    def self.rootfs_report_dir : String
      "/var/lib/#{REPORT_DIR_NAME}"
    end

    # Current rootfs-relative state path
    def state_path : Path
      w = @workspace.nil? ? SysrootWorkspace.new : @workspace.not_nil!
      w.log_path / STATE_FILE
    end

    # Current rootfs-relative overrides path
    def overrides_path : Path
      w = @workspace.nil? ? SysrootWorkspace.new : @workspace.not_nil!
      w.log_path / OVERRIDES_FILE
    end

    # Current rootfs-relative report directory
    def report_dir : Path
      w = @workspace.nil? ? SysrootWorkspace.new : @workspace.not_nil!
      w.log_path / REPORT_DIR_NAME
    end

    # Returns true when the build plan file exists for this workspace.
    def plan_exists? : Bool
      File.exists?(plan_path)
    end

    # Returns true when the build state file exists for this workspace.
    def state_exists? : Bool
      File.exists?(state_path)
    end

    # Record the current phase name for status reporting.
    def mark_current_phase(name : String?) : Nil
      @progress.current_phase = name
      touch
      save
    end

    # Load a state file at *path* and associate the provided workspace.
    def self.load(workspace : SysrootWorkspace, path : Path) : SysrootBuildState
      state = SysrootBuildState.from_json(File.read(path))
      state.workspace = workspace
      state
    end

    # Ensure a state file exists on disk.
    def ensure_state_file : Nil
      return if File.exists?(state_path)
      touch
      save
    end

    # Ensure a state file exists on disk, creating an empty one when needed.
    def self.ensure_state_file(workspace : SysrootWorkspace) : Nil
      state = SysrootBuildState.new(workspace: workspace)
      return if File.exists?(state.state_path)
      state.touch
      state.save
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
    def save
      FileUtils.mkdir_p(state_path.parent)
      File.write(state_path, to_pretty_json)
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

    # Update `updated_at` to the current UTC time.
    def touch : Nil
      @updated_at = Time.utc.to_s
    end

    # Return true when the resume step matches the most recent failure.
    def retrying_last_failure?(phase : String?, step : String?) : Bool
      return false unless phase && step
      failure = progress.last_failure
      return false unless failure
      failure.phase == phase && failure.step == step
    end

    # Resolve a rootfs-absolute *path* based on the location of *state_path*.
    def resolve_rootfs_path(path : String, state_path : String?) : String
      return path unless path.starts_with?("/") && state_path
      rootfs_root = Path[state_path].expand.parent.parent.parent
      (rootfs_root / path.lchop("/")).to_s
    end

    # Read the overrides JSON contents if the file exists.
    def overrides_contents(state_path : String? = nil) : String?
      path = overrides_path
      return nil unless path
      resolved = resolve_rootfs_path(path.to_s, state_path)
      return nil unless File.exists?(resolved)
      File.read(resolved)
    end

    # Determine the most relevant failure report path, if any.
    def failure_report_path(state_path : String? = nil) : String?
      if (failure = progress.last_failure)
        report_path = failure.report_path
        if report_path
          resolved = resolve_rootfs_path(report_path, state_path)
          return resolved if File.exists?(resolved)
        end
      end

      reports_dir = report_dir
      return nil unless reports_dir
      resolved_reports_dir = resolve_rootfs_path(reports_dir.to_s, state_path)
      return nil unless Dir.exists?(resolved_reports_dir)

      latest_path = nil
      latest_mtime = Time::UNIX_EPOCH
      Dir.each_child(resolved_reports_dir) do |entry|
        next unless entry.ends_with?(".json")
        path = File.join(resolved_reports_dir, entry)
        next unless File.file?(path)
        mtime = File.info(path).modification_time
        if latest_path.nil? || mtime > latest_mtime
          latest_path = path
          latest_mtime = mtime
        end
      end

      latest_path
    end

    # Read the most recent failure report JSON if available.
    def failure_report_contents(state_path : String? = nil) : String?
      path = failure_report_path(state_path)
      return nil unless path && File.exists?(path)
      File.read(path)
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
