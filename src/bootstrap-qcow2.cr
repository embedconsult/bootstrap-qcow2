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
      true
    end

    def self.findExe(exeName : String)
      Process.find_executable(exeName)
    end
  end
end
