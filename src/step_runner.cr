require "json"
require "log"
require "file_utils"
require "process"
require "random/secure"
require "set"
require "time"
require "http/client"
require "uri"
require "digest/sha256"
require "./build_plan"
require "./process_runner"
require "./alpine_setup"
require "./sysroot_workspace"
require "./patch_applier"
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
    # When true, extract-sources skips archives that already extracted their
    # build directories.
    property skip_existing_sources : Bool
    getter workspace : SysrootWorkspace
    @command_log_prefix : String?

    def initialize(@workspace : SysrootWorkspace, @clean_build_dirs : Bool = true, @skip_existing_sources : Bool = false)
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
      workdir = step.workdir
      cpus = (System.cpu_count || 1).to_i32
      Log.info { "Starting #{step.strategy} build for #{step.name} in #{workdir || "(no chdir)"} (cpus=#{cpus})" }
      run_block = -> {
        @command_log_prefix = log_prefix_for(phase, step)
        apply_patches(step.patches)
        env = effective_env(phase, step)
        install_prefix = step.install_prefix || phase.install_prefix
        destdir = step.destdir || phase.destdir
        case step.strategy
        when "cmake"
          step_root = workdir || "."
          build_dir = step.build_dir || step_root
          bootstrap_path = File.join(step_root, "bootstrap")
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
          if (config_tool = env["BQ2_KCONFIG_CONFIG_TOOL"]?) && File.exists?(config_tool)
            run_cmd([config_tool, "--file", ".config", "--disable", "STATIC_LIBGCC"], env: env)
            run_cmd(["make", "silentoldconfig"], env: env)
          else
            Log.warn { "Skipping BusyBox Kconfig update; set BQ2_KCONFIG_CONFIG_TOOL to disable STATIC_LIBGCC" }
          end
          run_cmd(["make", "-j#{cpus}"], env: env)
          install_root = destdir || install_prefix
          run_cmd(["make", "CONFIG_PREFIX=#{install_root}", "install"], env: env)
        when "makefile-classic"
          makefile = "Makefile.bq2"
          raise "Missing #{makefile} in #{workdir || Dir.current}" unless File.exists?(makefile)
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
          extract_sources(step)
        when "prefetch-shards"
          prefetch_shards(step, env)
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
          raise "symlink requires step.install_prefix (destination)" unless step.install_prefix
          source = step.content || step.env["CONTENT"]?
          raise "symlink requires content (source path)" unless source
          target = destdir ? "#{destdir}#{install_prefix}" : install_prefix
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.rm_rf(target) if File.exists?(target) || File.symlink?(target)
          File.symlink(source, target)
        when "remove-tree"
          raise "remove-tree requires step.install_prefix (path to remove)" unless step.install_prefix
          remove_root = destdir ? "#{destdir}#{install_prefix}" : install_prefix
          raise "Refusing to remove #{remove_root}" if remove_root == "/" || remove_root.empty?
          FileUtils.rm_rf(remove_root)
        when "tarball"
          output = step.install_prefix
          raise "tarball requires step.install_prefix (output path)" unless output
          output = output.not_nil!
          source_root = workdir || "/"
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
            # Exclude mountpoints and runtime-managed paths so the rootfs tarball
            # contains only the prefix-free filesystem payload.
            "--exclude=proc",
            "--exclude=proc/**",
            "--exclude=sys",
            "--exclude=sys/**",
            "--exclude=dev",
            "--exclude=dev/**",
            "--exclude=work",
            "--exclude=work/**",
            "--exclude=workspace",
            "--exclude=workspace/**",
            "--exclude=var/lib",
            "--exclude=var/lib/**",
            "--exclude=workspace",
            "--exclude=workspace/**",
            "--exclude=work",
            "--exclude=work/**",
            "--exclude=proc",
            "--exclude=proc/**",
            "--exclude=sys",
            "--exclude=sys/**",
            "--exclude=dev",
            "--exclude=dev/**",
            "--exclude=run",
            "--exclude=run/**",
            "--exclude=tmp",
            "--exclude=tmp/**",
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
            Log.info { "Skipping shards install for #{step.name} (prefetched during host setup)" }
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
      }
      if workdir
        Dir.cd(workdir, &run_block)
      else
        run_block.call
      end
    end

    # Returns true when shards install should be performed during build steps.
    private def run_shards_install?(env : Hash(String, String)) : Bool
      truthy_env?(env["BQ2_FORCE_SHARDS_INSTALL"]?)
    end

    private def prefetch_shards(step : BuildStep, env : Hash(String, String)) : Nil
      extract_specs = step.extract_sources || raise "prefetch-shards requires step.extract_sources"
      destdir = step.destdir ? Path[step.destdir.not_nil!] : Path["."]
      extract_specs.each do |spec|
        build_dir = spec.build_directory
        next unless build_dir
        build_path = destdir / build_dir
        shard_file = build_path / "shard.yml"
        next unless File.exists?(shard_file)
        unless Dir.exists?(build_path)
          Log.warn { "Skipping shards prefetch for #{build_path}: missing build directory" }
          next
        end
        Log.info { "Prefetching shards dependencies in #{build_path}" }
        Dir.cd(build_path) do
          run_cmd(["shards", "install"], env: env)
        end
      end
    end

    # Download all configured package sources and return their cached paths.
    def download_sources(step : BuildStep) : Array(Path)
      sources = step.sources || raise "download-sources requires step.sources"
      sources_dir = step.destdir ? Path[step.destdir.not_nil!] : sources_dir()
      sources.map { |spec| download_and_verify(spec, sources_dir) }
    end

    # Download a source tarball (if missing) into the source cache and verify
    # its checksum before returning the cached path.
    def download_and_verify(spec : SourceSpec, target_dir : Path = sources_dir) : Path
      target = target_dir / spec.filename
      attempts = 3
      attempts.times do |idx|
        begin
          if File.exists?(target)
            if File.size(target) > 0 && verify(spec, target)
              return target
            else
              File.delete(target)
            end
          end

          Log.debug { "Downloading #{spec.name} #{spec.version} from #{spec.url}" }
          elapsed = ProcessRunner.run_fibered("Downloading #{spec.name}") do
            download_with_redirects(spec.url, target)
            raise "Empty download for #{spec.name}" if File.size(target) == 0
            verify(spec, target)
          end
          Log.info { "Downloaded #{spec.name} in #{elapsed.total_seconds.round(3)}s" }
          return target
        rescue error
          File.delete(target) if File.exists?(target)
          raise error if idx == attempts - 1
          Log.warn { "Retrying #{spec.name} after error: #{error.message}" }
          sleep 2.seconds
        end
      end
      target
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

    # Extract all configured package sources into the workdir.
    #
    # When `skip_existing_sources` is enabled, archives with an existing
    # `build_directory` are skipped to avoid overwriting previously extracted
    # sources during resume flows.
    def extract_sources(step : BuildStep) : Nil
      sources = step.extract_sources || raise "extract-sources requires step.extract_sources"
      destination = step.destdir ? Path[step.destdir.not_nil!] : Path["."]
      source_root = step.sources_directory ? Path[step.sources_directory.not_nil!] : sources_dir
      sources.each do |spec|
        archive = source_root / spec.filename
        raise "Missing source tarball #{archive}" unless File.exists?(archive)
        if @skip_existing_sources
          if (build_directory = spec.build_directory)
            build_path = destination / build_directory
            if File.exists?(build_path)
              Log.warn do
                "Skipping extract of #{spec.name} #{spec.version}: #{build_path} already exists; " \
                "remove the directory to force a clean re-extract if the previous run was incomplete"
              end
              next
            end
          end
        end
        Log.info { "Extracting #{archive} into #{destination}" }
        elapsed = ProcessRunner.run_fibered("Extracting #{spec.name}") do
          Tarball.extract(archive, destination, preserve_ownership: false, owner_uid: nil, owner_gid: nil)
        end
        Log.info { "Extracted #{spec.name} in #{elapsed.total_seconds.round(3)}s" }
        if build_directory = spec.build_directory
          build_path = destination / build_directory
          raise "Expected #{build_path} after extracting #{archive}" unless Dir.exists?(build_path)
        end
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
      return if patches.empty?
      applier = PatchApplier.new
      patches.each do |patch|
        Log.info { "Applying patch #{patch}" }
        result = applier.apply(patch)
        if result.already_applied?
          Log.info { "Patch already applied; skipping #{patch}" }
        else
          result.applied_files.each do |path|
            Log.info { "Applied #{patch} to #{path}" }
          end
          result.skipped_files.each do |path|
            Log.info { "Skipping already-applied hunk in #{patch} for #{path}" }
          end
        end
      end
    end

    private def sources_dir : Path
      @workspace.host_workdir.not_nil! / "sources"
    end

    private def verify(spec : SourceSpec, path : Path) : Bool
      expected = spec.sha256
      if expected.nil? && (checksum_url = spec.checksum_url)
        expected = fetch_checksum(checksum_url, spec.filename)
      end
      return true unless expected
      actual = sha256(path)
      raise "Checksum mismatch for #{spec.name} (expected #{expected}, got #{actual})" unless actual == expected
      true
    end

    private def fetch_checksum(url : String, filename : String) : String
      response = request_with_redirects("GET", url, max_redirects: 10)
      body = response.body
      body.each_line do |line|
        next if line.strip.empty?
        parts = line.split(/\s+/)
        next if parts.empty?
        if parts.size >= 2 && parts[1].includes?(filename)
          return parts[0]
        end
      end
      body.lines.first?.try(&.split(/\s+/).first) || raise "Unable to parse checksum from #{url}"
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

    private def download_with_redirects(url : String, target : Path, max_redirects : Int32 = 10) : Nil
      response = request_with_redirects("GET", url, max_redirects: max_redirects)
      FileUtils.mkdir_p(target.parent)
      if body_io = response.body_io?
        File.open(target, "w") { |io| IO.copy(body_io, io) }
        return
      end
      body = response.body
      raise "Empty response body for #{url}" if body.empty?
      File.write(target, body)
    end

    private def request_with_redirects(method : String, url : String, max_redirects : Int32) : HTTP::Client::Response
      redirects = 0
      current_url = url
      loop do
        response = HTTP::Client.exec(method, current_url)
        unless redirect?(response.status_code)
          unless response.success?
            message = "#{method} #{current_url} failed with HTTP #{response.status_code}"
            message += ": #{response.status_message}" if response.status_message.presence
            raise message
          end
          return response
        end
        raise "Redirect missing Location header" unless response.headers["Location"]?
        raise "Too many redirects" if redirects >= max_redirects
        current_url = resolve_redirect(current_url, response.headers["Location"])
        redirects += 1
      end
    end

    private def redirect?(status : Int32) : Bool
      status == 301 || status == 302 || status == 303 || status == 307 || status == 308
    end

    private def resolve_redirect(base : String, location : String) : String
      base_uri = URI.parse(base)
      target = URI.parse(location)
      return target.to_s if target.scheme
      base_uri.resolve(target).to_s
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
      sysroot_bin = "/opt/sysroot/bin"
      sysroot_lib = "/opt/sysroot/lib"
      if (path = merged["PATH"]?) && path.includes?(sysroot_bin)
        current = merged["LD_LIBRARY_PATH"]?
        unless current && current.split(':').includes?(sysroot_lib)
          Log.warn { "PATH includes #{sysroot_bin} without #{sysroot_lib} in LD_LIBRARY_PATH; check plan env for #{phase.name}/#{step.name}" }
        end
      end
      merged
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
