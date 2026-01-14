require "file_utils"
require "log"
require "path"
require "process"

module Bootstrap
  # Shared Alpine-specific setup for sysroot iteration.
  #
  # This is intentionally small and explicit:
  # - DNS must be configured by writing `etc/resolv.conf` on the *host-visible*
  #   rootfs tree before entering the namespace.
  # - Packages are installed *after* `SysrootNamespace.enter_rootfs` via `apk`.
  module AlpineSetup
    DEFAULT_NAMESERVER = "8.8.8.8"

    # Packages needed to replay the sysroot build plan in an Alpine seed rootfs.
    #
    # Keep this explicit (avoid meta packages) so the environment is auditable.
    SYSROOT_RUNNER_PACKAGES = %w[
      bash
      binutils
      clang
      libgcc
      libstdc++-dev
      crystal
      lld
      linux-headers
      make
      musl-dev
      patch
      perl
      shards
    ]

    # Extra packages needed to run Codex via `npx codex` inside Alpine.
    CODEX_PACKAGES = %w[
      nodejs-lts
      npm
    ]

    CODEX_NPM_PACKAGES = %w[
      @openai/codex
    ]

    def self.write_resolv_conf(rootfs : Path, nameserver : String = DEFAULT_NAMESERVER) : Nil
      target = rootfs / "etc/resolv.conf"
      FileUtils.mkdir_p(target.parent)
      File.write(target, "nameserver #{nameserver}\n", perm = 0o644)
    end

    def self.install_sysroot_runner_packages : Nil
      apk_add(SYSROOT_RUNNER_PACKAGES)
    end

    def self.install_codex_packages(install_npm_global : Bool = true) : Nil
      apk_add(CODEX_PACKAGES)
      return unless install_npm_global
      npm_install_global(CODEX_NPM_PACKAGES)
    end

    def self.apk_add(packages : Array(String)) : Nil
      return if packages.empty?
      argv = ["add", "--no-cache"] + packages
      Log.info { "apk #{argv.join(" ")}" }
      status = Process.run("apk", argv, output: STDOUT, error: STDERR)
      raise "apk add failed (#{status.exit_code})" unless status.success?
    end

    def self.npm_install_global(packages : Array(String)) : Nil
      return if packages.empty?
      argv = ["i", "-g"] + packages
      Log.info { "npm #{argv.join(" ")}" }
      status = Process.run("npm", argv, output: STDOUT, error: STDERR)
      raise "npm install failed (#{status.exit_code})" unless status.success?
    end
  end
end
