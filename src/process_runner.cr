require "time"

module Bootstrap
  # Run processes with throttled output to reduce IO overhead during builds.
  class ProcessRunner
    # Result wrapper for a timed process invocation.
    record Result,
      status : Process::Status,
      elapsed : Time::Span

    # Flush output at most 5 times per second.
    # Source: build output throttling requirement (5 Hz).
    DEFAULT_FLUSH_INTERVAL = 0.2.seconds

    # Run *argv* with throttled stdout/stderr, returning status + elapsed time.
    def self.run(argv : Array(String),
                 env : Hash(String, String) = {} of String => String,
                 input : IO = STDIN,
                 stdout : IO = STDOUT,
                 stderr : IO = STDERR,
                 flush_interval : Time::Span = DEFAULT_FLUSH_INTERVAL) : Result
      started = Time.monotonic
      status = run_with_throttled_output(argv, env, input, stdout, stderr, flush_interval)
      Result.new(status, Time.monotonic - started)
    end

    # Run a command with throttled stdout/stderr output.
    private def self.run_with_throttled_output(argv : Array(String),
                                               env : Hash(String, String),
                                               input : IO,
                                               stdout : IO,
                                               stderr : IO,
                                               flush_interval : Time::Span) : Process::Status
      process = Process.new(
        argv[0],
        argv[1..],
        env: env,
        input: input,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe
      )
      stdout_io = process.output.not_nil!
      stderr_io = process.error.not_nil!
      throttler = ThrottledOutput.new(stdout, stderr, flush_interval)
      throttler.start

      done = Channel(Nil).new
      spawn do
        drain_stream(stdout_io) { |bytes| throttler.append_stdout(bytes) }
        done.send(nil)
      end
      spawn do
        drain_stream(stderr_io) { |bytes| throttler.append_stderr(bytes) }
        done.send(nil)
      end

      status = process.wait
      2.times { done.receive }
      throttler.close
      status
    end

    # Drain a process output stream into the provided block.
    private def self.drain_stream(io : IO, &block : Bytes ->) : Nil
      # 8 KiB read size matches common pipe buffers for steady throughput.
      buffer = Bytes.new(8192)
      while (read = io.read(buffer)) > 0
        yield buffer[0, read]
      end
    end

    private class ThrottledOutput
      def initialize(@stdout : IO, @stderr : IO, @interval : Time::Span = DEFAULT_FLUSH_INTERVAL)
        @stdout_buffer = IO::Memory.new
        @stderr_buffer = IO::Memory.new
        @mutex = Mutex.new
        @closed = false
      end

      # Append bytes destined for stdout.
      def append_stdout(bytes : Bytes) : Nil
        @mutex.synchronize { @stdout_buffer.write(bytes) }
      end

      # Append bytes destined for stderr.
      def append_stderr(bytes : Bytes) : Nil
        @mutex.synchronize { @stderr_buffer.write(bytes) }
      end

      # Start the periodic flush loop.
      def start : Nil
        spawn do
          loop do
            sleep @interval
            break if @mutex.synchronize { @closed }
            flush
          end
        end
      end

      # Flush buffered stdout/stderr to the real outputs.
      def flush : Nil
        @mutex.synchronize do
          flush_buffer(@stdout_buffer, @stdout)
          flush_buffer(@stderr_buffer, @stderr)
        end
      end

      # Stop flushing and emit any buffered output.
      def close : Nil
        @mutex.synchronize { @closed = true }
        flush
      end

      # Write a buffered stream into the target IO and clear it.
      private def flush_buffer(buffer : IO::Memory, io : IO) : Nil
        return if buffer.size == 0
        io.write(buffer.to_slice)
        buffer.clear
        io.flush
      end
    end
  end
end
