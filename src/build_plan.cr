require "json"

module Bootstrap
  # Common data structures for describing the sysroot build plan.
  #
  # The plan is authored in code (`SysrootBuilder`) and serialized into the chroot
  # so the runner (`SysrootRunner`) can replay it reproducibly.
  struct ExtractSpec
    include JSON::Serializable

    getter name : String
    getter version : String
    getter filename : String
    getter build_directory : String

    # Describes how a source archive should be extracted.
    def initialize(@name : String,
                   @version : String,
                   @filename : String,
                   @build_directory : String)
    end
  end

  struct SourceSpec
    include JSON::Serializable

    getter name : String
    getter version : String
    getter url : String
    getter sha256 : String?
    getter checksum_url : String?
    getter filename : String
    getter build_directory : String?

    # Describes a single downloadable source archive.
    def initialize(@name : String,
                   @version : String,
                   @url : String,
                   @filename : String,
                   @build_directory : String? = nil,
                   @sha256 : String? = nil,
                   @checksum_url : String? = nil)
    end
  end

  struct BuildStep
    include JSON::Serializable

    getter name : String
    getter strategy : String
    getter workdir : String
    getter configure_flags : Array(String)
    getter patches : Array(String)
    getter build_dir : String?
    getter install_prefix : String?
    getter destdir : String?
    getter env : Hash(String, String)
    getter clean_build : Bool
    getter sources : Array(SourceSpec)?
    getter extract_sources : Array(ExtractSpec)?
    getter packages : Array(String)?
    getter content : String?

    # Creates a single step within a build phase.
    #
    # Steps can optionally override install locations (`install_prefix`/`destdir`)
    # and set additional environment variables via `env`. `build_dir` selects
    # an out-of-tree directory for build outputs, while `clean_build` requests
    # a `make clean` before building (when supported by the strategy).
    def initialize(@name : String,
                   @strategy : String,
                   @workdir : String,
                   @configure_flags : Array(String),
                   @patches : Array(String),
                   @install_prefix : String? = nil,
                   @destdir : String? = nil,
                   @env : Hash(String, String) = {} of String => String,
                   @build_dir : String? = nil,
                   @clean_build : Bool = false,
                   @sources : Array(SourceSpec)? = nil,
                   @extract_sources : Array(ExtractSpec)? = nil,
                   @packages : Array(String)? = nil,
                   @content : String? = nil)
    end
  end

  # A named stage of the overall build. Phases are executed in order unless the
  # runner selects a specific phase by name.
  struct BuildPhase
    include JSON::Serializable

    getter name : String
    getter description : String
    getter workspace : String
    getter environment : String
    getter install_prefix : String
    getter destdir : String?
    getter env : Hash(String, String)
    getter steps : Array(BuildStep)

    # Creates a build phase containing steps plus shared install/environment
    # defaults.
    def initialize(@name : String,
                   @description : String,
                   @workspace : String,
                   @environment : String,
                   @install_prefix : String,
                   @destdir : String? = nil,
                   @env : Hash(String, String) = {} of String => String,
                   @steps : Array(BuildStep) = [] of BuildStep)
    end
  end

  # Root object written to disk inside the inner rootfs var/lib directory
  # (for example `/var/lib/sysroot-build-plan.json` in the inner rootfs).
  class BuildPlan
    include JSON::Serializable

    CURRENT_FORMAT_VERSION = 2

    getter format_version : Int32
    getter phases : Array(BuildPhase)

    # Creates a build plan. `format_version` allows forward-compatible changes
    # to the on-disk JSON schema.
    def initialize(@phases : Array(BuildPhase), @format_version : Int32 = CURRENT_FORMAT_VERSION)
    end

    def_equals @format_version, @phases

    def self.load(path : String) : BuildPlan
      parse(File.read(path))
    end

    def self.parse(json : String) : BuildPlan
      stripped = json.lstrip
      if stripped.starts_with?("[")
        raise "Legacy build plan format is not supported; regenerate the plan with sysroot-builder"
      end
      plan = BuildPlan.from_json(json)
      unless plan.format_version == CURRENT_FORMAT_VERSION
        raise "Unsupported build plan format version #{plan.format_version} (expected #{CURRENT_FORMAT_VERSION})"
      end
      plan
    end
  end
end
