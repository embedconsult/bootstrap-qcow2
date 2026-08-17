require "file_utils"
require "path"
require "./sysroot_namespace"

module Bootstrap
  # Rootfs workspace helpers anchored on the .bq2-rootfs marker.
  #
  # Environment names (namespace):
  # - host: used for initial invocation and building the workspace
  # - seed: outer rootfs used for building the tools into /opt/sysroot to build the rootfs
  # - bq2: the final inner rootfs as /
  #
  # Stable path references:
  # - host_workdir: directory on host used to store all of the working files (host: <host_workdir>)
  # - seed_rootfs_path: directory containing the outer rootfs (host:
  #   <host_workdir>/rootfs, outer rootfs: /).
  # - sysroot_path: directory to target the initial tool build (host: <host_workdir>/rootfs/opt/sysroot,
  #   outer rootfs: /opt/sysroot)
  # - bq2_rootfs_path: directory that contains .bq2-rootfs and the inner rootfs (host:
  #   <host_workdir>/rootfs/workspace/rootfs, outer rootfs: /workspace/rootfs, inner rootfs: /).
  # - workspace_path: directory that contains the workspace root (host:
  #   <host_workdir>/rootfs/workspace, outer rootfs: /workspace, inner rootfs: /workspace).
  # - log_path: /var/lib under in the inner rootfs (host <host_workdir>/rootfs/workspace/rootfs/var/lib,
  #   outer rootfs: /workspace/rootfs/var/lib, inner rootfs: /var/lib).
  #
  # To simplify coordination of path changes from namespace changes, this class should be used instead of
  # SysrootNamespace directly.
  class SysrootWorkspace
    ROOTFS_MARKER_NAME      = ".bq2-rootfs"
    DEFAULT_HOST_WORKDIR    = "data/sysroot"
    ROOTFS_DIR_NAME         = "rootfs"
    WORKSPACE_DIR_NAME      = "workspace"
    INNER_ROOTFS_DIR_NAME   = "rootfs"
    LOG_DIR_NAME            = "var/lib"
    SYSROOT_DIR_NAME        = "opt/sysroot"
    ROOTFS_WORKSPACE_PATH   = Path["/workspace"]
    ROOTFS_WORKSPACE_ROOTFS = Path["/workspace/rootfs"]
    enum Namespace
      Host
      Seed
      BQ2
    end
    PROBE_PATHS_FOR_MARKER = [
      {namespace: Namespace::Host, path: Path["#{DEFAULT_HOST_WORKDIR}/#{ROOTFS_DIR_NAME}/#{WORKSPACE_DIR_NAME}/#{INNER_ROOTFS_DIR_NAME}/#{ROOTFS_MARKER_NAME}"]},
      {namespace: Namespace::Seed, path: ROOTFS_WORKSPACE_ROOTFS / ROOTFS_MARKER_NAME},
      {namespace: Namespace::BQ2, path: Path["/#{ROOTFS_MARKER_NAME}"]},
    ]

    getter host_workdir : Path?
    getter seed_rootfs_path : Path?
    getter sysroot_path : Path?
    getter bq2_rootfs_path : Path
    getter marker_path : Path
    getter workspace_path : Path
    getter log_path : Path
    getter namespace : Namespace
    @extra_binds : Array(Tuple(Path, Path))

    def initialize(@host_workdir : Path? = nil,
                   @extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path),
                   namespace : Namespace? = nil,
                   inner_rootfs_path : Path? = nil)
      if namespace
        @namespace = namespace
      elsif @host_workdir.nil?
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
      @workspace_path = self.class.workspace_from(@namespace, @host_workdir)
      @bq2_rootfs_path = inner_rootfs_path || self.class.bq2_rootfs_from(@namespace, @host_workdir)
      @marker_path = @bq2_rootfs_path / Path["#{ROOTFS_MARKER_NAME}"]
      @log_path = @bq2_rootfs_path / Path["#{LOG_DIR_NAME}"]
    end

    def self.seed_rootfs_from(namespace : Namespace, host_workdir : Path? = nil)
      case namespace
      in .host?
        host_workdir.not_nil! / Path["#{ROOTFS_DIR_NAME}"]
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
      workspace_path = workspace_from(namespace, host_workdir)
      return Path["/"] if namespace.bq2?
      workspace_path / Path["#{INNER_ROOTFS_DIR_NAME}"]
    end

    def self.workspace_from(namespace : Namespace, host_workdir : Path? = nil)
      case namespace
      in .host?
        host_workdir.not_nil! / Path["#{ROOTFS_DIR_NAME}/#{WORKSPACE_DIR_NAME}"]
      in .seed?
        ROOTFS_WORKSPACE_PATH
      in .bq2?
        ROOTFS_WORKSPACE_PATH
      end
    end

    # Create a workspace rooted at *host_workdir*, ensuring marker + dirs exist.
    def self.create(host_workdir : Path = Path["#{DEFAULT_HOST_WORKDIR}"], extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path)) : SysrootWorkspace
      workspace = SysrootWorkspace.new(host_workdir: host_workdir, extra_binds: extra_binds)
      FileUtils.mkdir_p(workspace.sysroot_path.not_nil!)
      FileUtils.mkdir_p(workspace.workspace_path)
      FileUtils.mkdir_p(workspace.bq2_rootfs_path)
      File.write(workspace.marker_path, "bq2-rootfs\n") unless File.exists?(workspace.marker_path)
      FileUtils.mkdir_p(workspace.log_path)
      workspace
    end

    def self.from_host_workdir(host_workdir : Path) : SysrootWorkspace
      SysrootWorkspace.new(host_workdir: host_workdir)
    end

    def self.from_inner_rootfs(root : Path) : SysrootWorkspace
      SysrootWorkspace.new(namespace: Namespace::BQ2, inner_rootfs_path: root)
    end

    def rootfs_root_path : Path
      @bq2_rootfs_path
    end

    def var_lib_dir : Path
      @log_path
    end
  end
end
