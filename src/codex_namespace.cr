require "digest/sha256"
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

      command = if bookmark = CodexSessionBookmark.read(work_dir)
                  ["codex"] + codex_args + ["resume", bookmark]
                else
                  ["codex"] + codex_args
                end
      status = Process.run(command.first, command[1..], env: env, clear_env: true, input: STDIN, output: STDOUT, error: STDERR)
      if latest = CodexSessionBookmark.latest_from(work_dir / ".codex")
        CodexSessionBookmark.write(work_dir, latest)
      end
      status
    end

    # Download the Codex binary into the rootfs when requested.
    private def self.stage_codex_binary(rootfs : Path, codex_url : URI?, codex_sha256 : String?, codex_target : Path) : Nil
      return unless codex_url
      target = rootfs / normalize_rootfs_target(codex_target)
      return if File.exists?(target) && File.executable?(target)
      download : Path? = nil
      FileUtils.mkdir_p(target.parent)
      if codex_url.scheme == "file"
        source = Path[codex_url.path]
        raise "Codex binary not found at #{source}" unless File.exists?(source)
        FileUtils.cp(source, target)
      else
        download = Path["#{target}.download"]
        download_to(codex_url, download)
        if codex_sha256
          actual = sha256(download)
          raise "Codex SHA256 mismatch: expected #{codex_sha256}, got #{actual}" unless actual == codex_sha256
        end
        FileUtils.mv(download, target)
      end
      File.chmod(target, 0o755)
    ensure
      File.delete?(download) if download
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
