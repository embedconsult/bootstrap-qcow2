require "digest/crc32"
require "file_utils"
require "http/client"
require "json"
require "log"
require "option_parser"
require "uri"

module Bootstrap
  class BuildStep
    include JSON::Serializable

    getter command : String
    getter args : Array(String)
    getter chdir : String?
    getter env : Hash(String, String)?

    def initialize(
      @command : String,
      @args : Array(String) = [] of String,
      @chdir : String? = nil,
      @env : Hash(String, String)? = nil
    )
    end
  end

  class SourcePackage
    include JSON::Serializable

    getter name : String
    getter version : String
    getter source_uri : String
    getter recipe : String
    getter steps : Array(BuildStep)?
    getter destination : String
    property checksum : String?

    def initialize(
      @name : String,
      @version : String,
      @source_uri : String,
      @recipe : String,
      @destination : String = "/opt/sysroot",
      @checksum : String? = nil,
      @steps : Array(BuildStep)? = nil
    )
    end

    def archive_filename : String
      File.basename(URI.parse(@source_uri).path)
    end

    def checksum_filename : String
      "#{archive_filename}.crc32"
    end
  end

  class DockerSysrootBuilder
    getter packages : Array(SourcePackage)
    getter cache_dir : String
    getter context_dir : String
    getter image_tag : String
    getter manifest_path : String

    DEFAULT_PREFIX        = "/opt/sysroot"
    DEFAULT_MANIFEST      = "manifest.json"
    DEFAULT_RUNNER        = "sysroot-runner.cr"
    DEFAULT_SOURCES_DIR   = "sources"
    DEFAULT_DOCKER_TAG    = "bootstrap/sysroot:local"
    DEFAULT_DOCKER_ALPINE = "3.20"

    def initialize(
      cache_dir : String = File.join("data", "cache", "sources"),
      context_dir : String = File.join("data", "sysroot-image"),
      image_tag : String = DEFAULT_DOCKER_TAG,
      packages : Array(SourcePackage) = DockerSysrootBuilder.default_packages
    )
      @cache_dir = cache_dir
      @context_dir = context_dir
      @image_tag = image_tag
      @packages = packages
      @manifest_path = File.join(@context_dir, DEFAULT_MANIFEST)
    end

    def self.default_packages : Array(SourcePackage)
      prefix = DEFAULT_PREFIX
      autotools = ->{ default_autotools_steps(prefix) }

      [
        SourcePackage.new(
          name: "m4",
          version: "1.4.19",
          source_uri: "https://ftp.gnu.org/gnu/m4/m4-1.4.19.tar.gz",
          recipe: "autotools",
          steps: autotools.call
        ),
        SourcePackage.new(
          name: "musl",
          version: "1.2.5",
          source_uri: "https://musl.libc.org/releases/musl-1.2.5.tar.gz",
          recipe: "autotools",
          steps: autotools.call
        ),
        SourcePackage.new(
          name: "cmake",
          version: "3.29.6",
          source_uri: "https://github.com/Kitware/CMake/releases/download/v3.29.6/cmake-3.29.6.tar.gz",
          recipe: "cmake-bootstrap",
          steps: [
            BuildStep.new(command: "./bootstrap", args: ["--parallel={jobs}", "--prefix=#{prefix}"]),
            BuildStep.new(command: "make", args: ["-j{jobs}"]),
            BuildStep.new(command: "make", args: ["install"])
          ]
        ),
        SourcePackage.new(
          name: "busybox",
          version: "1.36.1",
          source_uri: "https://busybox.net/downloads/busybox-1.36.1.tar.bz2",
          recipe: "busybox",
          steps: [
            BuildStep.new(command: "make", args: ["defconfig"]),
            BuildStep.new(command: "make", args: ["CONFIG_PREFIX=#{prefix}", "-j{jobs}"]),
            BuildStep.new(command: "make", args: ["CONFIG_PREFIX=#{prefix}", "install"])
          ]
        ),
        SourcePackage.new(
          name: "make",
          version: "4.4.1",
          source_uri: "https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz",
          recipe: "autotools",
          steps: autotools.call
        ),
        SourcePackage.new(
          name: "zlib",
          version: "1.3.1",
          source_uri: "https://zlib.net/zlib-1.3.1.tar.gz",
          recipe: "autotools",
          steps: autotools.call
        ),
        SourcePackage.new(
          name: "libressl",
          version: "3.8.2",
          source_uri: "https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-3.8.2.tar.gz",
          recipe: "autotools",
          steps: autotools.call
        ),
        SourcePackage.new(
          name: "libatomic",
          version: "7.8.2",
          source_uri: "https://github.com/ivmai/libatomic_ops/releases/download/v7.8.2/libatomic_ops-7.8.2.tar.gz",
          recipe: "autotools",
          steps: autotools.call
        ),
        SourcePackage.new(
          name: "compiler-rt-builtins",
          version: "18.1.8",
          source_uri: "https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/llvm-project-18.1.8.src.tar.xz",
          recipe: "llvm-project",
          steps: llvm_steps(prefix, %w(compiler-rt))
        ),
        SourcePackage.new(
          name: "clang",
          version: "18.1.8",
          source_uri: "https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/llvm-project-18.1.8.src.tar.xz",
          recipe: "llvm-project",
          steps: llvm_steps(prefix, %w(clang))
        ),
        SourcePackage.new(
          name: "lld",
          version: "18.1.8",
          source_uri: "https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/llvm-project-18.1.8.src.tar.xz",
          recipe: "llvm-project",
          steps: llvm_steps(prefix, %w(lld))
        ),
        SourcePackage.new(
          name: "bdwgc",
          version: "8.2.6",
          source_uri: "https://github.com/ivmai/bdwgc/releases/download/v8.2.6/gc-8.2.6.tar.gz",
          recipe: "autotools",
          steps: autotools.call
        ),
        SourcePackage.new(
          name: "pcre2",
          version: "10.44",
          source_uri: "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.gz",
          recipe: "autotools",
          steps: autotools.call
        ),
        SourcePackage.new(
          name: "gmp",
          version: "6.3.0",
          source_uri: "https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz",
          recipe: "autotools",
          steps: autotools.call
        ),
        SourcePackage.new(
          name: "libiconv",
          version: "1.17",
          source_uri: "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.17.tar.gz",
          recipe: "autotools",
          steps: autotools.call
        ),
        SourcePackage.new(
          name: "libxml2",
          version: "2.12.7",
          source_uri: "https://download.gnome.org/sources/libxml2/2.12/libxml2-2.12.7.tar.xz",
          recipe: "autotools",
          steps: autotools.call
        ),
        SourcePackage.new(
          name: "libyaml",
          version: "0.2.5",
          source_uri: "https://pyyaml.org/download/libyaml/yaml-0.2.5.tar.gz",
          recipe: "autotools",
          steps: autotools.call
        ),
        SourcePackage.new(
          name: "libffi",
          version: "3.4.6",
          source_uri: "https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz",
          recipe: "autotools",
          steps: autotools.call
        )
      ]
    end

    def download_sources
      FileUtils.mkdir_p(@cache_dir)
      @packages.each do |pkg|
        fetch_package(pkg)
      end
    end

    def prepare_context
      FileUtils.rm_rf(@context_dir)
      FileUtils.mkdir_p(@context_dir)
      sources_target = File.join(@context_dir, DEFAULT_SOURCES_DIR)
      FileUtils.mkdir_p(sources_target)

      download_sources
      write_manifest(@manifest_path)
      write_runner(File.join(@context_dir, DEFAULT_RUNNER))
      write_dockerfile(File.join(@context_dir, "Dockerfile"))

      @packages.each do |pkg|
        cached = File.join(@cache_dir, pkg.archive_filename)
        FileUtils.cp(cached, File.join(sources_target, pkg.archive_filename))
        checksum = checksum_for(pkg, cached)
        File.write(File.join(sources_target, pkg.checksum_filename), checksum)
      end
    end

    def build_image
      prepare_context
      Process.run(
        "docker",
        args: ["build", "-t", @image_tag, @context_dir],
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit
      ).success?
    end

    def manifest_json : String
      io = IO::Memory.new
      write_manifest(io)
      io.to_s
    end

    def dockerfile_preview : String
      dockerfile_contents
    end

    def rebuild_sources
      Process.run(
        "docker",
        args: ["run", "--rm", @image_tag, "/usr/local/bin/sysroot-runner", "rebuild"],
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit
      ).success?
    end

    private def fetch_package(pkg : SourcePackage) : String
      target = File.join(@cache_dir, pkg.archive_filename)
      if File.exists?(target) && verify_package(pkg, target)
        Log.info { "Reusing cached #{pkg.name} at #{target}" }
        pkg.checksum ||= checksum_for(pkg, target)
        return target
      end

      Log.info { "Downloading #{pkg.name} from #{pkg.source_uri}" }
      HTTP::Client.get(pkg.source_uri) do |response|
        unless response.status.success?
          raise "Download of #{pkg.name} failed with #{response.status}"
        end

        File.open(target, "w") do |file|
          IO.copy(response.body_io, file)
        end
      end

      pkg.checksum = checksum_for(pkg, target)
      unless verify_package(pkg, target)
        File.delete(target) if File.exists?(target)
        raise "Checksum verification failed for #{pkg.name}"
      end
      target
    end

    private def verify_package(pkg : SourcePackage, path : String) : Bool
      return false unless File.exists?(path)

      checksum_file = File.join(@cache_dir, pkg.checksum_filename)
      expected = pkg.checksum || (File.exists?(checksum_file) ? File.read(checksum_file).strip : nil)
      actual = checksum_for(pkg, path)

      if expected && expected != actual
        Log.warn { "Checksum mismatch for #{pkg.name}. expected=#{expected} actual=#{actual}" }
        return false
      end

      File.write(checksum_file, actual)
      pkg.checksum = actual
      true
    end

    private def checksum_for(pkg : SourcePackage, path : String) : String
      crc = Digest::CRC32.checksum(File.read_bytes(path))
      crc.to_s(16).rjust(8, '0')
    end

    private def write_manifest(path : String)
      File.open(path, "w") do |io|
        write_manifest(io)
      end
    end

    private def write_runner(path : String)
      File.write(path, runner_source)
    end

    private def write_dockerfile(path : String)
      File.write(path, dockerfile_contents)
    end

    private def write_manifest(io : IO)
      JSON.build(io) do |builder|
        builder.array do
          @packages.each do |pkg|
            builder.object do
              builder.field "name", pkg.name
              builder.field "version", pkg.version
              builder.field "source_uri", pkg.source_uri
              builder.field "recipe", pkg.recipe
              builder.field "destination", pkg.destination
              builder.field "checksum", pkg.checksum
              builder.field "steps" do
                if steps = pkg.steps
                  builder.array do
                    steps.each do |step|
                      builder.object do
                        builder.field "command", step.command
                        builder.field "args", step.args
                        builder.field "chdir", step.chdir
                        builder.field "env", step.env
                      end
                    end
                  end
                else
                  builder.null
                end
              end
            end
          end
        end
      end
    end

    private def dockerfile_contents : String
      <<-DOCKERFILE
