require "./spec_helper"
require "../src/tar_writer"

describe Bootstrap::StepRunner do
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
end
