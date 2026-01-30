require "./spec_helper"
require "http/server"
require "socket"
require "file_utils"
require "digest"
require "random/secure"

class StubBuilder < Bootstrap::SysrootBuilder
  property fake_tarball : Path?
  property override_packages : Array(Bootstrap::SysrootBuilder::PackageSpec) = [] of Bootstrap::SysrootBuilder::PackageSpec
  property skip_stage_sources : Bool = false
  property stage_sources_calls : Int32 = 0
  property package_tarballs : Hash(String, Path) = {} of String => Path

  def packages : Array(Bootstrap::SysrootBuilder::PackageSpec)
    override_packages.empty? ? super : override_packages
  end

  def download_and_verify(pkg : Bootstrap::SysrootBuilder::PackageSpec) : Path
    return fake_tarball.not_nil! if fake_tarball && pkg.name == "bootstrap-rootfs"
    if tarball = package_tarballs[pkg.name]?
      return tarball
    end
    super
  end

  def stage_sources : Nil
    @stage_sources_calls += 1
    return if skip_stage_sources
    super
  end
end

def write_tar_header(io : IO, name : String, size : Int64, typeflag : Char, mode : Int32)
  header = Bytes.new(512, 0)
  write_tar_string(header, 0, 100, name)
  write_tar_octal(header, 100, 8, mode)
  write_tar_octal(header, 108, 8, 0)
  write_tar_octal(header, 116, 8, 0)
  write_tar_octal(header, 124, 12, size)
  write_tar_octal(header, 136, 12, Time.utc.to_unix)
  8.times { |idx| header[148 + idx] = 0x20_u8 }
  header[156] = typeflag.ord.to_u8
  write_tar_string(header, 257, 6, "ustar")
  write_tar_string(header, 263, 2, "00")
  checksum = header.sum { |byte| byte.to_i64 }
  write_tar_octal(header, 148, 8, checksum)
  io.write(header)
end

def write_tar_string(buffer : Bytes, offset : Int32, length : Int32, value : String)
  bytes = value.to_slice
  limit = Math.min(bytes.size, length)
  limit.times { |idx| buffer[offset + idx] = bytes[idx] }
end

def write_tar_octal(buffer : Bytes, offset : Int32, length : Int32, value : Int64)
  string = value.to_s(8).rjust(length - 1, '0')
  write_tar_string(buffer, offset, length - 1, string)
  buffer[offset + length - 1] = 0
end

def pad_tar(io : IO, size : Int64)
  remainder = size % 512
  return if remainder == 0
  io.write(Bytes.new(512 - remainder, 0))
end

def socket_blocked_reason
  server = TCPServer.new("127.0.0.1", 0)
  server.close
  nil
rescue ex : Socket::Error
  "socket creation is blocked (#{ex.message})"
end

