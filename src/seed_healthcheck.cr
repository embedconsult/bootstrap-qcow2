require "file_utils"
require "log"
require "./cli"

module Bootstrap
  # SeedHealthcheck validates key runtime/toolchain assumptions in the seed rootfs.
  class SeedHealthcheck < CLI
    record CheckResult, name : String, ok : Bool, details : String? = nil

    # Summarize the seed healthcheck CLI behavior for help output.
    def self.summary : String
      "Check seed health before a sysroot build"
    end

    # Return command aliases for seed healthcheck.
    def self.aliases : Array(String)
      ["seed-check"]
    end

    # Describe help output entries for seed healthcheck.
    def self.help_entries : Array(Tuple(String, String))
      [
        {"seed-healthcheck", summary},
        {"seed-check", summary},
      ]
    end

    # Run the seed healthcheck.
    def self.run(args : Array(String), _command_name : String) : Int32
      json = false
      parser, _remaining, help = CLI.parse(args, "Usage: bq2 seed-healthcheck [options]") do |p|
        p.on("--json", "Emit results as JSON") { json = true }
      end
      return CLI.print_help(parser) if help

      results = run_checks
      if json
        puts results.to_json
      else
        print_results(results)
      end
      results.all?(&.ok) ? 0 : 1
    end

    private def self.print_results(results : Array(CheckResult)) : Nil
      puts "Seed healthcheck:"
      results.each do |result|
        status = result.ok ? "OK" : "FAIL"
        line = "  - #{result.name}: #{status}"
        line += " (#{result.details})" if result.details
        puts line
      end
    end

    private def self.run_checks : Array(CheckResult)
      arch = normalized_arch
      triple = sysroot_triple(arch)
      results = [] of CheckResult
      results << check_ld_musl_path(triple, arch)
      results << check_ld_symlink
      results << check_bq2_symlinks
      results << check_crystal_target(triple)
      results << check_clang_compile
      results
    end

    private def self.check_ld_musl_path(triple : String, arch : String) : CheckResult
      path = "/etc/ld-musl-#{arch}.path"
      unless File.exists?(path)
        return CheckResult.new("musl loader path", false, "missing #{path}")
      end
      contents = File.read(path).strip
      required = "/usr/lib/#{triple}"
      ok = contents.split(":").includes?(required)
      details = ok ? nil : "missing #{required}"
      CheckResult.new("musl loader path", ok, details)
    end

    private def self.check_ld_symlink : CheckResult
      path = "/usr/bin/ld"
      unless File.exists?(path)
        return CheckResult.new("ld symlink", false, "missing #{path}")
      end
      unless File.symlink?(path)
        return CheckResult.new("ld symlink", false, "#{path} is not a symlink")
      end
      target = File.readlink(path)
      ok = target == "ld.lld" || target.ends_with?("/ld.lld")
      details = ok ? nil : "points to #{target}"
      CheckResult.new("ld symlink", ok, details)
    end

    private def self.check_bq2_symlinks : CheckResult
      required = [
        "/usr/bin/bq2",
        "/usr/bin/sysroot-runner",
        "/usr/bin/pkg-config",
      ]
      missing = required.reject { |path| File.exists?(path) }
      ok = missing.empty?
      details = ok ? nil : "missing #{missing.join(", ")}"
      CheckResult.new("bq2 symlinks", ok, details)
    end

    private def self.check_crystal_target(triple : String) : CheckResult
      status, out, err = run_capture("crystal", ["--version"])
      unless status.success?
        details = err.empty? ? out : err
        return CheckResult.new("crystal default target", false, details.strip)
      end
      target_line = out.lines.find { |line| line.starts_with?("Default target:") }
      ok = target_line && target_line.includes?(triple)
      details = ok ? nil : (target_line || "missing default target line")
      CheckResult.new("crystal default target", ok, details)
    end

    private def self.check_clang_compile : CheckResult
      tmpdir = Dir.mktmpdir("bq2-seed-check")
      source = File.join(tmpdir, "cc-test.c")
      output = File.join(tmpdir, "cc-test")
      File.write(source, "int main(){return 0;}\n")
      status, out, err = run_capture("clang", ["-xc", source, "-o", output])
      unless status.success?
        details = err.empty? ? out : err
        FileUtils.rm_rf(tmpdir)
        return CheckResult.new("clang compile/link", false, details.strip)
      end
      status, out, err = run_capture(output, [] of String)
      FileUtils.rm_rf(tmpdir)
      ok = status.success?
      details = ok ? nil : (err.empty? ? out : err)
      CheckResult.new("clang compile/link", ok, details.try(&.strip))
    end

    private def self.run_capture(command : String,
                                 args : Array(String),
                                 env : Hash(String, String) = {} of String => String) : {Process::Status, String, String}
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(command, args, env: env, output: stdout, error: stderr)
      {status, stdout.to_s, stderr.to_s}
    end

    private def self.normalized_arch : String
      status, out, _err = run_capture("uname", ["-m"])
      arch = status.success? ? out.strip : "unknown"
      case arch
      when "arm64"
        "aarch64"
      when "amd64"
        "x86_64"
      else
        arch
      end
    end

    private def self.sysroot_triple(arch : String) : String
      case arch
      when "aarch64"
        "aarch64-bq2-linux-musl"
      when "x86_64"
        "x86_64-bq2-linux-musl"
      else
        "#{arch}-bq2-linux-musl"
      end
    end
  end
end
