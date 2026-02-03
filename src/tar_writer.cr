require "compress/gzip"
require "digest/crc32"
require "file_utils"
require "log"
require "path"

module Bootstrap
  # Write a .tar.gz file for putting the generated rootfs into a single file
  class TarWriter
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
    def self.write_gz(sources : Array(Path), output : Path, base_path : Path = Path["/"])
      sources.each { |source| assert_paths_fit(source, base_path) }
      File.open(output, "w") do |file|
        Compress::Gzip::Writer.open(file) do |gzip|
          writer = new(gzip, sources, base_path)
          writer.write_all
        end
      end
    end

    # Create a tar writer rooted at a source directory.
    def initialize(@io : IO, @sources : Array(Path), @base_path : Path = "/")
    end

    # Write every entry in the source tree to the tar stream.
    def write_all
      @sources.each do |source|
        walk(source) do |entry, stat|
          relative = Path.new(entry).relative_to(@base_path).to_s
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
    private def self.assert_paths_fit(source : Path, base_path : Path = Path["/"])
      Dir.glob(["#{source}/**/*"], match: File::MatchOptions::DotFiles).each do |entry|
        rel = Path.new(entry).relative_to(base_path).to_s
        next if rel.bytesize <= 99
        header_name = File.basename(rel)
        next if header_name.bytesize <= 99
        raise LongPathError.new("Path too long for tar header even with PAX: #{rel}")
      end
    end
  end
end
