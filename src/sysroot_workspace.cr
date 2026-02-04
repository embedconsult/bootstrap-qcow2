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
  # - seed_rootfs_path: directory containing the rootfs the outer rootfs (host:
  #   <host_workdir>/seed-rootfs, outer rootfs: /).
  # - sysroot_path: directory to target the initial tool build (host: <host_workdir>/seed-rootfs/opt/sysroot,
  #   outer rootfs: /opt/sysroot)
  # - bq2_rootfs_path: directory that contains .bq2-rootfs and inner rootfs (host:
  #   <host_workdir>/seed-rootfs/bq2-rootfs, outer rootfs: /bq2-rootfs, inner rootfs: /).
  # - workspace_path: directory that contains the inner rootfs (host:
  #   <host_workdir>/seed-rootfs/bq2-rootfs/workspace, outer rootfs: /bq2-rootfs/workspace, inner rootfs: /workspace).
  # - log_path: /var/lib under in the inner rootfs (host <host_workdir>/seed-rootfs/bq2-rootfs/var/lib,
  #   outer rootfs: /bq2-rootfs/var/lib, inner rootfs: /var/lib).
  #
  # To simplify coordination of path changes from namespace changes, this class should be used to instead of
  # SysrootNamespace directly.
  class SysrootWorkspace
    ROOTFS_MARKER_NAME   = ".bq2-rootfs"
    DEFAULT_HOST_WORKDIR = "data/sysroot"
    SEED_DIR_NAME        = "seed-rootfs"
    BQ2_DIR_NAME         = "bq2-rootfs"
    LOG_DIR_NAME         = "var/lib"
    WORKSPACE_DIR_NAME   = "workspace"
    SYSROOT_DIR_NAME     = "opt/sysroot"
    enum Namespace
      Host
      Seed
      BQ2
    end
    PROBE_PATHS_FOR_MARKER = [
      {namespace: Namespace::Host, path: Path["#{DEFAULT_HOST_WORKDIR}/#{SEED_DIR_NAME}/#{BQ2_DIR_NAME}/#{ROOTFS_MARKER_NAME}"]},
      {namespace: Namespace::Seed, path: Path["/#{BQ2_DIR_NAME}/#{ROOTFS_MARKER_NAME}"]},
      {namespace: Namespace::BQ2, path: Path["/#{ROOTFS_MARKER_NAME}"]},
    ]

    getter host_workdir : Path?
    getter seed_rootfs_path : Path?
    getter sysroot_path : Path?
    getter bq2_rootfs_path : Path
    getter marker_path : Path
    getter workspace_path : Path
    getter log_path : Path
    @namespace : Namespace
    @extra_binds : Array(Tuple(Path, Path))

    def initialize(@host_workdir : Path? = nil, @extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path))
      if @host_workdir.nil?
        found_marker = PROBE_PATHS_FOR_MARKER.find { |s| File.exists?(s[:path]) }
        raise "Missing BQ2 rootfs marker at one of these paths: #{PROBE_PATHS_FOR_MARKER}" if found_marker.nil?
        marker_match = found_marker.not_nil!
        @namespace = marker_match[:namespace]
        if @namespace == Namespace::Host
          @host_workdir = Path["#{DEFAULT_HOST_WORKDIR}"]
        end
      else
        @namespace = Namespace::Host
      end

      raise "Invalid namespace: #{@namespace}" unless [Namespace::Host, Namespace::Seed, Namespace::BQ2].includes?(@namespace)

      @seed_rootfs_path = self.class.seed_rootfs_from(@namespace, @host_workdir)
      @sysroot_path = self.class.sysroot_from(@namespace, @host_workdir)
      @bq2_rootfs_path = self.class.bq2_rootfs_from(@namespace, @host_workdir)
      @marker_path = @bq2_rootfs_path / Path["#{ROOTFS_MARKER_NAME}"]
      @workspace_path = @bq2_rootfs_path / Path["#{WORKSPACE_DIR_NAME}"]
      @log_path = @bq2_rootfs_path / Path["#{LOG_DIR_NAME}"]
    end

    def self.seed_rootfs_from(namespace : Namespace, host_workdir : Path? = nil)
      case namespace
      in .host?
        host_workdir.not_nil! / Path["#{SEED_DIR_NAME}"]
      in .seed?
        Path["/"]
      in .bq2?
        nil
      end
    end

    def self.sysroot_from(namespace : Namespace, host_workdir : Path? = nil)
      seed_rootfs_path = seed_rootfs_from(namespace, host_workdir)
      return nil if seed_rootfs_path.nil?
      prefix = seed_rootfs_path.not_nil!
      prefix / Path["#{SYSROOT_DIR_NAME}"]
    end

    def self.bq2_rootfs_from(namespace : Namespace, host_workdir : Path? = nil)
      seed_rootfs_path = seed_rootfs_from(namespace, host_workdir)
      return Path["/"] if seed_rootfs_path.nil?
      prefix = seed_rootfs_path.not_nil!
      prefix / Path["#{BQ2_DIR_NAME}"]
    end

    # Create a workspace rooted at *host_workdir*, ensuring marker + dirs exist.
    def self.create(host_workdir : Path = Path["#{DEFAULT_HOST_WORKDIR}"], extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path)) : SysrootWorkspace
      workspace = SysrootWorkspace.new(host_workdir: host_workdir, extra_binds: extra_binds)
      FileUtils.mkdir_p(workspace.sysroot_path.not_nil!)
      FileUtils.mkdir_p(workspace.bq2_rootfs_path)
      File.write(workspace.marker_path, "bq2-rootfs\n") unless File.exists?(workspace.marker_path)
      FileUtils.mkdir_p(workspace.workspace_path)
      FileUtils.mkdir_p(workspace.log_path)
      workspace
    end

    private def update_namespace(namespace : String)
      @workspace.namespace = namespace
      init_workspace_by_namespace(@workspace)
    end

    def enter_bq2_rootfs_namespace
      unless @workspace.namespace == "seed"
        raise
      end
      SysrootNamespace.enter_rootfs
      update_namespace("bq2")
    end

    def enter_seed_rootfs_namespace
      unless @workspace.namespace == "host"
        raise
      end
      SysrootNamespace.enter_rootfs
      update_namespace("seed")
    end
  end
end
