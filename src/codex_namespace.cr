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
    DEFAULT_WORK_MOUNT = Path["work"]
    DEFAULT_WORK_DIR   = Path["/work"]

    # Runs a command inside a fresh namespace rooted at *rootfs*. Binds the host
    # work directory (`./codex/work`) into `/work`.
    #
    # When invoking Codex, the wrapper stores the most recent Codex session id in
    # `/work/.codex-session-id` and will resume that session on the next run when
    # possible.
    # Optionally installs node/npm via apk when targeting Alpine rootfs.
    def self.run(rootfs : Path = DEFAULT_ROOTFS,
                 alpine_setup : Bool = false,
                 add_dirs : Array(String) = DEFAULT_CODEX_ADD_DIRS,
                 work_mount : Path = DEFAULT_WORK_MOUNT,
                 work_dir : Path = DEFAULT_WORK_DIR) : Process::Status
      host_work = Path["codex/work"].expand
      FileUtils.mkdir_p(host_work)
      FileUtils.mkdir_p(rootfs / work_mount)
      binds = [{host_work, work_mount}] of Tuple(Path, Path)

      AlpineSetup.write_resolv_conf(rootfs) if alpine_setup
      SysrootNamespace.enter_rootfs(rootfs.to_s, extra_binds: binds)
      FileUtils.mkdir_p(work_dir)
      Dir.cd(work_dir)

      env = {
        "HOME"       => work_dir.to_s,
        "CODEX_HOME" => (work_dir / ".codex").to_s,
        "PATH"       => ENV["PATH"]? || "",
      }
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
      status = Process.run(command.first, command[1..], env: env, input: STDIN, output: STDOUT, error: STDERR)
      if latest = CodexSessionBookmark.latest_from(work_dir / ".codex")
        CodexSessionBookmark.write(work_dir, latest)
      end
      status
    end
  end
end
