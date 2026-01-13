require "log"
require "./bootstrap-qcow2"
require "./cli"
require "./sysroot_builder"
require "./sysroot_namespace"
require "./sysroot_runner_lib"
require "./codex_namespace"

module Bootstrap
  # Busybox-style dispatcher: one binary, many entrypoints selected by argv[0]
  # or by providing the subcommand as the first argument.
  module Main
    COMMANDS = {
      "--install"               => ->(args : Array(String)) { run_install(args) },
      "default"                 => ->(args : Array(String)) { run_default(args) },
      "sysroot-builder"         => ->(args : Array(String)) { run_sysroot_builder(args) },
      "sysroot-namespace"       => ->(args : Array(String)) { run_sysroot_namespace(args) },
      "sysroot-namespace-check" => ->(args : Array(String)) { run_sysroot_namespace_check(args) },
      "sysroot-runner"          => ->(args : Array(String)) { run_sysroot_runner(args) },
      "codex-namespace"         => ->(args : Array(String)) { run_codex_namespace(args) },
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
      puts "  bootstrap-qcow2 <command> [options] [-- command args]\n\nCommands:"
      puts "  --install               Create CLI symlinks in ./bin"
      puts "  (default)               Build sysroot and enter shell inside it"
      puts "  sysroot-builder         Build sysroot tarball or directory"
      puts "  sysroot-namespace       Enter a namespaced rootfs and exec a command"
      puts "  sysroot-namespace-check Check host namespace prerequisites"
      puts "  sysroot-runner          Replay build plan inside the sysroot"
      puts "  codex-namespace         Run Codex inside a namespaced rootfs"
      puts "  help                    Show this message"
      puts "\nInvoke via symlink (e.g., bin/sysroot-builder) or as the first argument."
      exit_code
    end

    private def self.run_sysroot_namespace(args : Array(String)) : Int32
      rootfs = "data/sysroot/rootfs"
      command = [] of String
      parser, remaining, help = CLI.parse(args, "Usage: bootstrap-qcow2 sysroot-namespace [options] [-- command...]") do |p|
        p.on("--rootfs=PATH", "Path to the sysroot rootfs (default: #{rootfs})") { |val| rootfs = val }
      end
      return CLI.print_help(parser) if help

      command = remaining.empty? ? ["/bin/sh"] : remaining
      Log.debug { "Entering namespace with rootfs=#{rootfs} command=#{command.join(" ")}" }

      SysrootNamespace.enter_rootfs(rootfs)
      Process.exec(command.first, command[1..])
    rescue ex : File::Error
      cmd = command || [] of String
      Log.error { "Process exec failed for #{cmd.join(" ")}: #{ex.message}" }
      raise ex
    end

    private def self.run_sysroot_builder(args : Array(String)) : Int32
      output = Path["sysroot.tar.gz"]
      workspace = Path["data/sysroot"]
      architecture = SysrootBuilder::DEFAULT_ARCH
      branch = SysrootBuilder::DEFAULT_BRANCH
      base_version = SysrootBuilder::DEFAULT_BASE_VERSION
      include_sources = true
      use_system_tar_for_sources = false
      use_system_tar_for_rootfs = false
      preserve_ownership_for_sources = false
      preserve_ownership_for_rootfs = false
      owner_uid = nil
      owner_gid = nil
      write_tarball = true

      parser, _remaining, help = CLI.parse(args, "Usage: bootstrap-qcow2 sysroot-builder [options]") do |p|
        p.on("-o OUTPUT", "--output=OUTPUT", "Target sysroot tarball (default: #{output})") { |val| output = Path[val] }
        p.on("-w DIR", "--workspace=DIR", "Workspace directory (default: #{workspace})") { |val| workspace = Path[val] }
        p.on("-a ARCH", "--arch=ARCH", "Target architecture (default: #{architecture})") { |val| architecture = val }
        p.on("-b BRANCH", "--branch=BRANCH", "Source branch/release tag (default: #{branch})") { |val| branch = val }
        p.on("-v VERSION", "--base-version=VERSION", "Base rootfs version/tag (default: #{base_version})") { |val| base_version = val }
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
        p.on("--no-tarball", "Prepare the chroot tree without writing a tarball") { write_tarball = false }
      end
      return CLI.print_help(parser) if help

      Log.info { "Sysroot builder log level=#{Log.for("").level} (env-configured)" }
      builder = SysrootBuilder.new(
        workspace: workspace,
        architecture: architecture,
        branch: branch,
        base_version: base_version,
        use_system_tar_for_sources: use_system_tar_for_sources,
        use_system_tar_for_rootfs: use_system_tar_for_rootfs,
        preserve_ownership_for_sources: preserve_ownership_for_sources,
        preserve_ownership_for_rootfs: preserve_ownership_for_rootfs,
        owner_uid: owner_uid,
        owner_gid: owner_gid
      )
      if write_tarball
        builder.generate_chroot_tarball(output, include_sources: include_sources)
        puts "Generated sysroot tarball at #{output}"
      else
        chroot_path = builder.generate_chroot(include_sources: include_sources)
        puts "Prepared chroot directory at #{chroot_path}"
      end
      0
    end

    private def self.run_sysroot_namespace_check(args : Array(String)) : Int32
      proc_root = Path["/proc"]
      filesystems_path = Path["/proc/filesystems"]

      parser, _remaining, help = CLI.parse(args, "Usage: bootstrap-qcow2 sysroot-namespace-check [options]") do |p|
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

    private def self.run_sysroot_runner(_args : Array(String)) : Int32
      SysrootRunner.run_plan
      0
    end

    private def self.run_codex_namespace(args : Array(String)) : Int32
      rootfs = Path["data/sysroot/rootfs"]
      bind_codex_work = true
      alpine_setup = false

      parser, remaining, help = CLI.parse(args, "Usage: bootstrap-qcow2 codex-namespace [options] [-- cmd ...]") do |p|
        p.on("-C DIR", "Rootfs directory for the command (default: #{rootfs})") { |dir| rootfs = Path[dir].expand }
        p.on("--no-bind-codex-work", "Do not bind host ./codex/work into /work") { bind_codex_work = false }
        p.on("--alpine", "Assume rootfs is Alpine and install runtime deps for npx codex (node/npm)") { alpine_setup = true }
      end
      return CLI.print_help(parser) if help

      command = remaining.dup
      command = ["npx", "codex"] if command.empty?

      status = CodexNamespace.run(command, rootfs: rootfs, bind_codex_work: bind_codex_work, alpine_setup: alpine_setup)
      status.exit_code
    rescue ex : SysrootNamespace::NamespaceError
      STDERR.puts "Namespace setup failed: #{ex.message}"
      1
    end

    private def self.run_default(_args : Array(String)) : Int32
      workspace = Path["data/sysroot"]
      puts "Sysroot builder log level=#{Log.for("").level} (env-configured)"
      builder = SysrootBuilder.new(
        workspace: workspace,
        architecture: SysrootBuilder::DEFAULT_ARCH,
        branch: SysrootBuilder::DEFAULT_BRANCH,
        base_version: SysrootBuilder::DEFAULT_BASE_VERSION,
        use_system_tar_for_sources: false,
        use_system_tar_for_rootfs: false,
        preserve_ownership_for_sources: false,
        preserve_ownership_for_rootfs: false,
      )
      chroot_path = builder.generate_chroot(include_sources: true)
      puts "Prepared chroot directory at #{chroot_path}"

      File.write(chroot_path / "/etc/resolv.conf", "nameserver 8.8.8.8", perm = 0o644)
      SysrootNamespace.enter_rootfs(chroot_path.to_s)
      status = Process.run(
        "apk",
        ["add", "crystal", "clang", "lld"],
        input: STDIN,
        output: STDOUT,
        error: STDERR,
      )
      status.exit_code
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
    codex-namespace
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
