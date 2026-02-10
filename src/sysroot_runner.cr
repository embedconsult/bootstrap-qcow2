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
    def self.run_plan(state : SysrootBuildState,
                      runner : StepRunner = StepRunner.new,
                      phase : String = "all",
                      packages : Array(String) = [] of String,
                      report : Bool = true,
                      report_dir : String? = nil,
                      dry_run : Bool = false,
                      dry_run_io : IO? = nil,
                      resume : Bool = true) : Nil
      phases = state.filtered_phases(by_name: phase, by_state: resume, by_packages: packages)

      if dry_run
        print_dry_run(phases, dry_run_io || STDOUT)
        return
      end

      phases.each_with_index do |phase_entry, idx|
        if resume && state
          state.mark_current_phase(phase_entry.name)
        end
        enter_phase_namespace(phase_entry, state.workspace) if state.workspace && namespace_switch_required?(phase_entry, state.workspace)
        run_phase(phase_entry, runner, report: report, report_dir: report_dir, state: state, resume: resume)
        if resume && state
          state.mark_current_phase(phases[idx + 1]?.try(&.name))
        end
      end
    end

    # Run a single phase from the plan.
    def self.run_phase(phase : BuildPhase,
                       runner,
                       report : Bool = true,
                       report_dir : String? = nil,
                       allow_outside_rootfs : Bool = false,
                       state : SysrootBuildState? = nil,
                       resume : Bool = true) : Nil
      if phase.namespace == "bq2" && !allow_outside_rootfs
        raise "Refusing to run #{phase.name} outside the rootfs" unless inside_rootfs?
      end
      Log.info { "Executing phase #{phase.name} (namespace=#{phase.namespace})" }
      Log.info { "**** #{phase.description} ****" }
      if destdir = phase.destdir
        prepare_destdir(destdir)
      end
      run_steps(phase, phase.steps, runner, report: report, report_dir: report_dir, state: state, resume: resume)
      Log.info { "Completed phase #{phase.name}" }
    end

    # Execute a list of BuildStep entries, stopping immediately on failure.
    def self.run_steps(phase : BuildPhase,
                       steps : Array(BuildStep),
                       runner,
                       report : Bool = true,
                       report_dir : String? = nil,
                       state : SysrootBuildState? = nil,
                       resume : Bool = true) : Nil
      Log.info { "Executing #{steps.size} build steps" }
      effective_report_dir = report ? resolve_report_dir(report_dir, state) : nil
      steps.each do |step|
        if resume && state && state.completed?(phase.name, step.name)
          Log.info { "Skipping previously completed #{phase.name}/#{step.name}" }
          next
        end
        Log.info { "Building #{step.name} in #{step.workdir} (phase=#{phase.name})" }
        begin
          runner.run(phase, step)
          if resume && state
            state.mark_success(phase.name, step.name)
          end
        rescue ex
          report_path = effective_report_dir ? write_failure_report(effective_report_dir, phase, step, ex) : nil
          if resume && state
            state.mark_failure(phase.name, step.name, ex.message, report_path)
          end
          raise ex
        end
      end
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
      run_plan(
        build_state,
        step_runner,
        phase: start_phase,
        packages: packages,
        report: report,
        dry_run: dry_run,
        resume: resume
      )
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
        STDERR.puts "No valid workspace found, build out the workspace first with `bq2 sysroot-builder`: #{ex.message}"
        return -1
      end

      state = SysrootBuildState.new
      next_phase, next_step = state.next_incomplete_step
      puts "plan_path=#{state.plan_path}"
      puts "state_path=#{state.state_path}"
      puts "report_dir=#{state.report_dir}"
      puts "current_phase=#{state.progress.current_phase}" if state.progress.current_phase
      if next_phase
        puts "next_phase=#{next_phase}"
        puts "next_step=#{next_step}" if next_step
      else
        puts "next_phase=complete"
      end
      if (failure = state.progress.last_failure)
        puts "last_failure=#{failure.phase}/#{failure.step}"
        if (report_path = failure.report_path)
          puts "last_failure_report=#{report_path}"
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

    # TODO: Use SysrootWorkspace method for this
    private def self.inside_rootfs? : Bool
      marker = ENV["BQ2_ROOTFS_MARKER"]?
      return File.exists?(marker) if marker
      File.exists?(Path["/#{SysrootWorkspace::ROOTFS_MARKER_NAME}"])
    end

    # TODO: Use SysrootWorkspace method for this
    # Return the namespace label for the current workspace.
    private def self.namespace_name(workspace : SysrootWorkspace) : String
      workspace.namespace.label
    end

    # TODO: Use SysrootWorkspace method for this
    # Return true when the phase should execute in a different namespace.
    private def self.namespace_switch_required?(phase : BuildPhase, workspace : SysrootWorkspace) : Bool
      requested = SysrootWorkspace::Namespace.parse(phase.namespace)
      requested != workspace.namespace
    end

    # TODO: Use SysrootWorkspace method for this
    # Enter the requested phase namespace, if needed.
    private def self.enter_phase_namespace(phase : BuildPhase, workspace : SysrootWorkspace) : Nil
      requested = SysrootWorkspace::Namespace.parse(phase.namespace)
      case requested
      in .host?
        raise "Cannot enter host namespace from #{namespace_name(workspace)}" unless workspace.namespace.host?
      in .seed?
        if workspace.namespace.host?
          workspace.enter_seed_rootfs_namespace
        elsif workspace.namespace.seed?
          # Already in seed namespace.
        else
          raise "Cannot enter seed namespace from #{namespace_name(workspace)}"
        end
      in .bq2?
        if workspace.namespace.host?
          workspace.enter_bq2_rootfs_namespace
        elsif workspace.namespace.seed?
          workspace.enter_bq2_rootfs_namespace
        elsif workspace.namespace.bq2?
          # Already in bq2 namespace.
        else
          raise "Cannot enter bq2 namespace from #{namespace_name(workspace)}"
        end
      end
    end

    # Ensure the DESTDIR root exists before running installs that expect it.
    private def self.prepare_destdir(destdir : String)
      FileUtils.mkdir_p(destdir)
    end

    private def self.print_dry_run(phases : Array(BuildPhase), io : IO) : Nil
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

    private def self.write_failure_report(report_dir : String, phase : BuildPhase, step : BuildStep, ex : Exception) : String?
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

    private def self.slugify(value : String) : String
      value.gsub(/[^A-Za-z0-9]+/, "_").gsub(/^_+|_+$/, "").downcase
    end

    # Resolve the report directory for the active namespace or use a provided override.
    private def self.resolve_report_dir(report_dir : String?, state : SysrootBuildState?) : String?
      return report_dir if report_dir
      return nil unless state
      state.report_dir.to_s
    end
  end
end
