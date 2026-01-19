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
      "bdw-gc"    => ["-lgc"],
      "libpcre2-8" => ["-lpcre2-8"],
    }
    PKG_VERSIONS = {
      "libssl"    => "3.8.2",
      "openssl"   => "3.8.2",
      "libcrypto" => "3.8.2",
      "crypto"    => "3.8.2",
      "bdw-gc"    => "8.2.6",
      "libpcre2-8" => "10.44",
    }
    PKG_VARIABLES = {
      "prefix"     => "/usr",
      "includedir" => "/usr/include",
      "libdir"     => "/usr/lib",
    }

    private struct Options
      property libs : Bool
      property cflags : Bool
      property exists : Bool
      property modversion : Bool
      property variable : String?
      property libs_only_l : Bool
      property libs_only_L : Bool
      property cflags_only_I : Bool
      property silence : Bool
      property show_help : Bool
      property show_version : Bool
      property unknown_options : Array(String)

      def initialize
        @libs = false
        @cflags = false
        @exists = false
        @modversion = false
        @variable = nil
        @libs_only_l = false
        @libs_only_L = false
        @cflags_only_I = false
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

        if options.variable
          value = package_variable(known.first, options.variable.not_nil!)
          return fail_with("Unknown variable #{options.variable}", options.silence) unless value
          puts value
          return 0
        end

        if !options.libs && !options.cflags && !options.modversion
          options.libs = true
        end

        outputs = [] of String
        if options.cflags || options.cflags_only_I
          add_unique(outputs, include_flags) if options.cflags || options.cflags_only_I
        end
        if options.libs || options.libs_only_l || options.libs_only_L
          libs = lib_flags(known)
          if options.libs_only_l
            libs = libs.select { |flag| flag.starts_with?("-l") }
          elsif options.libs_only_L
            libs = libs.select { |flag| flag.starts_with?("-L") }
          end
          add_unique(outputs, libs)
        end
        if options.modversion
          outputs << package_version(known.first)
        end
        puts outputs.join(" ")
        0
    rescue ex
      STDERR.puts ex.message unless options.silence
      1
    end
    end

    private def self.parse_args(args : Array(String), options : Options, packages : Array(String)) : Nil
      idx = 0
      while idx < args.size
        arg = args[idx]
        case arg
        when "--libs"
          options.libs = true
        when "--cflags"
          options.cflags = true
        when "--exists"
          options.exists = true
        when "--modversion"
          options.modversion = true
        when "--libs-only-l"
          options.libs_only_l = true
        when "--libs-only-L"
          options.libs_only_L = true
        when "--cflags-only-I"
          options.cflags_only_I = true
        when "--variable"
          idx += 1
          options.variable = args[idx]?
          if options.variable.nil? || options.variable.not_nil!.empty?
            options.unknown_options << "--variable"
          end
        else
          if arg.starts_with?("--variable=")
            options.variable = arg.split("=", 2)[1]? || ""
          elsif arg == "--silence-errors" || arg == "--silence"
            options.silence = true
          elsif arg == "--print-errors"
            # Ignored; we always print errors unless --silence-errors was given.
          elsif arg == "--static"
            # Ignored; libs are always reported as dynamic linker flags.
          elsif arg == "--version"
            options.show_version = true
          elsif arg == "-h" || arg == "--help"
            options.show_help = true
          elsif arg.starts_with?("-")
            options.unknown_options << arg
          else
            packages << arg
          end
        end
        idx += 1
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

    private def self.package_version(package : String) : String
      PKG_VERSIONS[package]? || "0.0.0"
    end

    private def self.package_variable(_package : String, variable : String) : String?
      return PKG_VARIABLES[variable]? if PKG_VARIABLES.has_key?(variable)
      nil
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
      puts "  --libs-only-l       Print only -l flags"
      puts "  --libs-only-L       Print only -L flags"
      puts "  --cflags-only-I     Print only -I flags"
      puts "  --exists            Exit 0 if package exists"
      puts "  --modversion        Print package version"
      puts "  --variable=VAR      Print package variable"
      puts "  --silence-errors    Suppress error output"
      puts "  --version           Print pkg-config version"
      puts "  -h, --help          Show this help"
    end
  end
end
