module Bootstrap
  # Minimal pkg-config replacement for Crystal's libssl/libcrypto probes.
  module PkgConfigCommand
    VERSION      = "0.29.2"
    LIB_DIRS     = ["/usr/lib", "/usr/lib64", "/opt/sysroot/lib", "/opt/sysroot/lib64"]
    INCLUDE_DIRS = ["/usr/include", "/opt/sysroot/include"]
    PKG_LIBS     = {
      "libssl"    => ["-lssl", "-lcrypto"],
      "openssl"   => ["-lssl", "-lcrypto"],
      "libcrypto" => ["-lcrypto"],
      "crypto"    => ["-lcrypto"],
    }

    private struct Options
      property libs : Bool
      property cflags : Bool
      property exists : Bool
      property modversion : Bool
      property silence : Bool
      property show_help : Bool
      property show_version : Bool
      property unknown_options : Array(String)

      def initialize
        @libs = false
        @cflags = false
        @exists = false
        @modversion = false
        @silence = false
        @show_help = false
        @show_version = false
        @unknown_options = [] of String
      end
    end

    def self.run(args : Array(String)) : Int32
      options = Options.new
      begin
        packages = [] of String
        parse_args(args, options, packages)

        if options.show_help
          print_help
          return 0
        end
        if options.show_version
          puts VERSION
          return 0
        end
        unless options.unknown_options.empty?
          return fail_with("Unsupported option(s): #{options.unknown_options.join(", ")}", options.silence)
        end
        if packages.empty?
          return fail_with("No packages specified", options.silence)
        end

        known, unknown = split_packages(packages)
        unless unknown.empty?
          return fail_with("Unknown package(s): #{unknown.join(", ")}", options.silence)
        end

        if options.exists
          return 0
        end

        if !options.libs && !options.cflags && !options.modversion
          options.libs = true
        end

        outputs = [] of String
        if options.cflags
          add_unique(outputs, include_flags)
        end
        if options.libs
          add_unique(outputs, lib_flags(known))
        end
        outputs << VERSION if options.modversion
        puts outputs.join(" ")
        0
      rescue ex
        STDERR.puts ex.message unless options.silence
        1
      end
    end

    private def self.parse_args(args : Array(String), options : Options, packages : Array(String)) : Nil
      args.each do |arg|
        case arg
        when "--libs"
          options.libs = true
        when "--cflags"
          options.cflags = true
        when "--exists"
          options.exists = true
        when "--modversion"
          options.modversion = true
        when "--silence-errors", "--silence"
          options.silence = true
        when "--print-errors"
          # Ignored; we always print errors unless --silence-errors was given.
        when "--static"
          # Ignored; libs are always reported as dynamic linker flags.
        when "--version"
          options.show_version = true
        when "-h", "--help"
          options.show_help = true
        else
          if arg.starts_with?("-")
            options.unknown_options << arg
          else
            packages << arg
          end
        end
      end
    end

    private def self.split_packages(packages : Array(String)) : {Array(String), Array(String)}
      known = [] of String
      unknown = [] of String
      packages.each do |pkg|
        if PKG_LIBS.has_key?(pkg)
          known << pkg
        else
          unknown << pkg
        end
      end
      {known, unknown}
    end

    private def self.include_flags : Array(String)
      INCLUDE_DIRS.map { |dir| "-I#{dir}" }
    end

    private def self.lib_flags(packages : Array(String)) : Array(String)
      flags = [] of String
      LIB_DIRS.each { |dir| flags << "-L#{dir}" }
      packages.each do |pkg|
        PKG_LIBS[pkg].each { |flag| flags << flag }
      end
      flags
    end

    private def self.add_unique(target : Array(String), additions : Array(String)) : Nil
      additions.each do |item|
        target << item unless target.includes?(item)
      end
    end

    private def self.fail_with(message : String, silence : Bool) : Int32
      STDERR.puts message unless silence
      1
    end

    private def self.print_help : Nil
      puts "Usage: pkg-config [options] <packages>"
      puts "Options:"
      puts "  --libs              Print linker flags"
      puts "  --cflags            Print compiler flags"
      puts "  --exists            Exit 0 if package exists"
      puts "  --modversion        Print package version"
      puts "  --silence-errors    Suppress error output"
      puts "  --version           Print pkg-config version"
      puts "  -h, --help          Show this help"
    end
  end
end
