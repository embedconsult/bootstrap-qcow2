require "file_utils"
require "./alpine_setup"
require "./sysroot_namespace"
require "./codex_session_bookmark"

module Bootstrap
  module CodexNamespace
    DEFAULT_ROOTFS = Path["data/sysroot/rootfs"]

    # Runs a command inside a fresh namespace rooted at *rootfs*. Binds the host
    # work directory (`./codex/work`) into `/work`.
    #
    # When invoking Codex, the wrapper stores the most recent Codex session id in
    # `/work/.codex-session-id` and will resume that session on the next run when
    # possible.
    # Optionally installs node/npm via apk when targeting Alpine rootfs.
    def self.run(rootfs : Path = DEFAULT_ROOTFS, alpine_setup : Bool = false) : Process::Status
      host_work = Path["codex/work"].expand
      FileUtils.mkdir_p(host_work)
      binds = [{host_work, Path["work"]}] of Tuple(Path, Path)

      AlpineSetup.write_resolv_conf(rootfs) if alpine_setup
      SysrootNamespace.enter_rootfs(rootfs.to_s, extra_binds: binds)
      Dir.cd(Path["/work"])

      env = {
        "HOME"       => "/work",
        "CODEX_HOME" => "/work/.codex",
      }
      FileUtils.mkdir_p(Path["/work/.codex"])

      if alpine_setup
        AlpineSetup.install_sysroot_runner_packages
        AlpineSetup.install_codex_packages
      end

      command = if bookmark = CodexSessionBookmark.read(Path["/work"])
                  ["codex", "resume", bookmark]
                else
                  ["codex"]
                end
      status = Process.run(command.first, command[1..], env: env, input: STDIN, output: STDOUT, error: STDERR)
      if latest = CodexSessionBookmark.latest_from(Path["/work/.codex"])
        CodexSessionBookmark.write(Path["/work"], latest)
      end
      status
    end
  end
end
