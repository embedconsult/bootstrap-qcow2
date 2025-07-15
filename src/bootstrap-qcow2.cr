# TODO: Write documentation for `Bootstrap::Qcow2`
require "log"

module Bootstrap
  VERSION = "0.1.0"

  class Qcow2
    def initialize(@filename : String)
      Log.info { "Working with qcow2 file: #{@filename}" }
    end

    def checkDeps()
      File.exists?("../fossil-scm.fossil") &&
      File.exists?("../bootstrap-qcow2.fossil") &&
      self.class.findExe?("qemu-img") &&
      self.class.findExe?("docker") &&
      true
    end

    def self.findExe?(exeName : String)
      exePath = Process.find_executable(exeName)
      Log.info { "Found #{exeName} at #{exePath}" }
      exePath && File::Info.executable?(exePath)
    end

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
    def fetchData()
      # https://github.com/gregkh/linux/archive/refs/tags/v6.12.38.tar.gz --> linux.tar.gz
    end

    def genQcow2()
      self.class.exec(command: "docker", args: ["build", "-t", "jkridner/bootstrap-qcow2", "."])
      self.class.exec(command: "docker", args: ["rm", "temp-img"])
      self.class.exec(command: "docker", args: ["create", "--name", "temp-img", "jkridner/bootstrap-qcow2"])
      self.class.exec(command: "docker", args: ["cp", "temp-img:/tmp/genimage/images/bootstrap.qcow2", @filename])
    end

    def self.test()
      #self.exec(command: "docker", args: ["build", "-t", "bootstrap-qcow2-buildroot", "-f", "Dockerfile.buildroot", "."])
      #self.exec(command: "docker", args: ["volume", "create", "buildroot_downloads"])
      true
    end
  end
end
