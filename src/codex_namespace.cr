require "file_utils"
require "./sysroot_namespace"

module Bootstrap
  module CodexNamespace
    DEFAULT_ROOTFS = Path["data/sysroot/rootfs"]

    # Runs a command inside a fresh namespace rooted at *rootfs*. Binds the host
    # optionally binds ./codex/work into /work.
    # Optionally installs node/npm via apk when targeting Alpine rootfs.
    def self.run(command : Array(String) = ["npx", "codex"],
                 rootfs : Path = DEFAULT_ROOTFS,
                 bind_codex_work : Bool = true,
                 alpine_setup : Bool = false) : Process::Status
      raise "Empty command" if command.empty?

      extra_binds = [] of Tuple(Path, Path)
      if bind_codex_work
        host_work = Path["codex/work"].expand
        FileUtils.mkdir_p(host_work)
        extra_binds << {host_work, Path["work"]}
      end

      SysrootNamespace.enter_rootfs(rootfs.to_s, extra_binds: extra_binds)
      workdir = bind_codex_work ? Path["/work"] : Path["/"]
      Dir.cd(Dir.exists?(workdir) ? workdir : Path["/"])

      if alpine_setup
        status = Process.run("apk", ["add", "nodejs-lts", "npm", "bash"], output: STDOUT, error: STDERR)
        raise "apk install failed" unless status.success?
        status = Process.run("npm", ["i", "-g", "@openai/codex"], output: STDOUT, error: STDERR)
        raise "npm install failed" unless status.success?
      end

      Process.run(command.first, command[1..], input: STDIN, output: STDOUT, error: STDERR)
    end
  end
end
