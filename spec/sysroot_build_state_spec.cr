require "./spec_helper"

describe Bootstrap::SysrootBuildState do
  it "discovers the default workspace when no workspace is provided" do
    with_bq2_workspace do
      state = Bootstrap::SysrootBuildState.new
      state.workspace.namespace.host?.should be_true
      state.plan_path.to_s.should end_with Path["data/sysroot/seed-rootfs/bq2-rootfs/var/lib/#{Bootstrap::SysrootBuildState::PLAN_FILE}"].to_s
      state.state_path.to_s.should end_with Path["data/sysroot/seed-rootfs/bq2-rootfs/var/lib/#{Bootstrap::SysrootBuildState::STATE_FILE}"].to_s
    end
  end

  it "loads an on-disk plan when initialized with default workspace discovery" do
    with_bq2_workspace do
      workspace = Bootstrap::SysrootWorkspace.new
      plan = Bootstrap::BuildPlan.new([
        Bootstrap::BuildPhase.new(
          name: "phase-default",
          description: "default workspace phase",
          namespace: "host",
          install_prefix: "/opt/sysroot",
          steps: [] of Bootstrap::BuildStep,
        ),
      ])

      FileUtils.mkdir_p(workspace.log_path)
      File.write(workspace.log_path / Bootstrap::SysrootBuildState::PLAN_FILE, plan.to_json)

      state = Bootstrap::SysrootBuildState.new
      state.plan.phases.map(&.name).should eq ["phase-default"]
    end
  end

  it "round-trips JSON and preserves completed step markers" do
    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.create(Path[dir])
      Log.debug { "workspace: #{workspace}" }
      state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      state.mark_success("phase-a", "musl")
      encoded = state.to_json
      decoded = Bootstrap::SysrootBuildState.from_json(encoded)
      decoded.workspace = workspace
      decoded.completed?("phase-a", "musl").should be_true
      decoded.completed?("phase-a", "busybox").should be_false
    end
  end

  it "loads or initializes state and updates metadata" do
    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.create(Path[dir])
      state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      state.plan_path.should eq workspace.log_path / Bootstrap::SysrootBuildState::PLAN_FILE
      state.overrides_path.should eq workspace.log_path / Bootstrap::SysrootBuildState::OVERRIDES_FILE
      state.report_dir.should eq workspace.log_path / Bootstrap::SysrootBuildState::REPORT_DIR_NAME
      state.save
      loaded = Bootstrap::SysrootBuildState.new(workspace: workspace)
      loaded.plan_path.should eq workspace.log_path / Bootstrap::SysrootBuildState::PLAN_FILE
    end
  end

  it "restores progress from an existing state file" do
    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.create(Path[dir])
      state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      state.mark_success("phase-a", "musl")
      state.save

      reloaded = Bootstrap::SysrootBuildState.new(workspace: workspace)
      reloaded.completed?("phase-a", "musl").should be_true
      reloaded.completed?("phase-a", "busybox").should be_false
    end
  end

  it "applies on-disk overrides without rewriting them" do
    with_tempdir do |dir|
      workspace = Bootstrap::SysrootWorkspace.create(Path[dir])
      plan_path = workspace.log_path / Bootstrap::SysrootBuildState::PLAN_FILE
      overrides_path = workspace.log_path / Bootstrap::SysrootBuildState::OVERRIDES_FILE

      FileUtils.mkdir_p(plan_path.parent)
      plan = Bootstrap::BuildPlan.new([
        Bootstrap::BuildPhase.new(
          name: "phase-a",
          description: "phase a",
          namespace: "host",
          install_prefix: "/opt/sysroot",
          steps: [Bootstrap::BuildStep.new(name: "pkg", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)],
        ),
      ])
      overrides_json = %({"phases":{"phase-a":{"steps":{"pkg":{"configure_flags_add":["--with-foo"]}}}}})
      File.write(plan_path, plan.to_json)
      File.write(overrides_path, overrides_json)

      state = Bootstrap::SysrootBuildState.new(workspace: workspace)

      state.plan.phases.first.steps.first.configure_flags.should eq ["--with-foo"]
      state.overrides_digest.should eq Bootstrap::SysrootBuildState.digest_for?(overrides_path)
      File.read(overrides_path).should eq overrides_json
    end
  end
end
