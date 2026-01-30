require "path"

module Bootstrap
  # Minimal rootfs workspace helpers anchored on the .bq2-rootfs marker.
  #
  # Two stable references:
  # - inner_rootfs_path: directory that contains .bq2-rootfs.
  # - outer_rootfs_path: directory two levels above .bq2-rootfs (outer /workspace).
  #
  # All sysroot build plan/state/override/report paths live under
  # inner_rootfs_path/var/lib.
  module SysrootWorkspace
    ROOTFS_MARKER_NAME = ".bq2-rootfs"
    ROOTFS_WORKSPACE   = Path["/workspace"]
    OUTER_ROOTFS_PATH  = ROOTFS_WORKSPACE / "rootfs"
    INNER_MARKER_PATH  = Path["/#{ROOTFS_MARKER_NAME}"]
    OUTER_MARKER_PATH  = OUTER_ROOTFS_PATH / ROOTFS_MARKER_NAME

    # Return the directory that contains the .bq2-rootfs marker.
    # Raises when the marker cannot be found.
    def self.inner_rootfs_path : Path
      return Path["/"] if File.exists?(INNER_MARKER_PATH)
      return OUTER_ROOTFS_PATH if File.exists?(OUTER_MARKER_PATH)
      raise "Missing inner rootfs marker at #{INNER_MARKER_PATH} or #{OUTER_MARKER_PATH}"
    end

    # Return the outer workspace path inferred from the inner marker.
    # Raises when the marker is not visible from the outer rootfs.
    def self.outer_rootfs_path : Path
      return ROOTFS_WORKSPACE if File.exists?(OUTER_MARKER_PATH)
      raise "Missing outer rootfs marker at #{OUTER_MARKER_PATH}"
    end

    # Returns true when running inside the inner rootfs.
    def self.inner_rootfs_marker_present? : Bool
      marker_override = ENV["BQ2_ROOTFS_MARKER"]?
      return true if marker_override && File.exists?(marker_override)
      File.exists?(INNER_MARKER_PATH)
    end

    # Returns true when the inner rootfs marker is visible from the outer rootfs.
    def self.outer_rootfs_marker_present? : Bool
      File.exists?(OUTER_MARKER_PATH)
    end

    # Inner rootfs var/lib directory that stores plans/state/overrides/reports.
    def self.inner_var_lib_dir : Path
      inner_rootfs_path / "var/lib"
    end

    # Inner rootfs build plan path.
    def self.plan_path : Path
      inner_var_lib_dir / "sysroot-build-plan.json"
    end

    # Inner rootfs build overrides path.
    def self.overrides_path : Path
      inner_var_lib_dir / "sysroot-build-overrides.json"
    end

    # Inner rootfs build state path.
    def self.state_path : Path
      inner_var_lib_dir / "sysroot-build-state.json"
    end

    # Inner rootfs build report directory.
    def self.report_dir : Path
      inner_var_lib_dir / "sysroot-build-reports"
    end

    # Inner rootfs workspace path (where sources are staged).
    def self.inner_workspace_path : Path
      inner_rootfs_path / "workspace"
    end
  end
end
