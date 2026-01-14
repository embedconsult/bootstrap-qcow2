require "compress/gzip"
require "digest/crc32"
require "digest/sha256"
require "file_utils"
require "http/client"
require "json"
require "log"
require "path"
require "uri"
require "./build_plan"

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
    {% if flag?(:x86_64) %}
      DEFAULT_ARCH = "x86_64"
    {% elsif flag?(:aarch64) %}
      DEFAULT_ARCH = "aarch64"
    {% else %}
      DEFAULT_ARCH = ""
    {% end %}
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
    DEFAULT_BQ2_BRANCH    = "codex-development"

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
      # Prefer a filename that includes the package name for clarity.
      def filename : String
        basename = File.basename(url.path)
        basename.includes?(name) ? basename : "#{name}-#{basename}"
      end

      # Return the canonical URL list: primary URL plus any extras.
      def all_urls : Array(URI)
        [url] + extra_urls
      end
    end

    getter architecture : String
    getter branch : String
    getter workspace : Path
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
      extra_steps : Array(BuildStep) = [] of BuildStep,
      env_overrides : Hash(String, Hash(String, String)) = {} of String => Hash(String, String),
      configure_overrides : Hash(String, Array(String)) = {} of String => Array(String),
      patch_overrides : Hash(String, Array(String)) = {} of String => Array(String)

    # Create a sysroot builder rooted at the workspace directory.
    def initialize(@workspace : Path = Path["data/sysroot"],
                   @architecture : String = DEFAULT_ARCH,
                   @branch : String = DEFAULT_BRANCH,
                   @base_version : String = DEFAULT_BASE_VERSION,
                   @use_system_tar_for_sources : Bool = false,
                   @use_system_tar_for_rootfs : Bool = false,
                   @preserve_ownership_for_sources : Bool = false,
                   @preserve_ownership_for_rootfs : Bool = false,
                   @owner_uid : Int32? = nil,
                   @owner_gid : Int32? = nil)
      FileUtils.mkdir_p(@workspace)
      FileUtils.mkdir_p(cache_dir)
      FileUtils.mkdir_p(checksum_dir)
      FileUtils.mkdir_p(sources_dir)
    end

    # Directory for cached artifacts within the workspace.
    def cache_dir : Path
      @workspace / "cache"
    end

    # Directory for checksum cache entries.
    def checksum_dir : Path
      cache_dir / "checksums"
    end

    # Directory containing downloaded source archives.
    def sources_dir : Path
      @workspace / "sources"
    end

    # Directory containing the extracted rootfs.
    def rootfs_dir : Path
      @workspace / "rootfs"
    end

    # Absolute path to the serialized build plan inside the rootfs.
    def plan_path : Path
      rootfs_dir / "var/lib/sysroot-build-plan.json"
    end

    # Returns true when the workspace contains a prepared rootfs with a
    # serialized build plan. Iteration state is created by `SysrootRunner` and
    # is not part of a clean sysroot build output.
    def rootfs_ready? : Bool
      File.exists?(plan_path)
    end

    # Directory containing the staged sysroot install prefix.
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
      bootstrap_repo_dir = "/workspace/bootstrap-qcow2-#{bootstrap_source_branch}"
      [
        PackageSpec.new(
          "bootstrap-qcow2",
          bootstrap_source_branch,
          URI.parse("https://github.com/embedconsult/bootstrap-qcow2/archive/refs/heads/#{bootstrap_source_branch}.tar.gz"),
          strategy: "crystal",
        ),
        PackageSpec.new("m4", DEFAULT_M4, URI.parse("https://ftp.gnu.org/gnu/m4/m4-#{DEFAULT_M4}.tar.gz")),
        PackageSpec.new("musl", DEFAULT_MUSL, URI.parse("https://musl.libc.org/releases/musl-#{DEFAULT_MUSL}.tar.gz")),
        PackageSpec.new(
          "busybox",
          DEFAULT_BUSYBOX,
          URI.parse("https://github.com/mirror/busybox/archive/refs/tags/#{DEFAULT_BUSYBOX.tr(".", "_")}.tar.gz"),
          strategy: "busybox",
          patches: ["#{bootstrap_repo_dir}/patches/busybox-#{DEFAULT_BUSYBOX.tr(".", "_")}/tc-disable-cbq-when-missing-headers.patch"],
        ),
        PackageSpec.new("make", DEFAULT_GNU_MAKE, URI.parse("https://ftp.gnu.org/gnu/make/make-#{DEFAULT_GNU_MAKE}.tar.gz")),
        PackageSpec.new("zlib", DEFAULT_ZLIB, URI.parse("https://zlib.net/zlib-#{DEFAULT_ZLIB}.tar.gz")),
        PackageSpec.new("libressl", DEFAULT_LIBRESSL, URI.parse("https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-#{DEFAULT_LIBRESSL}.tar.gz")),
        PackageSpec.new(
          "cmake",
          DEFAULT_CMAKE,
          URI.parse("https://github.com/Kitware/CMake/releases/download/v#{DEFAULT_CMAKE}/cmake-#{DEFAULT_CMAKE}.tar.gz"),
          strategy: "cmake",
          configure_flags: [
            "-DCMAKE_CXX_FLAGS=-static-libstdc++ -static-libgcc",
            "-DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++ -static-libgcc",
            "-DCMake_HAVE_CXX_MAKE_UNIQUE=ON",
            "-DCMake_HAVE_CXX_UNIQUE_PTR=ON",
            "-DCMake_HAVE_CXX_FILESYSTEM=ON",
            "-DOPENSSL_ROOT_DIR=/opt/sysroot",
            "-DOPENSSL_INCLUDE_DIR=/opt/sysroot/include",
            "-DOPENSSL_SSL_LIBRARY=/opt/sysroot/lib/libssl.so",
            "-DOPENSSL_CRYPTO_LIBRARY=/opt/sysroot/lib/libcrypto.so",
          ],
          patches: ["#{bootstrap_repo_dir}/patches/cmake-#{DEFAULT_CMAKE}/cmcppdap-include-cstdint.patch"],
        ),
        PackageSpec.new("libatomic_ops", DEFAULT_LIBATOMIC_OPS, URI.parse("https://github.com/ivmai/libatomic_ops/releases/download/v#{DEFAULT_LIBATOMIC_OPS}/libatomic_ops-#{DEFAULT_LIBATOMIC_OPS}.tar.gz")),
        PackageSpec.new(
          "llvm-project",
          DEFAULT_LLVM_VER,
          URI.parse("https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-#{DEFAULT_LLVM_VER}.tar.gz"),
          strategy: "llvm",
          configure_flags: [
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_CXX_FLAGS=-static-libstdc++ -static-libgcc",
            "-DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++ -static-libgcc",
            "-DLLVM_TARGETS_TO_BUILD=AArch64",
            "-DLLVM_ENABLE_PROJECTS=clang;lld",
            "-DLLVM_INCLUDE_TESTS=OFF",
            "-DLLVM_INCLUDE_EXAMPLES=OFF",
            "-DLLVM_INCLUDE_BENCHMARKS=OFF",
            "-DLLVM_ENABLE_TERMINFO=OFF",
            "-DLLVM_ENABLE_PIC=OFF",
          ],
          patches: ["#{bootstrap_repo_dir}/patches/llvm-project-llvmorg-#{DEFAULT_LLVM_VER}/smallvector-include-cstdint.patch"],
        ),
        PackageSpec.new("bdwgc", DEFAULT_BDWGC, URI.parse("https://github.com/ivmai/bdwgc/releases/download/v#{DEFAULT_BDWGC}/gc-#{DEFAULT_BDWGC}.tar.gz"), build_directory: "gc-#{DEFAULT_BDWGC}"),
        PackageSpec.new("pcre2", DEFAULT_PCRE2, URI.parse("https://github.com/PhilipHazel/pcre2/releases/download/pcre2-#{DEFAULT_PCRE2}/pcre2-#{DEFAULT_PCRE2}.tar.gz")),
        PackageSpec.new("gmp", DEFAULT_GMP, URI.parse("https://ftp.gnu.org/gnu/gmp/gmp-#{DEFAULT_GMP}.tar.gz")),
        PackageSpec.new("libiconv", DEFAULT_LIBICONV, URI.parse("https://ftp.gnu.org/pub/gnu/libiconv/libiconv-#{DEFAULT_LIBICONV}.tar.gz")),
        PackageSpec.new(
          "libxml2",
          DEFAULT_LIBXML2,
          URI.parse("https://github.com/GNOME/libxml2/archive/refs/tags/v#{DEFAULT_LIBXML2}.tar.gz"),
          build_directory: "libxml2-#{DEFAULT_LIBXML2}",
          configure_flags: [
            "-DLIBXML2_WITH_PYTHON=OFF",
            "-DLIBXML2_WITH_TESTS=OFF",
            "-DLIBXML2_WITH_LZMA=OFF",
          ],
        ),
        PackageSpec.new("libyaml", DEFAULT_LIBYAML, URI.parse("https://pyyaml.org/download/libyaml/yaml-#{DEFAULT_LIBYAML}.tar.gz"), build_directory: "yaml-#{DEFAULT_LIBYAML}"),
        PackageSpec.new("libffi", DEFAULT_LIBFFI, URI.parse("https://github.com/libffi/libffi/releases/download/v#{DEFAULT_LIBFFI}/libffi-#{DEFAULT_LIBFFI}.tar.gz")),
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

    # Clone a PackageSpec with a different URL and checksum URL.
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
      extract_tarball(tarball, rootfs_dir, @preserve_ownership_for_rootfs, force_system_tar: @use_system_tar_for_rootfs)
      FileUtils.mkdir_p(rootfs_dir / "workspace")
      FileUtils.mkdir_p(rootfs_dir / "var/lib")
      stage_sources if include_sources
      rootfs_dir
    end

    # Extract downloaded sources into /workspace inside the rootfs for offline builds.
    def stage_sources : Nil
      workspace_path = rootfs_dir / "workspace"
      download_sources.each do |archive|
        Log.info { "Extracting source archive #{archive} into #{workspace_path}" }
        extract_tarball(archive, workspace_path, @preserve_ownership_for_sources, force_system_tar: @use_system_tar_for_sources)
      end
    end

    private def bootstrap_source_branch : String
      ENV["BQ2_SOURCE_BRANCH"]? || DEFAULT_BQ2_BRANCH
    end

    # Define the multi-phase build in an LFS-inspired style:
    # 1. build a complete sysroot from sources using Alpine's seed environment
    # 2. validate the sysroot by using it as the toolchain when assembling a rootfs
    def phase_specs : Array(PhaseSpec)
      sysroot_prefix = "/opt/sysroot"
      rootfs_destdir = "/workspace/rootfs"
      musl_ld_path = "/etc/ld-musl-#{@architecture}.path"
      [
        PhaseSpec.new(
          name: "sysroot-from-alpine",
          description: "Build a self-contained sysroot using Alpine-hosted tools.",
          workspace: "/workspace",
          environment: "alpine-seed",
          install_prefix: sysroot_prefix,
          destdir: nil,
          env: sysroot_phase_env(sysroot_prefix),
          package_allowlist: nil,
          env_overrides: {
            "cmake" => {
              "CPPFLAGS" => "-I#{sysroot_prefix}/include",
              "LDFLAGS"  => "-L#{sysroot_prefix}/lib -static-libstdc++ -static-libgcc",
            },
          },
        ),
        PhaseSpec.new(
          name: "rootfs-from-sysroot",
          description: "Build a minimal rootfs using the newly built sysroot toolchain.",
          workspace: "/workspace",
          environment: "sysroot-toolchain",
          install_prefix: "/usr",
          destdir: rootfs_destdir,
          env: rootfs_phase_env(sysroot_prefix),
          package_allowlist: ["musl", "busybox"],
          extra_steps: [
            BuildStep.new(
              name: "musl-ld-path",
              strategy: "write-file",
              workdir: "/",
              configure_flags: [] of String,
              patches: [] of String,
              install_prefix: musl_ld_path,
              env: {
                "CONTENT" => "/lib:/usr/lib:/opt/sysroot/lib:/opt/sysroot/usr/lib\n",
              },
            ),
            BuildStep.new(
              name: "sysroot",
              strategy: "copy-tree",
              workdir: sysroot_prefix,
              configure_flags: [] of String,
              patches: [] of String,
              install_prefix: sysroot_prefix,
            ),
          ],
        ),
      ]
    end

    # Return environment variables for the rootfs validation phase.
    #
    # The rootfs phase is intended to use tools from the newly built sysroot,
    # but still execute in the bootstrap environment.
    private def rootfs_phase_env(sysroot_prefix : String) : Hash(String, String)
      {
        "PATH" => "#{sysroot_prefix}/bin:#{sysroot_prefix}/sbin:/usr/bin:/bin",
        "CC"   => "#{sysroot_prefix}/bin/clang",
        "CXX"  => "#{sysroot_prefix}/bin/clang++",
      }
    end

    # Return environment variables for the sysroot bootstrap phase.
    #
    # This ensures tools installed into the sysroot prefix (for example, CMake)
    # are immediately available to later steps in the same phase while ensuring
    # the seed rootfs uses Clang for all C/C++ compilation.
    private def sysroot_phase_env(sysroot_prefix : String) : Hash(String, String)
      {
        "PATH"     => "#{sysroot_prefix}/bin:#{sysroot_prefix}/sbin:/usr/bin:/bin",
        "CC"       => "/usr/bin/clang",
        "CXX"      => "/usr/bin/clang++",
        "CXXFLAGS" => "-static-libstdc++ -static-libgcc",
        "LDFLAGS"  => "-static-libstdc++ -static-libgcc",
      }
    end

    # Construct a phased build plan. The plan is serialized into the chroot so
    # it can be replayed by the coordinator runner.
    def build_plan : BuildPlan
      phases = phase_specs.map { |spec| build_phase(spec) }
      BuildPlan.new(phases)
    end

    # Persist the build plan JSON into the chroot at /var/lib/sysroot-build-plan.json.
    def write_plan(plan : BuildPlan = build_plan) : Path
      FileUtils.mkdir_p(self.plan_path.parent)
      File.write(self.plan_path, plan.to_json)
      self.plan_path
    end

    # Convert a PhaseSpec into a concrete BuildPhase with computed workdirs and
    # per-package build steps.
    private def build_phase(spec : PhaseSpec) : BuildPhase
      phase_packages = select_packages(spec.package_allowlist)
      steps = phase_packages.map do |pkg|
        build_directory = pkg.build_directory || strip_archive_extension(pkg.filename)
        build_root = File.join(spec.workspace, build_directory)
        BuildStep.new(
          name: pkg.name,
          strategy: pkg.strategy,
          workdir: build_root,
          configure_flags: configure_flags_for(pkg, spec),
          patches: patches_for(pkg, spec),
          env: spec.env_overrides[pkg.name]? || ({} of String => String),
        )
      end
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

    # Selects the packages to include in a phase.
    #
    # When *allowlist* is nil, includes all packages. Otherwise, it maps each
    # requested name to its PackageSpec and raises if any are missing.
    private def select_packages(allowlist : Array(String)?) : Array(PackageSpec)
      return packages unless allowlist
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

    # Produce a gzipped tarball of the prepared rootfs so it can be consumed by
    # tooling that expects a chroot-able environment.
    def generate_chroot(include_sources : Bool = true) : Path
      prepare_rootfs(include_sources: include_sources)
      write_plan
      rootfs_dir
    end

    # Generate a chroot tarball for the prepared rootfs.
    def generate_chroot_tarball(output : Path? = nil, include_sources : Bool = true) : Path
      generate_chroot(include_sources: include_sources)
      output ||= rootfs_dir.parent / "sysroot.tar.gz"
      FileUtils.mkdir_p(output.parent) if output.parent
      write_tar_gz(rootfs_dir, output)
      chown_tarball_to_sudo_user(output)
      output
    end

    # Generate a chroot tarball from an already-prepared rootfs.
    #
    # This does not regenerate the rootfs or rewrite the build plan; it only
    # packages the existing `rootfs_dir` into a tarball. Raises when the rootfs
    # is missing the serialized build plan (i.e. `rootfs_ready?` is false).
    def write_chroot_tarball(output : Path? = nil) : Path
      raise "Rootfs is not prepared at #{rootfs_dir}" unless rootfs_ready?
      output ||= rootfs_dir.parent / "sysroot.tar.gz"
      FileUtils.mkdir_p(output.parent) if output.parent
      write_tar_gz(rootfs_dir, output)
      chown_tarball_to_sudo_user(output)
      output
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

    # Extract the tarball into the destination, honoring ownership rules.
    private def extract_tarball(path : Path, destination : Path, preserve_ownership : Bool, force_system_tar : Bool = false) : Nil
      FileUtils.mkdir_p(destination)
      return run_system_tar_extract(path, destination, preserve_ownership) if force_system_tar
      Extractor.new(path, destination, preserve_ownership, @owner_uid, @owner_gid).run
    end

    # Extract with system tar when a pure Crystal extraction is not desired.
    private def run_system_tar_extract(path : Path, destination : Path, preserve_ownership : Bool) : Nil
      args = ["-xf", path.to_s, "-C", destination.to_s]
      if preserve_ownership
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

    # Write a gzipped tarball with a pure Crystal implementation.
    private def write_tar_gz(source : Path, output : Path) : Nil
      TarWriter.write_gz(source, output)
    rescue ex
      Log.warn { "Falling back to system tar due to: #{ex.message}" }
      File.delete?(output)
      Log.info { "Running: tar -czf #{output} -C #{source} ." }
      status = Process.run("tar", ["-czf", output.to_s, "-C", source.to_s, "."])
      raise "Failed to create tarball with system tar" unless status.success?
    end

    # Placeholder for future build command materialization.
    private def build_commands_for(pkg : PackageSpec, sysroot_prefix : String) : Array(Array(String))
      # The builder remains data-only: embed strategy metadata and let the runner
      # translate into concrete commands.
      Array(Array(String)).new
    end

    # Minimal tar extractor/writer implemented in Crystal to avoid shelling out.
    private struct Extractor
      # Create a tar extractor for a single archive.
      def initialize(@archive : Path, @destination : Path, @preserve_ownership : Bool, @owner_uid : Int32?, @owner_gid : Int32?)
      end

      # Extract the archive contents into the destination.
      def run
        return if fallback_for_unhandled_compression?
        File.open(@archive) do |file|
          io = maybe_gzip(file)
          TarReader.new(io, @destination, @preserve_ownership, @owner_uid, @owner_gid).extract_all
        end
      end

      # Wrap gzip compressed archives in a gzip reader.
      private def maybe_gzip(io : IO) : IO
        if @archive.to_s.ends_with?(".gz")
          Compress::Gzip::Reader.new(io)
        else
          io
        end
      end

      # Use system tar for compression formats we do not decode in Crystal.
      private def fallback_for_unhandled_compression? : Bool
        if @archive.to_s.ends_with?(".tar.xz") || @archive.to_s.ends_with?(".tar.bz2")
          Log.warn { "Running: tar -xf #{@archive} -C #{@destination}" }
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
      MTIME_LENGTH    =  12
      TYPEFLAG_OFFSET = 156
      LINKNAME_OFFSET = 157
      LINKNAME_LENGTH = 100
      PREFIX_OFFSET   = 345
      PREFIX_LENGTH   = 155

      TYPE_DIRECTORY = '5'
      TYPE_SYMLINK   = '2'
      TYPE_HARDLINK  = '1'
      TYPE_FILE      = '\u0000'

      # Create a tar reader that writes entries into the destination.
      def initialize(@io : IO, @destination : Path, @preserve_ownership : Bool, @owner_uid : Int32?, @owner_gid : Int32?)
      end

      # Extract every entry in the tar stream.
      def extract_all
        deferred_dir_times = [] of Tuple(Path, Int64)
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
          mtime = octal_to_i(header[MTIME_OFFSET, MTIME_LENGTH])
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
            uid, gid = resolved_owner(header_uid, header_gid)
            apply_ownership(target, uid, gid)
            deferred_dir_times << {target, mtime}
            skip_padding(size)
            next
          end

          uid, gid = resolved_owner(header_uid, header_gid)
          case normalized_typeflag
          when TYPE_DIRECTORY # directory
            FileUtils.mkdir_p(target)
            File.chmod(target, header_mode(header))
            apply_ownership(target, uid, gid)
            deferred_dir_times << {target, mtime}
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
            apply_mtime(target, mtime)
          end

          skip_padding(size)
        end

        # Apply directory timestamps after extracting all children; otherwise,
        # subsequent file creation would clobber the directory mtime.
        deferred_dir_times.reverse_each do |(path, entry_mtime)|
          apply_mtime(path, entry_mtime)
        end
      end

      # Skip the next *size* bytes in the stream.
      private def skip_bytes(size : Int64)
        @io.skip(size) if size > 0
      end

      # Skip zero padding up to the next 512-byte boundary.
      private def skip_padding(size : Int64)
        remainder = size % HEADER_SIZE
        skip = remainder.zero? ? 0 : HEADER_SIZE - remainder
        @io.skip(skip) if skip > 0
      end

      # Write a file payload from the tar stream to disk.
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

      private def apply_mtime(path : Path, mtime : Int64)
        return if mtime <= 0
        time = Time.unix(mtime)
        File.utime(time, time, path)
      rescue ex
        Log.warn { "Failed to apply mtime to #{path}: #{ex.message}" }
      end

      # Resolve uid/gid ownership for an entry based on preservation settings.
      private def resolved_owner(header_uid : Int32, header_gid : Int32) : {Int32?, Int32?}
        return {nil, nil} unless @preserve_ownership
        {(@owner_uid || header_uid), (@owner_gid || header_gid)}
      end

      # Apply ownership metadata to a path when requested.
      private def apply_ownership(path : Path, uid : Int32?, gid : Int32?)
        return unless @preserve_ownership
        return unless uid || gid
        File.chown(path, uid || -1, gid || -1)
      rescue ex
        Log.warn { "Failed to apply ownership to #{path}: #{ex.message}" }
      end

      # Ensure a tar entry stays within the destination root.
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

      # Decode a NUL-terminated byte slice into a string.
      private def cstring(bytes : Bytes) : String
        String.new(bytes).split("\0", 2)[0].to_s
      end

      # Parse an octal-encoded integer from tar header bytes.
      private def octal_to_i(bytes : Bytes) : Int64
        cleaned = String.new(bytes).tr("\0", "").strip.gsub(/[^0-7]/, "")
        cleaned.empty? ? 0_i64 : cleaned.to_i64(8)
      end

      # Resolve a file mode from a tar header, defaulting to 0755.
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

      # Write a gzipped tarball for a directory tree.
      def self.write_gz(source : Path, output : Path)
        assert_paths_fit(source)
        File.open(output, "w") do |file|
          Compress::Gzip::Writer.open(file) do |gzip|
            writer = new(gzip, source)
            writer.write_all
          end
        end
      end

      # Create a tar writer rooted at a source directory.
      def initialize(@io : IO, @source : Path)
      end

      # Write every entry in the source tree to the tar stream.
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

      # Walk the directory tree and yield every entry with its metadata.
      private def walk(path : Path, &block : Path, File::Info ->)
        Dir.children(path).each do |child|
          entry = path / child
          stat = File.info(entry, follow_symlinks: false)
          yield entry, stat
          walk(entry, &block) if stat.directory?
        end
      end

      # Write a tar entry, emitting PAX headers for long names if needed.
      private def write_entry(name : String, size : Int64, stat : File::Info, typeflag : Char, linkname : String = "")
        if name.bytesize > 99 || linkname.bytesize > 99
          write_pax_header(name, linkname, stat)
        end
        header_name = header_name_for(name)
        header_linkname = header_name_for(linkname)
        write_header(header_name, size, stat, typeflag, header_linkname)
      end

      # Emit a PAX extended header for long path or link names.
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

      # Format a single PAX record with a correct length prefix.
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

      # Generate a deterministic PAX header filename based on the entry name.
      private def pax_header_name(name : String) : String
        digest = Digest::CRC32.new
        digest.update(name)
        "PaxHeaders.0/#{digest.final.hexstring}"
      end

      # Return a tar header-safe name, truncating when required.
      private def header_name_for(name : String) : String
        return name if name.bytesize <= 99
        base = File.basename(name)
        return base if base.bytesize <= 99
        base.byte_slice(0, 99)
      end

      # Write a tar header for the provided entry.
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

      # Write a NUL-terminated string into a tar header field.
      private def write_string(buffer : Bytes, offset : Int32, length : Int32, value : String)
        slice = buffer[offset, length]
        slice.fill(0u8)
        str = value.byte_slice(0, length - 1)
        slice_part = slice[0, str.bytesize]
        slice_part.copy_from(str.to_slice)
      end

      # Write an octal integer into a tar header field.
      private def write_octal(buffer : Bytes, offset : Int32, length : Int32, value : Int64)
        str = value.to_s(8)
        padded = str.rjust(length - 1, '0')
        slice = buffer[offset, length - 1]
        slice.copy_from(padded.to_slice)
        buffer[offset + length - 1] = 0u8
      end

      # Calculate the tar header checksum.
      private def checksum(header : Bytes) : Int64
        temp = header.dup
        (CHECKSUM_OFFSET...(CHECKSUM_OFFSET + CHECKSUM_LENGTH)).each { |i| temp[i] = 32u8 }
        temp.sum(&.to_i64)
      end

      # Pad the tar stream to the next header boundary.
      private def pad_file(size : Int64)
        remainder = size % HEADER_SIZE
        pad = remainder.zero? ? 0 : HEADER_SIZE - remainder
        @io.write(Bytes.new(pad, 0)) if pad > 0
      end

      # Ensure all entries can fit in the tar header naming limits.
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
  end
end
