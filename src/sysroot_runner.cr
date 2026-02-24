require "json"
require "log"
require "file_utils"
require "process"
require "random/secure"
require "set"
require "time"
require "./build_plan"
require "./cli"
require "./sysroot_build_state"
require "./sysroot_workspace"
require "./sysroot_namespace"
require "./step_runner"

module Bootstrap
  # SysrootRunner replays build plan phases and delegates step execution to
  # StepRunner for the active namespace.
  class SysrootRunner < CLI
    @state : SysrootBuildState
    @step_runner : StepRunner
    property phase : String
    property packages : Array(String)
    property report : Bool
    property dry_run : Bool
    property dry_run_io : IO?
    property resume : Bool

    def initialize(@state : SysrootBuildState = SysrootBuildState.new,
                   @step_runner : StepRunner = StepRunner.new,
                   @phase : String = "all",
                   @packages : Array(String) = [] of String,
                   @report : Bool = true,
                   @dry_run : Bool = false,
                   @dry_run_io : IO? = nil,
                   @resume : Bool = true) : Nil
      Log.debug { "Created new SysrootRunner (phase=#{@phase}, packages=#{packages}, report=#{report}, dry_run=#{dry_run}, resume=#{@resume})" }
    end

    # Summarize the sysroot runner CLI behavior for help output.
    def self.summary : String
      "Execute build plan to build rootfs and emit rootfs tarball"
    end

    # Return additional command aliases handled by the sysroot runner.
    def self.aliases : Array(String)
      ["sysroot-status", "sysroot-tarball"]
    end

    # Describe help output entries for sysroot runner commands.
    def self.help_entries : Array(Tuple(String, String))
      [
        {"sysroot-runner", "Execute build plan to build rootfs"},
        {"sysroot-status", "Print current sysroot build phase"},
        {"sysroot-tarball", "Emit a prefix-free rootfs tarball"},
      ]
    end

    # Dispatch sysroot runner subcommands by command name.
    def self.run(args : Array(String), command_name : String) : Int32
      case command_name
      when "sysroot-runner"
        run_runner(args)
      when "sysroot-status"
        run_status(args)
      when "sysroot-tarball"
        run_tarball(args)
      else
        raise "Unknown sysroot runner command #{command_name}"
      end
    end

    # Execute a build plan from a preloaded build state.
    def run_plan
      run_started_at = monotonic_now
      run_succeeded = false
      Log.debug { "Running plan filtered by_name: #{@phase}, by_state: #{@resume}, by_packages: #{@packages}" }
      selected_phases = @state.filtered_phases(by_name: @phase, by_state: @resume, by_packages: @packages)
      Log.debug { "selected_phases=#{selected_phases.map { |phase| phase.name }}" }

      begin
        if @dry_run
          print_dry_run(selected_phases)
          run_succeeded = true
          return
        end

        selected_phases.each_with_index do |phase_entry, idx|
          if @resume
            Log.debug { "Marking phase #{phase_entry.name} as current" }
            @state.mark_current_phase(phase_entry.name)
          end
          if @state.workspace.namespace_switch_required?(phase_entry.namespace)
            Log.info { "Entering namespace #{phase_entry.namespace} for phase #{phase_entry.name}" }
            @state.workspace.enter_namespace(phase_entry.namespace)
          end
          run_phase(phase_entry)
          if @resume
            next_phase = @state.plan.phases[idx + 1]?.try(&.name)
            Log.debug { "Marking next phase #{next_phase} as current" }
            @state.mark_current_phase(next_phase)
          end
        end

        run_succeeded = true
      ensure
        run_duration = monotonic_elapsed_since(run_started_at)
        state = run_succeeded ? "Completed" : "Failed"
        Log.info { "#{state} sysroot run in #{format_duration(run_duration)}" }
      end
    end

    # Run a single phase from the plan.
    private def run_phase(phase : BuildPhase)
      phase_started_at = monotonic_now
      phase_succeeded = false
      Log.info { "Executing phase #{phase.name} (namespace=#{phase.namespace})" }
      Log.info { "**** #{phase.description} ****" }
      begin
        if destdir = phase.destdir
          FileUtils.mkdir_p(destdir)
        end
        @step_runner.with_phase_environment(phase) do
          run_steps(phase)
        end
        phase_succeeded = true
      ensure
        phase_duration = monotonic_elapsed_since(phase_started_at)
        status = phase_succeeded ? "Completed" : "Failed"
        Log.info { "#{status} phase #{phase.name} in #{format_duration(phase_duration)}" }
      end
    end

    # Execute a list of BuildStep entries, stopping immediately on failure.
    private def run_steps(phase : BuildPhase)
      Log.info { "Executing #{phase.steps.size} build steps" }
      effective_report_dir = @report ? @state.report_dir : nil
      @step_runner.report_dir = effective_report_dir.try(&.to_s)
      phase.steps.each do |step|
        if @resume && @state.completed?(phase.name, step.name)
          Log.info { "Skipping previously completed #{phase.name}/#{step.name}" }
          next
        end
        Log.info { "Building #{step.name} in #{step.workdir} (phase=#{phase.name})" }
        begin
          @step_runner.run(phase, step)
          if resume
            @state.mark_success(phase.name, step.name)
          end
        rescue ex
          report_path = effective_report_dir ? write_failure_report(phase, step, ex, report_dir: effective_report_dir) : nil
          if resume
            @state.mark_failure(phase.name, step.name, ex.message, report_path)
          end
          raise ex
        end
      end
      @step_runner.report_dir = nil
      Log.info { "All build steps completed" }
    end

    # Run build plan phases/steps from the CLI.
    private def self.run_runner(args : Array(String)) : Int32
      packages = [] of String
      start_phase : String = "all"
      report = true
      resume = true
      dry_run = false
      invalidate_overrides = false
      host_workdir : Path? = nil
      extra_binds = [] of Tuple(Path, Path)
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-runner [options]") do |p|
        p.on("--phase NAME", "Select first build phase to run (default: auto)") { |name| start_phase = name }
        p.on("--package NAME", "Only run the named package(s) (repeatable)") { |name| packages << name }
        p.on("--no-report", "Disable failure report writing") { report = false }
        p.on("--invalidate-overrides", "Invalidate completed steps when overrides change") { invalidate_overrides = true }
        p.on("--no-resume", "Disable resume/state tracking (useful when the default state path is not writable)") { resume = false }
        p.on("--dry-run", "Print plan entries and exit") { dry_run = true }
        p.on("--workdir=PATH", "Starting path for looking for build plan (default: #{SysrootWorkspace::DEFAULT_HOST_WORKDIR})") { |path| host_workdir = Path[path] }
        p.on("--bind=SRC:DST", "Bind-mount SRC into DST inside the rootfs (repeatable)") do |val|
          extra_binds << parse_bind_spec(val)
        end
      end
      return CLI.print_help(parser) if help

      begin
        workspace = SysrootWorkspace.new(host_workdir: host_workdir, extra_binds: extra_binds)
      rescue ex
        STDERR.puts "Please build out the workspace first with `bq2 sysroot-builder`: #{ex.message}"
        return -1
      end

      build_state = SysrootBuildState.new(workspace: workspace, invalidate_on_overrides: invalidate_overrides)
      Log.info { "Running plan #{build_state.plan_path} with overrides #{build_state.overrides_path} (namespace=#{workspace.namespace})" }
      if resume && build_state.overrides_changed && !invalidate_overrides
        Log.warn { "Overrides changed; completed steps are preserved. To re-run affected steps, pass --invalidate-overrides, or clear the state." }
      end

      step_runner = StepRunner.new(workspace: workspace)
      step_runner.skip_existing_sources = resume
      runner = SysrootRunner.new(state: build_state, step_runner: step_runner, phase: start_phase, packages: packages, report: report, resume: resume, dry_run: dry_run)
      runner.run_plan
      0
    end

    private def self.parse_bind_spec(value : String) : Tuple(Path, Path)
      parts = value.split(":", 2)
      raise "Expected --bind=SRC:DST" unless parts.size == 2
      src = Path[parts[0]].expand
      dst_raw = parts[1]
      dst_clean = dst_raw.starts_with?("/") ? dst_raw[1..] : dst_raw
      {src, Path[dst_clean]}
    end

    # Print the current build status and next phase/step.
    private def self.run_status(args : Array(String)) : Int32
      host_workdir : Path? = nil
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-status [options]") do |p|
        p.on("--workdir=PATH", "Starting path for looking for build plan (default: #{SysrootWorkspace::DEFAULT_HOST_WORKDIR})") { |path| host_workdir = Path[path] }
      end
      return CLI.print_help(parser) if help

      begin
        workspace = SysrootWorkspace.new(host_workdir: host_workdir)
      rescue ex
        Log.error { "No valid workspace found, build out the workspace first with `bq2 sysroot-builder`: #{ex.message}" }
        return -1
      end

      state = SysrootBuildState.new(workspace: workspace)
      next_phase, next_step = state.next_incomplete_step
      Log.info { "plan_path=#{state.plan_path}" }
      Log.info { "state_path=#{state.state_path}" }
      Log.info { "report_dir=#{state.report_dir}" }
      Log.info { "current_phase=#{state.progress.current_phase}" } if state.progress.current_phase
      if next_phase
        Log.info { "next_phase=#{next_phase}" }
        Log.info { "next_step=#{next_step}" } if next_step
      else
        Log.info { "next_phase=complete" }
      end
      if (failure = state.progress.last_failure)
        Log.info { "last_failure=#{failure.phase}/#{failure.step}" }
        if (report_path = failure.report_path)
          Log.info { "last_failure_report=#{report_path}" }
        end
      end
      0
    end

    # TODO: Get this wired up
    # Run the finalize-rootfs phase to emit a prefix-free rootfs tarball.
    private def self.run_tarball(args : Array(String)) : Int32
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-tarball [options]") do |p|
      end
      return CLI.print_help(parser) if help
      STDERR.puts "sysroot-tarball is not yet wired up"
      1
    end

    private def print_dry_run(phases : Array(BuildPhase)) : Nil
      io = @dry_run_io || STDOUT
      phases.each do |phase|
        phase.steps.each do |step|
          payload = {
            "phase" => phase,
            "step"  => step,
          }
          io.puts payload.to_pretty_json
        end
      end
    end

    # Return a monotonic timestamp compatible with multiple Crystal versions.
    private def monotonic_now
      {% if Time.class.has_method?(:instant) %}
        Time.instant
      {% else %}
        Time.monotonic
      {% end %}
    end

    # Return elapsed monotonic time since +started_at+.
    private def monotonic_elapsed_since(started_at) : Time::Span
      monotonic_now - started_at
    end

    # Format elapsed monotonic duration in a stable human-readable form.
    private def format_duration(duration : Time::Span) : String
      milliseconds = duration.total_milliseconds
      if milliseconds >= 1000
        "#{"%.3f" % duration.total_seconds}s"
      else
        "#{milliseconds.round(1)}ms"
      end
    end

    private def write_failure_report(phase : BuildPhase, step : BuildStep, ex : Exception, report_dir : Path = @state.report_dir) : String?
      FileUtils.mkdir_p(report_dir)
      timestamp = Time.utc.to_s("%Y%m%dT%H%M%S.%LZ")
      phase_slug = slugify(phase.name)
      step_slug = slugify(step.name)
      disambiguator = Random::Secure.hex(4)
      report_path = File.join(report_dir, "#{timestamp}-#{phase_slug}-#{step_slug}-#{disambiguator}.json")

      argv = nil
      exit_code = nil
      output_log = nil
      if ex.is_a?(CommandFailedError)
        argv = ex.argv
        exit_code = ex.exit_code
        output_log = ex.output_path
      end
      effective_env = phase.env.dup
      step.env.each { |key, value| effective_env[key] = value }

      report = {
        "format_version" => 1,
        "occurred_at"    => timestamp,
        "phase"          => {
          "name"           => phase.name,
          "namespace"      => phase.namespace,
          "install_prefix" => phase.install_prefix,
          "destdir"        => phase.destdir,
          "env"            => phase.env,
        },
        "step" => {
          "name"            => step.name,
          "strategy"        => step.strategy,
          "workdir"         => step.workdir,
          "install_prefix"  => step.install_prefix,
          "destdir"         => step.destdir,
          "env"             => step.env,
          "effective_env"   => effective_env,
          "configure_flags" => step.configure_flags,
          "patches"         => step.patches,
        },
        "command"    => argv,
        "exit_code"  => exit_code,
        "output_log" => output_log,
        "error"      => ex.message,
      }.to_pretty_json

      File.write(report_path, report)
      Log.error { "Wrote build failure report to #{report_path}" }
      report_path
    rescue report_ex
      Log.warn { "Failed to write build failure report: #{report_ex.message}" }
      nil
    end

    private def slugify(value : String) : String
      value.gsub(/[^A-Za-z0-9]+/, "_").gsub(/^_+|_+$/, "").downcase
    end
  end
end
