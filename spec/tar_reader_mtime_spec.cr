require "./spec_helper"
require "../src/sysroot_builder"

class Bootstrap::SysrootBuilder
  def self._spec_write_tar_gz(source : Path, output : Path) : Nil
    TarWriter.write_gz(source, output)
  end

  def _spec_extract_tarball(path : Path, destination : Path) : Nil
    extract_tarball(path, destination, false)
  end
end

describe "Bootstrap::SysrootBuilder tar extraction" do
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
      Bootstrap::SysrootBuilder._spec_write_tar_gz(source, archive)

      builder = Bootstrap::SysrootBuilder.new(dir)
      builder._spec_extract_tarball(archive, dest)

      extracted = dest / "hello.txt"
      File.exists?(extracted).should be_true

      actual = File.info(extracted).modification_time.to_unix
      actual.should eq fixed.to_unix
    end
  end
end
