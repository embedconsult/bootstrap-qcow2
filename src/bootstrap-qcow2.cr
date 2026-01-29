# `Bootstrap::Qcow2` coordinates qcow2 image generation and dependency checks.
#
# Rootfs/sysroot orchestration now runs through `SysrootNamespace` and the
# Crystal CLI tooling. qcow2 image generation is still evolving; container-based
# steps may be reintroduced for CI once user-namespace constraints are captured
# and a Crystal-first flow is fully defined.
require "log"

module Bootstrap
  # Semantic version of the bootstrap-qcow2 tooling.
  VERSION = "0.1.1"

  # Basic qcow2 wrapper that validates tools and triggers image builds.
  #
  # The long-term plan is to orchestrate qcow2 assembly via Crystal-only
  # tooling and the sysroot namespace workflow.
  class Qcow2
    # Create a new qcow2 helper for the provided filename.
    def initialize(@filename : String)
      Log.info { "Working with qcow2 file: #{@filename}" }
    end

    # Check whether required dependencies and local fossils are available.
    def checkDeps
      File.exists?("../fossil-scm.fossil") &&
        File.exists?("../bootstrap-qcow2.fossil") &&
        self.class.findExe?("qemu-img") &&
        self.class.findExe?("docker") &&
        true
    end

    # Return true when *exeName* resolves to an executable on PATH.
    def self.findExe?(exeName : String)
      exePath = Process.find_executable(exeName)
      Log.info { "Found #{exeName} at #{exePath}" }
      exePath && File::Info.executable?(exePath)
    end

    # Run a command and raise when it fails.
    def self.exec!(command : String, args : Array(String) = [] of String, chdir = "./data")
      result = self.exec(command, args, chdir)
      if !result
        raise RuntimeError.new("#{result}")
      end
    end

    # Run a command, logging stdout/stderr, and return true on success.
    def self.exec(command : String, args : Array(String) = [] of String, chdir = "./data")
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      proc = Process.new(command: command, args: args, chdir: chdir, output: stdout, error: stderr)
      result = proc.wait
      Log.info { "#{command} #{args}: #{result}" }
      Log.debug { "stdout: #{stdout}" }
      Log.debug { "stderr: #{stderr}" }
      if !result.normal_exit?
        raise RuntimeError.new("#{result}")
      end
      result.success?
    end

    # TODO: Add method to fetch data files
    # Placeholder for future data-fetch orchestration.
    def fetchData
      # https://github.com/gregkh/linux/archive/refs/tags/v6.12.38.tar.gz --> linux.tar.gz
    end

    # Build a qcow2 image using the legacy Docker pipeline while the
    # Crystal-first orchestration is still being built out.
    def genQcow2
      self.class.exec(command: "docker", args: ["build", "-f", "Dockerfile.uefi_rs", "-t", "jkridner/bootstrap-qcow2", "."])
      self.class.exec(command: "docker", args: ["rm", "temp-img"])
      self.class.exec(command: "docker", args: ["create", "--name", "temp-img", "jkridner/bootstrap-qcow2"])
      self.class.exec(command: "docker", args: ["cp", "temp-img:/tmp/genimage/images/bootstrap.qcow2", @filename])
      # self.class.exec(command: "docker", args: ["cp", "temp-img:/tmp/genimage/images/bootstrap.img", "bootstrap.img"])
    end

    # Placeholder for future integration test orchestration.
    def self.test
      # self.exec(command: "docker", args: ["build", "-t", "bootstrap-qcow2-buildroot", "-f", "Dockerfile.buildroot", "."])
      # self.exec(command: "docker", args: ["volume", "create", "buildroot_downloads"])
      # self.exec(
      #  command: "crystal",
      #  args: [
      #    "build", "--prelude=empty", "--cross-compile", "--target", "x86_64-unknown-efi",
      #    "--static", "--no-debug", "-p", "--error-trace", "--mcmodel", "kernel",
      #    "src/hello-efi.cr"
      #  ],
      #  chdir: "."
      # )
      true
    end
  end
end
