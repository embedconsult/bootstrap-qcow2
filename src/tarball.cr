require "compress/gzip"
require "digest/crc32"
require "file_utils"
require "log"
require "path"

module Bootstrap
  # Tarball helpers for sysroot extraction and archiving.
  module Tarball
    # Extract a tarball into *destination*.
    def self.extract(path : Path,
                     destination : Path,
                     preserve_ownership : Bool,
                     owner_uid : Int32?,
                     owner_gid : Int32?,
                     force_system_tar : Bool = false) : Nil
      FileUtils.mkdir_p(destination)
      return run_system_tar_extract(path, destination, preserve_ownership, owner_uid, owner_gid) if force_system_tar
      Extractor.new(path, destination, preserve_ownership, owner_uid, owner_gid).run
    end

    # Write a gzipped tarball for *source*, falling back to system tar as needed.
    def self.write_gz(source : Path, output : Path) : Nil
      TarWriter.write_gz(source, output)
    rescue ex
      Log.warn { "Falling back to system tar due to: #{ex.message}" }
      File.delete?(output)
      Log.info { "Running: tar -czf #{output} -C #{source} ." }
      status = Process.run("tar", ["-czf", output.to_s, "-C", source.to_s, "."])
      raise "Failed to create tarball with system tar" unless status.success?
    end

    # Extract with system tar when a pure Crystal extraction is not desired.
    private def self.run_system_tar_extract(path : Path,
                                            destination : Path,
                                            preserve_ownership : Bool,
                                            owner_uid : Int32?,
                                            owner_gid : Int32?) : Nil
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

    # Minimal tar extractor/writer implemented in Crystal to avoid shelling out.
    private struct Extractor
      # Create a tar extractor for a single archive.
      def initialize(@archive : Path, @destination : Path, @preserve_ownership : Bool, @owner_uid : Int32?, @owner_gid : Int32?)
      end

      # Extract the archive contents into the destination.
      def run
        return if fallback_for_unhandled_compression?
        File.open(@archive) do |file|
          io = maybe_gzip(file)
          TarReader.new(io, @destination, @preserve_ownership, @owner_uid, @owner_gid).extract_all
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

      TYPE_DIRECTORY = '5'
      TYPE_SYMLINK   = '2'
      TYPE_HARDLINK  = '1'
      TYPE_FILE      = '\u0000'

      # Create a tar reader that writes entries into the destination.
      def initialize(@io : IO, @destination : Path, @preserve_ownership : Bool, @owner_uid : Int32?, @owner_gid : Int32?)
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

          # Skip metadata/pax headers or empty entries.
          if name.empty? || name == "./" || name.starts_with?("././@PaxHeader") || normalized_typeflag.in?({'g', 'x'})
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

    private struct TarWriter
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
      CHECKSUM_OFFSET = 148
      CHECKSUM_LENGTH =   8
      TYPEFLAG_OFFSET = 156
      LINKNAME_OFFSET = 157
      LINKNAME_LENGTH = 100
      MAGIC_OFFSET    = 257
      VERSION_OFFSET  = 263

      TYPE_DIRECTORY = '5'
      TYPE_SYMLINK   = '2'
      TYPE_FILE      = '0'
      TYPE_PAX       = 'x'

      class LongPathError < Exception; end

      # Write a gzipped tarball for a directory tree.
      def self.write_gz(source : Path, output : Path)
        assert_paths_fit(source)
        File.open(output, "w") do |file|
          Compress::Gzip::Writer.open(file) do |gzip|
            writer = new(gzip, source)
            writer.write_all
          end
        end
      end

      # Create a tar writer rooted at a source directory.
      def initialize(@io : IO, @source : Path)
      end

      # Write every entry in the source tree to the tar stream.
      def write_all
        walk(@source) do |entry, stat|
          relative = Path.new(entry).relative_to(@source).to_s
          if stat.directory?
            write_entry(relative, 0_i64, stat, TYPE_DIRECTORY)
          elsif stat.symlink?
            target = File.readlink(entry)
            write_entry(relative, 0_i64, stat, TYPE_SYMLINK, target)
          else
            write_entry(relative, stat.size, stat, TYPE_FILE)
            File.open(entry) do |file|
              IO.copy(file, @io)
            end
            pad_file(stat.size)
          end
        end
        @io.write(Bytes.new(HEADER_SIZE * 2, 0))
      end

      # Walk the directory tree and yield every entry with its metadata.
      private def walk(path : Path, &block : Path, File::Info ->)
        Dir.children(path).each do |child|
          entry = path / child
          stat = File.info(entry, follow_symlinks: false)
          yield entry, stat
          walk(entry, &block) if stat.directory?
        end
      end

      # Write a tar entry, emitting PAX headers for long names if needed.
      private def write_entry(name : String, size : Int64, stat : File::Info, typeflag : Char, linkname : String = "")
        if name.bytesize > 99 || linkname.bytesize > 99
          write_pax_header(name, linkname, stat)
        end
        header_name = header_name_for(name)
        header_linkname = header_name_for(linkname)
        write_header(header_name, size, stat, typeflag, header_linkname)
      end

      # Emit a PAX extended header for long path or link names.
      private def write_pax_header(name : String, linkname : String, stat : File::Info)
        entries = [] of String
        entries << pax_record("path", name) if name.bytesize > 99
        entries << pax_record("linkpath", linkname) if linkname.bytesize > 99
        payload = entries.join
        pax_name = pax_header_name(name)
        write_header(pax_name, payload.bytesize.to_i64, stat, TYPE_PAX)
        @io.write(payload.to_slice)
        pad_file(payload.bytesize.to_i64)
      end

      # Format a single PAX record with a correct length prefix.
      private def pax_record(key : String, value : String) : String
        record = "#{key}=#{value}\n"
        length = record.bytesize + 2
        loop do
          candidate = "#{length} #{record}"
          candidate_length = candidate.bytesize
          return candidate if candidate_length == length
          length = candidate_length
        end
      end

      # Generate a deterministic PAX header filename based on the entry name.
      private def pax_header_name(name : String) : String
        digest = Digest::CRC32.new
        digest.update(name)
        "PaxHeaders.0/#{digest.final.hexstring}"
      end

      # Return a tar header-safe name, truncating when required.
      private def header_name_for(name : String) : String
        return name if name.bytesize <= 99
        base = File.basename(name)
        return base if base.bytesize <= 99
        base.byte_slice(0, 99)
      end

      # Write a tar header for the provided entry.
      private def write_header(name : String, size : Int64, stat : File::Info, typeflag : Char, linkname : String = "")
        header = Bytes.new(HEADER_SIZE, 0)
        write_string(header, NAME_OFFSET, NAME_LENGTH, name)
        write_octal(header, MODE_OFFSET, MODE_LENGTH, stat.permissions.value)
        write_octal(header, UID_OFFSET, UID_LENGTH, 0) # uid
        write_octal(header, GID_OFFSET, GID_LENGTH, 0) # gid
        write_octal(header, SIZE_OFFSET, SIZE_LENGTH, size)
        write_octal(header, MTIME_OFFSET, MTIME_LENGTH, stat.modification_time.to_unix)
        header[TYPEFLAG_OFFSET] = typeflag.ord.to_u8
        write_string(header, LINKNAME_OFFSET, LINKNAME_LENGTH, linkname)
        header[MAGIC_OFFSET, 6].copy_from("ustar\0".to_slice)
        header[VERSION_OFFSET, 2].copy_from("00".to_slice)
        write_octal(header, CHECKSUM_OFFSET, CHECKSUM_LENGTH, checksum(header))
        @io.write(header)
      end

      # Write a NUL-terminated string into a tar header field.
      private def write_string(buffer : Bytes, offset : Int32, length : Int32, value : String)
        slice = buffer[offset, length]
        slice.fill(0u8)
        str = value.byte_slice(0, length - 1)
        slice_part = slice[0, str.bytesize]
        slice_part.copy_from(str.to_slice)
      end

      # Write an octal integer into a tar header field.
      private def write_octal(buffer : Bytes, offset : Int32, length : Int32, value : Int64)
        str = value.to_s(8)
        padded = str.rjust(length - 1, '0')
        slice = buffer[offset, length - 1]
        slice.copy_from(padded.to_slice)
        buffer[offset + length - 1] = 0u8
      end

      # Calculate the tar header checksum.
      private def checksum(header : Bytes) : Int64
        temp = header.dup
        (CHECKSUM_OFFSET...(CHECKSUM_OFFSET + CHECKSUM_LENGTH)).each { |i| temp[i] = 32u8 }
        temp.sum(&.to_i64)
      end

      # Pad the tar stream to the next header boundary.
      private def pad_file(size : Int64)
        remainder = size % HEADER_SIZE
        pad = remainder.zero? ? 0 : HEADER_SIZE - remainder
        @io.write(Bytes.new(pad, 0)) if pad > 0
      end

      # Ensure all entries can fit in the tar header naming limits.
      private def self.assert_paths_fit(source : Path)
        Dir.glob(["#{source}/**/*"], match: File::MatchOptions::DotFiles).each do |entry|
          rel = Path.new(entry).relative_to(source).to_s
          next if rel.bytesize <= 99
          header_name = File.basename(rel)
          next if header_name.bytesize <= 99
          raise LongPathError.new("Path too long for tar header even with PAX: #{rel}")
        end
      end
    end
  end
end
