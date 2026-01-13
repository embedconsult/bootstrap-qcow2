require "option_parser"
require "file_utils"

module Bootstrap
  # Minimal CLI utilities to support a busybox-style dispatcher.
  module CLI
    # Returns the basename of the invoked executable, falling back to a default
    # when it cannot be resolved (e.g., when Process.executable_path is nil).
    def self.invoked_name(default : String = "bq2") : String
      argv0 = ARGV[0]? || PROGRAM_NAME
      return File.basename(argv0) if argv0 && !argv0.empty?
      if exe = Process.executable_path
        return File.basename(exe)
      end
      default
    end

    # Selects a command name based on the executable name or the first argument
    # when invoked via the canonical name.
    def self.dispatch(argv : Array(String),
                      known : Array(String),
                      default_command : String = "help") : {String, Array(String)}
      args = argv.dup
      name = invoked_name
      if known.includes?(name)
        return {name, args}
      end

      if !args.empty? && known.includes?(args.first)
        command = args.shift
        return {command, args}
      end

      {default_command, args}
    end

    # Builds an OptionParser with a common -h/--help toggle and returns the
    # parser plus the parsed args array so callers can inspect remaining args.
    def self.parse(args : Array(String), banner : String, &block : OptionParser ->) : {OptionParser, Array(String), Bool}
      parser = OptionParser.new
      parser.banner = banner
      help = false
      yield parser
      parser.on("-h", "--help", "Show this help") { help = true }
      parser.parse(args)
      {parser, args, help}
    end

    def self.print_help(parser : OptionParser, io = STDOUT) : Int32
      io.puts parser
      0
    end
  end
end
