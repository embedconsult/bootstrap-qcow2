require "file_utils"
require "option_parser"
require "path"

module Bootstrap
  # Base CLI registry with shared helpers for busybox-style dispatch.
  abstract class CLI
    @@registry = {} of String => CLI.class

    macro inherited
      {% if @type.superclass && @type.superclass.name == "Bootstrap::CLI" %}
        Bootstrap::CLI.register({{ @type }})
      {% end %}
    end

    # Register a CLI class for every declared command line entry.
    def self.register(klass : CLI.class) : Nil
      klass.command_lines.each do |name|
        if existing = @@registry[name]?
          next if existing == klass
          raise "CLI command #{name} already registered to #{existing.name}"
        end
        @@registry[name] = klass
      end
    end

    # Return the registry mapping of command names to CLI classes.
    def self.registry : Hash(String, CLI.class)
      @@registry
    end

    # Optional override for the derived command line name.
    def self.command_line_override : String?
      nil
    end

    # Additional command aliases for this class.
    def self.aliases : Array(String)
      [] of String
    end

    # Return the primary CLI command name for this class.
    def self.command_line : String
      override = command_line_override
      return override if override && !override.empty?
      command_line_from_name(self.name)
    end

    # Return all command line entries handled by this class.
    def self.command_lines : Array(String)
      [command_line] + aliases
    end

    # One-line summary for help output.
    def self.summary : String
      raise "summary not defined for #{self.name}"
    end

    # Help entries for this command and its aliases.
    def self.help_entries : Array(Tuple(String, String))
      command_lines.map { |name| {name, summary} }
    end

    # Run the command with the provided args and command name.
    def self.run(_args : Array(String), _command_name : String) : Int32
      raise "CLI command #{self.name} must implement .run(args, command_name)"
    end

    # Returns the basename of the invoked executable, falling back to a default
    # when it cannot be resolved (e.g., when Process.executable_path is nil).
    def self.invoked_name(default : String = "bq2") : String
      return File.basename(PROGRAM_NAME) unless PROGRAM_NAME.empty?
      if exe = Process.executable_path
        return File.basename(exe)
      end
      default
    end

    # Selects a command name based on the executable name or the first argument
    # when invoked via the canonical name.
    def self.dispatch(argv : Array(String)) : {String, Array(String)}
      args = argv.dup
      name = invoked_name
      known = registry.keys

      if known.includes?(name)
        return {name, args}
      end

      if name == "--install"
        return {"--install", args}
      end

      if args.includes?("-h") || args.includes?("--help")
        return {"help", args}
      end

      if !args.empty?
        candidate = args.first
        if known.includes?(candidate) || candidate == "help" || candidate == "--install"
          command = args.shift
          return {command, args}
        end
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

    # Dispatch a CLI invocation to the registered command class.
    def self.run(argv = ARGV) : Int32
      command_name, args = dispatch(argv)
      case command_name
      when "help"
        return run_help
      when "--install"
        return run_install
      else
        klass = registry[command_name]?
        unless klass
          STDERR.puts "Unknown command #{command_name}"
          return run_help(exit_code: 1)
        end
        return klass.run(args, command_name)
      end
    end

    # Print the shared help output.
    def self.run_help(exit_code : Int32 = 0) : Int32
      puts "Usage:"
      puts "  bq2 <command> [options] [-- command args]\n\nCommands:"
      entries = registry.values.uniq.flat_map(&.help_entries)
      entries.each do |(name, summary)|
        label = name == "default" ? "(default)" : name
        puts "  #{label.ljust(24)} #{summary}"
      end
      puts "  --install               Create CLI symlinks in ./bin"
      puts "  help                    Show this message"
      puts "\nInvoke via symlink (e.g., bin/sysroot-builder) or as the first argument."
      exit_code
    end

    # Create CLI symlinks in ./bin for each registered command.
    def self.run_install : Int32
      bin_dir = Path["bin"]
      target = bin_dir / "bq2"
      links = registry.keys.select { |name| !name.starts_with?("-") && !hidden_from_symlinks?(name) }.sort

      FileUtils.mkdir_p(bin_dir)
      unless File.exists?(target)
        STDERR.puts "warning: #{target} is missing; run `shards build` first"
      end

      links.each do |name|
        link_path = bin_dir / name
        File.delete(link_path) if File.symlink?(link_path) || File.exists?(link_path)
        File.symlink("bq2", link_path)
      end

      puts "Created symlinks in #{bin_dir}: #{links.join(", ")}"
      0
    end

    # Derive a command line name from a class name.
    private def self.command_line_from_name(name : String) : String
      base = name.split("::").last? || name
      dashed = base.gsub(/([a-z0-9])([A-Z])/, "\\1-\\2")
      dashed = dashed.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1-\\2")
      dashed.downcase
    end

    # Determine which commands should be hidden from help/symlink lists.
    private def self.hidden_from_symlinks?(name : String) : Bool
      name == "default"
    end

    # Select the fallback command when none is specified.
    private def self.default_command : String
      registry.has_key?("default") ? "default" : "help"
    end
  end
end
