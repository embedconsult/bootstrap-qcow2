require "json"
require "log"
require "digest/sha256"
require "file_utils"
require "random/secure"
require "time"
require "./build_plan"
require "./build_plan_overrides"
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
    @workspace : SysrootWorkspace?

    @[JSON::Field(ignore: true)]
    property plan : BuildPlan = BuildPlan.new([] of BuildPhase)

    @[JSON::Field(ignore: true)]
    property overrides : BuildPlanOverrides? = nil

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

    # true when the overrides digest changed since the last load.
    @[JSON::Field(ignore: true)]
    property overrides_changed : Bool = false

    # Timestamp (UTC, ISO8601) for the most recent state invalidation.
    property invalidated_at : String?

    # Human-readable reason for invalidating runner progress.
    property invalidation_reason : String?

    # Runner progress tracked per phase/package.
    getter progress : Progress = Progress.new

    # Active workspace for this build state.
    @[JSON::Field(ignore: true)]
    def workspace : SysrootWorkspace
      @workspace.not_nil!
    end

    def workspace=(workspace : SysrootWorkspace) : SysrootWorkspace
      @workspace = workspace
    end

    # Initialize the build state, loading any persisted state from disk.
    def initialize(@workspace : SysrootWorkspace = SysrootWorkspace.new,
                   @rootfs_id : String = Random::Secure.hex(8),
                   @created_at : String = Time.utc.to_s,
                   @updated_at : String? = nil,
                   @plan_digest : String? = nil,
                   @overrides_digest : String? = nil,
                   @invalidated_at : String? = nil,
                   @invalidation_reason : String? = nil,
                   @progress : Progress = Progress.new,
                   @format_version : Int32 = FORMAT_VERSION,
                   ignore_overrides : Bool = false,
                   invalidate_on_overrides : Bool = false)
      Log.debug { "Initializing SysrootBuildState (workspace=#{workspace} workspace.host_dir=#{workspace.host_workdir})" }
      @plan = BuildPlan.new([] of BuildPhase)
      saved_plan = on_disk_plan
      @plan = saved_plan.not_nil! unless saved_plan.nil?
      current_overrides_digest = on_disk_overrides_digest
      # Apply overrides before restoring state so the in-memory plan is the
      # resolved version used for resume decisions.
      apply_overrides unless ignore_overrides
      # Restore persisted metadata and progress after loading the plan so the
      # persisted plan digest and progress markers remain intact.
      previous_state = on_disk_state
      restore_from(previous_state) if previous_state
      # Refresh plan/overrides digests from disk for resume and invalidation
      # decisions (these are compared against restored values when present).
      @plan_digest = on_disk_plan_digest
      @overrides_digest = current_overrides_digest unless ignore_overrides
      update_overrides_tracking(previous_state, current_overrides_digest, ignore_overrides, invalidate_on_overrides)
    end

    # Current rootfs-relative state path
    def state_path : Path
      workspace.log_path / STATE_FILE
    end

    # Resolve the plan path into the active namespace.
    def plan_path : Path
      workspace.log_path / PLAN_FILE
    end

    # Resolve overrides path into the active namespace.
    def overrides_path : Path
      workspace.log_path / OVERRIDES_FILE
    end

    # Resolve report directory path into the active namespace.
    def report_dir : Path
      workspace.log_path / REPORT_DIR_NAME
    end

    # Returns true when the build plan file exists for this workspace.
    def plan_exists? : Bool
      File.exists?(plan_path)
    end

    # Returns true when the overrides file exists for this workspace.
    def overrides_exists? : Bool
      File.exists?(overrides_path)
    end

    # Returns true when the build state file exists for this workspace.
    def state_exists? : Bool
      File.exists?(state_path)
    end

    # Apply overrides to *plan* and return the resolved plan.
    def resolve_plan(plan : BuildPlan,
                     use_overrides : Bool = true) : BuildPlan
      @plan = plan
      path = use_overrides ? self.overrides_path : nil
      if path && File.exists?(path)
        Log.info { "Applying build plan overrides from #{path}" }
        overrides = BuildPlanOverrides.from_json(File.read(path))
        @plan = overrides.apply(@plan.not_nil!)
      end
      @plan.not_nil!
    end

    # Persist the current build plan to the workspace and refresh its digest.
    def save_plan : String?
      plan_json = @plan.to_pretty_json
      FileUtils.mkdir_p(plan_path.parent)
      File.write(plan_path, plan_json)
      Log.info { "Saved build plan at #{plan_path}" }
      @plan_digest = on_disk_plan_digest
    end

    # Persist overrides to disk and refresh their digest.
    def save_overrides : String?
      overrides_json = @overrides.to_pretty_json
      FileUtils.mkdir_p(overrides_path.parent)
      File.write(overrides_path, overrides_json)
      @overrides_digest = on_disk_overrides_digest
    end

    # Return the next incomplete phase/step for the plan.
    def next_incomplete_step : Tuple(String?, String?)
      @plan.phases.each do |phase|
        phase.steps.each do |step|
          next if completed?(phase.name, step.name)
          return {phase.name, step.name}
        end
      end
      {nil, nil}
    end

    # Load persisted state from the workspace, or nil when missing.
    def on_disk_state : SysrootBuildState?
      return nil unless state_exists?
      state = SysrootBuildState.from_json(File.read(state_path))
      state.workspace = workspace
      state
    end

    # Load the build plan JSON from the workspace, or nil when missing.
    def on_disk_plan : BuildPlan?
      plan_exists? ? BuildPlan.parse(File.read(plan_path)) : nil
    end

    # Load overrides JSON from the workspace, or nil when missing.
    def on_disk_overrides : BuildPlanOverrides?
      overrides_exists? ? BuildPlanOverrides.from_json(File.read(overrides_path)) : nil
    end

    # Return the digest for the on-disk build plan, if present.
    def on_disk_plan_digest : String?
      self.class.digest_for?(plan_path)
    end

    # Return the digest for the on-disk overrides file, if present.
    def on_disk_overrides_digest : String?
      self.class.digest_for?(overrides_path)
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
    end

    # Update the current phase tracking marker.
    def mark_current_phase(phase_name : String?) : Nil
      @progress.current_phase = phase_name
      touch
    end

    # Update `updated_at` to the current UTC time.
    def touch : Nil
      @updated_at = Time.utc.to_s
      save
    end

    # Clear completed steps and record a reason for invalidation.
    def invalidate_progress!(reason : String) : Nil
      @progress.completed_steps.clear
      @progress.current_phase = nil
      @progress.last_success = nil
      @progress.last_failure = nil
      @invalidated_at = Time.utc.to_s
      @invalidation_reason = reason
      touch
    end

    # Apply overrides from disk to the loaded build plan.
    private def apply_overrides
      return unless overrides_path && overrides_exists?
      Log.info { "Applying build plan overrides from #{overrides_path}" }
      overrides = BuildPlanOverrides.from_json(File.read(overrides_path))
      old_plan = @plan.not_nil!
      @plan = overrides.apply(old_plan)
    end

    private def update_overrides_tracking(previous_state : SysrootBuildState?,
                                          current_overrides_digest : String?,
                                          ignore_overrides : Bool,
                                          invalidate_on_overrides : Bool) : Nil
      return if ignore_overrides
      return unless previous_state
      @overrides_changed = previous_state.overrides_digest != current_overrides_digest
      if invalidate_on_overrides && @overrides_changed
        invalidate_progress!("Overrides changed; cleared completed steps")
      end
    end

    # Restore persisted metadata and progress from *previous_state*.
    private def restore_from(previous_state : SysrootBuildState) : Nil
      @rootfs_id = previous_state.rootfs_id
      @created_at = previous_state.created_at
      @updated_at = previous_state.updated_at
      @plan_digest = previous_state.plan_digest
      @overrides_digest = previous_state.overrides_digest
      @invalidated_at = previous_state.invalidated_at
      @invalidation_reason = previous_state.invalidation_reason
      @progress = previous_state.progress.not_nil!
    end

    private def phase_names(phases : Array(BuildPhase)) : Array(String)?
      phases.map { |phase| phase.name }
    end

    def filtered_phases(by_name : String = "all",
                        by_state : Bool = false,
                        by_packages : Array(String) = [] of String,) : Array(BuildPhase)
      selected_phases = @plan.phases.dup
      Log.debug { "Testing #{phase_names(selected_phases)} for inclusion in selected_phases" }
      selected_phases.reject! { |phase| phase.name != by_name } unless by_name == "all"
      Log.debug { "Phases #{phase_names(selected_phases)} remain after rejection by_name: #{by_name}" }
      raise "Unknown build phase #{by_name}" if selected_phases.empty?

      if by_state
        selected_phases = selected_phases.compact_map do |phase|
          steps = phase.steps.reject { |step| completed?(phase.name, step.name) }
          Log.debug { "Remaining steps in phase '#{phase.name}': #{steps}" }
          steps.empty? ? nil : phase.with_steps(steps)
        end
      end
      Log.debug { "Phases #{phase_names(selected_phases)} remain after rejection by_state: #{by_state}" }

      if by_packages.present?
        requested = by_packages.uniq.to_set
        matched = selected_phases.flat_map(&.steps).map(&.name).select { |name| requested.includes?(name) }.to_set
        missing = requested.reject { |name| matched.includes?(name) }
        raise "Requested package(s) not found in selected phases: #{missing.join(", ")}" unless missing.empty?

        selected_phases = selected_phases.compact_map do |phase|
          steps = phase.steps.select { |step| requested.includes?(step.name) }
          steps.empty? ? nil : phase.with_steps(steps)
        end
        raise "No matching packages found in selected phases: #{by_packages.join(", ")}" if selected_phases.empty?
      end
      Log.debug { "Phases #{phase_names(selected_phases)} remain after rejection by_packages: #{by_packages}" }
      selected_phases
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
