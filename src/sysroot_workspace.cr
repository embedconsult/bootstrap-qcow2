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
    ROOTFS_MARKER_NAME     = ".bq2-rootfs"
    DEFAULT_HOST_WORKDIR   = "data/sysroot"
    SEED_DIR_NAME          = "seed-rootfs"
    BQ2_DIR_NAME           = "bq2-rootfs"
    LOG_DIR_NAME           = "var/lib"
    WORKSPACE_DIR_NAME     = "workspace"
    SYSROOT_DIR_NAME       = "opt/sysroot"
    PROBE_PATHS_FOR_MARKER = [
      {namespace: "host", path: Path["#{DEFAULT_HOST_WORKDIR}/#{SEED_DIR_NAME}/#{BQ2_DIR_NAME}/#{ROOTFS_MARKER_NAME}"]},
      {namespace: "seed", path: Path["/#{BQ2_DIR_NAME}/#{ROOTFS_MARKER_NAME}"]},
      {namepsace: "bq2", path: Path["/#{ROOTFS_MARKER_NAME}"]},
    ]

    @host_workdir : Path?
    @seed_rootfs_path : Path?
    @sysroot_path : Path?
    @bq2_rootfs_path : Path
    @marker_path : Path
    @workspace_path : Path
    @log_path : Path
    @namespace : String
    @extra_binds : Array(String)

    def initialize(@host_workdir : Path? = nil, @extra_binds : Array(String) = [] of String)
      if host_dir.not_nil?
        @namespace = "host"
      else
        found_marker = PROBE_PATHS_FOR_MARKER.find { |namespace, path| File.exists?(path) }
        if found_marker.not_nil?
          @namespace = found_marker[:namespace].not_nil!
        else
          raise "Missing BQ2 rootfs marker at one of these paths: #{PROBE_PATHS_FOR_MARKER}"
        end
      end

      case @namespace
      when "host"
        @seed_rootfs_path = @host_workdir / Path["#{SEED_DIR_NAME}"]
        @sysroot_path = @seed_rootfs_path / Path["#{SYSROOT_DIR_NAME}"]
        @bq2_rootfs_path = @seed_rootfs_path.not_nil! / Path["#{BQ2_DIR_NAME}"]
      when "seed"
        @seed_rootfs_path = Path["/"]
        @sysroot_path = @seed_rootfs_path / Path["#{SYSROOT_DIR_NAME}"]
        @bq2_rootfs_path = @seed_rootfs_path.not_nil! / Path["#{BQ2_DIR_NAME}"]
      when "bq2"
        @seed_rootfs_path = nil
        @sysroot_path = nil
        @bq2_rootfs_path = Path["/"]
        default
        raise "Invalid namespace: #{@namespace}"
      end
      @marker_path = @bq2_rootfs_path.not_nil! / Path["#{ROOTFS_MARKER_NAME}"]
      @workspace_path = @bq2_rootfs_path / Path["#{WORKSPACE_DIR_NAME}"]
      @log_path = @bq2_rootfs_path / Path["#{LOG_DIR_NAME}"]
    end

    # Create a workspace rooted at *host_workdir*, ensuring marker + dirs exist.
    def self.create(host_workdir : Path = Path["#{DEFAULT_HOST_WORKDIR}"], extra_binds : Array(String) = [] of String) : SysrootWorkspace
      workspace = SysrootWorkspace.new(host_workdir: host_workdir, extra_binds: extra_binds)
      FileUtils.mkdir_p(workspace.sysroot_path)
      FileUtils.mkdir_p(workspace.bq2_rootfs_path)
      File.write(workspace.marker_path, "bq2-rootfs\n") unless File.exists?(workspace.marker_path)
      FileUtils.mkdir_p(workspace.workspace_path)
      FileUtils.mkdir_p(workspace.log_path)
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
