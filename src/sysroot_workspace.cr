require "path"

module Bootstrap
  # Shared defaults for sysroot workspace paths and rootfs marker detection.
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
      if value = ENV[ROOTFS_ENV_FLAG]?
        normalized = value.strip.downcase
        return false if normalized.empty? || normalized == "0" || normalized == "false" || normalized == "no"
        return true
      end
      File.exists?(ROOTFS_MARKER_PATH)
    end

    # Default workspace directory for sysroot operations.
    def self.default_workspace : Path
      return ROOTFS_WORKSPACE if rootfs_marker_present?
      DEFAULT_WORKSPACE
    end

    # Default rootfs directory derived from the workspace.
    def self.default_rootfs : Path
      default_workspace / "rootfs"
    end

    # Returns true when the workspace rootfs marker exists.
    def self.workspace_rootfs_present? : Bool
      File.exists?(WORKSPACE_ROOTFS_MARKER_PATH)
    end
  end
end
