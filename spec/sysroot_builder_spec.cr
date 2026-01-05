require "./spec_helper"

describe Bootstrap::DockerSysrootBuilder do
  it "enumerates the Alpine-aligned packages needed for the sysroot" do
    builder = Bootstrap::DockerSysrootBuilder.new
    names = builder.packages.map(&.name)
    %w(
      m4 musl cmake busybox make zlib libressl libatomic compiler-rt-builtins
      clang lld bdwgc pcre2 gmp libiconv libxml2 libyaml libffi
    ).each do |pkg|
      names.includes?(pkg).should be_true
    end
  end

  it "emits a Dockerfile that builds and reuses the Crystal runner" do
    dockerfile = Bootstrap::DockerSysrootBuilder.new.dockerfile_preview
    dockerfile.includes?("FROM alpine:").should be_true
    dockerfile.includes?("sysroot-runner").should be_true
    dockerfile.includes?("COPY --from=builder /usr/local/share/bootstrap/manifest.json").should be_true
  end

  it "serializes a data-driven manifest for the container coordinator" do
    manifest = Bootstrap::DockerSysrootBuilder.new.manifest_json
    manifest.includes?("compiler-rt-builtins").should be_true
    manifest.includes?("checksum").should be_true
    manifest.includes?("recipe").should be_true
  end
end
