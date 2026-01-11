require "file_utils"
require "./sysroot_builder"
require "./sysroot_namespace"
require "./sysroot_runner_lib"

module Bootstrap
  class Main
    # Prototype entrypoint to build and mount a sysroot in-place.
    def self.run
      workspace = Path["data/sysroot"]
      architecture = SysrootBuilder::DEFAULT_ARCH
      branch = SysrootBuilder::DEFAULT_BRANCH
      base_version = SysrootBuilder::DEFAULT_BASE_VERSION

      puts "Sysroot builder log level=#{Log.for("").level} (env-configured)"
      builder = SysrootBuilder.new(
        workspace: workspace,
        architecture: architecture,
        branch: branch,
        base_version: base_version,
        use_system_tar_for_sources: false,
        use_system_tar_for_rootfs: false,
        preserve_ownership_for_sources: false,
        preserve_ownership_for_rootfs: false,
      )
      chroot_path = builder.generate_chroot(include_sources: true)
      puts "Prepared chroot directory at #{chroot_path}"

      File.write(chroot_path / "/etc/resolv.conf", "nameserver 8.8.8.8", perm = 0o644)
      SysrootNamespace.enter_rootfs(chroot_path.to_s)
      Process.run("apk", ["add", "crystal", "clang", "lld"], output: STDOUT)
    end
  end
end

Log.setup_from_env
Bootstrap::Main.run
