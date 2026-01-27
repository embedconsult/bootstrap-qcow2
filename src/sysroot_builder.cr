require "digest/crc32"
require "digest/sha256"
require "file_utils"
require "http/client"
require "json"
require "log"
require "path"
require "uri"
require "./build_plan"
require "./build_plan_utils"
require "./cli"
require "./sysroot_runner"
require "./tarball"

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
  class SysrootBuilder < CLI
    {% if flag?(:x86_64) %}
      DEFAULT_ARCH = "x86_64"
    {% elsif flag?(:aarch64) %}
      DEFAULT_ARCH = "aarch64"
    {% else %}
      DEFAULT_ARCH = "aarch64"
    {% end %}
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
    DEFAULT_FOSSIL        = "2.25"
    DEFAULT_GIT           = "2.45.2"
    DEFAULT_CRYSTAL       = "1.18.2"
    DEFAULT_BQ2           = "0.0.7"
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
                   @base_rootfs_path : Path? = nil,
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
      bootstrap_repo_dir = "/workspace/bootstrap-qcow2-#{bootstrap_source_version}"
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
        PackageSpec.new("libressl", DEFAULT_LIBRESSL, URI.parse("https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-#{DEFAULT_LIBRESSL}.tar.gz"), phases: ["sysroot-from-alpine", "system-from-sysroot"]),
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
        PackageSpec.new("libatomic_ops", DEFAULT_LIBATOMIC_OPS, URI.parse("https://github.com/ivmai/libatomic_ops/releases/download/v#{DEFAULT_LIBATOMIC_OPS}/libatomic_ops-#{DEFAULT_LIBATOMIC_OPS}.tar.gz"), phases: ["sysroot-from-alpine", "system-from-sysroot"]),
        PackageSpec.new(
          "llvm-project",
          DEFAULT_LLVM_VER,
          URI.parse("https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-#{DEFAULT_LLVM_VER}.tar.gz"),
          strategy: "llvm-libcxx",
          configure_flags: [
            "-DCMAKE_BUILD_TYPE=Release",
            "-DLLVM_TARGETS_TO_BUILD=AArch64",
            "-DLLVM_HOST_TRIPLE=#{sysroot_triple}",
            "-DLLVM_DEFAULT_TARGET_TRIPLE=#{sysroot_triple}",
            "-DLLVM_ENABLE_PROJECTS=clang;lld;compiler-rt",
            "-DLLVM_ENABLE_RUNTIMES=libunwind;libcxxabi;libcxx",
            "-DLLVM_ENABLE_LIBCXX=ON",
            "-DLLVM_INCLUDE_TOOLS=ON",
            "-DLLVM_BUILD_TOOLS=ON",
            "-DLLVM_INCLUDE_UTILS=OFF",
            "-DLLVM_INSTALL_UTILS=OFF",
            "-DLLVM_TOOL_BUGPOINT_BUILD=OFF",
            "-DLLVM_TOOL_BUGPOINT_PASSES_BUILD=OFF",
            "-DLLVM_TOOL_DSYMUTIL_BUILD=OFF",
            "-DLLVM_TOOL_DXIL_DIS_BUILD=OFF",
            "-DLLVM_TOOL_GOLD_BUILD=OFF",
            "-DLLVM_TOOL_LLC_BUILD=OFF",
            "-DLLVM_TOOL_LLI_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_AS_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_AS_FUZZER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_BCANALYZER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_C_TEST_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_CAT_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_CFI_VERIFY_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_COV_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_CVTRES_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_CXXDUMP_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_CXXFILT_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_CXXMAP_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_DEBUGINFO_ANALYZER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_DEBUGINFOD_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_DEBUGINFOD_FIND_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_DIFF_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_DIS_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_DIS_FUZZER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_DLANG_DEMANGLE_FUZZER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_DRIVER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_DWARFDUMP_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_DWARFUTIL_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_DWP_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_EXEGESIS_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_EXTRACT_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_GSYMUTIL_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_IFS_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_ISEL_FUZZER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_ITANIUM_DEMANGLE_FUZZER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_JITLINK_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_JITLISTENER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_LIBTOOL_DARWIN_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_LINK_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_LIPO_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_LTO_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_LTO2_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_MC_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_MC_ASSEMBLE_FUZZER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_MC_DISASSEMBLE_FUZZER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_MCA_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_MICROSOFT_DEMANGLE_FUZZER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_ML_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_MODEXTRACT_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_MT_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_OBJCOPY_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_OBJDUMP_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_OPT_FUZZER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_OPT_REPORT_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_PDBUTIL_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_PROFDATA_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_PROFGEN_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_RC_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_READOBJ_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_READTAPI_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_REDUCE_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_REMARKUTIL_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_RTDYLD_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_RUST_DEMANGLE_FUZZER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_SHLIB_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_SIM_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_SIZE_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_SPECIAL_CASE_LIST_FUZZER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_SPLIT_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_STRESS_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_STRINGS_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_SYMBOLIZER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_TLI_CHECKER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_UNDNAME_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_XRAY_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_YAML_NUMERIC_PARSER_FUZZER_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_YAML_PARSER_FUZZER_BUILD=OFF",
            "-DLLVM_TOOL_LTO_BUILD=OFF",
            "-DLLVM_TOOL_OBJ2YAML_BUILD=OFF",
            "-DLLVM_TOOL_OPT_BUILD=OFF",
            "-DLLVM_TOOL_OPT_VIEWER_BUILD=OFF",
            "-DLLVM_TOOL_REMARKS_SHLIB_BUILD=OFF",
            "-DLLVM_TOOL_SANCOV_BUILD=OFF",
            "-DLLVM_TOOL_SANSTATS_BUILD=OFF",
            "-DLLVM_TOOL_SPIRV_TOOLS_BUILD=OFF",
            "-DLLVM_TOOL_VERIFY_USELISTORDER_BUILD=OFF",
            "-DLLVM_TOOL_VFABI_DEMANGLE_FUZZER_BUILD=OFF",
            "-DLLVM_TOOL_XCODE_TOOLCHAIN_BUILD=OFF",
            "-DLLVM_TOOL_YAML2OBJ_BUILD=OFF",
            "-DLLVM_TOOL_LLVM_AR_BUILD=ON",
            "-DLLVM_TOOL_LLVM_NM_BUILD=ON",
            "-DLLVM_TOOL_LLVM_RANLIB_BUILD=ON",
            "-DLLVM_TOOL_LLVM_STRIP_BUILD=ON",
            "-DLLVM_TOOL_LLVM_CONFIG_BUILD=ON",
            "-DLLVM_INCLUDE_TESTS=OFF",
            "-DLLVM_INCLUDE_EXAMPLES=OFF",
            "-DLLVM_INCLUDE_BENCHMARKS=OFF",
            "-DLLVM_BUILD_DOCS=OFF",
            "-DLLVM_ENABLE_DOXYGEN=OFF",
            "-DLLVM_ENABLE_SPHINX=OFF",
            "-DCLANG_BUILD_DOCS=OFF",
            "-DCLANG_ENABLE_STATIC_ANALYZER=OFF",
            "-DCLANG_ENABLE_ARCMT=OFF",
            "-DLLVM_ENABLE_TERMINFO=OFF",
            "-DLLVM_ENABLE_PYTHON=OFF",
            "-DLLVM_ENABLE_PIC=OFF",
            "-DCOMPILER_RT_BUILD_BUILTINS=ON",
            "-DCOMPILER_RT_BUILD_CRT=ON",
            "-DCOMPILER_RT_INCLUDE_TESTS=OFF",
            "-DCOMPILER_RT_BUILD_SANITIZERS=OFF",
            "-DCOMPILER_RT_BUILD_XRAY=OFF",
            "-DCOMPILER_RT_BUILD_LIBFUZZER=OFF",
            "-DCOMPILER_RT_BUILD_PROFILE=OFF",
            "-DCOMPILER_RT_BUILD_MEMPROF=OFF",
            "-DLIBUNWIND_USE_COMPILER_RT=ON",
            "-DLIBUNWIND_ENABLE_SHARED=OFF",
            "-DLIBUNWIND_ENABLE_STATIC=ON",
            "-DLIBUNWIND_INCLUDE_TESTS=OFF",
            "-DLIBCXX_HAS_MUSL_LIBC=ON",
            "-DLIBCXX_USE_COMPILER_RT=ON",
            "-DLIBCXX_ENABLE_SHARED=OFF",
            "-DLIBCXX_ENABLE_STATIC=ON",
            "-DLIBCXX_INCLUDE_TESTS=OFF",
            "-DLIBCXXABI_USE_COMPILER_RT=ON",
            "-DLIBCXXABI_USE_LLVM_UNWINDER=ON",
            "-DLIBCXXABI_ENABLE_SHARED=OFF",
            "-DLIBCXXABI_ENABLE_STATIC=ON",
            "-DLIBCXXABI_INCLUDE_TESTS=OFF",
          ],
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
        PackageSpec.new("bdwgc", DEFAULT_BDWGC, URI.parse("https://github.com/ivmai/bdwgc/releases/download/v#{DEFAULT_BDWGC}/gc-#{DEFAULT_BDWGC}.tar.gz"), build_directory: "gc-#{DEFAULT_BDWGC}", phases: ["sysroot-from-alpine", "system-from-sysroot"]),
        PackageSpec.new("pcre2", DEFAULT_PCRE2, URI.parse("https://github.com/PhilipHazel/pcre2/releases/download/pcre2-#{DEFAULT_PCRE2}/pcre2-#{DEFAULT_PCRE2}.tar.gz"), phases: ["sysroot-from-alpine", "system-from-sysroot"]),
        PackageSpec.new("gmp", DEFAULT_GMP, URI.parse("https://ftp.gnu.org/gnu/gmp/gmp-#{DEFAULT_GMP}.tar.gz"), phases: ["sysroot-from-alpine", "system-from-sysroot"]),
        PackageSpec.new("libiconv", DEFAULT_LIBICONV, URI.parse("https://ftp.gnu.org/pub/gnu/libiconv/libiconv-#{DEFAULT_LIBICONV}.tar.gz"), phases: ["sysroot-from-alpine", "system-from-sysroot"]),
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
          phases: ["sysroot-from-alpine", "system-from-sysroot"],
        ),
        PackageSpec.new("libyaml", DEFAULT_LIBYAML, URI.parse("https://pyyaml.org/download/libyaml/yaml-#{DEFAULT_LIBYAML}.tar.gz"), build_directory: "yaml-#{DEFAULT_LIBYAML}", phases: ["sysroot-from-alpine", "system-from-sysroot"]),
        PackageSpec.new("libffi", DEFAULT_LIBFFI, URI.parse("https://github.com/libffi/libffi/releases/download/v#{DEFAULT_LIBFFI}/libffi-#{DEFAULT_LIBFFI}.tar.gz"), phases: ["sysroot-from-alpine", "system-from-sysroot"]),
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
          "fossil",
          DEFAULT_FOSSIL,
          URI.parse("https://www.fossil-scm.org/home/tarball/fossil-src-#{DEFAULT_FOSSIL}.tar.gz"),
          phases: ["tools-from-system"],
        ),
        PackageSpec.new(
          "git",
          DEFAULT_GIT,
          URI.parse("https://www.kernel.org/pub/software/scm/git/git-#{DEFAULT_GIT}.tar.gz"),
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
    # * creates workspace/var/lib directories (/workspace holds extracted sources,
    #   /var/lib holds the build plan)
    # * stages the coordinator entrypoints
    # Returns the rootfs path on success.
    # Invoked by `generate_chroot_tarball` and can also be used directly in callers.
    def prepare_rootfs(base_rootfs : PackageSpec = base_rootfs_spec, include_sources : Bool = true) : Path
      Log.info { "Preparing rootfs at #{rootfs_dir} (include_sources=#{include_sources})" }
      FileUtils.rm_rf(rootfs_dir)
      FileUtils.mkdir_p(rootfs_dir)

      tarball = resolve_base_rootfs_tarball(base_rootfs)
      Log.info { "Extracting base rootfs from #{tarball}" }
      Tarball.extract(tarball, rootfs_dir, @preserve_ownership_for_rootfs, @owner_uid, @owner_gid, force_system_tar: @use_system_tar_for_rootfs)
      FileUtils.mkdir_p(rootfs_dir / "workspace")
      FileUtils.mkdir_p(rootfs_dir / "var/lib")
      stage_sources if include_sources
      rootfs_dir
    end

    # Extract downloaded sources into /workspace inside the rootfs for offline builds.
    def stage_sources : Nil
      workspace_path = rootfs_dir / "workspace"
      stage_sources(skip_existing: false, workspace_path: workspace_path)
    end

    # Extract downloaded sources into /workspace inside the rootfs for offline builds.
    #
    # When *skip_existing* is true, source archives are only extracted when the
    # expected build directory does not already exist.
    def stage_sources(skip_existing : Bool, workspace_path : Path = rootfs_dir / "workspace") : Nil
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
            Log.info { "Skipping already-staged source directory #{build_root}" }
            next
          end
          Log.info { "Extracting source archive #{archive} into #{workspace_path}" }
          Tarball.extract(archive, workspace_path, @preserve_ownership_for_sources, @owner_uid, @owner_gid, force_system_tar: @use_system_tar_for_sources)
        end
      end
    end

    private def bootstrap_source_version : String
      ENV["BQ2_SOURCE_BRANCH"]? || DEFAULT_BQ2
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

    # Define the multi-phase build in an LFS-inspired style:
    # 1. build a complete sysroot from sources using Alpine's seed environment
    # 2. validate the sysroot by using it as the toolchain when assembling a rootfs
    #
    # Phase environments:
    # - sysroot-from-alpine: runs in the Alpine seed rootfs (host tools).
    # - rootfs-from-sysroot: runs inside the workspace rootfs and seeds /etc plus /opt/sysroot.
    # - system-from-sysroot/tools-from-system/finalize-rootfs: run inside the workspace rootfs,
    #   prefer /usr/bin, and rely on musl's /etc/ld-musl-<arch>.path for runtime lookup.
    def phase_specs : Array(PhaseSpec)
      bootstrap_repo_dir = "/workspace/bootstrap-qcow2-#{bootstrap_source_version}"
      sysroot_prefix = "/opt/sysroot"
      rootfs_destdir = "/workspace/rootfs"
      rootfs_tarball = "/workspace/bq2-rootfs-#{bootstrap_source_version}.tar.gz"
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
      cmake_c_flags = "--target=#{sysroot_triple} --rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld"
      cmake_cxx_flags = "#{cmake_c_flags} -nostdinc++ -isystem #{libcxx_include} -isystem #{libcxx_target_include} -nostdlib++ -stdlib=libc++ -L#{libcxx_libdir} -L#{sysroot_prefix}/lib -Wl,--start-group -lc++ -lc++abi -lunwind -Wl,--end-group"
      cmake_archive_create = "#{sysroot_prefix}/bin/llvm-ar qc <TARGET> <OBJECTS>"
      cmake_archive_append = "#{sysroot_prefix}/bin/llvm-ar q <TARGET> <OBJECTS>"
      cmake_archive_finish = "#{sysroot_prefix}/bin/llvm-ranlib <TARGET>"
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
          name: "sysroot-from-alpine",
          description: "Build a self-contained sysroot using Alpine-hosted tools.",
          workspace: "/workspace",
          environment: "alpine-seed",
          install_prefix: sysroot_prefix,
          destdir: nil,
          env: sysroot_env,
          package_allowlist: nil,
          env_overrides: {
            "cmake" => {
              "CPPFLAGS" => "-I#{sysroot_prefix}/include -Wdeprecated-literal-operator",
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
            },
            "shards" => {
              "SHARDS_CACHE_PATH" => "/tmp/shards-cache",
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
          workspace: "/workspace",
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
            BuildStep.new(
              name: "musl-ld-path",
              strategy: "write-file",
              workdir: "/",
              configure_flags: [] of String,
              patches: [] of String,
              install_prefix: musl_ld_path,
              env: {
                "CONTENT" => "/lib:/usr/lib:/opt/sysroot/lib:/opt/sysroot/lib/#{sysroot_triple}:/opt/sysroot/usr/lib\n",
              },
            ),
            BuildStep.new(
              name: "prepare-rootfs",
              strategy: "prepare-rootfs",
              workdir: "/",
              configure_flags: [] of String,
              patches: [] of String,
              install_prefix: "/",
              env: {
                "FILE_0_PATH"    => "/etc/os-release",
                "FILE_0_CONTENT" => os_release_content,
                "FILE_1_PATH"    => "/etc/profile",
                "FILE_1_CONTENT" => profile_content,
                "FILE_2_PATH"    => "/etc/resolv.conf",
                "FILE_2_CONTENT" => resolv_conf_content,
                "FILE_3_PATH"    => "/etc/hosts",
                "FILE_3_CONTENT" => hosts_content,
                "FILE_4_PATH"    => "/etc/ssl/certs/ca-certificates.crt",
                "FILE_4_CONTENT" => rootfs_ca_bundle_content,
                "FILE_5_PATH"    => "/.bq2-rootfs",
                "FILE_5_CONTENT" => "bq2-rootfs\n",
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
        PhaseSpec.new(
          name: "system-from-sysroot",
          description: "Rebuild sysroot packages into /usr inside the new rootfs (prefix-free).",
          workspace: "/workspace",
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
            BuildStep.new(
              name: "bq2-symlinks",
              strategy: "symlink",
              workdir: "/",
              configure_flags: [] of String,
              patches: [] of String,
              install_prefix: "/",
              env: {
                "LINK_0_SRC"  => "bq2",
                "LINK_0_DEST" => "/usr/bin/curl",
                "LINK_1_SRC"  => "bq2",
                "LINK_1_DEST" => "/usr/bin/git-remote-https",
                "LINK_2_SRC"  => "bq2",
                "LINK_2_DEST" => "/usr/bin/pkg-config",
              },
            ),
          ],
        ),
        PhaseSpec.new(
          name: "tools-from-system",
          description: "Build additional developer tools inside the new rootfs.",
          workspace: "/workspace",
          environment: "rootfs-system",
          install_prefix: "/usr",
          destdir: nil,
          env: rootfs_env,
          package_allowlist: nil,
          env_overrides: {
            "git" => {
              "MAKEFLAGS"  => "-e",
              "NO_DOCS"    => "1",
              "NO_GETTEXT" => "1",
              "NO_TCLTK"   => "1",
            },
          },
        ),
        PhaseSpec.new(
          name: "finalize-rootfs",
          description: "Strip the sysroot prefix and emit a prefix-free rootfs tarball.",
          workspace: "/workspace",
          environment: "rootfs-finalize",
          install_prefix: "/usr",
          destdir: rootfs_destdir,
          env: rootfs_phase_env(sysroot_prefix),
          package_allowlist: [] of String,
          extra_steps: [
            BuildStep.new(
              name: "strip-sysroot",
              strategy: "remove-tree",
              workdir: "/",
              configure_flags: [] of String,
              patches: [] of String,
              install_prefix: sysroot_prefix,
            ),
            BuildStep.new(
              name: "musl-ld-path-final",
              strategy: "write-file",
              workdir: "/",
              configure_flags: [] of String,
              patches: [] of String,
              install_prefix: musl_ld_path,
              env: {
                "CONTENT" => "/lib:/usr/lib\n",
              },
            ),
            BuildStep.new(
              name: "rootfs-tarball",
              strategy: "tarball",
              workdir: "/",
              configure_flags: [] of String,
              patches: [] of String,
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
      cc = "#{sysroot_prefix}/bin/clang --target=#{target} --rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld"
      cxx = "#{sysroot_prefix}/bin/clang++ --target=#{target} --rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld -nostdinc++ -isystem #{libcxx_include} -isystem #{libcxx_target_include} -nostdlib++ -stdlib=libc++ -L#{libcxx_libdir} -L#{sysroot_prefix}/lib -Wl,--start-group -lc++ -lc++abi -lunwind -Wl,--end-group"
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
        "PATH"            => "#{sysroot_prefix}/bin:#{sysroot_prefix}/sbin:/usr/bin:/bin",
        "CC"              => "/usr/bin/clang",
        "CXX"             => "/usr/bin/clang++",
        "LD_LIBRARY_PATH" => "#{sysroot_prefix}/lib",
      }
    end

    # Construct a phased build plan. The plan is serialized into the chroot so
    # it can be replayed by the coordinator runner.
    def build_plan : BuildPlan
      phases = phase_specs.map { |spec| build_phase(spec) }.reject(&.steps.empty?)
      BuildPlan.new(phases)
    end

    # Persist the build plan JSON into the chroot at /var/lib/sysroot-build-plan.json.
    def write_plan(plan : BuildPlan = build_plan) : Path
      FileUtils.mkdir_p(self.plan_path.parent)
      File.write(self.plan_path, plan.to_pretty_json)
      self.plan_path
    end

    # Convert a PhaseSpec into a concrete BuildPhase with computed workdirs and
    # per-package build steps.
    private def build_phase(spec : PhaseSpec) : BuildPhase
      phase_packages = select_packages(spec.name, spec.package_allowlist)
      steps = phase_packages.map do |pkg|
        build_directory = pkg.build_directory || strip_archive_extension(pkg.filename)
        build_root = File.join(spec.workspace, build_directory)
        build_dir = pkg.build_dir
        if build_dir
          build_dir = build_dir.gsub("%{phase}", spec.name).gsub("%{name}", pkg.name)
          build_dir = build_dir.starts_with?("/") ? build_dir : File.join(spec.workspace, build_dir)
        end
        BuildStep.new(
          name: pkg.name,
          strategy: pkg.strategy,
          workdir: build_root,
          configure_flags: configure_flags_for(pkg, spec),
          patches: patches_for(pkg, spec),
          env: spec.env_overrides[pkg.name]? || ({} of String => String),
          build_dir: build_dir,
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
      Tarball.write_gz(rootfs_dir, output)
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
      Tarball.write_gz(rootfs_dir, output)
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
      output = Path["sysroot.tar.gz"]
      workspace = Path["data/sysroot"]
      architecture = SysrootBuilder::DEFAULT_ARCH
      branch = SysrootBuilder::DEFAULT_BRANCH
      base_version = SysrootBuilder::DEFAULT_BASE_VERSION
      base_rootfs_path : Path? = nil
      include_sources = true
      use_system_tar_for_sources = false
      use_system_tar_for_rootfs = false
      preserve_ownership_for_sources = false
      preserve_ownership_for_rootfs = false
      owner_uid = nil
      owner_gid = nil
      write_tarball = true
      reuse_rootfs = false
      refresh_plan = false
      restage_sources = false

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-builder [options]") do |p|
        p.on("-o OUTPUT", "--output=OUTPUT", "Target sysroot tarball (default: #{output})") { |val| output = Path[val] }
        p.on("-w DIR", "--workspace=DIR", "Workspace directory (default: #{workspace})") { |val| workspace = Path[val] }
        p.on("-a ARCH", "--arch=ARCH", "Target architecture (default: #{architecture})") { |val| architecture = val }
        p.on("-b BRANCH", "--branch=BRANCH", "Source branch/release tag (default: #{branch})") { |val| branch = val }
        p.on("-v VERSION", "--base-version=VERSION", "Base rootfs version/tag (default: #{base_version})") { |val| base_version = val }
        p.on("--base-rootfs PATH", "Use a local rootfs tarball instead of downloading the Alpine minirootfs") { |val| base_rootfs_path = Path[val].expand }
        p.on("--skip-sources", "Skip staging source archives into the rootfs") { include_sources = false }
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
        p.on("--no-tarball", "Prepare the chroot tree without writing a tarball") { write_tarball = false }
        p.on("--reuse-rootfs", "Reuse an existing prepared rootfs when present") { reuse_rootfs = true }
        p.on("--refresh-plan", "Rewrite the build plan inside an existing rootfs (requires --reuse-rootfs)") { refresh_plan = true }
        p.on("--restage-sources", "Extract missing sources into an existing rootfs /workspace (requires --reuse-rootfs)") { restage_sources = true }
      end
      return CLI.print_help(parser) if help

      Log.info { "Sysroot builder log level=#{Log.for("").level} (env-configured)" }
      builder = SysrootBuilder.new(
        workspace: workspace,
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

      if reuse_rootfs && builder.rootfs_ready?
        puts "Reusing existing rootfs at #{builder.rootfs_dir}"
        puts "Build plan found at #{builder.plan_path} (iteration state is maintained by sysroot-runner)"
        if include_sources && restage_sources
          builder.stage_sources(skip_existing: true)
          puts "Staged missing sources into #{builder.rootfs_dir}/workspace"
        end
        if refresh_plan
          builder.write_plan
          puts "Refreshed build plan at #{builder.plan_path}"
        end
        if write_tarball
          builder.write_chroot_tarball(output)
          puts "Generated sysroot tarball at #{output}"
        end
        return 0
      end

      if write_tarball
        builder.generate_chroot_tarball(output, include_sources: include_sources)
        puts "Generated sysroot tarball at #{output}"
      else
        chroot_path = builder.generate_chroot(include_sources: include_sources)
        puts "Prepared chroot directory at #{chroot_path}"
      end
      0
    end

    # Writes a freshly generated build plan JSON.
    private def self.run_plan_write(args : Array(String)) : Int32
      output = SysrootRunner::DEFAULT_PLAN_PATH
      workspace_root = Bootstrap::BuildPlanUtils::DEFAULT_WORKSPACE_ROOT
      force = false
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-plan-write [options]") do |p|
        p.on("--output PATH", "Write the plan to PATH (default: #{SysrootRunner::DEFAULT_PLAN_PATH})") { |path| output = path }
        p.on("--workspace-root PATH", "Rewrite plan workdirs rooted at /workspace to PATH (default: #{workspace_root})") { |path| workspace_root = path }
        p.on("--force", "Overwrite an existing plan at the output path") { force = true }
      end
      return CLI.print_help(parser) if help

      if File.exists?(output) && !force
        STDERR.puts "Refusing to overwrite existing plan at #{output} (pass --force)"
        return 1
      end

      tmp_workspace = Path["/tmp/bq2-plan-write-#{Random::Secure.hex(4)}"]
      builder = SysrootBuilder.new(workspace: tmp_workspace)
      plan = builder.build_plan
      if workspace_root != Bootstrap::BuildPlanUtils::DEFAULT_WORKSPACE_ROOT
        plan = Bootstrap::BuildPlanUtils.rewrite_workspace_root(plan, workspace_root)
      end

      FileUtils.mkdir_p(File.dirname(output))
      File.write(output, plan.to_pretty_json)
      puts "Wrote build plan to #{output}"
      0
    end

    # Run the finalize-rootfs phase to emit a prefix-free rootfs tarball.
    private def self.run_sysroot_tarball(args : Array(String)) : Int32
      plan_path = SysrootRunner::DEFAULT_PLAN_PATH
      overrides_path : String? = nil
      use_default_overrides = true
      report_dir : String? = SysrootRunner::DEFAULT_REPORT_DIR
      state_path : String? = nil
      resume = true
      allow_outside_rootfs = false
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-tarball [options]") do |p|
        p.on("--plan PATH", "Read the build plan from PATH (default: #{SysrootRunner::DEFAULT_PLAN_PATH})") { |path| plan_path = path }
        p.on("--overrides PATH", "Apply runtime overrides JSON (default: #{SysrootRunner::DEFAULT_OVERRIDES_PATH} when using the default plan path)") do |path|
          overrides_path = path
          use_default_overrides = false
        end
        p.on("--no-overrides", "Disable runtime overrides") do
          overrides_path = nil
          use_default_overrides = false
        end
        p.on("--report-dir PATH", "Write failure reports to PATH (default: #{SysrootRunner::DEFAULT_REPORT_DIR})") { |path| report_dir = path }
        p.on("--no-report", "Disable failure report writing") { report_dir = nil }
        p.on("--state-path PATH", "Write runner state/bookmarks to PATH (default: #{SysrootRunner::DEFAULT_STATE_PATH} when using the default plan path)") { |path| state_path = path }
        p.on("--no-resume", "Disable resume/state tracking (useful when the default state path is not writable)") { resume = false }
        p.on("--allow-outside-rootfs", "Allow running rootfs-* phases outside the produced rootfs (requires destdir overrides)") { allow_outside_rootfs = true }
      end
      return CLI.print_help(parser) if help

      SysrootRunner.run_plan(
        plan_path,
        phase: "finalize-rootfs",
        overrides_path: overrides_path,
        use_default_overrides: use_default_overrides,
        report_dir: report_dir,
        state_path: state_path,
        resume: resume,
        allow_outside_rootfs: allow_outside_rootfs,
      )
      0
    end
  end
end
