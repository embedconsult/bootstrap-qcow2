require "./spec_helper"
require "http/server"
require "socket"
require "file_utils"
require "digest"
require "random/secure"

def with_tempdir(&)
  path = Path[Dir.tempdir] / "sysroot-spec-#{Random::Secure.hex(8)}"
  FileUtils.mkdir_p(path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

class StubBuilder < Bootstrap::SysrootBuilder
  property fake_tarball : Path?
  property override_packages : Array(Bootstrap::SysrootBuilder::PackageSpec) = [] of Bootstrap::SysrootBuilder::PackageSpec
  property skip_stage_sources : Bool = false
  property stage_sources_calls : Int32 = 0

  def packages : Array(Bootstrap::SysrootBuilder::PackageSpec)
    override_packages.empty? ? super : override_packages
  end

  def download_and_verify(pkg : Bootstrap::SysrootBuilder::PackageSpec) : Path
    return fake_tarball.not_nil! if fake_tarball
    super
  end

  def stage_sources : Nil
    @stage_sources_calls += 1
    return if skip_stage_sources
    super
  end
end

def with_http_server(body : String, &)
  server = HTTP::Server.new do |context|
    context.response.content_type = "application/octet-stream"
    context.response.print(body)
  end

  address = server.bind_tcp("127.0.0.1", 0)
  port = address.port
  spawn { server.listen }
  url = "http://127.0.0.1:#{port}/file"
  sleep 50.milliseconds
  begin
    yield url
  ensure
    server.close
  end
end

describe Bootstrap::SysrootBuilder do
  it "exposes workspace directories" do
    with_tempdir do |dir|
      builder = Bootstrap::SysrootBuilder.new(dir)
      builder.cache_dir.should eq dir / "cache"
      builder.checksum_dir.should eq dir / "cache/checksums"
      builder.sources_dir.should eq dir / "sources"
      builder.rootfs_dir.should eq dir / "rootfs"
    end
  end

  it "builds a base rootfs spec for the configured architecture" do
    builder = Bootstrap::SysrootBuilder.new(Path["/tmp/work"], "arm64", "edge", "edge")
    spec = builder.base_rootfs_spec
    spec.name.should eq "bootstrap-rootfs"
    spec.url.to_s.should contain("arm64")
  end

  it "lists default packages" do
    names = Bootstrap::SysrootBuilder.new.packages.map(&.name)
    names.should contain("musl")
    names.should contain("llvm-project")
  end

  it "computes hashes" do
    with_tempdir do |dir|
      path = dir / "data.txt"
      File.write(path, "hello")
      builder = Bootstrap::SysrootBuilder.new(dir)
      builder.sha256(path).size.should eq 64
      builder.crc32(path).should_not be_empty
    end
  end

  it "writes and caches checksums" do
    with_tempdir do |dir|
      builder = Bootstrap::SysrootBuilder.new(dir)
      builder.write_checksum(Bootstrap::SysrootBuilder::PackageSpec.new("demo", "1", URI.parse("https://example.com/demo.tar")), "abc", "def")
      builder.cached_sha256(Bootstrap::SysrootBuilder::PackageSpec.new("demo", "1", URI.parse("https://example.com/demo.tar"))).should eq "abc"
      builder.cached_crc32(Bootstrap::SysrootBuilder::PackageSpec.new("demo", "1", URI.parse("https://example.com/demo.tar"))).should eq "def"
    end
  end

  it "fetches remote checksums" do
    with_http_server("1234 demo.tar") do |url|
      pkg = Bootstrap::SysrootBuilder::PackageSpec.new("demo", "1", URI.parse("https://example.com/demo.tar"), checksum_url: URI.parse(url))
      builder = Bootstrap::SysrootBuilder.new(Path["/tmp/work"])
      builder.fetch_remote_checksum(pkg).should eq "1234"
    end
  end

  it "verifies content with explicit sha" do
    with_tempdir do |dir|
      path = dir / "file.txt"
      File.write(path, "abc")
      sha = Digest::SHA256.hexdigest("abc")
      pkg = Bootstrap::SysrootBuilder::PackageSpec.new("demo", "1", URI.parse("https://example.com/demo.tar"), sha256: sha)
      builder = Bootstrap::SysrootBuilder.new(dir)
      builder.verify(pkg, path).should be_true
    end
  end

  it "downloads and verifies using HTTP" do
    with_tempdir do |dir|
      with_http_server("payload") do |url|
        sha = Digest::SHA256.hexdigest("payload")
        pkg = Bootstrap::SysrootBuilder::PackageSpec.new("demo", "1", URI.parse(url), sha256: sha)
        builder = StubBuilder.new(dir)
        builder.override_packages = [pkg]
        downloaded = builder.download_and_verify(pkg)
        File.exists?(downloaded).should be_true
      end
    end
  end

  it "builds a plan for each package" do
    with_tempdir do |dir|
      pkg = Bootstrap::SysrootBuilder::PackageSpec.new("pkg", "1.0", URI.parse("https://example.com/pkg-1.0.tar.gz"), configure_flags: ["--foo"])
      builder = StubBuilder.new(dir)
      builder.override_packages = [pkg]
      plan = builder.build_plan
      plan.size.should eq 1
      step = plan.first
      step.name.should eq "pkg"
      step.configure_flags.should eq ["--foo"]
      step.sysroot_prefix.should eq "/opt/sysroot"
    end
  end

  it "prepares rootfs from a local tarball" do
    with_tempdir do |dir|
      tar_dir = dir / "tarroot"
      FileUtils.mkdir_p(tar_dir)
      File.write(tar_dir / "etc.txt", "config")
      tarball = dir / "miniroot.tar"
      Process.run("tar", ["-cf", tarball.to_s, "-C", tar_dir.to_s, "."])

      builder = StubBuilder.new(dir)
      builder.override_packages = [] of Bootstrap::SysrootBuilder::PackageSpec
      builder.fake_tarball = tarball
      rootfs = builder.prepare_rootfs
      File.exists?(rootfs / "workspace").should be_true
      File.exists?(rootfs / "usr/local/bin/sysroot_runner_main.cr").should be_true
    end
  end

  it "can skip staging sources on request" do
    with_tempdir do |dir|
      tar_dir = dir / "tarroot"
      FileUtils.mkdir_p(tar_dir)
      File.write(tar_dir / "etc.txt", "config")
      tarball = dir / "miniroot.tar"
      Process.run("tar", ["-cf", tarball.to_s, "-C", tar_dir.to_s, "."])

      builder = StubBuilder.new(dir)
      builder.override_packages = [] of Bootstrap::SysrootBuilder::PackageSpec
      builder.fake_tarball = tarball
      builder.prepare_rootfs(include_sources: false)
      builder.stage_sources_calls.should eq 0
    end
  end

  it "stages sources into the workspace when enabled" do
    with_tempdir do |dir|
      tar_dir = dir / "tarroot"
      FileUtils.mkdir_p(tar_dir)
      File.write(tar_dir / "etc.txt", "config")
      tarball = dir / "miniroot.tar"
      Process.run("tar", ["-cf", tarball.to_s, "-C", tar_dir.to_s, "."])

      pkg = Bootstrap::SysrootBuilder::PackageSpec.new("pkg", "1.0", URI.parse("https://example.com/pkg.tar"))
      builder = StubBuilder.new(dir)
      builder.override_packages = [pkg]
      builder.fake_tarball = tarball
      builder.prepare_rootfs(include_sources: true)
      builder.stage_sources_calls.should eq 1
      Dir.children(builder.rootfs_dir / "workspace").should_not be_empty
    end
  end

  it "generates a chroot tarball" do
    with_tempdir do |dir|
      tar_dir = dir / "tarroot"
      FileUtils.mkdir_p(tar_dir)
      File.write(tar_dir / "etc.txt", "config")
      tarball = dir / "miniroot.tar"
      Process.run("tar", ["-cf", tarball.to_s, "-C", tar_dir.to_s, "."])

      builder = StubBuilder.new(dir)
      builder.override_packages = [] of Bootstrap::SysrootBuilder::PackageSpec
      builder.fake_tarball = tarball
      output = dir / "chroot.tar.gz"
      builder.generate_chroot_tarball(output)
      File.exists?(output).should be_true
    end
  end

  it "returns chroot command when running in dry-run mode" do
    with_tempdir do |dir|
      tar_dir = dir / "tarroot"
      FileUtils.mkdir_p(tar_dir)
      File.write(tar_dir / "etc.txt", "config")
      tarball = dir / "miniroot.tar"
      Process.run("tar", ["-cf", tarball.to_s, "-C", tar_dir.to_s, "."])

      builder = StubBuilder.new(dir)
      builder.override_packages = [] of Bootstrap::SysrootBuilder::PackageSpec
      builder.fake_tarball = tarball
      builder.prepare_rootfs
      commands = builder.rebuild_in_chroot(true)
      commands.should eq [
        ["apk", "add", "--no-cache", "crystal"],
        ["crystal", "run", "/usr/local/bin/sysroot_runner_main.cr"],
      ]
    end
  end
end