FROM alpine:#{DEFAULT_DOCKER_ALPINE} AS builder
RUN apk add --no-cache build-base crystal llvm18 clang18 lld llvm-libunwind cmake make ninja python3 tar xz bzip2
WORKDIR /usr/local/src/bootstrap
COPY #{DEFAULT_MANIFEST} /usr/local/share/bootstrap/#{DEFAULT_MANIFEST}
COPY #{DEFAULT_RUNNER} /usr/local/src/bootstrap/#{DEFAULT_RUNNER}
COPY #{DEFAULT_SOURCES_DIR}/ /var/cache/bootstrap/sources/
RUN crystal build --release /usr/local/src/bootstrap/#{DEFAULT_RUNNER} -o /usr/local/bin/sysroot-runner
RUN /usr/local/bin/sysroot-runner build --manifest /usr/local/share/bootstrap/#{DEFAULT_MANIFEST} --sysroot #{DEFAULT_PREFIX} --sources /var/cache/bootstrap/sources

FROM alpine:#{DEFAULT_DOCKER_ALPINE}
COPY --from=builder /usr/local/bin/sysroot-runner /usr/local/bin/sysroot-runner
COPY --from=builder /usr/local/share/bootstrap/#{DEFAULT_MANIFEST} /usr/local/share/bootstrap/#{DEFAULT_MANIFEST}
COPY --from=builder /var/cache/bootstrap/sources/ /var/cache/bootstrap/sources/
COPY --from=builder #{DEFAULT_PREFIX} #{DEFAULT_PREFIX}
ENTRYPOINT ["/usr/local/bin/sysroot-runner"]
CMD ["rebuild", "--manifest", "/usr/local/share/bootstrap/#{DEFAULT_MANIFEST}", "--sysroot", "#{DEFAULT_PREFIX}", "--sources", "/var/cache/bootstrap/sources"]
      DOCKERFILE
    end

    private def runner_source : String
      <<-CRYSTAL
