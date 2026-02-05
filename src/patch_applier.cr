require "log"
require "path"

module Bootstrap
  # Raised when a unified diff patch cannot be applied.
  class PatchApplyError < Exception
    getter patch_path : String

    # Create a patch error tied to *patch_path* with a human-friendly *message*.
    def initialize(@patch_path : String, message : String)
      super(message)
    end
  end

  # Summarizes which files were changed or skipped after applying a patch.
  struct PatchApplyResult
    getter applied_files : Array(String)
    getter skipped_files : Array(String)

    # Create a new patch result with applied and skipped file lists.
    def initialize(@applied_files : Array(String), @skipped_files : Array(String))
    end

    # Return true when the patch resulted in no changes because it was already applied.
    def already_applied? : Bool
      @applied_files.empty? && @skipped_files.any?
    end
  end

  # Apply unified diff patches without relying on external tooling.
  class PatchApplier
    private enum ApplyDisposition
      Applied
      Skipped
    end

    private enum Direction
      Forward
      Reverse
    end

    private struct HunkLine
      getter kind : Char
      getter text : String

      # Create a hunk line with a leading *kind* marker and its *text* content.
      def initialize(@kind : Char, @text : String)
      end
    end

    private struct Hunk
      getter old_start : Int32
      getter old_count : Int32
      getter new_start : Int32
      getter new_count : Int32
      getter lines : Array(HunkLine)

      # Create a diff hunk with positional metadata and content lines.
      def initialize(@old_start : Int32, @old_count : Int32, @new_start : Int32, @new_count : Int32, @lines : Array(HunkLine))
      end
    end

    private class FilePatch
      property old_path : String
      property new_path : String
      getter hunks : Array(Hunk)

      # Create a patch entry with old/new paths and its list of hunks.
      def initialize(@old_path : String, @new_path : String, @hunks : Array(Hunk))
      end

      # Return the display path used for logging and reporting.
      def display_path : String
        path = new_path == "/dev/null" ? old_path : new_path
        path.sub(%r{\A[ab]/}, "")
      end
    end

    @root : Path

    # Create a new patch applier rooted at *root*.
    def initialize(@root : Path = Path["."])
    end

    # Apply a patch file located at *patch_path* and return a summary of changes.
    def apply(patch_path : String) : PatchApplyResult
      patch_text = File.read(patch_path)
      file_patches = parse_patch(patch_text)
      raise PatchApplyError.new(patch_path, "No diff entries found") if file_patches.empty?

      applied = [] of String
      skipped = [] of String

      file_patches.each do |file_patch|
        disposition = apply_file_patch(file_patch)
        case disposition
        when ApplyDisposition::Applied
          applied << file_patch.display_path
        when ApplyDisposition::Skipped
          skipped << file_patch.display_path
        end
      end

      PatchApplyResult.new(applied, skipped)
    rescue ex : PatchApplyError
      raise PatchApplyError.new(patch_path, ex.message || "Patch failed")
    rescue ex
      raise PatchApplyError.new(patch_path, ex.message || "Patch failed")
    end

    # Parse unified diff content into file patch entries.
    private def parse_patch(patch_text : String) : Array(FilePatch)
      lines = patch_text.split('\n', remove_empty: false)
      file_patches = [] of FilePatch
      index = 0

      while index < lines.size
        line = lines[index]
        unless line.starts_with?("diff --git ")
          index += 1
          next
        end

        old_path, new_path = parse_diff_paths(line)
        file_patch = FilePatch.new(old_path, new_path, [] of Hunk)
        index += 1

        while index < lines.size
          header = lines[index]
          break if header.starts_with?("diff --git ")

          if header.starts_with?("--- ")
            file_patch.old_path = extract_path(header, "--- ")
            index += 1
            if index < lines.size && lines[index].starts_with?("+++ ")
              file_patch.new_path = extract_path(lines[index], "+++ ")
              index += 1
            end
            next
          end

          if header.starts_with?("@@ ")
            hunk, index = parse_hunk(lines, index)
            file_patch.hunks << hunk
            next
          end

          index += 1
        end

        file_patches << file_patch
      end

      file_patches
    end

    # Parse a diff --git header into old and new paths.
    private def parse_diff_paths(line : String) : {String, String}
      parts = line.split(" ")
      old_path = parts[-2]? || ""
      new_path = parts[-1]? || ""
      {old_path, new_path}
    end

    # Extract a path token from a line that starts with *prefix*.
    private def extract_path(line : String, prefix : String) : String
      token = line[prefix.size..]?.to_s
      token.split(/\s+/).first? || ""
    end

    # Parse a unified diff hunk starting at *start_index*.
    private def parse_hunk(lines : Array(String), start_index : Int32) : {Hunk, Int32}
      header = lines[start_index]
      match = /@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.match(header)
      raise PatchApplyError.new("unknown", "Invalid hunk header: #{header}") unless match

      old_start = match[1].to_i
      # Unified diff counts default to 1 when omitted per GNU diffutils documentation.
      old_count = (match[2]? || "1").to_i
      new_start = match[3].to_i
      new_count = (match[4]? || "1").to_i

      hunk_lines = [] of HunkLine
      index = start_index + 1

      while index < lines.size
        line = lines[index]
        break if line.starts_with?("diff --git ") || line.starts_with?("@@ ")
        if line.starts_with?("\\")
          index += 1
          next
        end
        kind = line[0]?
        break unless kind
        unless kind == ' ' || kind == '+' || kind == '-'
          break
        end
        hunk_lines << HunkLine.new(kind, line[1..])
        index += 1
      end

      {Hunk.new(old_start, old_count, new_start, new_count, hunk_lines), index}
    end

    # Apply a file patch, returning whether it was applied or skipped.
    private def apply_file_patch(file_patch : FilePatch) : ApplyDisposition
      target_path = resolve_target_path(file_patch)
      lines = read_lines(target_path, allow_missing: allow_missing?(file_patch))

      if file_patch.old_path == "/dev/null" && File.exists?(target_path) && lines.any?
        return ApplyDisposition::Skipped if can_apply?(lines, file_patch, Direction::Reverse)
        raise PatchApplyError.new(target_path.to_s, "Refusing to overwrite existing file #{file_patch.display_path}")
      end

      if can_apply?(lines, file_patch, Direction::Forward)
        updated = apply_hunks(lines, file_patch, Direction::Forward)
        persist_lines(target_path, updated, delete_after: file_patch.new_path == "/dev/null")
        return ApplyDisposition::Applied
      end

      if can_apply?(lines, file_patch, Direction::Reverse)
        return ApplyDisposition::Skipped
      end

      raise PatchApplyError.new(target_path.to_s, "Hunks failed to apply for #{file_patch.display_path}")
    end

    # Determine whether a patch can apply cleanly for the given *direction*.
    private def can_apply?(lines : Array(String), file_patch : FilePatch, direction : Direction) : Bool
      apply_hunks(lines, file_patch, direction)
      true
    rescue ex : PatchApplyError
      Log.debug { "Patch dry-run failed for #{file_patch.display_path} (#{direction}): #{ex.message}" }
      false
    end

    # Apply hunks to *lines* in the given *direction*.
    private def apply_hunks(lines : Array(String), file_patch : FilePatch, direction : Direction) : Array(String)
      updated = lines.dup
      offset = 0

      file_patch.hunks.each do |hunk|
        start = direction == Direction::Forward ? hunk.old_start : hunk.new_start
        index = start - 1 + offset
        index = 0 if index < 0
        hunk.lines.each do |hunk_line|
          case hunk_line.kind
          when ' '
            assert_line(updated, index, hunk_line.text, file_patch)
            index += 1
          when '-'
            if direction == Direction::Forward
              assert_line(updated, index, hunk_line.text, file_patch)
              updated.delete_at(index)
            else
              updated.insert(index, hunk_line.text)
              index += 1
            end
          when '+'
            if direction == Direction::Forward
              updated.insert(index, hunk_line.text)
              index += 1
            else
              assert_line(updated, index, hunk_line.text, file_patch)
              updated.delete_at(index)
            end
          else
            raise PatchApplyError.new(file_patch.display_path, "Unsupported hunk line: #{hunk_line.kind}")
          end
        end

        delta = direction == Direction::Forward ? hunk.new_count - hunk.old_count : hunk.old_count - hunk.new_count
        offset += delta
      end

      updated
    end

    # Assert that *lines* contains *expected* at *index*.
    private def assert_line(lines : Array(String), index : Int32, expected : String, file_patch : FilePatch) : Nil
      actual = lines[index]?
      return if actual == expected
      raise PatchApplyError.new(file_patch.display_path, "Expected #{expected.inspect} at #{index + 1}, found #{actual.inspect}")
    end

    # Load file contents as an array of lines without trailing newline characters.
    private def read_lines(path : Path, allow_missing : Bool) : Array(String)
      unless File.exists?(path)
        raise PatchApplyError.new(path.to_s, "Missing file #{path}") unless allow_missing
        return [] of String
      end
      File.read(path).split('\n', remove_empty: false)
    end

    # Persist the patched *lines* to *path*, deleting the file when requested.
    private def persist_lines(path : Path, lines : Array(String), delete_after : Bool) : Nil
      if delete_after
        File.delete?(path)
        return
      end
      FileUtils.mkdir_p(path.parent)
      File.write(path, lines.join("\n"))
    end

    # Resolve the patch target path, applying a -p1 style prefix strip.
    private def resolve_target_path(file_patch : FilePatch) : Path
      raw_path = file_patch.new_path == "/dev/null" ? file_patch.old_path : file_patch.new_path
      stripped = strip_patch_prefix(raw_path)
      @root / stripped
    end

    # Return true when the file may be missing for this patch.
    private def allow_missing?(file_patch : FilePatch) : Bool
      file_patch.old_path == "/dev/null"
    end

    # Strip the leading "a/" or "b/" path component used by unified diff output.
    private def strip_patch_prefix(path : String) : String
      return path if path == "/dev/null"
      path.sub(%r{\A[ab]/}, "")
    end
  end
end
