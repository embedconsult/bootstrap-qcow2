require "./spec_helper"
require "../src/codex_session_bookmark"

describe Bootstrap::CodexSessionBookmark do
  it "builds the bookmark path under work directory" do
    with_tempdir do |dir|
      Bootstrap::CodexSessionBookmark.path(dir).to_s.should eq (dir / ".codex-session-id").to_s
    end
  end

  it "extracts a uuid from a session filename" do
    id = "019bb5a2-d388-7f01-b44a-2c35e74d0d53"
    Bootstrap::CodexSessionBookmark.extract_id("/tmp/rollout-#{id}.jsonl").should eq id
    Bootstrap::CodexSessionBookmark.extract_id("/tmp/nope.txt").should be_nil
  end

  it "reads and writes a session bookmark" do
    with_tempdir do |dir|
      work = dir / "work"
      Bootstrap::CodexSessionBookmark.read(work).should be_nil
      Bootstrap::CodexSessionBookmark.write(work, "019bb5a2-d388-7f01-b44a-2c35e74d0d53")
      Bootstrap::CodexSessionBookmark.read(work).should eq "019bb5a2-d388-7f01-b44a-2c35e74d0d53"
    end
  end

  it "extracts the latest session id from a codex home directory" do
    with_tempdir do |dir|
      codex_home = dir / ".codex"
      sessions_dir = codex_home / "sessions/2026/01/13"
      FileUtils.mkdir_p(sessions_dir)

      old_id = "00000000-0000-0000-0000-000000000001"
      new_id = "00000000-0000-0000-0000-000000000002"
      old_path = sessions_dir / "rollout-2026-01-13T00-00-00-#{old_id}.jsonl"
      new_path = sessions_dir / "rollout-2026-01-13T00-00-01-#{new_id}.jsonl"

      File.write(old_path, "old\n")
      File.write(new_path, "new\n")
      File.utime(Time.utc - 5.seconds, Time.utc - 5.seconds, old_path)
      File.utime(Time.utc, Time.utc, new_path)

      Bootstrap::CodexSessionBookmark.latest_from(codex_home).should eq new_id
    end
  end
end
