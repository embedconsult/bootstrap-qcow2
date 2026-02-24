require "./spec_helper"

describe Bootstrap::EfiAppBuilder do
  it "maps architecture aliases" do
    Bootstrap::EfiAppBuilder.parse_arch("arm64").should eq Bootstrap::EfiAppBuilder::Arch::AARCH64
    Bootstrap::EfiAppBuilder.parse_arch("amd64").should eq Bootstrap::EfiAppBuilder::Arch::X86_64
  end

  it "builds Crystal cross-compile argv for aarch64" do
    argv = Bootstrap::EfiAppBuilder.crystal_build_argv(
      "crystal",
      Bootstrap::EfiAppBuilder::Arch::AARCH64,
      "src/hello-efi.cr",
      "hello-efi.obj"
    )

    argv.should contain("--cross-compile")
    argv.should contain("--target")
    argv.should contain("aarch64-unknown-windows")
    argv.last.should eq "src/hello-efi.cr"
  end

  it "builds linker argv for EFI applications" do
    argv = Bootstrap::EfiAppBuilder.linker_build_argv("lld-link", "hello-efi.obj", "hello-efi.efi", "efi_main")

    argv.should eq [
      "lld-link",
      "-subsystem:efi_application",
      "-nodefaultlib",
      "-entry:efi_main",
      "hello-efi.obj",
      "-out:hello-efi.efi",
    ]
  end

  it "runs compile then link in order" do
    calls = [] of Array(String)
    code = Bootstrap::EfiAppBuilder.run_with_runner([
      "--input", "src/hello-efi.cr",
      "--output", "out/hello-efi.efi",
      "--arch", "x86_64",
      "--keep-object",
    ]) do |argv|
      calls << argv
      0
    end

    code.should eq 0
    calls.size.should eq 2
    calls[0].should contain("x86_64-unknown-windows")
    calls[1].should eq [
      "lld-link",
      "-subsystem:efi_application",
      "-nodefaultlib",
      "-entry:efi_main",
      "out/hello-efi.obj",
      "-out:out/hello-efi.efi",
    ]
  end
end
