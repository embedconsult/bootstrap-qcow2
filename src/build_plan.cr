require "json"

module Bootstrap
  # Common data structures for describing the sysroot build plan.
  #
  # The plan is authored in code (`SysrootBuilder`) and serialized into the chroot
  # so the runner (`SysrootRunner`) can replay it reproducibly.
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
                   @clean_build : Bool = false)
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
  struct BuildPlan
    include JSON::Serializable

    getter format_version : Int32
    getter phases : Array(BuildPhase)

    # Creates a build plan. `format_version` allows forward-compatible changes
    # to the on-disk JSON schema.
    def initialize(@phases : Array(BuildPhase), @format_version : Int32 = 1)
    end
  end
end
