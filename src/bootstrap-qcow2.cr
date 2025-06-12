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
  end
end
