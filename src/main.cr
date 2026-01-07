require "option_parser"
require "./sysroot_builder"
require "./sysroot_runner_lib"

module Bootstrap
  class Main
    def self.run
      architecture = SysrootBuilder::DEFAULT_ARCH
      branch = SysrootBuilder::DEFAULT_BRANCH
      base_version = SysrootBuilder::DEFAULT_BASE_VERSION

      puts "Sysroot builder log level=#{Log.for("").level} (env-configured)"
      builder = SysrootBuilder.new(
        workspace: Path["data/sysroot"],
        architecture: architecture,
        branch: branch,
        base_version: base_version,
        use_system_tar_for_sources: false,
        use_system_tar_for_rootfs: false,
        preserve_ownership_for_sources: false,
        preserve_ownership_for_rootfs: true,
      )
      chroot_path = builder.generate_chroot(include_sources: true)
      puts "Prepared chroot directory at #{chroot_path}"
    end
  end
end

Log.setup_from_env
Bootstrap::Main.run
