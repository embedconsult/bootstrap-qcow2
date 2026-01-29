require "./spec_helper"

describe "Bootstrap::Tarball" do
  it "preserves entry mtimes from the archive" do
    with_tempdir do |dir|
      source = dir / "src"
      dest = dir / "dest"
      FileUtils.mkdir_p(source)
      FileUtils.mkdir_p(dest)

      file_path = source / "hello.txt"
      File.write(file_path, "hello")
      fixed = Time.unix(1_700_000_000)
      File.utime(fixed, fixed, file_path)

      archive = dir / "out.tar.gz"
      Bootstrap::Tarball.write_gz(source, archive)

      Bootstrap::Tarball.extract(archive, dest, false, nil, nil)

      extracted = dest / "hello.txt"
      File.exists?(extracted).should be_true

      actual = File.info(extracted).modification_time.to_unix
      actual.should eq fixed.to_unix
    end
  end
end
