require "digest/sha256"
require "file_utils"
require "http/client"
require "json"
require "log"
require "process"
require "random/secure"
require "set"
require "time"
require "uri"
require "./build_plan"
require "./process_runner"
require "./alpine_setup"
require "./sysroot_workspace"
require "./sysroot_builder"
require "./tarball"

module Bootstrap
  # Raised when a command fails during a StepRunner invocation.
  class CommandFailedError < Exception
    getter argv : Array(String)
    getter exit_code : Int32
    getter output_path : String?

    def initialize(@argv : Array(String), @exit_code : Int32, message : String, @output_path : String? = nil)
      super(message)
    end
  end

  # StepRunner performs tasks using the strategy metadata from BuildPhase and BuildStep.
  #
  # Until utilities are fully developed here, StepRunner shells out via ProcessRunner for some taks.
  #
  # StepRunner utilizes:
  # * BuildPlan for reading the build plan with potential overrides
  # * ProcessRunner for invoking and logging external executables
  # * AlpineSetup for Alpine seed rootfs configuration
  class StepRunner
    property clean_build_dirs : Bool
    property report_dir : String?
    getter workspace : SysrootWorkspace?
    @command_log_prefix : String?

    def initialize(@clean_build_dirs : Bool = true, @workspace : SysrootWorkspace? = nil)
      @command_log_prefix = nil
      @report_dir = nil
    end

    # Run a build step using the selected strategy.
    #
    # The effective install destination is computed from the phase defaults
    # and optional step overrides:
    # - `install_prefix` selects the prefix used by configure/CMake.
    # - `destdir` (when present) is passed to install commands to stage files
    #   into a rootfs directory without needing chroot/pivot_root.
    # - `env` combines phase env with step env, with step keys overriding.
    def run(phase : BuildPhase, step : BuildStep)
      Dir.cd(step.workdir) do
        cpus = (System.cpu_count || 1).to_i32
        Log.info { "Starting #{step.strategy} build for #{step.name} in #{step.workdir} (cpus=#{cpus})" }
        @command_log_prefix = log_prefix_for(phase, step)
        apply_patches(step.patches)
        env = effective_env(phase, step)
        install_prefix = step.install_prefix || phase.install_prefix
        destdir = step.destdir || phase.destdir
        case step.strategy
        when "cmake"
          build_dir = step.build_dir || step.workdir
          bootstrap_path = File.join(step.workdir, "bootstrap")
          had_build_files = File.exists?(File.join(build_dir, "CMakeCache.txt")) ||
                            File.exists?(File.join(build_dir, "Makefile")) ||
                            Dir.exists?(File.join(build_dir, "CMakeFiles"))
          FileUtils.mkdir_p(build_dir)
          Dir.cd(build_dir) do
            # CMake's bootstrap script only parallelizes when --parallel is set.
            bootstrap_argv = [bootstrap_path, "--parallel=#{cpus}", "--prefix=#{install_prefix}"]
            if step.configure_flags.size > 0
              bootstrap_argv << "--"
              bootstrap_argv.concat(step.configure_flags)
            end
            run_cmd(bootstrap_argv, env: env)
            if (step.clean_build || had_build_files) && File.exists?("Makefile")
              run_cmd(["make", "clean"], env: env)
            end
            run_cmd(["make", "-j#{cpus}"], env: env)
            run_make_install(destdir, env)
          end
        when "busybox"
          run_cmd(["make", "defconfig"], env: env)
          run_cmd(["make", "-j#{cpus}"], env: env)
          install_root = destdir || install_prefix
          run_cmd(["make", "CONFIG_PREFIX=#{install_root}", "install"], env: env)
        when "makefile-classic"
          makefile = "Makefile.bq2"
          raise "Missing #{makefile} in #{step.workdir}" unless File.exists?(makefile)
          run_cmd(["make", "-f", makefile, "-j#{cpus}"], env: env)
          if destdir
            run_cmd(["make", "-f", makefile, "DESTDIR=#{destdir}", "install"], env: env)
          else
            run_cmd(["make", "-f", makefile, "install"], env: env)
          end
        when "copy-tree"
          raise "copy-tree requires step.install_prefix (destination path)" unless step.install_prefix
          install_root = destdir ? "#{destdir}#{install_prefix}" : install_prefix
          FileUtils.mkdir_p(install_root)
          run_cmd(["cp", "-a", ".", install_root], env: env)
        when "write-file"
          raise "write-file requires step.install_prefix (file path)" unless step.install_prefix
          content = step.content || step.env["CONTENT"]?
          raise "write-file requires env CONTENT" unless content
          target = destdir ? "#{destdir}#{install_prefix}" : install_prefix
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, content)
        when "alpine-setup"
          AlpineSetup.install_sysroot_runner_packages
        when "apk-add"
          packages = step.packages
          raise "apk-add requires step.packages" unless packages
          AlpineSetup.apk_add(packages)
        when "download-sources"
          download_sources(step)
        when "extract-sources"
          extract_sources(step)
        when "populate-seed"
          populate_seed(step)
        when "prepare-rootfs"
          idx = 0
          wrote = false
          loop do
            path_key = "FILE_#{idx}_PATH"
            content_key = "FILE_#{idx}_CONTENT"
            path = step.env[path_key]?
            content = step.env[content_key]?
            break unless path || content
            raise "prepare-rootfs requires #{path_key}" unless path
            raise "prepare-rootfs requires #{content_key}" unless content
            target = destdir ? "#{destdir}#{path}" : path
            FileUtils.mkdir_p(File.dirname(target))
            File.write(target, content)
            wrote = true
            idx += 1
          end
          raise "prepare-rootfs wrote no files" unless wrote
        when "symlink"
          idx = 0
          linked = false
          loop do
            src_key = "LINK_#{idx}_SRC"
            dest_key = "LINK_#{idx}_DEST"
            source = step.env[src_key]?
            dest = step.env[dest_key]?
            break unless source || dest
            raise "symlink requires #{src_key}" unless source
            raise "symlink requires #{dest_key}" unless dest
            target = destdir ? "#{destdir}#{dest}" : dest
            FileUtils.mkdir_p(File.dirname(target))
            FileUtils.rm_rf(target) if File.exists?(target) || File.symlink?(target)
            File.symlink(source, target)
            linked = true
            idx += 1
          end
          raise "symlink wrote no links" unless linked
        when "remove-tree"
          raise "remove-tree requires step.install_prefix (path to remove)" unless step.install_prefix
          remove_root = destdir ? "#{destdir}#{install_prefix}" : install_prefix
          raise "Refusing to remove #{remove_root}" if remove_root == "/" || remove_root.empty?
          FileUtils.rm_rf(remove_root)
        when "tarball"
          output = step.install_prefix
          raise "tarball requires step.install_prefix (output path)" unless output
          output = output.not_nil!
          source_root = step.workdir
          if destdir
            if source_root.starts_with?(destdir)
              # Already rooted at the destdir.
            elsif source_root == "/"
              source_root = destdir
            elsif source_root.starts_with?("/")
              source_root = "#{destdir}#{source_root}"
            else
              source_root = File.join(destdir, source_root)
            end
          end
          # TODO: Replace this logic with call to TarWriter.write_gz
          raise "Missing tarball source #{source_root}" unless Dir.exists?(source_root)
          FileUtils.mkdir_p(File.dirname(output))
          tar_excludes = [
            "--exclude=var/lib",
            "--exclude=var/lib/**",
            "--exclude=.bq2-rootfs",
          ]
          run_cmd(["tar", "-czf", output] + tar_excludes + ["-C", source_root, "."], env: env)
        when "linux-headers"
          install_root = destdir ? "#{destdir}#{install_prefix}" : install_prefix
          run_cmd(["make"] + step.configure_flags + ["headers"], env: env)
          include_dest = File.join(install_root, "include")
          FileUtils.mkdir_p(include_dest)
          run_cmd(["cp", "-a", "usr/include/.", include_dest], env: env)
        when "cmake-project"
          run_cmake_project(step, env, install_prefix, destdir, cpus)
        when "crystal"
          run_cmd(["shards", "build"], env: env)
          bin_prefix = destdir ? "#{destdir}#{install_prefix}" : install_prefix
          run_cmd(["install", "-d", "#{bin_prefix}/bin"], env: env)
          Dir.glob("bin/*").each do |artifact|
            run_cmd(["install", "-m", "0755", artifact, "#{bin_prefix}/bin/"], env: env)
          end
        when "crystal-build"
          if File.exists?("shard.yml") && run_shards_install?(env)
            run_cmd(["shards", "install"], env: env)
          elsif File.exists?("shard.yml")
            Log.info { "Skipping shards install for #{step.name} (prefetched during download phase)" }
          end
          run_cmd(["crystal", "build"] + step.configure_flags, env: env)
          bin_prefix = destdir ? "#{destdir}#{install_prefix}" : install_prefix
          run_cmd(["install", "-d", "#{bin_prefix}/bin"], env: env)
          Dir.glob("bin/*").each do |artifact|
            run_cmd(["install", "-m", "0755", artifact, "#{bin_prefix}/bin/"], env: env)
          end
        when "crystal-compiler"
          FileUtils.rm_rf(".build") if Dir.exists?(".build")
          run_cmd(["make", "-j#{cpus}", "crystal"], env: env)
          install_env = destdir ? env.merge({"DESTDIR" => destdir}) : env
          run_cmd(["make", "install", "PREFIX=#{install_prefix}"], env: install_env)
        else # autotools/default
          if File.exists?("configure")
            if step.clean_build && File.exists?("Makefile")
              status = run_cmd_status(["make", "distclean"], env: env)
              unless status.success?
                Log.warn { "make distclean failed (#{status.exit_code}); attempting make clean" }
                status = run_cmd_status(["make", "clean"], env: env)
                Log.warn { "make clean failed (#{status.exit_code}); continuing" } unless status.success?
              end
            end
            normalize_autotools_timestamps
            run_cmd(["./configure", "--prefix=#{install_prefix}"] + step.configure_flags, env: env)
            run_cmd(["make", "-j#{cpus}"], env: env)
            run_make_install(destdir, env)
          elsif cmake_lists_present?(step)
            run_cmake_project(step, env, install_prefix, destdir, cpus)
          else
            raise "Unknown build strategy #{step.strategy} and missing ./configure in #{step.workdir}"
          end
        end
        Log.info { "Finished #{step.name}" }
      end
    end

    # Returns true when shards install should be performed during build steps.
    private def run_shards_install?(env : Hash(String, String)) : Bool
      truthy_env?(env["BQ2_FORCE_SHARDS_INSTALL"]?)
    end

    private def host_setup_builder(phase : BuildPhase, &block : SysrootBuilder ->) : Nil
      builder = build_host_setup_builder(phase)
      with_source_branch(phase.env) do
        yield builder
      end
    end

    private def build_host_setup_builder(_phase : BuildPhase) : SysrootBuilder
      workspace = @workspace || SysrootWorkspace.new
      SysrootBuilder.new(workspace: workspace)
    end

    # Download all configured package sources and return their cached paths.
    def download_sources(step : BuildStep) : Array(Path)
      sources = step.sources || raise "download-sources requires step.sources"
      sources.map { |source| download_source(source) }
    end

    # Extract configured source archives into the rootfs workspace.
    def extract_sources(step : BuildStep) : Nil
      extracts = step.extract_sources || raise "extract-sources requires step.extract_sources"
      workspace_root = workspace.rootfs_workspace_path
      extracts.each do |spec|
        archive = sources_dir / spec.filename
        raise "Missing source archive #{archive}" unless File.exists?(archive)
        build_root = workspace_root / spec.build_directory
        next if Dir.exists?(build_root)
        Tarball.extract(archive, workspace_root, false, nil, nil)
      end
    end

    # Populate the seed rootfs from the base rootfs tarball.
    def populate_seed(step : BuildStep) : Nil
      sources = step.sources || raise "populate-seed requires step.sources"
      base = sources.first? || raise "populate-seed requires a base rootfs source"
      archive = download_source(base)
      seed_rootfs = workspace.seed_rootfs_path || raise "Missing seed rootfs path"
      FileUtils.mkdir_p(seed_rootfs)
      Tarball.extract(archive, seed_rootfs, false, nil, nil)
      AlpineSetup.write_resolv_conf(seed_rootfs)
    end

    private def download_source(source : SourceSpec) : Path
      target = sources_dir / source.filename
      attempts = 3
      attempts.times do |idx|
        begin
          if File.exists?(target)
            if File.size(target) > 0 && verify_source(source, target)
              return target
            else
              File.delete(target)
            end
          end

          Log.debug { "Downloading #{source.name} #{source.version} from #{source.url}" }
          download_with_redirects(URI.parse(source.url), target)
          raise "Empty download for #{source.name}" if File.size(target) == 0
          verify_source(source, target)
          return target
        rescue error
          File.delete(target) if File.exists?(target)
          raise error if idx == attempts - 1
          Log.warn { "Retrying #{source.name} after error: #{error.message}" }
          sleep 2.seconds
        end
      end
      target
    end

    private def verify_source(source : SourceSpec, path : Path) : Bool
      expected = expected_sha256(source)
      return true unless expected
      actual = sha256(path)
      raise "SHA256 mismatch for #{source.name}: expected #{expected}, got #{actual}" unless expected == actual
      true
    end

    private def expected_sha256(source : SourceSpec) : String?
      source.sha256 || fetch_remote_checksum(source)
    end

    private def fetch_remote_checksum(source : SourceSpec) : String?
      return nil unless checksum_url = source.checksum_url
      body = fetch_string_with_redirects(URI.parse(checksum_url))
      body ? normalize_checksum(body) : nil
    end

    private def normalize_checksum(body : String) : String
      body.strip.split(/\s+/).first
    end

    private def sha256(path : Path) : String
      digest = Digest::SHA256.new
      File.open(path) do |file|
        buffer = Bytes.new(8192)
        while (read = file.read(buffer)) > 0
          digest.update(buffer[0, read])
        end
      end
      digest.final.hexstring
    end

    private def download_with_redirects(uri : URI, target : Path, limit : Int32 = 5) : Nil
      raise "Too many redirects while fetching #{uri}" if limit < 0
      HTTP::Client.get(uri) do |response|
        if response.status_code.in?({301, 302, 303, 307, 308})
          location = response.headers["Location"]?
          raise "Redirect missing Location header for #{uri}" unless location
          return download_with_redirects(resolve_redirect(uri, location), target, limit - 1)
        end
        raise "Failed to download #{uri}: HTTP #{response.status_code}" unless response.success?
        File.open(target, "wb") do |file|
          IO.copy(response.body_io, file)
        end
      end
    end

    private def fetch_string_with_redirects(uri : URI, limit : Int32 = 5) : String?
      raise "Too many redirects while fetching #{uri}" if limit < 0
      buffer = IO::Memory.new
      success = false
      HTTP::Client.get(uri) do |response|
        if response.status_code.in?({301, 302, 303, 307, 308})
          location = response.headers["Location"]?
          raise "Redirect missing Location header for #{uri}" unless location
          return fetch_string_with_redirects(resolve_redirect(uri, location), limit - 1)
        end
        return nil unless response.success?
        IO.copy(response.body_io, buffer)
        success = true
      end
      success ? buffer.to_s : nil
    end

    private def resolve_redirect(uri : URI, location : String) : URI
      target = URI.parse(location)
      return target unless target.scheme.nil? || target.host.nil?
      uri.resolve(target)
    end

    private def sources_dir : Path
      workspace = @workspace || SysrootWorkspace.new
      dir = workspace.sources_dir
      FileUtils.mkdir_p(dir)
      dir
    end

    private def workspace : SysrootWorkspace
      @workspace || SysrootWorkspace.new
    end

    private def with_source_branch(env : Hash(String, String), &block : -> T) : T forall T
      override = env["BQ2_SOURCE_BRANCH"]?
      previous = ENV["BQ2_SOURCE_BRANCH"]?
      if override
        ENV["BQ2_SOURCE_BRANCH"] = override
      end
      yield
    ensure
      if previous
        ENV["BQ2_SOURCE_BRANCH"] = previous
      else
        ENV.delete("BQ2_SOURCE_BRANCH")
      end
    end

    # Many release tarballs include pre-generated autotools artifacts
    # (`configure`, `aclocal.m4`, etc.) that should not be regenerated during
    # a normal build. If an extractor fails to preserve mtimes, those artifacts
    # can appear older than `configure.ac` and trigger automake/autoconf
    # rebuild rules, which breaks minimal bootstrap environments.
    private def normalize_autotools_timestamps
      return unless File.exists?("configure.ac")
      reference = File.info("configure.ac").modification_time
      bump = reference + 1.second
      %w[
        aclocal.m4
        configure
        config.h.in
        config.hin
        Makefile.in
        lib/config.hin
        src/config.h.in
        src/config.hin
        include/config.h.in
        include/config.hin
      ].each do |candidate|
        next unless File.exists?(candidate)
        info = File.info(candidate, follow_symlinks: false)
        next if info.modification_time > reference
        File.utime(bump, bump, candidate)
      rescue ex
        Log.warn { "Failed to bump autotools timestamp for #{candidate}: #{ex.message}" }
      end
    end

    # Apply patch files before invoking build commands.
    private def apply_patches(patches : Array(String))
      patches.each do |patch|
        Log.info { "Applying patch #{patch}" }
        dry_run = ["patch", "-p1", "--forward", "-N", "--dry-run", "-i", patch]
        dry_status = run_cmd_status(dry_run)
        if dry_status.success?
          argv = ["patch", "-p1", "--forward", "-N", "-i", patch]
          status = run_cmd_status(argv)
          raise CommandFailedError.new(argv, status.exit_code, "Patch failed (#{status.exit_code}): #{patch}") unless status.success?
          next
        end

        reverse_dry_run = ["patch", "-p1", "--reverse", "--dry-run", "-i", patch]
        reverse_status = run_cmd_status(reverse_dry_run)
        if reverse_status.success?
          Log.info { "Patch already applied; skipping #{patch}" }
          next
        end

        raise CommandFailedError.new(dry_run, dry_status.exit_code, "Patch failed (#{dry_status.exit_code}): #{patch}")
      end
    end

    # Run a command array and raise if it fails.
    private def run_cmd(argv : Array(String), env : Hash(String, String) = {} of String => String)
      result = run_cmd_result(argv, env: env)
      unless result.status.success?
        Log.error { "Command failed (#{result.status.exit_code}): #{argv.join(" ")}" }
        raise CommandFailedError.new(argv, result.status.exit_code, "Command failed (#{result.status.exit_code}): #{argv.join(" ")}", result.output_path)
      end
      Log.debug { "Completed #{argv.first} with exit #{result.status.exit_code}" }
    end

    # Run a command array and return its Process::Status while throttling output.
    private def run_cmd_status(argv : Array(String), env : Hash(String, String) = {} of String => String) : Process::Status
      run_cmd_result(argv, env: env).status
    end

    private def run_cmd_result(argv : Array(String), env : Hash(String, String) = {} of String => String) : ProcessRunner::Result
      Log.info { "Running in #{Dir.current}: #{argv.join(" ")}" }
      result = ProcessRunner.run(argv, env: env, capture_path: capture_path_for(argv), capture_on_error: true)
      Log.info { "Finished in #{result.elapsed.total_seconds.round(3)}s (exit=#{result.status.exit_code}): #{argv.join(" ")}" }
      result
    end

    private def capture_path_for(argv : Array(String)) : String?
      report_dir = @report_dir
      return nil unless report_dir
      FileUtils.mkdir_p(report_dir)
      timestamp = Time.utc.to_s("%Y%m%dT%H%M%S.%LZ")
      base = @command_log_prefix || argv.first? || "command"
      slug = slugify(base)
      disambiguator = Random::Secure.hex(4)
      File.join(report_dir, "#{timestamp}-#{slug}-#{disambiguator}.log")
    end

    private def log_prefix_for(phase : BuildPhase, step : BuildStep) : String
      "#{phase.name}-#{step.name}"
    end

    private def slugify(value : String) : String
      value.gsub(/[^A-Za-z0-9]+/, "_").gsub(/^_+|_+$/, "").downcase
    end

    # Runs `make install`, optionally staging through `DESTDIR`.
    private def run_make_install(destdir : String?, env : Hash(String, String))
      if destdir
        run_cmd(["make", "DESTDIR=#{destdir}", "install"], env: env)
      else
        run_cmd(["make", "install"], env: env)
      end
    end

    # Merge phase and step environment variables. Step keys override phase keys.
    private def effective_env(phase : BuildPhase, step : BuildStep) : Hash(String, String)
      merged = phase.env.dup
      step.env.each { |key, value| merged[key] = value }
      ensure_sysroot_ld_library_path(merged)
    end

    private def ensure_sysroot_ld_library_path(env : Hash(String, String)) : Hash(String, String)
      sysroot_bin = "/opt/sysroot/bin"
      sysroot_lib = "/opt/sysroot/lib"
      path = env["PATH"]?
      return env unless path && path.includes?(sysroot_bin)
      current = env["LD_LIBRARY_PATH"]?
      if current
        parts = current.split(':')
        return env if parts.includes?(sysroot_lib)
        env["LD_LIBRARY_PATH"] = "#{current}:#{sysroot_lib}"
      else
        env["LD_LIBRARY_PATH"] = sysroot_lib
      end
      env
    end

    # Returns true when a string environment value should be treated as true.
    private def truthy_env?(value : String?) : Bool
      return false unless value
      normalized = value.strip.downcase
      return false if normalized.empty?
      !(%w[0 false no].includes?(normalized))
    end

    # Returns true when a CMakeLists.txt file exists for the step.
    private def cmake_lists_present?(step : BuildStep) : Bool
      source_dir = cmake_source_dir_for(step)
      File.exists?("CMakeLists.txt") || File.exists?(File.join(source_dir, "CMakeLists.txt"))
    end

    # Resolve the CMake source directory for a build step.
    private def cmake_source_dir_for(step : BuildStep) : String
      step.env["CMAKE_SOURCE_DIR"]? || "."
    end

    # Resolve the CMake build directory for a build step.
    private def cmake_build_dir_for(step : BuildStep) : String
      step.build_dir || "build"
    end

    # Run a standard CMake configure/build/install cycle.
    private def run_cmake_project(step : BuildStep,
                                  env : Hash(String, String),
                                  install_prefix : String,
                                  destdir : String?,
                                  cpus : Int32) : Nil
      source_dir = cmake_source_dir_for(step)
      build_dir = cmake_build_dir_for(step)
      FileUtils.rm_rf(build_dir) if clean_build_dirs && Dir.exists?(build_dir)
      run_cmd(["cmake", "-S", source_dir, "-B", build_dir, "-DCMAKE_INSTALL_PREFIX=#{install_prefix}"] + step.configure_flags, env: env)
      run_cmd(["cmake", "--build", build_dir, "-j#{cpus}"], env: env)
      install_env = destdir ? env.merge({"DESTDIR" => destdir}) : env
      run_cmd(["cmake", "--install", build_dir], env: install_env)
    end
  end
end
