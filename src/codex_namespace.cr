require "file_utils"
require "./sysroot_namespace"

module Bootstrap
  module CodexNamespace
    DEFAULT_ROOTFS = Path["data/sysroot/rootfs"]

    # Runs a command inside a fresh namespace rooted at *rootfs*. Binds the host
    # repository into /workspace and optionally binds ./codex/work into /work.
    # Optionally installs node/npm via apk when targeting Alpine rootfs.
    def self.run(command : Array(String) = ["npx", "codex"],
                 rootfs : Path = DEFAULT_ROOTFS,
                 bind_codex_work : Bool = true,
                 alpine_setup : Bool = false) : Process::Status
      raise "Empty command" if command.empty?

      extra_binds = [] of Tuple(Path, Path)
      extra_binds << {Path[Dir.current], Path["workspace"]}
      if bind_codex_work
        extra_binds << {Path["codex/work"].expand, Path["work"]}
      end

      SysrootNamespace.enter_rootfs(rootfs.to_s, extra_binds: extra_binds)
      Dir.cd("/workspace")

      if alpine_setup
        status = Process.run("apk", ["add", "nodejs", "npm", "bash"], output: STDOUT, error: STDERR)
        raise "apk install failed" unless status.success?
      end

      Process.run(command.first, command[1..], output: STDOUT, error: STDERR)
    end
  end
end