SOCKET_BLOCKED_REASON = socket_blocked_reason

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
      builder.outer_rootfs_dir.should eq dir / "rootfs"
    end
  end

  it "treats the serialized plan file as rootfs readiness" do
    with_tempdir do |dir|
      builder = Bootstrap::SysrootBuilder.new(dir)
      builder.rootfs_ready?.should be_false

      FileUtils.mkdir_p(builder.plan_path.parent)
      File.write(builder.plan_path, "[]")
      builder.rootfs_ready?.should be_true
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
    names.should contain("shards")
    names.should contain("llvm-project")
  end

  it "expands llvm into staged cmake steps" do
    builder = Bootstrap::SysrootBuilder.new(Path["/tmp/work"])
    plan = builder.build_plan
    sysroot_phase = plan.phases.find(&.name.==("sysroot-from-alpine")).not_nil!
    llvm_steps = sysroot_phase.steps.select { |step| step.name.starts_with?("llvm-project-stage") }
    llvm_steps.map(&.name).should eq ["llvm-project-stage1", "llvm-project-stage2"]
    llvm_steps.all? { |step| step.strategy == "cmake-project" }.should be_true
    llvm_steps.each do |step|
      step.env["CMAKE_SOURCE_DIR"].should eq "llvm"
    end
    sysroot_phase.steps.any? { |step| step.name == "llvm-project" }.should be_false
  end

  it "lists build phase names" do
    phases = Bootstrap::SysrootBuilder.new.phase_specs.map(&.name)
    phases.should eq ["sysroot-from-alpine", "rootfs-from-sysroot", "system-from-sysroot", "tools-from-system", "finalize-rootfs"]
  end

  it "seeds rootfs profile, CA bundle, and final musl loader path" do
    builder = Bootstrap::SysrootBuilder.new(Path["/tmp/work"])
    sysroot_phase = builder.phase_specs.find(&.name.==("sysroot-from-alpine")).not_nil!
    sysroot_zlib_env = sysroot_phase.env_overrides["zlib"]
    sysroot_zlib_env["CFLAGS"].should contain("-fPIC")
    rootfs_phase = builder.phase_specs.find(&.name.==("rootfs-from-sysroot")).not_nil!
    prepare_step = rootfs_phase.extra_steps.find(&.name.==("prepare-rootfs")).not_nil!
    profile = prepare_step.env["FILE_1_CONTENT"]
    profile.should contain("SSL_CERT_FILE=\"/etc/ssl/certs/ca-certificates.crt\"")
    profile.should contain("LANG=C.UTF-8")
    ca_bundle = prepare_step.env["FILE_4_CONTENT"]
    ca_bundle.should contain("BEGIN CERTIFICATE")

    system_phase = builder.phase_specs.find(&.name.==("system-from-sysroot")).not_nil!
    system_zlib_env = system_phase.env_overrides["zlib"]
    system_zlib_env["CFLAGS"].should contain("-fPIC")

    finalize_phase = builder.phase_specs.find(&.name.==("finalize-rootfs")).not_nil!
    final_ld_step = finalize_phase.extra_steps.find(&.name.==("musl-ld-path-final")).not_nil!
    final_ld_step.env["CONTENT"].should eq "/lib:/usr/lib\n"
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

  if reason = SOCKET_BLOCKED_REASON
    pending "fetches remote checksums (#{reason})" do
    end
  else
    it "fetches remote checksums" do
      with_http_server("1234 demo.tar") do |url|
        pkg = Bootstrap::SysrootBuilder::PackageSpec.new("demo", "1", URI.parse("https://example.com/demo.tar"), checksum_url: URI.parse(url))
        builder = Bootstrap::SysrootBuilder.new(Path["/tmp/work"])
        builder.fetch_remote_checksum(pkg).should eq "1234"
      end
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

  if reason = SOCKET_BLOCKED_REASON
    pending "downloads and verifies using HTTP (#{reason})" do
    end
  else
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
  end

  it "builds a plan for each package" do
    with_tempdir do |dir|
      pkg = Bootstrap::SysrootBuilder::PackageSpec.new("pkg", "1.0", URI.parse("https://example.com/pkg-1.0.tar.gz"), configure_flags: ["--foo"])
      musl = Bootstrap::SysrootBuilder::PackageSpec.new("musl", "1.0", URI.parse("https://example.com/musl-1.0.tar.gz"))
      busybox = Bootstrap::SysrootBuilder::PackageSpec.new("busybox", "1.0", URI.parse("https://example.com/busybox-1.0.tar.gz"), strategy: "busybox")
      linux_headers = Bootstrap::SysrootBuilder::PackageSpec.new(
        "linux-headers",
        "1.0",
        URI.parse("https://example.com/linux-1.0.tar.gz"),
        strategy: "linux-headers",
        phases: ["rootfs-from-sysroot"],
      )
      builder = StubBuilder.new(dir)
      builder.override_packages = [pkg, musl, busybox, linux_headers]
      plan = builder.build_plan
      plan.phases.map(&.name).should eq ["sysroot-from-alpine", "rootfs-from-sysroot", "system-from-sysroot", "finalize-rootfs"]
      sysroot_phase = plan.phases.first
      sysroot_phase.install_prefix.should eq "/opt/sysroot"
      sysroot_phase.destdir.should be_nil
      sysroot_phase.steps.size.should eq 3
      sysroot_phase.steps.find(&.name.==("pkg")).not_nil!.configure_flags.should eq ["--foo"]

      rootfs_phase = plan.phases.find(&.name.==("rootfs-from-sysroot")).not_nil!
      rootfs_phase.install_prefix.should eq "/usr"
      rootfs_phase.destdir.should eq "/workspace/rootfs"
      rootfs_phase.steps.map(&.name).should eq ["musl", "busybox", "linux-headers", "musl-ld-path", "prepare-rootfs", "sysroot"]

      finalize_phase = plan.phases.find(&.name.==("finalize-rootfs")).not_nil!
      finalize_phase.steps.map(&.name).should eq ["strip-sysroot", "musl-ld-path-final", "rootfs-tarball"]
    end
  end

  it "writes a phased build plan into the chroot var/lib directory" do
    with_tempdir do |dir|
      builder = StubBuilder.new(dir)
      builder.override_packages = [
        Bootstrap::SysrootBuilder::PackageSpec.new("musl", "1.0", URI.parse("https://example.com/musl.tar.gz")),
        Bootstrap::SysrootBuilder::PackageSpec.new("busybox", "1.0", URI.parse("https://example.com/busybox.tar.gz"), strategy: "busybox"),
        Bootstrap::SysrootBuilder::PackageSpec.new(
          "linux-headers",
          "1.0",
          URI.parse("https://example.com/linux.tar.gz"),
          strategy: "linux-headers",
          phases: ["rootfs-from-sysroot"],
        ),
      ]
      plan_path = builder.write_plan
      File.exists?(plan_path).should be_true
      plan = Bootstrap::BuildPlan.from_json(File.read(plan_path))
      plan.phases.map(&.name).should eq ["sysroot-from-alpine", "rootfs-from-sysroot", "system-from-sysroot", "finalize-rootfs"]
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
      source_tar = dir / "bootstrap.tar"
      source_dir = dir / "bootstrap-qcow2"
      FileUtils.mkdir_p(source_dir / "src")
      File.write(source_dir / "src/main.cr", "puts \"hello\"")
      Process.run("tar", ["-cf", source_tar.to_s, "-C", dir.to_s, "bootstrap-qcow2"])
      builder.override_packages = [
        Bootstrap::SysrootBuilder::PackageSpec.new(
          "bootstrap-qcow2",
          "test",
          URI.parse("https://example.com/bootstrap-qcow2.tar"),
          build_directory: "bootstrap-qcow2"
        ),
      ]
      builder.package_tarballs["bootstrap-qcow2"] = source_tar
      builder.fake_tarball = tarball
      rootfs = builder.prepare_rootfs
      File.exists?(rootfs / "workspace").should be_true
      File.exists?(builder.inner_rootfs_workspace_dir / "bootstrap-qcow2/src/main.cr").should be_true
    end
  end

  it "prepares rootfs from a base rootfs tarball path" do
    with_tempdir do |dir|
      tar_dir = dir / "tarroot"
      FileUtils.mkdir_p(tar_dir)
      File.write(tar_dir / "etc.txt", "config")
      tarball = dir / "miniroot.tar"
      Process.run("tar", ["-cf", tarball.to_s, "-C", tar_dir.to_s, "."])

      builder = StubBuilder.new(dir, base_rootfs_path: tarball)
      builder.override_packages = [] of Bootstrap::SysrootBuilder::PackageSpec
      builder.skip_stage_sources = true
      rootfs = builder.prepare_rootfs(include_sources: false)
      File.exists?(rootfs / "etc.txt").should be_true
    end
  end

  it "replaces directories with files when tar entries conflict" do
    with_tempdir do |dir|
      tarball = dir / "conflict.tar"
      File.open(tarball, "w") do |io|
        write_tar_header(io, "foo/", 0_i64, '5', 0o755)
        content = "replacement"
        write_tar_header(io, "foo", content.bytesize.to_i64, '0', 0o644)
        io.write(content.to_slice)
        pad_tar(io, content.bytesize.to_i64)
        io.write(Bytes.new(1024, 0))
      end

      builder = StubBuilder.new(dir, base_rootfs_path: tarball)
      builder.override_packages = [] of Bootstrap::SysrootBuilder::PackageSpec
      builder.skip_stage_sources = true
      rootfs = builder.prepare_rootfs(include_sources: false)

      File.file?(rootfs / "foo").should be_true
      File.exists?(rootfs / "foo" / "bar.txt").should be_false
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
      builder.override_packages = builder.packages
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
      pkg_tar = dir / "pkg.tar"
      pkg_dir = dir / "pkg"
      FileUtils.mkdir_p(pkg_dir)
      File.write(pkg_dir / "readme.txt", "pkg")
      Process.run("tar", ["-cf", pkg_tar.to_s, "-C", dir.to_s, "pkg"])
      builder.package_tarballs["pkg"] = pkg_tar
      builder.fake_tarball = tarball
      builder.prepare_rootfs(include_sources: true)
      builder.stage_sources_calls.should eq 1
      Dir.children(builder.inner_rootfs_workspace_dir).should_not be_empty
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
      builder.skip_stage_sources = true
      builder.fake_tarball = tarball
      output = dir / "chroot.tar.gz"
      builder.generate_chroot_tarball(output)
      File.exists?(output).should be_true
    end
  end

  it "uses a default tarball location when output is omitted" do
    with_tempdir do |dir|
      tar_dir = dir / "tarroot"
      FileUtils.mkdir_p(tar_dir)
      File.write(tar_dir / "etc.txt", "config")
      tarball = dir / "miniroot.tar"
      Process.run("tar", ["-cf", tarball.to_s, "-C", tar_dir.to_s, "."])

      builder = StubBuilder.new(dir)
      builder.override_packages = [] of Bootstrap::SysrootBuilder::PackageSpec
      builder.skip_stage_sources = true
      builder.fake_tarball = tarball
      output = builder.generate_chroot_tarball
      output.should eq dir / "sysroot.tar.gz"
      File.exists?(output).should be_true
    end
  end

  it "can write a tarball for an existing prepared rootfs" do
    with_tempdir do |dir|
      tar_dir = dir / "tarroot"
      FileUtils.mkdir_p(tar_dir)
      File.write(tar_dir / "etc.txt", "config")
      tarball = dir / "miniroot.tar"
      Process.run("tar", ["-cf", tarball.to_s, "-C", tar_dir.to_s, "."])

      builder = StubBuilder.new(dir)
      builder.override_packages = [] of Bootstrap::SysrootBuilder::PackageSpec
      builder.skip_stage_sources = true
      builder.fake_tarball = tarball
      builder.generate_chroot(include_sources: false)

      output = dir / "existing-rootfs.tar.gz"
      builder.write_chroot_tarball(output)
      File.exists?(output).should be_true
    end
  end

  it "can prepare a chroot directory without a tarball" do
    with_tempdir do |dir|
      tar_dir = dir / "tarroot"
      FileUtils.mkdir_p(tar_dir)
      File.write(tar_dir / "etc.txt", "config")
      tarball = dir / "miniroot.tar"
      Process.run("tar", ["-cf", tarball.to_s, "-C", tar_dir.to_s, "."])

      builder = StubBuilder.new(dir)
      builder.override_packages = [] of Bootstrap::SysrootBuilder::PackageSpec
      builder.skip_stage_sources = true
      builder.fake_tarball = tarball
      rootfs = builder.generate_chroot
      rootfs.should eq builder.outer_rootfs_dir
      File.exists?(rootfs / "workspace").should be_true
    end
  end

  it "prepares a rootfs with the coordinator staged" do
    with_tempdir do |dir|
      tar_dir = dir / "tarroot"
      FileUtils.mkdir_p(tar_dir)
      File.write(tar_dir / "etc.txt", "config")
      tarball = dir / "miniroot.tar"
      Process.run("tar", ["-cf", tarball.to_s, "-C", tar_dir.to_s, "."])

      builder = StubBuilder.new(dir)
      source_tar = dir / "bootstrap.tar"
      source_dir = dir / "bootstrap-qcow2"
      FileUtils.mkdir_p(source_dir / "src")
      File.write(source_dir / "src/main.cr", "puts \"hello\"")
      Process.run("tar", ["-cf", source_tar.to_s, "-C", dir.to_s, "bootstrap-qcow2"])
      builder.override_packages = [
        Bootstrap::SysrootBuilder::PackageSpec.new(
          "bootstrap-qcow2",
          "test",
          URI.parse("https://example.com/bootstrap-qcow2.tar"),
          build_directory: "bootstrap-qcow2"
        ),
      ]
      builder.package_tarballs["bootstrap-qcow2"] = source_tar
      builder.fake_tarball = tarball
      builder.prepare_rootfs
      File.exists?(builder.inner_rootfs_workspace_dir / "bootstrap-qcow2/src/main.cr").should be_true
    end
  end
end
