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
    ROOTFS_MARKER_NAME    = ".bq2-rootfs"
    DEFAULT_HOST_WORKDIR  = "data/sysroot"
    SEED_DIR_NAME         = "seed-rootfs"
    OUTER_ROOTFS_DIR      = SEED_DIR_NAME
    BQ2_DIR_NAME          = "bq2-rootfs"
    LOG_DIR_NAME          = "var/lib"
    WORKSPACE_DIR_NAME    = "workspace"
    SYSROOT_DIR_NAME      = "opt/sysroot"
    SOURCES_DIR_NAME      = "sources"
    CACHE_DIR_NAME        = "cache"
    ROOTFS_WORKSPACE_PATH = Path["/workspace"]
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
    getter namespace : Namespace
    getter extra_binds : Array(Tuple(Path, Path))
    @bq2_rootfs_path : Path = Path["/"]
    @marker_path : Path = Path["/#{ROOTFS_MARKER_NAME}"]
    @workspace_path : Path = ROOTFS_WORKSPACE_PATH
    @log_path : Path = Path["/#{LOG_DIR_NAME}"]
    @namespace : Namespace = Namespace::Host
    @extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path)

    def initialize(@host_workdir : Path? = nil, @extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path))
      if @host_workdir.nil?
        found_marker = PROBE_PATHS_FOR_MARKER.find { |s| File.exists?(s[:path]) }
        if found_marker.nil?
          @namespace = Namespace::Host
          @host_workdir = Path["#{DEFAULT_HOST_WORKDIR}"]
        else
          marker_match = found_marker.not_nil!
          @namespace = marker_match[:namespace]
          if @namespace == Namespace::Host
            @host_workdir = Path["#{DEFAULT_HOST_WORKDIR}"]
          end
        end
      else
        @namespace = Namespace::Host
      end

      raise "Invalid namespace: #{@namespace}" unless [Namespace::Host, Namespace::Seed, Namespace::BQ2].includes?(@namespace)

      assign_paths(@namespace)
    end

    def self.detect : SysrootWorkspace
      new
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
      sysroot_path = workspace.sysroot_path || raise "Missing sysroot path for host workspace"
      FileUtils.mkdir_p(sysroot_path)
      FileUtils.mkdir_p(workspace.bq2_rootfs_path)
      File.write(workspace.marker_path, "bq2-rootfs\n") unless File.exists?(workspace.marker_path)
      FileUtils.mkdir_p(workspace.workspace_path)
      FileUtils.mkdir_p(workspace.log_path)
      workspace
    end

    def self.from_outer_rootfs(rootfs_root : Path, extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path)) : SysrootWorkspace
      build_for(Namespace::Seed, host_workdir: nil, seed_rootfs_root: rootfs_root, extra_binds: extra_binds)
    end

    def self.from_inner_rootfs(rootfs_root : Path, extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path)) : SysrootWorkspace
      build_for(Namespace::BQ2, host_workdir: nil, seed_rootfs_root: rootfs_root, extra_binds: extra_binds)
    end

    def namespace_name : String
      case @namespace
      when .host?
        "host"
      when .seed?
        "seed"
      else
        "bq2"
      end
    end

    def outer_rootfs_path : Path?
      @seed_rootfs_path
    end

    def inner_rootfs_path : Path
      @bq2_rootfs_path
    end

    def inner_workspace_path : Path
      @workspace_path
    end

    def rootfs_workspace_path : Path
      @workspace_path
    end

    def var_lib_dir : Path
      @log_path
    end

    def sources_dir : Path
      if @host_workdir
        @host_workdir.not_nil! / Path["#{SOURCES_DIR_NAME}"]
      else
        @workspace_path / Path["#{SOURCES_DIR_NAME}"]
      end
    end

    def cache_dir : Path
      if @host_workdir
        @host_workdir.not_nil! / Path["#{CACHE_DIR_NAME}"]
      else
        @workspace_path / Path["#{CACHE_DIR_NAME}"]
      end
    end

    def enter_bq2_rootfs_namespace
      raise "Namespace must be host or seed to enter bq2" if @namespace == Namespace::BQ2
      SysrootNamespace.enter_rootfs(@bq2_rootfs_path.to_s, extra_binds: @extra_binds)
      assign_paths(Namespace::BQ2)
    end

    def enter_seed_rootfs_namespace
      raise "Namespace must be host to enter seed" unless @namespace == Namespace::Host
      raise "Missing seed rootfs path" unless @seed_rootfs_path
      SysrootNamespace.enter_rootfs(@seed_rootfs_path.not_nil!.to_s, extra_binds: @extra_binds)
      assign_paths(Namespace::Seed)
    end

    private def self.build_for(namespace : Namespace, host_workdir : Path?, seed_rootfs_root : Path?, extra_binds : Array(Tuple(Path, Path))) : SysrootWorkspace
      workspace = SysrootWorkspace.allocate
      workspace.initialize_for(namespace, host_workdir, seed_rootfs_root, extra_binds)
      workspace
    end

    protected def initialize_for(namespace : Namespace, host_workdir : Path?, seed_rootfs_root : Path?, extra_binds : Array(Tuple(Path, Path))) : Nil
      @host_workdir = host_workdir
      @extra_binds = extra_binds
      assign_paths(namespace, seed_rootfs_root)
    end

    private def assign_paths(namespace : Namespace, seed_rootfs_root : Path? = nil) : Nil
      @namespace = namespace
      case @namespace
      when .host?
        @seed_rootfs_path = self.class.seed_rootfs_from(@namespace, @host_workdir)
      when .seed?
        @seed_rootfs_path = seed_rootfs_root || Path["/"]
      when .bq2?
        @seed_rootfs_path = nil
      end
      @sysroot_path = case @namespace
                      when .bq2?
                        Path["/#{SYSROOT_DIR_NAME}"]
                      else
                        self.class.sysroot_from(@namespace, @host_workdir) || @seed_rootfs_path.try { |path| path / Path["#{SYSROOT_DIR_NAME}"] }
                      end
      @bq2_rootfs_path = case @namespace
                         when .bq2?
                           seed_rootfs_root || Path["/"]
                         when .seed?
                           @seed_rootfs_path.not_nil! / Path["#{BQ2_DIR_NAME}"]
                         else
                           self.class.bq2_rootfs_from(@namespace, @host_workdir)
                         end
      @marker_path = @bq2_rootfs_path / Path["#{ROOTFS_MARKER_NAME}"]
      @workspace_path = @bq2_rootfs_path / Path["#{WORKSPACE_DIR_NAME}"]
      @log_path = @bq2_rootfs_path / Path["#{LOG_DIR_NAME}"]
    end
  end
end
