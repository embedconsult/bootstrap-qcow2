require "file_utils"
require "path"

module Bootstrap
  # Rootfs workspace helpers anchored on the .bq2-rootfs marker.
  #
  # Three stable references:
  # - inner_rootfs_path: directory that contains .bq2-rootfs (host:
  #   <host_workdir>/rootfs/workspace/rootfs).
  # - rootfs_workspace_path: directory that contains the inner rootfs (host:
  #   <host_workdir>/rootfs/workspace, outer rootfs: /workspace).
  # - outer_rootfs_path: directory containing the rootfs workspace (host:
  #   <host_workdir>/rootfs, outer rootfs: /).
  #
  # The outer rootfs lives at <host_workdir>/rootfs on the host, and at / when
  # running inside the outer rootfs namespace. The rootfs workspace lives at
  # <host_workdir>/rootfs/workspace on the host and at /workspace in the outer
  # rootfs namespace.
  class SysrootWorkspace
    ROOTFS_MARKER_NAME   = ".bq2-rootfs"
    DEFAULT_HOST_WORKDIR = Path["data/sysroot"]

    ROOTFS_WORKSPACE_PATH = Path["/workspace"]
    OUTER_ROOTFS_DIR      = Path["rootfs"]
    ROOTFS_WORKSPACE_DIR  = Path["rootfs/workspace"]
    INNER_ROOTFS_DIR      = Path["rootfs/workspace/rootfs"]
    INNER_WORKSPACE_DIR   = Path["rootfs/workspace/rootfs/workspace"]
    INNER_VAR_LIB_DIR     = Path["rootfs/workspace/rootfs/var/lib"]
    WORKSPACE_DIR         = INNER_WORKSPACE_DIR
    LOG_DIR               = INNER_VAR_LIB_DIR

    INNER_ROOTFS_PATH_IN_OUTER    = ROOTFS_WORKSPACE_PATH / "rootfs"
    INNER_WORKSPACE_PATH_IN_OUTER = ROOTFS_WORKSPACE_PATH / "rootfs/workspace"

    INNER_MARKER_PATH = Path["/#{ROOTFS_MARKER_NAME}"]
    OUTER_MARKER_PATH = Path["/workspace/rootfs/#{ROOTFS_MARKER_NAME}"]

    getter host_workdir : Path?
    getter inner_rootfs_path : Path

    def initialize(@inner_rootfs_path : Path,
                   @rootfs_workspace_path : Path? = nil,
                   @outer_rootfs_path : Path? = nil,
                   @host_workdir : Path? = nil)
    end

    # Create a workspace rooted at *host_workdir*, ensuring marker + dirs exist.
    def self.create(host_workdir : Path) : SysrootWorkspace
      workspace = from_host_workdir(host_workdir)
      FileUtils.mkdir_p(workspace.outer_rootfs_path)
      FileUtils.mkdir_p(workspace.rootfs_workspace_path)
      FileUtils.mkdir_p(workspace.inner_rootfs_path)
      FileUtils.mkdir_p(workspace.var_lib_dir)
      FileUtils.mkdir_p(workspace.inner_workspace_path)
      File.write(workspace.marker_path, "bq2-rootfs\n") unless File.exists?(workspace.marker_path)
      workspace
    end

    # Build a workspace rooted at *host_workdir* without mutating the filesystem.
    def self.from_host_workdir(host_workdir : Path) : SysrootWorkspace
      inner_rootfs_path = host_workdir / INNER_ROOTFS_DIR
      rootfs_workspace_path = host_workdir / ROOTFS_WORKSPACE_DIR
      outer_rootfs_path = host_workdir / OUTER_ROOTFS_DIR
      new(inner_rootfs_path, rootfs_workspace_path: rootfs_workspace_path, outer_rootfs_path: outer_rootfs_path, host_workdir: host_workdir)
    end

    # Build a workspace rooted at an outer rootfs directory.
    def self.from_outer_rootfs(outer_rootfs_path : Path) : SysrootWorkspace
      inner_rootfs_path = outer_rootfs_path / "workspace/rootfs"
      rootfs_workspace_path = outer_rootfs_path / "workspace"
      host_workdir = nil
      if outer_rootfs_path.absolute? && outer_rootfs_path.to_s.ends_with?("/#{OUTER_ROOTFS_DIR}")
        host_workdir = outer_rootfs_path.parent
      end
      new(
        inner_rootfs_path,
        rootfs_workspace_path: rootfs_workspace_path,
        outer_rootfs_path: outer_rootfs_path,
        host_workdir: host_workdir
      )
    end

    # Build a workspace rooted at an inner rootfs directory.
    def self.from_inner_rootfs(inner_rootfs_path : Path) : SysrootWorkspace
      host_workdir = nil
      if inner_rootfs_path.absolute? && inner_rootfs_path.to_s.ends_with?("/#{INNER_ROOTFS_DIR}")
        host_workdir = inner_rootfs_path.parent.parent.parent
      end
      new(inner_rootfs_path, host_workdir: host_workdir)
    end

    # Detect the workspace for the current namespace, optionally anchored by *host_workdir*.
    def self.detect(host_workdir : Path? = DEFAULT_HOST_WORKDIR) : SysrootWorkspace
      if host_workdir
        candidate = from_host_workdir(host_workdir)
        return candidate if File.exists?(candidate.marker_path)
      end

      if File.exists?(INNER_MARKER_PATH)
        return new(Path["/"], rootfs_workspace_path: nil, outer_rootfs_path: nil)
      end

      if File.exists?(OUTER_MARKER_PATH)
        return from_outer_rootfs(Path["/"])
      end

      return from_host_workdir(host_workdir) if host_workdir

      raise "Missing inner rootfs marker at #{INNER_MARKER_PATH} or #{OUTER_MARKER_PATH}"
    end

    # Returns true when running inside the inner rootfs.
    def self.inner_rootfs_marker_present? : Bool
      marker_override = ENV["BQ2_ROOTFS_MARKER"]?
      return true if marker_override && File.exists?(marker_override)
      File.exists?(INNER_MARKER_PATH)
    end

    # Returns true when the inner rootfs marker is visible from the outer rootfs.
    def self.outer_rootfs_marker_present? : Bool
      marker_override = ENV["BQ2_OUTER_ROOTFS_MARKER"]?
      return true if marker_override && File.exists?(marker_override)
      File.exists?(OUTER_MARKER_PATH)
    end

    # Return the outer rootfs path when available for this workspace.
    def outer_rootfs_path : Path
      @outer_rootfs_path || raise "Outer rootfs path is not available for this workspace"
    end

    # Return the rootfs workspace path when available for this workspace.
    def rootfs_workspace_path : Path
      if path = @rootfs_workspace_path
        return path
      end
      return host_workdir.not_nil! / ROOTFS_WORKSPACE_DIR if host_workdir
      raise "Rootfs workspace path is not available for this workspace"
    end

    # Translate *path* from host workspace coordinates into the current rootfs
    # namespace when running inside the outer or inner rootfs.
    #
    # Host absolute paths are left untouched unless they point at the inner
    # rootfs tree (for example, the host's rootfs workspace). When running in
    # a rootfs namespace, paths under the host's inner rootfs are rewritten to
    # the inner rootfs mountpoint (/workspace/rootfs for the outer rootfs, or
    # / for the inner rootfs).
    def path_for_context(path : String) : String
      return path unless host_workdir

      inner_rootfs = inner_rootfs_path.to_s
      return path unless path.starts_with?(inner_rootfs)

      suffix = path[inner_rootfs.size..-1] || ""
      suffix = suffix.lstrip('/')

      if SysrootWorkspace.inner_rootfs_marker_present?
        return suffix.empty? ? "/" : "/#{suffix}"
      end

      if SysrootWorkspace.outer_rootfs_marker_present?
        return suffix.empty? ? INNER_ROOTFS_PATH_IN_OUTER.to_s : (INNER_ROOTFS_PATH_IN_OUTER / suffix).to_s
      end

      path
    end

    # Convert a path in the current namespace back into a rootfs-absolute path.
    #
    # This is useful for normalizing report paths so status tooling can resolve
    # them consistently from the host.
    def rootfs_path_for_context(path : String) : String
      return path if SysrootWorkspace.inner_rootfs_marker_present?
      return path unless host_workdir

      inner_rootfs = inner_rootfs_path.to_s
      if path.starts_with?(inner_rootfs)
        suffix = path[inner_rootfs.size..-1] || ""
        suffix = suffix.lstrip('/')
        return suffix.empty? ? "/" : "/#{suffix}"
      end

      if SysrootWorkspace.outer_rootfs_marker_present?
        outer_prefix = INNER_ROOTFS_PATH_IN_OUTER.to_s
        if path.starts_with?(outer_prefix)
          suffix = path[outer_prefix.size..-1] || ""
          suffix = suffix.lstrip('/')
          return suffix.empty? ? "/" : "/#{suffix}"
        end
      end

      path
    end

    # Path to the .bq2-rootfs marker inside the inner rootfs.
    def marker_path : Path
      inner_rootfs_path / ROOTFS_MARKER_NAME
    end

    # Inner rootfs workspace path (where sources are staged).
    def inner_workspace_path : Path
      return host_workdir.not_nil! / WORKSPACE_DIR if host_workdir
      inner_rootfs_path / "workspace"
    end

    # Inner rootfs var/lib directory that stores plans/state/overrides/reports.
    def var_lib_dir : Path
      return host_workdir.not_nil! / LOG_DIR if host_workdir
      inner_rootfs_path / "var/lib"
    end
  end
end
