require "./spec_helper"
require "file_utils"

class StubBuilder < Bootstrap::SysrootBuilder
  property override_packages : Array(Bootstrap::SysrootBuilder::PackageSpec) = [] of Bootstrap::SysrootBuilder::PackageSpec

  def packages : Array(Bootstrap::SysrootBuilder::PackageSpec)
    override_packages.empty? ? super : override_packages
  end
end

private def with_temp_workdir(&block : Path ->)
  with_tempdir do |dir|
    Dir.cd(dir) do
      yield dir
    end
  end
end

describe Bootstrap::SysrootBuilder do
  it "exposes workspace directories" do
    with_temp_workdir do |dir|
      builder = Bootstrap::SysrootBuilder.new
      host_workdir = Path["data/sysroot"].expand
      builder.cache_dir.expand.should eq host_workdir / "cache"
      builder.checksum_dir.expand.should eq host_workdir / "cache/checksums"
      builder.sources_dir.expand.should eq host_workdir / "sources"
      builder.outer_rootfs_dir.expand.should eq host_workdir / "seed-rootfs"
    end
  end

  it "treats the serialized plan file as rootfs readiness" do
    with_temp_workdir do |dir|
      builder = Bootstrap::SysrootBuilder.new
      builder.rootfs_ready?.should be_false

      workspace = Bootstrap::SysrootWorkspace.new(host_workdir: builder.host_workdir)
      build_state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      FileUtils.mkdir_p(build_state.plan_path.parent)
      File.write(build_state.plan_path, "[]")
      builder.rootfs_ready?.should be_true
    end
  end

  it "builds a seed rootfs spec for the configured architecture" do
    with_temp_workdir do |_dir|
      builder = Bootstrap::SysrootBuilder.new(architecture: "arm64")
      spec = builder.seed_rootfs_spec
      spec.name.should eq "bootstrap-rootfs"
      spec.url.to_s.should contain("arm64")
    end
  end

  it "lists default packages" do
    with_temp_workdir do |_dir|
      names = Bootstrap::SysrootBuilder.new.packages.map(&.name)
      names.should contain("musl")
      names.should contain("shards")
      names.should contain("llvm-project")
    end
  end

  it "expands llvm into staged cmake steps" do
    with_temp_workdir do |_dir|
      builder = Bootstrap::SysrootBuilder.new
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
  end

  it "lists build phase names" do
    with_temp_workdir do |_dir|
      phases = Bootstrap::SysrootBuilder.new.phase_specs.map { |spec| spec.phase.name }
      phases.should eq ["host-setup", "sysroot-from-alpine", "rootfs-from-sysroot", "system-from-sysroot", "tools-from-system", "finalize-rootfs"]
    end
  end

  it "sets phase workdirs per namespace" do
    with_temp_workdir do |_dir|
      builder = Bootstrap::SysrootBuilder.new
      host_workdir = builder.host_workdir
      seed_workspace = Bootstrap::SysrootWorkspace.workspace_from(Bootstrap::SysrootWorkspace::Namespace::Seed, host_workdir).to_s
      bq2_workspace = Bootstrap::SysrootWorkspace.workspace_from(Bootstrap::SysrootWorkspace::Namespace::BQ2, host_workdir).to_s
      phases = builder.phase_specs.to_h { |spec| {spec.phase.name, spec.phase} }
      phases["host-setup"].workdir.should eq "/"
      phases["sysroot-from-alpine"].workdir.should eq seed_workspace
      phases["rootfs-from-sysroot"].workdir.should eq seed_workspace
      phases["system-from-sysroot"].workdir.should eq bq2_workspace
      phases["tools-from-system"].workdir.should eq bq2_workspace
      phases["finalize-rootfs"].workdir.should eq bq2_workspace
    end
  end

  it "seeds rootfs profile, CA bundle, and final musl loader path" do
    with_temp_workdir do |_dir|
      builder = Bootstrap::SysrootBuilder.new
      sysroot_phase = builder.phase_specs.find { |spec| spec.phase.name == "sysroot-from-alpine" }.not_nil!
      sysroot_zlib_env = sysroot_phase.env_overrides["zlib"]
      sysroot_zlib_env["CFLAGS"].should contain("-fPIC")
      rootfs_phase = builder.phase_specs.find { |spec| spec.phase.name == "rootfs-from-sysroot" }.not_nil!
      prepare_step = rootfs_phase.extra_steps.find(&.name.==("prepare-rootfs")).not_nil!
      profile = prepare_step.env["FILE_1_CONTENT"]
      profile.should contain("SSL_CERT_FILE=\"/etc/ssl/certs/ca-certificates.crt\"")
      profile.should contain("LANG=C.UTF-8")
      ca_bundle = prepare_step.env["FILE_4_CONTENT"]
      ca_bundle.should contain("BEGIN CERTIFICATE")

      system_phase = builder.phase_specs.find { |spec| spec.phase.name == "system-from-sysroot" }.not_nil!
      system_zlib_env = system_phase.env_overrides["zlib"]
      system_zlib_env["CFLAGS"].should contain("-fPIC")

      finalize_phase = builder.phase_specs.find { |spec| spec.phase.name == "finalize-rootfs" }.not_nil!
      final_ld_step = finalize_phase.extra_steps.find(&.name.==("musl-ld-path-final")).not_nil!
      final_ld_step.content.should eq "/lib:/usr/lib\n"
    end
  end

  it "builds a plan for each package" do
    with_temp_workdir do |dir|
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
      builder = StubBuilder.new
      builder.override_packages = [pkg, musl, busybox, linux_headers]
      plan = builder.build_plan
      plan.phases.map(&.name).should eq ["host-setup", "sysroot-from-alpine", "rootfs-from-sysroot", "system-from-sysroot", "finalize-rootfs"]
      sysroot_phase = plan.phases.find(&.name.==("sysroot-from-alpine")).not_nil!
      sysroot_phase.install_prefix.should eq "/opt/sysroot"
      sysroot_phase.destdir.should be_nil
      sysroot_phase.steps.size.should eq 5
      sysroot_phase.steps.find(&.name.==("pkg")).not_nil!.configure_flags.should eq ["--foo"]

      rootfs_phase = plan.phases.find(&.name.==("rootfs-from-sysroot")).not_nil!
      rootfs_phase.install_prefix.should eq "/usr"
      rootfs_phase.destdir.should eq "/bq2-rootfs"
      rootfs_phase.steps.map(&.name).should eq ["musl", "busybox", "linux-headers", "musl-ld-path", "prepare-rootfs", "sysroot"]

      finalize_phase = plan.phases.find(&.name.==("finalize-rootfs")).not_nil!
      finalize_phase.steps.map(&.name).should eq ["strip-sysroot", "musl-ld-path-final", "rootfs-tarball"]
    end
  end

  it "writes a phased build plan into the chroot var/lib directory" do
    with_temp_workdir do |dir|
      builder = StubBuilder.new
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
      plan = Bootstrap::BuildPlan.parse(File.read(plan_path))
      plan.phases.map(&.name).should eq ["host-setup", "sysroot-from-alpine", "rootfs-from-sysroot", "system-from-sysroot", "finalize-rootfs"]
    end
  end
end
