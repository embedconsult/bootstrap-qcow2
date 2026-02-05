require "digest/crc32"
require "file_utils"
require "log"
require "path"

module Bootstrap
  # Helpers for tarball extraction
  module Tarball
    # Extract a tarball into *destination*.
    def self.extract(path : Path,
                     destination : Path,
                     preserve_ownership : Bool,
                     owner_uid : Int32?,
                     owner_gid : Int32?,
                     force_system_tar : Bool = false,
                     guard_paths : Array(Path) = [] of Path) : Nil
      FileUtils.mkdir_p(destination)
      return run_system_tar_extract(path, destination, preserve_ownership, owner_uid, owner_gid, guard_paths) if force_system_tar
      Extractor.new(path, destination, preserve_ownership, owner_uid, owner_gid, guard_paths).run
    end

    # Extract with system tar when a pure Crystal extraction is not desired.
    private def self.run_system_tar_extract(path : Path,
                                            destination : Path,
                                            preserve_ownership : Bool,
                                            owner_uid : Int32?,
                                            owner_gid : Int32?,
                                            guard_paths : Array(Path)) : Nil
      assert_guard_paths!(path, destination, guard_paths) unless guard_paths.empty?
      args = ["-xf", path.to_s, "-C", destination.to_s]
      if preserve_ownership
        args << "--same-owner"
        args << "--owner=#{owner_uid}" if owner_uid
        args << "--group=#{owner_gid}" if owner_gid
      end
      Log.info { "Running: tar #{args.join(" ")}" }
      status = Process.run("tar", args)
      raise "Failed to extract #{path}" unless status.success?
    end

    def self.assert_guard_paths!(archive : Path, destination : Path, guard_paths : Array(Path)) : Nil
      guard_set = guard_paths.map(&.expand)
      return if guard_set.empty?

      output = IO::Memory.new
      status = Process.run("tar", ["-tf", archive.to_s], output: output)
      raise "Failed to inspect tarball #{archive}" unless status.success?

      output.to_s.each_line do |entry|
        entry = entry.strip
        next if entry.empty?
        entry = entry.sub(%r{^\.?/}, "")
        target = (destination / entry).expand
        if guarded_target?(target, guard_set)
          raise "Refusing to extract #{archive}: entry #{entry} would overwrite #{target}"
        end
      end
    end

    private def self.guarded_target?(target : Path, guard_paths : Array(Path)) : Bool
      target_str = target.to_s
      guard_paths.any? do |guard|
        guard_str = guard.to_s
        target_str == guard_str || target_str.starts_with?(guard_str + "/")
      end
    end

    # Minimal tar extractor/writer implemented in Crystal to avoid shelling out.
    private struct Extractor
      # Create a tar extractor for a single archive.
      def initialize(@archive : Path,
                     @destination : Path,
                     @preserve_ownership : Bool,
                     @owner_uid : Int32?,
                     @owner_gid : Int32?,
                     @guard_paths : Array(Path))
      end

      # Extract the archive contents into the destination.
      def run
        return if fallback_for_unhandled_compression?
        File.open(@archive) do |file|
          io = maybe_gzip(file)
          TarReader.new(io, @destination, @preserve_ownership, @owner_uid, @owner_gid, @guard_paths).extract_all
        end
      end

      # Wrap gzip compressed archives in a gzip reader.
      private def maybe_gzip(io : IO) : IO
        if @archive.to_s.ends_with?(".gz")
          Compress::Gzip::Reader.new(io)
        else
          io
        end
      end

      # Use system tar for compression formats we do not decode in Crystal.
      private def fallback_for_unhandled_compression? : Bool
        if @archive.to_s.ends_with?(".tar.xz") || @archive.to_s.ends_with?(".tar.bz2")
          Tarball.assert_guard_paths!(@archive, @destination, @guard_paths) unless @guard_paths.empty?
          Log.warn { "Running: tar -xf #{@archive} -C #{@destination}" }
          status = Process.run("tar", ["-xf", @archive.to_s, "-C", @destination.to_s])
          raise "Failed to extract #{@archive}" unless status.success?
          true
        else
          false
        end
      end
    end

    private struct TarReader
      # POSIX ustar header layout: offsets/lengths per POSIX.1-1988.
      # Reference: https://pubs.opengroup.org/onlinepubs/009695399/basedefs/tar.h.html
      HEADER_SIZE     = 512
      NAME_OFFSET     =   0
      NAME_LENGTH     = 100
      MODE_OFFSET     = 100
      MODE_LENGTH     =   8
      UID_OFFSET      = 108
      UID_LENGTH      =   8
      GID_OFFSET      = 116
      GID_LENGTH      =   8
      SIZE_OFFSET     = 124
      SIZE_LENGTH     =  12
      MTIME_OFFSET    = 136
      MTIME_LENGTH    =  12
      TYPEFLAG_OFFSET = 156
      LINKNAME_OFFSET = 157
      LINKNAME_LENGTH = 100
      PREFIX_OFFSET   = 345
      PREFIX_LENGTH   = 155

      TYPE_DIRECTORY  = '5'
      TYPE_SYMLINK    = '2'
      TYPE_HARDLINK   = '1'
      TYPE_FILE       = '\u0000'
      TYPE_PAX_EXT    = 'x'
      TYPE_PAX_GLOBAL = 'g'
      # Linux PATH_MAX is 4096 bytes (see /usr/include/linux/limits.h).
      PAX_VALUE_LIMIT = 4096

      # Create a tar reader that writes entries into the destination.
      def initialize(@io : IO,
                     @destination : Path,
                     @preserve_ownership : Bool,
                     @owner_uid : Int32?,
                     @owner_gid : Int32?,
                     @guard_paths : Array(Path))
        @pax_global = {} of String => String
        @pax_next = {} of String => String
      end

      # Extract every entry in the tar stream.
      def extract_all
        deferred_dir_times = [] of Tuple(Path, Int64)
        loop do
          header = Bytes.new(HEADER_SIZE)
          bytes = @io.read_fully?(header)
          break unless bytes == HEADER_SIZE
          break if header.all? { |b| b == 0u8 }

          name = cstring(header[NAME_OFFSET, NAME_LENGTH])
          prefix = cstring(header[PREFIX_OFFSET, PREFIX_LENGTH])
          name = "#{prefix}/#{name}" unless prefix.empty?
          header_uid = octal_to_i(header[UID_OFFSET, UID_LENGTH]).to_i
          header_gid = octal_to_i(header[GID_OFFSET, GID_LENGTH]).to_i
          size = octal_to_i(header[SIZE_OFFSET, SIZE_LENGTH])
          mtime = octal_to_i(header[MTIME_OFFSET, MTIME_LENGTH])
          typeflag = header[TYPEFLAG_OFFSET].chr
          linkname = cstring(header[LINKNAME_OFFSET, LINKNAME_LENGTH])
          normalized_typeflag = typeflag == TYPE_FILE ? TYPE_FILE : typeflag
          normalized_typeflag = TYPE_SYMLINK if normalized_typeflag == TYPE_FILE && !linkname.empty?
          Log.debug { "Tar entry name=#{name} typeflag=#{typeflag.inspect} normalized=#{normalized_typeflag.inspect} linkname=#{linkname}" }

          if normalized_typeflag.in?({TYPE_PAX_GLOBAL, TYPE_PAX_EXT})
            records = read_pax_records(size)
            if normalized_typeflag == TYPE_PAX_GLOBAL
              @pax_global.merge!(records)
            else
              @pax_next = records
            end
            skip_padding(size)
            next
          end

          pax_overrides = @pax_global
          pax_overrides = pax_overrides.merge(@pax_next) unless @pax_next.empty?
          name = pax_overrides["path"]? || name
          linkname = pax_overrides["linkpath"]? || linkname
          @pax_next.clear

          # Skip metadata/empty entries.
          if name.empty? || name == "./" || name.starts_with?("././@PaxHeader")
            skip_bytes(size)
            skip_padding(size)
            next
          end

          target = safe_target_path(name)
          unless target
            Log.warn { "Skipping unsafe tar entry #{name}" }
            skip_bytes(size)
            skip_padding(size)
            next
          end

          if guarded_target?(target)
            raise "Refusing to extract tar entry #{name}: would overwrite #{target}"
          end

          if has_symlink_ancestor?(target)
            Log.warn { "Skipping tar entry #{name} due to symlinked ancestor" }
            skip_bytes(size)
            skip_padding(size)
            next
          end

          if name.ends_with?("/")
            reconcile_existing_target(target, TYPE_DIRECTORY)
            ensure_parent_dir(target)
            FileUtils.mkdir_p(target)
            uid, gid = resolved_owner(header_uid, header_gid)
            apply_ownership(target, uid, gid)
            deferred_dir_times << {target, mtime}
            skip_padding(size)
            next
          end

          uid, gid = resolved_owner(header_uid, header_gid)
          case normalized_typeflag
          when TYPE_DIRECTORY # directory
            reconcile_existing_target(target, TYPE_DIRECTORY)
            ensure_parent_dir(target)
            FileUtils.mkdir_p(target)
            File.chmod(target, header_mode(header))
            apply_ownership(target, uid, gid)
            deferred_dir_times << {target, mtime}
          when TYPE_SYMLINK # symlink
            reconcile_existing_target(target, TYPE_SYMLINK)
            ensure_parent_dir(target)
            FileUtils.mkdir_p(target.parent)
            Log.debug { "Creating symlink #{target} -> #{linkname}" }
            FileUtils.ln_sf(linkname, target)
          when TYPE_HARDLINK # hardlink
            reconcile_existing_target(target, TYPE_HARDLINK)
            ensure_parent_dir(target)
            FileUtils.mkdir_p(target.parent)
            link_target = safe_target_path(linkname)
            unless link_target
              Log.warn { "Skipping unsafe hardlink target #{linkname}" }
              skip_padding(size)
              next
            end
            if has_symlink_ancestor?(link_target)
              Log.warn { "Skipping hardlink #{name} due to symlinked ancestor in #{linkname}" }
              skip_padding(size)
              next
            end
            Log.debug { "Creating hardlink #{target} -> #{link_target}" }
            File.link(link_target, target)
          else # regular file
            reconcile_existing_target(target, TYPE_FILE)
            ensure_parent_dir(target)
            FileUtils.mkdir_p(target.parent)
            write_file(target, size, header_mode(header))
            apply_ownership(target, uid, gid)
            apply_mtime(target, mtime)
          end

          skip_padding(size)
        end

        # Apply directory timestamps after extracting all children; otherwise,
        # subsequent file creation would clobber the directory mtime.
        deferred_dir_times.reverse_each do |(path, entry_mtime)|
          apply_mtime(path, entry_mtime)
        end
      end

      private def guarded_target?(target : Path) : Bool
        target_str = target.to_s
        @guard_paths.any? do |guard|
          guard_str = guard.to_s
          target_str == guard_str || target_str.starts_with?(guard_str + "/")
        end
      end

      # Skip the next *size* bytes in the stream.
      private def skip_bytes(size : Int64)
        @io.skip(size) if size > 0
      end

      # Skip zero padding up to the next 512-byte boundary.
      private def skip_padding(size : Int64)
        remainder = size % HEADER_SIZE
        skip = remainder.zero? ? 0 : HEADER_SIZE - remainder
        @io.skip(skip) if skip > 0
      end

      # Parse PAX header records into a key/value hash.
      private def read_pax_records(size : Int64) : Hash(String, String)
        records = {} of String => String
        return records if size <= 0
        bytes_left = size
        buffer = Bytes.new(IO::DEFAULT_BUFFER_SIZE)
        while bytes_left > 0
          length_digits = String.build do |builder|
            while bytes_left > 0
              byte = @io.read_byte
              raise "Unexpected EOF in tar" unless byte
              bytes_left -= 1
              if byte == ' '.ord
                break
              end
              builder << byte.chr
            end
          end
          break if length_digits.empty?
          length = length_digits.to_i?
          raise "Invalid PAX header length" unless length && length > (length_digits.bytesize + 1)
          record_bytes = length - length_digits.bytesize - 1
          raise "Invalid PAX header length" if record_bytes > bytes_left
          key_builder = String::Builder.new
          value_builder = String::Builder.new
          value_size = 0
          key = ""
          key_done = false
          capture_value = false
          value_too_long = false

          while record_bytes > 0
            to_read = Math.min(buffer.size, record_bytes.to_i)
            read = @io.read(buffer[0, to_read])
            raise "Unexpected EOF in tar" if read == 0
            slice = buffer[0, read]
            slice.each do |byte|
              if key_done
                next unless capture_value
                next if value_too_long
                if value_size < PAX_VALUE_LIMIT
                  value_builder << byte.chr
                  value_size += 1
                else
                  value_too_long = true
                end
              else
                if byte == '='.ord
                  key_done = true
                  key = key_builder.to_s
                  capture_value = key == "path" || key == "linkpath"
                else
                  key_builder << byte.chr
                end
              end
            end
            record_bytes -= read
            bytes_left -= read
          end

          if capture_value
            if value_too_long
              Log.warn { "Skipping PAX #{key} longer than PATH_MAX (#{PAX_VALUE_LIMIT})" }
            else
              value = value_builder.to_s.chomp
              records[key] = value
            end
          end
        end
        records
      end

      # Write a file payload from the tar stream to disk.
      private def write_file(path : Path, size : Int64, mode : Int32)
        File.open(path, "w") do |target_io|
          bytes_left = size
          buffer = Bytes.new(8192)
          while bytes_left > 0
            to_read = Math.min(buffer.size, bytes_left.to_i)
            read = @io.read(buffer[0, to_read])
            raise "Unexpected EOF in tar" if read == 0
            target_io.write(buffer[0, read])
            bytes_left -= read
          end
        end
        File.chmod(path, mode)
      end

      # Ensure the parent path is a directory, removing conflicting entries.
      private def ensure_parent_dir(target : Path)
        parent = target.parent
        return if parent == @destination
        info = File.info(parent, follow_symlinks: false) rescue nil
        if info && !info.directory?
          FileUtils.rm_rf(parent)
        end
      end

      # Return true if any ancestor path component is a symlink.
      private def has_symlink_ancestor?(target : Path) : Bool
        relative = target.relative_to(@destination) rescue nil
        return true unless relative
        parts = relative.to_s.split('/')
        current = @destination
        parts[0...-1].each do |part|
          current /= part
          info = File.info(current, follow_symlinks: false) rescue nil
          return true if info && info.symlink?
        end
        false
      end

      # Remove conflicting paths to allow tar entries to replace them.
      private def reconcile_existing_target(target : Path, entry_type : Char)
        info = File.info(target, follow_symlinks: false) rescue nil
        return unless info
        case entry_type
        when TYPE_DIRECTORY
          FileUtils.rm_rf(target) unless info.directory?
        when TYPE_SYMLINK, TYPE_HARDLINK
          if info.directory?
            FileUtils.rm_rf(target)
          else
            File.delete?(target)
          end
        else
          if info.directory?
            FileUtils.rm_rf(target)
          elsif info.symlink?
            File.delete?(target)
          end
        end
      end

      private def apply_mtime(path : Path, mtime : Int64)
        return if mtime <= 0
        time = Time.unix(mtime)
        File.utime(time, time, path)
      rescue ex
        Log.warn { "Failed to apply mtime to #{path}: #{ex.message}" }
      end

      # Resolve uid/gid ownership for an entry based on preservation settings.
      private def resolved_owner(header_uid : Int32, header_gid : Int32) : {Int32?, Int32?}
        return {nil, nil} unless @preserve_ownership
        {(@owner_uid || header_uid), (@owner_gid || header_gid)}
      end

      # Apply ownership metadata to a path when requested.
      private def apply_ownership(path : Path, uid : Int32?, gid : Int32?)
        return unless @preserve_ownership
        return unless uid || gid
        File.chown(path, uid || -1, gid || -1)
      rescue ex
        Log.warn { "Failed to apply ownership to #{path}: #{ex.message}" }
      end

      # Ensure a tar entry stays within the destination root.
      private def safe_target_path(name : String) : Path?
        return nil if name.starts_with?("/")
        clean = name
        while clean.starts_with?("./")
          clean = clean[2..] || ""
        end
        return nil if clean.empty?
        parts = clean.split('/')
        return nil if parts.any? { |part| part == ".." }
        @destination / clean
      end

      # Decode a NUL-terminated byte slice into a string.
      private def cstring(bytes : Bytes) : String
        String.new(bytes).split("\0", 2)[0].to_s
      end

      # Parse an octal-encoded integer from tar header bytes.
      private def octal_to_i(bytes : Bytes) : Int64
        cleaned = String.new(bytes).tr("\0", "").strip.gsub(/[^0-7]/, "")
        cleaned.empty? ? 0_i64 : cleaned.to_i64(8)
      end

      # Resolve a file mode from a tar header, defaulting to 0755.
      private def header_mode(header : Bytes) : Int32
        mode = octal_to_i(header[MODE_OFFSET, MODE_LENGTH]).to_i
        mode.zero? ? 0o755 : mode
      end
    end
  end
end
