require "./spec_helper"
require "../src/syscalls"
require "random/secure"

private def with_tmpdir(&)
  dir = File.join(Dir.tempdir, "syscalls-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Bootstrap::Syscalls do
  describe ".write_proc_self_map" do
    it "rejects unsupported entries" do
      expect_raises(ArgumentError, "Unsupported proc entry") do
        Bootstrap::Syscalls.write_proc_self_map("nope", "0 0 1", "/tmp")
      end
    end

    it "rejects null bytes in content" do
      with_tmpdir do |dir|
        path = File.join(dir, "uid_map")
        File.write(path, "")
        expect_raises(ArgumentError, "null bytes") do
          Bootstrap::Syscalls.write_proc_self_map("uid_map", "0\0 0 1", dir)
        end
      end
    end

    it "appends a newline when missing" do
      with_tmpdir do |dir|
        Bootstrap::Syscalls.write_proc_self_map("uid_map", "0 1000 1", dir)
        content = File.read(File.join(dir, "uid_map"))
        content.should eq("0 1000 1\n")
      end
    end
  end
end
