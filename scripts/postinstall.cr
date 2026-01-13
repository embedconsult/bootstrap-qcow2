require "file_utils"

BIN_DIR = Path["bin"]
TARGET  = BIN_DIR / "bq2"
LINKS   = %w[
  sysroot-builder
  sysroot-namespace
  sysroot-namespace-check
  sysroot-runner
  codex-namespace
]

FileUtils.mkdir_p(BIN_DIR)

unless File.exists?(TARGET)
  STDERR.puts "warning: expected #{TARGET} to exist; run `shards build` to compile bq2"
end

LINKS.each do |name|
  link_path = BIN_DIR / name
  File.delete(link_path) if File.symlink?(link_path) || File.exists?(link_path)
  File.symlink("bq2", link_path)
end

puts "Created symlinks: #{LINKS.join(", ")} -> #{TARGET}"
