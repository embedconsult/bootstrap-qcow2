require "json"
require "digest/sha256"
require "file_utils"
require "random/secure"
require "time"

module Bootstrap
  # Persistent, human-readable state for in-container sysroot/rootfs iterations.
  #
  # The build plan JSON is treated as immutable during iterations. Instead, the
  # runner records progress into this state file so subsequent runs can pick up
  # where they left off without re-running already successful steps.
  struct SysrootBuildState
    include JSON::Serializable

    DEFAULT_PATH      = "/var/lib/sysroot-build-state.json"
    DEFAULT_PLAN      = "/var/lib/sysroot-build-plan.json"
    DEFAULT_OVERRIDES = "/var/lib/sysroot-build-overrides.json"
    DEFAULT_REPORTS   = "/var/lib/sysroot-build-reports"
    FORMAT_VERSION    = 1

    # Schema version for forward-compatible upgrades.
    getter format_version : Int32 = FORMAT_VERSION

    # Identifier for the prepared rootfs. This changes whenever the rootfs is
    # regenerated from scratch.
    getter rootfs_id : String

    # Timestamp for when this state file was initially created (UTC, ISO8601).
    getter created_at : String

    # Timestamp for the most recent update (UTC, ISO8601).
    property updated_at : String?

    # Absolute path to the serialized build plan inside the rootfs.
    property plan_path : String

    # Absolute path to the runtime overrides JSON inside the rootfs, when used.
    property overrides_path : String?

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

    # Absolute path to the failure report directory inside the rootfs, when enabled.
    property report_dir : String?

    # Timestamp (UTC, ISO8601) for the most recent state invalidation.
    property invalidated_at : String?

    # Human-readable reason for invalidating runner progress.
    property invalidation_reason : String?

    # Runner progress tracked per phase/package.
    getter progress : Progress = Progress.new

    def initialize(@rootfs_id : String = Random::Secure.hex(8),
                   @created_at : String = Time.utc.to_s,
                   @updated_at : String? = nil,
                   @plan_path : String = DEFAULT_PLAN,
                   @overrides_path : String? = DEFAULT_OVERRIDES,
                   @plan_digest : String? = nil,
                   @overrides_digest : String? = nil,
                   @report_dir : String? = DEFAULT_REPORTS,
                   @invalidated_at : String? = nil,
                   @invalidation_reason : String? = nil,
                   @progress : Progress = Progress.new,
                   @format_version : Int32 = FORMAT_VERSION)
    end

    # Load state from *path*, returning nil when the file does not exist.
    def self.load?(path : String = DEFAULT_PATH) : SysrootBuildState?
      return nil unless File.exists?(path)
      from_json(File.read(path))
    end

    # Load state from *path*, raising when the file does not exist.
    def self.load(path : String = DEFAULT_PATH) : SysrootBuildState
      raise "Missing sysroot build state #{path}" unless File.exists?(path)
      from_json(File.read(path))
    end

    # Load state from *path* if present; otherwise initialize a new state file.
    # Always updates the metadata fields to reflect the current runner config.
    def self.load_or_init(path : String = DEFAULT_PATH,
                          plan_path : String = DEFAULT_PLAN,
                          overrides_path : String? = DEFAULT_OVERRIDES,
                          report_dir : String? = DEFAULT_REPORTS) : SysrootBuildState
      state = load?(path) || new(plan_path: plan_path, overrides_path: overrides_path, report_dir: report_dir)
      state.plan_path = plan_path
      state.overrides_path = overrides_path
      state.report_dir = report_dir
      state.reconcile_inputs!
      state.touch!
      state
    end

    # Persist the state JSON to disk.
    def save(path : String = DEFAULT_PATH) : Nil
      FileUtils.mkdir_p(Path[path].parent)
      File.write(path, to_json)
    end

    # Returns true when the given *step_name* has already completed successfully
    # within *phase_name*.
    def completed?(phase_name : String, step_name : String) : Bool
      progress.completed_steps[phase_name]?.try(&.includes?(step_name)) || false
    end

    # Record that *step_name* finished successfully within *phase_name*.
    def mark_success(phase_name : String, step_name : String) : Nil
      progress.current_phase = phase_name
      steps = (progress.completed_steps[phase_name]? || [] of String)
      unless steps.includes?(step_name)
        steps << step_name
        progress.completed_steps[phase_name] = steps
      end
      progress.last_success = StepRef.new(phase: phase_name, step: step_name, occurred_at: Time.utc.to_s)
      touch!
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
      touch!
    end

    # Update `updated_at` to the current UTC time.
    def touch! : Nil
      self.updated_at = Time.utc.to_s
    end

    # Ensure stored digests match the current plan/overrides files.
    #
    # When the plan or overrides inputs change, this clears completed steps so
    # the runner does not incorrectly skip work based on stale state.
    def reconcile_inputs! : Nil
      previous_plan = plan_digest
      previous_overrides = overrides_digest
      current_plan = digest_for?(plan_path)
      current_overrides = overrides_path ? digest_for?(overrides_path.not_nil!) : nil

      self.plan_digest = current_plan
      self.overrides_digest = current_overrides

      return if progress.completed_steps.empty?

      changed = false
      changed ||= previous_plan != current_plan
      changed ||= previous_overrides != current_overrides
      return unless changed

      progress.completed_steps.clear
      progress.current_phase = nil
      progress.last_success = nil
      progress.last_failure = nil
      self.invalidated_at = Time.utc.to_s
      self.invalidation_reason = "Build plan/overrides changed; cleared completed steps"
    end

    private def digest_for?(path : String) : String?
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
