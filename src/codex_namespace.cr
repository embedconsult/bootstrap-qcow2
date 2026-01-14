require "file_utils"
require "./alpine_setup"
require "./sysroot_namespace"
require "./codex_session_bookmark"

module Bootstrap
  module CodexNamespace
    DEFAULT_ROOTFS         = Path["data/sysroot/rootfs"]
    DEFAULT_CODEX_ADD_DIRS = [
      "/var",
      "/opt",
      "/workspace",
    ]

    # Runs a command inside a fresh namespace rooted at *rootfs*. Binds the host
    # work directory (`./codex/work`) into `/work` when requested.
    #
    # When invoking Codex, the wrapper stores the most recent Codex session id in
    # `/work/.codex-session-id` and will resume that session on the next run when
    # the default command is used.
    # Optionally installs node/npm via apk when targeting Alpine rootfs.
    def self.run(command : Array(String) = ["npx", "codex"],
                 rootfs : Path = DEFAULT_ROOTFS,
                 bind_work : Bool = true,
                 alpine_setup : Bool = false,
                 codex_add_dirs : Array(String) = DEFAULT_CODEX_ADD_DIRS) : Process::Status
      raise "Empty command" if command.empty?

      binds = [] of Tuple(Path, Path)
      if bind_work
        host_work = Path["codex/work"].expand
        FileUtils.mkdir_p(host_work)
        binds << {host_work, Path["work"]}
      end

      AlpineSetup.write_resolv_conf(rootfs) if alpine_setup
      SysrootNamespace.enter_rootfs(rootfs.to_s, extra_binds: binds)
      workdir = bind_work ? Path["/work"] : Path["/"]
      Dir.cd(Dir.exists?(workdir) ? workdir : Path["/"])

      env = {} of String => String
      uses_codex = command == ["codex"] || command == ["npx", "codex"] || command.first? == "codex" || (command.size > 1 && command.first == "npx" && command[1] == "codex")
      if bind_work && uses_codex
        env["HOME"] = "/work"
        env["CODEX_HOME"] = "/work/.codex"
        FileUtils.mkdir_p(Path["/work/.codex"])
        if command == ["npx", "codex"] || command == ["codex"]
          command = inject_codex_add_dirs(command, codex_add_dirs)
          if bookmark = CodexSessionBookmark.read(Path["/work"])
            command += ["resume", bookmark]
          end
        end
      end

      if alpine_setup
        AlpineSetup.install_sysroot_runner_packages
        AlpineSetup.install_codex_packages
      end

      status = Process.run(command.first, command[1..], env: env, input: STDIN, output: STDOUT, error: STDERR)
      if bind_work && uses_codex
        if latest = CodexSessionBookmark.latest_from(Path["/work/.codex"])
          CodexSessionBookmark.write(Path["/work"], latest)
        end
      end
      status
    end

    private def self.inject_codex_add_dirs(command : Array(String), dirs : Array(String)) : Array(String)
      insert_at =
        if command.size >= 2 && command[0] == "npx" && command[1] == "codex"
          2
        elsif command[0] == "codex"
          1
        else
          return command
        end

      updated = command.dup
      dirs.reverse_each do |dir|
        updated.insert(insert_at, dir)
        updated.insert(insert_at, "--add-dir")
      end
      updated
    end
  end
end
