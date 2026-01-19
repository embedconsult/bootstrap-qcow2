require "log"
require "./bootstrap-qcow2"
require "./alpine_setup"
require "./cli"
require "./build_plan_utils"
require "./sysroot_builder"
require "./sysroot_namespace"
require "./sysroot_runner_lib"
require "./codex_namespace"
require "./bq2_curl"
require "./git_remote_https"
require "./github_cli"

module Bootstrap
  # Busybox-style dispatcher: one binary, many entrypoints selected by argv[0]
  # or by providing the subcommand as the first argument.
  module Main
    COMMANDS = {
      "--install"               => ->(args : Array(String)) { run_install(args) },
      "--all"                   => ->(args : Array(String)) { run_all(args) },
      "bq2-curl"                => ->(args : Array(String)) { run_bq2_curl(args) },
      "default"                 => ->(args : Array(String)) { run_default(args) },
      "git-remote-https"        => ->(args : Array(String)) { run_git_remote_https(args) },
      "sysroot-builder"         => ->(args : Array(String)) { run_sysroot_builder(args) },
      "sysroot-namespace"       => ->(args : Array(String)) { run_sysroot_namespace(args) },
      "sysroot-namespace-check" => ->(args : Array(String)) { run_sysroot_namespace_check(args) },
      "sysroot-runner"          => ->(args : Array(String)) { run_sysroot_runner(args) },
      "sysroot-plan-write"      => ->(args : Array(String)) { run_sysroot_plan_write(args) },
      "sysroot-tarball"         => ->(args : Array(String)) { run_sysroot_tarball(args) },
      "sysroot-status"          => ->(args : Array(String)) { run_sysroot_status(args) },
      "codex-namespace"         => ->(args : Array(String)) { run_codex_namespace(args) },
      "github-pr-feedback"      => ->(args : Array(String)) { run_github_pr_feedback(args) },
      "github-pr-comment"       => ->(args : Array(String)) { run_github_pr_comment(args) },
      "github-pr-create"        => ->(args : Array(String)) { run_github_pr_create(args) },
      "help"                    => ->(args : Array(String)) { run_help(args) },
    }

    def self.run(argv = ARGV)
      command_name, args = CLI.dispatch(argv, COMMANDS.keys, "default")
      handler = COMMANDS[command_name]?
      unless handler
        STDERR.puts "Unknown command #{command_name}"
        exit run_help([] of String, exit_code: 1)
      end

      exit handler.call(args)
    end

    def self.run_help(_args, exit_code : Int32 = 0) : Int32
      puts "Usage:"
      puts "  bq2 <command> [options] [-- command args]\n\nCommands:"
      puts "  --install               Create CLI symlinks in ./bin"
      puts "  --all                   Build the full rootfs and capture bq2-rootfs-#{Bootstrap::VERSION}.tar.gz"
      puts "  bq2-curl                Minimal HTTP client helper"
      puts "  (default)               Show this message"
      puts "  sysroot-builder         Build sysroot tarball or directory"
      puts "  sysroot-namespace       Enter a namespaced rootfs and exec a command"
      puts "  sysroot-namespace-check Check host namespace prerequisites"
      puts "  sysroot-runner          Replay build plan inside the sysroot"
      puts "  sysroot-plan-write      Write a fresh build plan JSON"
      puts "  sysroot-tarball         Emit a prefix-free rootfs tarball"
      puts "  sysroot-status          Print current sysroot build phase"
      puts "  codex-namespace         Run Codex inside a namespaced rootfs"
      puts "  git-remote-https        HTTPS remote helper for Git"
      puts "  github-pr-feedback      Fetch PR feedback as JSON"
      puts "  github-pr-comment       Post a PR conversation comment"
      puts "  github-pr-create        Create a GitHub pull request"
      puts "  help                    Show this message"
      puts "\nInvoke via symlink (e.g., bin/sysroot-builder) or as the first argument."
      exit_code
    end

    private def self.run_sysroot_namespace(args : Array(String)) : Int32
      rootfs = "data/sysroot/rootfs"
      extra_binds = [] of Tuple(Path, Path)
      command = [] of String
      enter_workspace_rootfs = false
      parser, remaining, help = CLI.parse(args, "Usage: bq2 sysroot-namespace [options] [-- command...]") do |p|
        p.on("--rootfs=PATH", "Path to the sysroot rootfs (default: #{rootfs})") { |val| rootfs = val }
        p.on("--workspace-rootfs", "Enter the generated rootfs at <rootfs>/workspace/rootfs (output of rootfs-from-sysroot)") { enter_workspace_rootfs = true }
        p.on("--bind=SRC:DST", "Bind-mount SRC into DST inside the rootfs (repeatable; DST is inside rootfs)") do |val|
          parts = val.split(":", 2)
          raise "Expected --bind=SRC:DST" unless parts.size == 2
          src = Path[parts[0]].expand
          dst = normalize_bind_target(parts[1])
          extra_binds << {src, dst}
        end
      end
      return CLI.print_help(parser) if help

      command = remaining.empty? ? ["/bin/sh"] : remaining
      if enter_workspace_rootfs
        rootfs = (Path[rootfs].expand / "workspace" / "rootfs").to_s
      end
      Log.debug { "Entering namespace with rootfs=#{rootfs} command=#{command.join(" ")}" }

      SysrootNamespace.enter_rootfs(rootfs, extra_binds: extra_binds)
      Process.exec(command.first, command[1..])
    rescue ex : File::Error
      cmd = command || [] of String
      Log.error { "Process exec failed for #{cmd.join(" ")}: #{ex.message}" }
      raise ex
    end

    # Normalize a bind-mount target path inside a rootfs.
    #
    # Bind targets are expressed as `SRC:DST`, where DST is a path inside the
    # rootfs. This helper strips a leading slash to ensure DST is interpreted as
    # relative to the rootfs directory instead of an absolute host path.
    private def self.normalize_bind_target(value : String) : Path
      cleaned = value.starts_with?("/") ? value[1..] : value
      Path[cleaned]
    end

    private def self.run_sysroot_status(args : Array(String)) : Int32
      workspace = "data/sysroot"
      rootfs : String? = nil
      state_path : String? = nil

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-status [options]") do |p|
        p.on("-w DIR", "--workspace=DIR", "Sysroot workspace directory (default: #{workspace})") { |val| workspace = val }
        p.on("--rootfs=PATH", "Prepared rootfs directory (default: <workspace>/rootfs)") { |val| rootfs = val }
        p.on("--state=PATH", "Explicit sysroot build state JSON path") { |val| state_path = val }
      end
      return CLI.print_help(parser) if help

      rootfs_dir = rootfs
      rootfs_dir ||= File.join(workspace, "rootfs")
      resolved_state_path = state_path
      resolved_state_path ||= File.join(rootfs_dir, "var/lib/sysroot-build-state.json")
      resolved_state_path = resolved_state_path.not_nil!
      unless File.exists?(resolved_state_path)
        resolved_state_path = SysrootBuildState::DEFAULT_PATH if File.exists?(SysrootBuildState::DEFAULT_PATH)
      end
      raise "Missing sysroot build state at #{resolved_state_path}" unless File.exists?(resolved_state_path)

      state = SysrootBuildState.load(resolved_state_path)
      puts(state.progress.current_phase || "(none)")

      plan_path = File.join(rootfs_dir, "var/lib/sysroot-build-plan.json")
      plan_path = state.plan_path unless File.exists?(plan_path)
      if File.exists?(plan_path)
        plan = BuildPlan.from_json(File.read(plan_path))
        next_phase = plan.phases.find do |phase|
          phase.steps.any? { |step| !state.completed?(phase.name, step.name) }
        end
        if next_phase
          next_step = next_phase.steps.find { |step| !state.completed?(next_phase.name, step.name) }
          puts("next_phase=#{next_phase.name}")
          puts("next_step=#{next_step.not_nil!.name}") if next_step
        else
          puts("next_phase=(none)")
        end
      end

      if (success = state.progress.last_success)
        puts("last_success=#{success.phase}/#{success.step}")
      end
      if (failure = state.progress.last_failure)
        puts("last_failure=#{failure.phase}/#{failure.step}")
      end
      0
    end

    private def self.run_sysroot_builder(args : Array(String)) : Int32
      output = Path["sysroot.tar.gz"]
      workspace = Path["data/sysroot"]
      architecture = SysrootBuilder::DEFAULT_ARCH
      branch = SysrootBuilder::DEFAULT_BRANCH
      base_version = SysrootBuilder::DEFAULT_BASE_VERSION
      base_rootfs_path : Path? = nil
      include_sources = true
      use_system_tar_for_sources = false
      use_system_tar_for_rootfs = false
      preserve_ownership_for_sources = false
      preserve_ownership_for_rootfs = false
      owner_uid = nil
      owner_gid = nil
      write_tarball = true
      reuse_rootfs = false
      codex_bin : Path? = nil
      codex_url : URI? = nil
      codex_sha256 : String? = nil
      codex_target = Bootstrap::SysrootBuilder::DEFAULT_CODEX_TARGET
      install_codex = false
      refresh_plan = false
      restage_sources = false

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-builder [options]") do |p|
        p.on("-o OUTPUT", "--output=OUTPUT", "Target sysroot tarball (default: #{output})") { |val| output = Path[val] }
        p.on("-w DIR", "--workspace=DIR", "Workspace directory (default: #{workspace})") { |val| workspace = Path[val] }
        p.on("-a ARCH", "--arch=ARCH", "Target architecture (default: #{architecture})") { |val| architecture = val }
        p.on("-b BRANCH", "--branch=BRANCH", "Source branch/release tag (default: #{branch})") { |val| branch = val }
        p.on("-v VERSION", "--base-version=VERSION", "Base rootfs version/tag (default: #{base_version})") { |val| base_version = val }
        p.on("--base-rootfs PATH", "Use a local rootfs tarball instead of downloading the Alpine minirootfs") { |val| base_rootfs_path = Path[val].expand }
        p.on("--skip-sources", "Skip staging source archives into the rootfs") { include_sources = false }
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
        p.on("--codex", "Install the host codex binary into the rootfs (default target: #{codex_target})") do
          install_codex = true
        end
        p.on("--codex-bin PATH", "Copy a host Codex binary into the rootfs workspace (default target: #{codex_target})") do |val|
          codex_bin = Path[val].expand
        end
        p.on("--codex-url URL", "Download Codex using the sysroot builder fetcher") do |val|
          codex_url = URI.parse(val)
        end
        p.on("--codex-sha256 SHA256", "Expected SHA256 for --codex-url") { |val| codex_sha256 = val }
        p.on("--codex-target PATH", "Target path for --codex-bin/--codex-url inside the rootfs (default: #{codex_target})") do |val|
          codex_target = Path[val]
        end
        p.on("--no-tarball", "Prepare the chroot tree without writing a tarball") { write_tarball = false }
        p.on("--reuse-rootfs", "Reuse an existing prepared rootfs when present") { reuse_rootfs = true }
        p.on("--refresh-plan", "Rewrite the build plan inside an existing rootfs (requires --reuse-rootfs)") { refresh_plan = true }
        p.on("--restage-sources", "Extract missing sources into an existing rootfs /workspace (requires --reuse-rootfs)") { restage_sources = true }
      end
      return CLI.print_help(parser) if help

      if install_codex && codex_bin.nil? && codex_url.nil?
        if found = Process.find_executable("codex")
          codex_bin = Path[found]
        else
          STDERR.puts "codex not found on PATH; pass --codex-bin or --codex-url instead"
          return 1
        end
      end

      Log.info { "Sysroot builder log level=#{Log.for("").level} (env-configured)" }
      builder = SysrootBuilder.new(
        workspace: workspace,
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
        codex_bin: codex_bin,
        codex_url: codex_url,
        codex_sha256: codex_sha256,
        codex_target: codex_target
      )

      if reuse_rootfs && builder.rootfs_ready?
        puts "Reusing existing rootfs at #{builder.rootfs_dir}"
        puts "Build plan found at #{builder.plan_path} (iteration state is maintained by sysroot-runner)"
        if include_sources && restage_sources
          builder.stage_sources(skip_existing: true)
          puts "Staged missing sources into #{builder.rootfs_dir}/workspace"
        end
        builder.stage_codex_binary if codex_bin || codex_url
        if refresh_plan
          builder.write_plan
          puts "Refreshed build plan at #{builder.plan_path}"
        end
        if write_tarball
          builder.write_chroot_tarball(output)
          puts "Generated sysroot tarball at #{output}"
        end
        return 0
      end

      if write_tarball
        builder.generate_chroot_tarball(output, include_sources: include_sources)
        puts "Generated sysroot tarball at #{output}"
      else
        chroot_path = builder.generate_chroot(include_sources: include_sources)
        puts "Prepared chroot directory at #{chroot_path}"
      end
      0
    end

    # Run the internal bq2-curl helper.
    private def self.run_bq2_curl(args : Array(String)) : Int32
      Bq2Curl.run(args)
    end

    # Run the Git HTTPS remote helper.
    private def self.run_git_remote_https(args : Array(String)) : Int32
      GitRemoteHttps.run(args)
    end

    # Build a sysroot, run the full build plan, and archive the produced rootfs tarball.
    private def self.run_all(args : Array(String)) : Int32
      workspace = Path["data/sysroot"]
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

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 --all [options]") do |p|
        p.on("-w DIR", "--workspace=DIR", "Sysroot workspace directory (default: #{workspace})") { |val| workspace = Path[val] }
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
      end
      return CLI.print_help(parser) if help

      builder = SysrootBuilder.new(
        workspace: workspace,
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

      chroot_path = builder.generate_chroot(include_sources: true)
      puts "Prepared chroot directory at #{chroot_path}"

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
        STDERR.puts "Expected #{bq2_path}; run shards build && ./bin/bq2 --install before invoking --all."
        return 1
      end

      bind_spec = "#{repo_root}:#{repo_root}"
      status = Process.run(
        bq2_path.to_s,
        [
          "sysroot-namespace",
          "--rootfs",
          builder.rootfs_dir.to_s,
          "--bind",
          bind_spec,
          "--",
          bq2_path.to_s,
          "sysroot-runner",
          "--phase",
          "all",
        ],
        input: STDIN,
        output: STDOUT,
        error: STDERR,
      )

      unless status.success?
        STDERR.puts "sysroot-runner failed with exit code #{status.exit_code}"
        return status.exit_code
      end

      produced_tarball = builder.rootfs_dir / "workspace" / "bq-rootfs.tar.gz"
      unless File.exists?(produced_tarball)
        STDERR.puts "Expected rootfs tarball missing at #{produced_tarball}"
        return 1
      end

      output = builder.sources_dir / "bq2-rootfs-#{Bootstrap::VERSION}.tar.gz"
      FileUtils.mkdir_p(output.parent)
      FileUtils.cp(produced_tarball, output)
      puts "Generated rootfs tarball at #{output}"
      0
    end

    private def self.run_sysroot_namespace_check(args : Array(String)) : Int32
      proc_root = Path["/proc"]
      filesystems_path = Path["/proc/filesystems"]

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-namespace-check [options]") do |p|
        p.on("--proc-root=PATH", "Override proc root (default: #{proc_root})") { |val| proc_root = Path[val] }
        p.on("--filesystems=PATH", "Override /proc/filesystems path (default: #{filesystems_path})") { |val| filesystems_path = Path[val] }
      end
      return CLI.print_help(parser) if help

      restrictions = SysrootNamespace.collect_restrictions(
        proc_root: proc_root,
        filesystems_path: filesystems_path,
      )

      if restrictions.empty?
        puts "Namespace checks: OK (no obvious restrictions detected)"
        return 0
      end

      userns_toggle = File.exists?(SysrootNamespace::USERNS_TOGGLE_PATH) ? File.read(SysrootNamespace::USERNS_TOGGLE_PATH).strip : "missing"
      apparmor_toggle = File.exists?(SysrootNamespace::APPARMOR_USERNS_SYSCTL_PATH) ? File.read(SysrootNamespace::APPARMOR_USERNS_SYSCTL_PATH).strip : "missing"
      puts "Kernel userns toggles: kernel.unprivileged_userns_clone=#{userns_toggle}, kernel.apparmor_restrict_unprivileged_userns=#{apparmor_toggle}"

      puts "Namespace checks: detected potential restrictions:"
      restrictions.each { |restriction| puts "- #{restriction}" }

      puts
      puts "Suggested fixes:"
      restrictions.each do |restriction|
        case restriction
        when .includes?("kernel.unprivileged_userns_clone")
          puts "- Enable user namespaces: sudo sysctl -w kernel.unprivileged_userns_clone=1"
        when .includes?("missing filesystem support")
          puts "- Ensure proc/sysfs/tmpfs are enabled in the kernel (CONFIG_PROC_FS/CONFIG_SYSFS/CONFIG_TMPFS)"
        when .includes?("no_new_privs")
          puts "- Run without NoNewPrivs (container runtime security profile may need adjustment)"
        when .includes?("seccomp")
          puts "- Disable or relax the seccomp profile (e.g., --security-opt seccomp=unconfined) to allow userns mapping and sockets"
        when .includes?("user namespace setgroups mapping failed")
          puts "- Allow setgroups/uid_map writes inside user namespaces (adjust seccomp/LSM or run privileged)"
        when .includes?("setgroups")
          puts "- Ensure /proc/self/setgroups is present and writable (AppArmor/LSM/seccomp may be blocking it); consider running without seccomp/NoNewPrivs"
        end
      end
      1
    end

    private def self.run_sysroot_runner(args : Array(String)) : Int32
      plan_path = SysrootRunner::DEFAULT_PLAN_PATH
      phase : String? = nil
      packages = [] of String
      overrides_path : String? = nil
      use_default_overrides = true
      report_dir : String? = SysrootRunner::DEFAULT_REPORT_DIR
      state_path : String? = nil
      dry_run = false
      resume = true
      allow_outside_rootfs = false
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-runner [options]") do |p|
        p.on("--plan PATH", "Read the build plan from PATH (default: #{SysrootRunner::DEFAULT_PLAN_PATH})") { |path| plan_path = path }
        p.on("--phase NAME", "Select build phase to run (default: first phase; use 'all' for every phase)") { |name| phase = name }
        p.on("--package NAME", "Only run the named package(s); repeatable") { |name| packages << name }
        p.on("--overrides PATH", "Apply runtime overrides JSON (default: #{SysrootRunner::DEFAULT_OVERRIDES_PATH} when using the default plan path)") do |path|
          overrides_path = path
          use_default_overrides = false
        end
        p.on("--no-overrides", "Disable runtime overrides") do
          overrides_path = nil
          use_default_overrides = false
        end
        p.on("--report-dir PATH", "Write failure reports to PATH (default: #{SysrootRunner::DEFAULT_REPORT_DIR})") { |path| report_dir = path }
        p.on("--no-report", "Disable failure report writing") { report_dir = nil }
        p.on("--state-path PATH", "Write runner state/bookmarks to PATH (default: #{SysrootRunner::DEFAULT_STATE_PATH} when using the default plan path)") { |path| state_path = path }
        p.on("--no-resume", "Disable resume/state tracking (useful when the default state path is not writable)") { resume = false }
        p.on("--allow-outside-rootfs", "Allow running rootfs-* phases outside the produced rootfs (requires destdir overrides)") { allow_outside_rootfs = true }
        p.on("--dry-run", "List selected phases/steps and exit") { dry_run = true }
      end
      return CLI.print_help(parser) if help

      SysrootRunner.run_plan(
        plan_path,
        phase: phase,
        packages: packages.empty? ? nil : packages,
        overrides_path: overrides_path,
        use_default_overrides: use_default_overrides,
        report_dir: report_dir,
        dry_run: dry_run,
        state_path: state_path,
        resume: resume,
        allow_outside_rootfs: allow_outside_rootfs,
      )
      0
    end

    # Writes a freshly generated build plan JSON.
    #
    # This is useful when iterating inside a sysroot that contains an older plan
    # schema (or when you want to reset the plan after updating the tooling).
    private def self.run_sysroot_plan_write(args : Array(String)) : Int32
      output = SysrootRunner::DEFAULT_PLAN_PATH
      workspace_root = Bootstrap::BuildPlanUtils::DEFAULT_WORKSPACE_ROOT
      force = false
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-plan-write [options]") do |p|
        p.on("--output PATH", "Write the plan to PATH (default: #{SysrootRunner::DEFAULT_PLAN_PATH})") { |path| output = path }
        p.on("--workspace-root PATH", "Rewrite plan workdirs rooted at /workspace to PATH (default: #{workspace_root})") { |path| workspace_root = path }
        p.on("--force", "Overwrite an existing plan at the output path") { force = true }
      end
      return CLI.print_help(parser) if help

      if File.exists?(output) && !force
        STDERR.puts "Refusing to overwrite existing plan at #{output} (pass --force)"
        return 1
      end

      tmp_workspace = Path["/tmp/bq2-plan-write-#{Random::Secure.hex(4)}"]
      builder = SysrootBuilder.new(workspace: tmp_workspace)
      plan = builder.build_plan
      plan = Bootstrap::BuildPlanUtils.rewrite_workspace_root(plan, workspace_root) if workspace_root != Bootstrap::BuildPlanUtils::DEFAULT_WORKSPACE_ROOT

      FileUtils.mkdir_p(File.dirname(output))
      File.write(output, plan.to_json)
      puts "Wrote build plan to #{output}"
      0
    end

    # Run the finalize-rootfs phase to emit a prefix-free rootfs tarball.
    private def self.run_sysroot_tarball(args : Array(String)) : Int32
      plan_path = SysrootRunner::DEFAULT_PLAN_PATH
      overrides_path : String? = nil
      use_default_overrides = true
      report_dir : String? = SysrootRunner::DEFAULT_REPORT_DIR
      state_path : String? = nil
      resume = true
      allow_outside_rootfs = false
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-tarball [options]") do |p|
        p.on("--plan PATH", "Read the build plan from PATH (default: #{SysrootRunner::DEFAULT_PLAN_PATH})") { |path| plan_path = path }
        p.on("--overrides PATH", "Apply runtime overrides JSON (default: #{SysrootRunner::DEFAULT_OVERRIDES_PATH} when using the default plan path)") do |path|
          overrides_path = path
          use_default_overrides = false
        end
        p.on("--no-overrides", "Disable runtime overrides") do
          overrides_path = nil
          use_default_overrides = false
        end
        p.on("--report-dir PATH", "Write failure reports to PATH (default: #{SysrootRunner::DEFAULT_REPORT_DIR})") { |path| report_dir = path }
        p.on("--no-report", "Disable failure report writing") { report_dir = nil }
        p.on("--state-path PATH", "Write runner state/bookmarks to PATH (default: #{SysrootRunner::DEFAULT_STATE_PATH} when using the default plan path)") { |path| state_path = path }
        p.on("--no-resume", "Disable resume/state tracking (useful when the default state path is not writable)") { resume = false }
        p.on("--allow-outside-rootfs", "Allow running rootfs-* phases outside the produced rootfs (requires destdir overrides)") { allow_outside_rootfs = true }
      end
      return CLI.print_help(parser) if help

      SysrootRunner.run_plan(
        plan_path,
        phase: "finalize-rootfs",
        overrides_path: overrides_path,
        use_default_overrides: use_default_overrides,
        report_dir: report_dir,
        state_path: state_path,
        resume: resume,
        allow_outside_rootfs: allow_outside_rootfs,
      )
      0
    end

    private def self.run_codex_namespace(args : Array(String)) : Int32
      args = apply_codex_download_default(args)
      rootfs = Path["data/sysroot/rootfs"]
      alpine_setup = false
      add_dirs = Bootstrap::CodexNamespace::DEFAULT_CODEX_ADD_DIRS.dup
      codex_url : URI? = nil
      codex_sha256 : String? = nil
      codex_target = Bootstrap::CodexNamespace::DEFAULT_CODEX_TARGET
      default_codex_url = Bootstrap::CodexNamespace.default_codex_url?.try(&.to_s) || "unknown"

      parser, remaining, help = CLI.parse(args, "Usage: bq2 codex-namespace [options]") do |p|
        p.on("-C DIR", "Rootfs directory for the command (default: #{rootfs})") { |dir| rootfs = Path[dir].expand }
        p.on("--alpine", "Assume rootfs is Alpine and install runtime deps for Codex (node/npm/crystal)") { alpine_setup = true }
        p.on("--no-default-add-dirs", "Do not pass the default Codex sandbox writable dirs (/var,/workspace,/opt)") { add_dirs.clear }
        p.on("--add-dir PATH", "Add an extra writable dir for the Codex sandbox (repeatable)") { |dir| add_dirs << dir }
        p.on("--codex-download URL", "Download Codex into the rootfs before running it (default: #{default_codex_url})") do |val|
          codex_url = URI.parse(val)
        end
        p.on("--codex-sha256 SHA256", "Expected SHA256 for --codex-download") { |val| codex_sha256 = val }
        p.on("--codex-target PATH", "Target path for --codex-download inside the rootfs (default: #{codex_target})") { |val| codex_target = Path[val] }
      end
      return CLI.print_help(parser) if help

      unless remaining.empty?
        STDERR.puts "Unexpected extra arguments: #{remaining.join(" ")}"
        STDERR.puts "codex-namespace runs Codex; pass options only."
        return 1
      end

      status = CodexNamespace.run(
        rootfs: rootfs,
        alpine_setup: alpine_setup,
        add_dirs: add_dirs,
        codex_url: codex_url,
        codex_sha256: codex_sha256,
        codex_target: codex_target
      )
      status.exit_code
    rescue ex : SysrootNamespace::NamespaceError
      STDERR.puts "Namespace setup failed: #{ex.message}"
      1
    rescue ex
      STDERR.puts ex.message
      1
    end

    private def self.apply_codex_download_default(args : Array(String)) : Array(String)
      return args if args.empty?
      expanded = [] of String
      idx = 0
      while idx < args.size
        arg = args[idx]
        if arg == "--codex-download"
          next_arg = args[idx + 1]?
          if next_arg.nil? || next_arg.starts_with?("-")
            url = Bootstrap::CodexNamespace.default_codex_url?
            raise "No default Codex URL for this architecture; pass --codex-download URL instead." unless url
            expanded << "--codex-download=#{url}"
          else
            expanded << arg
            expanded << next_arg
            idx += 1
          end
        else
          expanded << arg
        end
        idx += 1
      end
      expanded
    end

    private def self.run_github_pr_feedback(args : Array(String)) : Int32
      GitHubCLI.run_pr_feedback(args)
    end

    private def self.run_github_pr_comment(args : Array(String)) : Int32
      GitHubCLI.run_pr_comment(args)
    end

    private def self.run_github_pr_create(args : Array(String)) : Int32
      GitHubCLI.run_pr_create(args)
    end

    private def self.run_default(args : Array(String)) : Int32
      run_help(args)
    end
  end
end

Log.setup_from_env
Bootstrap::Main.run

private def self.run_install(_args : Array(String)) : Int32
  bin_dir = Path["bin"]
  target = bin_dir / "bq2"
  links = %w[
    sysroot-builder
    sysroot-namespace
    sysroot-namespace-check
    sysroot-runner
    sysroot-plan-write
    sysroot-status
    codex-namespace
    github-pr-feedback
    github-pr-comment
    github-pr-create
  ]

  FileUtils.mkdir_p(bin_dir)
  unless File.exists?(target)
    STDERR.puts "warning: #{target} is missing; run `shards build` first"
  end

  links.each do |name|
    link_path = bin_dir / name
    File.delete(link_path) if File.symlink?(link_path) || File.exists?(link_path)
    File.symlink("bq2", link_path)
  end

  puts "Created symlinks in #{bin_dir}: #{links.join(", ")}"
  0
end
