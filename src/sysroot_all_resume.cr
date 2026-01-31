require "file_utils"
require "log"
require "path"
require "./build_plan"
require "./cli"
require "./sysroot_build_state"
require "./sysroot_builder"
require "./sysroot_workspace"

module Bootstrap
  # Determines the earliest resume stage for `bq2 sysroot --resume`.
  class SysrootAllResume < CLI
    # Ordered stage list for the sysroot workflow.
    STAGE_ORDER = [
      "plan-write",
      "sysroot-runner",
    ]

    # Result describing the stage to resume and its supporting details.
    struct Decision
      getter stage : String
      getter reason : String
      getter resume_phase : String?
      getter resume_step : String?
      getter plan_path : Path?
      getter state_path : Path?

      # Create a new resume decision.
      def initialize(@stage : String,
                     @reason : String,
                     @resume_phase : String? = nil,
                     @resume_step : String? = nil,
                     @plan_path : Path? = nil,
                     @state_path : Path? = nil)
      end

      # Return a log message summarizing the decision.
      def log_message : String
        String.build do |io|
          io << "Resume decision:\n stage=" << stage << " (" << reason << ")"
          if resume_phase
            io << "\n phase=" << resume_phase
          end
          if resume_step
            io << "\n step=" << resume_step
          end
          if state_path
            io << "\n state=" << state_path
          end
          if plan_path
            io << "\n plan=" << plan_path
          end
        end
      end
    end

    getter workspace : SysrootWorkspace
    getter build_state : SysrootBuildState

    # Create a resume inspector for the provided *workspace*.
    def initialize(@workspace : SysrootWorkspace)
      @build_state = SysrootBuildState.new(workspace: @workspace)
    end

    # Determine the earliest incomplete stage for `sysroot --resume`.
    def decide : Decision
      plan_exists = build_state.plan_exists?
      state_exists = build_state.state_exists?
      if state_exists && !plan_exists
        raise "Ambiguous resume state: state exists at #{build_state.state_path} but plan is missing at #{build_state.plan_path_path}"
      end

      unless plan_exists
        return Decision.new("plan-write", "missing build plan at #{build_state.plan_path_path}")
      end

      plan_path = build_state.plan_path_path
      plan = BuildPlan.parse(File.read(plan_path))
      if state_exists
        state = SysrootBuildState.load(workspace, build_state.state_path)
        plan_digest = SysrootBuildState.digest_for?(plan_path.to_s)
        if plan_digest.nil? || state.plan_digest != plan_digest
          return Decision.new("sysroot-runner", "plan digest mismatch; ignoring state", plan_path: plan_path)
        end

        next_phase, next_step = next_incomplete_step(plan, state)
        if next_phase.nil?
          return Decision.new("complete", "build complete", plan_path: plan_path, state_path: build_state.state_path)
        end

        resume_phase = next_phase
        reason = "state present and plan digest matches"
        return Decision.new("sysroot-runner", reason, resume_phase: resume_phase, resume_step: next_step, plan_path: plan_path, state_path: build_state.state_path)
      end

      Decision.new("sysroot-runner", "plan present but state is missing", plan_path: plan_path)
    end

    # Find the next incomplete step in the build plan for the given *state*.
    def next_incomplete_step(plan : BuildPlan, state : SysrootBuildState) : Tuple(String?, String?)
      plan.phases.each do |phase|
        phase.steps.each do |step|
          next if state.completed?(phase.name, step.name)
          return {phase.name, step.name}
        end
      end
      {nil, nil}
    end

    # Return the default command name used by bq2.
    def self.command_line_override : String?
      "sysroot"
    end

    # Return additional command aliases handled by this class.
    def self.aliases : Array(String)
      ["default"]
    end

    # Summarize the default command behavior for help output.
    def self.summary : String
      "Show resume status for the sysroot build"
    end

    # Describe the help output entries for the default and sysroot flows.
    def self.help_entries : Array(Tuple(String, String))
      [
        {"default", "Show resume status and help output"},
        {"sysroot", "Build the full rootfs and capture bq2-rootfs-#{Bootstrap::VERSION}.tar.gz"},
      ]
    end

    # Dispatch the default or sysroot CLI entrypoints.
    def self.run(args : Array(String), command_name : String) : Int32
      case command_name
      when "sysroot"
        run_all(args)
      when "default"
        run_default(args)
      else
        raise "Unknown sysroot resume command #{command_name}"
      end
    end

    # Execute the full sysroot flow (plan write + runner).
    private def self.run_all(args : Array(String)) : Int32
      host_workdir = SysrootBuilder::DEFAULT_HOST_WORKDIR
      architecture = SysrootBuilder::DEFAULT_ARCH
      branch = SysrootBuilder::DEFAULT_BRANCH
      base_version = SysrootBuilder::DEFAULT_BASE_VERSION
      base_rootfs_path : Path? = nil
      use_system_tar_for_sources = false
      use_system_tar_for_rootfs = false
      preserve_ownership_for_sources = false
      preserve_ownership_for_rootfs = false
      owner_uid = nil
      owner_gid = nil
      repo_root = Path["."].expand
      resume = true

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot [options]") do |p|
        p.on("-a ARCH", "--arch=ARCH", "Target architecture (default: #{architecture})") { |val| architecture = val }
        p.on("-b BRANCH", "--branch=BRANCH", "Source branch/release tag (default: #{branch})") { |val| branch = val }
        p.on("-v VERSION", "--base-version=VERSION", "Base rootfs version/tag (default: #{base_version})") { |val| base_version = val }
        p.on("--base-rootfs PATH", "Use a local rootfs tarball instead of downloading the Alpine minirootfs") { |val| base_rootfs_path = Path[val].expand }
        p.on("--system-tar-sources", "Use system tar to extract all staged source archives") { use_system_tar_for_sources = true }
        p.on("--system-tar-rootfs", "Use system tar to extract the base rootfs") { use_system_tar_for_rootfs = true }
        p.on("--preserve-ownership-sources", "Apply ownership metadata when extracting source archives") { preserve_ownership_for_sources = true }
        p.on("--no-preserve-ownership-sources", "Skip applying ownership metadata for source archives") { preserve_ownership_for_sources = false }
        p.on("--preserve-ownership-rootfs", "Apply ownership metadata for the base rootfs") { preserve_ownership_for_rootfs = true }
        p.on("--owner-uid=UID", "Override extracted file owner uid (implies ownership preservation)") do |val|
          preserve_ownership_for_sources = true
          preserve_ownership_for_rootfs = true
          owner_uid = val.to_i
        end
        p.on("--owner-gid=GID", "Override extracted file owner gid (implies ownership preservation)") do |val|
          preserve_ownership_for_sources = true
          preserve_ownership_for_rootfs = true
          owner_gid = val.to_i
        end
        p.on("--repo-root PATH", "Path to the bootstrap-qcow2 repo (default: #{repo_root})") { |val| repo_root = Path[val].expand }
        p.on("--resume", "Resume the sysroot workflow from the earliest incomplete stage") { resume = true }
        p.on("--no-resume", "Restart the sysroot workflow from scratch") { resume = false }
      end
      return CLI.print_help(parser) if help

      puts "bq2 sysroot starting"
      puts "host_workdir=#{host_workdir} arch=#{architecture} branch=#{branch} base_version=#{base_version} resume=#{resume}"
      puts "repo_root=#{repo_root}"

      builder = SysrootBuilder.new(
        architecture: architecture,
        branch: branch,
        base_version: base_version,
        base_rootfs_path: base_rootfs_path,
        use_system_tar_for_sources: use_system_tar_for_sources,
        use_system_tar_for_rootfs: use_system_tar_for_rootfs,
        preserve_ownership_for_sources: preserve_ownership_for_sources,
        preserve_ownership_for_rootfs: preserve_ownership_for_rootfs,
        owner_uid: owner_uid,
        owner_gid: owner_gid,
      )

      unless File.exists?(repo_root / "shard.yml")
        if exe = Process.executable_path
          candidate = Path[exe].expand.parent.parent
          repo_root = candidate if File.exists?(candidate / "shard.yml")
        end
      end

      unless File.exists?(repo_root / "shard.yml")
        STDERR.puts "Unable to locate repo root at #{repo_root}; pass --repo-root from the bootstrap-qcow2 checkout."
        return 1
      end

      bq2_path = repo_root / "bin" / "bq2"
      unless File.exists?(bq2_path)
        STDERR.puts "Expected #{bq2_path}; run shards build && ./bin/bq2 --install before invoking sysroot."
        return 1
      end

      default_rootfs_path = builder.sources_dir / builder.rootfs_tarball_name
      rootfs_tarball = base_rootfs_path || (File.exists?(default_rootfs_path) ? default_rootfs_path : nil)
      puts "base_rootfs=#{rootfs_tarball || "(download)"}"

      stages = SysrootAllResume::STAGE_ORDER
      start_stage = "plan-write"
      resume_phase : String? = nil
      resume_step : String? = nil
      if resume
        workspace = builder.workspace
        decision = SysrootAllResume.new(workspace).decide
        puts decision.log_message
        if decision.stage == "complete"
          return copy_rootfs_tarball(builder) ? 0 : 1
        end
        start_stage = decision.stage
        resume_phase = decision.resume_phase
        resume_step = decision.resume_step
      end
      puts "stage_order=#{stages.join(" -> ")} start_stage=#{start_stage}"

      start_index = stages.index(start_stage)
      raise "Unknown resume stage #{start_stage}" unless start_index

      runner_no_resume = !resume
      stages[start_index..].each do |stage|
        case stage
        when "plan-write"
          time_stage(stage) do
            chroot_path = builder.generate_chroot(include_sources: true)
            Log.info { "Prepared chroot directory at #{chroot_path}" }
          end
        when "sysroot-runner"
          time_stage(stage) do
            Log.info { "Starting runner exe=#{bq2_path} repo_root=#{repo_root}" }
            status = run_sysroot_runner(
              bq2_path,
              "all",
              no_resume: runner_no_resume,
            )
            unless status.success?
              STDERR.puts "sysroot-runner failed with exit code #{status.exit_code}"
              return status.exit_code
            end
          end
        end
      end

      unless copy_rootfs_tarball(builder)
        produced_tarball = builder.inner_rootfs_workspace_dir / builder.rootfs_tarball_name
        STDERR.puts "Expected rootfs tarball missing at #{produced_tarball}"
        STDERR.puts "Resume hint: #{resume_phase}/#{resume_step}" if resume_phase || resume_step
        return 1
      end
      0
    end

    # Print the current resume decision and help output.
    private def self.run_default(args : Array(String)) : Int32
      builder = SysrootBuilder.new
      begin
        workspace = builder.workspace
        decision = SysrootAllResume.new(workspace).decide
        puts(decision.log_message)
        if decision.stage == "sysroot-runner" && (state_path = decision.state_path)
          state = SysrootBuildState.load(workspace, state_path)
          if state.retrying_last_failure?(decision.resume_phase, decision.resume_step)
            puts "\nResume details: retrying last failed step."
            if (overrides = state.overrides_contents(state_path.to_s))
              puts "overrides_path=#{state.overrides_path}"
              puts overrides
            else
              puts "overrides_path=(none)"
            end
            if (report_path = state.failure_report_path(state_path.to_s))
              puts "failure_report_path=#{report_path}"
              if (report = state.failure_report_contents(state_path.to_s))
                puts report
              end
            else
              puts "failure_report_path=(none)"
            end
          end
        end
        puts "\nHint: run ./bin/bq2 sysroot --resume to continue from this stage."
      rescue error
        puts "\nResume decision unavailable: #{error.message}"
      end
      puts "\n"
      CLI.run_help
    end

    # Run a bq2 subcommand inside the sysroot namespace.
    private def self.run_sysroot_runner(bq2_path : Path,
                                        phase : String,
                                        no_resume : Bool = false) : Process::Status
      argv = [
        "sysroot-runner",
      ]
      argv << "--no-resume" if no_resume
      argv.concat(["--phase", phase])
      Process.run(
        bq2_path.to_s,
        argv,
        input: STDIN,
        output: STDOUT,
        error: STDERR,
      )
    end

    # Log the duration of a stage for the sysroot workflow.
    private def self.time_stage(stage : String, &block : -> T) : T? forall T
      Log.info { "Stage #{stage} starting" }
      result = nil.as(T?)
      elapsed = Time.measure do
        result = yield
      end
      Log.info { "Stage #{stage} finished in #{elapsed.total_seconds.round(2)}s" }
      result
    end

    # Copy the produced rootfs tarball into the workspace source cache.
    private def self.copy_rootfs_tarball(builder : SysrootBuilder) : Bool
      produced_tarball = builder.inner_rootfs_workspace_dir / builder.rootfs_tarball_name
      return false unless File.exists?(produced_tarball)
      output = builder.sources_dir / builder.rootfs_tarball_name
      FileUtils.mkdir_p(output.parent)
      FileUtils.cp(produced_tarball, output)
      puts "Generated rootfs tarball at #{output}"
      true
    end
  end
end
