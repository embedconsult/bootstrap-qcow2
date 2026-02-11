require "./spec_helper"

describe Bootstrap::StepRunner do
  server_ok, server_reason = tcp_server_available?

  it "skips extracting sources with existing build directories when enabled" do
    with_tempdir do |dir|
      host_workdir = dir / "sysroot"
      workspace = Bootstrap::SysrootWorkspace.create(host_workdir: host_workdir)
      sources_dir = dir / "sources"
      FileUtils.mkdir_p(sources_dir)

      archive_source = dir / "archive"
      build_directory = archive_source / "m4-1.4.19"
      FileUtils.mkdir_p(build_directory)
      File.write(build_directory / "bootstrap", "fresh")

      archive_path = sources_dir / "m4-1.4.19.tar.gz"
      Bootstrap::TarWriter.write_gz([archive_source], archive_path, base_path: archive_source)

      destination = workspace.workspace_path
      existing = destination / "m4-1.4.19"
      FileUtils.mkdir_p(existing)
      File.write(existing / "bootstrap", "original")

      step = Bootstrap::BuildStep.new(
        name: "extract-sources",
        strategy: "extract-sources",
        workdir: nil,
        configure_flags: [] of String,
        patches: [] of String,
        destdir: destination.to_s,
        sources_directory: sources_dir.to_s,
        extract_sources: [
          Bootstrap::ExtractSpec.new(
            name: "m4",
            version: "1.4.19",
            filename: "m4-1.4.19.tar.gz",
            build_directory: "m4-1.4.19",
          ),
        ],
      )

      runner = Bootstrap::StepRunner.new(workspace: workspace)
      runner.skip_existing_sources = true
      runner.extract_sources(step)

      File.read(existing / "bootstrap").should eq("original")
    end
  end

  it "prefetches shards dependencies for extracted shard projects" do
    with_tempdir do |dir|
      host_workdir = dir / "sysroot"
      workspace = Bootstrap::SysrootWorkspace.create(host_workdir: host_workdir)
      destdir = workspace.workspace_path
      shard_dir = destdir / "shards-0.18.0"
      FileUtils.mkdir_p(shard_dir)
      File.write(shard_dir / "shard.yml", "name: example\nversion: 0.1.0\n")

      bin_dir = dir / "bin"
      FileUtils.mkdir_p(bin_dir)
      shards_script = bin_dir / "shards"
      File.write(shards_script, "#!/bin/sh\n touch .shards-install-ran\n")
      File.chmod(shards_script, 0o755)

      step = Bootstrap::BuildStep.new(
        name: "prefetch-shards",
        strategy: "prefetch-shards",
        workdir: nil,
        configure_flags: [] of String,
        patches: [] of String,
        destdir: destdir.to_s,
        extract_sources: [
          Bootstrap::ExtractSpec.new(
            name: "shards",
            version: "0.18.0",
            filename: "shards-0.18.0.tar.gz",
            build_directory: "shards-0.18.0",
          ),
        ],
        env: {} of String => String,
      )

      phase = Bootstrap::BuildPhase.new(
        name: "host-setup",
        description: "prefetch",
        namespace: "host",
        install_prefix: "/opt/sysroot",
        steps: [step],
      )

      runner = Bootstrap::StepRunner.new(workspace: workspace)
      # Process argv lookup uses the parent process PATH. Override ENV here so
      # `shards` resolves to our fixture script before the real executable.
      with_env({"PATH" => "#{bin_dir}:#{ENV["PATH"]?}"}) do
        runner.run(phase, step)
      end

      File.exists?(shard_dir / ".shards-install-ran").should be_true
    end
  end

  if server_ok
    it "fails download_and_verify on non-success HTTP responses" do
      with_tempdir do |dir|
        host_workdir = dir / "sysroot"
        workspace = Bootstrap::SysrootWorkspace.create(host_workdir: host_workdir)
        runner = Bootstrap::StepRunner.new(workspace: workspace)

        with_server(status_code: 404, message: "missing") do |port|
          spec = Bootstrap::SourceSpec.new(
            name: "missing",
            version: "1.0.0",
            url: "http://127.0.0.1:#{port}/missing.tar.gz",
            filename: "missing.tar.gz",
          )

          expect_raises(Exception, /HTTP 404/) do
            runner.download_and_verify(spec)
          end
        end
      end
    end
  else
    pending "fails download_and_verify on non-success HTTP responses (HTTP server unavailable: #{server_reason || "unknown"})" do
    end
  end
end
