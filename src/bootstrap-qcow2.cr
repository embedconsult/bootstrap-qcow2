# TODO: Write documentation for `Bootstrap::Qcow2`
module Bootstrap
  VERSION = "0.1.0"

  class Qcow2
    def initialize(@filename : String)
      puts "Working with qcow2 file: #{@filename}"
    end
  end
end
