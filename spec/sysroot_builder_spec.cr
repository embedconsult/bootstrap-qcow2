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

private def sysroot_triple_for(arch : String) : String
  case arch
  when "aarch64", "arm64"
    "aarch64-bq2-linux-musl"
  when "x86_64", "amd64"
    "x86_64-bq2-linux-musl"
  else
    "#{arch}-bq2-linux-musl"
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
      File.write(build_state.plan_path, Bootstrap::BuildPlan.new([] of Bootstrap::BuildPhase).to_json)
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

  it "builds a seed rootfs spec for the published bq2 seed tarball" do
    with_temp_workdir do |_dir|
      builder = Bootstrap::SysrootBuilder.new(seed: Bootstrap::SysrootBuilder::BQ2_SEED_NAME)
      spec = builder.seed_rootfs_spec
      spec.name.should eq "bootstrap-rootfs"
      spec.version.should eq Bootstrap::SysrootBuilder::BQ2_SEED_NAME
      spec.url.to_s.should eq Bootstrap::SysrootBuilder::DEFAULT_BQ2_SEED_URL
    end
  end

  it "includes apk bootstrap only for Alpine seed" do
    with_temp_workdir do |_dir|
      alpine_builder = Bootstrap::SysrootBuilder.new
      alpine_phase = alpine_builder.build_plan.phases.find(&.name.==("sysroot-from-seed")).not_nil!
      alpine_phase.steps.any? { |step| step.name == "alpine-apk-add" }.should be_true

      bq2_builder = Bootstrap::SysrootBuilder.new(seed: Bootstrap::SysrootBuilder::BQ2_SEED_NAME)
      bq2_phase = bq2_builder.build_plan.phases.find(&.name.==("sysroot-from-seed")).not_nil!
      bq2_phase.steps.any? { |step| step.name == "alpine-apk-add" }.should be_false
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
      sysroot_phase = plan.phases.find(&.name.==("sysroot-from-seed")).not_nil!
      llvm_steps = sysroot_phase.steps.select { |step| step.name.starts_with?("llvm-project-stage") }
      llvm_steps.map(&.name).should eq ["llvm-project-stage1", "llvm-project-stage2"]
      llvm_steps.all? { |step| step.strategy == "cmake-project" }.should be_true
      llvm_steps.each do |step|
        step.env["CMAKE_SOURCE_DIR"].should eq "llvm"
      end
      sysroot_phase.steps.any? { |step| step.name == "llvm-project" }.should be_false
    end
  end

  it "skips LLVM runtimes in stage1 when rebuilding the system toolchain" do
    with_temp_workdir do |_dir|
      builder = Bootstrap::SysrootBuilder.new
      plan = builder.build_plan
      sysroot_phase = plan.phases.find(&.name.==("sysroot-from-seed")).not_nil!
      sysroot_stage1 = sysroot_phase.steps.find(&.name.==("llvm-project-stage1")).not_nil!
      sysroot_stage1.configure_flags.any? { |flag| flag.starts_with?("-DLLVM_ENABLE_RUNTIMES=") }.should be_true

      system_phase = plan.phases.find(&.name.==("system-from-sysroot")).not_nil!
      system_stage1 = system_phase.steps.find(&.name.==("llvm-project-stage1")).not_nil!
      system_stage1.configure_flags.any? { |flag| flag.starts_with?("-DLLVM_ENABLE_RUNTIMES=") }.should be_false
      system_stage2 = system_phase.steps.find(&.name.==("llvm-project-stage2")).not_nil!
      system_stage2.configure_flags.any? do |flag|
        flag.starts_with?("-DCMAKE_CXX_FLAGS=") && flag.includes?("-stdlib=libc++")
      end.should be_true
      system_stage2.configure_flags.any? do |flag|
        flag.starts_with?("-DRUNTIMES_CMAKE_ARGS=") &&
          flag.includes?("-DCMAKE_C_FLAGS=") &&
          flag.includes?("-DCMAKE_CXX_FLAGS=") &&
          flag.includes?("--sysroot=/opt/sysroot") &&
          !flag.includes?("/opt/sysroot/include/c++/v1")
      end.should be_true
    end
  end

  it "lists build phase names" do
    with_temp_workdir do |_dir|
      phases = Bootstrap::SysrootBuilder.new.phase_specs.map { |spec| spec.phase.name }
      phases.should eq ["host-setup", "sysroot-from-seed", "rootfs-from-sysroot", "system-from-sysroot", "tools-from-system", "finalize-rootfs"]
    end
  end

  it "sets phase workdirs per namespace" do
    with_temp_workdir do |_dir|
      builder = Bootstrap::SysrootBuilder.new
      host_workdir = builder.host_workdir
      seed_workspace = Bootstrap::SysrootWorkspace.workspace_from(Bootstrap::SysrootWorkspace::Namespace::Seed, host_workdir).to_s
      phases = builder.phase_specs.to_h { |spec| {spec.phase.name, spec} }
      phases["host-setup"].workdir.should be_nil
      phases["sysroot-from-seed"].workdir.should eq seed_workspace
      phases["rootfs-from-sysroot"].workdir.should eq seed_workspace
      bq2_workspace = Bootstrap::SysrootWorkspace.workspace_from(Bootstrap::SysrootWorkspace::Namespace::BQ2, host_workdir).to_s
      phases["system-from-sysroot"].workdir.should eq bq2_workspace
      phases["tools-from-system"].workdir.should eq bq2_workspace
      phases["finalize-rootfs"].workdir.should eq bq2_workspace
    end
  end

  it "sets the system-from-sysroot linker" do
    with_temp_workdir do |_dir|
      builder = Bootstrap::SysrootBuilder.new
      phase = builder.phase_specs.find { |spec| spec.phase.name == "system-from-sysroot" }.not_nil!
      sysroot_prefix = "/#{Bootstrap::SysrootWorkspace::SYSROOT_DIR_NAME}"
      phase.phase.env["LD"].should eq "#{sysroot_prefix}/bin/ld.lld"
    end
  end

  it "sets crystal env for system-from-sysroot" do
    with_temp_workdir do |_dir|
      builder = Bootstrap::SysrootBuilder.new
      phase = builder.phase_specs.find { |spec| spec.phase.name == "system-from-sysroot" }.not_nil!
      env = phase.env_overrides["crystal"]
      sysroot_triple = sysroot_triple_for(Bootstrap::SysrootBuilder::DEFAULT_ARCH)
      env["CRYSTAL_CACHE_DIR"].should eq "/tmp/crystal_cache"
      env["CRYSTAL"].should eq "/opt/sysroot/bin/crystal"
      env["LLVM_CONFIG"].should eq "/usr/bin/llvm-config"
      env["LDFLAGS"].should eq "-L/usr/lib/#{sysroot_triple} -L/usr/lib"
      env["LIBRARY_PATH"].should eq "/usr/lib/#{sysroot_triple}:/usr/lib"
      env["LD_LIBRARY_PATH"].should eq "/usr/lib/#{sysroot_triple}:/usr/lib:/opt/sysroot/lib/#{sysroot_triple}:/opt/sysroot/lib"
    end
  end

  it "sets bootstrap-qcow2 env in system-from-sysroot" do
    with_temp_workdir do |_dir|
      builder = Bootstrap::SysrootBuilder.new
      phase = builder.phase_specs.find { |spec| spec.phase.name == "system-from-sysroot" }.not_nil!
      env = phase.env_overrides["bootstrap-qcow2"]
      sysroot_triple = sysroot_triple_for(Bootstrap::SysrootBuilder::DEFAULT_ARCH)
      cmake_c_flags = "--target=#{sysroot_triple} --rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld -Wno-unused-command-line-argument"
      usr_cxx_flags = "#{cmake_c_flags} -nostdinc++ -isystem /usr/include/c++/v1 -isystem /usr/include/#{sysroot_triple}/c++/v1 -nostdlib++ -stdlib=libc++ -L/usr/lib/#{sysroot_triple} -L/usr/lib -Wl,--start-group -lc++ -lc++abi -lunwind -Wl,--end-group"
      clang_rt_dir = "/usr/lib/clang/#{Bootstrap::SysrootBuilder::DEFAULT_LLVM_VER.split(".").first}/lib/#{sysroot_triple}"
      env["SHARDS_CACHE_PATH"].should eq Bootstrap::SysrootBuilder::SHARDS_CACHE_DIR
      env["LDFLAGS"].should eq "-L#{clang_rt_dir} -L/usr/lib/#{sysroot_triple} -L/usr/lib"
      env["LIBRARY_PATH"].should eq "#{clang_rt_dir}:/usr/lib/#{sysroot_triple}:/usr/lib"
      env["LD_LIBRARY_PATH"].should eq "#{clang_rt_dir}:/usr/lib/#{sysroot_triple}:/usr/lib"
      env["CRYSTAL_OPTS"].should eq "-Dlibressl_version=#{Bootstrap::SysrootBuilder::DEFAULT_LIBRESSL}"
      env["CC"].should eq "/usr/bin/clang #{cmake_c_flags}"
      env["CXX"].should eq "/usr/bin/clang++ #{usr_cxx_flags}"
      env["AR"].should eq "/usr/bin/llvm-ar"
      env["NM"].should eq "/usr/bin/llvm-nm"
      env["RANLIB"].should eq "/usr/bin/llvm-ranlib"
      env["STRIP"].should eq "/usr/bin/llvm-strip"
      env["LD"].should eq "/usr/bin/ld.lld"
      env["PATH"].should eq "/usr/bin:/bin:/usr/sbin:/sbin"
    end
  end

  it "seeds rootfs profile, CA bundle, and final musl loader path" do
    with_temp_workdir do |_dir|
      builder = Bootstrap::SysrootBuilder.new
      sysroot_phase = builder.phase_specs.find { |spec| spec.phase.name == "sysroot-from-seed" }.not_nil!
      sysroot_zlib_env = sysroot_phase.env_overrides["zlib"]
      sysroot_zlib_env["CFLAGS"].should contain("-fPIC")
      rootfs_phase = builder.phase_specs.find { |spec| spec.phase.name == "rootfs-from-sysroot" }.not_nil!
      prepare_step = rootfs_phase.extra_steps.find(&.name.==("prepare-rootfs-1")).not_nil!
      profile = prepare_step.content.not_nil!
      profile.should contain("SSL_CERT_FILE=\"/etc/ssl/certs/ca-certificates.crt\"")
      profile.should contain("LANG=C.UTF-8")
      ca_bundle = rootfs_phase.extra_steps.find(&.name.==("prepare-rootfs-4")).not_nil!.content.not_nil!
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
      builder = StubBuilder.new(seed: Bootstrap::SysrootBuilder::BQ2_SEED_NAME)
      builder.override_packages = [pkg, musl, busybox, linux_headers]
      plan = builder.build_plan
      plan.phases.map(&.name).should eq ["host-setup", "sysroot-from-seed", "rootfs-from-sysroot", "system-from-sysroot", "finalize-rootfs"]
      sysroot_phase = plan.phases.find(&.name.==("sysroot-from-seed")).not_nil!
      sysroot_phase.install_prefix.should eq "/opt/sysroot"
      sysroot_phase.destdir.should be_nil
      sysroot_phase.steps.size.should eq 6
      sysroot_phase.steps.any? { |step| step.name == "seed-resolv-conf" }.should be_true
      sysroot_phase.steps.any? { |step| step.name == "sysroot-libatomic-link-0" }.should be_true
      sysroot_phase.steps.any? { |step| step.name == "sysroot-libatomic-link-1" }.should be_true
      sysroot_phase.steps.any? { |step| step.strategy == "apk-add" }.should be_false
      sysroot_phase.steps.find(&.name.==("pkg")).not_nil!.configure_flags.should eq ["--foo"]

      rootfs_phase = plan.phases.find(&.name.==("rootfs-from-sysroot")).not_nil!
      rootfs_phase.install_prefix.should eq "/usr"
      rootfs_phase.destdir.should eq "/bq2-rootfs"
      rootfs_phase.steps.map(&.name).should eq [
        "musl",
        "busybox",
        "linux-headers",
        "musl-ld-path",
        "prepare-rootfs-0",
        "prepare-rootfs-1",
        "prepare-rootfs-2",
        "prepare-rootfs-3",
        "prepare-rootfs-4",
        "prepare-rootfs-5",
      ]

      finalize_phase = plan.phases.find(&.name.==("finalize-rootfs")).not_nil!
      finalize_phase.destdir.should be_nil
      finalize_phase.steps.map(&.name).should eq ["musl-ld-path-final", "rootfs-tarball"]
      tarball_step = finalize_phase.steps.find(&.name.==("rootfs-tarball")).not_nil!
      tarball_path = tarball_step.install_prefix.not_nil!
      tarball_path.should start_with("/workspace/bq2-rootfs-")
      tarball_path.should end_with(".tar.gz")
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
      plan_path = builder.write_plan.not_nil!
      File.exists?(plan_path).should be_true
      plan = Bootstrap::BuildPlan.parse(File.read(plan_path))
      plan.phases.map(&.name).should eq ["host-setup", "sysroot-from-seed", "rootfs-from-sysroot", "system-from-sysroot", "finalize-rootfs"]
    end
  end
end