require "digest/crc32"
require "file_utils"
require "json"
require "log"
require "option_parser"
require "uri"

module Bootstrap
  module Sysroot
    class BuildStep
      include JSON::Serializable
      getter command : String
      getter args : Array(String)
      getter chdir : String?
      getter env : Hash(String, String)?

      def initialize(
        @command : String,
        @args : Array(String) = [] of String,
        @chdir : String? = nil,
        @env : Hash(String, String)? = nil
      )
      end

      def expanded_args(jobs : Int32, sysroot : String) : Array(String)
        @args.map { |arg| arg.gsub("{jobs}", jobs.to_s).gsub("{sysroot}", sysroot) }
      end
    end

    class Package
      include JSON::Serializable
      getter name : String
      getter version : String
      getter source_uri : String
      getter recipe : String
      getter destination : String
      getter checksum : String?
      getter steps : Array(BuildStep)?

      def archive_filename : String
        File.basename(URI.parse(@source_uri).path)
      end

      def checksum_filename : String
        "\#{archive_filename}.crc32"
      end
    end

    class Runner
      def initialize(@manifest_path : String, @sources_dir : String, @sysroot : String)
        @jobs = System.cpu_count || 4
        FileUtils.mkdir_p(@sysroot)
      end

      def run(rebuild_only = false)
        packages = load_manifest
        packages.each do |pkg|
          build_package(pkg, rebuild_only)
        end
      end

      private def load_manifest : Array(Package)
        File.open(@manifest_path) do |io|
          Array(Package).from_json(io)
        end
      end

      private def build_package(pkg : Package, rebuild_only : Bool)
        archive = File.join(@sources_dir, pkg.archive_filename)
        verify_checksum(pkg, archive)

        work_dir = File.join("/tmp", "build-\#{pkg.name}")
        FileUtils.rm_rf(work_dir)
        FileUtils.mkdir_p(work_dir)
        extract_archive(archive, work_dir)

        source_root = locate_source_root(work_dir)
        steps = pkg.steps || defaults_for(pkg)
        steps.each do |step|
          run_step(step, source_root)
        end

        unless rebuild_only
          Log.info { "Completed build for \#{pkg.name}" }
        end
      end

      private def locate_source_root(work_dir : String) : String
        children = Dir.children(work_dir).reject(&.starts_with?("."))
        return work_dir if children.empty?

        candidate = File.join(work_dir, children.first)
        Dir.exists?(candidate) ? candidate : work_dir
      end

      private def run_step(step : BuildStep, cwd : String)
        args = step.expanded_args(@jobs, @sysroot)
        env = default_env.merge(step.env || {} of String => String)
        chdir = step.chdir ? File.join(cwd, step.chdir.not_nil!) : cwd
        status = Process.run(
          step.command,
          args: args,
          env: env,
          chdir: chdir,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit
        )
        unless status.success?
          raise "Command failed for \#{step.command} with status \#{status.exit_code}"
        end
      end

      private def default_env
        {
          "DESTDIR" => @sysroot,
          "SYSROOT" => @sysroot,
        }
      end

      private def defaults_for(pkg : Package) : Array(BuildStep)
        case pkg.recipe
        when "cmake", "llvm-project"
          [
            BuildStep.new(command: "cmake", args: ["-S", ".", "-B", "build", "-DCMAKE_INSTALL_PREFIX=#{DEFAULT_PREFIX}", "-DCMAKE_BUILD_TYPE=Release"]),
            BuildStep.new(command: "cmake", args: ["--build", "build", "--target", "install", "--", "-j{jobs}"])
          ]
        when "cmake-bootstrap"
          [
            BuildStep.new(command: "./bootstrap", args: ["--parallel={jobs}", "--prefix=#{DEFAULT_PREFIX}"]),
            BuildStep.new(command: "make", args: ["-j{jobs}"]),
            BuildStep.new(command: "make", args: ["install"])
          ]
        when "busybox"
          [
            BuildStep.new(command: "make", args: ["defconfig"]),
            BuildStep.new(command: "make", args: ["CONFIG_PREFIX=#{DEFAULT_PREFIX}", "-j{jobs}"]),
            BuildStep.new(command: "make", args: ["CONFIG_PREFIX=#{DEFAULT_PREFIX}", "install"])
          ]
        else
          [
            BuildStep.new(command: "./configure", args: ["--prefix=#{DEFAULT_PREFIX}"]),
            BuildStep.new(command: "make", args: ["-j{jobs}"]),
            BuildStep.new(command: "make", args: ["install"])
          ]
        end
      end

      private def extract_archive(archive : String, work_dir : String)
        status = Process.run(
          "tar",
          args: ["xf", archive, "-C", work_dir],
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit
        )
        unless status.success?
          raise "Extraction failed for \#{archive}"
        end
      end

      private def verify_checksum(pkg : Package, archive : String)
        unless File.exists?(archive)
          raise "Missing source archive for \#{pkg.name} (expected at \#{archive})"
        end

        crc = Digest::CRC32.checksum(File.read_bytes(archive)).to_s(16).rjust(8, '0')
        expected = pkg.checksum
        if expected && expected != crc
          raise "Checksum mismatch for \#{pkg.name}: expected \#{expected}, got \#{crc}"
        end
      end
    end
  end
