require "./spec_helper"

describe Bootstrap::TarWriter do
  it "writes a gzipped tarball containing all files" do
    with_tempdir do |dir|
      source = dir / "root"
      FileUtils.mkdir_p(source / "sub")
      File.write(source / "a.txt", "hello")
      File.write(source / "sub" / "b.txt", "world")

      output = dir / "out.tar.gz"
      Bootstrap::TarWriter.write_gz(
        sources: [source],
        output: output,
        base_path: source
      )

      File.exists?(output).should be_true
      File.size(output).should be > 0

      extract_dir = dir / "extracted"
      Bootstrap::Tarball.extract(output, extract_dir,
        preserve_ownership: false, owner_uid: nil, owner_gid: nil)

      File.read(extract_dir / "a.txt").should eq "hello"
      File.read(extract_dir / "sub" / "b.txt").should eq "world"
    end
  end

  it "excludes files matching an exclude prefix" do
    with_tempdir do |dir|
      source = dir / "root"
      FileUtils.mkdir_p(source)
      File.write(source / "keep.txt", "kept")
      File.write(source / ".bq2-rootfs", "marker")

      output = dir / "out.tar.gz"
      Bootstrap::TarWriter.write_gz(
        sources: [source],
        output: output,
        base_path: source,
        excludes: [".bq2-rootfs"]
      )

      extract_dir = dir / "extracted"
      Bootstrap::Tarball.extract(output, extract_dir,
        preserve_ownership: false, owner_uid: nil, owner_gid: nil)

      File.exists?(extract_dir / "keep.txt").should be_true
      File.exists?(extract_dir / ".bq2-rootfs").should be_false
    end
  end

  it "excludes entire directory subtrees matching an exclude prefix" do
    with_tempdir do |dir|
      source = dir / "root"
      FileUtils.mkdir_p(source / "var" / "lib" / "nested")
      FileUtils.mkdir_p(source / "var" / "log")
      File.write(source / "var" / "lib" / "state.json", "{}")
      File.write(source / "var" / "lib" / "nested" / "deep.txt", "deep")
      File.write(source / "var" / "log" / "messages", "log entry")
      File.write(source / "top.txt", "top")

      output = dir / "out.tar.gz"
      Bootstrap::TarWriter.write_gz(
        sources: [source],
        output: output,
        base_path: source,
        excludes: ["var/lib"]
      )

      extract_dir = dir / "extracted"
      Bootstrap::Tarball.extract(output, extract_dir,
        preserve_ownership: false, owner_uid: nil, owner_gid: nil)

      File.exists?(extract_dir / "top.txt").should be_true
      File.exists?(extract_dir / "var" / "log" / "messages").should be_true
      Dir.exists?(extract_dir / "var" / "lib").should be_false
      File.exists?(extract_dir / "var" / "lib" / "state.json").should be_false
      File.exists?(extract_dir / "var" / "lib" / "nested" / "deep.txt").should be_false
    end
  end

  it "produces the same output as without excludes when excludes is empty" do
    with_tempdir do |dir|
      source = dir / "root"
      FileUtils.mkdir_p(source)
      File.write(source / "file.txt", "content")

      out_no_excludes = dir / "no-excludes.tar.gz"
      Bootstrap::TarWriter.write_gz(
        sources: [source],
        output: out_no_excludes,
        base_path: source
      )

      out_empty_excludes = dir / "empty-excludes.tar.gz"
      Bootstrap::TarWriter.write_gz(
        sources: [source],
        output: out_empty_excludes,
        base_path: source,
        excludes: [] of String
      )

      File.size(out_no_excludes).should eq File.size(out_empty_excludes)
    end
  end
end
