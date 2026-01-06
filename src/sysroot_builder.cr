require "compress/gzip"
require "digest/crc32"
require "digest/sha256"
require "file_utils"
require "http/client"
require "json"
require "log"
require "path"
require "uri"

module Bootstrap
  # SysrootBuilder prepares a chroot-able environment that can rebuild
  # a complete sysroot using source tarballs cached on the host. The default
  # seed uses Alpine’s minirootfs, but the seed rootfs, architecture, and
  # package set are all swappable once a self-hosted rootfs exists.
  #
  # Key expectations:
  # * No shell-based downloads: HTTP/Digest from Crystal stdlib only.
  # * aarch64-first defaults, but architecture/branch/version are configurable.
  # * Deterministic source handling: every tarball is cached locally with CRC32 +
  #   SHA256 bookkeeping for reuse and verification.
  # * Coordinator source is stored in the repository and copied into the chroot
  #   so it participates in formatting and specs.
  class SysrootBuilder
    DEFAULT_ARCH         = "aarch64"
    DEFAULT_BRANCH       = "edge"
    DEFAULT_BASE_VERSION = "edge"
    DEFAULT_LLVM_VER     = "18.1.7"
    DEFAULT_LIBRESSL     = "3.8.2"
    DEFAULT_BUSYBOX      = "1.36.1"
    DEFAULT_MUSL         = "1.2.5"
    DEFAULT_CMAKE        = "3.29.6"
    DEFAULT_M4           = "1.4.19"
    DEFAULT_GNU_MAKE     = "4.4.1"
    DEFAULT_ZLIB         = "1.3.1"
    DEFAULT_PCRE2        = "10.44"
    DEFAULT_GMP          = "6.3.0"
    DEFAULT_LIBICONV     = "1.17"
    DEFAULT_LIBXML2      = "2.12.7"
    DEFAULT_LIBYAML      = "0.2.5"
    DEFAULT_LIBFFI       = "3.4.6"
    DEFAULT_BDWGC        = "8.2.6"

    record PackageSpec,
      name : String,
      version : String,
      url : URI,
      sha256 : String? = nil,
      checksum_url : URI? = nil,
      configure_flags : Array(String) = [] of String,
      build_directory : String? = nil,
      strategy : String = "autotools",
      patches : Array(String) = [] of String do
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
    getter base_version : String

    def initialize(@workspace : Path = Path["data/sysroot"],
                   @architecture : String = DEFAULT_ARCH,
                   @branch : String = DEFAULT_BRANCH,
                   @base_version : String = DEFAULT_BASE_VERSION)
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

    # Build a PackageSpec pointing at the base rootfs tarball for the configured
    # architecture/branch/version. The checksum URL is derived from the upstream
    # naming convention when available.
    def base_rootfs_spec : PackageSpec
      version_tag = @base_version
      file = "alpine-minirootfs-#{version_tag}-#{@architecture}.tar.gz"
      url = URI.parse("https://dl-cdn.alpinelinux.org/alpine/#{@branch}/releases/#{@architecture}/#{file}")
      checksum_url = URI.parse("#{url}.sha256") rescue nil
      PackageSpec.new("bootstrap-rootfs", version_tag, url, nil, checksum_url)
    end

    # Declarative list of upstream sources that should populate the sysroot.
    # Each PackageSpec can carry optional configure flags or a custom build
    # directory name when upstream archives use non-standard layouts.
    def packages : Array(PackageSpec)
      llvm_url = URI.parse("https://github.com/llvm/llvm-project/releases/download/llvmorg-#{DEFAULT_LLVM_VER}")
      [
        PackageSpec.new("m4", DEFAULT_M4, URI.parse("https://ftp.gnu.org/gnu/m4/m4-#{DEFAULT_M4}.tar.xz")),
        PackageSpec.new("musl", DEFAULT_MUSL, URI.parse("https://musl.libc.org/releases/musl-#{DEFAULT_MUSL}.tar.gz")),
        PackageSpec.new("cmake", DEFAULT_CMAKE, URI.parse("https://github.com/Kitware/CMake/releases/download/v#{DEFAULT_CMAKE}/cmake-#{DEFAULT_CMAKE}.tar.gz"), strategy: "cmake"),
        PackageSpec.new("busybox", DEFAULT_BUSYBOX, URI.parse("https://busybox.net/downloads/busybox-#{DEFAULT_BUSYBOX}.tar.bz2"), strategy: "busybox"),
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

    # Download a package tarball (if missing) into the source cache and verify
    # its checksum before returning the cached path.
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

    # Validate the downloaded archive against SHA256 and CRC32. If an expected
    # checksum is provided or cached, mismatches raise immediately.
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

    # Discover an expected SHA256 for a package from an explicit value, cached
    # value, or a remote checksum file.
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

    # Fetch a checksum body from a remote sidecar (usually .sha256) and return
    # the first whitespace-delimited token.
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
        buffer = Bytes.new(4096)
        while (read = file.read(buffer)) > 0
          digest.update(buffer[0, read])
        end
      end
      digest.final.hexstring
    end

    def crc32(path : Path) : String
      digest = Digest::CRC32.new
      File.open(path) do |file|
        buffer = Bytes.new(4096)
        while (read = file.read(buffer)) > 0
          digest.update(buffer[0, read])
        end
      end
      digest.final.hexstring
    end

    def write_checksum(pkg : PackageSpec, sha : String, crc : String) : Nil
      File.write(checksum_dir / "#{pkg.filename}.sha256", sha + "\n")
      File.write(checksum_dir / "#{pkg.filename}.crc32", crc + "\n")
    end

    # Assemble a chroot-able rootfs:
    # * extracts the seed rootfs
    # * creates workspace/var/lib directories (/workspace holds extracted sources,
    #   /var/lib holds the build plan)
    # * stages the coordinator entrypoints
    # Returns the rootfs path on success.
    def prepare_rootfs(base_rootfs : PackageSpec = base_rootfs_spec) : Path
      FileUtils.rm_rf(rootfs_dir)
      FileUtils.mkdir_p(rootfs_dir)

      tarball = download_and_verify(base_rootfs)
      extract_tarball(tarball, rootfs_dir)
      FileUtils.mkdir_p(rootfs_dir / "workspace")
      FileUtils.mkdir_p(rootfs_dir / "var/lib")
      stage_sources
      install_coordinator_source
      rootfs_dir
    end

    # Extract downloaded sources into /workspace inside the rootfs for offline builds.
    def stage_sources : Nil
      workspace_path = rootfs_dir / "workspace"
      download_sources.each do |archive|
        extract_tarball(archive, workspace_path)
      end
    end

    # Copy the coordinator source files into the chroot so they can be executed
    # with `crystal run` during a rebuild.
    def install_coordinator_source : Path
      coordinator_dir = rootfs_dir / "usr/local/bin"
      FileUtils.mkdir_p(coordinator_dir)
      coordinator_support_files.each do |source|
        FileUtils.cp(source, coordinator_dir / File.basename(source))
      end
      coordinator_dir / "sysroot_runner_main.cr"
    end

    # Primary coordinator entrypoint stored in-repo (and formatted/tested).
    def coordinator_source_path : Path
      Path.new(__DIR__).join("sysroot_runner_main.cr")
    end

    # All coordinator artifacts that should be staged into the chroot.
    def coordinator_support_files : Array(Path)
      [
        Path.new(__DIR__).join("sysroot_runner_main.cr"),
        Path.new(__DIR__).join("sysroot_runner_lib.cr"),
      ]
    end

    # Construct a build plan that:
    # * assumes sources are already extracted into /workspace
    # * runs a strategy-specific configure/bootstrap step
    # * builds and installs into /opt/sysroot
    # This plan is serialized for the coordinator to replay inside the chroot.
    def build_plan : Array(BuildStep)
      sysroot_prefix = "/opt/sysroot"
      workdir = "/workspace"
      cpus = (System.cpu_count || 1).to_i32
      packages.map do |pkg|
        build_directory = pkg.build_directory || strip_archive_extension(pkg.filename)
        build_root = File.join(workdir, build_directory)
        commands = build_commands_for(pkg, sysroot_prefix, cpus)
        BuildStep.new(pkg, commands, build_root)
      end
    end

    # Persist the build plan JSON into the chroot at /var/lib/sysroot-build-plan.json.
    def write_plan(plan : Array(BuildStep) = build_plan) : Path
      plan_path = rootfs_dir / "var/lib/sysroot-build-plan.json"
      FileUtils.mkdir_p(plan_path.parent)
      File.write(plan_path, plan.to_json)
      plan_path
    end

    # Produce a gzipped tarball of the prepared rootfs so it can be consumed by
    # tooling that expects a chroot-able environment.
    def generate_chroot_tarball(output : Path) : Path
      prepare_rootfs
      write_plan
      FileUtils.mkdir_p(output.parent) if output.parent
      write_tar_gz(rootfs_dir, output)
      output
    end

    # Execute (or return) the chroot rebuild command. Dry-run returns argv for
    # testing; normal mode invokes `crystal run` on the coordinator inside the
    # chroot using Process.chroot.
    def rebuild_in_chroot(dry_run : Bool = false)
      coordinator = "/usr/local/bin/sysroot_runner_main.cr"
      unless File.exists?(rootfs_dir / coordinator)
        raise "Coordinator not installed at #{coordinator}"
      end

      args = ["crystal", "run", coordinator]
      return args if dry_run

      Process.chroot(rootfs_dir.to_s)
      Dir.cd("/")
      status = Process.run(args[0], args[1..])
      raise "Failed to rebuild packages in chroot (#{status.exit_code})" unless status.success?
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
      Extractor.new(path, destination).run
    end

    private def write_tar_gz(source : Path, output : Path) : Nil
      TarWriter.write_gz(source, output)
    end

    private def build_commands_for(pkg : PackageSpec, sysroot_prefix : String, cpus : Int32) : Array(Array(String))
      commands = [] of Array(String)
      pkg.patches.each do |patch|
        commands << ["patch", "-p1", "-i", patch]
      end

      case pkg.strategy
      when "cmake"
        commands << ["./bootstrap", "--prefix=#{sysroot_prefix}"]
        commands << ["make", "-j#{cpus}"]
        commands << ["make", "install"]
      when "busybox"
        commands << ["make", "defconfig"]
        commands << ["make", "-j#{cpus}"]
        commands << ["make", "CONFIG_PREFIX=#{sysroot_prefix}", "install"]
      else # autotools/default
        commands << ["./configure", "--prefix=#{sysroot_prefix}"] + pkg.configure_flags
        commands << ["make", "-j#{cpus}"]
        commands << ["make", "install"]
      end

      commands
    end

    # Minimal tar extractor/writer implemented in Crystal to avoid shelling out.
    private struct Extractor
      def initialize(@archive : Path, @destination : Path)
      end

      def run
        return if fallback_for_unhandled_compression?
        File.open(@archive) do |file|
          io = maybe_gzip(file)
          TarReader.new(io, @destination).extract_all
        end
      end

      private def maybe_gzip(io : IO) : IO
        if @archive.to_s.ends_with?(".gz")
          Compress::Gzip::Reader.new(io)
        else
          io
        end
      end

      private def fallback_for_unhandled_compression? : Bool
        if @archive.to_s.ends_with?(".tar.xz") || @archive.to_s.ends_with?(".tar.bz2")
          status = Process.run("tar", ["-xf", @archive.to_s, "-C", @destination.to_s])
          raise "Failed to extract #{@archive}" unless status.success?
          true
        else
          false
        end
      end
    end

    private struct TarReader
      HEADER_SIZE = 512

      def initialize(@io : IO, @destination : Path)
      end

      def extract_all
        loop do
          header = Bytes.new(HEADER_SIZE)
          bytes = @io.read_fully?(header)
          break unless bytes == HEADER_SIZE
          break if header.all? { |b| b == 0u8 }

          name = cstring(header[0, 100])
          size = octal_to_i(header[124, 12])
          typeflag = header[156].chr
          linkname = cstring(header[157, 100])

          if name.empty? || name == "./"
            skip_bytes(size)
            skip_padding(size)
            next
          end

          target = @destination / name
          case typeflag
          when "5" # directory
            FileUtils.mkdir_p(target)
          when "2" # symlink
            FileUtils.mkdir_p(target.parent)
            File.symlink(linkname, target)
          else # regular file
            FileUtils.mkdir_p(target.parent)
            write_file(target, size)
          end

          skip_padding(size)
        end
      end

      private def skip_bytes(size : Int64)
        @io.skip(size) if size > 0
      end

      private def skip_padding(size : Int64)
        remainder = size % HEADER_SIZE
        skip = remainder.zero? ? 0 : HEADER_SIZE - remainder
        @io.skip(skip) if skip > 0
      end

      private def write_file(path : Path, size : Int64)
        File.open(path, "w") do |target_io|
          bytes_left = size
          buffer = Bytes.new(8192)
          while bytes_left > 0
            to_read = Math.min(buffer.size, bytes_left.to_i)
            read = @io.read(buffer[0, to_read])
            raise "Unexpected EOF in tar" if read == 0
            target_io.write(buffer[0, read])
            bytes_left -= read
          end
        end
      end

      private def cstring(bytes : Bytes) : String
        String.new(bytes).split("\0", 2)[0].to_s
      end

      private def octal_to_i(bytes : Bytes) : Int64
        String.new(bytes).strip.to_i64(8)
      end
    end

    private struct TarWriter
      HEADER_SIZE = 512

      def self.write_gz(source : Path, output : Path)
        File.open(output, "w") do |file|
          Compress::Gzip::Writer.open(file) do |gzip|
            writer = new(gzip, source)
            writer.write_all
          end
        end
      end

      def initialize(@io : IO, @source : Path)
      end

      def write_all
        walk(@source) do |entry, stat|
          relative = Path.new(entry).relative_to(@source).to_s

          if stat.directory?
            write_header(relative, 0_i64, stat, '5')
          elsif stat.symlink?
            target = File.readlink(entry)
            write_header(relative, 0_i64, stat, '2', target)
          else
            write_header(relative, stat.size, stat, '0')
            File.open(entry) do |file|
              IO.copy(file, @io)
            end
            pad_file(stat.size)
          end
        end
        @io.write(Bytes.new(HEADER_SIZE * 2, 0))
      end

      private def walk(path : Path, &block : Path, File::Info ->)
        Dir.children(path).each do |child|
          entry = path / child
          stat = File.info(entry, follow_symlinks: false)
          yield entry, stat
          walk(entry, &block) if stat.directory?
        end
      end

      private def write_header(name : String, size : Int64, stat : File::Info, typeflag : Char, linkname : String = "")
        header = Bytes.new(HEADER_SIZE, 0)
        write_string(header, 0, 100, name)
        write_octal(header, 100, 8, stat.permissions.value)
        write_octal(header, 108, 8, 0) # uid
        write_octal(header, 116, 8, 0) # gid
        write_octal(header, 124, 12, size)
        write_octal(header, 136, 12, stat.modification_time.to_unix)
        header[156] = typeflag.ord.to_u8
        write_string(header, 157, 100, linkname)
        header[257, 6].copy_from("ustar\0".to_slice)
        header[263, 2].copy_from("00".to_slice)
        write_octal(header, 148, 8, checksum(header))
        @io.write(header)
      end

      private def write_string(buffer : Bytes, offset : Int32, length : Int32, value : String)
        slice = buffer[offset, length]
        slice.fill(0u8)
        str = value.byte_slice(0, length - 1)
        slice_part = slice[0, str.bytesize]
        slice_part.copy_from(str.to_slice)
      end

      private def write_octal(buffer : Bytes, offset : Int32, length : Int32, value : Int64)
        str = value.to_s(8)
        padded = str.rjust(length - 1, '0')
        slice = buffer[offset, length - 1]
        slice.copy_from(padded.to_slice)
        buffer[offset + length - 1] = 0u8
      end

      private def checksum(header : Bytes) : Int64
        temp = header.dup
        (148..155).each { |i| temp[i] = 32u8 }
        temp.sum(&.to_i64)
      end

      private def pad_file(size : Int64)
        remainder = size % HEADER_SIZE
        pad = remainder.zero? ? 0 : HEADER_SIZE - remainder
        @io.write(Bytes.new(pad, 0)) if pad > 0
      end
    end
  end
end
