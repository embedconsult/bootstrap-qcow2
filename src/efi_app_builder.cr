require "option_parser"
require "path"
require "./cli"

module Bootstrap
  # Build EFI `.efi` applications from Crystal sources via cross-compilation.
  #
  # Crystal does not currently expose an `*-unknown-efi` target triple, so this
  # command intentionally compiles to a Windows COFF object and then links it as
  # an EFI application. This follows the PE/COFF image format used by UEFI.
  #
  # References:
  # - UEFI Specification 2.10, chapter 2 (PE/COFF image requirements).
  # - LLVM lld-link docs for `/subsystem:efi_application`.
  class EfiAppBuilder < CLI
    enum Arch
      X86_64
      AARCH64
    end

    # Return the command name exposed in `bq2 --help`.
    def self.command_line_override : String?
      "efi-app-builder"
    end

    # Summarize this command for CLI help output.
    def self.summary : String
      "Build a UEFI application (.efi) from a Crystal source"
    end

    # Dispatch command execution for the busybox-style CLI.
    def self.run(args : Array(String), _command_name : String) : Int32
      run_with_runner(args) do |argv|
        status = Process.run(argv[0], argv[1..], input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
        status.exit_code
      end
    end

    # Parse options, compile the Crystal source to COFF, then link an EFI image.
    def self.run_with_runner(args : Array(String), stderr : IO = STDERR, &command_runner : Array(String) -> Int32) : Int32
      input = "src/hello-efi.cr"
      output = "hello-efi.efi"
      arch = Arch::AARCH64
      crystal_exe = "crystal"
      linker_exe = "lld-link"
      entrypoint = "efi_main"
      keep_object = false

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 efi-app-builder [options]") do |p|
        p.on("--input PATH", "Crystal source file (default: #{input})") { |val| input = val }
        p.on("--output PATH", "Output EFI image (default: #{output})") { |val| output = val }
        p.on("--arch ARCH", "Target architecture: aarch64|x86_64 (default: aarch64)") { |val| arch = parse_arch(val) }
        p.on("--crystal PATH", "Crystal executable (default: crystal)") { |val| crystal_exe = val }
        p.on("--linker PATH", "Linker executable (default: lld-link)") { |val| linker_exe = val }
        p.on("--entry SYMBOL", "EFI entrypoint symbol (default: efi_main)") { |val| entrypoint = val }
        p.on("--keep-object", "Keep the intermediate COFF object") { keep_object = true }
      end
      return CLI.print_help(parser) if help

      object_path = object_path_for(output)
      crystal_argv = crystal_build_argv(crystal_exe, arch, input, object_path)
      linker_argv = linker_build_argv(linker_exe, object_path, output, entrypoint)

      crystal_exit = command_runner.call(crystal_argv)
      return crystal_exit unless crystal_exit == 0

      link_exit = command_runner.call(linker_argv)
      return link_exit unless link_exit == 0

      unless keep_object
        begin
          File.delete(object_path)
        rescue ex
          stderr.puts "warning: unable to delete #{object_path}: #{ex.message}"
        end
      end

      0
    end

    # Return the target architecture parsed from user input.
    def self.parse_arch(value : String) : Arch
      normalized = value.downcase
      return Arch::AARCH64 if normalized == "aarch64" || normalized == "arm64"
      return Arch::X86_64 if normalized == "x86_64" || normalized == "amd64"
      raise "Unsupported architecture '#{value}'. Expected aarch64 or x86_64."
    end

    # Return the Windows triple Crystal can emit COFF objects for.
    def self.crystal_target_triple(arch : Arch) : String
      case arch
      in .aarch64?
        "aarch64-unknown-windows"
      in .x86_64?
        "x86_64-unknown-windows"
      end
    end

    # Build the Crystal compiler command line used for cross-compilation.
    def self.crystal_build_argv(crystal_exe : String, arch : Arch, input : String, object_path : String) : Array(String)
      [
        crystal_exe,
        "build",
        "--cross-compile",
        "--single-module",
        "--target", crystal_target_triple(arch),
        "-Dwithout_iconv",
        "-Dskip_crystal_compiler_rt",
        "-Dgc_none",
        "-Dwithout_openssl",
        "-Dwithout_zlib",
        "-o", object_path,
        input,
      ]
    end

    # Build the linker command line used to emit the final EFI image.
    def self.linker_build_argv(linker_exe : String, object_path : String, output : String, entrypoint : String) : Array(String)
      [
        linker_exe,
        "-subsystem:efi_application",
        "-nodefaultlib",
        "-entry:#{entrypoint}",
        object_path,
        "-out:#{output}",
      ]
    end

    # Return the intermediate object path for the requested output image.
    def self.object_path_for(output : String) : String
      output_path = Path[output]
      stem = output_path.basename.sub(/\.efi$/i, "")
      stem = "efi-app" if stem.empty?
      (output_path.parent / "#{stem}.obj").to_s
    end
  end
end
