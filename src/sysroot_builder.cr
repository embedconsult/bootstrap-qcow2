require "digest/crc32"
require "digest/sha256"
require "file_utils"
require "http/client"
require "json"
require "log"
require "path"
require "uri"

module Bootstrap
  # SysrootBuilder prepares a chroot-able Alpine environment that can rebuild
  # a complete sysroot using source tarballs cached on the host.
  #
  # The builder fetches and verifies sources with Crystal's HTTP and Digest
  # standard libraries—no external download tools are invoked. The default
  # package set mirrors the minimal Alpine inputs required to rebuild the
  # Crystal toolchain and a Clang/LLVM userland on aarch64.
  class SysrootBuilder
    DEFAULT_ARCH     = "aarch64"
    DEFAULT_BRANCH   = "edge"
    DEFAULT_MINIROOT = "edge"
    DEFAULT_LLVM_VER = "18.1.7"
    DEFAULT_LIBRESSL = "3.8.2"
    DEFAULT_BUSYBOX  = "1.36.1"
    DEFAULT_MUSL     = "1.2.5"
    DEFAULT_CMAKE    = "3.29.6"
    DEFAULT_M4       = "1.4.19"
    DEFAULT_GNU_MAKE = "4.4.1"
    DEFAULT_ZLIB     = "1.3.1"
    DEFAULT_PCRE2    = "10.44"
    DEFAULT_GMP      = "6.3.0"
    DEFAULT_LIBICONV = "1.17"
    DEFAULT_LIBXML2  = "2.12.7"
    DEFAULT_LIBYAML  = "0.2.5"
    DEFAULT_LIBFFI   = "3.4.6"
    DEFAULT_BDWGC    = "8.2.6"

    record PackageSpec,
      name : String,
      version : String,
      url : URI,
      sha256 : String? = nil,
      checksum_url : URI? = nil,
      configure_flags : Array(String) = [] of String,
      build_directory : String? = nil do
      def filename : String
        File.basename(url.path)
      end
    end

    struct BuildStep
      include JSON::Serializable

      getter name : String
      getter commands : Array(Array(String))
      getter workdir : String

      def initialize(pkg : PackageSpec, commands : Array(Array(String)), workdir : String)
        @name = pkg.name
        @commands = commands
        @workdir = workdir
      end
    end

    getter architecture : String
    getter branch : String
    getter workspace : Path

    def initialize(@workspace : Path = Path["data/sysroot"],
                   @architecture : String = DEFAULT_ARCH,
                   @branch : String = DEFAULT_BRANCH)
      FileUtils.mkdir_p(@workspace)
      FileUtils.mkdir_p(cache_dir)
      FileUtils.mkdir_p(checksum_dir)
      FileUtils.mkdir_p(sources_dir)
    end

    def cache_dir : Path
      @workspace / "cache"
    end

    def checksum_dir : Path
      cache_dir / "checksums"
    end

    def sources_dir : Path
      @workspace / "sources"
    end

    def rootfs_dir : Path
      @workspace / "rootfs"
    end

    def sysroot_dir : Path
      @workspace / "sysroot"
    end

    def minirootfs_spec : PackageSpec
      version_tag = DEFAULT_MINIROOT
      file = "alpine-minirootfs-#{version_tag}-#{@architecture}.tar.gz"
      url = URI.parse("https://dl-cdn.alpinelinux.org/alpine/#{@branch}/releases/#{@architecture}/#{file}")
      checksum_url = URI.parse("#{url}.sha256") rescue nil
      PackageSpec.new("alpine-minirootfs", version_tag, url, nil, checksum_url)
    end

    def packages : Array(PackageSpec)
      llvm_url = URI.parse("https://github.com/llvm/llvm-project/releases/download/llvmorg-#{DEFAULT_LLVM_VER}")
      [
        PackageSpec.new("m4", DEFAULT_M4, URI.parse("https://ftp.gnu.org/gnu/m4/m4-#{DEFAULT_M4}.tar.xz")),
        PackageSpec.new("musl", DEFAULT_MUSL, URI.parse("https://musl.libc.org/releases/musl-#{DEFAULT_MUSL}.tar.gz")),
        PackageSpec.new("cmake", DEFAULT_CMAKE, URI.parse("https://github.com/Kitware/CMake/releases/download/v#{DEFAULT_CMAKE}/cmake-#{DEFAULT_CMAKE}.tar.gz")),
        PackageSpec.new("busybox", DEFAULT_BUSYBOX, URI.parse("https://busybox.net/downloads/busybox-#{DEFAULT_BUSYBOX}.tar.bz2")),
        PackageSpec.new("make", DEFAULT_GNU_MAKE, URI.parse("https://ftp.gnu.org/gnu/make/make-#{DEFAULT_GNU_MAKE}.tar.gz")),
        PackageSpec.new("zlib", DEFAULT_ZLIB, URI.parse("https://zlib.net/zlib-#{DEFAULT_ZLIB}.tar.gz")),
        PackageSpec.new("libressl", DEFAULT_LIBRESSL, URI.parse("https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-#{DEFAULT_LIBRESSL}.tar.gz")),
        PackageSpec.new("libatomic_ops", "7.8.2", URI.parse("https://github.com/ivmai/libatomic_ops/releases/download/v7.8.2/libatomic_ops-7.8.2.tar.gz")),
        PackageSpec.new("compiler-rt", DEFAULT_LLVM_VER, URI.parse("#{llvm_url}/compiler-rt-#{DEFAULT_LLVM_VER}.src.tar.xz")),
        PackageSpec.new("clang", DEFAULT_LLVM_VER, URI.parse("#{llvm_url}/clang-#{DEFAULT_LLVM_VER}.src.tar.xz")),
        PackageSpec.new("lld", DEFAULT_LLVM_VER, URI.parse("#{llvm_url}/lld-#{DEFAULT_LLVM_VER}.src.tar.xz")),
        PackageSpec.new("bdwgc", DEFAULT_BDWGC, URI.parse("https://github.com/ivmai/bdwgc/releases/download/v#{DEFAULT_BDWGC}/gc-#{DEFAULT_BDWGC}.tar.gz")),
        PackageSpec.new("pcre2", DEFAULT_PCRE2, URI.parse("https://github.com/PhilipHazel/pcre2/releases/download/pcre2-#{DEFAULT_PCRE2}/pcre2-#{DEFAULT_PCRE2}.tar.gz")),
        PackageSpec.new("gmp", DEFAULT_GMP, URI.parse("https://gmplib.org/download/gmp/gmp-#{DEFAULT_GMP}.tar.xz")),
        PackageSpec.new("libiconv", DEFAULT_LIBICONV, URI.parse("https://ftp.gnu.org/pub/gnu/libiconv/libiconv-#{DEFAULT_LIBICONV}.tar.gz")),
        PackageSpec.new("libxml2", DEFAULT_LIBXML2, URI.parse("https://download.gnome.org/sources/libxml2/#{DEFAULT_LIBXML2.split('.')[0...-1].join(".")}/libxml2-#{DEFAULT_LIBXML2}.tar.xz")),
        PackageSpec.new("libyaml", DEFAULT_LIBYAML, URI.parse("https://pyyaml.org/download/libyaml/yaml-#{DEFAULT_LIBYAML}.tar.gz")),
        PackageSpec.new("libffi", DEFAULT_LIBFFI, URI.parse("https://github.com/libffi/libffi/releases/download/v#{DEFAULT_LIBFFI}/libffi-#{DEFAULT_LIBFFI}.tar.gz")),
      ]
    end

    def download_sources : Array(Path)
      packages.map { |pkg| download_and_verify(pkg) }
    end

    def download_and_verify(pkg : PackageSpec) : Path
      target = sources_dir / pkg.filename
      if File.exists?(target) && verify(pkg, target)
        Log.debug { "Using cached #{pkg.name} at #{target}" }
        return target
      end

      Log.info { "Downloading #{pkg.name} #{pkg.version} from #{pkg.url}" }
      File.open(target, "w") do |file|
        HTTP::Client.get(pkg.url) do |response|
          raise "Failed to download #{pkg.url} (#{response.status_code})" unless response.success?
          IO.copy(response.body_io, file)
        end
      end

      verify(pkg, target)
      target
    end

    def verify(pkg : PackageSpec, path : Path) : Bool
      expected = expected_sha256(pkg)
      actual = sha256(path)
      if expected && expected != actual
        raise "SHA256 mismatch for #{pkg.name}: expected #{expected}, got #{actual}"
      end

      crc = crc32(path)
      if cached_crc = cached_crc32(pkg)
        raise "CRC32 mismatch for #{pkg.name}: expected #{cached_crc}, got #{crc}" unless cached_crc == crc
      end

      write_checksum(pkg, actual, crc)
      true
    end

    def expected_sha256(pkg : PackageSpec) : String?
      pkg.sha256 || cached_sha256(pkg) || fetch_remote_checksum(pkg)
    end

    def cached_sha256(pkg : PackageSpec) : String?
      checksum_path = checksum_dir / "#{pkg.filename}.sha256"
      File.exists?(checksum_path) ? File.read(checksum_path).strip : nil
    end

    def cached_crc32(pkg : PackageSpec) : String?
      checksum_path = checksum_dir / "#{pkg.filename}.crc32"
      File.exists?(checksum_path) ? File.read(checksum_path).strip : nil
    end

    def fetch_remote_checksum(pkg : PackageSpec) : String?
      return nil unless uri = pkg.checksum_url
      HTTP::Client.get(uri) do |response|
        return normalize_checksum(response.body_io.gets_to_end) if response.success?
      end
      nil
    end

    private def normalize_checksum(body : String) : String
      body.strip.split(/\s+/).first
    end

    def sha256(path : Path) : String
      digest = Digest::SHA256.new
      File.open(path) do |file|
        IO.copy(file, digest)
      end
      digest.hexdigest
    end

    def crc32(path : Path) : String
      digest = Digest::CRC32.new
      File.open(path) do |file|
        IO.copy(file, digest)
      end
      digest.hexdigest
    end

    def write_checksum(pkg : PackageSpec, sha : String, crc : String) : Nil
      File.write(checksum_dir / "#{pkg.filename}.sha256", sha + "\n")
      File.write(checksum_dir / "#{pkg.filename}.crc32", crc + "\n")
    end

    def prepare_rootfs(minirootfs : PackageSpec = minirootfs_spec) : Path
      FileUtils.rm_rf(rootfs_dir)
      FileUtils.mkdir_p(rootfs_dir)

      tarball = download_and_verify(minirootfs)
      extract_tarball(tarball, rootfs_dir)
      FileUtils.mkdir_p(rootfs_dir / "workspace")
      FileUtils.mkdir_p(rootfs_dir / "sources")
      FileUtils.mkdir_p(rootfs_dir / "var/lib")
      populate_sources
      install_coordinator_source
      rootfs_dir
    end

    def populate_sources : Nil
      download_sources.each do |archive|
        destination = rootfs_dir / "sources" / File.basename(archive)
        FileUtils.mkdir_p(destination.parent)
        FileUtils.cp(archive, destination)
      end
    end

    def install_coordinator_source : Path
      coordinator_path = rootfs_dir / "usr/local/bin/sysroot-runner.cr"
      FileUtils.mkdir_p(coordinator_path.parent)
      File.write(coordinator_path, coordinator_source)
      coordinator_path
    end

    def coordinator_source : String
      <<-CR
        require "json"
        require "log"
        require "file_utils"
        require "process"

        Log.setup("*", Log::Severity::Info)

        struct BuildStep
          include JSON::Serializable
          property name : String
          property commands : Array(Array(String))
          property workdir : String
        end

        steps_file = "/var/lib/sysroot-build-plan.json"
        raise "Missing build plan \#{steps_file}" unless File.exists?(steps_file)

        steps = Array(BuildStep).from_json(File.read(steps_file))
        steps.each do |step|
          Log.info { "Building \#{step.name} in \#{step.workdir}" }
          step.commands.each do |argv|
            status = Process.run(argv[0], argv[1..], chdir: step.workdir)
            raise "Command failed (\#{status.exit_status}): \#{argv.join(" ")}" unless status.success?
          end
        end
        Log.info { "All sysroot components rebuilt" }
      CR
    end

    def build_plan : Array(BuildStep)
      sysroot_prefix = "/opt/sysroot"
      workdir = "/workspace"
      cpus = System.cpu_count || 1
      packages.map do |pkg|
        build_directory = pkg.build_directory || strip_archive_extension(pkg.filename)
        build_root = File.join(workdir, build_directory)

        commands = [] of Array(String)
        commands << ["tar", "xf", File.join("/sources", pkg.filename), "-C", workdir]

        configure_cmd = if pkg.name == "cmake"
                          ["./bootstrap", "--prefix=#{sysroot_prefix}"]
                        elsif pkg.name == "busybox"
                          ["make", "defconfig"]
                        else
                          ["./configure", "--prefix=#{sysroot_prefix}"] + pkg.configure_flags
                        end

        commands << configure_cmd
        commands << ["make", "-j#{cpus}"]
        commands << ["make", "install"]
        BuildStep.new(pkg, commands, build_root)
      end
    end

    def write_plan(plan : Array(BuildStep) = build_plan) : Path
      plan_path = rootfs_dir / "var/lib/sysroot-build-plan.json"
      FileUtils.mkdir_p(plan_path.parent)
      File.write(plan_path, plan.to_json)
      plan_path
    end

    def generate_chroot_tarball(output : Path) : Path
      prepare_rootfs
      write_plan
      FileUtils.mkdir_p(output.parent) if output.parent
      status = Process.run("tar", ["-czf", output.to_s, "-C", rootfs_dir.to_s, "."])
      raise "Failed to create chroot tarball: #{status.exit_status}" unless status.success?
      output
    end

    def rebuild_in_chroot
      coordinator = "/usr/local/bin/sysroot-runner"
      if File.exists?(rootfs_dir / coordinator)
        args = ["chroot", rootfs_dir.to_s, coordinator]
      else
        source = rootfs_dir / "usr/local/bin/sysroot-runner.cr"
        status = Process.run("chroot", [rootfs_dir.to_s, "crystal", "run", source.to_s])
        raise "Failed to run coordinator inside chroot" unless status.success?
        return
      end

      status = Process.run(args[0], args[1..])
      raise "Failed to rebuild packages in chroot" unless status.success?
    end

    private def strip_archive_extension(filename : String) : String
      archive_suffixes = %w[.tar.gz .tar.xz .tar.bz2 .tgz .tbz2 .zip .tar]
      archive_suffixes.each do |suffix|
        next unless filename.ends_with?(suffix)
        basename = filename.chomp(suffix)
        return basename.ends_with?(".src") ? basename.chomp(".src") : basename
      end
      simple = filename.rpartition('.').first
      simple.empty? ? filename : simple
    end

    private def extract_tarball(path : Path, destination : Path) : Nil
      FileUtils.mkdir_p(destination)
      status = Process.run("tar", ["-xf", path.to_s, "-C", destination.to_s])
      raise "Failed to extract #{path}" unless status.success?
    end
  end
end
