require "digest/crc32"
require "file_utils"
require "json"
require "log"
require "option_parser"
require "uri"

module Bootstrap
  module Sysroot
    DEFAULT_PREFIX   = "/opt/sysroot"
    DEFAULT_MANIFEST = "manifest.json"

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
        @env : Hash(String, String)? = nil,
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
        "#{archive_filename}.crc32"
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

        work_dir = File.join("/tmp", "build-#{pkg.name}")
        FileUtils.rm_rf(work_dir)
        FileUtils.mkdir_p(work_dir)
        extract_archive(archive, work_dir)

        source_root = locate_source_root(work_dir)
        steps = pkg.steps || defaults_for(pkg)
        steps.each do |step|
          run_step(step, source_root)
        end

        unless rebuild_only
          Log.info { "Completed build for #{pkg.name}" }
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
          raise "Command failed for #{step.command} with status #{status.exit_code}"
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
            BuildStep.new(command: "cmake", args: ["--build", "build", "--target", "install", "--", "-j{jobs}"]),
          ]
        when "cmake-bootstrap"
          [
            BuildStep.new(command: "./bootstrap", args: ["--parallel={jobs}", "--prefix=#{DEFAULT_PREFIX}"]),
            BuildStep.new(command: "make", args: ["-j{jobs}"]),
            BuildStep.new(command: "make", args: ["install"]),
          ]
        when "busybox"
          [
            BuildStep.new(command: "make", args: ["defconfig"]),
            BuildStep.new(command: "make", args: ["CONFIG_PREFIX=#{DEFAULT_PREFIX}", "-j{jobs}"]),
            BuildStep.new(command: "make", args: ["CONFIG_PREFIX=#{DEFAULT_PREFIX}", "install"]),
          ]
        else
          [
            BuildStep.new(command: "./configure", args: ["--prefix=#{DEFAULT_PREFIX}"]),
            BuildStep.new(command: "make", args: ["-j{jobs}"]),
            BuildStep.new(command: "make", args: ["install"]),
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
          raise "Extraction failed for #{archive}"
        end
      end

      private def verify_checksum(pkg : Package, archive : String)
        unless File.exists?(archive)
          raise "Missing source archive for #{pkg.name} (expected at #{archive})"
        end

        crc = Digest::CRC32.checksum(File.read_bytes(archive)).to_s(16).rjust(8, '0')
        expected = pkg.checksum
        if expected && expected != crc
          raise "Checksum mismatch for #{pkg.name}: expected #{expected}, got #{crc}"
        end
      end
    end
  end
end

if __FILE__ == PROGRAM_NAME
  manifest = "/usr/local/share/bootstrap/#{Bootstrap::Sysroot::DEFAULT_MANIFEST}"
  sources = "/var/cache/bootstrap/sources"
  sysroot = Bootstrap::Sysroot::DEFAULT_PREFIX
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
