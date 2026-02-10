require "./spec_helper"
require "json"
require "file_utils"
require "random/secure"

class RecordingRunner
  getter calls = [] of NamedTuple(phase: String, name: String, workdir: String?, strategy: String, configure_flags: Array(String), env: Hash(String, String))
  property status : Bool = true
  property exit_code : Int32 = 0

  def initialize(@status : Bool = true, @exit_code : Int32 = 0)
  end

  def run(phase : Bootstrap::BuildPhase, step : Bootstrap::BuildStep)
    @calls << {phase: phase.name, name: step.name, workdir: step.workdir, strategy: step.strategy, configure_flags: step.configure_flags, env: step.env}
    raise "Command failed (#{@exit_code})" unless @status
    FakeStatus.new(@status, @exit_code)
  end

  struct FakeStatus
    def initialize(@success : Bool, @exit_code : Int32)
    end

    def success? : Bool
      @success
    end

    def exit_code : Int32
      @exit_code
    end
  end
end

private def run_plan_from_state_plan(plan : Bootstrap::BuildPlan,
                                     runner,
                                     phase : String? = nil,
                                     packages : Array(String) = [] of String,
                                     report : Bool = true,
                                     report_dir : String? = nil,
                                     dry_run : Bool = false,
                                     dry_run_io : IO? = nil,
                                     resume : Bool = true,
                                     workspace : Bootstrap::SysrootWorkspace? = nil) : Nil
  if workspace
    state = Bootstrap::SysrootBuildState.new(workspace: workspace)
    state.plan = plan
    Bootstrap::SysrootRunner.run_plan(
      state,
      runner,
      phase: phase,
      packages: packages,
      report: report,
      report_dir: report_dir,
      dry_run: dry_run,
      dry_run_io: dry_run_io,
      resume: resume,
      workspace: workspace
    )
    return
  end

  with_tempdir do |dir|
    temp_workspace = Bootstrap::SysrootWorkspace.create(Path[dir])
    state = Bootstrap::SysrootBuildState.new(workspace: temp_workspace)
    state.plan = plan
    Bootstrap::SysrootRunner.run_plan(
      state,
      runner,
      phase: phase,
      packages: packages,
      report: report,
      report_dir: report_dir,
      dry_run: dry_run,
      dry_run_io: dry_run_io,
      resume: resume,
      workspace: temp_workspace
    )
  end
end

