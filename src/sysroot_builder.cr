require "digest/crc32"
require "digest/sha256"
require "file_utils"
require "http/client"
require "json"
require "log"
require "path"
require "process"
require "uri"
require "./build_plan"
require "./build_plan_utils"
require "./cli"
require "./process_runner"
require "./alpine_setup"
require "./sysroot_workspace"
require "./tarball"

module Bootstrap
  # SysrootBuilder prepares a chroot-able environment that can rebuild a
  # complete sysroot using source tarballs cached on the host. The default seed
  # uses Alpine’s minirootfs, but the seed rootfs, architecture, and package set
  # are all swappable once a self-hosted rootfs exists.
  #
  # Key expectations:
  # * No shell-based downloads: HTTP/Digest from Crystal stdlib only.
  # * aarch64-first defaults, but architecture/branch/version are configurable.
  # * Deterministic source handling: every tarball is cached locally with CRC32 +
  #   SHA256 bookkeeping for reuse and verification.
  # * bootstrap-qcow2 source is fetched as a tarball and staged into the inner
  #   rootfs workspace (/workspace inside the inner rootfs).
  #
  # Usage references:
  # * CLI entrypoints: `bq2 sysroot-builder`, `bq2 sysroot-plan-write`,
  #   and `bq2 sysroot-tarball` (see `self.run`, `help_entries`, and README).
  # * Workspace layout: host workspace is data/sysroot. The inner workspace is
  #   /workspace inside the inner rootfs and /workspace/rootfs/workspace from the
  #   outer rootfs.
  # * Build plan contract: `write_plan` persists the plan consumed by
  #   `SysrootRunner` under the inner rootfs var/lib directory.
  class SysrootBuilder < CLI
    {% if flag?(:x86_64) %}
      DEFAULT_ARCH = "x86_64"
    {% elsif flag?(:aarch64) %}
      DEFAULT_ARCH = "aarch64"
    {% else %}
      DEFAULT_ARCH = "aarch64"
    {% end %}
    DEFAULT_HOST_WORKDIR  = SysrootWorkspace::DEFAULT_HOST_WORKDIR
    DEFAULT_BRANCH        = "v3.23"
    DEFAULT_BASE_VERSION  = "3.23.2"
    DEFAULT_LLVM_VER      = "18.1.7"
    DEFAULT_LIBRESSL      = "3.8.2"
    DEFAULT_BUSYBOX       = "1.36.1"
    DEFAULT_MUSL          = "1.2.5"
    DEFAULT_CMAKE         = "3.29.6"
    DEFAULT_SHARDS        = "0.18.0"
    DEFAULT_NAMESERVER    = "8.8.8.8"
    DEFAULT_M4            = "1.4.19"
    DEFAULT_GNU_MAKE      = "4.4.1"
    DEFAULT_ZLIB          = "1.3.1"
    DEFAULT_LINUX         = "6.12.38"
    DEFAULT_PCRE2         = "10.44"
    DEFAULT_LIBATOMIC_OPS = "7.8.2"
    DEFAULT_GMP           = "6.3.0"
    DEFAULT_LIBICONV      = "1.17"
    DEFAULT_LIBXML2       = "2.12.7"
    DEFAULT_LIBYAML       = "0.2.5"
    DEFAULT_LIBFFI        = "3.4.6"
    DEFAULT_BDWGC         = "8.2.6"
    # Source: https://www.sqlite.org/2024/sqlite-autoconf-3460000.tar.gz (SQLite 3.46.0).
    DEFAULT_SQLITE  = "3460000"
    DEFAULT_FOSSIL  = "2.25"
    DEFAULT_GIT     = "2.45.2"
    DEFAULT_CRYSTAL = "1.18.2"
    # Cache directory name for prefetched shards dependencies.
    SHARDS_CACHE_DIR = ".shards-cache"
    # Source: https://curl.se/ca/cacert.pem (Mozilla CA certificate bundle).
    CA_BUNDLE_PEM = {{ read_file("#{__DIR__}/../data/ca-bundle/ca-certificates.crt") }}

    record PackageSpec,
      name : String,
      version : String,
      url : URI,
      sha256 : String? = nil,
      checksum_url : URI? = nil,
      phases : Array(String)? = nil,
      configure_flags : Array(String) = [] of String,
      build_directory : String? = nil,
      # Optional out-of-tree build directory template. Supports %{phase} and %{name}.
      build_dir : String? = nil,
      strategy : String = "autotools",
      patches : Array(String) = [] of String,
      extra_urls : Array(URI) = [] of URI do
      # Prefer a filename that includes the package name for clarity.
      def filename : String
        filename_for(url)
      end

      # Return the preferred filename for an arbitrary *uri*.
      def filename_for(uri : URI) : String
        basename = File.basename(uri.path)
        basename.includes?(name) ? basename : "#{name}-#{basename}"
      end

      # Return the canonical URL list: primary URL plus any extras.
      def all_urls : Array(URI)
        [url] + extra_urls
      end
    end

    getter architecture : String
    getter branch : String
    getter host_workdir : Path
    getter workspace : SysrootWorkspace
    getter cache_dir : Path
    getter checksum_dir : Path
    getter sources_dir : Path
    getter outer_rootfs_dir : Path
    getter inner_rootfs_dir : Path
    getter inner_rootfs_workspace_dir : Path
    getter sysroot_dir : Path
    getter base_version : String
    @resolved_base_version : String?

    record PhaseSpec,
      name : String,
      description : String,
      workspace : String,
      environment : String,
      install_prefix : String,
      destdir : String? = nil,
      env : Hash(String, String) = {} of String => String,
      package_allowlist : Array(String)? = nil,
      pre_steps : Array(BuildStep) = [] of BuildStep,
      extra_steps : Array(BuildStep) = [] of BuildStep,
      env_overrides : Hash(String, Hash(String, String)) = {} of String => Hash(String, String),
      configure_overrides : Hash(String, Array(String)) = {} of String => Array(String),
      patch_overrides : Hash(String, Array(String)) = {} of String => Array(String)

    # Create a sysroot builder rooted at the host workdir directory.
    def initialize(@architecture : String = DEFAULT_ARCH,
                   @branch : String = DEFAULT_BRANCH,
                   @base_version : String = DEFAULT_BASE_VERSION,
                   @base_rootfs_path : Path? = nil,
                   @use_system_tar_for_sources : Bool = false,
                   @use_system_tar_for_rootfs : Bool = false,
                   @preserve_ownership_for_sources : Bool = false,
                   @preserve_ownership_for_rootfs : Bool = false,
                   @owner_uid : Int32? = nil,
                   @owner_gid : Int32? = nil)
      @host_workdir = DEFAULT_HOST_WORKDIR
      @cache_dir = @host_workdir / "cache"
      @checksum_dir = @cache_dir / "checksums"
      @sources_dir = @host_workdir / "sources"
      @workspace = SysrootWorkspace.from_host_workdir(@host_workdir)
      @outer_rootfs_dir = @workspace.outer_rootfs_path
      @inner_rootfs_dir = @workspace.inner_rootfs_path
      @inner_rootfs_workspace_dir = @workspace.inner_workspace_path
      @sysroot_dir = @host_workdir / "sysroot"

      FileUtils.mkdir_p(@cache_dir)
      FileUtils.mkdir_p(@checksum_dir)
      FileUtils.mkdir_p(@sources_dir)
    end

    # Return the expected archive paths for all configured packages.
    def expected_source_archives : Array(Path)
      packages.flat_map do |pkg|
        pkg.all_urls.map { |uri| sources_dir / pkg.filename_for(uri) }
      end
    end

    # Return the expected archive paths that are missing from the source cache.
    def missing_source_archives : Array(Path)
      expected_source_archives.reject do |path|
        File.exists?(path) && File.size(path) > 0
      end
    end

    # Returns true when the workspace contains a prepared rootfs with a
    # serialized build plan. Iteration state is created by `SysrootRunner` and
    # is not part of a clean sysroot build output.
    def rootfs_ready? : Bool
      SysrootBuildState.new(workspace: @workspace).plan_exists?
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
      bootstrap_repo_dir = "#{SysrootWorkspace::INNER_WORKSPACE_PATH_IN_OUTER}/bootstrap-qcow2-#{bootstrap_source_version}"
      sysroot_triple = sysroot_target_triple
      [
        PackageSpec.new("m4", DEFAULT_M4, URI.parse("https://ftp.gnu.org/gnu/m4/m4-#{DEFAULT_M4}.tar.gz"), phases: ["sysroot-from-alpine", "system-from-sysroot"]),
        PackageSpec.new("musl", DEFAULT_MUSL, URI.parse("https://musl.libc.org/releases/musl-#{DEFAULT_MUSL}.tar.gz"), phases: ["sysroot-from-alpine", "rootfs-from-sysroot"]),
        PackageSpec.new(
          "busybox",
          DEFAULT_BUSYBOX,
          URI.parse("https://github.com/mirror/busybox/archive/refs/tags/#{DEFAULT_BUSYBOX.tr(".", "_")}.tar.gz"),
          strategy: "busybox",
          patches: ["#{bootstrap_repo_dir}/patches/busybox-#{DEFAULT_BUSYBOX.tr(".", "_")}/tc-disable-cbq-when-missing-headers.patch"],
          phases: ["sysroot-from-alpine", "rootfs-from-sysroot"],
        ),
        PackageSpec.new("make", DEFAULT_GNU_MAKE, URI.parse("https://ftp.gnu.org/gnu/make/make-#{DEFAULT_GNU_MAKE}.tar.gz"), phases: ["sysroot-from-alpine", "system-from-sysroot"]),
        PackageSpec.new("zlib", DEFAULT_ZLIB, URI.parse("https://zlib.net/zlib-#{DEFAULT_ZLIB}.tar.gz"), phases: ["sysroot-from-alpine", "system-from-sysroot"], configure_flags: ["--shared"]),
        PackageSpec.new(
          "linux-headers",
          DEFAULT_LINUX,
          URI.parse("https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-#{DEFAULT_LINUX}.tar.gz"),
          strategy: "linux-headers",
          build_directory: "linux-#{DEFAULT_LINUX}",
          configure_flags: [
            "ARCH=#{kernel_headers_arch}",
            "LLVM=1",
            "HOSTCC=clang",
            "HOSTCXX=clang++",
          ],
          phases: ["sysroot-from-alpine", "rootfs-from-sysroot", "system-from-sysroot"],
        ),
        PackageSpec.new(
          "libressl",
          DEFAULT_LIBRESSL,
          URI.parse("https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-#{DEFAULT_LIBRESSL}.tar.gz"),
          phases: ["sysroot-from-alpine", "system-from-sysroot"],
          configure_flags: ["--enable-shared", "--disable-static"],
        ),
        PackageSpec.new(
          "cmake",
          DEFAULT_CMAKE,
          URI.parse("https://github.com/Kitware/CMake/releases/download/v#{DEFAULT_CMAKE}/cmake-#{DEFAULT_CMAKE}.tar.gz"),
          strategy: "cmake",
          build_dir: "cmake-#{DEFAULT_CMAKE}-build-%{phase}",
          configure_flags: [
            "-DCMake_HAVE_CXX_MAKE_UNIQUE=ON",
            "-DCMake_HAVE_CXX_UNIQUE_PTR=ON",
            "-DCMake_HAVE_CXX_FILESYSTEM=ON",
            "-DBUILD_DOCS=OFF",
            "-DCMAKE_ENABLE_BASH_COMPLETION=OFF",
            "-DCMAKE_DOC_DIR=",
            "-DCMAKE_MAN_DIR=",
            "-DSPHINX_MAN=OFF",
            "-DSPHINX_HTML=OFF",
            "-DBUILD_CursesDialog=OFF",
            "-DOPENSSL_ROOT_DIR=/opt/sysroot",
            "-DOPENSSL_INCLUDE_DIR=/opt/sysroot/include",
            "-DOPENSSL_SSL_LIBRARY=/opt/sysroot/lib/libssl.so",
            "-DOPENSSL_CRYPTO_LIBRARY=/opt/sysroot/lib/libcrypto.so",
          ],
          patches: ["#{bootstrap_repo_dir}/patches/cmake-#{DEFAULT_CMAKE}/cmcppdap-include-cstdint.patch"],
          phases: ["sysroot-from-alpine", "system-from-sysroot"],
        ),
        PackageSpec.new(
          "libatomic_ops",
          DEFAULT_LIBATOMIC_OPS,
          URI.parse("https://github.com/ivmai/libatomic_ops/releases/download/v#{DEFAULT_LIBATOMIC_OPS}/libatomic_ops-#{DEFAULT_LIBATOMIC_OPS}.tar.gz"),
          phases: ["sysroot-from-alpine", "system-from-sysroot"],
          configure_flags: ["--enable-shared", "--disable-static"],
        ),
        PackageSpec.new(
          "llvm-project",
          DEFAULT_LLVM_VER,
          URI.parse("https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-#{DEFAULT_LLVM_VER}.tar.gz"),
          strategy: "cmake-project",
          configure_flags: llvm_configure_flags(sysroot_triple),
          patches: [
            "#{bootstrap_repo_dir}/patches/llvm-project-llvmorg-#{DEFAULT_LLVM_VER}/smallvector-include-cstdint.patch",
            "#{bootstrap_repo_dir}/patches/llvm-project-llvmorg-#{DEFAULT_LLVM_VER}/cmake-guard-cxx-compiler-id.patch",
            "#{bootstrap_repo_dir}/patches/llvm-project-llvmorg-#{DEFAULT_LLVM_VER}/disable-python-required.patch",
            "#{bootstrap_repo_dir}/patches/llvm-project-llvmorg-#{DEFAULT_LLVM_VER}/flow-sensitive-html-logger-prebuilt.patch",
            "#{bootstrap_repo_dir}/patches/llvm-project-llvmorg-#{DEFAULT_LLVM_VER}/runtimes-python-optional.patch",
            "#{bootstrap_repo_dir}/patches/llvm-project-llvmorg-#{DEFAULT_LLVM_VER}/runtimes-propagate-python-option.patch",
          ],
          phases: ["sysroot-from-alpine", "system-from-sysroot"],
        ),
        PackageSpec.new(
          "bdwgc",
          DEFAULT_BDWGC,
          URI.parse("https://github.com/ivmai/bdwgc/releases/download/v#{DEFAULT_BDWGC}/gc-#{DEFAULT_BDWGC}.tar.gz"),
          build_directory: "gc-#{DEFAULT_BDWGC}",
          phases: ["sysroot-from-alpine", "system-from-sysroot"],
          patches: ["#{bootstrap_repo_dir}/patches/bdwgc-#{DEFAULT_BDWGC}/disable-libcord.patch"],
          configure_flags: ["--enable-shared", "--disable-static"],
        ),
        PackageSpec.new(
          "pcre2",
          DEFAULT_PCRE2,
          URI.parse("https://github.com/PhilipHazel/pcre2/releases/download/pcre2-#{DEFAULT_PCRE2}/pcre2-#{DEFAULT_PCRE2}.tar.gz"),
          phases: ["sysroot-from-alpine", "system-from-sysroot"],
          configure_flags: ["--enable-shared", "--disable-static"],
        ),
        PackageSpec.new(
          "gmp",
          DEFAULT_GMP,
          URI.parse("https://ftp.gnu.org/gnu/gmp/gmp-#{DEFAULT_GMP}.tar.gz"),
          phases: ["sysroot-from-alpine", "system-from-sysroot"],
          configure_flags: ["--enable-shared", "--disable-static"],
        ),
        PackageSpec.new(
          "libiconv",
          DEFAULT_LIBICONV,
          URI.parse("https://ftp.gnu.org/pub/gnu/libiconv/libiconv-#{DEFAULT_LIBICONV}.tar.gz"),
          phases: ["sysroot-from-alpine", "system-from-sysroot"],
          configure_flags: ["--enable-shared", "--disable-static", "--disable-nls"],
        ),
        PackageSpec.new(
          "libxml2",
          DEFAULT_LIBXML2,
          URI.parse("https://github.com/GNOME/libxml2/archive/refs/tags/v#{DEFAULT_LIBXML2}.tar.gz"),
          build_directory: "libxml2-#{DEFAULT_LIBXML2}",
          configure_flags: [
            "-DBUILD_SHARED_LIBS=ON",
            "-DBUILD_STATIC=OFF",
            "-DLIBXML2_WITH_PYTHON=OFF",
            "-DLIBXML2_WITH_TESTS=OFF",
            "-DLIBXML2_WITH_LZMA=OFF",
          ],
          phases: ["sysroot-from-alpine", "system-from-sysroot"],
        ),
        PackageSpec.new(
          "libyaml",
          DEFAULT_LIBYAML,
          URI.parse("https://pyyaml.org/download/libyaml/yaml-#{DEFAULT_LIBYAML}.tar.gz"),
          build_directory: "yaml-#{DEFAULT_LIBYAML}",
          phases: ["sysroot-from-alpine", "system-from-sysroot"],
          configure_flags: ["--enable-shared", "--disable-static"],
        ),
        PackageSpec.new(
          "libffi",
          DEFAULT_LIBFFI,
          URI.parse("https://github.com/libffi/libffi/releases/download/v#{DEFAULT_LIBFFI}/libffi-#{DEFAULT_LIBFFI}.tar.gz"),
          phases: ["sysroot-from-alpine", "system-from-sysroot"],
          configure_flags: ["--enable-shared", "--disable-static"],
        ),
        PackageSpec.new(
          "crystal",
          DEFAULT_CRYSTAL,
          URI.parse("https://github.com/crystal-lang/crystal/archive/refs/tags/#{DEFAULT_CRYSTAL}.tar.gz"),
          strategy: "crystal-compiler",
          patches: ["#{bootstrap_repo_dir}/patches/crystal-#{DEFAULT_CRYSTAL}/use-libcxx.patch"],
          phases: ["sysroot-from-alpine", "system-from-sysroot"],
        ),
        PackageSpec.new(
          "shards",
          DEFAULT_SHARDS,
          URI.parse("https://github.com/crystal-lang/shards/archive/refs/tags/v#{DEFAULT_SHARDS}.tar.gz"),
          strategy: "crystal-build",
          configure_flags: ["-o", "bin/shards", "src/shards.cr"],
          build_directory: "shards-#{DEFAULT_SHARDS}",
          phases: ["sysroot-from-alpine", "system-from-sysroot"],
        ),
        PackageSpec.new(
          "bootstrap-qcow2",
          bootstrap_source_version,
          URI.parse("https://github.com/embedconsult/bootstrap-qcow2/archive/refs/tags/#{bootstrap_source_version}.tar.gz"),
          strategy: "crystal",
          phases: ["system-from-sysroot"],
        ),
        PackageSpec.new(
          "git",
          DEFAULT_GIT,
          URI.parse("https://www.kernel.org/pub/software/scm/git/git-#{DEFAULT_GIT}.tar.gz"),
          phases: ["tools-from-system"],
        ),
        PackageSpec.new(
          "sqlite",
          DEFAULT_SQLITE,
          URI.parse("https://www.sqlite.org/2024/sqlite-autoconf-#{DEFAULT_SQLITE}.tar.gz"),
          phases: ["tools-from-system"],
          configure_flags: ["--enable-shared", "--disable-static"],
        ),
        PackageSpec.new(
          "fossil",
          DEFAULT_FOSSIL,
          URI.parse("https://www.fossil-scm.org/home/tarball/fossil-src-#{DEFAULT_FOSSIL}.tar.gz"),
          strategy: "makefile-classic",
          patches: ["#{bootstrap_repo_dir}/patches/fossil-#{DEFAULT_FOSSIL}/makefile-bq2.patch"],
          phases: ["tools-from-system"],
        ),
      ]
    end

    # Download all configured package sources and return their cached paths.
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

          Log.debug { "Downloading #{pkg.name} #{pkg.version} from #{pkg.url}" }
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

    # Clone a PackageSpec with a different URL and checksum URL.
    private def pkg_with_url(pkg : PackageSpec, url : URI, checksum_url : URI?) : PackageSpec
      PackageSpec.new(
        pkg.name,
        pkg.version,
        url,
        sha256: pkg.sha256,
        checksum_url: checksum_url,
        phases: pkg.phases,
        configure_flags: pkg.configure_flags,
        build_directory: pkg.build_directory,
        strategy: pkg.strategy,
        patches: pkg.patches,
        extra_urls: [] of URI,
      )
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

    # Read a cached SHA256 for the package, if present.
    def cached_sha256(pkg : PackageSpec) : String?
      checksum_path = checksum_dir / "#{pkg.filename}.sha256"
      File.exists?(checksum_path) ? File.read(checksum_path).strip : nil
    end

    # Read a cached CRC32 for the package, if present.
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

    # Normalize a checksum file to the first whitespace-delimited token.
    private def normalize_checksum(body : String) : String
      body.strip.split(/\s+/).first
    end

    # Return the base version after resolving the local override.
    private def resolved_base_version : String
      @resolved_base_version ||= @base_version
    end

    # Fetch a URL body as a string while honoring redirect limits.
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

    # Download a URL into a target path while honoring redirect limits.
    private def download_with_redirects(uri : URI, target : Path, limit : Int32 = 5) : Nil
      File.open(target, "w") do |file|
        fetch_with_redirects(uri, limit) do |response|
          raise "Failed to download #{uri} (#{response.status_code})" unless response.success?
          IO.copy(response.body_io, file)
        end
      end
    end

    # Perform HTTP GET requests while handling redirects up to *limit*.
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

    # Compute a SHA256 hex digest for a file path.
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

    # Compute a CRC32 hex digest for a file path.
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

    # Persist checksum entries for a package.
    def write_checksum(pkg : PackageSpec, sha : String, crc : String) : Nil
      File.write(checksum_dir / "#{pkg.filename}.sha256", sha + "\n")
      File.write(checksum_dir / "#{pkg.filename}.crc32", crc + "\n")
    end

    # Assemble a chroot-able rootfs:
    # * extracts the seed rootfs
    # * creates inner rootfs var/lib + workspace directories
    # * stages source archives (including bootstrap-qcow2) into /workspace/rootfs/workspace
    # Returns the rootfs path on success.
    # Invoked by `generate_chroot_tarball` and can also be used directly in callers.
    def prepare_rootfs(base_rootfs : PackageSpec = base_rootfs_spec, include_sources : Bool = true) : Path
      Log.info { "Preparing rootfs at #{outer_rootfs_dir} (include_sources=#{include_sources})" }
      populate_seed_rootfs(base_rootfs)
      stage_sources if include_sources
      outer_rootfs_dir
    end

    # Populate the seed rootfs tarball into the outer rootfs without clobbering
    # the plan/state marker directory.
    def populate_seed_rootfs(base_rootfs : PackageSpec = base_rootfs_spec) : Path
      prepare_workspace
      FileUtils.mkdir_p(outer_rootfs_dir)
      tarball = resolve_base_rootfs_tarball(base_rootfs)
      Log.debug { "Extracting base rootfs from #{tarball}" }
      guard_paths = [@workspace.marker_path, @workspace.var_lib_dir]
      Tarball.extract(
        tarball,
        outer_rootfs_dir,
        @preserve_ownership_for_rootfs,
        @owner_uid,
        @owner_gid,
        force_system_tar: @use_system_tar_for_rootfs,
        guard_paths: guard_paths,
      )
      AlpineSetup.write_resolv_conf(outer_rootfs_dir)
      outer_rootfs_dir
    end

    # Extract downloaded sources into the inner rootfs workspace for offline builds.
    def stage_sources : Nil
      workspace_path = inner_rootfs_workspace_dir
      stage_sources(skip_existing: false, workspace_path: workspace_path)
    end

    # Extract downloaded sources into the inner rootfs workspace for offline builds.
    #
    # When *skip_existing* is true, source archives are only extracted when the
    # expected build directory does not already exist.
    def stage_sources(skip_existing : Bool, workspace_path : Path = inner_rootfs_workspace_dir) : Nil
      shard_projects = [] of Path
      shards_cache = workspace_path / SHARDS_CACHE_DIR
      packages.each do |pkg|
        archives = download_all(pkg)
        archives.each_with_index do |archive, idx|
          build_directory =
            if idx == 0
              pkg.build_directory || strip_archive_extension(pkg.filename)
            else
              strip_archive_extension(File.basename(archive))
            end
          build_root = workspace_path / build_directory
          if skip_existing && Dir.exists?(build_root)
            Log.debug { "Skipping already-staged source directory #{build_root}" }
            next
          end
          Log.debug { "Extracting source archive #{archive} into #{workspace_path}" }
          Tarball.extract(archive, workspace_path, @preserve_ownership_for_sources, @owner_uid, @owner_gid, force_system_tar: @use_system_tar_for_sources)
          shard_projects << build_root if File.exists?(build_root / "shard.yml")
        end
      end
      prefetch_shards_dependencies(shard_projects, shards_cache) unless shard_projects.empty?
    end

    # Prefetch shards dependencies into a shared cache so later build phases
    # can run offline without network access.
    private def prefetch_shards_dependencies(projects : Array(Path), cache_dir : Path) : Nil
      shards_exe = Process.find_executable("shards")
      raise "shards executable not found (needed to prefetch shard dependencies)" unless shards_exe

      FileUtils.mkdir_p(cache_dir)
      env = {"SHARDS_CACHE_PATH" => cache_dir.to_s}
      projects.uniq.each do |project|
        shard_file = project / "shard.yml"
        next unless File.exists?(shard_file)
        Log.info { "Prefetching shards dependencies for #{project}" }
        Dir.cd(project) do
          result = ProcessRunner.run([shards_exe, "install"], env: env)
          unless result.status.success?
            raise "shards install failed in #{project} (exit=#{result.status.exit_code})"
          end
        end
      end
    end

    private def bootstrap_source_version : String
      ENV["BQ2_SOURCE_BRANCH"]? || Bootstrap::VERSION
    end

    # Return the expected rootfs tarball filename for the bootstrap source version.
    def rootfs_tarball_name : String
      "bq2-rootfs-#{bootstrap_source_version}.tar.gz"
    end

    # Resolve the base rootfs tarball, favoring a local override when provided.
    private def resolve_base_rootfs_tarball(base_rootfs : PackageSpec) : Path
      if @base_rootfs_path
        path = @base_rootfs_path.not_nil!
        raise "Base rootfs tarball not found at #{path}" unless File.exists?(path)
        return path
      end

      if (path = default_base_rootfs_path) && File.exists?(path)
        return path
      end

      download_and_verify(base_rootfs)
    end

    # Returns the default local rootfs tarball path when present.
    private def default_base_rootfs_path : Path?
      sources_dir / "bq2-rootfs-#{bootstrap_source_version}.tar.gz"
    end

    private def kernel_headers_arch : String
      case @architecture
      when "aarch64", "arm64"
        "arm64"
      when "x86_64", "amd64"
        "x86"
      else
        @architecture
      end
    end

    # Build the LLVM configure flags for the sysroot toolchain.
    private def llvm_configure_flags(sysroot_triple : String) : Array(String)
      llvm_targets = llvm_targets_to_build(@architecture)
      enabled_tools = %w[LLVM_AR LLVM_NM LLVM_RANLIB LLVM_STRIP LLVM_CONFIG LLVM_SHLIB]
      disabled_tools = %w[
        BUGPOINT
        BUGPOINT_PASSES
        DSYMUTIL
        DXIL_DIS
        GOLD
        LLC
        LLI
        LLVM_AS
        LLVM_AS_FUZZER
        LLVM_BCANALYZER
        LLVM_C_TEST
        LLVM_CAT
        LLVM_CFI_VERIFY
        LLVM_COV
        LLVM_CVTRES
        LLVM_CXXDUMP
        LLVM_CXXFILT
        LLVM_CXXMAP
        LLVM_DEBUGINFO_ANALYZER
        LLVM_DEBUGINFOD
        LLVM_DEBUGINFOD_FIND
        LLVM_DIFF
        LLVM_DIS
        LLVM_DIS_FUZZER
        LLVM_DLANG_DEMANGLE_FUZZER
        LLVM_DRIVER
        LLVM_DWARFDUMP
        LLVM_DWARFUTIL
        LLVM_DWP
        LLVM_EXEGESIS
        LLVM_EXTRACT
        LLVM_GSYMUTIL
        LLVM_IFS
        LLVM_ISEL_FUZZER
        LLVM_ITANIUM_DEMANGLE_FUZZER
        LLVM_JITLINK
        LLVM_JITLISTENER
        LLVM_LIBTOOL_DARWIN
        LLVM_LINK
        LLVM_LIPO
        LLVM_LTO
        LLVM_LTO2
        LLVM_MC
        LLVM_MC_ASSEMBLE_FUZZER
        LLVM_MC_DISASSEMBLE_FUZZER
        LLVM_MCA
        LLVM_MICROSOFT_DEMANGLE_FUZZER
        LLVM_ML
        LLVM_MODEXTRACT
        LLVM_MT
        LLVM_OBJCOPY
        LLVM_OBJDUMP
        LLVM_OPT_FUZZER
        LLVM_OPT_REPORT
        LLVM_PDBUTIL
        LLVM_PROFDATA
        LLVM_PROFGEN
        LLVM_RC
        LLVM_READOBJ
        LLVM_READTAPI
        LLVM_REDUCE
        LLVM_REMARKUTIL
        LLVM_RTDYLD
        LLVM_RUST_DEMANGLE_FUZZER
        LLVM_SIM
        LLVM_SIZE
        LLVM_SPECIAL_CASE_LIST_FUZZER
        LLVM_SPLIT
        LLVM_STRESS
        LLVM_STRINGS
        LLVM_SYMBOLIZER
        LLVM_TLI_CHECKER
        LLVM_UNDNAME
        LLVM_XRAY
        LLVM_YAML_NUMERIC_PARSER_FUZZER
        LLVM_YAML_PARSER_FUZZER
        LTO
        OBJ2YAML
        OPT
        OPT_VIEWER
        REMARKS_SHLIB
        SANCOV
        SANSTATS
        SPIRV_TOOLS
        VERIFY_USELISTORDER
        VFABI_DEMANGLE_FUZZER
        XCODE_TOOLCHAIN
        YAML2OBJ
      ]
      flags = [
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DLLVM_TARGETS_TO_BUILD=#{llvm_targets}",
        "-DLLVM_HOST_TRIPLE=#{sysroot_triple}",
        "-DLLVM_DEFAULT_TARGET_TRIPLE=#{sysroot_triple}",
        "-DLLVM_ENABLE_WARNINGS=OFF",
        "-DLLVM_ENABLE_PROJECTS=clang;lld;compiler-rt",
        "-DLLVM_ENABLE_RUNTIMES=libunwind;libcxxabi;libcxx",
        "-DLLVM_ENABLE_LIBCXX=ON",
        "-DLLVM_INCLUDE_TOOLS=ON",
        "-DLLVM_BUILD_TOOLS=ON",
        "-DLLVM_INCLUDE_UTILS=OFF",
        "-DLLVM_INSTALL_UTILS=OFF",
      ]
      flags.concat(llvm_tool_flags(disabled_tools, enabled: false))
      flags.concat(llvm_tool_flags(enabled_tools, enabled: true))
      flags.concat([
        "-DLLVM_INCLUDE_TESTS=OFF",
        "-DLLVM_INCLUDE_EXAMPLES=OFF",
        "-DLLVM_INCLUDE_BENCHMARKS=OFF",
        "-DLLVM_BUILD_DOCS=OFF",
        "-DLLVM_ENABLE_DOXYGEN=OFF",
        "-DLLVM_ENABLE_SPHINX=OFF",
        "-DLLVM_ENABLE_SHARED=ON",
        "-DLLVM_BUILD_LLVM_DYLIB=ON",
        "-DLLVM_LINK_LLVM_DYLIB=ON",
        "-DLLVM_INSTALL_CMAKE_DIR=",
        "-DCLANG_INSTALL_CMAKE_DIR=",
        "-DLLD_INSTALL_CMAKE_DIR=",
        "-DCLANG_BUILD_DOCS=OFF",
        "-DCLANG_ENABLE_STATIC_ANALYZER=OFF",
        "-DCLANG_ENABLE_ARCMT=OFF",
        "-DLLVM_ENABLE_TERMINFO=OFF",
        "-DLLVM_ENABLE_PYTHON=OFF",
        "-DLLVM_ENABLE_PIC=ON",
        "-DCOMPILER_RT_BUILD_BUILTINS=ON",
        "-DCOMPILER_RT_BUILD_CRT=ON",
        "-DCOMPILER_RT_INCLUDE_TESTS=OFF",
        "-DCOMPILER_RT_BUILD_SANITIZERS=OFF",
        "-DCOMPILER_RT_BUILD_XRAY=OFF",
        "-DCOMPILER_RT_BUILD_LIBFUZZER=OFF",
        "-DCOMPILER_RT_BUILD_PROFILE=OFF",
        "-DCOMPILER_RT_BUILD_MEMPROF=OFF",
        "-DLIBUNWIND_USE_COMPILER_RT=ON",
        "-DLIBUNWIND_ENABLE_SHARED=ON",
        "-DLIBUNWIND_ENABLE_STATIC=OFF",
        "-DLIBUNWIND_INCLUDE_TESTS=OFF",
        "-DLIBCXX_HAS_MUSL_LIBC=ON",
        "-DLIBCXX_USE_COMPILER_RT=ON",
        "-DLIBCXX_ENABLE_SHARED=ON",
        "-DLIBCXX_ENABLE_STATIC=OFF",
        "-DLIBCXX_ENABLE_BENCHMARKS=OFF",
        "-DLIBCXX_INCLUDE_TESTS=OFF",
        "-DLIBCXXABI_USE_COMPILER_RT=ON",
        "-DLIBCXXABI_USE_LLVM_UNWINDER=ON",
        "-DLIBCXXABI_ENABLE_SHARED=ON",
        "-DLIBCXXABI_ENABLE_STATIC=OFF",
        "-DLIBCXXABI_INCLUDE_TESTS=OFF",
      ])
      flags
    end

    # Select LLVM target names for the configured architecture.
    # Uses LLVM target identifiers (e.g. AArch64, X86).
    private def llvm_targets_to_build(architecture : String) : String
      case architecture
      when "aarch64", "arm64"
        "AArch64"
      when "x86_64", "amd64"
        "X86"
      else
        architecture.upcase
      end
    end

    # Format LLVM tool enable/disable flags from tool name lists.
    private def llvm_tool_flags(tools : Array(String), enabled : Bool) : Array(String)
      value = enabled ? "ON" : "OFF"
      tools.map { |tool| "-DLLVM_TOOL_#{tool}_BUILD=#{value}" }
    end

    # Define the multi-phase build in an LFS-inspired style:
    # 1. build a complete sysroot from sources using Alpine's seed environment
    # 2. validate the sysroot by using it as the toolchain when assembling a rootfs
    #
    # Phase environments:
    # - host-setup: runs on the host before entering any namespace.
    # - sysroot-from-alpine: runs in the Alpine seed rootfs (host tools).
    # - rootfs-from-sysroot: runs inside the workspace rootfs and seeds /etc plus /opt/sysroot.
    # - system-from-sysroot/tools-from-system/finalize-rootfs: run inside the workspace rootfs,
    #   prefer /usr/bin, and rely on musl's /etc/ld-musl-<arch>.path for runtime lookup.
    def phase_specs : Array(PhaseSpec)
      sysroot_prefix = "/opt/sysroot"
      inner_rootfs_path_in_outer = SysrootWorkspace::INNER_ROOTFS_PATH_IN_OUTER.to_s
      outer_sources_workspace_value = SysrootWorkspace::INNER_WORKSPACE_PATH_IN_OUTER.to_s
      bootstrap_repo_dir = "#{outer_sources_workspace_value}/bootstrap-qcow2-#{bootstrap_source_version}"
      rootfs_destdir = inner_rootfs_path_in_outer
      rootfs_tarball = "#{SysrootWorkspace::ROOTFS_WORKSPACE_PATH}/bq2-rootfs-#{bootstrap_source_version}.tar.gz"
      sysroot_triple = sysroot_target_triple
      sysroot_env = sysroot_phase_env(sysroot_prefix)
      rootfs_env = rootfs_phase_env(sysroot_prefix)
      os_release_content = rootfs_os_release_content
      profile_content = rootfs_profile_content
      resolv_conf_content = rootfs_resolv_conf_content
      hosts_content = rootfs_hosts_content
      libcxx_include = "#{sysroot_prefix}/include/c++/v1"
      libcxx_target_include = "#{sysroot_prefix}/include/#{sysroot_triple}/c++/v1"
      libcxx_libdir = "#{sysroot_prefix}/lib/#{sysroot_triple}"
      cmake_c_flags = "--target=#{sysroot_triple} --rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld -Wno-unused-command-line-argument"
      cmake_cxx_flags = "#{cmake_c_flags} -nostdinc++ -isystem #{libcxx_include} -isystem #{libcxx_target_include} -nostdlib++ -stdlib=libc++ -L#{libcxx_libdir} -L#{sysroot_prefix}/lib -Wl,--start-group -lc++ -lc++abi -lunwind -Wl,--end-group"
      cmake_archive_create = "#{sysroot_prefix}/bin/llvm-ar qc <TARGET> <OBJECTS>"
      cmake_archive_append = "#{sysroot_prefix}/bin/llvm-ar q <TARGET> <OBJECTS>"
      cmake_archive_finish = "#{sysroot_prefix}/bin/llvm-ranlib <TARGET>"
      shards_cache_root = "#{outer_sources_workspace_value}/#{SHARDS_CACHE_DIR}"
      libxml2_env = {
        "CPPFLAGS" => "-I#{sysroot_prefix}/include",
        "LDFLAGS"  => "-L#{sysroot_prefix}/lib",
      }
      libxml2_cmake_flags = [
        "-DLIBXML2_WITH_ZLIB=ON",
        "-DZLIB_LIBRARY=#{sysroot_prefix}/lib/libz.so.1",
        "-DZLIB_INCLUDE_DIR=#{sysroot_prefix}/include",
        "-DIconv_INCLUDE_DIR=#{sysroot_prefix}/include",
        "-DIconv_LIBRARY=#{sysroot_prefix}/lib/libiconv.so",
        "-DIconv_IS_BUILT_IN=OFF",
      ]
      musl_arch = case @architecture
                  when "aarch64", "arm64"
                    "aarch64"
                  when "x86_64", "amd64"
                    "x86_64"
                  else
                    @architecture
                  end
      musl_ld_path = "/etc/ld-musl-#{musl_arch}.path"
      [
        PhaseSpec.new(
          name: "host-setup",
          description: "Prepare cached sources and seed the rootfs from the host.",
          workspace: @host_workdir.to_s,
          environment: "host-setup",
          install_prefix: "/",
          destdir: nil,
          env: host_setup_env,
          package_allowlist: [] of String,
          extra_steps: host_setup_steps,
        ),
        PhaseSpec.new(
          name: "sysroot-from-alpine",
          description: "Build a self-contained sysroot using Alpine-hosted tools.",
          workspace: outer_sources_workspace_value,
          environment: "alpine-seed",
          install_prefix: sysroot_prefix,
          destdir: nil,
          env: sysroot_env,
          pre_steps: [
            build_step(
              name: "alpine-setup",
              strategy: "alpine-setup",
              workdir: "/",
            ),
          ],
          package_allowlist: nil,
          env_overrides: {
            "cmake" => {
              "CPPFLAGS" => "-I#{sysroot_prefix}/include -Wno-deprecated-literal-operator",
              "LDFLAGS"  => "-L#{sysroot_prefix}/lib",
            },
            "zlib" => {
              "CFLAGS"   => "-fPIC",
              "LDSHARED" => "#{sysroot_env["CC"]} -shared -Wl,-soname,libz.so.1 -Wl,--version-script,zlib.map",
            },
            "libxml2" => libxml2_env,
            "crystal" => {
              "CRYSTAL_CACHE_DIR" => "/tmp/crystal_cache",
              "CRYSTAL"           => "/usr/bin/crystal",
              "SHARDS"            => "/usr/bin/shards",
              "LLVM_CONFIG"       => "#{sysroot_prefix}/bin/llvm-config",
              "CC"                => "#{sysroot_prefix}/bin/clang++ --target=#{sysroot_triple} --rtlib=compiler-rt --unwindlib=libunwind -stdlib=libc++",
              "CXX"               => "#{sysroot_prefix}/bin/clang++ --target=#{sysroot_triple} --rtlib=compiler-rt --unwindlib=libunwind -stdlib=libc++",
              "CPPFLAGS"          => "-I#{sysroot_prefix}/include",
              "LDFLAGS"           => "-L#{sysroot_prefix}/lib/#{sysroot_triple} -L#{sysroot_prefix}/lib",
              "LIBRARY_PATH"      => "#{sysroot_prefix}/lib/#{sysroot_triple}:#{sysroot_prefix}/lib",
              "LD_LIBRARY_PATH"   => "#{sysroot_prefix}/lib/#{sysroot_triple}:#{sysroot_prefix}/lib",
            },
            "shards" => {
              "SHARDS_CACHE_PATH" => shards_cache_root,
              "CC"                => "#{sysroot_prefix}/bin/clang --target=#{sysroot_triple} --rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld",
              "CXX"               => "#{sysroot_prefix}/bin/clang++ --target=#{sysroot_triple} --rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld -stdlib=libc++",
              "LDFLAGS"           => "-L#{sysroot_prefix}/lib/#{sysroot_triple} -L#{sysroot_prefix}/lib",
              "LIBRARY_PATH"      => "#{sysroot_prefix}/lib/#{sysroot_triple}:#{sysroot_prefix}/lib",
            },
            "bootstrap-qcow2" => {
              "CRYSTAL"         => "/usr/bin/crystal",
              "SHARDS"          => "/usr/bin/shards",
              "CPPFLAGS"        => "-I#{sysroot_prefix}/include",
              "LDFLAGS"         => "-L#{sysroot_prefix}/lib",
              "LIBRARY_PATH"    => "#{sysroot_prefix}/lib",
              "PKG_CONFIG_PATH" => "#{sysroot_prefix}/lib/pkgconfig",
            },
          },
          configure_overrides: {
            "libxml2" => libxml2_cmake_flags,
          },
          patch_overrides: {
            "llvm-project" => [
              "#{bootstrap_repo_dir}/patches/llvm-project-llvmorg-#{DEFAULT_LLVM_VER}/x86-mctargetdesc-include-cstdint.patch",
            ],
          },
        ),
        PhaseSpec.new(
          name: "rootfs-from-sysroot",
          description: "Build a minimal rootfs using the newly built sysroot toolchain.",
          workspace: outer_sources_workspace_value,
          environment: "sysroot-toolchain",
          install_prefix: "/usr",
          destdir: rootfs_destdir,
          env: rootfs_env,
          package_allowlist: ["musl", "busybox", "linux-headers"],
          env_overrides: {
            "busybox" => {
              "HOSTCC"      => "#{sysroot_prefix}/bin/clang #{cmake_c_flags}",
              "HOSTCXX"     => "#{sysroot_prefix}/bin/clang++ #{cmake_c_flags}",
              "HOSTLDFLAGS" => "-L#{sysroot_prefix}/lib/#{sysroot_triple} -L#{sysroot_prefix}/lib",
              "MAKEFLAGS"   => "-e",
              "STRIP"       => "/bin/true",
            },
          },
          extra_steps: [
            write_file_step(
              "musl-ld-path",
              musl_ld_path,
              "/lib:/usr/lib:/opt/sysroot/lib:/opt/sysroot/lib/#{sysroot_triple}:/opt/sysroot/usr/lib\n",
            ),
            prepare_rootfs_step([
              {"/etc/os-release", os_release_content},
              {"/etc/profile", profile_content},
              {"/etc/resolv.conf", resolv_conf_content},
              {"/etc/hosts", hosts_content},
              {"/etc/ssl/certs/ca-certificates.crt", rootfs_ca_bundle_content},
              {"/.bq2-rootfs", "bq2-rootfs\n"},
            ]),
            build_step(
              name: "sysroot",
              strategy: "copy-tree",
              workdir: sysroot_prefix,
              install_prefix: sysroot_prefix,
            ),
          ],
        ),
        PhaseSpec.new(
          name: "system-from-sysroot",
          description: "Rebuild sysroot packages into /usr inside the new rootfs (prefix-free).",
          workspace: SysrootWorkspace::ROOTFS_WORKSPACE_PATH.to_s,
          environment: "rootfs-system",
          install_prefix: "/usr",
          destdir: nil,
          env: rootfs_env,
          package_allowlist: nil,
          env_overrides: {
            "libxml2" => libxml2_env,
            "zlib"    => {
              "CFLAGS"   => "-fPIC",
              "LDSHARED" => "#{rootfs_env["CC"]} -shared -Wl,-soname,libz.so.1 -Wl,--version-script,libz.map",
            },
            "m4" => {
              "INSTALL" => "./build-aux/install-sh",
            },
            "bootstrap-qcow2" => {
              "SHARDS_CACHE_PATH" => shards_cache_root,
            },
          },
          configure_overrides: {
            "cmake" => [
              "-DOPENSSL_ROOT_DIR=/usr",
              "-DOPENSSL_INCLUDE_DIR=/usr/include",
              "-DOPENSSL_SSL_LIBRARY=/usr/lib/libssl.so",
              "-DOPENSSL_CRYPTO_LIBRARY=/usr/lib/libcrypto.so",
              "-DCMAKE_C_COMPILER=#{sysroot_prefix}/bin/clang",
              "-DCMAKE_CXX_COMPILER=#{sysroot_prefix}/bin/clang++",
              "-DCMAKE_AR:FILEPATH=#{sysroot_prefix}/bin/llvm-ar",
              "-DCMAKE_RANLIB:FILEPATH=#{sysroot_prefix}/bin/llvm-ranlib",
              "-DCMAKE_C_COMPILER_AR:FILEPATH=#{sysroot_prefix}/bin/llvm-ar",
              "-DCMAKE_C_COMPILER_RANLIB:FILEPATH=#{sysroot_prefix}/bin/llvm-ranlib",
              "-DCMAKE_CXX_COMPILER_AR:FILEPATH=#{sysroot_prefix}/bin/llvm-ar",
              "-DCMAKE_CXX_COMPILER_RANLIB:FILEPATH=#{sysroot_prefix}/bin/llvm-ranlib",
              "-DCMAKE_C_ARCHIVE_CREATE:STRING=#{cmake_archive_create}",
              "-DCMAKE_C_ARCHIVE_APPEND:STRING=#{cmake_archive_append}",
              "-DCMAKE_C_ARCHIVE_FINISH:STRING=#{cmake_archive_finish}",
              "-DCMAKE_CXX_ARCHIVE_CREATE:STRING=#{cmake_archive_create}",
              "-DCMAKE_CXX_ARCHIVE_APPEND:STRING=#{cmake_archive_append}",
              "-DCMAKE_CXX_ARCHIVE_FINISH:STRING=#{cmake_archive_finish}",
              "-DCMAKE_C_FLAGS=#{cmake_c_flags}",
              "-DCMAKE_CXX_FLAGS=#{cmake_cxx_flags}",
              "-DCMAKE_MAKE_PROGRAM=/usr/bin/make",
              "-DKWSYS_CXX_HAS_EXT_STDIO_FILEBUF_H=0",
              # musl doesn't ship sys/cdefs.h, but cmake's libarchive probe can mis-detect it.
              "-DHAVE_SYS_CDEFS_H=0",
            ],
            "libxml2" => libxml2_cmake_flags,
          },
          extra_steps: [
            symlink_step(
              "bq2-symlinks",
              [
                {"bq2", "/usr/bin/curl"},
                {"bq2", "/usr/bin/git-remote-https"},
                {"bq2", "/usr/bin/pkg-config"},
              ],
            ),
          ],
        ),
        PhaseSpec.new(
          name: "tools-from-system",
          description: "Build additional developer tools inside the new rootfs.",
          workspace: SysrootWorkspace::ROOTFS_WORKSPACE_PATH.to_s,
          environment: "rootfs-system",
          install_prefix: "/usr",
          destdir: nil,
          env: rootfs_env,
          package_allowlist: nil,
          env_overrides: {
            "fossil" => {
              # autosetup-find-tclsh uses CC_FOR_BUILD when bootstrapping jimsh0.
              "CC_FOR_BUILD" => "#{sysroot_prefix}/bin/clang",
            },
            "git" => {
              "MAKEFLAGS"  => "-e",
              "NO_DOCS"    => "1",
              "NO_GETTEXT" => "1",
              "NO_TCLTK"   => "1",
              "NO_GITWEB"  => "1",
            },
          },
        ),
        PhaseSpec.new(
          name: "finalize-rootfs",
          description: "Strip the sysroot prefix and emit a prefix-free rootfs tarball.",
          workspace: SysrootWorkspace::ROOTFS_WORKSPACE_PATH.to_s,
          environment: "rootfs-finalize",
          install_prefix: "/usr",
          destdir: rootfs_destdir,
          env: rootfs_phase_env(sysroot_prefix),
          package_allowlist: [] of String,
          extra_steps: [
            build_step(
              name: "strip-sysroot",
              strategy: "remove-tree",
              workdir: "/",
              install_prefix: sysroot_prefix,
            ),
            write_file_step("musl-ld-path-final", musl_ld_path, "/lib:/usr/lib\n"),
            build_step(
              name: "rootfs-tarball",
              strategy: "tarball",
              workdir: "/",
              install_prefix: rootfs_tarball,
            ),
          ],
        ),
      ]
    end

    # Return the os-release contents for the generated rootfs.
    private def rootfs_os_release_content : String
      version = bootstrap_source_version
      lines = [
        "NAME=\"bootstrap-qcow2\"",
        "ID=bootstrap-qcow2",
        "VERSION_ID=\"#{version}\"",
        "VERSION=\"bootstrap-qcow2 #{version}\"",
        "PRETTY_NAME=\"bootstrap-qcow2 #{version}\"",
        "HOME_URL=\"https://github.com/embedconsult/bootstrap-qcow2\"",
      ]
      lines.join("\n") + "\n"
    end

    # Return the /etc/profile content for the generated rootfs.
    private def rootfs_profile_content : String
      lines = [
        "# /etc/profile for bootstrap-qcow2 rootfs.",
        "export PATH=\"/usr/sbin:/usr/bin:/sbin:/bin\"",
        "export HOME=\"${HOME:-/root}\"",
        "export CODEX_HOME=\"${CODEX_HOME:-/work}\"",
        "export CC=clang",
        "export CXX=clang++",
        "export AR=llvm-ar",
        "export NM=llvm-nm",
        "export RANLIB=llvm-ranlib",
        "export STRIP=llvm-strip",
        "export CRYSTAL_PATH=\"/usr/share/crystal/src\"",
        "export BQ2_ROOTFS=1",
        "export CHARSET=UTF-8",
        "export LANG=C.UTF-8",
        "export LC_COLLATE=C",
        "export SSL_CERT_FILE=\"/etc/ssl/certs/ca-certificates.crt\"",
      ]
      lines.join("\n") + "\n"
    end

    private def rootfs_resolv_conf_content : String
      "nameserver #{DEFAULT_NAMESERVER}\n"
    end

    # Return the CA bundle contents to seed /etc/ssl/certs/ca-certificates.crt.
    #
    # The bundle is sourced from the Mozilla CA bundle published by curl.se
    # (https://curl.se/ca/cacert.pem) and stored in data/ca-bundle.
    private def rootfs_ca_bundle_content : String
      CA_BUNDLE_PEM
    end

    private def rootfs_hosts_content : String
      lines = [
        "127.0.0.1 localhost",
        "::1 localhost",
      ]
      lines.join("\n") + "\n"
    end

    # Return environment variables for the rootfs validation phase.
    #
    # The rootfs phase is intended to use tools from the newly built sysroot,
    # but still execute in the bootstrap environment. Dynamic linker search
    # paths come from /etc/ld-musl-<arch>.path written during rootfs phases,
    # so avoid LD_LIBRARY_PATH overrides here.
    private def rootfs_phase_env(sysroot_prefix : String) : Hash(String, String)
      target = sysroot_target_triple
      libcxx_include = "#{sysroot_prefix}/include/c++/v1"
      libcxx_target_include = "#{sysroot_prefix}/include/#{target}/c++/v1"
      libcxx_libdir = "#{sysroot_prefix}/lib/#{target}"
      cc = "#{sysroot_prefix}/bin/clang --target=#{target} --rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld -Wno-unused-command-line-argument"
      cxx = "#{sysroot_prefix}/bin/clang++ --target=#{target} --rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld -Wno-unused-command-line-argument -nostdinc++ -isystem #{libcxx_include} -isystem #{libcxx_target_include} -nostdlib++ -stdlib=libc++ -L#{libcxx_libdir} -L#{sysroot_prefix}/lib -Wl,--start-group -lc++ -lc++abi -lunwind -Wl,--end-group"
      {
        "PATH"   => "/usr/bin:/bin:/usr/sbin:/sbin:#{sysroot_prefix}/bin:#{sysroot_prefix}/sbin",
        "CC"     => cc,
        "CXX"    => cxx,
        "AR"     => "#{sysroot_prefix}/bin/llvm-ar",
        "NM"     => "#{sysroot_prefix}/bin/llvm-nm",
        "RANLIB" => "#{sysroot_prefix}/bin/llvm-ranlib",
        "STRIP"  => "#{sysroot_prefix}/bin/llvm-strip",
      }
    end

    private def sysroot_target_triple : String
      case @architecture
      when "aarch64", "arm64"
        "aarch64-alpine-linux-musl"
      when "x86_64", "amd64"
        "x86_64-alpine-linux-musl"
      else
        "#{@architecture}-alpine-linux-musl"
      end
    end

    # Return environment variables for the sysroot bootstrap phase.
    #
    # This ensures tools installed into the sysroot prefix (for example, CMake)
    # are immediately available to later steps in the same phase while ensuring
    # the seed rootfs uses Clang for all C/C++ compilation.
    private def sysroot_phase_env(sysroot_prefix : String) : Hash(String, String)
      {
        "PATH" => "#{sysroot_prefix}/bin:#{sysroot_prefix}/sbin:/usr/bin:/bin",
        "CC"   => "/usr/bin/clang",
        "CXX"  => "/usr/bin/clang++",
        # TODO: determine if this should be here.
        "LD_LIBRARY_PATH" => "#{sysroot_prefix}/lib",
      }
    end

    private def host_setup_env : Hash(String, String)
      env = {
        "BQ2_ARCH"          => @architecture,
        "BQ2_BRANCH"        => @branch,
        "BQ2_BASE_VERSION"  => @base_version,
        "BQ2_SOURCE_BRANCH" => bootstrap_source_version,
      }
      env["BQ2_BASE_ROOTFS_PATH"] = @base_rootfs_path.not_nil!.to_s if @base_rootfs_path
      env["BQ2_USE_SYSTEM_TAR_SOURCES"] = @use_system_tar_for_sources ? "1" : "0"
      env["BQ2_USE_SYSTEM_TAR_ROOTFS"] = @use_system_tar_for_rootfs ? "1" : "0"
      env["BQ2_PRESERVE_OWNERSHIP_SOURCES"] = @preserve_ownership_for_sources ? "1" : "0"
      env["BQ2_PRESERVE_OWNERSHIP_ROOTFS"] = @preserve_ownership_for_rootfs ? "1" : "0"
      env["BQ2_OWNER_UID"] = @owner_uid.to_s if @owner_uid
      env["BQ2_OWNER_GID"] = @owner_gid.to_s if @owner_gid
      env
    end

    private def host_setup_steps : Array(BuildStep)
      workdir = @host_workdir.to_s
      [
        build_step(
          name: "download-sources",
          strategy: "download-sources",
          workdir: workdir,
        ),
        build_step(
          name: "populate-seed",
          strategy: "populate-seed",
          workdir: workdir,
        ),
        build_step(
          name: "extract-sources",
          strategy: "extract-sources",
          workdir: workdir,
        ),
      ]
    end

    # Construct a phased build plan. The plan is serialized into the chroot so
    # it can be replayed by the coordinator runner.
    def build_plan : BuildPlan
      phases = phase_specs.map { |spec| build_phase(spec) }.reject(&.steps.empty?)
      BuildPlan.new(phases)
    end

    # Persist the build plan JSON into the inner rootfs var/lib directory.
    def write_plan(plan : BuildPlan = build_plan) : Path
      prepare_workspace
      build_state = SysrootBuildState.new(workspace: @workspace)
      plan_json = plan.to_pretty_json
      plan_path = build_state.plan_path_path
      FileUtils.mkdir_p(plan_path.parent)
      File.write(plan_path, plan_json)
      ensure_state_file(build_state, plan_path)
      plan_path
    end

    # Ensure the workspace layout + marker exist, returning the workspace.
    def prepare_workspace : SysrootWorkspace
      @workspace = SysrootWorkspace.create(@host_workdir)
      @outer_rootfs_dir = @workspace.outer_rootfs_path
      @inner_rootfs_dir = @workspace.inner_rootfs_path
      @inner_rootfs_workspace_dir = @workspace.inner_workspace_path
      @workspace
    end

    private def ensure_state_file(build_state : SysrootBuildState, plan_path : Path) : Nil
      return if build_state.state_exists?
      build_state.plan_path = build_state.rootfs_plan_path
      build_state.plan_digest = SysrootBuildState.digest_for?(plan_path.to_s)
      build_state.ensure_state_file
    end

    # Convert a PhaseSpec into a concrete BuildPhase with computed workdirs and
    # per-package build steps.
    private def build_phase(spec : PhaseSpec) : BuildPhase
      phase_packages = select_packages(spec.name, spec.package_allowlist)
      steps = [] of BuildStep
      steps.concat(spec.pre_steps) unless spec.pre_steps.empty?
      steps.concat(phase_packages.flat_map { |pkg| build_steps_for(pkg, spec) })
      steps.concat(spec.extra_steps) unless spec.extra_steps.empty?
      BuildPhase.new(
        name: spec.name,
        description: spec.description,
        workspace: spec.workspace,
        environment: spec.environment,
        install_prefix: spec.install_prefix,
        destdir: spec.destdir,
        env: spec.env,
        steps: steps,
      )
    end

    # Create a BuildStep with defaulted arrays for simple helper usage.
    private def build_step(name : String,
                           strategy : String,
                           workdir : String,
                           install_prefix : String? = nil,
                           env : Hash(String, String) = {} of String => String,
                           configure_flags : Array(String) = [] of String,
                           patches : Array(String) = [] of String,
                           destdir : String? = nil,
                           build_dir : String? = nil) : BuildStep
      BuildStep.new(
        name: name,
        strategy: strategy,
        workdir: workdir,
        configure_flags: configure_flags,
        patches: patches,
        install_prefix: install_prefix,
        destdir: destdir,
        env: env,
        build_dir: build_dir,
      )
    end

    # Build a write-file step for a single content payload.
    private def write_file_step(name : String, path : String, content : String) : BuildStep
      build_step(
        name: name,
        strategy: "write-file",
        workdir: "/",
        install_prefix: path,
        env: {"CONTENT" => content},
      )
    end

    # Build a prepare-rootfs step for a list of path/content pairs.
    private def prepare_rootfs_step(files : Array(Tuple(String, String))) : BuildStep
      env = {} of String => String
      files.each_with_index do |(path, content), idx|
        env["FILE_#{idx}_PATH"] = path
        env["FILE_#{idx}_CONTENT"] = content
      end
      build_step(
        name: "prepare-rootfs",
        strategy: "prepare-rootfs",
        workdir: "/",
        install_prefix: "/",
        env: env,
      )
    end

    # Build a symlink step from a list of source/destination pairs.
    private def symlink_step(name : String, links : Array(Tuple(String, String))) : BuildStep
      env = {} of String => String
      links.each_with_index do |(source, dest), idx|
        env["LINK_#{idx}_SRC"] = source
        env["LINK_#{idx}_DEST"] = dest
      end
      build_step(
        name: name,
        strategy: "symlink",
        workdir: "/",
        install_prefix: "/",
        env: env,
      )
    end

    # Build the steps for a package, expanding multi-stage packages as needed.
    private def build_steps_for(pkg : PackageSpec, spec : PhaseSpec) : Array(BuildStep)
      build_root = build_root_for(pkg, spec)
      env = env_overrides_for(pkg, spec)
      return llvm_stage_steps(pkg, spec, build_root, env) if pkg.name == "llvm-project"

      clean_build = clean_build_for(pkg, spec)
      [BuildStep.new(
        name: pkg.name,
        strategy: pkg.strategy,
        workdir: build_root,
        configure_flags: configure_flags_for(pkg, spec),
        patches: patches_for(pkg, spec),
        env: env,
        build_dir: build_dir_for(pkg, spec),
        clean_build: clean_build,
      )]
    end

    # Resolve the package build root in the workspace.
    private def build_root_for(pkg : PackageSpec, spec : PhaseSpec) : String
      build_directory = pkg.build_directory || strip_archive_extension(pkg.filename)
      File.join(spec.workspace, build_directory)
    end

    # Resolve the package build directory when an out-of-tree build is requested.
    private def build_dir_for(pkg : PackageSpec, spec : PhaseSpec) : String?
      build_dir = pkg.build_dir
      return nil unless build_dir
      build_dir = build_dir.gsub("%{phase}", spec.name).gsub("%{name}", pkg.name)
      build_dir.starts_with?("/") ? build_dir : File.join(spec.workspace, build_dir)
    end

    # Return a copy of the env overrides for a package.
    private def env_overrides_for(pkg : PackageSpec, spec : PhaseSpec) : Hash(String, String)
      overrides = spec.env_overrides[pkg.name]? || ({} of String => String)
      overrides.dup
    end

    # Ensure clean rebuilds when a package is installed into multiple prefixes.
    private def clean_build_for(pkg : PackageSpec, spec : PhaseSpec) : Bool
      return false unless pkg.name == "bdwgc"
      spec.name == "sysroot-from-alpine" || spec.name == "system-from-sysroot"
    end

    # Expand llvm-project into a two-stage CMake build using the sysroot toolchain.
    private def llvm_stage_steps(pkg : PackageSpec,
                                 spec : PhaseSpec,
                                 build_root : String,
                                 env : Hash(String, String)) : Array(BuildStep)
      env["CMAKE_SOURCE_DIR"] = "llvm"
      stage2_env = env.dup
      stage2_lib = File.join(build_root, "build-stage2", "lib")
      existing_ld = stage2_env["LD_LIBRARY_PATH"]?
      stage2_env["LD_LIBRARY_PATH"] = existing_ld && !existing_ld.empty? ? "#{stage2_lib}:#{existing_ld}" : stage2_lib
      base_flags = configure_flags_for(pkg, spec)
      patches = patches_for(pkg, spec)
      stage1_flags = llvm_stage1_flags(base_flags, spec.env)
      stage2_flags = llvm_stage2_flags(base_flags, spec.install_prefix, sysroot_target_triple, build_root)
      [
        BuildStep.new(
          name: "#{pkg.name}-stage1",
          strategy: "cmake-project",
          workdir: build_root,
          configure_flags: stage1_flags,
          patches: patches,
          env: env,
          build_dir: "build-stage1",
        ),
        BuildStep.new(
          name: "#{pkg.name}-stage2",
          strategy: "cmake-project",
          workdir: build_root,
          configure_flags: stage2_flags,
          patches: patches,
          env: stage2_env,
          build_dir: "build-stage2",
        ),
      ]
    end

    # Split a compiler command string into its binary and trailing flags.
    private def split_compiler_flags(value : String) : Tuple(String, String)
      parts = value.split(/\s+/)
      compiler = parts.first? || value
      flags = parts.size > 1 ? parts[1..-1].join(" ") : ""
      {compiler, flags}
    end

    # Ensure warning suppression is present for LLVM C++ builds.
    private def append_warning_suppression(flags : String) : String
      warning_flag = "-Wno-unnecessary-virtual-specifier"
      return flags if flags.includes?(warning_flag)
      return warning_flag if flags.empty?
      "#{flags} #{warning_flag}"
    end

    # Stage 1 LLVM flags use the host compiler, keep LLVM static, and still
    # build runtimes so stage 2 can link against libunwind/libc++ while it
    # assembles the shared toolchain.
    private def llvm_stage1_flags(base_flags : Array(String),
                                  phase_env : Hash(String, String)) : Array(String)
      cc_value = phase_env["CC"]? || "clang"
      cxx_value = phase_env["CXX"]? || "clang++"
      cc, cc_flags = split_compiler_flags(cc_value)
      cxx, cxx_flags = split_compiler_flags(cxx_value)
      cxx_flags = append_warning_suppression(cxx_flags)

      flags = base_flags.reject do |flag|
        flag.starts_with?("-DBUILD_SHARED_LIBS=") ||
          flag.starts_with?("-DLLVM_ENABLE_SHARED=") ||
          flag.starts_with?("-DLLVM_ENABLE_LIBCXX=") ||
          flag.starts_with?("-DLLVM_BUILD_LLVM_DYLIB=") ||
          flag.starts_with?("-DLLVM_LINK_LLVM_DYLIB=") ||
          flag.starts_with?("-DLLVM_TOOL_LLVM_SHLIB_BUILD=")
      end
      flags << "-DCMAKE_C_COMPILER=#{cc}"
      flags << "-DCMAKE_CXX_COMPILER=#{cxx}"
      flags << "-DBUILD_SHARED_LIBS=OFF"
      flags << "-DLLVM_ENABLE_SHARED=OFF"
      flags << "-DLLVM_BUILD_LLVM_DYLIB=ON"
      flags << "-DLLVM_LINK_LLVM_DYLIB=OFF"
      flags << "-DLLVM_TOOL_LLVM_SHLIB_BUILD=OFF"
      unless cc_flags.empty? || flags.any? { |flag| flag.starts_with?("-DCMAKE_C_FLAGS=") }
        flags << "-DCMAKE_C_FLAGS=#{cc_flags}"
      end
      unless cxx_flags.empty? || flags.any? { |flag| flag.starts_with?("-DCMAKE_CXX_FLAGS=") }
        flags << "-DCMAKE_CXX_FLAGS=#{cxx_flags}"
      end
      flags
    end

    # Stage 2 LLVM flags use the sysroot compiler and link against the sysroot
    # libc++/libunwind runtimes for a self-contained toolchain.
    private def llvm_stage2_flags(base_flags : Array(String),
                                  sysroot_prefix : String,
                                  sysroot_triple : String,
                                  build_root : String) : Array(String)
      libcxx_include = "#{sysroot_prefix}/include/c++/v1"
      libcxx_target_include = "#{sysroot_prefix}/include/#{sysroot_triple}/c++/v1"
      libcxx_libdir = "#{sysroot_prefix}/lib/#{sysroot_triple}"
      build_rpath = File.join(build_root, "build-stage2", "lib")
      install_rpath = "#{libcxx_libdir}:#{sysroot_prefix}/lib"
      cxx_standard_libs = "-lc++ -lc++abi -lunwind"
      c_flags = "--rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld -Wno-unused-command-line-argument"
      cxx_flags = "-nostdinc++ -isystem #{libcxx_include} -isystem #{libcxx_target_include} -nostdlib++ -stdlib=libc++ --rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld -Wno-unused-command-line-argument -Wno-unnecessary-virtual-specifier -L#{libcxx_libdir} -L#{sysroot_prefix}/lib"
      linker_flags = "--rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld -L#{libcxx_libdir} -L#{sysroot_prefix}/lib"

      flags = base_flags.dup
      flags << "-DCMAKE_C_COMPILER=#{sysroot_prefix}/bin/clang"
      flags << "-DCMAKE_CXX_COMPILER=#{sysroot_prefix}/bin/clang++"
      flags << "-DCMAKE_C_FLAGS=#{c_flags}"
      flags << "-DCMAKE_CXX_FLAGS=#{cxx_flags}"
      flags << "-DCMAKE_CXX_STANDARD_LIBRARIES=#{cxx_standard_libs}"
      flags << "-DCMAKE_EXE_LINKER_FLAGS=#{linker_flags}"
      flags << "-DCMAKE_SHARED_LINKER_FLAGS=#{linker_flags}"
      flags << "-DCMAKE_MODULE_LINKER_FLAGS=#{linker_flags}"
      flags << "-DCMAKE_BUILD_RPATH=#{build_rpath}:#{install_rpath}"
      flags << "-DCMAKE_INSTALL_RPATH=#{install_rpath}"
      flags << "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
      flags
    end

    # Selects the packages to include in a phase.
    #
    # When *allowlist* is nil, includes all packages. Otherwise, it maps each
    # requested name to its PackageSpec and raises if any are missing.
    private def select_packages(phase_name : String, allowlist : Array(String)?) : Array(PackageSpec)
      unless allowlist
        return packages.select do |pkg|
          phases = pkg.phases
          phases ? phases.includes?(phase_name) : phase_name == "sysroot-from-alpine"
        end
      end
      allowlist.map do |name|
        pkg = packages.find { |candidate| candidate.name == name }
        raise "Unknown package #{name} in build phase allowlist" unless pkg
        pkg
      end
    end

    # Returns the build flags for a package after applying phase-level overrides.
    private def configure_flags_for(pkg : PackageSpec, spec : PhaseSpec) : Array(String)
      pkg.configure_flags + (spec.configure_overrides[pkg.name]? || [] of String)
    end

    # Returns the patch list for a package after applying phase-level overrides.
    private def patches_for(pkg : PackageSpec, spec : PhaseSpec) : Array(String)
      pkg.patches + (spec.patch_overrides[pkg.name]? || [] of String)
    end

    # Prepare the workspace layout and serialize the build plan.
    #
    # The sysroot seed and sources are now populated by the runner's host-setup
    # phase, so this method only creates the layout/marker and writes the plan.
    def generate_chroot(include_sources : Bool = true) : Path
      prepare_workspace
      write_plan
      outer_rootfs_dir
    end

    # Generate a chroot tarball for the prepared rootfs.
    def generate_chroot_tarball(output : Path? = nil, include_sources : Bool = true) : Path
      raise "sysroot-builder no longer generates tarballs; use sysroot-runner finalize-rootfs instead"
    end

    # Generate a chroot tarball from an already-prepared rootfs.
    def write_chroot_tarball(output : Path? = nil) : Path
      raise "sysroot-builder no longer generates tarballs; use sysroot-runner finalize-rootfs instead"
    end

    # Remove known archive extensions to derive the directory name.
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

    # Placeholder for future build command materialization.
    private def build_commands_for(pkg : PackageSpec, sysroot_prefix : String) : Array(Array(String))
      # The builder remains data-only: embed strategy metadata and let the runner
      # translate into concrete commands.
      Array(Array(String)).new
    end

    # Try to chown the tarball to the invoking sudo user for convenience.
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

    # Resolve uid/gid from /etc/passwd for a username.
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

    # Summarize the sysroot builder CLI behavior for help output.
    def self.summary : String
      "Build sysroot tarball or directory"
    end

    # Return command aliases handled by the sysroot builder CLI.
    def self.aliases : Array(String)
      ["sysroot-plan-write", "sysroot-tarball"]
    end

    # Describe help output entries for the sysroot builder CLI.
    def self.help_entries : Array(Tuple(String, String))
      [
        {"sysroot-builder", "Build sysroot tarball or directory"},
        {"sysroot-plan-write", "Write a fresh build plan JSON"},
        {"sysroot-tarball", "Emit a prefix-free rootfs tarball"},
      ]
    end

    # Dispatch sysroot builder subcommands by command name.
    def self.run(args : Array(String), command_name : String) : Int32
      case command_name
      when "sysroot-builder"
        run_builder(args)
      when "sysroot-plan-write"
        run_plan_write(args)
      when "sysroot-tarball"
        run_sysroot_tarball(args)
      else
        raise "Unknown sysroot builder command #{command_name}"
      end
    end

    # Build or reuse a sysroot workspace and optionally emit a tarball.
    private def self.run_builder(args : Array(String)) : Int32
      architecture = SysrootBuilder::DEFAULT_ARCH
      branch = SysrootBuilder::DEFAULT_BRANCH
      base_version = SysrootBuilder::DEFAULT_BASE_VERSION
      base_rootfs_path : Path? = nil
      use_system_tar_for_sources = false
      use_system_tar_for_rootfs = false
      preserve_ownership_for_sources = false
      preserve_ownership_for_rootfs = false
      owner_uid = nil
      owner_gid = nil

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-builder [options]") do |p|
        p.on("-a ARCH", "--arch=ARCH", "Target architecture (default: #{architecture})") { |val| architecture = val }
        p.on("-b BRANCH", "--branch=BRANCH", "Source branch/release tag (default: #{branch})") { |val| branch = val }
        p.on("-v VERSION", "--base-version=VERSION", "Base rootfs version/tag (default: #{base_version})") { |val| base_version = val }
        p.on("--base-rootfs PATH", "Use a local rootfs tarball instead of downloading the Alpine minirootfs") { |val| base_rootfs_path = Path[val].expand }
        p.on("--system-tar-sources", "Use system tar to extract all staged source archives") { use_system_tar_for_sources = true }
        p.on("--system-tar-rootfs", "Use system tar to extract the base rootfs") { use_system_tar_for_rootfs = true }
        p.on("--preserve-ownership-sources", "Apply ownership metadata when extracting source archives") { preserve_ownership_for_sources = true }
        p.on("--no-preserve-ownership-sources", "Skip applying ownership metadata for source archives") { preserve_ownership_for_sources = false }
        p.on("--preserve-ownership-rootfs", "Apply ownership metadata for the base rootfs") { preserve_ownership_for_rootfs = true }
        p.on("--owner-uid=UID", "Override extracted file owner uid (implies ownership preservation)") do |val|
          preserve_ownership_for_sources = true
          preserve_ownership_for_rootfs = true
          owner_uid = val.to_i
        end
        p.on("--owner-gid=GID", "Override extracted file owner gid (implies ownership preservation)") do |val|
          preserve_ownership_for_sources = true
          preserve_ownership_for_rootfs = true
          owner_gid = val.to_i
        end
      end
      return CLI.print_help(parser) if help

      Log.info { "Sysroot builder log level=#{Log.for("").level} (env-configured)" }
      builder = SysrootBuilder.new(
        architecture: architecture,
        branch: branch,
        base_version: base_version,
        base_rootfs_path: base_rootfs_path,
        use_system_tar_for_sources: use_system_tar_for_sources,
        use_system_tar_for_rootfs: use_system_tar_for_rootfs,
        preserve_ownership_for_sources: preserve_ownership_for_sources,
        preserve_ownership_for_rootfs: preserve_ownership_for_rootfs,
        owner_uid: owner_uid,
        owner_gid: owner_gid
      )

      chroot_path = builder.generate_chroot
      build_state = SysrootBuildState.new(workspace: builder.workspace)
      puts "Prepared sysroot workspace at #{chroot_path}"
      puts "Wrote build plan at #{build_state.plan_path_path}"
      0
    end

    # Writes a freshly generated build plan JSON.
    private def self.run_plan_write(args : Array(String)) : Int32
      workspace = SysrootWorkspace.create(SysrootBuilder::DEFAULT_HOST_WORKDIR)
      build_state = SysrootBuildState.new(workspace: workspace)
      output = build_state.plan_path_path.to_s
      workspace_root = Bootstrap::BuildPlanUtils::DEFAULT_WORKSPACE_ROOT
      force = false
      write_overrides = false
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-plan-write [options]") do |p|
        p.on("--output PATH", "Write the plan to PATH (default: #{output})") { |path| output = path }
        p.on("--workspace-root PATH", "Rewrite plan workdirs rooted at #{SysrootWorkspace::ROOTFS_WORKSPACE_PATH} to PATH (default: #{workspace_root})") { |path| workspace_root = path }
        p.on("--force", "Overwrite an existing plan at the output path") { force = true }
        p.on("--override", "Write sysroot-build-overrides.json with differences from the existing plan") { write_overrides = true }
      end
      return CLI.print_help(parser) if help

      if write_overrides && force
        STDERR.puts "Refusing to combine --override with --force"
        return 1
      end

      existing_plan = nil
      if write_overrides && File.exists?(output)
        existing_plan = BuildPlan.parse(File.read(output))
      end
      if write_overrides && existing_plan.nil?
        STDERR.puts "Refusing to write overrides without an existing plan at #{output}"
        return 1
      end
      if File.exists?(output) && !force && !write_overrides
        STDERR.puts "Refusing to overwrite existing plan at #{output} (pass --force)"
        return 1
      end

      builder = SysrootBuilder.new
      plan = builder.build_plan
      if workspace_root != Bootstrap::BuildPlanUtils::DEFAULT_WORKSPACE_ROOT
        plan = Bootstrap::BuildPlanUtils.rewrite_workspace_root(plan, workspace_root)
      end

      if write_overrides
        overrides = BuildPlanOverrides.from_diff(existing_plan.not_nil!, plan)
        overrides_path = File.join(File.dirname(output), SysrootBuildState::OVERRIDES_FILE)
        FileUtils.mkdir_p(File.dirname(overrides_path))
        File.write(overrides_path, overrides.to_pretty_json)
        puts "Wrote build plan overrides to #{overrides_path}"
        return 0
      end

      FileUtils.mkdir_p(File.dirname(output))
      File.write(output, plan.to_pretty_json)
      puts "Wrote build plan to #{output}"
      0
    end

    # Run the finalize-rootfs phase to emit a prefix-free rootfs tarball.
    private def self.run_sysroot_tarball(args : Array(String)) : Int32
      workspace = SysrootWorkspace.detect(SysrootWorkspace::DEFAULT_HOST_WORKDIR)
      build_state = SysrootBuildState.new(workspace: workspace)
      plan_path = build_state.plan_path_path.to_s
      overrides_path : String? = nil
      use_default_overrides = true
      report_dir : String? = build_state.report_dir_path.to_s
      resume = true
      allow_outside_rootfs = false
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-tarball [options]") do |p|
        p.on("--overrides PATH", "Apply runtime overrides JSON (default: sysroot-build-overrides.json in the inner rootfs var/lib)") do |path|
          overrides_path = path
          use_default_overrides = false
        end
        p.on("--no-overrides", "Disable runtime overrides") do
          overrides_path = nil
          use_default_overrides = false
        end
        p.on("--report-dir PATH", "Write failure reports to PATH (default: #{report_dir})") { |path| report_dir = path }
        p.on("--no-report", "Disable failure report writing") { report_dir = nil }
        p.on("--no-resume", "Disable resume/state tracking (useful when the default state path is not writable)") { resume = false }
        p.on("--allow-outside-rootfs", "Allow running rootfs-* phases outside the produced rootfs (requires destdir overrides)") { allow_outside_rootfs = true }
      end
      return CLI.print_help(parser) if help

      exe = Process.executable_path
      raise "Unable to locate bq2 executable for sysroot-runner" unless exe
      argv = [
        "sysroot-runner",
        "--phase",
        "finalize-rootfs",
      ]
      argv.concat(["--overrides", overrides_path]) if overrides_path
      argv << "--no-overrides" if overrides_path.nil? && !use_default_overrides
      argv.concat(["--report-dir", report_dir.not_nil!]) if report_dir
      argv << "--no-report" if report_dir.nil?
      argv << "--no-resume" unless resume
      argv << "--allow-outside-rootfs" if allow_outside_rootfs
      status = Process.run(exe, argv, input: STDIN, output: STDOUT, error: STDERR)
      raise "sysroot-runner failed (exit=#{status.exit_code})" unless status.success?
      0
    end
  end
end
