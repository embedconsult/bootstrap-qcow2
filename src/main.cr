require "file_utils"
require "./sysroot_builder"
require "./sysroot_runner_lib"

module Bootstrap
  class Main
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
        preserve_ownership_for_rootfs: true,
      )
      chroot_path = builder.generate_chroot(include_sources: true)
      puts "Prepared chroot directory at #{chroot_path}"

      begin
        FileUtils.mkdir_p(workspace / "rootfs/dev")
        Process.run("mount", ["-t", "devtmpfs", "none", (workspace / "rootfs/dev").to_s])

        FileUtils.mkdir_p(workspace / "rootfs/proc")
        Process.run("mount", ["-t", "proc", "none", (workspace / "rootfs/proc").to_s])

        FileUtils.mkdir_p(workspace / "rootfs/sys")
        Process.run("mount", ["-t", "sysfs", "none", (workspace / "rootfs/sys").to_s])

        FileUtils.mkdir_p(workspace / "rootfs/tmp")
        Process.run("mount", ["-t", "tmpfs", "none", (workspace / "rootfs/tmp").to_s])

        File.write(workspace / "rootfs/etc/resolv.conf", "nameserver 8.8.8.8", perm = 0o644)

        Process.chroot((workspace / "rootfs").to_s)
        Process.run("/bin/echo", ["got here"], output: STDOUT)
        Process.run("apk", ["add", "crystal", "clang", "lld"], output: STDOUT)
      ensure
        Process.run("umount", ["-l", (workspace / "rootfs/tmp").to_s])
        Process.run("umount", ["-l", (workspace / "rootfs/sys").to_s])
        Process.run("umount", ["-l", (workspace / "rootfs/proc").to_s])
        Process.run("umount", ["-l", (workspace / "rootfs/dev").to_s])
      end
    end
  end
end

Log.setup_from_env
Bootstrap::Main.run
