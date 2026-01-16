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
    DEFAULT_CODEX_BIN  = Path["/workspace/codex/bin/codex"]
    DEFAULT_WORK_MOUNT = Path["work"]
    DEFAULT_WORK_DIR   = Path["/work"]
    DEFAULT_EXEC_PATH  = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    # Runs a command inside a fresh namespace rooted at *rootfs*. Binds the host
    # work directory (`./codex/work`) into `/work`.
    #
    # When invoking Codex, the wrapper stores the most recent Codex session id in
    # `/work/.codex-session-id` and will resume that session on the next run when
    # possible.
    # Optionally installs node/npm via apk when targeting Alpine rootfs.
    # When *codex_bin* is set, the host Codex binary is bind-mounted into
    # *codex_target* (default: /workspace/codex/bin/codex) for non-Alpine rootfs.
    def self.run(rootfs : Path = DEFAULT_ROOTFS,
                 alpine_setup : Bool = false,
                 add_dirs : Array(String) = DEFAULT_CODEX_ADD_DIRS,
                 exec_path : String = DEFAULT_EXEC_PATH,
                 work_mount : Path = DEFAULT_WORK_MOUNT,
                 work_dir : Path = DEFAULT_WORK_DIR,
                 codex_bin : Path? = nil,
                 codex_target : Path = DEFAULT_CODEX_BIN) : Process::Status
      host_work = Path["codex/work"].expand
      FileUtils.mkdir_p(host_work)
      FileUtils.mkdir_p(rootfs / work_mount)
      binds = [{host_work, work_mount}] of Tuple(Path, Path)
      effective_exec_path = exec_path
      if codex_bin
        target = normalize_bind_target(codex_target)
        FileUtils.mkdir_p(rootfs / target.parent)
        binds << {codex_bin.not_nil!, target}
      end

      workspace_bin = "/workspace/codex/bin"
      if codex_bin || File.exists?(rootfs / normalize_bind_target(DEFAULT_CODEX_BIN))
        unless effective_exec_path.split(":").includes?(workspace_bin)
          effective_exec_path = "#{workspace_bin}:#{effective_exec_path}"
        end
      end

      AlpineSetup.write_resolv_conf(rootfs) if alpine_setup
      SysrootNamespace.enter_rootfs(rootfs.to_s, extra_binds: binds)
      FileUtils.mkdir_p(work_dir)
      Dir.cd(work_dir)

      env = {
        "HOME"       => work_dir.to_s,
        "CODEX_HOME" => (work_dir / ".codex").to_s,
        "PATH"       => effective_exec_path,
      }
      if api_key = ENV["OPENAI_API_KEY"]?
        env["OPENAI_API_KEY"] = api_key
      end
      FileUtils.mkdir_p(work_dir / ".codex")

      if alpine_setup
        AlpineSetup.install_sysroot_runner_packages
        AlpineSetup.install_codex_packages
      end

      codex_args = [] of String
      add_dirs.each do |dir|
        codex_args << "--add-dir"
        codex_args << dir
      end

      command = if bookmark = CodexSessionBookmark.read(work_dir)
                  ["codex"] + codex_args + ["resume", bookmark]
                else
                  ["codex"] + codex_args
                end
      status = with_path_for_lookup(effective_exec_path) do
        Process.run(command.first, command[1..], env: env, clear_env: true, input: STDIN, output: STDOUT, error: STDERR)
      end
      if latest = CodexSessionBookmark.latest_from(work_dir / ".codex")
        CodexSessionBookmark.write(work_dir, latest)
      end
      status
    end

    # Normalize a bind target so it is relative to the rootfs.
    private def self.normalize_bind_target(target : Path) : Path
      cleaned = target.to_s
      cleaned = cleaned[1..] if cleaned.starts_with?("/")
      Path[cleaned]
    end

    # Ensure PATH-based lookups for the executable use *exec_path*.
    private def self.with_path_for_lookup(exec_path : String, &block : -> T) : T forall T
      previous = ENV["PATH"]?
      ENV["PATH"] = exec_path
      begin
        yield
      ensure
        if previous
          ENV["PATH"] = previous
        else
          ENV.delete("PATH")
        end
      end
    end
  end
end
