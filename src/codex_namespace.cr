require "file_utils"
require "./sysroot_namespace"
require "./codex_session_bookmark"

module Bootstrap
  module CodexNamespace
    DEFAULT_ROOTFS = Path["data/sysroot/rootfs"]

    # Runs a command inside a fresh namespace rooted at *rootfs*. Binds the host
    # work directory into `/work` when requested.
    #
    # When invoking Codex, the wrapper stores the most recent Codex session id in
    # `/work/.codex-session-id` and will resume that session on the next run when
    # the default command is used.
    # Optionally installs node/npm via apk when targeting Alpine rootfs.
    def self.run(command : Array(String) = ["npx", "codex"],
                 rootfs : Path = DEFAULT_ROOTFS,
                 bind_work : Bool = true,
                 extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path),
                 alpine_setup : Bool = false) : Process::Status
      raise "Empty command" if command.empty?

      binds = extra_binds.dup
      if bind_work
        host_work = Path["/work"]
        if Dir.exists?(host_work)
          binds << {host_work, Path["work"]}
        else
          host_work = Path["codex/work"].expand
          FileUtils.mkdir_p(host_work)
          binds << {host_work, Path["work"]}
        end
      end

      SysrootNamespace.enter_rootfs(rootfs.to_s, extra_binds: binds)
      workdir = bind_work ? Path["/work"] : Path["/"]
      Dir.cd(Dir.exists?(workdir) ? workdir : Path["/"])

      env = {} of String => String
      uses_codex = command == ["codex"] || command == ["npx", "codex"] || command.first? == "codex" || (command.size > 1 && command.first == "npx" && command[1] == "codex")
      if bind_work && uses_codex
        env["HOME"] = "/work"
        env["CODEX_HOME"] = "/work/.codex"
        FileUtils.mkdir_p(Path["/work/.codex"])
        if bookmark = CodexSessionBookmark.read(Path["/work"])
          if command == ["npx", "codex"]
            command = ["npx", "codex", "resume", bookmark]
          elsif command == ["codex"]
            command = ["codex", "resume", bookmark]
          end
        end
      end

      if alpine_setup
        status = Process.run("apk", ["add", "nodejs-lts", "npm", "bash"], output: STDOUT, error: STDERR)
        raise "apk install failed" unless status.success?
        status = Process.run("npm", ["i", "-g", "@openai/codex"], output: STDOUT, error: STDERR)
        raise "npm install failed" unless status.success?
      end

      status = Process.run(command.first, command[1..], env: env, input: STDIN, output: STDOUT, error: STDERR)
      if bind_work && uses_codex
        if latest = CodexSessionBookmark.latest_from(Path["/work/.codex"])
          CodexSessionBookmark.write(Path["/work"], latest)
        end
      end
      status
    end
  end
end
