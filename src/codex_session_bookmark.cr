require "file_utils"
require "path"
require "time"

module Bootstrap
  # Manages a small bookmark file that records the last Codex session id used in
  # an iteration workspace.
  #
  # This enables `bq2 codex-namespace` to resume the same interactive Codex
  # session across multiple namespace entries by invoking `codex resume <id>`.
  module CodexSessionBookmark
    SESSION_FILENAME = ".codex-session-id"

    # Returns the bookmark file path used to store the Codex session id.
    def self.path(work_dir : Path = Path["/work"]) : Path
      work_dir / SESSION_FILENAME
    end

    # Read the bookmarked session id from *work_dir*, returning nil when absent.
    def self.read(work_dir : Path = Path["/work"]) : String?
      bookmark = path(work_dir)
      return nil unless File.exists?(bookmark)
      value = File.read(bookmark).strip
      value.empty? ? nil : value
    rescue ex : File::Error
      nil
    end

    # Write a bookmarked session id into *work_dir*.
    def self.write(work_dir : Path, session_id : String) : Nil
      FileUtils.mkdir_p(work_dir)
      File.write(path(work_dir), session_id.strip + "\n")
    end

    # Extract the most recently modified session id from a Codex home directory
    # that contains `sessions/**/*.jsonl` files.
    def self.latest_from(codex_home : Path) : String?
      sessions_dir = codex_home / "sessions"
      return nil unless Dir.exists?(sessions_dir)

      best_id = nil
      best_mtime = nil
      Dir.glob((sessions_dir / "**/*.jsonl").to_s).each do |file|
        id = extract_id(file)
        next unless id
        mtime = File.info(file).modification_time
        if best_mtime.nil? || mtime > best_mtime.not_nil!
          best_mtime = mtime
          best_id = id
        end
      end
      best_id
    end

    # Extract a Codex UUID session id from a sessions file path, returning nil
    # when the filename does not contain a UUID.
    def self.extract_id(path : String) : String?
      if match = path.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)
        return match[0]
      end
      nil
    end
  end
end
