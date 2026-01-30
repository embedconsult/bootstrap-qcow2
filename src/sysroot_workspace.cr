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
    # Resolved rootfs paths used for build plan/state/log locations.
    struct Paths
      getter inner_rootfs_path : Path
      getter outer_rootfs_path : Path?

      def initialize(@inner_rootfs_path : Path, @outer_rootfs_path : Path? = nil)
      end

      def inner_workspace_path : Path
        inner_rootfs_path / "workspace"
      end

      def var_lib_dir : Path
        inner_rootfs_path / "var/lib"
      end
    end

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
      outer_rootfs_path? || raise "Missing outer rootfs marker at #{OUTER_MARKER_PATH}"
    end

    # Return the outer workspace path when visible from the outer rootfs.
    def self.outer_rootfs_path? : Path?
      return ROOTFS_WORKSPACE if File.exists?(OUTER_MARKER_PATH)
      nil
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

    # Inner rootfs workspace path (where sources are staged).
    def self.inner_workspace_path : Path
      inner_rootfs_path / "workspace"
    end

    # Resolve default rootfs paths from the visible rootfs markers.
    def self.default_paths : Paths
      Paths.new(inner_rootfs_path, outer_rootfs_path?)
    end
  end
end
