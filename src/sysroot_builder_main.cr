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

      OptionParser.parse do |parser|
        parser.banner = "Usage: crystal run src/sysroot_builder_main.cr -- [options]"
        parser.on("-o OUTPUT", "--output=OUTPUT", "Target sysroot tarball (default: #{output})") { |val| output = Path[val] }
        parser.on("-w DIR", "--workspace=DIR", "Workspace directory (default: #{workspace})") { |val| workspace = Path[val] }
        parser.on("-a ARCH", "--arch=ARCH", "Target architecture (default: #{architecture})") { |val| architecture = val }
        parser.on("-b BRANCH", "--branch=BRANCH", "Source branch/release tag (default: #{branch})") { |val| branch = val }
        parser.on("-v VERSION", "--base-version=VERSION", "Base rootfs version/tag (default: #{base_version})") { |val| base_version = val }
        parser.on("-h", "--help", "Show this help") { puts parser; exit }
      end

      builder = SysrootBuilder.new(workspace, architecture, branch, base_version)
      builder.generate_chroot_tarball(output)
      puts "Generated sysroot tarball at #{output}"
    end
  end
end

Bootstrap::SysrootBuilderMain.run
