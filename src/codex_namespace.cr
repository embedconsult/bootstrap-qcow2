require "digest/sha256"
require "compress/gzip"
require "file_utils"
require "http/client"
require "uri"
require "./alpine_setup"
require "./sysroot_namespace"
require "./codex_session_bookmark"

module Bootstrap
  module CodexNamespace
    DEFAULT_ROOTFS         = Path["data/sysroot/rootfs"]
    DEFAULT_CODEX_ADD_DIRS = [
      "/var",
      "/opt",
      "/workspace",
    ]
    DEFAULT_CODEX_URL = {% if flag?(:aarch64) || flag?(:arm64) %}
                          "https://github.com/openai/codex/releases/download/rust-v0.87.0/codex-aarch64-unknown-linux-gnu.tar.gz"
                        {% elsif flag?(:x86_64) %}
                          "https://github.com/openai/codex/releases/download/rust-v0.87.0/codex-x86_64-unknown-linux-gnu.tar.gz"
                        {% else %}
                          nil
                        {% end %}
    DEFAULT_CODEX_TARGET = Path["/usr/bin/codex"]
    DEFAULT_WORK_MOUNT   = Path["work"]
    DEFAULT_WORK_DIR     = Path["/work"]
    DEFAULT_EXEC_PATH    = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    # Runs a command inside a fresh namespace rooted at *rootfs*. Binds the host
    # work directory (`./codex/work`) into `/work`.
    #
    # When invoking Codex, the wrapper stores the most recent Codex session id in
    # `/work/.codex-session-id` and will resume that session on the next run when
    # possible.
    # Optionally installs node/npm via apk when targeting Alpine rootfs.
    def self.run(rootfs : Path = DEFAULT_ROOTFS,
                 alpine_setup : Bool = false,
                 add_dirs : Array(String) = DEFAULT_CODEX_ADD_DIRS,
                 exec_path : String = DEFAULT_EXEC_PATH,
                 work_mount : Path = DEFAULT_WORK_MOUNT,
                 work_dir : Path = DEFAULT_WORK_DIR,
                 codex_url : URI? = nil,
                 codex_sha256 : String? = nil,
                 codex_target : Path = DEFAULT_CODEX_TARGET) : Process::Status
      host_work = Path["codex/work"].expand
      FileUtils.mkdir_p(host_work)
      FileUtils.mkdir_p(rootfs / work_mount)
      binds = [{host_work, work_mount}] of Tuple(Path, Path)

      stage_codex_binary(rootfs, codex_url, codex_sha256, codex_target) if codex_url
      AlpineSetup.write_resolv_conf(rootfs) if alpine_setup
      SysrootNamespace.enter_rootfs(rootfs.to_s, extra_binds: binds)
      FileUtils.mkdir_p(work_dir)
      Dir.cd(work_dir)

      env = {
        "HOME"       => work_dir.to_s,
        "CODEX_HOME" => (work_dir / ".codex").to_s,
        "PATH"       => exec_path,
      }
      if api_key = ENV["OPENAI_API_KEY"]?
        env["OPENAI_API_KEY"] = api_key
      end
      FileUtils.mkdir_p(work_dir / ".codex")

      if alpine_setup
        AlpineSetup.install_sysroot_runner_packages
        AlpineSetup.install_codex_packages
      end

      codex_args = [] of String
      add_dirs.each do |dir|
        codex_args << "--add-dir"
        codex_args << dir
      end

      codex_executable = resolve_executable("codex", exec_path)
      command = if bookmark = CodexSessionBookmark.read(work_dir)
                  [codex_executable] + codex_args + ["resume", bookmark]
                else
                  [codex_executable] + codex_args
                end
      status = Process.run(command.first, command[1..], env: env, clear_env: true, input: STDIN, output: STDOUT, error: STDERR)
      if latest = CodexSessionBookmark.latest_from(work_dir / ".codex")
        CodexSessionBookmark.write(work_dir, latest)
      end
      status
    end

    def self.default_codex_url : URI
      default_codex_url? || raise "No default Codex URL for this architecture; pass --codex-download URL instead."
    end

    def self.default_codex_url? : URI?
      url = DEFAULT_CODEX_URL
      return nil unless url
      URI.parse(url)
    end

    # Resolve the provided executable name using a PATH-like string.
    # Returns the original name when no matching executable is found.
    private def self.resolve_executable(command : String, exec_path : String) : String
      return command if command.includes?('/')
      exec_path.split(':').each do |entry|
        next if entry.empty?
        candidate = (Path[entry].expand / command)
        return candidate.to_s if File::Info.executable?(candidate)
      end
      command
    end

    # Download the Codex binary into the rootfs when requested.
    private def self.stage_codex_binary(rootfs : Path, codex_url : URI?, codex_sha256 : String?, codex_target : Path) : Nil
      return unless codex_url
      target = rootfs / normalize_rootfs_target(codex_target)
      download : Path? = nil
      extract_dir : Path? = nil
      if File.exists?(target)
        gunzip_if_needed(target) if gzip_file?(target)
        if tar_file?(target)
          extract_dir = Path["#{target}.extract"]
          FileUtils.rm_r(extract_dir) if Dir.exists?(extract_dir)
          FileUtils.mkdir_p(extract_dir)
          extract_tarball(target, extract_dir, gzip: false)
          codex_binary = find_codex_binary(extract_dir)
          if codex_binary
            FileUtils.cp(codex_binary, target)
            FileUtils.rm_r(extract_dir) if Dir.exists?(extract_dir)
            File.chmod(target, 0o755)
            return if elf_binary?(target)
          end
        elsif elf_binary?(target)
          ensure_runtime_libraries(rootfs, target)
          File.chmod(target, 0o755)
          return
        end
      end
      FileUtils.mkdir_p(target.parent)
      source = if codex_url.scheme == "file"
                 path = Path[codex_url.path]
                 raise "Codex binary not found at #{path}" unless File.exists?(path)
                 path
               else
                 download = Path["#{target}.download"]
                 download_to(codex_url, download)
                 download
               end
      if codex_sha256
        actual = sha256(source)
        raise "Codex SHA256 mismatch: expected #{codex_sha256}, got #{actual}" unless actual == codex_sha256
      end
      if tarball?(source, codex_url)
        extract_dir = Path["#{target}.extract"]
        FileUtils.rm_r(extract_dir) if Dir.exists?(extract_dir)
        FileUtils.mkdir_p(extract_dir)
        extract_tarball(source, extract_dir, gzip: gzip_tarball?(source, codex_url))
        codex_binary = find_codex_binary(extract_dir)
        raise "Codex binary not found in #{source}" unless codex_binary
        FileUtils.cp(codex_binary, target)
      else
        if codex_url.scheme == "file"
          FileUtils.cp(source, target)
        else
          FileUtils.mv(source, target)
          download = nil
        end
      end
      gunzip_if_needed(target)
      ensure_runtime_libraries(rootfs, target) if elf_binary?(target)
      File.chmod(target, 0o755)
    ensure
      File.delete?(download) if download
      FileUtils.rm_r(extract_dir) if extract_dir && Dir.exists?(extract_dir)
    end

    private def self.tarball?(path : Path) : Bool
      name = path.to_s
      name.ends_with?(".tar.gz") || name.ends_with?(".tgz") || name.ends_with?(".tar")
    end

    private def self.tarball?(path : Path, uri : URI) : Bool
      return true if tarball?(path)
      uri_path = uri.path
      return false unless uri_path
      uri_path.ends_with?(".tar.gz") || uri_path.ends_with?(".tgz") || uri_path.ends_with?(".tar")
    end

    private def self.extract_tarball(archive : Path, destination : Path, gzip : Bool) : Nil
      args = ["-xf", archive.to_s, "-C", destination.to_s]
      args.unshift("-z") if gzip
      status = Process.run("tar", args)
      raise "Failed to extract #{archive}" unless status.success?
    end

    private def self.gzip_tarball?(path : Path, uri : URI) : Bool
      return true if path.to_s.ends_with?(".tar.gz") || path.to_s.ends_with?(".tgz")
      uri_path = uri.path
      return false unless uri_path
      uri_path.ends_with?(".tar.gz") || uri_path.ends_with?(".tgz")
    end

    private def self.find_codex_binary(root : Path) : Path?
      matches = [] of Path
      Dir.glob((root / "**" / "*").to_s) do |entry|
        path = Path[entry]
        next unless File.file?(path)
        matches << path
      end

      preferred = matches.select do |path|
        basename = path.basename
        basename == "codex" || basename == "codex.gz" || basename.starts_with?("codex-")
      end

      pick = preferred.empty? ? matches : preferred
      pick.find { |path| elf_binary?(path) } ||
        pick.find { |path| gzip_file?(path) } ||
        pick.find { |path| File::Info.executable?(path) } ||
        (matches.size == 1 ? matches.first? : pick.first?)
    end

    private def self.ensure_runtime_libraries(rootfs : Path, binary : Path) : Nil
      return unless elf_binary?(binary)
      return if File.size(binary) < 1024 * 1024
      readelf = Process.find_executable("readelf")
      raise "readelf not found; install binutils to stage Codex runtime libraries" unless readelf

      if interpreter = elf_interpreter(binary, readelf)
        install_host_path(rootfs, Path[interpreter])
      end

      elf_needed(binary, readelf).each do |lib_name|
        next if lib_name.empty?
        host_path = find_host_library(lib_name)
        raise "Missing runtime library #{lib_name} for #{binary}" unless host_path
        install_host_path(rootfs, host_path)
      end
    end

    private def self.elf_interpreter(binary : Path, readelf : String) : String?
      output = readelf_output(readelf, ["-l"], binary)
      output.each_line do |line|
        next unless line.includes?("Requesting program interpreter:")
        start = line.index(":")
        next unless start
        value = line[start + 1..].strip
        if open = value.index('[')
          close = value.index(']', open)
          return value[open + 1, close - open - 1] if close
        end
      end
      nil
    end

    private def self.elf_needed(binary : Path, readelf : String) : Array(String)
      libs = [] of String
      output = readelf_output(readelf, ["-d"], binary)
      output.each_line do |line|
        next unless line.includes?("NEEDED")
        if open = line.index('[')
          close = line.index(']', open)
          libs << line[open + 1, close - open - 1] if close
        end
      end
      libs.uniq
    end

    private def self.readelf_output(readelf : String, args : Array(String), binary : Path) : String
      io = IO::Memory.new
      status = Process.run(readelf, args + [binary.to_s], output: io, error: io)
      raise "readelf failed for #{binary}: #{io.to_s}" unless status.success?
      io.to_s
    end

    private def self.install_host_path(rootfs : Path, host_path : Path) : Nil
      raise "Runtime file not found on host: #{host_path}" unless File.exists?(host_path)
      target = rootfs / normalize_rootfs_target(host_path)
      return if File.exists?(target)
      FileUtils.mkdir_p(target.parent)
      FileUtils.cp(host_path, target)
    end

    private def self.find_host_library(name : String) : Path?
      search_dirs = [
        "/lib",
        "/lib64",
        "/usr/lib",
        "/usr/lib64",
        "/lib/aarch64-linux-gnu",
        "/usr/lib/aarch64-linux-gnu",
        "/lib/arm64-linux-gnu",
        "/usr/lib/arm64-linux-gnu",
      ]
      search_dirs.each do |dir|
        path = Path[dir] / name
        return path if File.exists?(path)
      end
      search_dirs.each do |dir|
        Dir.glob(File.join(dir, "**", name)) do |entry|
          return Path[entry] if File.exists?(entry)
        end
      end
      nil
    end

    private def self.elf_binary?(path : Path) : Bool
      File.open(path) do |file|
        magic = Bytes.new(4)
        return false unless file.read(magic) == 4
        magic[0] == 0x7f && magic[1] == 'E'.ord && magic[2] == 'L'.ord && magic[3] == 'F'.ord
      end
    rescue
      false
    end

    private def self.tar_file?(path : Path) : Bool
      File.open(path) do |file|
        header = Bytes.new(512)
        return false unless file.read(header) == 512
        header[257] == 'u'.ord && header[258] == 's'.ord && header[259] == 't'.ord && header[260] == 'a'.ord && header[261] == 'r'.ord
      end
    rescue
      false
    end

    private def self.gzip_file?(path : Path) : Bool
      File.open(path) do |file|
        magic = Bytes.new(2)
        return false unless file.read(magic) == 2
        magic[0] == 0x1f && magic[1] == 0x8b
      end
    rescue
      false
    end

    private def self.gunzip_if_needed(path : Path) : Nil
      return unless gzip_file?(path)
      tmp = Path["#{path}.gunzip"]
      File.open(path) do |input|
        Compress::Gzip::Reader.open(input) do |gz|
          File.open(tmp, "w") do |output|
            IO.copy(gz, output)
          end
        end
      end
      FileUtils.mv(tmp, path)
    ensure
      File.delete?(tmp) if tmp
    end

    private def self.normalize_rootfs_target(path : Path) : Path
      value = path.to_s
      value = value[1..] if value.starts_with?("/")
      Path[value]
    end

    private def self.download_to(uri : URI, target : Path) : Nil
      File.open(target, "w") do |file|
        fetch_with_redirects(uri) do |response|
          raise "Failed to download #{uri} (#{response.status_code})" unless response.success?
          IO.copy(response.body_io, file)
        end
      end
    end

    private def self.fetch_with_redirects(uri : URI, limit : Int32 = 5, &block : HTTP::Client::Response ->)
      current = uri
      attempts = 0
      loop do
        raise "Too many redirects for #{uri}" if attempts > limit
        attempts += 1
        HTTP::Client.get(current) do |response|
          if response.status_code.in?(300..399) && (location = response.headers["Location"]?)
            next_uri = URI.parse(location).absolute? ? URI.parse(location) : current.resolve(location)
            current = next_uri
            next
          end
          return yield response
        end
      end
    end

    private def self.sha256(path : Path) : String
      digest = Digest::SHA256.new
      File.open(path) do |file|
        buffer = Bytes.new(4096)
        while (read = file.read(buffer)) > 0
          digest.update(buffer[0, read])
        end
      end
      digest.final.hexstring
    end
  end
end
