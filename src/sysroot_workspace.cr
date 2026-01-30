require "log"
require "path"

module Bootstrap
  # Shared defaults for sysroot workspace paths and rootfs marker detection.
  #
  # Terminology alignment (see README "Usage" and AGENTS.md):
  # - Host working directory: `data/sysroot` in the checkout.
  # - Rootfs (outer): the seed/rootfs namespace running on the host.
  # - Rootfs (inner): the generated rootfs mounted inside the outer rootfs.
  # - Rootfs marker: `/.bq2-rootfs` inside the inner rootfs.
  #
  # What "workspace" means in each namespace:
  # - Host working directory: `data/sysroot` is the root for builder artifacts
  #   (cache, sources, and the seed rootfs). It is not the same as `/workspace`.
  # - Outer rootfs: `/` is a bind mount of `data/sysroot/rootfs`. `/workspace`
  #   is a subdirectory of that rootfs and corresponds to the host path
  #   `data/sysroot/rootfs/workspace`.
  # - Inner rootfs: `/workspace` is a bind mount of
  #   `data/sysroot/rootfs/workspace/rootfs/workspace` from the host.
  #
  # Host path equivalents for the rootfs workspaces:
  # - Outer rootfs workspace on host: data/sysroot/rootfs/workspace
  # - Inner rootfs workspace on host: data/sysroot/rootfs/workspace/rootfs/workspace
  #
  # This module centralizes both:
  # - Path constants for "where /workspace lives" in each context.
  # - Detection of whether we are inside the inner rootfs (marker/env flag).
  # - Mount/bind checks for /workspace when running in the outer rootfs.
  # - Location of the inner rootfs var/lib directory that hosts build plans,
  #   overrides, state, and failure reports.
  #
  # It is referenced by:
  # - SysrootBuilder: host working directory defaults + plan roots for /workspace.
  # - SysrootRunner: marker detection + namespace entry logic.
  # - SysrootNamespace: default rootfs path + bind target selection.
  module SysrootWorkspace
    DEFAULT_WORKSPACE            = Path["data/sysroot"]
    ROOTFS_WORKSPACE             = Path["/workspace"]
    ROOTFS_MARKER_NAME           = ".bq2-rootfs"
    ROOTFS_MARKER_PATH           = Path["/#{ROOTFS_MARKER_NAME}"]
    WORKSPACE_ROOTFS             = ROOTFS_WORKSPACE / "rootfs"
    WORKSPACE_ROOTFS_MARKER_PATH = WORKSPACE_ROOTFS / ROOTFS_MARKER_NAME
    ROOTFS_ENV_FLAG              = "BQ2_ROOTFS"

    # Returns true when a rootfs marker is present (env override or marker file).
    def self.rootfs_marker_present? : Bool
      return true if env_flag_enabled?(ROOTFS_ENV_FLAG)
      File.exists?(ROOTFS_MARKER_PATH)
    end

    # Returns true when an environment flag is set to a truthy value.
    def self.env_flag_enabled?(name : String, default : Bool = false) : Bool
      value = ENV[name]?
      return default unless value
      normalized = value.strip.downcase
      return default if normalized.empty?
      !(%w[0 false no].includes?(normalized))
    end

    # Default workspace directory for sysroot operations.
    def self.default_workspace : Path
      return ROOTFS_WORKSPACE if rootfs_marker_present?
      DEFAULT_WORKSPACE
    end

    # Host path for the sysroot workspace root.
    def self.host_workspace_root : Path
      DEFAULT_WORKSPACE
    end

    # Host path for the outer rootfs directory (data/sysroot/rootfs).
    def self.host_rootfs_dir(workspace : Path = host_workspace_root) : Path
      workspace / "rootfs"
    end

    # Host path to the outer rootfs workspace (data/sysroot/rootfs/workspace).
    def self.host_rootfs_workspace(workspace : Path = host_workspace_root) : Path
      host_rootfs_dir(workspace) / "workspace"
    end

    # Host path to the inner rootfs directory (data/sysroot/rootfs/workspace/rootfs).
    def self.host_inner_rootfs_dir(workspace : Path = host_workspace_root) : Path
      host_rootfs_workspace(workspace) / "rootfs"
    end

    # Host path to the inner rootfs workspace (data/sysroot/rootfs/workspace/rootfs/workspace).
    def self.host_inner_rootfs_workspace(workspace : Path = host_workspace_root) : Path
      host_inner_rootfs_dir(workspace) / "workspace"
    end

    # Default rootfs directory derived from the workspace.
    def self.default_rootfs : Path
      default_workspace / "rootfs"
    end

    # Inner rootfs directory resolved from the current context.
    #
    # Priority:
    # - Explicit rootfs path.
    # - Inner rootfs marker (we are already inside).
    # - Workspace rootfs marker (outer rootfs sees /workspace/rootfs).
    # - Host workspace fallback.
    def self.inner_rootfs_dir(workspace : Path = host_workspace_root, rootfs : Path? = nil) : Path
      return rootfs.not_nil! if rootfs
      return Path["/"] if rootfs_marker_present?
      return WORKSPACE_ROOTFS if workspace_rootfs_present?
      host_inner_rootfs_dir(workspace)
    end

    # Inner rootfs var/lib directory resolved from the current context.
    def self.inner_var_lib_dir(workspace : Path = host_workspace_root, rootfs : Path? = nil) : Path
      inner_rootfs_dir(workspace, rootfs) / "var/lib"
    end

    # Inner rootfs build plan path resolved from the current context.
    def self.plan_path(workspace : Path = host_workspace_root, rootfs : Path? = nil) : Path
      inner_var_lib_dir(workspace, rootfs) / "sysroot-build-plan.json"
    end

    # Inner rootfs build overrides path resolved from the current context.
    def self.overrides_path(workspace : Path = host_workspace_root, rootfs : Path? = nil) : Path
      inner_var_lib_dir(workspace, rootfs) / "sysroot-build-overrides.json"
    end

    # Inner rootfs build state path resolved from the current context.
    def self.state_path(workspace : Path = host_workspace_root, rootfs : Path? = nil) : Path
      inner_var_lib_dir(workspace, rootfs) / "sysroot-build-state.json"
    end

    # Inner rootfs build report directory resolved from the current context.
    def self.report_dir(workspace : Path = host_workspace_root, rootfs : Path? = nil) : Path
      inner_var_lib_dir(workspace, rootfs) / "sysroot-build-reports"
    end

    # Returns true when the workspace rootfs marker exists.
    def self.workspace_rootfs_present? : Bool
      File.exists?(WORKSPACE_ROOTFS_MARKER_PATH)
    end

    # Returns true when /workspace is mounted (bind or otherwise).
    def self.workspace_mount_present? : Bool
      mount_point?(ROOTFS_WORKSPACE)
    end

    # Returns true when /workspace is expected to be a bind mount.
    def self.workspace_bind_required? : Bool
      !rootfs_marker_present?
    end

    # Returns true when /workspace is expected to be mounted and is present.
    def self.workspace_bind_ready? : Bool
      return true unless workspace_bind_required?
      workspace_mount_present?
    end

    # Returns true when the provided path is a mount point.
    private def self.mount_point?(path : Path) : Bool
      mountinfo = "/proc/self/mountinfo"
      return false unless File.exists?(mountinfo)
      File.each_line(mountinfo) do |line|
        parts = line.split(" ", 6)
        next unless parts.size >= 5
        mount_point = parts[4]
        return true if mount_point == path.to_s
      end
      false
    rescue ex
      Log.warn { "Failed to read mountinfo: #{ex.message}" }
      false
    end
  end
end
