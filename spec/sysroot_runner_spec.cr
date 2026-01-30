require "./spec_helper"
require "json"
require "file_utils"
require "random/secure"

class RecordingRunner
  getter calls = [] of NamedTuple(phase: String, name: String, workdir: String, strategy: String, configure_flags: Array(String), env: Hash(String, String))
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

describe Bootstrap::SysrootRunner do
  it "runs steps with a custom runner" do
    phase = Bootstrap::BuildPhase.new(
      name: "phase-a",
      description: "test phase",
      workspace: "/workspace",
      environment: "test",
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
    Bootstrap::SysrootRunner.run_steps(phase, steps, runner)

    runner.calls.size.should eq 2
    runner.calls.first[:workdir].should eq "/tmp"
    runner.calls.last[:strategy].should eq "cmake"
  end

  it "raises when a command fails" do
    phase = Bootstrap::BuildPhase.new(
      name: "phase-fail",
      description: "test phase",
      workspace: "/workspace",
      environment: "test",
      install_prefix: "/opt/sysroot",
      steps: [] of Bootstrap::BuildStep,
    )
    steps = [Bootstrap::BuildStep.new(name: "fail", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    runner = RecordingRunner.new(false, 2)

    expect_raises(Exception) do
      Bootstrap::SysrootRunner.run_steps(phase, steps, runner, report_dir: nil)
    end
  end

  it "loads a plan file and executes only the default phase" do
    phase_a_steps = [Bootstrap::BuildStep.new(name: "file-a", strategy: "autotools", workdir: "/opt", configure_flags: [] of String, patches: [] of String)]
    phase_b_steps = [Bootstrap::BuildStep.new(name: "file-b", strategy: "autotools", workdir: "/var", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "phase-a",
        description: "phase a",
        workspace: "/workspace",
        environment: "test",
        install_prefix: "/opt/sysroot",
        steps: phase_a_steps,
      ),
      Bootstrap::BuildPhase.new(
        name: "phase-b",
        description: "phase b",
        workspace: "/workspace",
        environment: "test",
        install_prefix: "/usr",
        destdir: "/tmp/rootfs",
        steps: phase_b_steps,
      ),
    ])
    runner = RecordingRunner.new

    plan_file = File.tempfile("plan")
    plan_file.print(plan.to_json)
    plan_file.flush
    plan_path = plan_file.path
    plan_file.close

    Bootstrap::SysrootRunner.run_plan(plan_path, runner)
    runner.calls.size.should eq 1
    runner.calls.first[:workdir].should eq "/opt"
    runner.calls.first[:name].should eq "file-a"
  end

  it "runs all phases when requested" do
    steps = [Bootstrap::BuildStep.new(name: "step", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", workspace: "/workspace", environment: "test", install_prefix: "/opt/sysroot", steps: steps),
      Bootstrap::BuildPhase.new(name: "two", description: "b", workspace: "/workspace", environment: "test", install_prefix: "/usr", destdir: "/tmp/rootfs", steps: steps),
    ])

    runner = RecordingRunner.new
    Bootstrap::SysrootRunner.run_plan(plan, runner, phase: "all")
    runner.calls.size.should eq 2
    runner.calls.map(&.[:phase]).should eq ["one", "two"]
  end

  it "runs only the selected phase when requested" do
    steps = [Bootstrap::BuildStep.new(name: "step", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", workspace: "/workspace", environment: "test", install_prefix: "/opt/sysroot", steps: steps),
      Bootstrap::BuildPhase.new(name: "two", description: "b", workspace: "/workspace", environment: "test", install_prefix: "/usr", destdir: "/tmp/rootfs", steps: steps),
    ])

    runner = RecordingRunner.new
    Bootstrap::SysrootRunner.run_plan(plan, runner, phase: "two")
    runner.calls.size.should eq 1
    runner.calls.first[:phase].should eq "two"
  end

  it "defaults to the first phase when not running inside the rootfs" do
    steps = [Bootstrap::BuildStep.new(name: "step", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", workspace: "/workspace", environment: "alpine-seed", install_prefix: "/opt/sysroot", steps: steps),
      Bootstrap::BuildPhase.new(name: "two", description: "b", workspace: "/workspace", environment: "rootfs-system", install_prefix: "/usr", steps: steps),
    ])

    previous = ENV["BQ2_ROOTFS_MARKER"]?
    ENV.delete("BQ2_ROOTFS_MARKER")
    begin
      runner = RecordingRunner.new
      Bootstrap::SysrootRunner.run_plan(plan, runner)
      runner.calls.size.should eq 1
      runner.calls.first[:phase].should eq "one"
    ensure
      if previous
        ENV["BQ2_ROOTFS_MARKER"] = previous
      else
        ENV.delete("BQ2_ROOTFS_MARKER")
      end
    end
  end

  it "defaults to the first rootfs phase when running inside the rootfs" do
    steps = [Bootstrap::BuildStep.new(name: "step", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", workspace: "/workspace", environment: "alpine-seed", install_prefix: "/opt/sysroot", steps: steps),
      Bootstrap::BuildPhase.new(name: "two", description: "b", workspace: "/workspace", environment: "rootfs-system", install_prefix: "/usr", steps: steps),
    ])

    with_tempdir do |dir|
      marker_path = dir / ".bq2-rootfs"
      File.write(marker_path, "bq2-rootfs\n")
      previous = ENV["BQ2_ROOTFS_MARKER"]?
      ENV["BQ2_ROOTFS_MARKER"] = marker_path.to_s
      begin
        runner = RecordingRunner.new
        Bootstrap::SysrootRunner.run_plan(plan, runner)
        runner.calls.size.should eq 1
        runner.calls.first[:phase].should eq "two"
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
        workspace: "/workspace",
        environment: "rootfs-system",
        install_prefix: "/usr",
        steps: [] of Bootstrap::BuildStep,
      )
      runner = RecordingRunner.new
      previous = ENV["BQ2_ROOTFS"]?
      ENV["BQ2_ROOTFS"] = "0"

      begin
        Bootstrap::SysrootRunner.run_phase(phase, runner, report_dir: nil)
        raise "Expected refusal when running outside the rootfs"
      rescue ex
        ex.message.should match(/Refusing to run/)
      ensure
        if previous
          ENV["BQ2_ROOTFS"] = previous
        else
          ENV.delete("BQ2_ROOTFS")
        end
      end

      Bootstrap::SysrootRunner.run_phase(phase, runner, report_dir: nil, allow_outside_rootfs: true)
    end
  else
    reason = restrictions.join("; ")
    pending "allows rootfs phases to run outside the rootfs when requested (#{reason})" do
    end
  end

  it "raises when a requested phase does not exist" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", workspace: "/workspace", environment: "test", install_prefix: "/opt/sysroot", steps: [] of Bootstrap::BuildStep),
    ])
    runner = RecordingRunner.new

    expect_raises(Exception, /Unknown build phase/) do
      Bootstrap::SysrootRunner.run_plan(plan, runner, phase: "missing")
    end
  end

  it "prepares a destdir rootfs skeleton" do
    destdir = Path[Dir.tempdir] / "bq2-rootfs-spec-#{Random::Secure.hex(8)}"
    begin
      plan = Bootstrap::BuildPlan.new([
        Bootstrap::BuildPhase.new(
          name: "rootfs",
          description: "rootfs phase",
          workspace: "/workspace",
          environment: "test",
          install_prefix: "/usr",
          destdir: destdir.to_s,
          steps: [] of Bootstrap::BuildStep,
        ),
      ])

      runner = RecordingRunner.new
      Bootstrap::SysrootRunner.run_plan(plan, runner, phase: "all")

      File.directory?(destdir / "usr/bin").should be_true
      File.directory?(destdir / "var/lib").should be_true
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
        workspace: "/workspace",
        environment: "test",
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
      Bootstrap::BuildPhase.new(name: "one", description: "a", workspace: "/workspace", environment: "test", install_prefix: "/opt/sysroot", steps: steps_a),
      Bootstrap::BuildPhase.new(name: "two", description: "b", workspace: "/workspace", environment: "test", install_prefix: "/usr", destdir: "/tmp/rootfs", steps: steps_b),
    ])

    runner = RecordingRunner.new
    Bootstrap::SysrootRunner.run_plan(plan, runner, phase: "all", packages: ["b"], report_dir: nil)
    runner.calls.size.should eq 1
    runner.calls.first[:phase].should eq "two"
    runner.calls.first[:name].should eq "b"
  end

  it "raises when any requested package filter is missing" do
    steps = [Bootstrap::BuildStep.new(name: "a", strategy: "autotools", workdir: "/a", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", workspace: "/workspace", environment: "test", install_prefix: "/opt/sysroot", steps: steps),
    ])

    runner = RecordingRunner.new
    expect_raises(Exception, /not found/) do
      Bootstrap::SysrootRunner.run_plan(plan, runner, packages: ["a", "missing"], report_dir: nil)
    end
  end

  it "applies overrides from a file when requested" do
    steps = [Bootstrap::BuildStep.new(name: "pkg", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", workspace: "/workspace", environment: "test", install_prefix: "/opt/sysroot", steps: steps),
    ])

    plan_file = File.tempfile("plan")
    plan_file.print(plan.to_json)
    plan_file.flush
    plan_path = plan_file.path
    plan_file.close

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
    overrides_file = File.tempfile("overrides")
    overrides_file.print(overrides)
    overrides_file.flush
    overrides_path = overrides_file.path
    overrides_file.close

    runner = RecordingRunner.new
    Bootstrap::SysrootRunner.run_plan(plan_path, runner, overrides_path: overrides_path, report_dir: nil)
    runner.calls.size.should eq 1
    runner.calls.first[:configure_flags].should eq ["--with-foo"]
    runner.calls.first[:env]["CC"].should eq "clang"
  end

  it "supports dry-run without executing steps" do
    steps = [Bootstrap::BuildStep.new(name: "pkg", strategy: "autotools", workdir: "/tmp", configure_flags: [] of String, patches: [] of String)]
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(name: "one", description: "a", workspace: "/workspace", environment: "test", install_prefix: "/opt/sysroot", steps: steps),
    ])

    runner = RecordingRunner.new
    Bootstrap::SysrootRunner.run_plan(plan, runner, dry_run: true, report_dir: nil)
    runner.calls.should be_empty
  end

  it "skips completed steps when a state file is present" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "a",
        workspace: "/workspace",
        environment: "test",
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

    state_path : Path? = nil
    state_path = Path[File.tempname("bq2-state").not_nil!]
    File.delete?(state_path.to_s)
    workspace = Bootstrap::SysrootWorkspace.from_inner_rootfs(Path["/"])
    state = Bootstrap::SysrootBuildState.load_or_init(
      workspace,
      state_path
    )
    state.mark_success("one", "a")
    state.save(state_path)

    runner = RecordingRunner.new
    Bootstrap::SysrootRunner.run_plan(plan_path, runner, report_dir: nil, state_path: state_path.to_s, overrides_path: nil)
    runner.calls.map { |call| call[:name] }.should eq ["b"]

    updated = Bootstrap::SysrootBuildState.load(workspace, state_path)
    updated.completed?("one", "a").should be_true
    updated.completed?("one", "b").should be_true
  ensure
    File.delete?(state_path.to_s) if state_path
  end

  it "honors resume=false by running completed steps when a state file is present" do
    plan = Bootstrap::BuildPlan.new([
      Bootstrap::BuildPhase.new(
        name: "one",
        description: "a",
        workspace: "/workspace",
        environment: "test",
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

    state_path : Path? = nil
    state_path = Path[File.tempname("bq2-state").not_nil!]
    File.delete?(state_path.to_s)
    workspace = Bootstrap::SysrootWorkspace.from_inner_rootfs(Path["/"])
    state = Bootstrap::SysrootBuildState.load_or_init(
      workspace,
      state_path
    )
    state.mark_success("one", "a")
    state.save(state_path)

    runner = RecordingRunner.new
    Bootstrap::SysrootRunner.run_plan(plan_path, runner, report_dir: nil, state_path: state_path.to_s, resume: false, overrides_path: nil)
    runner.calls.map { |call| call[:name] }.should eq ["a", "b"]
  ensure
    File.delete?(state_path.to_s) if state_path
  end
end
