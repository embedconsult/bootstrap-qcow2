require "file_utils"
require "path"
require "./sysroot_namespace"

module Bootstrap
  # Rootfs workspace helpers anchored on the .bq2-rootfs marker.
  #
  # Environment names (namespace):
  # - host: used for initial invocation and building the workspace
  # - seed: outer rootfs used for building the tools into /opt/sysroot to build the bq2 rootfs
  # - bq2: the final inner rootfs as /
  #
  # Stable path references:
  # - host_workdir: directory on host used to store all of the working files (host: <host_workdir>)
  # - seed_path: directory containing the outer rootfs (host: <host_workdir>/seed-rootfs, outer rootfs: /).
  # - sysroot_path: directory to target the initial tool build (host: <host_workdir>/seed-rootfs/opt/sysroot,
  #   outer rootfs: /opt/sysroot)
  # - bq2_path: directory that contains .bq2-rootfs and the inner rootfs (host:
  #   <host_workdir>/seed-rootfs/bq2-rootfs, outer rootfs: /bq2-rootfs, inner rootfs: /).
  # - workspace_path: directory that contains the workspace root (host:
  #   <host_workdir>/seed-rootfs/bq2-rootfs/workspace, outer rootfs: /bq2-rootfs/workspace, inner rootfs: /workspace).
  # - log_path: /var/lib under in the inner rootfs (host <host_workdir>/seed-rootfs/bq2-rootfs/var/lib,
  #   outer rootfs: /bq2-rootfs/var/lib, inner rootfs: /var/lib).
  #
  # To simplify coordination of path changes from namespace changes, this class should be used instead of
  # SysrootNamespace directly.
  class SysrootWorkspace
    DEFAULT_HOST_WORKDIR = "data/sysroot"
    SYSROOT_DIR_NAME = "opt/sysroot"
    enum Namespace
      Host
      Seed
      BQ2

      # Return the namespace name as a lowercase underscore string.
      def label : String
        to_s.underscore
      end
    end

    alias Host = Bootstrap::SysrootWorkspace::Namespace::Host
    alias Seed = Bootstrap::SysrootWorkspace::Namespace::Seed
    alias BQ2 = Bootstrap::SysrootWorkspace::Namespace::BQ2

    # Defines path constants and generates path `getter` based on namespace
    macro path(name, space, rel_path)
      {% name_c = name.stringify.upcase.id %}

      # Constant defaults
      {% if space == Host %}
        # Host from Host
        HOST_{{name_c}} = "{{rel_path}}"
      {% elsif space == Seed %}
        # Seed from Host
        HOST_{{name_c}} = "seed-rootfs/{{rel_path}}"
        # Seed from Seed
        SEED_{{name_c}} = "{{rel_path}}"
      {% elsif space == BQ2 %}
        # BQ2 from Host
        HOST_{{name_c}} = "seed-rootfs/bq2-rootfs/{{rel_path}}"
        # BQ2 from Seed
        SEED_{{name_c}} = "bq2-rootfs/{{rel_path}}"
        # BQ2 from BQ2
        BQ2_{{name_c}} = "{{rel_path}}"
      {% endif %}

      # {{name}} getter method
      def {{name}}(from_namespace: Namespace = @namespace) : Path
        case from_namespace
        when Host
          @host_workdir / Path["HOST_{{name_c}}"]
        when Seed
          {% if (space == Host) %}
            raise "Cannot fetch path for '{{name}}' in {{space.stringify}} namespace from #{from_namespace.label} namespace"
          {% else %}
            Path["/#{SEED_{{name_c}}}"]
          {% end %}
        when BQ2
          {% if (space == Host) || (space == Seed) %}
            raise "Cannot fetch path for '{{name}}' in {{space.stringify}} from_namespace from BQ2 namespace"
          {% else %}
            Path["/#{BQ2_{{name_c}}}"]
          {% end %}
        end
      end
    end

    path host_path, Host, ""
    path cache_path, Host, "cache" # Cache directory for checksum metadata.
    path checksum_path,Host, "cache/checksums" # Directory for checksum files keyed by package.
    path sources_path,Host, "sources" # Directory where source tarballs are stored.
    path seed_path,Seed, ""
    path sysroot_path,Seed, SYSROOT_DIR_NAME
    path bq2_path,BQ2, ""
    path log_path,BQ2, "var/lib"
    path marker_path, BQ2, ".bq2-rootfs"
    path workspace_path, BQ2, "workspace"

    property host_workdir : Path
    property namespace : Namespace
    property extra_binds : Array(Tuple(Path, Path))

    PROBE_PATHS_FOR_MARKER = [
      {namespace: Host, path: "#{DEFAULT_HOST_WORKDIR}/#{HOST_MARKER_PATH}"}, 
      {namespace: Seed, path: SEED_MARKER_PATH},
      {namespace: BQ2, path: BQ2_MARKER_PATH},
    ]

    def initialize(@host_workdir : Path? = nil,
                   @extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path))
      if @host_workdir.nil?
        found_marker = PROBE_PATHS_FOR_MARKER.find { |s| File.exists?(s[:path]) }
        raise "Missing BQ2 rootfs marker at one of these paths: #{PROBE_PATHS_FOR_MARKER}" if found_marker.nil?
        marker_match = found_marker.not_nil!
        @namespace = marker_match[:namespace]
        if @namespace == Namespace::Host
          @host_workdir = Path["#{DEFAULT_HOST_WORKDIR}"].expand
        end
      else
        @host_workdir = @host_workdir.not_nil!.expand
        @namespace = Namespace::Host
      end
      Log.debug { "Initialized namespace (host_workdir=#{@host_workdir}, namespace=#{@namespace})" }

      raise "Invalid namespace: #{@namespace}" unless [Namespace::Host, Namespace::Seed, Namespace::BQ2].includes?(@namespace)

      found_marker = File.exists?(marker_path)
      raise "Missing BQ2 rootfs marker at #{marker_path}" unless found_marker
    end

    # Create a workspace rooted at *host_workdir*, ensuring marker + dirs exist.
    def self.create(host_workdir : Path = Path["#{DEFAULT_HOST_WORKDIR}"], extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path)) : SysrootWorkspace
      workspace = SysrootWorkspace.allocate
      workspace.host_workdir = host_workdir
      workspace.extra_binds = extra_binds
      FileUtils.mkdir_p(workspace.sysroot_path)
      FileUtils.mkdir_p(workspace.workspace_path)
      FileUtils.mkdir_p(workspace.log_path)
      unless File.exists?(workspace.marker_path)
        Log.debug { "Generating #{workspace.marker_path}" }
        File.write(workspace.marker_path, "bq2-rootfs\n")
      end
      Log.debug { "Created #{workspace} at #{workspace.host_workdir}" }
      workspace
    end

    # Enter the requested namespace by label, if needed.
    def enter_namespace(requested_label : String) : Nil
      requested = Namespace.parse(requested_label)
      case requested
      in .host?
        raise "Cannot enter Host namespace from #{@namespace.label}" unless @namespace.host?
      in .seed?
        if @namespace.host?
          # From Host to Seed
          Log.debug { "**** Entering Seed namespace from #{@namespace.label} ****" }
          SysrootNamespace.enter_rootfs(seed_path.to_s, extra_binds: seed_binds)
        elsif @namespace.seed?
          # Already in seed namespace.
        else
          raise "Cannot enter Seed namespace from #{@namespace.label}"
        end
      in .bq2?
        if @namespace.host? || @namespace.seed?
          # From Host or Seed to BQ2
          Log.debug { "**** Entering BQ2 namespace from #{@namespace.label} ****" }
          SysrootNamespace.enter_rootfs(bq2_path.to_s, extra_binds: bq2_binds)
        elsif @namespace.bq2?
          # Already in bq2 namespace.
        else
          raise "Cannot enter BQ2 namespace from #{@namespace.label}"
        end
      end
      @namespace = requested
    end

    private def seed_binds
      @extra_binds
    end

    # Return bind mounts to apply when entering the bq2 rootfs namespace.
    #
    # The system-from-sysroot phase relies on the sysroot toolchain from the
    # seed namespace, so bind /opt/sysroot into the bq2 rootfs.
    private def bq2_binds : Array(Tuple(Path, Path))
      binds = [] of Tuple(Path, Path)
      @extra_binds.each do |(source, target)|
        if File.exists?(source)
          binds << {source, target}
          next
        end
        rebound_source = Path["/"] / target
        if File.exists?(rebound_source)
          binds << {rebound_source, target}
          next
        end
        raise "Bind source #{source} is unavailable in the #{@namespace.label} namespace (also missing #{rebound_source})."
      end
      unless Dir.exists?(sysroot_path)
        raise "Missing sysroot at #{sysroot_path}; run bq2 sysroot-builder first."
      end
      sysroot_target = Path["/#{SYSROOT_DIR_NAME}"]
      unless binds.any? { |(_source, target)| target == sysroot_target }
        binds << {sysroot_path, sysroot_target}
      end
      binds
    end
  end
end
