require "./spec_helper"

describe Bootstrap::PatchApplier do
  it "applies patches and skips already applied hunks" do
    with_tempdir do |dir|
      File.write(dir.join("hello.txt"), "line1\nline2\n")
      patch_text = [
        "diff --git a/hello.txt b/hello.txt",
        "--- a/hello.txt",
        "+++ b/hello.txt",
        "@@ -1,2 +1,3 @@",
        " line1",
        "-line2",
        "+line2-changed",
        "+line3",
        "",
      ].join("\n")
      patch_path = dir.join("change.patch")
      File.write(patch_path, patch_text)

      applier = Bootstrap::PatchApplier.new(dir)
      result = applier.apply(patch_path.to_s)
      result.applied_files.should eq(["hello.txt"])
      result.skipped_files.should be_empty
      File.read(dir.join("hello.txt")).should eq("line1\nline2-changed\nline3\n")

      second_result = applier.apply(patch_path.to_s)
      second_result.applied_files.should be_empty
      second_result.skipped_files.should eq(["hello.txt"])
      second_result.already_applied?.should be_true
    end
  end

  it "creates new files from patches" do
    with_tempdir do |dir|
      patch_text = [
        "diff --git a/new.txt b/new.txt",
        "new file mode 100644",
        "--- /dev/null",
        "+++ b/new.txt",
        "@@ -0,0 +1,2 @@",
        "+hello",
        "+world",
        "",
      ].join("\n")
      patch_path = dir.join("create.patch")
      File.write(patch_path, patch_text)

      applier = Bootstrap::PatchApplier.new(dir)
      result = applier.apply(patch_path.to_s)
      result.applied_files.should eq(["new.txt"])
      result.skipped_files.should be_empty
      File.read(dir.join("new.txt")).should eq("hello\nworld")
    end
  end

  it "applies patches without diff --git headers" do
    with_tempdir do |dir|
      File.write(dir.join("hello.txt"), "line1\nline2\n")
      patch_text = [
        "--- a/hello.txt",
        "+++ b/hello.txt",
        "@@ -1,2 +1,2 @@",
        " line1",
        "-line2",
        "+line2-updated",
        "",
      ].join("\n")
      patch_path = dir.join("change.patch")
      File.write(patch_path, patch_text)

      applier = Bootstrap::PatchApplier.new(dir)
      result = applier.apply(patch_path.to_s)
      result.applied_files.should eq(["hello.txt"])
      result.skipped_files.should be_empty
      File.read(dir.join("hello.txt")).should eq("line1\nline2-updated\n")
    end
  end

  it "applies hunks even when line numbers are shifted" do
    with_tempdir do |dir|
      File.write(dir.join("hello.txt"), "line0\nline1\nline2\n")
      patch_text = [
        "diff --git a/hello.txt b/hello.txt",
        "--- a/hello.txt",
        "+++ b/hello.txt",
        "@@ -1,2 +1,2 @@",
        " line1",
        "-line2",
        "+line2-shifted",
        "",
      ].join("\n")
      patch_path = dir.join("change.patch")
      File.write(patch_path, patch_text)

      applier = Bootstrap::PatchApplier.new(dir)
      result = applier.apply(patch_path.to_s)
      result.applied_files.should eq(["hello.txt"])
      File.read(dir.join("hello.txt")).should eq("line0\nline1\nline2-shifted\n")
    end
  end
end
