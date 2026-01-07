require "option_parser"
require "./sysroot_builder"

module Bootstrap
  # Entry point to generate a chrootable sysroot tarball without using crystal eval.
  class SysrootBuilderMain
    def self.run
      output = Path["sysroot.tar.gz"]
      workspace = Path["data/sysroot"]
      architecture = SysrootBuilder::DEFAULT_ARCH
      branch = SysrootBuilder::DEFAULT_BRANCH
      base_version = SysrootBuilder::DEFAULT_BASE_VERSION
      include_sources = true
      use_system_tar_for_sources = false
      use_system_tar_for_rootfs = false
      preserve_ownership = false
      owner_uid = nil
      owner_gid = nil
      write_tarball = true

      OptionParser.parse do |parser|
        parser.banner = "Usage: crystal run src/sysroot_builder_main.cr -- [options]"
        parser.on("-o OUTPUT", "--output=OUTPUT", "Target sysroot tarball (default: #{output})") { |val| output = Path[val] }
        parser.on("-w DIR", "--workspace=DIR", "Workspace directory (default: #{workspace})") { |val| workspace = Path[val] }
        parser.on("-a ARCH", "--arch=ARCH", "Target architecture (default: #{architecture})") { |val| architecture = val }
        parser.on("-b BRANCH", "--branch=BRANCH", "Source branch/release tag (default: #{branch})") { |val| branch = val }
        parser.on("-v VERSION", "--base-version=VERSION", "Base rootfs version/tag (default: #{base_version})") { |val| base_version = val }
        parser.on("--skip-sources", "Skip staging source archives into the rootfs") { include_sources = false }
        parser.on("--system-tar-sources", "Use system tar to extract all staged source archives") { use_system_tar_for_sources = true }
        parser.on("--system-tar-rootfs", "Use system tar to extract the base rootfs") { use_system_tar_for_rootfs = true }
        parser.on("--preserve-ownership", "Preserve archive ownership metadata when extracting tarballs") { preserve_ownership = true }
        parser.on("--owner-uid=UID", "Override extracted file owner uid (implies --preserve-ownership)") do |val|
          preserve_ownership = true
          owner_uid = val.to_i
        end
        parser.on("--owner-gid=GID", "Override extracted file owner gid (implies --preserve-ownership)") do |val|
          preserve_ownership = true
          owner_gid = val.to_i
        end
        parser.on("--no-tarball", "Prepare the chroot tree without writing a tarball") { write_tarball = false }
        parser.on("-h", "--help", "Show this help") { puts parser; exit }
      end

      Log.info { "Sysroot builder log level=#{Log.for("").level} (env-configured)" }
      builder = SysrootBuilder.new(
        workspace: workspace,
        architecture: architecture,
        branch: branch,
        base_version: base_version,
        use_system_tar_for_sources: use_system_tar_for_sources,
        use_system_tar_for_rootfs: use_system_tar_for_rootfs,
        preserve_ownership: preserve_ownership,
        owner_uid: owner_uid,
        owner_gid: owner_gid
      )
      if write_tarball
        builder.generate_chroot_tarball(output, include_sources: include_sources)
        puts "Generated sysroot tarball at #{output}"
      else
        chroot_path = builder.generate_chroot(include_sources: include_sources)
        puts "Prepared chroot directory at #{chroot_path}"
      end
    end
  end
end

Log.setup_from_env
Bootstrap::SysrootBuilderMain.run
