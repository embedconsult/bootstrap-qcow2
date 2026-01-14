require "./spec_helper"

describe Bootstrap::CodexNamespace do
  it "binds a host work directory into /work" do
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

          module Bootstrap::CodexSessionBookmark
            def self.read(work_dir : Path = Path["/work"]) : String?
              nil
            end

            def self.latest_from(codex_home : Path) : String?
              nil
            end

            def self.write(work_dir : Path, session_id : String) : Nil
            end
          end

          temp_root = Path[File.tempname("codex-work")]
          File.delete(temp_root) if File.exists?(temp_root)
          FileUtils.mkdir_p(temp_root)
          FileUtils.mkdir_p(temp_root / "bin")

          codex_path = temp_root / "bin" / "codex"
          File.write(codex_path, "#!/bin/sh\\necho ran-codex\\npwd\\nexit 0\\n")
          File.chmod(codex_path, 0o755)

          Dir.cd(temp_root) do
            ENV["PATH"] = temp_root.to_s + "/bin:" + ENV["PATH"]

            status = Bootstrap::CodexNamespace.run(rootfs: Path["/"], alpine_setup: false)
            exit 1 unless status.success?

            captured = Bootstrap::SysrootNamespace.captured_binds
            exit 1 unless captured

            host_work, target = captured.not_nil!.first
            exit 1 unless target == Path["work"]
            exit 1 unless host_work.to_s.ends_with?("/codex/work")
            exit 1 unless Dir.exists?(host_work)
          end
        CR
      ],
      chdir: Path[__DIR__] / ".."
    )

    status.success?.should be_true
  end

  it "runs codex resume when bookmark exists" do
    status = Process.run(
      "crystal",
      [
        "eval",
        <<-CR
          require "./src/codex_namespace"
          require "file_utils"

          class Bootstrap::SysrootNamespace
            def self.enter_rootfs(rootfs : String,
                                  extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path),
                                  bind_host_dev : Bool = true)
            end
          end

          module Bootstrap::CodexSessionBookmark
            def self.read(work_dir : Path = Path["/work"]) : String?
              "11111111-2222-3333-4444-555555555555"
            end

            def self.latest_from(codex_home : Path) : String?
              nil
            end

            def self.write(work_dir : Path, session_id : String) : Nil
            end
          end

          temp_root = Path[File.tempname("codex-work")]
          File.delete(temp_root) if File.exists?(temp_root)
          FileUtils.mkdir_p(temp_root)
          FileUtils.mkdir_p(temp_root / "bin")

          codex_path = temp_root / "bin" / "codex"
          File.write(codex_path, "#!/bin/sh\\n[ \\"$1\\" = resume ] || exit 2\\n[ \\"$2\\" = 11111111-2222-3333-4444-555555555555 ] || exit 3\\nexit 0\\n")
          File.chmod(codex_path, 0o755)

          Dir.cd(temp_root) do
            ENV["PATH"] = temp_root.to_s + "/bin:" + ENV["PATH"]
            status = Bootstrap::CodexNamespace.run(rootfs: Path["/"], alpine_setup: false)
            exit status.exit_code
          end
        CR
      ],
      chdir: Path[__DIR__] / ".."
    )

    status.success?.should be_true
  end
end