describe Bootstrap::SysrootRunner do
  it "runs steps with a custom runner" do
    phase = Bootstrap::BuildPhase.new(
      name: "phase-a",
      description: "test phase",
      namespace: "host",
      install_prefix: "/opt/sysroot",
      destdir: nil,
      env: {} of String => String,
      steps: [] of Bootstrap::BuildStep,
    )
    steps = [
      Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String),
      Bootstrap::BuildStep.new(name: "b", strategy: "cmake", workdir: "/var", configure_flags: [] of String, patches: [] of String),
    ]

    runner = RecordingRunner.new
    Bootstrap::SysrootRunner.run_steps(phase, steps, runner, report_dir: nil)

    runner.calls.size.should eq 2
    runner.calls.first[:workdir].should eq "/tmp"
    runner.calls.last[:strategy].should eq "cmake"
  end

  it "raises when a command fails" do
    phase = Bootstrap::BuildPhase.new(
      name: "phase-fail",
      description: "test phase",
      namespace: "host",
      install_prefix: "/opt/sysroot",
      steps: [] of Bootstrap::BuildStep,
    )
    steps = [Bootstrap::BuildStep.new(name: "fail", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    runner = RecordingRunner.new(false, 2)

    expect_raises(Exception) do
      Bootstrap::SysrootRunner.run_steps(phase, steps, runner, report_dir: nil)
    end
  end

  it "loads a plan file and executes all phases by default" do
    phase_a_steps = [Bootstrap::BuildStep.new(name: "file-a", strategy: "autotools", workdir: "/opt", configure_flags: [] of String, patches: [] of String)]
    phase_b_steps = [Bootstrap::BuildStep.new(name: "file-b", strategy: "autotools", workdir: "/var", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "phase-a",
        description: "phase a",
        namespace: "host",
        install_prefix: "/opt/sysroot",
        steps: phase_a_steps,
      ),
      Bootstrap::BuildPhase.new(
        name: "phase-b",
        description: "phase b",
        namespace: "host",
        install_prefix: "/usr",
        destdir: "/tmp/rootfs",
        steps: phase_b_steps,
      ),
    ])
    runner = RecordingRunner.new

    with_tempdir do |dir|
      inner_rootfs = dir / "rootfs"
      var_lib = inner_rootfs / "var/lib"
      FileUtils.mkdir_p(var_lib)
      plan_path = var_lib / "sysroot-build-plan.json"
      File.write(plan_path, plan.to_json)

      run_plan_from_state_plan(plan, runner)
      runner.calls.size.should eq 2
      runner.calls.map(&.[:name]).should eq ["file-a", "file-b"]
    end
  end

  it "runs all phases when requested" do
    steps = [Bootstrap::BuildStep.new(name: "step", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", steps: steps),
      Bootstrap::BuildPhase.new(name: "two", description: "b", namespace: "host", install_prefix: "/usr", destdir: "/tmp/rootfs", steps: steps),
    ])

    runner = RecordingRunner.new
    run_plan_from_state_plan(plan, runner, phase: "all")
    runner.calls.size.should eq 2
    runner.calls.map(&.[:phase]).should eq ["one", "two"]
  end

  it "runs only the selected phase when requested" do
    steps = [Bootstrap::BuildStep.new(name: "step", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", steps: steps),
      Bootstrap::BuildPhase.new(name: "two", description: "b", namespace: "host", install_prefix: "/usr", destdir: "/tmp/rootfs", steps: steps),
    ])

    runner = RecordingRunner.new
    run_plan_from_state_plan(plan, runner, phase: "two")
    runner.calls.size.should eq 1
    runner.calls.first[:phase].should eq "two"
  end

  it "defaults to all phases when not running inside the rootfs" do
    steps = [Bootstrap::BuildStep.new(name: "step", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", steps: steps),
      Bootstrap::BuildPhase.new(name: "two", description: "b", namespace: "host", install_prefix: "/usr", steps: steps),
    ])

    previous = ENV["BQ2_ROOTFS_MARKER"]?
    ENV.delete("BQ2_ROOTFS_MARKER")
    begin
      runner = RecordingRunner.new
      run_plan_from_state_plan(plan, runner)
      runner.calls.size.should eq 2
      runner.calls.map(&.[:phase]).should eq ["one", "two"]
    ensure
      if previous
        ENV["BQ2_ROOTFS_MARKER"] = previous
      else
        ENV.delete("BQ2_ROOTFS_MARKER")
      end
    end
  end

  it "defaults to all rootfs phases when running inside the rootfs" do
    steps = [Bootstrap::BuildStep.new(name: "step", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "two", description: "b", namespace: "host", install_prefix: "/usr", steps: steps),
      Bootstrap::BuildPhase.new(name: "three", description: "c", namespace: "host", install_prefix: "/usr", steps: steps),
    ])

    with_tempdir do |dir|
      marker_path = dir / ".bq2-rootfs"
      File.write(marker_path, "bq2-rootfs\n")
      previous = ENV["BQ2_ROOTFS_MARKER"]?
      ENV["BQ2_ROOTFS_MARKER"] = marker_path.to_s
      begin
        runner = RecordingRunner.new
        run_plan_from_state_plan(plan, runner)
        runner.calls.size.should eq 2
        runner.calls.map(&.[:phase]).should eq ["two", "three"]
      ensure
        if previous
          ENV["BQ2_ROOTFS_MARKER"] = previous
        else
          ENV.delete("BQ2_ROOTFS_MARKER")
        end
      end
    end
  end

  restrictions = Bootstrap::SysrootNamespace.collect_restrictions
  if restrictions.empty?
    it "allows rootfs phases to run outside the rootfs when requested" do
      phase = Bootstrap::BuildPhase.new(
        name: "rootfs-phase",
        description: "rootfs phase",
        namespace: "bq2",
        install_prefix: "/usr",
        steps: [] of Bootstrap::BuildStep,
      )
      runner = RecordingRunner.new
      previous = ENV["BQ2_ROOTFS"]?
      ENV["BQ2_ROOTFS"] = "0"

      begin
        expect_raises(Exception, /Refusing to run/) do
          Bootstrap::SysrootRunner.run_phase(phase, runner, report_dir: nil)
        end
      ensure
        if previous
          ENV["BQ2_ROOTFS"] = previous
        else
          ENV.delete("BQ2_ROOTFS")
        end
      end

      Bootstrap::SysrootRunner.run_phase(phase, runner, report_dir: nil, allow_outside_rootfs: true).should be_nil
    end
  else
    reason = restrictions.join("; ")
    pending "allows rootfs phases to run outside the rootfs when requested (#{reason})" do
    end
  end

  it "raises when a requested phase does not exist" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", steps: [] of Bootstrap::BuildStep),
    ])
    runner = RecordingRunner.new

    expect_raises(Exception, /Unknown build phase/) do
      run_plan_from_state_plan(plan, runner, phase: "missing")
    end
  end

  it "prepares a destdir root directory" do
    destdir = Path[Dir.tempdir] / "bq2-rootfs-spec-#{Random::Secure.hex(8)}"
    begin
      plan = Bootstrap::BuildPlan.new([
        Bootstrap::BuildPhase.new(
          name: "rootfs",
          description: "rootfs phase",
          namespace: "host",
          install_prefix: "/usr",
          destdir: destdir.to_s,
          steps: [
            Bootstrap::BuildStep.new(
              name: "usr-bin-placeholder",
              strategy: "write-file",
              workdir: nil,
              install_prefix: "/usr/bin/.keep",
              content: "placeholder\n",
              configure_flags: [] of String,
              patches: [] of String,
            ),
            Bootstrap::BuildStep.new(
              name: "var-lib-placeholder",
              strategy: "write-file",
              workdir: nil,
              install_prefix: "/var/lib/.keep",
              content: "placeholder\n",
              configure_flags: [] of String,
              patches: [] of String,
            ),
          ],
        ),
      ])

      workspace = Bootstrap::SysrootWorkspace.create(host_workdir: destdir / "work")
      runner = Bootstrap::StepRunner.new(workspace: workspace)
      run_plan_from_state_plan(plan, runner, phase: "all")

      File.directory?(destdir).should be_true
    ensure
      FileUtils.rm_rf(destdir)
    end
  end

  it "writes a failure report when a step fails" do
    report_dir = Path[Dir.tempdir] / "bq2-report-spec-#{Random::Secure.hex(8)}"
    begin
      phase = Bootstrap::BuildPhase.new(
        name: "phase-fail",
        description: "test phase",
        namespace: "host",
        install_prefix: "/opt/sysroot",
        steps: [] of Bootstrap::BuildStep,
      )
      steps = [Bootstrap::BuildStep.new(name: "fail", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
      runner = RecordingRunner.new(false, 23)

      expect_raises(Exception) do
        Bootstrap::SysrootRunner.run_steps(phase, steps, runner, report_dir: report_dir.to_s)
      end

      Dir.glob("#{report_dir}/*.json").size.should be > 0
    ensure
      FileUtils.rm_rf(report_dir)
    end
  end

  it "filters packages when requested" do
    steps_a = [Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/a", configure_flags: [] of String, patches: [] of String)]
    steps_b = [Bootstrap::BuildStep.new(name: "b", strategy: "autotools", workdir: "/b", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", steps: steps_a),
      Bootstrap::BuildPhase.new(name: "two", description: "b", namespace: "host", install_prefix: "/usr", destdir: "/tmp/rootfs", steps: steps_b),
    ])

    runner = RecordingRunner.new
    run_plan_from_state_plan(plan, runner, phase: "all", packages: ["b"], report_dir: nil)
    runner.calls.size.should eq 1
    runner.calls.first[:phase].should eq "two"
    runner.calls.first[:name].should eq "b"
  end

  it "raises when any requested package filter is missing" do
    steps = [Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/a", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", steps: steps),
    ])

    runner = RecordingRunner.new
    expect_raises(Exception, /not found/) do
      run_plan_from_state_plan(plan, runner, packages: ["a", "missing"], report_dir: nil)
    end
  end

  it "applies overrides from a file when requested" do
    steps = [Bootstrap::BuildStep.new(name: "pkg", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", steps: steps),
    ])

    overrides = {
      "phases" => {
        "one" => {
          "steps" => {
            "pkg" => {
              "configure_flags_add" => ["--with-foo"],
              "env"                 => {"CC" => "clang"},
            },
          },
        },
      },
    }.to_json
    runner = RecordingRunner.new

    with_tempdir do |dir|
      inner_rootfs = dir / "rootfs"
      var_lib = inner_rootfs / "var/lib"
      FileUtils.mkdir_p(var_lib)
      plan_path = var_lib / "sysroot-build-plan.json"
      File.write(plan_path, plan.to_json)
      overrides_path = dir / "overrides.json"
      File.write(overrides_path, overrides)

      overrides = Bootstrap::BuildPlanOverrides.from_json(File.read(overrides_path))
      plan = overrides.apply(plan)
      run_plan_from_state_plan(plan, runner, report_dir: nil)
      runner.calls.size.should eq 1
      runner.calls.first[:configure_flags].should eq ["--with-foo"]
      runner.calls.first[:env]["CC"].should eq "clang"
    end
  end

  it "supports dry-run without executing steps" do
    steps = [Bootstrap::BuildStep.new(name: "pkg", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", namespace: "host", install_prefix: "/opt/sysroot", steps: steps),
    ])

    runner = RecordingRunner.new
    output = IO::Memory.new
    run_plan_from_state_plan(plan, runner, dry_run: true, dry_run_io: output, report_dir: nil)
    runner.calls.should be_empty
  end

  it "skips completed steps when a state file is present" do
    with_tempdir do |dir|
      plan = Bootstrap::BuildPlan.new([
        Bootstrap::BuildPhase.new(
          name: "one",
          description: "a",
          namespace: "host",
          install_prefix: "/opt/sysroot",
          steps: [
            Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/a", configure_flags: [] of String, patches: [] of String),
            Bootstrap::BuildStep.new(name: "b", strategy: "autotools", workdir: "/b", configure_flags: [] of String, patches: [] of String),
          ],
        ),
      ])

      plan_file = File.tempfile("plan")
      plan_file.print(plan.to_json)
      plan_file.flush
      plan_path = plan_file.path
      plan_file.close

      workspace = Bootstrap::SysrootWorkspace.create(Path[dir])
      state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      state.mark_success("one", "a")
      state.save

      runner = RecordingRunner.new
      state.plan = Bootstrap::BuildPlan.parse(File.read(plan_path))
      Bootstrap::SysrootRunner.run_plan(state, runner, report_dir: nil)
      runner.calls.map { |call| call[:name] }.should eq ["b"]

      updated = Bootstrap::SysrootBuildState.new(workspace: workspace)
      updated.completed?("one", "a").should be_true
      updated.completed?("one", "b").should be_true
    end
  end

  it "honors resume=false by running completed steps when a state file is present" do
    with_tempdir do |dir|
      plan = Bootstrap::BuildPlan.new([
        Bootstrap::BuildPhase.new(
          name: "one",
          description: "a",
          namespace: "host",
          install_prefix: "/opt/sysroot",
          steps: [
            Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/a", configure_flags: [] of String, patches: [] of String),
            Bootstrap::BuildStep.new(name: "b", strategy: "autotools", workdir: "/b", configure_flags: [] of String, patches: [] of String),
          ],
        ),
      ])

      plan_file = File.tempfile("plan")
      plan_file.print(plan.to_json)
      plan_file.flush
      plan_path = plan_file.path
      plan_file.close

      workspace = Bootstrap::SysrootWorkspace.create(Path[dir])
      state = Bootstrap::SysrootBuildState.new(workspace: workspace)
      state.mark_success("one", "a")
      state.save

      runner = RecordingRunner.new
      state.plan = Bootstrap::BuildPlan.parse(File.read(plan_path))
      Bootstrap::SysrootRunner.run_plan(state, runner, report_dir: nil, resume: false)
      runner.calls.map { |call| call[:name] }.should eq ["a", "b"]
    end
  end
end
