require "json"
require "log"
require "file_utils"
require "process"
require "random/secure"
require "set"
require "time"
require "./build_plan"
require "./build_plan_overrides"
require "./cli"
require "./sysroot_build_state"
require "./sysroot_workspace"
require "./sysroot_namespace"
require "./step_runner"

module Bootstrap
  # SysrootRunner replays build plan phases and delegates step execution to
  # StepRunner for the active namespace.
  class SysrootRunner < CLI
    DEFAULT_PHASE = "default"

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

    # Execute a build plan from a path on disk.
    def self.run_plan(plan_path : String,
                      runner,
                      phase : String? = nil,
                      packages : Array(String) = [] of String,
                      report_dir : String? = nil,
                      dry_run : Bool = false,
                      resume : Bool = true,
                      state_path : String? = nil,
                      overrides_path : String? = nil,
                      use_default_overrides : Bool = true,
                      workspace : SysrootWorkspace? = nil) : Nil
      plan = BuildPlan.parse(File.read(plan_path))
      run_plan(plan,
        runner,
        phase: phase,
        packages: packages,
        report_dir: report_dir,
        dry_run: dry_run,
        resume: resume,
        state_path: state_path,
        overrides_path: overrides_path,
        use_default_overrides: use_default_overrides,
        workspace: workspace)
    end

    # Execute a build plan with a custom step runner.
    def self.run_plan(plan : BuildPlan,
                      runner,
                      phase : String? = nil,
                      packages : Array(String) = [] of String,
                      report_dir : String? = nil,
                      dry_run : Bool = false,
                      resume : Bool = true,
                      state_path : String? = nil,
                      overrides_path : String? = nil,
                      use_default_overrides : Bool = true,
                      workspace : SysrootWorkspace? = nil) : Nil
      resolved_plan = plan
      resolved_plan = BuildPlan.new(resolved_plan.phases_for_current_namespace(workspace), resolved_plan.format_version) if workspace
      resolved_plan = apply_overrides(resolved_plan, overrides_path, use_default_overrides, workspace)

      selected_phase = phase || default_phase(resolved_plan)
      phases = resolved_plan.selected_phases(selected_phase)
      phases = filter_phases_by_packages(phases, packages) if packages.any?

      state = load_state(workspace, state_path)
      state_save_path = state_path ? Path[state_path] : nil
      if state && resume
        phases = filter_phases_by_state(phases, state)
      end

      prepare_destdirs(phases)

      if dry_run
        print_dry_run(phases)
        return
      end

      phases.each_with_index do |phase_entry, idx|
        if state
          state.mark_current_phase(phase_entry.name)
          save_state(state, state_save_path)
        end
        run_phase(phase_entry, runner, report_dir: report_dir, state: state, resume: resume, state_path: state_save_path)
        if state
          state.mark_current_phase(phases[idx + 1]?.try(&.name))
          save_state(state, state_save_path)
        end
      end
    end

    # Run a single phase from the plan.
    def self.run_phase(phase : BuildPhase,
                       runner,
                       report_dir : String?,
                       allow_outside_rootfs : Bool = false,
                       state : SysrootBuildState? = nil,
                       resume : Bool = true,
                       state_path : Path? = nil) : Nil
      if phase.namespace == "bq2" && !allow_outside_rootfs
        raise "Refusing to run #{phase.name} outside the rootfs" unless inside_rootfs?
      end
      Log.info { "Executing phase #{phase.name} (namespace=#{phase.namespace})" }
      Log.info { "**** #{phase.description} ****" }
      run_steps(phase, phase.steps, runner, report_dir: report_dir, state: state, resume: resume, state_path: state_path)
      Log.info { "Completed phase #{phase.name}" }
    end

    # Execute a list of BuildStep entries, stopping immediately on failure.
    def self.run_steps(phase : BuildPhase,
                       steps : Array(BuildStep),
                       runner,
                       report_dir : String?,
                       state : SysrootBuildState? = nil,
                       resume : Bool = true,
                       state_path : Path? = nil) : Nil
      Log.info { "Executing #{steps.size} build steps" }
      steps.each do |step|
        if resume && state && state.completed?(phase.name, step.name)
          Log.info { "Skipping previously completed #{phase.name}/#{step.name}" }
          next
        end
        Log.info { "Building #{step.name} in #{step.workdir} (phase=#{phase.name})" }
        begin
          runner.run(phase, step)
          if state
            state.mark_success(phase.name, step.name)
            save_state(state, state_path)
          end
        rescue ex
          report_path = report_dir ? write_failure_report(report_dir, phase, step, ex) : nil
          if state
            state.mark_failure(phase.name, step.name, ex.message, report_path)
            save_state(state, state_path)
          end
          raise ex
        end
      end
      Log.info { "All build steps completed" }
    end

    # Run build plan phases/steps from the CLI.
    private def self.run_runner(args : Array(String)) : Int32
      packages = [] of String
      start_phase : String? = DEFAULT_PHASE
      report = true
      resume = true
      dry_run = false
      host_workdir : Path? = nil
      extra_binds = [] of Tuple(Path, Path)
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-runner [options]") do |p|
        p.on("--phase NAME", "Select first build phase to run (default: auto)") { |name| start_phase = name }
        p.on("--package NAME", "Only run the named package(s) (repeatable)") { |name| packages << name }
        p.on("--no-report", "Disable failure report writing") { report = false }
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

      build_state = SysrootBuildState.load_or_init(workspace)
      plan_path = build_state.plan_path.to_s
      overrides_path = build_state.overrides_path.to_s
      report_dir = report ? build_state.report_dir.to_s : nil

      step_runner = StepRunner.new(workspace: workspace)
      run_plan(
        plan_path,
        step_runner,
        phase: start_phase == DEFAULT_PHASE ? nil : start_phase,
        packages: packages,
        report_dir: report_dir,
        dry_run: dry_run,
        resume: resume,
        state_path: resume ? build_state.state_path.to_s : nil,
        overrides_path: overrides_path,
        use_default_overrides: true,
        workspace: workspace
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

      state = SysrootBuildState.load_or_init(workspace)
      puts "plan_path=#{state.plan_path}"
      puts "state_path=#{state.state_path}"
      if (failure = state.progress.last_failure)
        puts "last_failure=#{failure.phase}/#{failure.step}"
      end
      0
    end

    # Run the finalize-rootfs phase to emit a prefix-free rootfs tarball.
    private def self.run_tarball(args : Array(String)) : Int32
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-tarball [options]") do |p|
      end
      return CLI.print_help(parser) if help
      STDERR.puts "sysroot-tarball is not yet wired up"
      1
    end

    private def self.apply_overrides(plan : BuildPlan,
                                     overrides_path : String?,
                                     use_default_overrides : Bool,
                                     workspace : SysrootWorkspace?) : BuildPlan
      return plan if overrides_path.nil? && !use_default_overrides
      path = overrides_path
      if path.nil? && use_default_overrides && workspace
        path = (workspace.log_path / SysrootBuildState::OVERRIDES_FILE).to_s
      end
      return plan unless path && File.exists?(path)
      Log.info { "Applying build plan overrides from #{path}" }
      overrides = BuildPlanOverrides.from_json(File.read(path))
      overrides.apply(plan)
    end

    private def self.default_phase(plan : BuildPlan) : String
      return plan.phases.first.name if plan.phases.size == 1
      if inside_rootfs?
        bq2_phase = plan.phases.find { |phase| phase.namespace == "bq2" }
        return bq2_phase.name if bq2_phase
      end
      plan.phases.first.name
    end

    private def self.inside_rootfs? : Bool
      marker = ENV["BQ2_ROOTFS_MARKER"]?
      return File.exists?(marker) if marker
      File.exists?(Path["/#{SysrootWorkspace::ROOTFS_MARKER_NAME}"])
    end

    private def self.filter_phases_by_state(phases : Array(BuildPhase), state : SysrootBuildState) : Array(BuildPhase)
      phases.compact_map do |phase|
        remaining = phase.steps.reject { |step| state.completed?(phase.name, step.name) }
        next nil if remaining.empty?
        BuildPhase.new(
          name: phase.name,
          description: phase.description,
          workdir: phase.workdir,
          namespace: phase.namespace,
          install_prefix: phase.install_prefix,
          destdir: phase.destdir,
          env: phase.env,
          steps: remaining,
        )
      end
    end

    private def self.filter_phases_by_packages(phases : Array(BuildPhase), packages : Array(String)) : Array(BuildPhase)
      matched = Set(String).new
      phases.each do |phase|
        phase.steps.each do |step|
          matched << step.name if packages.includes?(step.name)
        end
      end
      missing = packages.uniq.reject { |name| matched.includes?(name) }
      raise "Requested package(s) not found in selected phases: #{missing.join(", ")}" unless missing.empty?

      selected = phases.compact_map do |phase|
        steps = phase.steps.select { |step| packages.includes?(step.name) }
        next nil if steps.empty?
        BuildPhase.new(
          name: phase.name,
          description: phase.description,
          workdir: phase.workdir,
          namespace: phase.namespace,
          install_prefix: phase.install_prefix,
          destdir: phase.destdir,
          env: phase.env,
          steps: steps,
        )
      end
      raise "No matching packages found in selected phases: #{packages.join(", ")}" if selected.empty?
      selected
    end

    private def self.prepare_destdirs(phases : Array(BuildPhase))
      phases.each do |phase|
        next unless destdir = phase.destdir
        prepare_destdir(destdir)
      end
    end

    # Creates a minimal directory skeleton for `DESTDIR` installs. The intent is
    # to keep packages with hard-coded expectations (e.g., `/usr/bin`) from
    # failing when the destdir tree is initially empty.
    private def self.prepare_destdir(destdir : String)
      FileUtils.mkdir_p(destdir)
      %w[bin dev etc lib opt proc sys tmp usr var workspace].each do |subdir|
        FileUtils.mkdir_p(File.join(destdir, subdir))
      end
      FileUtils.mkdir_p(File.join(destdir, "usr/bin"))
      FileUtils.mkdir_p(File.join(destdir, "usr/sbin"))
      FileUtils.mkdir_p(File.join(destdir, "usr/lib"))
      FileUtils.mkdir_p(File.join(destdir, "var/lib"))
    end

    private def self.print_dry_run(phases : Array(BuildPhase)) : Nil
      phases.each do |phase|
        phase.steps.each do |step|
          payload = {
            "phase" => phase,
            "step"  => step,
          }
          puts payload.to_pretty_json
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
          "workdir"        => phase.workdir,
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

    private def self.load_state(workspace : SysrootWorkspace?, state_path : String?) : SysrootBuildState?
      return nil unless workspace
      return SysrootBuildState.load(workspace, Path[state_path]) if state_path
      SysrootBuildState.load_or_init(workspace)
    rescue ex
      Log.warn { "Failed to load state: #{ex.message}" }
      nil
    end

    private def self.save_state(state : SysrootBuildState, state_path : Path?) : Nil
      if state_path
        state.save(state_path)
      else
        state.save
      end
    end
  end
end
