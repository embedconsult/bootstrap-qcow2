require "./spec_helper"

describe Bootstrap::CodexNamespace do
  it "falls back to / when /work is unavailable" do
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    status = Process.run(
      "crystal",
      [
        "eval",
        <<-CR
          require "./src/codex_namespace"

          class Bootstrap::SysrootNamespace
            def self.enter_rootfs(rootfs : String,
                                  extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path),
                                  bind_host_dev : Bool = true)
            end
          end

          temp_root = Path[File.tempname("codex-work")]
          File.delete(temp_root) if File.exists?(temp_root)
          FileUtils.mkdir_p(temp_root)

          Dir.cd(temp_root) do
            status = Bootstrap::CodexNamespace.run(["pwd"], rootfs: Path["/"], bind_work: false, alpine_setup: false)
            exit status.exit_code
          end
        CR
      ],
      chdir: Path[__DIR__] / "..",
      output: stdout,
      error: stderr
    )

    status.success?.should be_true
    stdout.to_s.lines.last?.try(&.chomp).should eq("/")
    stderr.to_s.should be_empty
  end

  it "binds a host work directory into /work when enabled" do
    status = Process.run(
      "crystal",
      [
        "eval",
        <<-CR
          require "./src/codex_namespace"
          require "file_utils"

          class Bootstrap::SysrootNamespace
            @@captured_binds : Array(Tuple(Path, Path))?

            def self.enter_rootfs(rootfs : String,
                                  extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path),
                                  bind_host_dev : Bool = true)
              @@captured_binds = extra_binds
            end

            def self.captured_binds
              @@captured_binds
            end
          end

          temp_root = Path[File.tempname("codex-work")]
          File.delete(temp_root) if File.exists?(temp_root)
          FileUtils.mkdir_p(temp_root)

          Dir.cd(temp_root) do
            status = Bootstrap::CodexNamespace.run(["pwd"], rootfs: Path["/"], bind_work: true, alpine_setup: false)
            exit 1 unless status.success?

            captured = Bootstrap::SysrootNamespace.captured_binds
            exit 1 unless captured

            host_work, target = captured.not_nil!.first
            exit 1 unless target == Path["work"]
            exit 1 unless Dir.exists?(host_work)
          end
        CR
      ],
      chdir: Path[__DIR__] / ".."
    )

    status.success?.should be_true
  end
end
