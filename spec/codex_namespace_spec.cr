require "./spec_helper"

describe Bootstrap::CodexNamespace do
  it "binds a host work directory into /work" do
    status = Process.run(
      "crystal",
      [
        "eval",
        <<-CR,
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
          File.write(codex_path, "#!/bin/sh\nexit 0\n")
          File.chmod(codex_path, 0o755)

          Dir.cd(temp_root) do
            rootfs = temp_root / "rootfs"
            FileUtils.mkdir_p(rootfs)
            work_dir = temp_root / "workdir"
            exec_path = (temp_root / "bin").to_s + ":/usr/bin:/bin"
            status = Bootstrap::CodexNamespace.run(rootfs: rootfs, alpine_setup: false, exec_path: exec_path, work_dir: work_dir)
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

  it "passes add-dir flags and resume arguments" do
    status = Process.run(
      "crystal",
      [
        "eval",
        <<-CR,
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
          File.write(codex_path, "#!/bin/sh\nset -eu\nseen_var=0\nseen_opt=0\nseen_ws=0\nseen_resume=0\nseen_id=0\nwhile [ $# -gt 0 ]; do\n  case $1 in\n    --add-dir)\n      shift\n      case ${1:-} in\n        /var) seen_var=1 ;;\n        /opt) seen_opt=1 ;;\n        /workspace) seen_ws=1 ;;\n      esac\n      ;;\n    resume)\n      seen_resume=1\n      shift\n      [ ${1:-} = 11111111-2222-3333-4444-555555555555 ] || exit 3\n      seen_id=1\n      ;;\n  esac\n  shift || true\ndone\n[ $seen_var -eq 1 ] || exit 10\n[ $seen_opt -eq 1 ] || exit 11\n[ $seen_ws -eq 1 ] || exit 12\n[ $seen_resume -eq 1 ] || exit 13\n[ $seen_id -eq 1 ] || exit 14\nexit 0\n")
          File.chmod(codex_path, 0o755)

          Dir.cd(temp_root) do
            rootfs = temp_root / "rootfs"
            FileUtils.mkdir_p(rootfs)
            work_dir = temp_root / "workdir"
            exec_path = (temp_root / "bin").to_s + ":/usr/bin:/bin"
            status = Bootstrap::CodexNamespace.run(rootfs: rootfs, alpine_setup: false, exec_path: exec_path, work_dir: work_dir)
            exit status.exit_code
          end
        CR
      ],
      chdir: Path[__DIR__] / ".."
    )

    status.success?.should be_true
  end

  it "honors explicit add_dirs" do
    status = Process.run(
      "crystal",
      [
        "eval",
        <<-CR,
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
          File.write(codex_path, "#!/bin/sh\nset -eu\nseen_custom=0\nseen_default=0\nwhile [ $# -gt 0 ]; do\n  case $1 in\n    --add-dir)\n      shift\n      case ${1:-} in\n        /tmp/custom) seen_custom=1 ;;\n        /var|/opt|/workspace) seen_default=1 ;;\n      esac\n      ;;\n  esac\n  shift || true\ndone\n[ $seen_custom -eq 1 ] || exit 20\n[ $seen_default -eq 0 ] || exit 21\nexit 0\n")
          File.chmod(codex_path, 0o755)

          Dir.cd(temp_root) do
            rootfs = temp_root / "rootfs"
            FileUtils.mkdir_p(rootfs)
            work_dir = temp_root / "workdir"
            exec_path = (temp_root / "bin").to_s + ":/usr/bin:/bin"
            status = Bootstrap::CodexNamespace.run(rootfs: rootfs, alpine_setup: false, add_dirs: ["/tmp/custom"], exec_path: exec_path, work_dir: work_dir)
            exit status.exit_code
          end
        CR
      ],
      chdir: Path[__DIR__] / ".."
    )

    status.success?.should be_true
  end

  it "downloads Codex into the rootfs before running" do
    status = Process.run(
      "crystal",
      [
        "eval",
        <<-CR,
          require "./src/codex_namespace"
          require "file_utils"
          require "uri"

          class Bootstrap::SysrootNamespace
            def self.enter_rootfs(rootfs : String,
                                  extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path),
                                  bind_host_dev : Bool = true)
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
          File.write(codex_path, "#!/bin/sh\\nexit 0\\n")
          File.chmod(codex_path, 0o755)

          codex_payload = temp_root / "codex-payload"
          File.write(codex_payload, "codex-binary")

          Dir.cd(temp_root) do
            rootfs = temp_root / "rootfs"
            FileUtils.mkdir_p(rootfs)
            work_dir = temp_root / "workdir"
            exec_path = (temp_root / "bin").to_s + ":/usr/bin:/bin"
            url = URI.parse("file://" + codex_payload.to_s)
            status = Bootstrap::CodexNamespace.run(rootfs: rootfs, alpine_setup: false, exec_path: exec_path, work_dir: work_dir, codex_url: url)
            exit status.exit_code unless status.success?

            staged = rootfs / "usr/bin/codex"
            exit 1 unless File.exists?(staged)
            exit 1 unless File.read(staged) == "codex-binary"
          end
        CR
      ],
      chdir: Path[__DIR__] / ".."
    )

    status.success?.should be_true
  end

  it "extracts Codex tarballs before staging" do
    status = Process.run(
      "crystal",
      [
        "eval",
        <<-CR,
          require "./src/codex_namespace"
          require "file_utils"
          require "uri"

          class Bootstrap::SysrootNamespace
            def self.enter_rootfs(rootfs : String,
                                  extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path),
                                  bind_host_dev : Bool = true)
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

          unless Process.find_executable("tar")
            exit 0
          end

          temp_root = Path[File.tempname("codex-work")]
          File.delete(temp_root) if File.exists?(temp_root)
          FileUtils.mkdir_p(temp_root)
          FileUtils.mkdir_p(temp_root / "bin")

          codex_path = temp_root / "bin" / "codex"
          File.write(codex_path, "#!/bin/sh\\nexit 0\\n")
          File.chmod(codex_path, 0o755)

          payload_dir = temp_root / "payload"
          FileUtils.mkdir_p(payload_dir)
          File.write(payload_dir / "codex", "codex-binary")

          tarball = temp_root / "codex.tar.gz"
          tar_status = Process.run("tar", ["-czf", tarball.to_s, "-C", payload_dir.to_s, "."])
          exit tar_status.exit_code unless tar_status.success?

          Dir.cd(temp_root) do
            rootfs = temp_root / "rootfs"
            FileUtils.mkdir_p(rootfs)
            work_dir = temp_root / "workdir"
            exec_path = (temp_root / "bin").to_s + ":/usr/bin:/bin"
            url = URI.parse("file://" + tarball.to_s)
            status = Bootstrap::CodexNamespace.run(rootfs: rootfs, alpine_setup: false, exec_path: exec_path, work_dir: work_dir, codex_url: url)
            exit status.exit_code unless status.success?

            staged = rootfs / "usr/bin/codex"
            exit 1 unless File.exists?(staged)
            exit 1 unless File.read(staged) == "codex-binary"
          end
        CR
      ],
      chdir: Path[__DIR__] / ".."
    )

    status.success?.should be_true
  end

  it "gunzips an existing codex.gz target" do
    status = Process.run(
      "crystal",
      [
        "eval",
        <<-CR,
          require "./src/codex_namespace"
          require "compress/gzip"
          require "file_utils"
          require "uri"

          class Bootstrap::SysrootNamespace
            def self.enter_rootfs(rootfs : String,
                                  extra_binds : Array(Tuple(Path, Path)) = [] of Tuple(Path, Path),
                                  bind_host_dev : Bool = true)
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
          File.write(codex_path, "#!/bin/sh\\nexit 0\\n")
          File.chmod(codex_path, 0o755)

          Dir.cd(temp_root) do
            rootfs = temp_root / "rootfs"
            FileUtils.mkdir_p(rootfs / "usr" / "bin")
            work_dir = temp_root / "workdir"
            exec_path = (temp_root / "bin").to_s + ":/usr/bin:/bin"
            target = rootfs / "usr/bin/codex"
            Compress::Gzip::Writer.open(target.to_s) { |gz| gz << "codex-binary" }
            File.chmod(target, 0o755)
            url = URI.parse("file://" + codex_path.to_s)
            status = Bootstrap::CodexNamespace.run(rootfs: rootfs, alpine_setup: false, exec_path: exec_path, work_dir: work_dir, codex_url: url)
            exit status.exit_code unless status.success?
            exit 1 unless File.read(target) == "codex-binary"
          end
        CR
      ],
      chdir: Path[__DIR__] / ".."
    )

    status.success?.should be_true
  end
end
