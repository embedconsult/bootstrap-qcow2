require "json"
require "log"
require "file_utils"
require "process"
require "random/secure"
require "set"
require "time"
require "./cli"
require "./sysroot_workspace"
require "./build_plan"
require "./sysroot_build_state"
require "./sysroot_namespace"
require "./step_runner"

module Bootstrap
  # SysrootRunner houses the logic that replays build steps, including changing into the appropriate namespace when needed using SysrootNamespace.
  # It is kept in a regular source file, rather than something like shell script pulled out of the JSON-formatted plan, to benefit from formatting, linting,
  # and spec unit tests. The main entrypoint registers the CLI class and dispatches into
  # the `run` helpers below. It can also be called from other coordinator classes like SysrootAllResume that can build the final output tarball.
  #
  # SysrootRunner utilizes:
  # * CLI for presenting the `sysroot-runner` and `sysroot-status` command-line interfaces via the self.run method
  # * SysrootWorkspace for identifying the current process's namespace relative to the ROOTFS_MARKER and build plan to get relative file paths
  # * SysrootBuildState for reading and writing the build state
  # * SysrootNamespace for changing the active namespace
  # * StepRunner for the execution of the individual steps
  #
  # NOTE: SysrootRunner cannot return to an outer namespace once it enters one inside, so invocation via Process.run may be appropriate if a coordinator needs to retain the previous process namespace.
  class SysrootRunner < CLI
    @workspace : SysrootWorkspace
    @state : SysrootBuildState
    @step_runner : StepRunner
    getter state : SysrootBuildState

    # workspace: holds the current working environment
    # report: do we generate a build report
    def initialize(
      @workspace : SysrootWorkspace = SysrootWorkspace.new,
      @start_phase : String = "all",
      @packages : Array(String) = [] of String,
      @report : Bool = true,
      @resume : Bool = true,
      @dry_run : Bool = true,
      @clean_build_dirs : Bool = true,
      step_runner : StepRunner? = nil,
    )
      @state = SysrootBuildState.new(workspace: @workspace)
      @step_runner = step_runner || StepRunner.new(clean_build_dirs: @clean_build_dirs, workspace: @workspace)
    end

    # Execute the build plan
    def run_plan
      plan = load_plan
      Log.info { "*** Running build plan #{@state.plan_path} from state #{@state.state_path} ***" }
      report_dir = @state.report_dir
      Log.info { "Using report_dir: #{report_dir}" } if @report && report_dir
      phases = plan.selected_phases(@start_phase)
      phases = apply_rootfs_env_overrides(phases) if rootfs_marker_present?
      phases = filter_phases_by_packages(phases, @packages) unless @packages.empty?
      phases = filter_phases_by_state(phases) if @resume
      if @dry_run
        Log.info { describe_phases(phases) }
        return
      end
      if @report && report_dir
        @step_runner.report_dir = report_dir.to_s
      end
      phases.each_with_index do |phase, idx|
        @state.mark_current_phase(phase.name)
        run_phase(phase)
        next_phase = phases[idx + 1]?.try(&.name)
        @state.mark_current_phase(next_phase)
      end
    end

    # Run a single phase from the plan.
    def run_phase(phase : BuildPhase)
      if phase.environment.starts_with?("host-")
        raise "Refusing to run #{phase.name} (env=#{phase.environment} namespace=#{@workspace.namespace_name})" unless @workspace.namespace.host?
      elsif phase.environment.in?({"alpine-seed", "sysroot-toolchain"})
        if @workspace.namespace.host?
          Log.info { "**** Entering outer seed rootfs at #{@workspace.seed_rootfs_path} ****" }
          @workspace.enter_seed_rootfs_namespace
        elsif @workspace.namespace.bq2?
          raise "Refusing to run #{phase.name} (env=#{phase.environment} namespace=#{@workspace.namespace_name})"
        end
        raise "Expected seed namespace, got #{@workspace.namespace_name}" unless @workspace.namespace.seed?
      elsif phase.environment.starts_with?("rootfs-")
        if @workspace.namespace.host? || @workspace.namespace.seed?
          Log.info { "**** Entering inner BQ2 rootfs at #{@workspace.bq2_rootfs_path} ****" }
          @workspace.enter_bq2_rootfs_namespace
        end
        raise "Expected bq2 namespace, got #{@workspace.namespace_name}" unless @workspace.namespace.bq2?
      end
      Log.info { "Executing phase #{phase.name} (env=#{phase.environment}, namespace=#{@workspace.namespace_name})" }
      Log.info { "**** #{phase.description} ****" }
      run_steps(phase, phase.steps)
      Log.info { "Completed phase #{phase.name}" }
    end

    # Execute a list of BuildStep entries, stopping immediately on failure.
    def run_steps(phase : BuildPhase,
                  steps : Array(BuildStep))
      Log.info { "Executing #{steps.size} build steps" }
      steps.each do |step|
        if @resume && @state.completed?(phase.name, step.name)
          Log.info { "Skipping previously completed #{phase.name}/#{step.name}" }
          next
        end
        Log.info { "Building #{step.name} in #{step.workdir} (phase=#{phase.name}, namespace=#{@workspace.namespace})" }
        begin
          if @resume && @state.retrying_last_failure?(phase.name, step.name)
            Log.debug { "Keeping previous build directory due to retrying previous build" }
            @step_runner.clean_build_dirs = false
          end
          @step_runner.run(phase, step)
          @state.mark_success(phase.name, step.name)
        rescue ex
          report_path = write_failure_report_if_available(phase, step, ex)
          @state.mark_failure(phase.name, step.name, ex.message, report_path)
          raise ex
        end
      end
      Log.info { "All build steps completed" }
    end

    private def filter_phases_by_state(phases : Array(BuildPhase)) : Array(BuildPhase)
      phases.compact_map do |phase|
        remaining = phase.steps.reject { |step| @state.completed?(phase.name, step.name) }
        next nil if remaining.empty?
        BuildPhase.new(
          name: phase.name,
          description: phase.description,
          workspace: phase.workspace,
          environment: phase.environment,
          install_prefix: phase.install_prefix,
          destdir: phase.destdir,
          env: phase.env,
          steps: remaining,
        )
      end
    end

    private def apply_rootfs_env_overrides(phases : Array(BuildPhase)) : Array(BuildPhase)
      phases.map do |phase|
        apply_rootfs_env_override(phase)
      end
    end

    private def apply_rootfs_env_override(phase : BuildPhase) : BuildPhase
      return phase unless phase.environment.starts_with?("rootfs-")
      overrides = native_rootfs_env
      merged = phase.env.dup
      overrides.each { |key, value| merged[key] = value }
      BuildPhase.new(
        name: phase.name,
        description: phase.description,
        workspace: phase.workspace,
        environment: phase.environment,
        install_prefix: phase.install_prefix,
        destdir: phase.destdir,
        env: merged,
        steps: phase.steps,
      )
    end

    private def native_rootfs_env : Hash(String, String)
      return {} of String => String unless File.exists?("/usr/bin/clang") && File.exists?("/usr/bin/clang++")
      {
        # Prefer prefix-free /usr tools but keep /opt/sysroot on PATH for the toolchain.
        "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin:/opt/sysroot/bin:/opt/sysroot/sbin",
      }
    end

    private def describe_phases(phases : Array(BuildPhase)) : String
      phases.map do |phase|
        steps = phase.steps.map(&.name).join(", ")
        "#{phase.name} (#{phase.steps.size} steps): #{steps}"
      end.join(" | ")
    end

    private def filter_phases_by_packages(phases : Array(BuildPhase), packages : Array(String)) : Array(BuildPhase)
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
          workspace: phase.workspace,
          environment: phase.environment,
          install_prefix: phase.install_prefix,
          destdir: phase.destdir,
          env: phase.env,
          steps: steps,
        )
      end
      raise "No matching packages found in selected phases: #{packages.join(", ")}" if selected.empty?
      selected
    end

    # Creates a minimal directory skeleton for `DESTDIR` installs. The intent is
    # to keep packages with hard-coded expectations (e.g., `/usr/bin`) from
    # failing when the destdir tree is initially empty.
    private def prepare_destdir(destdir : String)
      FileUtils.mkdir_p(destdir)
      %w[bin dev etc lib opt proc sys tmp usr var workspace].each do |subdir|
        FileUtils.mkdir_p(File.join(destdir, subdir))
      end
      FileUtils.mkdir_p(File.join(destdir, "usr/bin"))
      FileUtils.mkdir_p(File.join(destdir, "usr/sbin"))
      FileUtils.mkdir_p(File.join(destdir, "usr/lib"))
      FileUtils.mkdir_p(File.join(destdir, "var/lib"))
    end

    private def write_failure_report(report_dir : String, phase : BuildPhase, step : BuildStep, ex : Exception) : String?
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
          "environment"    => phase.environment,
          "workspace"      => phase.workspace,
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

    private def write_failure_report_if_available(phase : BuildPhase, step : BuildStep, ex : Exception) : String?
      return nil unless @report
      report_dir = @state.report_dir
      return nil unless report_dir
      write_failure_report(report_dir.to_s, phase, step, ex)
    end

    private def load_plan : BuildPlan
      BuildPlan.parse(File.read(@state.plan_path))
    end

    private def rootfs_marker_present? : Bool
      File.exists?(@workspace.marker_path)
    end

    # Summarize the sysroot runner CLI behavior for help output.
    def self.summary : String
      "Executed build plan to build rootfs and build rootfs tarball"
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

    # Run build plan phases/steps
    private def self.run_runner(args : Array(String)) : Int32
      packages = [] of String
      start_phase = "all"
      report = true
      resume = true
      dry_run = false
      host_workdir : Path? = nil
      extra_binds = [] of Tuple(Path, Path)
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-runner [options]") do |p|
        p.on("--phase NAME", "Select first build phase to run (default: all)") { |name| start_phase = name }
        p.on("--package NAME", "Only run the named package(s) (repeatable)") { |name| packages << name }
        p.on("--no-report", "Disable failure report writing") { report = false }
        p.on("--no-resume", "Disable resume/state tracking (useful when the default state path is not writable)") { resume = false }
        p.on("--dry-run", "List selected phases/steps and exit") { dry_run = true }
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

      runner = SysrootRunner.new(
        workspace: workspace,
        start_phase: start_phase,
        packages: packages,
        report: report,
        resume: resume,
        dry_run: dry_run
      )
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
      show_latest_report = false
      show_latest_log = false

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-status [options]") do |p|
        p.on("--workdir=PATH", "Starting path for looking for build plan (default: #{SysrootWorkspace::DEFAULT_HOST_WORKDIR})") { |path| host_workdir = Path[path] }
        p.on("--latest-report", "Print the latest failure report JSON") { show_latest_report = true }
        p.on("--latest-log", "Print the output log from the latest failure report") { show_latest_log = true }
      end
      return CLI.print_help(parser) if help

      begin
        workspace = SysrootWorkspace.new(host_workdir: host_workdir)
      rescue ex
        STDERR.puts "No valid workspace found, build out the workspace first with `bq2 sysroot-builder`: #{ex.message}"
        return -1
      end

      runner = SysrootRunner.new(workspace: workspace)

      if (current_phase = runner.state.progress.current_phase)
        puts("current_phase=#{current_phase}")
      end
      if (success = runner.state.progress.last_success)
        puts("last_success=#{success.phase}/#{success.step}")
      end
      if (failure = runner.state.progress.last_failure)
        puts("last_failure=#{failure.phase}/#{failure.step}")
      end

      if show_latest_report || show_latest_log
        report_path = runner.state.failure_report_path(runner.state.state_path.to_s)
        if report_path
          puts("latest_report=#{report_path}")
          puts(File.read(report_path)) if show_latest_report
        else
          puts("latest_report=(missing)")
        end
        if show_latest_log
          log_path = report_path ? output_log_for_report(report_path) : nil
          if log_path
            puts("latest_log=#{log_path}")
            puts(File.read(log_path)) if File.exists?(log_path)
          else
            puts("latest_log=(missing)")
          end
        end
      end
      0
    end

    private def self.resolve_latest_report_path(state : SysrootBuildState, _report_dir : String?, state_path : String?) : String?
      report_path = state.progress.last_failure.try(&.report_path)
      return nil unless report_path
      resolved = state.resolve_rootfs_path(report_path, state_path)
      return resolved if File.exists?(resolved)
      nil
    end

    private def self.latest_report_path(report_dir : String) : String?
      return nil unless Dir.exists?(report_dir)
      files = Dir.glob(File.join(report_dir, "*.json"))
      return nil if files.empty?
      files.sort.last
    end

    private def self.report_log_path(report_path : String) : String?
      return nil unless report_path.ends_with?(".json")
      candidate = report_path.sub(/\.json$/, ".log")
      File.exists?(candidate) ? candidate : nil
    end

    private def self.output_log_for_report(report_path : String) : String?
      json = JSON.parse(File.read(report_path))
      json["output_log"]?.try(&.as_s?)
    rescue ex
      Log.warn { "Failed to parse report #{report_path}: #{ex.message}" }
      nil
    end

    private def slugify(value : String) : String
      value.gsub(/[^A-Za-z0-9]+/, "_").gsub(/^_+|_+$/, "").downcase
    end

    # Run the finalize-rootfs phase to emit a prefix-free rootfs tarball.
    private def self.run_tarball(args : Array(String)) : Int32
      workspace = SysrootWorkspace.new
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-tarball [options]") do |p|
      end
      return CLI.print_help(parser) if help
      step_runner = StepRunner.new
      # TODO: Either load the existing build plan or generate a minimal plan with the "rootfs" strategy
      # TODO: Call step_runner.run with the plan
      0
    end
  end
end
