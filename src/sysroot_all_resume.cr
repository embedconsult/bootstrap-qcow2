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
        raise "Ambiguous resume state: state exists at #{build_state.state_path} but plan is missing at #{build_state.plan_path}"
      end

      unless plan_exists
        return Decision.new("plan-write", "missing build plan at #{build_state.plan_path}")
      end

      plan_path = build_state.plan_path
      plan = build_state.load_plan
      if state_exists
        state = build_state.load
        plan_digest = SysrootBuildState.digest_for?(plan_path)
        if plan_digest.nil? || state.plan_digest != plan_digest
          return Decision.new("sysroot-runner", "plan digest mismatch; ignoring state", plan_path: plan_path)
        end

        next_phase, next_step = state.next_incomplete_step(plan)
        if next_phase.nil?
          return Decision.new("complete", "build complete", plan_path: plan_path, state_path: build_state.state_path)
        end

        resume_phase = next_phase
        reason = "state present and plan digest matches"
        return Decision.new("sysroot-runner", reason, resume_phase: resume_phase, resume_step: next_step, plan_path: plan_path, state_path: build_state.state_path)
      end

      Decision.new("sysroot-runner", "plan present but state is missing", plan_path: plan_path)
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
      host_workdir = nil
      resume = true
      architecture = SysrootBuilder::DEFAULT_ARCH

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot [options]") do |p|
        p.on("-a ARCH", "--arch=ARCH", "Target architecture (default: #{architecture})") { |val| architecture = val }
        p.on("--base-rootfs PATH", "Use a local rootfs tarball instead of downloading the Alpine minirootfs") { |val| base_rootfs_path = Path[val].expand }
        p.on("--resume", "Resume the sysroot workflow from the earliest incomplete stage") { resume = true }
        p.on("--no-resume", "Restart the sysroot workflow from scratch") { resume = false }
      end
      return CLI.print_help(parser) if help

      puts "bq2 sysroot starting"
      puts "host_workdir=#{host_workdir} arch=#{architecture} resume=#{resume}"

      builder = SysrootBuilder.new(
        architecture: architecture
      )

      # TODO
      0
    end

    # Print the current resume decision and help output.
    private def self.run_default(args : Array(String)) : Int32
      # TODO
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
