require "./spec_helper"

describe Bootstrap::SysrootWorkspace::Namespace do
  describe "#label" do
    it "returns lowercase labels" do
      Bootstrap::SysrootWorkspace::Namespace::Host.label.should eq("host")
      Bootstrap::SysrootWorkspace::Namespace::Seed.label.should eq("seed")
      Bootstrap::SysrootWorkspace::Namespace::BQ2.label.should eq("bq2")
    end
  end
end

def prepare_host_layout(host_workdir : Path)
  bq2_rootfs = host_workdir /
               Path["#{Bootstrap::SysrootWorkspace::SEED_DIR_NAME}/#{Bootstrap::SysrootWorkspace::BQ2_DIR_NAME}"]
  FileUtils.mkdir_p(bq2_rootfs)
  marker = bq2_rootfs / Path[Bootstrap::SysrootWorkspace::ROOTFS_MARKER_NAME]
  File.write(marker, "bq2-rootfs\n")
end

describe Bootstrap::SysrootWorkspace do
  describe ".seed_rootfs_from" do
    it "resolves namespace specific rootfs paths" do
      host_workdir = Path["/tmp/host-root"]
      Bootstrap::SysrootWorkspace.seed_rootfs_from(Bootstrap::SysrootWorkspace::Namespace::Host, host_workdir).should eq(
        host_workdir / Path[Bootstrap::SysrootWorkspace::SEED_DIR_NAME]
      )
      Bootstrap::SysrootWorkspace.seed_rootfs_from(Bootstrap::SysrootWorkspace::Namespace::Seed).should eq(Path["/"])
      Bootstrap::SysrootWorkspace.seed_rootfs_from(Bootstrap::SysrootWorkspace::Namespace::BQ2).should be_nil
    end
  end

  describe ".sysroot_from" do
    it "builds sysroot paths when a seed rootfs exists" do
      host_workdir = Path["/tmp/host-root"]
      Bootstrap::SysrootWorkspace.sysroot_from(Bootstrap::SysrootWorkspace::Namespace::Host, host_workdir).should eq(
        host_workdir /
        Path["#{Bootstrap::SysrootWorkspace::SEED_DIR_NAME}/#{Bootstrap::SysrootWorkspace::SYSROOT_DIR_NAME}"]
      )
      Bootstrap::SysrootWorkspace.sysroot_from(Bootstrap::SysrootWorkspace::Namespace::Seed).should eq(
        Path["/#{Bootstrap::SysrootWorkspace::SYSROOT_DIR_NAME}"]
      )
      Bootstrap::SysrootWorkspace.sysroot_from(Bootstrap::SysrootWorkspace::Namespace::BQ2).should be_nil
    end
  end

  describe ".bq2_rootfs_from" do
    it "maps namespace to bq2 rootfs path" do
      host_workdir = Path["/tmp/host-root"]
      Bootstrap::SysrootWorkspace.bq2_rootfs_from(Bootstrap::SysrootWorkspace::Namespace::Host, host_workdir).should eq(
        host_workdir /
        Path["#{Bootstrap::SysrootWorkspace::SEED_DIR_NAME}/#{Bootstrap::SysrootWorkspace::BQ2_DIR_NAME}"]
      )
      Bootstrap::SysrootWorkspace.bq2_rootfs_from(Bootstrap::SysrootWorkspace::Namespace::Seed).should eq(
        Path["/#{Bootstrap::SysrootWorkspace::BQ2_DIR_NAME}"]
      )
      Bootstrap::SysrootWorkspace.bq2_rootfs_from(Bootstrap::SysrootWorkspace::Namespace::BQ2).should eq(Path["/"])
    end
  end

  describe ".workspace_from" do
    it "returns the namespace specific workspace path" do
      host_workdir = Path["/tmp/host-root"]
      Bootstrap::SysrootWorkspace.workspace_from(Bootstrap::SysrootWorkspace::Namespace::Host, host_workdir).should eq(
        host_workdir /
        Path["#{Bootstrap::SysrootWorkspace::SEED_DIR_NAME}/#{Bootstrap::SysrootWorkspace::BQ2_DIR_NAME}/#{Bootstrap::SysrootWorkspace::WORKSPACE_DIR_NAME}"]
      )
      Bootstrap::SysrootWorkspace.workspace_from(Bootstrap::SysrootWorkspace::Namespace::Seed).should eq(
        Path["/#{Bootstrap::SysrootWorkspace::BQ2_DIR_NAME}/#{Bootstrap::SysrootWorkspace::WORKSPACE_DIR_NAME}"]
      )
      Bootstrap::SysrootWorkspace.workspace_from(Bootstrap::SysrootWorkspace::Namespace::BQ2).should eq(
        Path["/#{Bootstrap::SysrootWorkspace::WORKSPACE_DIR_NAME}"]
      )
    end
  end

  describe ".create" do
    it "creates marker and workspace directories" do
      with_tempdir do |tmpdir|
        host_workdir = tmpdir / "host-workdir"
        workspace = Bootstrap::SysrootWorkspace.create(host_workdir: host_workdir)

        workspace.namespace.should eq(Bootstrap::SysrootWorkspace::Namespace::Host)
        File.exists?(workspace.marker_path).should be_true
        Dir.exists?(workspace.workspace_path).should be_true
        Dir.exists?(workspace.log_path).should be_true
        Dir.exists?(workspace.sysroot_path.not_nil!).should be_true
      end
    end
  end

  describe "#initialize" do
    it "initializes host namespace paths from explicit host_workdir" do
      with_tempdir do |tmpdir|
        host_workdir = tmpdir / "host-workdir"
        prepare_host_layout(host_workdir)

        workspace = Bootstrap::SysrootWorkspace.new(host_workdir: host_workdir)
        workspace.namespace.should eq(Bootstrap::SysrootWorkspace::Namespace::Host)
        workspace.seed_rootfs_path.should eq(host_workdir / Path[Bootstrap::SysrootWorkspace::SEED_DIR_NAME])
        workspace.workspace_path.should eq(
          host_workdir /
          Path["#{Bootstrap::SysrootWorkspace::SEED_DIR_NAME}/#{Bootstrap::SysrootWorkspace::BQ2_DIR_NAME}/#{Bootstrap::SysrootWorkspace::WORKSPACE_DIR_NAME}"]
        )
      end
    end

    it "fails fast when the marker is missing" do
      with_tempdir do |tmpdir|
        host_workdir = tmpdir / "host-workdir"
        FileUtils.mkdir_p(host_workdir / Path[Bootstrap::SysrootWorkspace::SEED_DIR_NAME])

        expect_raises(Exception, /Missing BQ2 rootfs marker/) do
          Bootstrap::SysrootWorkspace.new(host_workdir: host_workdir)
        end
      end
    end
  end

  describe "#bq2_namespace_binds" do
    it "includes the seed sysroot bind and caller-provided binds" do
      with_tempdir do |tmpdir|
        host_workdir = tmpdir / "host-workdir"
        prepare_host_layout(host_workdir)
        custom_src = tmpdir / "custom"
        workspace = Bootstrap::SysrootWorkspace.new(host_workdir: host_workdir, extra_binds: [{custom_src, Path["custom"]}])

        binds = workspace.bq2_namespace_binds
        binds.should contain({host_workdir / Path["seed-rootfs/opt/sysroot"], Path["opt/sysroot"]})
        binds.should contain({custom_src, Path["custom"]})
      end
    end
  end

  describe "#namespace_switch_required?" do
    it "returns true only when a switch is required" do
      with_tempdir do |tmpdir|
        host_workdir = tmpdir / "host-workdir"
        prepare_host_layout(host_workdir)
        workspace = Bootstrap::SysrootWorkspace.new(host_workdir: host_workdir)

        workspace.namespace_switch_required?("host").should be_false
        workspace.namespace_switch_required?("seed").should be_true
      end
    end
  end

  describe "#enter_seed_rootfs_namespace" do
    it "rejects transitions when not in host namespace" do
      with_tempdir do |tmpdir|
        host_workdir = tmpdir / "host-workdir"
        prepare_host_layout(host_workdir)
        workspace = Bootstrap::SysrootWorkspace.new(host_workdir: host_workdir)
        workspace.namespace = Bootstrap::SysrootWorkspace::Namespace::Seed

        expect_raises(Exception, /Expected host namespace/) do
          workspace.enter_seed_rootfs_namespace
        end
      end
    end
  end

  describe "#enter_bq2_rootfs_namespace" do
    it "rejects transitions when not in host or seed namespaces" do
      with_tempdir do |tmpdir|
        host_workdir = tmpdir / "host-workdir"
        prepare_host_layout(host_workdir)
        workspace = Bootstrap::SysrootWorkspace.new(host_workdir: host_workdir)
        workspace.namespace = Bootstrap::SysrootWorkspace::Namespace::BQ2

        expect_raises(Exception, /Expected host or seed namespace/) do
          workspace.enter_bq2_rootfs_namespace
        end
      end
    end
  end

  describe "#enter_namespace" do
    it "is a no-op when requesting the current host namespace" do
      with_tempdir do |tmpdir|
        host_workdir = tmpdir / "host-workdir"
        prepare_host_layout(host_workdir)
        workspace = Bootstrap::SysrootWorkspace.new(host_workdir: host_workdir)

        workspace.enter_namespace("host")
        workspace.namespace.should eq(Bootstrap::SysrootWorkspace::Namespace::Host)
      end
    end

    it "rejects switching from bq2 to seed" do
      with_tempdir do |tmpdir|
        host_workdir = tmpdir / "host-workdir"
        prepare_host_layout(host_workdir)
        workspace = Bootstrap::SysrootWorkspace.new(host_workdir: host_workdir)
        workspace.namespace = Bootstrap::SysrootWorkspace::Namespace::BQ2

        expect_raises(Exception, /Cannot enter seed namespace from bq2/) do
          workspace.enter_namespace("seed")
        end
      end
    end

    it "is a no-op when already in bq2 namespace" do
      with_tempdir do |tmpdir|
        host_workdir = tmpdir / "host-workdir"
        prepare_host_layout(host_workdir)
        workspace = Bootstrap::SysrootWorkspace.new(host_workdir: host_workdir)
        workspace.namespace = Bootstrap::SysrootWorkspace::Namespace::BQ2

        workspace.enter_namespace("bq2")
        workspace.namespace.should eq(Bootstrap::SysrootWorkspace::Namespace::BQ2)
      end
    end
  end
end
