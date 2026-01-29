require "file_utils"
require "log"
require "path"
require "process"
require "./process_runner"

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
      libressl-dev
      crystal
      lld
      llvm-libs
      linux-headers
      make
      musl-dev
      patch
      zlib-dev
      pcre2-dev
      gc-dev
      yaml-dev
      perl
      python3
      shards
    ]

    def self.write_resolv_conf(rootfs : Path, nameserver : String = DEFAULT_NAMESERVER) : Nil
      target = rootfs / "etc/resolv.conf"
      FileUtils.mkdir_p(target.parent)
      File.write(target, "nameserver #{nameserver}\n", perm = 0o644)
    end

    def self.install_sysroot_runner_packages : Nil
      apk_add(SYSROOT_RUNNER_PACKAGES)
    end

    def self.apk_add(packages : Array(String)) : Nil
      return if packages.empty?
      argv = ["add", "--no-cache"] + packages
      Log.info { "apk #{argv.join(" ")}" }
      result = ProcessRunner.run(["apk"] + argv)
      status = result.status
      raise "apk add failed (#{status.exit_code})" unless status.success?
    end
  end
end
