require "time"

module Bootstrap
  # Run processes with throttled output to reduce IO overhead during builds.
  class ProcessRunner
    # Result wrapper for a timed process invocation.
    record Result,
      status : Process::Status,
      elapsed : Time::Span

    # Flush output at most 2 times per second.
    # Source: build output throttling requirement (2 Hz).
    DEFAULT_FLUSH_INTERVAL = 0.5.seconds

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
      MAX_BUFFERED_LINES = 50

      def initialize(@stdout : IO, @stderr : IO, @interval : Time::Span = DEFAULT_FLUSH_INTERVAL)
        @stdout_buffer = IO::Memory.new
        @stderr_buffer = IO::Memory.new
        @stdout_fragment = ""
        @stderr_fragment = ""
        @last_lines = [] of String
        @rendered_lines = 0
        @tty_mode = @stdout.tty? && @stderr.tty?
        @mutex = Mutex.new
        @closed = false
      end

      # Append bytes destined for stdout.
      def append_stdout(bytes : Bytes) : Nil
        @mutex.synchronize do
          if @tty_mode
            @stdout_fragment = consume_bytes(bytes, @stdout_fragment)
          else
            @stdout_buffer.write(bytes)
          end
        end
      end

      # Append bytes destined for stderr.
      def append_stderr(bytes : Bytes) : Nil
        @mutex.synchronize do
          if @tty_mode
            @stderr_fragment = consume_bytes(bytes, @stderr_fragment)
          else
            @stderr_buffer.write(bytes)
          end
        end
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
          if @tty_mode
            render_tail
          else
            flush_buffer(@stdout_buffer, @stdout)
            flush_buffer(@stderr_buffer, @stderr)
          end
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

      private def consume_bytes(bytes : Bytes, fragment : String) : String
        text = String.new(bytes)
        combined = fragment + text
        parts = combined.split('\n', remove_empty: false)
        new_fragment = parts.pop? || ""
        parts.each { |line| record_line(line) }
        new_fragment
      end

      private def record_line(line : String) : Nil
        @last_lines << line
        if @last_lines.size > MAX_BUFFERED_LINES
          @last_lines.shift(@last_lines.size - MAX_BUFFERED_LINES)
        end
      end

      private def render_tail : Nil
        lines = @last_lines.dup
        lines << @stdout_fragment unless @stdout_fragment.empty?
        lines << @stderr_fragment unless @stderr_fragment.empty?
        lines = lines.last(5)

        clear_rendered_lines if @rendered_lines > 0
        if lines.empty?
          @rendered_lines = 0
          return
        end

        @stdout.print(lines.join("\n"))
        @stdout.flush
        @rendered_lines = lines.size
      end

      private def clear_rendered_lines : Nil
        @rendered_lines.times do |idx|
          @stdout.print("\r\033[2K")
          @stdout.print("\033[A") if idx < @rendered_lines - 1
        end
      end
    end
  end
end
