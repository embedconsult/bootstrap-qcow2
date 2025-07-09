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

    def genRootfs()
    end
  end
end
# cd data
# docker build -t jkridner/bootstrap-qcow2 .
# docker create --name temp-img jkridner/bootstrap-qcow2
# docker cp temp-img:/tmp/genimage/images/bootstrap.qcow2 .
