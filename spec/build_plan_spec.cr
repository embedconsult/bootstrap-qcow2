require "./spec_helper"
require "../src/build_plan"

describe Bootstrap::BuildPlan do
  it "round-trips JSON with phases and steps" do
    step = Bootstrap::BuildStep.new(
      name: "musl",
      strategy: "autotools",
      workdir: "/workspace/musl",
      configure_flags: ["--foo"],
      patches: ["fix.patch"],
      install_prefix: "/usr",
      destdir: "/workspace/rootfs",
      env: {"CC" => "clang"} of String => String,
      build_dir: "/workspace/musl-build",
      clean_build: true,
    )

    phase = Bootstrap::BuildPhase.new(
      name: "rootfs-from-sysroot",
      description: "test phase",
      workspace: "/workspace",
      environment: "sysroot-toolchain",
      install_prefix: "/usr",
      destdir: "/workspace/rootfs",
      env: {"PATH" => "/opt/sysroot/bin:/usr/bin"} of String => String,
      steps: [step],
    )

    plan = Bootstrap::BuildPlan.new([phase])
    parsed = Bootstrap::BuildPlan.from_json(plan.to_json)

    parsed.format_version.should eq 1
    parsed.phases.size.should eq 1
    parsed.phases.first.name.should eq "rootfs-from-sysroot"
    parsed.phases.first.destdir.should eq "/workspace/rootfs"
    parsed.phases.first.steps.first.install_prefix.should eq "/usr"
    parsed.phases.first.steps.first.env["CC"].should eq "clang"
    parsed.phases.first.steps.first.build_dir.should eq "/workspace/musl-build"
    parsed.phases.first.steps.first.clean_build.should eq true
  end
end
