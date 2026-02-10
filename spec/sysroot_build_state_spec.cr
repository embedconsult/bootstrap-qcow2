require "./spec_helper"

describe Bootstrap::SysrootBuildState do
  it "discovers the default workspace when no workspace is provided" do
    with_bq2_workspace do
      state = Bootstrap::SysrootBuildState.new
      state.workspace.namespace.host?.should be_true
      state.plan_path.should eq Path["data/sysroot/seed-rootfs/bq2-rootfs/var/lib/#{Bootstrap::SysrootBuildState::PLAN_FILE}"]
      state.state_path.should eq Path["data/sysroot/seed-rootfs/bq2-rootfs/var/lib/#{Bootstrap::SysrootBuildState::STATE_FILE}"]
    end
  end

  it "loads an on-disk plan when initialized with default workspace discovery" do
    with_bq2_workspace do
      workspace = nil.as(Bootstrap::SysrootWorkspace?)
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

  it "keeps completed steps when overrides content changes" do
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
          steps: [] of Bootstrap::BuildStep,
        ),
      ])
      File.write(plan_path, plan.to_json)
      File.write(overrides_path, %({"phases":{}}))

      state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      state.mark_success("phase-a", "musl")
      state.save

      File.write(overrides_path, %({"phases":{"phase-a":{"steps":{}}}}))

      reloaded = Bootstrap::SysrootBuildState.new(workspace: workspace)
      reloaded.completed?("phase-a", "musl").should be_true
      reloaded.overrides_changed.should be_true
      reloaded.invalidated_at.should be_nil
      reloaded.invalidation_reason.should be_nil
    end
  end

  it "clears completed steps when overrides change and invalidation is enabled" do
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
          steps: [] of Bootstrap::BuildStep,
        ),
      ])
      File.write(plan_path, plan.to_json)
      File.write(overrides_path, %({"phases":{}}))

      state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      state.mark_success("phase-a", "musl")
      state.save

      File.write(overrides_path, %({"phases":{"phase-a":{"steps":{}}}}))

      reloaded = Bootstrap::SysrootBuildState.new(workspace: workspace, invalidate_on_overrides: true)
      reloaded.completed?("phase-a", "musl").should be_false
      reloaded.invalidated_at.should_not be_nil
      reloaded.invalidation_reason.should eq "Overrides changed; cleared completed steps"
    end
  end
end
