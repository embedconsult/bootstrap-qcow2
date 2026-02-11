require "file_utils"
require "json"
require "log"
require "path"
require "process"
require "uri"
require "./build_plan"
require "./build_plan_overrides"
require "./cli"
require "./process_runner"
require "./alpine_setup"
require "./sysroot_build_state"
require "./sysroot_workspace"
require "./tarball"

module Bootstrap
  # SysrootBuilder prepares a chroot-able environment that can rebuild a
  # complete sysroot using source tarballs cached on the host. The default seed
  # uses Alpine’s minirootfs, but the seed rootfs, architecture, and package set
  # are intended to be swappable once self-hosted variants exist.
  #
  # Key expectations:
  # * No shell-based downloads: HTTP/Digest from Crystal stdlib only.
  # * Deterministic source handling: every tarball is cached locally with CRC32 +
  #   SHA256 bookkeeping for reuse and verification.
  # * bootstrap-qcow2 source is fetched as a tarball and staged into the inner
  #   rootfs workspace (/workspace inside the inner rootfs).
  #
  # Usage references:
  # * CLI entrypoints: `bq2 sysroot-builder` and `bq2 sysroot-plan-write`,
  #   (see `self.run`, `help_entries`, and README).
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
    DEFAULT_ROOTFS_SEED    = "Alpine"
    DEFAULT_ROOTFS_BRANCH  = "v3.23"
    DEFAULT_ROOTFS_VERSION = "3.23.2"
    DEFAULT_LLVM_VER       = "18.1.7"
    DEFAULT_LIBRESSL       = "3.8.2"
    DEFAULT_BUSYBOX        = "1.36.1"
    DEFAULT_MUSL           = "1.2.5"
    DEFAULT_CMAKE          = "3.29.6"
    DEFAULT_SHARDS         = "0.18.0"
    DEFAULT_M4             = "1.4.19"
    DEFAULT_GNU_MAKE       = "4.4.1"
    DEFAULT_ZLIB           = "1.3.1"
    DEFAULT_LINUX          = "6.12.38"
    DEFAULT_PCRE2          = "10.44"
    DEFAULT_LIBATOMIC_OPS  = "7.8.2"
    DEFAULT_GMP            = "6.3.0"
    DEFAULT_LIBICONV       = "1.17"
    DEFAULT_LIBXML2        = "2.12.7"
    DEFAULT_LIBYAML        = "0.2.5"
    DEFAULT_LIBFFI         = "3.4.6"
    DEFAULT_BDWGC          = "8.2.6"
    DEFAULT_SQLITE         = "3460000" # Source: https://www.sqlite.org/2024/sqlite-autoconf-3460000.tar.gz (SQLite 3.46.0).
    DEFAULT_FOSSIL         = "2.25"
    DEFAULT_GIT            = "2.45.2"
    DEFAULT_CRYSTAL        = "1.19.1"
    SHARDS_CACHE_DIR       = "/tmp/.shards-cache" # Cache directory name for prefetched shards dependencies.
    # Source: https://curl.se/ca/cacert.pem (Mozilla CA certificate bundle).
    CA_BUNDLE_PEM      = {{ read_file("#{__DIR__}/../data/ca-bundle/ca-certificates.crt") }}
    DEFAULT_NAMESERVER = "8.8.8.8"

    getter workspace : SysrootWorkspace
    @architecture : String
    @seed : String

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

    # PhaseSpec provides the base entries for a BuildPhase with additional elements that
    # allow for generating multiple BuildPhase entries modified for the same PackageSpec
    # used in different phases.
    record PhaseSpec,
      phase : BuildPhase,
      workdir : String?,
      package_allowlist : Array(String)? = nil,
      pre_steps : Array(BuildStep) = [] of BuildStep,
      extra_steps : Array(BuildStep) = [] of BuildStep,
      env_overrides : Hash(String, Hash(String, String)) = {} of String => Hash(String, String),
      configure_overrides : Hash(String, Array(String)) = {} of String => Array(String),
      patch_overrides : Hash(String, Array(String)) = {} of String => Array(String)

    # Create a sysroot builder in workspace.
    def initialize(workspace : SysrootWorkspace | Nil = nil,
                   @architecture : String = DEFAULT_ARCH,
                   @seed : String = DEFAULT_ROOTFS_SEED)
      @workspace = workspace || SysrootWorkspace.create
    end

    # Host workspace path for the builder.
    def host_workdir : Path
      @workspace.host_workdir.not_nil!
    end

    # Cache directory for checksum metadata.
    def cache_dir : Path
      host_workdir / "cache"
    end

    # Directory for checksum files keyed by package.
    def checksum_dir : Path
      cache_dir / "checksums"
    end

    # Directory where source tarballs are stored.
    def sources_dir : Path
      host_workdir / "sources"
    end

    # Path to the outer rootfs directory on the host.
    def outer_rootfs_dir : Path
      @workspace.seed_rootfs_path.not_nil!
    end

    # Path to the workspace directory inside the inner rootfs.
    def inner_rootfs_workspace_dir : Path
      @workspace.workspace_path
    end

    # Build a PackageSpec pointing at the base rootfs tarball for the configured
    # architecture. The checksum URL is derived from the upstream naming
    # convention when available.
    def seed_rootfs_spec : PackageSpec
      if @seed == "Alpine"
        file = "alpine-minirootfs-#{DEFAULT_ROOTFS_VERSION}-#{@architecture}.tar.gz"
        url = URI.parse("https://dl-cdn.alpinelinux.org/alpine/#{DEFAULT_ROOTFS_BRANCH}/releases/#{@architecture}/#{file}")
        checksum_url = URI.parse("#{url}.sha256") rescue nil
        PackageSpec.new("bootstrap-rootfs", "#{DEFAULT_ROOTFS_VERSION}", url, nil, checksum_url)
      else
        raise "Not currently defined seed: #{@seed}"
      end
    end

    # Return true when a serialized plan exists in the workspace.
    def rootfs_ready? : Bool
      build_state = SysrootBuildState.new(workspace: @workspace)
      File.exists?(build_state.plan_path)
    end

    def bootstrap_repo_dir
      "#{@workspace.workspace_path}/bootstrap-qcow2-#{bootstrap_source_version}"
    end

    # Declarative list of upstream sources that should populate the sysroot.
    # Each PackageSpec can carry optional configure flags or a custom build
    # directory name when upstream archives use non-standard layouts.
    def packages : Array(PackageSpec)
      sysroot_triple = sysroot_target_triple
      [
        PackageSpec.new("m4",
          DEFAULT_M4,
          URI.parse("https://ftp.gnu.org/gnu/m4/m4-#{DEFAULT_M4}.tar.gz"),
          phases: ["sysroot-from-alpine", "system-from-sysroot"]
        ),
        PackageSpec.new("musl",
          DEFAULT_MUSL,
          URI.parse("https://musl.libc.org/releases/musl-#{DEFAULT_MUSL}.tar.gz"),
          phases: ["sysroot-from-alpine", "rootfs-from-sysroot"]
        ),
        PackageSpec.new(
          "busybox",
          DEFAULT_BUSYBOX,
          URI.parse("https://github.com/mirror/busybox/archive/refs/tags/#{DEFAULT_BUSYBOX.tr(".", "_")}.tar.gz"),
          strategy: "busybox",
          patches: ["#{bootstrap_repo_dir}/patches/busybox-#{DEFAULT_BUSYBOX.tr(".", "_")}/tc-disable-cbq-when-missing-headers.patch"],
          phases: ["sysroot-from-alpine", "rootfs-from-sysroot"],
        ),
        PackageSpec.new("make", DEFAULT_GNU_MAKE, URI.parse("https://ftp.gnu.org/gnu/make/make-#{DEFAULT_GNU_MAKE}.tar.gz"), phases: ["sysroot-from-alpine", "system-from-sysroot"]),
        PackageSpec.new("zlib",
          DEFAULT_ZLIB,
          URI.parse("https://zlib.net/zlib-#{DEFAULT_ZLIB}.tar.gz"),
          phases: ["sysroot-from-alpine", "system-from-sysroot"],
          configure_flags: ["--shared"]
        ),
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

    def bootstrap_source_version : String
      ENV["BQ2_SOURCE_BRANCH"]? || Bootstrap::VERSION
    end

    # Return the expected rootfs tarball filename for the bootstrap source version.
    def rootfs_tarball_name : String
      "bq2-rootfs-#{bootstrap_source_version}.tar.gz"
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
      compiler_rt_arch = sysroot_triple.split("-").first
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
        "-DLLVM_ENABLE_LIBEDIT=OFF",
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
        "-DCOMPILER_RT_BUILD_STANDALONE_LIBATOMIC=ON",
        "-DCOMPILER_RT_LIBATOMIC_LINK_LIBS_#{compiler_rt_arch}=clang_rt.builtins-#{compiler_rt_arch};c",
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
    # Phases:
    # - host-setup: populate sources and seed the rootfs from the host.
    # - sysroot-from-alpine: build the sysroot using Alpine tools in the seed rootfs.
    # - rootfs-from-sysroot: build the minimal rootfs using the new sysroot toolchain.
    # - system-from-sysroot: build core system packages inside the new rootfs.
    # - tools-from-system: build developer tools inside the new rootfs.
    # - finalize-rootfs: strip /opt/sysroot and emit the tarball.
    #
    # Phase namespaces:
    # - host: runs on the host before entering any namespace.
    # - seed: runs in the Alpine seed rootfs (host tools).
    # - bq2: runs inside the bq2 rootfs, prefers /usr/bin, and relies on
    #   musl's /etc/ld-musl-<arch>.path for runtime lookup.
    def phase_specs : Array(PhaseSpec)
      sysroot_prefix = "/#{SysrootWorkspace::SYSROOT_DIR_NAME}"
      rootfs_tarball = "#{@workspace.workspace_path}/bq2-rootfs-#{bootstrap_source_version}.tar.gz"
      host_workdir = @workspace.host_workdir.not_nil!
      workspace_from_seed = SysrootWorkspace.workspace_from(SysrootWorkspace::Namespace::Seed, host_workdir).to_s
      workspace_from_bq2 = SysrootWorkspace.workspace_from(SysrootWorkspace::Namespace::BQ2, host_workdir).to_s
      bq2_from_seed = SysrootWorkspace.bq2_rootfs_from(SysrootWorkspace::Namespace::Seed, host_workdir).to_s
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
      llvm_major = DEFAULT_LLVM_VER.split(".").first
      compiler_rt_arch = sysroot_triple.split("-").first
      clang_rt_dir = "/usr/lib/clang/#{llvm_major}/lib/#{sysroot_triple}"
      clang_rt_atomic = "#{clang_rt_dir}/libclang_rt.atomic-#{compiler_rt_arch}.so"
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
      sysroot_ld_lib = "#{sysroot_prefix}/lib:#{sysroot_prefix}/lib/#{sysroot_triple}"
      system_from_sysroot_env = rootfs_env.dup
      existing_ld = system_from_sysroot_env["LD_LIBRARY_PATH"]?
      system_from_sysroot_env["LD_LIBRARY_PATH"] = existing_ld && !existing_ld.empty? ? "#{sysroot_ld_lib}:#{existing_ld}" : sysroot_ld_lib
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
        # Inputs: host repo workspace, source tarballs cache, seed rootfs spec.
        # Outputs: populated workspace sources, seed rootfs filesystem tree,
        #          build plan metadata under the workspace.
        PhaseSpec.new(
          BuildPhase.new(
            name: "host-setup",
            description: "Prepare cached sources and seed the rootfs from the host.",
            namespace: SysrootWorkspace::Namespace::Host.label,
            # install_prefix is unused in host-setup; steps provide explicit paths.
            install_prefix: "/",
            destdir: nil,
            env: host_setup_env,
          ),
          workdir: nil,
          package_allowlist: [] of String,
          extra_steps: host_setup_steps,
        ),
        # Inputs: seed rootfs from host-setup, downloaded sources.
        # Outputs: /opt/sysroot toolchain prefix (compiler, libc, build tools).
        PhaseSpec.new(
          BuildPhase.new(
            name: "sysroot-from-alpine",
            description: "Build a self-contained sysroot using Alpine-hosted tools.",
            namespace: SysrootWorkspace::Namespace::Seed.label,
            install_prefix: sysroot_prefix,
            destdir: nil,
            env: sysroot_env,
          ),
          workdir: workspace_from_seed,
          pre_steps: [
            write_file_step(
              "alpine-resolv-conf",
              "/etc/resolv.conf",
              rootfs_resolv_conf_content,
            ),
            apk_add_step(
              "alpine-apk-add",
              AlpineSetup::SYSROOT_RUNNER_PACKAGES,
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
              "SHARDS_CACHE_PATH" => "#{SHARDS_CACHE_DIR}",
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
        # Inputs: sysroot toolchain, seed rootfs environment.
        # Outputs: minimal bq2 rootfs tree (busybox + musl).
        PhaseSpec.new(
          BuildPhase.new(
            name: "rootfs-from-sysroot",
            description: "Build a minimal rootfs using the newly built sysroot toolchain.",
            namespace: SysrootWorkspace::Namespace::Seed.label,
            install_prefix: "/usr",
            destdir: bq2_from_seed,
            env: rootfs_env,
          ),
          workdir: workspace_from_seed,
          package_allowlist: ["musl", "busybox", "linux-headers"],
          env_overrides: {
            "busybox" => {
              "HOSTCC"                  => "#{sysroot_prefix}/bin/clang #{cmake_c_flags}",
              "HOSTCXX"                 => "#{sysroot_prefix}/bin/clang++ #{cmake_c_flags}",
              "HOSTLDFLAGS"             => "-L#{sysroot_prefix}/lib/#{sysroot_triple} -L#{sysroot_prefix}/lib",
              "MAKEFLAGS"               => "-e",
              "STRIP"                   => "/bin/true",
              "BQ2_KCONFIG_CONFIG_TOOL" => "#{workspace_from_seed}/bootstrap-qcow2-#{bootstrap_source_version}/tools/kconfig/config",
            },
          },
          extra_steps: [
            write_file_step(
              "musl-ld-path",
              musl_ld_path,
              "/lib:/usr/lib:/opt/sysroot/lib:/opt/sysroot/lib/#{sysroot_triple}:/opt/sysroot/usr/lib\n",
            ),
            write_file_steps([
              {"/etc/os-release", os_release_content},
              {"/etc/profile", profile_content},
              {"/etc/resolv.conf", resolv_conf_content},
              {"/etc/hosts", hosts_content},
              {"/etc/ssl/certs/ca-certificates.crt", rootfs_ca_bundle_content},
              {"/.bq2-rootfs", "bq2-rootfs\n"},
            ]),
          ].flatten,
        ),
        # Inputs: minimal bq2 rootfs, sysroot toolchain in the seed rootfs.
        # Outputs: prefix-free /usr system packages staged into the bq2 rootfs.
        PhaseSpec.new(
          BuildPhase.new(
            name: "system-from-sysroot",
            description: "Rebuild sysroot packages into /usr inside the new rootfs (prefix-free).",
            namespace: SysrootWorkspace::Namespace::Seed.label,
            install_prefix: "/usr",
            destdir: bq2_from_seed,
            env: system_from_sysroot_env,
          ),
          workdir: workspace_from_seed,
          package_allowlist: nil,
          env_overrides: {
            "libxml2" => libxml2_env,
            "zlib"    => {
              "CFLAGS"   => "-fPIC",
              "LDSHARED" => "#{system_from_sysroot_env["CC"]} -shared -Wl,-soname,libz.so.1 -Wl,--version-script,zlib.map",
            },
            "m4" => {
              "INSTALL" => "./build-aux/install-sh",
            },
            "bootstrap-qcow2" => {
              "SHARDS_CACHE_PATH" => "#{SHARDS_CACHE_DIR}",
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
          extra_steps: symlink_steps([
            {"bq2", "/usr/bin/curl"},
            {"bq2", "/usr/bin/git-remote-https"},
            {"bq2", "/usr/bin/pkg-config"},
            {clang_rt_atomic, "/usr/lib/libatomic.so.1"},
            {"libatomic.so.1", "/usr/lib/libatomic.so"},
          ]),
        ),
        # Inputs: prefix-free system rootfs staged in the bq2 rootfs.
        # Outputs: developer tooling added to /usr in the bq2 rootfs.
        PhaseSpec.new(
          BuildPhase.new(
            name: "tools-from-system",
            description: "Build additional developer tools inside the new rootfs.",
            namespace: SysrootWorkspace::Namespace::BQ2.label,
            install_prefix: "/usr",
            destdir: nil,
            env: bq2_phase_env,
          ),
          workdir: workspace_from_bq2,
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
        # Inputs: full bq2 rootfs staged in the seed namespace.
        # Outputs: finalized rootfs tarball emitted.
        PhaseSpec.new(
          BuildPhase.new(
            name: "finalize-rootfs",
            description: "Strip the sysroot prefix and emit a prefix-free rootfs tarball.",
            namespace: SysrootWorkspace::Namespace::Seed.label,
            install_prefix: "/usr",
            destdir: bq2_from_seed,
            env: rootfs_phase_env(sysroot_prefix),
          ),
          workdir: workspace_from_seed,
          package_allowlist: [] of String,
          extra_steps: [
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
        "aarch64-bq2-linux-musl"
      when "x86_64", "amd64"
        "x86_64-bq2-linux-musl"
      else
        "#{@architecture}-bq2-linux-musl"
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

    # Return environment variables for the prefix-free toolchain in the bq2 rootfs.
    private def bq2_phase_env : Hash(String, String)
      {
        "PATH"   => "/usr/bin:/bin:/usr/sbin:/sbin",
        "CC"     => "clang",
        "CXX"    => "clang++",
        "AR"     => "llvm-ar",
        "NM"     => "llvm-nm",
        "RANLIB" => "llvm-ranlib",
        "STRIP"  => "llvm-strip",
      }
    end

    private def host_setup_env : Hash(String, String)
      {
        "BQ2_ARCH" => @architecture,
        # TODO
        # "BQ2_SOURCE_BRANCH" => bootstrap_source_version,
      }
    end

    private def package_source_specs(specs : Array(PackageSpec)) : Array(SourceSpec)
      specs.flat_map do |pkg|
        pkg.all_urls.map_with_index do |uri, idx|
          checksum_uri = idx.zero? ? pkg.checksum_url : nil
          SourceSpec.new(
            name: pkg.name,
            version: pkg.version,
            url: uri.to_s,
            filename: pkg.filename_for(uri),
            build_directory: pkg.build_directory,
            sha256: pkg.sha256,
            checksum_url: checksum_uri ? checksum_uri.to_s : nil,
          )
        end
      end
    end

    private def extract_source_specs(specs : Array(PackageSpec), include_build_directory : Bool = true) : Array(ExtractSpec)
      specs.map do |pkg|
        build_directory = include_build_directory ? source_dir_for(pkg) : nil
        ExtractSpec.new(
          name: pkg.name,
          version: pkg.version,
          filename: pkg.filename,
          build_directory: build_directory,
        )
      end
    end

    private def host_setup_steps : Array(BuildStep)
      package_sources = package_source_specs(packages)
      extract_sources = extract_source_specs(packages)
      rootfs_sources = package_source_specs([seed_rootfs_spec])
      rootfs_extract = extract_source_specs([seed_rootfs_spec], include_build_directory: false)
      [
        build_step(
          name: "download-sources",
          strategy: "download-sources",
          sources: package_sources + rootfs_sources,
          destdir: sources_dir.to_s,
        ),
        build_step(
          name: "populate-seed",
          strategy: "populate-seed",
          extract_sources: rootfs_extract,
          sources_directory: sources_dir.to_s,
          destdir: @workspace.seed_rootfs_path.not_nil!.to_s,
        ),
        build_step(
          name: "extract-sources",
          strategy: "extract-sources",
          extract_sources: extract_sources,
          sources_directory: sources_dir.to_s,
          destdir: @workspace.workspace_path.to_s,
        ),
        build_step(
          name: "prefetch-shards",
          strategy: "prefetch-shards",
          extract_sources: extract_sources,
          destdir: @workspace.workspace_path.to_s,
          env: {
            "SHARDS_CACHE_PATH" => SHARDS_CACHE_DIR,
          },
        ),
      ]
    end

    # Construct a phased build plan. The plan is serialized into the chroot so
    # it can be replayed by the coordinator runner.
    def build_plan : BuildPlan
      phases = phase_specs.map { |spec| build_phase(spec) }.reject(&.steps.empty?)
      BuildPlan.new(phases)
    end

    # Persist the build plan JSON.
    def write_plan(plan : BuildPlan = build_plan) : Path
      @workspace = SysrootWorkspace.create
      build_state = SysrootBuildState.new(workspace: @workspace)
      plan_json = plan.to_pretty_json
      plan_path = build_state.plan_path
      FileUtils.mkdir_p(plan_path.parent)
      File.write(plan_path, plan_json)
      plan_path
    end

    # Convert a PhaseSpec into a concrete BuildPhase with computed workdirs and
    # per-package build steps.
    private def build_phase(spec : PhaseSpec) : BuildPhase
      phase_packages = select_packages(spec.phase.name, spec.package_allowlist)
      steps = [] of BuildStep
      steps.concat(spec.pre_steps) unless spec.pre_steps.empty?
      steps.concat(phase_packages.flat_map { |pkg| build_steps_for(pkg, spec) })
      steps.concat(spec.extra_steps) unless spec.extra_steps.empty?
      BuildPhase.new(
        name: spec.phase.name,
        description: spec.phase.description,
        namespace: spec.phase.namespace,
        install_prefix: spec.phase.install_prefix,
        destdir: spec.phase.destdir,
        env: spec.phase.env,
        steps: steps,
      )
    end

    # Create a BuildStep with defaulted arrays for simple helper usage.
    private def build_step(name : String,
                           strategy : String,
                           workdir : String? = nil,
                           install_prefix : String? = nil,
                           env : Hash(String, String) = {} of String => String,
                           configure_flags : Array(String) = [] of String,
                           patches : Array(String) = [] of String,
                           destdir : String? = nil,
                           build_dir : String? = nil,
                           sources : Array(SourceSpec)? = nil,
                           extract_sources : Array(ExtractSpec)? = nil,
                           packages : Array(String)? = nil,
                           content : String? = nil,
                           sources_directory : String? = nil) : BuildStep
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
        sources: sources,
        extract_sources: extract_sources,
        packages: packages,
        content: content,
        sources_directory: sources_directory,
      )
    end

    # Build a write-file step for a single content payload.
    private def write_file_step(name : String, path : String, content : String) : BuildStep
      build_step(
        name: name,
        strategy: "write-file",
        install_prefix: path,
        content: content,
      )
    end

    # Build write-file steps for a list of path/content pairs.
    private def write_file_steps(files : Array(Tuple(String, String))) : Array(BuildStep)
      files.map_with_index do |(path, content), idx|
        write_file_step("prepare-rootfs-#{idx}", path, content)
      end
    end

    # Build an apk-add step with an explicit package list.
    private def apk_add_step(name : String, packages : Array(String)) : BuildStep
      build_step(
        name: name,
        strategy: "apk-add",
        packages: packages,
      )
    end

    # Build symlink steps from a list of source/destination pairs.
    private def symlink_steps(links : Array(Tuple(String, String))) : Array(BuildStep)
      links.map_with_index do |(source, dest), idx|
        build_step(
          name: "symlink-#{idx}",
          strategy: "symlink",
          install_prefix: dest,
          content: source,
        )
      end
    end

    # Build the steps for a package, expanding multi-stage packages as needed.
    private def build_steps_for(pkg : PackageSpec, spec : PhaseSpec) : Array(BuildStep)
      workdir = workdir_for(pkg, spec)
      env = env_overrides_for(pkg, spec)
      return llvm_stage_steps(pkg, spec, workdir, env) if pkg.name == "llvm-project"

      clean_build = clean_build_for(pkg, spec)
      [BuildStep.new(
        name: pkg.name,
        strategy: pkg.strategy,
        workdir: workdir,
        configure_flags: configure_flags_for(pkg, spec),
        patches: patches_for(pkg, spec),
        env: env,
        build_dir: build_dir_for(pkg, spec),
        clean_build: clean_build,
      )]
    end

    # Return the workspace directory that should be used for building *package*.
    def workdir_for(package : PackageSpec, phase : PhaseSpec) : String
      base = phase.workdir
      raise "Missing workdir for phase #{phase.phase.name}" unless base
      File.join(base, source_dir_for(package))
    end

    # Resolve the extracted source directory name for a package.
    private def source_dir_for(package : PackageSpec) : String
      if build_directory = package.build_directory
        return build_directory
      end
      filename = package.filename
      base = filename
      [".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".tar"].each do |ext|
        next unless base.ends_with?(ext)
        base = base[0, base.size - ext.size]
        break
      end
      return base unless base.empty?
      "#{package.name}-#{package.version}"
    end

    # Resolve the package build directory.
    private def build_dir_for(pkg : PackageSpec, spec : PhaseSpec) : String?
      build_dir = pkg.build_dir
      return nil unless build_dir
      build_dir = build_dir.gsub("%{phase}", spec.phase.name).gsub("%{name}", pkg.name)
      build_dir.starts_with?("/") ? build_dir : File.join(workdir_for(pkg, spec), build_dir)
    end

    # Return a copy of the env overrides for a package.
    private def env_overrides_for(pkg : PackageSpec, spec : PhaseSpec) : Hash(String, String)
      overrides = spec.env_overrides[pkg.name]? || ({} of String => String)
      overrides.dup
    end

    # Ensure clean rebuilds when a package is installed into multiple prefixes.
    private def clean_build_for(pkg : PackageSpec, spec : PhaseSpec) : Bool
      return false unless pkg.name == "bdwgc" || pkg.name == "libatomic_ops"
      spec.phase.name == "sysroot-from-alpine" || spec.phase.name == "system-from-sysroot"
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
      stage1_flags = llvm_stage1_flags(base_flags, spec.phase.env)
      stage2_flags = llvm_stage2_flags(base_flags, spec.phase.install_prefix, sysroot_target_triple, build_root, spec.phase.env)
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

    # Stage 1 LLVM flags use the host compiler, keep LLVM static, and still
    # build runtimes so stage 2 can link against libunwind/libc++ while it
    # assembles the shared toolchain.
    private def llvm_stage1_flags(base_flags : Array(String),
                                  phase_env : Hash(String, String)) : Array(String)
      cc_value = phase_env["CC"]? || "clang"
      cxx_value = phase_env["CXX"]? || "clang++"
      cc, cc_flags = split_compiler_flags(cc_value)
      cxx, cxx_flags = split_compiler_flags(cxx_value)

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
                                  build_root : String,
                                  phase_env : Hash(String, String)) : Array(String)
      cc_value = phase_env["CC"]? || "#{sysroot_prefix}/bin/clang"
      cxx_value = phase_env["CXX"]? || "#{sysroot_prefix}/bin/clang++"
      cc, cc_flags = split_compiler_flags(cc_value)
      cxx, cxx_flags = split_compiler_flags(cxx_value)

      libcxx_include = "#{sysroot_prefix}/include/c++/v1"
      libcxx_target_include = "#{sysroot_prefix}/include/#{sysroot_triple}/c++/v1"
      libcxx_libdir = "#{sysroot_prefix}/lib/#{sysroot_triple}"
      build_rpath = File.join(build_root, "build-stage2", "lib")
      install_rpath = "#{libcxx_libdir}:#{sysroot_prefix}/lib"
      cxx_standard_libs = "-lc++ -lc++abi -lunwind"
      linker_flags = "--rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld -L#{libcxx_libdir} -L#{sysroot_prefix}/lib"

      flags = base_flags.dup
      flags << "-DCMAKE_C_COMPILER=#{cc}"
      flags << "-DCMAKE_CXX_COMPILER=#{cxx}"
      unless cc_flags.empty? || flags.any? { |flag| flag.starts_with?("-DCMAKE_C_FLAGS=") }
        flags << "-DCMAKE_C_FLAGS=#{cc_flags}"
      end
      unless cxx_flags.empty? || flags.any? { |flag| flag.starts_with?("-DCMAKE_CXX_FLAGS=") }
        flags << "-DCMAKE_CXX_FLAGS=#{cxx_flags}"
      end
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
      patches = pkg.patches + (spec.patch_overrides[pkg.name]? || [] of String)
      host_workdir = @workspace.host_workdir.not_nil!
      host_workspace = @workspace.workspace_path.to_s
      namespace_workspace = case spec.phase.namespace
                            when "seed"
                              SysrootWorkspace.workspace_from(SysrootWorkspace::Namespace::Seed, host_workdir).to_s
                            when "bq2"
                              SysrootWorkspace.workspace_from(SysrootWorkspace::Namespace::BQ2, host_workdir).to_s
                            else
                              host_workspace
                            end
      patches.map do |patch|
        patch.starts_with?(host_workspace) ? patch.sub(host_workspace, namespace_workspace) : patch
      end
    end

    # Placeholder for future build command materialization.
    private def build_commands_for(pkg : PackageSpec, sysroot_prefix : String) : Array(Array(String))
      # The builder remains data-only: embed strategy metadata and let the runner
      # translate into concrete commands.
      Array(Array(String)).new
    end

    # Summarize the sysroot builder CLI behavior for help output.
    def self.summary : String
      "Create sysroot workspace and build plan"
    end

    # Return command aliases handled by the sysroot builder CLI.
    def self.aliases : Array(String)
      ["sysroot-builder-overrides"]
    end

    # Describe help output entries for the sysroot builder CLI.
    def self.help_entries : Array(Tuple(String, String))
      [
        {"sysroot-builder", "Create workspace and build plan"},
        {"sysroot-builder-overrides", "Write overrides that match the current plan changes"},
      ]
    end

    # Dispatch sysroot builder subcommands by command name.
    def self.run(args : Array(String), command_name : String) : Int32
      case command_name
      when "sysroot-builder"
        run_builder(args)
      when "sysroot-builder-overrides"
        run_builder_overrides(args)
      else
        raise "Unknown sysroot builder command #{command_name}"
      end
    end

    # Build or reuse a sysroot workspace and optionally emit a tarball.
    private def self.run_builder(args : Array(String)) : Int32
      architecture = DEFAULT_ARCH
      seed = DEFAULT_ROOTFS_SEED
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-builder [options]") do |p|
        p.on("-a ARCH", "--arch=ARCH", "Target architecture (default: #{architecture})") { |val| architecture = val }
        p.on("-s SEED", "--seed=SEED", "Seed to use for initial rootfs (default: #{seed})") { |val| seed = val }
      end
      return CLI.print_help(parser) if help

      builder = SysrootBuilder.new(
        architecture: architecture,
        seed: seed,
      )
      plan_path = builder.write_plan
      puts "Prepared sysroot workspace at #{builder.workspace.host_workdir}"
      puts "Wrote build plan at #{plan_path}"
      0
    end

    # Emit a build plan overrides file capturing differences between the
    # on-disk plan and the current in-code plan.
    private def self.run_builder_overrides(args : Array(String)) : Int32
      architecture = DEFAULT_ARCH
      seed = DEFAULT_ROOTFS_SEED
      host_workdir : Path? = nil
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 sysroot-builder-overrides [options]") do |p|
        p.on("-a ARCH", "--arch=ARCH", "Target architecture (default: #{architecture})") { |val| architecture = val }
        p.on("-s SEED", "--seed=SEED", "Seed to use for initial rootfs (default: #{seed})") { |val| seed = val }
        p.on("--workdir=PATH", "Starting path for looking for build plan (default: #{SysrootWorkspace::DEFAULT_HOST_WORKDIR})") { |path| host_workdir = Path[path] }
      end
      return CLI.print_help(parser) if help

      begin
        workspace = SysrootWorkspace.new(host_workdir: host_workdir)
      rescue ex
        STDERR.puts "No valid workspace found, build out the workspace first with `bq2 sysroot-builder`: #{ex.message}"
        return -1
      end

      plan_path = workspace.log_path / SysrootBuildState::PLAN_FILE
      unless File.exists?(plan_path)
        STDERR.puts "No build plan found at #{plan_path}, run `bq2 sysroot-builder` first"
        return -1
      end

      base_plan = BuildPlan.parse(File.read(plan_path))
      builder = SysrootBuilder.new(workspace: workspace, architecture: architecture, seed: seed)
      target_plan = builder.build_plan
      overrides = BuildPlanOverrides.from_diff(base_plan, target_plan)

      overrides_path = workspace.log_path / SysrootBuildState::OVERRIDES_FILE
      FileUtils.mkdir_p(overrides_path.parent)
      File.write(overrides_path, overrides.to_pretty_json)

      build_state = SysrootBuildState.new(workspace: workspace, ignore_overrides: true)
      build_state.plan_digest = SysrootBuildState.digest_for?(plan_path)
      build_state.overrides_digest = SysrootBuildState.digest_for?(overrides_path)
      build_state.touch

      puts "Wrote build plan overrides to #{overrides_path}"
      puts "Overrides phases=#{overrides.phases.size}"
      0
    end
  end
end
