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
    DEFAULT_ARCH          = "aarch64"
    DEFAULT_BRANCH        = "v3.23"
    DEFAULT_BASE_VERSION  = "3.23.2"
    DEFAULT_LLVM_VER      = "18.1.7"
    DEFAULT_LIBRESSL      = "3.8.2"
    DEFAULT_BUSYBOX       = "1.36.1"
    DEFAULT_MUSL          = "1.2.5"
    DEFAULT_CMAKE         = "3.29.6"
    DEFAULT_M4            = "1.4.19"
    DEFAULT_GNU_MAKE      = "4.4.1"
    DEFAULT_ZLIB          = "1.3.1"
    DEFAULT_PCRE2         = "10.44"
    DEFAULT_LIBATOMIC_OPS = "7.8.2"
    DEFAULT_GMP           = "6.3.0"
    DEFAULT_LIBICONV      = "1.17"
    DEFAULT_LIBXML2       = "2.12.7"
    DEFAULT_LIBYAML       = "0.2.5"
    DEFAULT_LIBFFI        = "3.4.6"
    DEFAULT_BDWGC         = "8.2.6"

    record PackageSpec,
      name : String,
      version : String,
      url : URI,
      sha256 : String? = nil,
      checksum_url : URI? = nil,
      configure_flags : Array(String) = [] of String,
      build_directory : String? = nil,
      strategy : String = "autotools",
      patches : Array(String) = [] of String,
      extra_urls : Array(URI) = [] of URI do
      def filename : String
        File.basename(url.path)
      end

      def all_urls : Array(URI)
        [url] + extra_urls
      end
    end

    struct BuildStep
      include JSON::Serializable

      getter name : String
      getter strategy : String
      getter workdir : String
      getter configure_flags : Array(String)
      getter patches : Array(String)
      getter sysroot_prefix : String

      def initialize(@name : String, @strategy : String, @workdir : String, @configure_flags : Array(String), @patches : Array(String), @sysroot_prefix : String)
      end
    end

    getter architecture : String
    getter branch : String
    getter workspace : Path
    getter base_version : String
    @resolved_base_version : String?

    def initialize(@workspace : Path = Path["data/sysroot"],
                   @architecture : String = DEFAULT_ARCH,
                   @branch : String = DEFAULT_BRANCH,
                   @base_version : String = DEFAULT_BASE_VERSION,
                   @use_system_tar_for_sources : Bool = false,
                   @use_system_tar_for_rootfs : Bool = false,
                   @preserve_ownership : Bool = false,
                   @owner_uid : Int32? = nil,
                   @owner_gid : Int32? = nil)
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
      version_tag = resolved_base_version
      file = "alpine-minirootfs-#{version_tag}-#{@architecture}.tar.gz"
      url = URI.parse("https://dl-cdn.alpinelinux.org/alpine/#{@branch}/releases/#{@architecture}/#{file}")
      checksum_url = URI.parse("#{url}.sha256") rescue nil
      PackageSpec.new("bootstrap-rootfs", version_tag, url, nil, checksum_url)
    end

    # Declarative list of upstream sources that should populate the sysroot.
    # Each PackageSpec can carry optional configure flags or a custom build
    # directory name when upstream archives use non-standard layouts.
    def packages : Array(PackageSpec)
      [
        PackageSpec.new("m4", DEFAULT_M4, URI.parse("https://ftp.gnu.org/gnu/m4/m4-#{DEFAULT_M4}.tar.gz")),
        PackageSpec.new("musl", DEFAULT_MUSL, URI.parse("https://musl.libc.org/releases/musl-#{DEFAULT_MUSL}.tar.gz")),
        PackageSpec.new("cmake", DEFAULT_CMAKE, URI.parse("https://github.com/Kitware/CMake/releases/download/v#{DEFAULT_CMAKE}/cmake-#{DEFAULT_CMAKE}.tar.gz"), strategy: "cmake"),
        PackageSpec.new("busybox", DEFAULT_BUSYBOX, URI.parse("https://github.com/mirror/busybox/archive/refs/tags/#{DEFAULT_BUSYBOX.tr(".", "_")}.tar.gz"), strategy: "busybox"),
        PackageSpec.new("make", DEFAULT_GNU_MAKE, URI.parse("https://ftp.gnu.org/gnu/make/make-#{DEFAULT_GNU_MAKE}.tar.gz")),
        PackageSpec.new("zlib", DEFAULT_ZLIB, URI.parse("https://zlib.net/zlib-#{DEFAULT_ZLIB}.tar.gz")),
        PackageSpec.new("libressl", DEFAULT_LIBRESSL, URI.parse("https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-#{DEFAULT_LIBRESSL}.tar.gz")),
        PackageSpec.new("libatomic_ops", DEFAULT_LIBATOMIC_OPS, URI.parse("https://github.com/ivmai/libatomic_ops/releases/download/v#{DEFAULT_LIBATOMIC_OPS}/libatomic_ops-#{DEFAULT_LIBATOMIC_OPS}.tar.gz")),
        PackageSpec.new("llvm-project", DEFAULT_LLVM_VER, URI.parse("https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-#{DEFAULT_LLVM_VER}.tar.gz"), strategy: "llvm"),
        PackageSpec.new("bdwgc", DEFAULT_BDWGC, URI.parse("https://github.com/ivmai/bdwgc/releases/download/v#{DEFAULT_BDWGC}/gc-#{DEFAULT_BDWGC}.tar.gz")),
        PackageSpec.new("pcre2", DEFAULT_PCRE2, URI.parse("https://github.com/PhilipHazel/pcre2/releases/download/pcre2-#{DEFAULT_PCRE2}/pcre2-#{DEFAULT_PCRE2}.tar.gz")),
        PackageSpec.new("gmp", DEFAULT_GMP, URI.parse("https://ftp.gnu.org/gnu/gmp/gmp-#{DEFAULT_GMP}.tar.gz")),
        PackageSpec.new("libiconv", DEFAULT_LIBICONV, URI.parse("https://ftp.gnu.org/pub/gnu/libiconv/libiconv-#{DEFAULT_LIBICONV}.tar.gz")),
        PackageSpec.new("libxml2", DEFAULT_LIBXML2, URI.parse("https://github.com/GNOME/libxml2/archive/refs/tags/v#{DEFAULT_LIBXML2}.tar.gz")),
        PackageSpec.new("libyaml", DEFAULT_LIBYAML, URI.parse("https://pyyaml.org/download/libyaml/yaml-#{DEFAULT_LIBYAML}.tar.gz")),
        PackageSpec.new("libffi", DEFAULT_LIBFFI, URI.parse("https://github.com/libffi/libffi/releases/download/v#{DEFAULT_LIBFFI}/libffi-#{DEFAULT_LIBFFI}.tar.gz")),
      ]
    end

    def download_sources : Array(Path)
      packages.flat_map { |pkg| download_all(pkg) }
    end

    # Download all archives for a package (main + extras), verify, and return paths.
    def download_all(pkg : PackageSpec) : Array(Path)
      pkg.all_urls.map_with_index do |uri, idx|
        checksum_uri = idx.zero? ? pkg.checksum_url : URI.parse("#{uri}.sha256") rescue nil
        logical = idx.zero? ? pkg : pkg_with_url(pkg, uri, checksum_uri)
        download_and_verify(logical)
      end
    end

    # Download a package tarball (if missing) into the source cache and verify
    # its checksum before returning the cached path.
    def download_and_verify(pkg : PackageSpec) : Path
      target = sources_dir / pkg.filename
      attempts = 3
      attempts.times do |idx|
        begin
          if File.exists?(target)
            if File.size(target) > 0 && verify(pkg, target)
              return target
            else
              File.delete(target)
            end
          end

          Log.info { "Downloading #{pkg.name} #{pkg.version} from #{pkg.url}" }
          download_with_redirects(pkg.url, target)
          raise "Empty download for #{pkg.name}" if File.size(target) == 0
          verify(pkg, target)
          return target
        rescue error
          File.delete(target) if File.exists?(target)
          raise error if idx == attempts - 1
          Log.warn { "Retrying #{pkg.name} after error: #{error.message}" }
          sleep 2.seconds
        end
      end
      target
    end

    private def pkg_with_url(pkg : PackageSpec, url : URI, checksum_url : URI?) : PackageSpec
      PackageSpec.new(pkg.name, pkg.version, url, pkg.sha256, checksum_url, pkg.configure_flags, pkg.build_directory, pkg.strategy, pkg.patches, [] of URI)
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
      body = fetch_string_with_redirects(uri)
      body ? normalize_checksum(body) : nil
    end

    private def normalize_checksum(body : String) : String
      body.strip.split(/\s+/).first
    end

    private def resolved_base_version : String
      @resolved_base_version ||= @base_version
    end

    private def fetch_string_with_redirects(uri : URI, limit : Int32 = 5) : String?
      buffer = IO::Memory.new
      success = false
      fetch_with_redirects(uri, limit) do |response|
        next unless response.success?
        IO.copy(response.body_io, buffer)
        success = true
      end
      return nil unless success
      buffer.to_s
    end

    private def download_with_redirects(uri : URI, target : Path, limit : Int32 = 5) : Nil
      File.open(target, "w") do |file|
        fetch_with_redirects(uri, limit) do |response|
          raise "Failed to download #{uri} (#{response.status_code})" unless response.success?
          IO.copy(response.body_io, file)
        end
      end
    end

    private def fetch_with_redirects(uri : URI, limit : Int32 = 5, &block : HTTP::Client::Response ->)
      current = uri
      attempts = 0
      loop do
        raise "Too many redirects for #{uri}" if attempts > limit
        attempts += 1
        HTTP::Client.get(current) do |response|
          if response.status_code.in?(300..399) && (location = response.headers["Location"]?)
            next_uri = URI.parse(location).absolute? ? URI.parse(location) : current.resolve(location)
            current = next_uri
            next
          end
          return yield response
        end
      end
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
    # Invoked by `generate_chroot_tarball` and can also be used directly in callers.
    def prepare_rootfs(base_rootfs : PackageSpec = base_rootfs_spec, include_sources : Bool = true) : Path
      Log.info { "Preparing rootfs at #{rootfs_dir} (include_sources=#{include_sources})" }
      FileUtils.rm_rf(rootfs_dir)
      FileUtils.mkdir_p(rootfs_dir)

      tarball = download_and_verify(base_rootfs)
      Log.info { "Extracting base rootfs from #{tarball}" }
      extract_tarball(tarball, rootfs_dir, force_system_tar: @use_system_tar_for_rootfs)
      FileUtils.mkdir_p(rootfs_dir / "workspace")
      FileUtils.mkdir_p(rootfs_dir / "var/lib")
      stage_sources if include_sources
      install_coordinator_source
      rootfs_dir
    end

    # Extract downloaded sources into /workspace inside the rootfs for offline builds.
    def stage_sources : Nil
      workspace_path = rootfs_dir / "workspace"
      download_sources.each do |archive|
        Log.info { "Extracting source archive #{archive} into #{workspace_path}" }
        extract_tarball(archive, workspace_path, force_system_tar: @use_system_tar_for_sources)
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
      packages.map do |pkg|
        build_directory = pkg.build_directory || strip_archive_extension(pkg.filename)
        build_root = File.join(workdir, build_directory)
        BuildStep.new(pkg.name, pkg.strategy, build_root, pkg.configure_flags, pkg.patches, sysroot_prefix)
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
    def generate_chroot(include_sources : Bool = true) : Path
      prepare_rootfs(include_sources: include_sources)
      write_plan
      rootfs_dir
    end

    def generate_chroot_tarball(output : Path? = nil, include_sources : Bool = true) : Path
      generate_chroot(include_sources: include_sources)
      output ||= rootfs_dir.parent / "sysroot.tar.gz"
      FileUtils.mkdir_p(output.parent) if output.parent
      write_tar_gz(rootfs_dir, output)
      chown_tarball_to_sudo_user(output)
      output
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

    private def extract_tarball(path : Path, destination : Path, force_system_tar : Bool = false) : Nil
      FileUtils.mkdir_p(destination)
      return run_system_tar_extract(path, destination) if force_system_tar
      Extractor.new(path, destination, @preserve_ownership, @owner_uid, @owner_gid).run
    end

    private def run_system_tar_extract(path : Path, destination : Path) : Nil
      args = ["-xf", path.to_s, "-C", destination.to_s]
      if @preserve_ownership
        args << "--same-owner"
        if @owner_uid
          args << "--owner=#{@owner_uid}"
        end
        if @owner_gid
          args << "--group=#{@owner_gid}"
        end
      end
      Log.info { "Running: tar #{args.join(" ")}" }
      status = Process.run("tar", args)
      raise "Failed to extract #{path}" unless status.success?
    end

    private def write_tar_gz(source : Path, output : Path) : Nil
      TarWriter.write_gz(source, output)
    rescue ex
      Log.warn { "Falling back to system tar due to: #{ex.message}" }
      File.delete?(output)
      Log.info { "Running: tar -czf #{output} -C #{source} ." }
      status = Process.run("tar", ["-czf", output.to_s, "-C", source.to_s, "."])
      raise "Failed to create tarball with system tar" unless status.success?
    end

    private def build_commands_for(pkg : PackageSpec, sysroot_prefix : String) : Array(Array(String))
      # The builder remains data-only: embed strategy metadata and let the runner
      # translate into concrete commands.
      Array(Array(String)).new
    end

    # Minimal tar extractor/writer implemented in Crystal to avoid shelling out.
    private struct Extractor
      def initialize(@archive : Path, @destination : Path, @preserve_ownership : Bool, @owner_uid : Int32?, @owner_gid : Int32?)
      end

      def run
        return if fallback_for_unhandled_compression?
        File.open(@archive) do |file|
          io = maybe_gzip(file)
          TarReader.new(io, @destination, @preserve_ownership, @owner_uid, @owner_gid).extract_all
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
          Log.info { "Running: tar -xf #{@archive} -C #{@destination}" }
          status = Process.run("tar", ["-xf", @archive.to_s, "-C", @destination.to_s])
          raise "Failed to extract #{@archive}" unless status.success?
          true
        else
          false
        end
      end
    end

    private struct TarReader
      # POSIX ustar header layout: offsets/lengths per POSIX.1-1988.
      # Reference: https://pubs.opengroup.org/onlinepubs/009695399/basedefs/tar.h.html
      HEADER_SIZE     = 512
      NAME_OFFSET     =   0
      NAME_LENGTH     = 100
      MODE_OFFSET     = 100
      MODE_LENGTH     =   8
      UID_OFFSET      = 108
      UID_LENGTH      =   8
      GID_OFFSET      = 116
      GID_LENGTH      =   8
      SIZE_OFFSET     = 124
      SIZE_LENGTH     =  12
      MTIME_OFFSET    = 136
      TYPEFLAG_OFFSET = 156
      LINKNAME_OFFSET = 157
      LINKNAME_LENGTH = 100
      PREFIX_OFFSET   = 345
      PREFIX_LENGTH   = 155

      TYPE_DIRECTORY = '5'
      TYPE_SYMLINK   = '2'
      TYPE_HARDLINK  = '1'
      TYPE_FILE      = '\u0000'

      def initialize(@io : IO, @destination : Path, @preserve_ownership : Bool, @owner_uid : Int32?, @owner_gid : Int32?)
      end

      def extract_all
        loop do
          header = Bytes.new(HEADER_SIZE)
          bytes = @io.read_fully?(header)
          break unless bytes == HEADER_SIZE
          break if header.all? { |b| b == 0u8 }

          name = cstring(header[NAME_OFFSET, NAME_LENGTH])
          prefix = cstring(header[PREFIX_OFFSET, PREFIX_LENGTH])
          name = "#{prefix}/#{name}" unless prefix.empty?
          header_uid = octal_to_i(header[UID_OFFSET, UID_LENGTH]).to_i
          header_gid = octal_to_i(header[GID_OFFSET, GID_LENGTH]).to_i
          size = octal_to_i(header[SIZE_OFFSET, SIZE_LENGTH])
          typeflag = header[TYPEFLAG_OFFSET].chr
          linkname = cstring(header[LINKNAME_OFFSET, LINKNAME_LENGTH])
          normalized_typeflag = typeflag == TYPE_FILE ? TYPE_FILE : typeflag
          normalized_typeflag = TYPE_SYMLINK if normalized_typeflag == TYPE_FILE && !linkname.empty?
          Log.debug { "Tar entry name=#{name} typeflag=#{typeflag.inspect} normalized=#{normalized_typeflag.inspect} linkname=#{linkname}" }

          # Skip metadata/pax headers or empty entries.
          if name.empty? || name == "./" || name.starts_with?("././@PaxHeader") || normalized_typeflag.in?({'g', 'x'})
            skip_bytes(size)
            skip_padding(size)
            next
          end

          target = safe_target_path(name)
          unless target
            Log.warn { "Skipping unsafe tar entry #{name}" }
            skip_bytes(size)
            skip_padding(size)
            next
          end

          if name.ends_with?("/")
            FileUtils.mkdir_p(target)
            apply_ownership(target, header_uid, header_gid)
            skip_padding(size)
            next
          end

          uid, gid = resolved_owner(header_uid, header_gid)
          case normalized_typeflag
          when TYPE_DIRECTORY # directory
            FileUtils.mkdir_p(target)
            File.chmod(target, header_mode(header))
            apply_ownership(target, uid, gid)
          when TYPE_SYMLINK # symlink
            FileUtils.mkdir_p(target.parent)
            Log.debug { "Creating symlink #{target} -> #{linkname}" }
            FileUtils.ln_sf(linkname, target)
          when TYPE_HARDLINK # hardlink
            FileUtils.mkdir_p(target.parent)
            link_target = safe_target_path(linkname)
            unless link_target
              Log.warn { "Skipping unsafe hardlink target #{linkname}" }
              skip_padding(size)
              next
            end
            Log.debug { "Creating hardlink #{target} -> #{link_target}" }
            File.link(link_target, target)
          else # regular file
            FileUtils.mkdir_p(target.parent)
            write_file(target, size, header_mode(header))
            apply_ownership(target, uid, gid)
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

      private def write_file(path : Path, size : Int64, mode : Int32)
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
        File.chmod(path, mode)
      end

      private def resolved_owner(header_uid : Int32, header_gid : Int32) : {Int32?, Int32?}
        return {nil, nil} unless @preserve_ownership
        {(@owner_uid || header_uid), (@owner_gid || header_gid)}
      end

      private def apply_ownership(path : Path, uid : Int32?, gid : Int32?)
        return unless uid || gid
        File.chown(path, uid || -1, gid || -1)
      rescue ex
        Log.warn { "Failed to apply ownership to #{path}: #{ex.message}" }
      end

      private def safe_target_path(name : String) : Path?
        return nil if name.starts_with?("/")
        clean = name
        while clean.starts_with?("./")
          clean = clean[2..] || ""
        end
        return nil if clean.empty?
        parts = clean.split('/')
        return nil if parts.any? { |part| part == ".." }
        @destination / clean
      end

      private def cstring(bytes : Bytes) : String
        String.new(bytes).split("\0", 2)[0].to_s
      end

      private def octal_to_i(bytes : Bytes) : Int64
        cleaned = String.new(bytes).tr("\0", "").strip.gsub(/[^0-7]/, "")
        cleaned.empty? ? 0_i64 : cleaned.to_i64(8)
      end

      private def header_mode(header : Bytes) : Int32
        mode = octal_to_i(header[MODE_OFFSET, MODE_LENGTH]).to_i
        mode.zero? ? 0o755 : mode
      end
    end

    private struct TarWriter
      # POSIX ustar header layout: offsets/lengths per POSIX.1-1988.
      # Reference: https://pubs.opengroup.org/onlinepubs/009695399/basedefs/tar.h.html
      HEADER_SIZE     = 512
      NAME_OFFSET     =   0
      NAME_LENGTH     = 100
      MODE_OFFSET     = 100
      MODE_LENGTH     =   8
      UID_OFFSET      = 108
      UID_LENGTH      =   8
      GID_OFFSET      = 116
      GID_LENGTH      =   8
      SIZE_OFFSET     = 124
      SIZE_LENGTH     =  12
      MTIME_OFFSET    = 136
      MTIME_LENGTH    =  12
      CHECKSUM_OFFSET = 148
      CHECKSUM_LENGTH =   8
      TYPEFLAG_OFFSET = 156
      LINKNAME_OFFSET = 157
      LINKNAME_LENGTH = 100
      MAGIC_OFFSET    = 257
      VERSION_OFFSET  = 263

      TYPE_DIRECTORY = '5'
      TYPE_SYMLINK   = '2'
      TYPE_FILE      = '0'
      TYPE_PAX       = 'x'

      class LongPathError < Exception; end

      def self.write_gz(source : Path, output : Path)
        assert_paths_fit(source)
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
            write_entry(relative, 0_i64, stat, TYPE_DIRECTORY)
          elsif stat.symlink?
            target = File.readlink(entry)
            write_entry(relative, 0_i64, stat, TYPE_SYMLINK, target)
          else
            write_entry(relative, stat.size, stat, TYPE_FILE)
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

      private def write_entry(name : String, size : Int64, stat : File::Info, typeflag : Char, linkname : String = "")
        if name.bytesize > 99 || linkname.bytesize > 99
          write_pax_header(name, linkname, stat)
        end
        header_name = header_name_for(name)
        header_linkname = header_name_for(linkname)
        write_header(header_name, size, stat, typeflag, header_linkname)
      end

      private def write_pax_header(name : String, linkname : String, stat : File::Info)
        entries = [] of String
        entries << pax_record("path", name) if name.bytesize > 99
        entries << pax_record("linkpath", linkname) if linkname.bytesize > 99
        payload = entries.join
        pax_name = pax_header_name(name)
        write_header(pax_name, payload.bytesize.to_i64, stat, TYPE_PAX)
        @io.write(payload.to_slice)
        pad_file(payload.bytesize.to_i64)
      end

      private def pax_record(key : String, value : String) : String
        record = "#{key}=#{value}\n"
        length = record.bytesize + 2
        loop do
          candidate = "#{length} #{record}"
          candidate_length = candidate.bytesize
          return candidate if candidate_length == length
          length = candidate_length
        end
      end

      private def pax_header_name(name : String) : String
        digest = Digest::CRC32.new
        digest.update(name)
        "PaxHeaders.0/#{digest.final.hexstring}"
      end

      private def header_name_for(name : String) : String
        return name if name.bytesize <= 99
        base = File.basename(name)
        return base if base.bytesize <= 99
        base.byte_slice(0, 99)
      end

      private def write_header(name : String, size : Int64, stat : File::Info, typeflag : Char, linkname : String = "")
        header = Bytes.new(HEADER_SIZE, 0)
        write_string(header, NAME_OFFSET, NAME_LENGTH, name)
        write_octal(header, MODE_OFFSET, MODE_LENGTH, stat.permissions.value)
        write_octal(header, UID_OFFSET, UID_LENGTH, 0) # uid
        write_octal(header, GID_OFFSET, GID_LENGTH, 0) # gid
        write_octal(header, SIZE_OFFSET, SIZE_LENGTH, size)
        write_octal(header, MTIME_OFFSET, MTIME_LENGTH, stat.modification_time.to_unix)
        header[TYPEFLAG_OFFSET] = typeflag.ord.to_u8
        write_string(header, LINKNAME_OFFSET, LINKNAME_LENGTH, linkname)
        header[MAGIC_OFFSET, 6].copy_from("ustar\0".to_slice)
        header[VERSION_OFFSET, 2].copy_from("00".to_slice)
        write_octal(header, CHECKSUM_OFFSET, CHECKSUM_LENGTH, checksum(header))
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
        (CHECKSUM_OFFSET...(CHECKSUM_OFFSET + CHECKSUM_LENGTH)).each { |i| temp[i] = 32u8 }
        temp.sum(&.to_i64)
      end

      private def pad_file(size : Int64)
        remainder = size % HEADER_SIZE
        pad = remainder.zero? ? 0 : HEADER_SIZE - remainder
        @io.write(Bytes.new(pad, 0)) if pad > 0
      end

      private def self.assert_paths_fit(source : Path)
        Dir.glob(["#{source}/**/*"], match: File::MatchOptions::DotFiles).each do |entry|
          rel = Path.new(entry).relative_to(source).to_s
          next if rel.bytesize <= 99
          header_name = File.basename(rel)
          next if header_name.bytesize <= 99
          raise LongPathError.new("Path too long for tar header even with PAX: #{rel}")
        end
      end
    end

    private def chown_tarball_to_sudo_user(path : Path)
      return unless sudo_user = ENV["SUDO_USER"]?
      begin
        if ids = sudo_user_ids(sudo_user)
          File.chown(path, ids[0], ids[1])
        else
          Log.warn { "Unable to resolve #{sudo_user} in /etc/passwd; skipping ownership change." }
        end
      rescue ex
        Log.warn { "Failed to chown #{path} to #{sudo_user}: #{ex.message}" }
      end
    end

    private def sudo_user_ids(user : String) : Tuple(Int32, Int32)?
      passwd_path = Path["/etc/passwd"]
      return nil unless File.exists?(passwd_path)

      File.each_line(passwd_path) do |line|
        next if line.empty? || line.starts_with?('#')
        parts = line.split(':', 7)
        next unless parts[0]? == user
        uid = parts[2]?
        gid = parts[3]?
        return {uid.to_i, gid.to_i} if uid && gid
        return nil
      end

      nil
    rescue ex
      Log.warn { "Failed to read #{passwd_path}: #{ex.message}" }
      nil
    end
  end
end