end

if __FILE__ == PROGRAM_NAME
  manifest = "/usr/local/share/bootstrap/#{DEFAULT_MANIFEST}"
  sources = "/var/cache/bootstrap/sources"
  sysroot = "#{DEFAULT_PREFIX}"
  command = "build"

  OptionParser.parse! do |parser|
    parser.banner = "Usage: sysroot-runner [options] [build|rebuild]"
    parser.on("--manifest PATH", "Path to the manifest file") { |path| manifest = path }
    parser.on("--sources PATH", "Directory containing cached sources") { |path| sources = path }
    parser.on("--sysroot PATH", "Sysroot destination inside the image") { |path| sysroot = path }
    parser.on("--build", "Perform a clean build") { command = "build" }
    parser.on("--rebuild", "Rebuild sources using the existing sysroot") { command = "rebuild" }
    parser.unknown_args do |args|
      command = args.first? if args.any?
    end
  end

  Log.setup_from_env
  Bootstrap::Sysroot::Runner.new(manifest, sources, sysroot).run(command == "rebuild")
end
      CRYSTAL
    end

    private def self.default_autotools_steps(prefix = DEFAULT_PREFIX) : Array(BuildStep)
      [
        BuildStep.new(command: "./configure", args: ["--prefix=#{prefix}"]),
        BuildStep.new(command: "make", args: ["-j{jobs}"]),
        BuildStep.new(command: "make", args: ["install"])
      ]
    end

    private def self.default_cmake_steps(prefix = DEFAULT_PREFIX) : Array(BuildStep)
      [
        BuildStep.new(command: "cmake", args: ["-S", ".", "-B", "build", "-DCMAKE_INSTALL_PREFIX=#{prefix}", "-DCMAKE_BUILD_TYPE=Release"]),
        BuildStep.new(command: "cmake", args: ["--build", "build", "--target", "install", "--", "-j{jobs}"])
      ]
    end

    private def self.llvm_steps(prefix = DEFAULT_PREFIX, projects = %w(clang lld compiler-rt)) : Array(BuildStep)
      runtime_flags = [] of String
      if projects.includes?("compiler-rt")
        runtime_flags = [
          "-DLLVM_ENABLE_RUNTIMES=compiler-rt",
          "-DCOMPILER_RT_BUILD_BUILTINS=ON",
          "-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON",
        ]
      end

      [
        BuildStep.new(
          command: "cmake",
          args: [
            "-S", "llvm",
            "-B", "build",
            "-G", "Unix Makefiles",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_INSTALL_PREFIX=#{prefix}",
            "-DLLVM_TARGETS_TO_BUILD=AArch64;X86",
            "-DLLVM_ENABLE_PROJECTS=#{projects.join(",")}",
          ] + runtime_flags
        ),
        BuildStep.new(
          command: "cmake",
          args: ["--build", "build", "--target", "install", "--", "-j{jobs}"]
        )
      ]
    end
  end
end
