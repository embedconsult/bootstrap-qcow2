require "time"

module Bootstrap
  # Run processes with throttled output to reduce IO overhead during builds.
  # When attached to a TTY, only the last few lines are rendered at a
  # controlled rate to avoid scrolling.
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
      previous_handler = Signal::INT.trap_handler?
      Signal::INT.trap do |signal|
        throttler.restore_cursor
        if previous_handler
          previous_handler.call(signal)
        else
          Signal::INT.reset
          Process.signal(signal, Process.pid)
        end
      end

      done = Channel(Nil).new
      begin
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
        status
      ensure
        throttler.close
        if previous_handler
          Signal::INT.trap { |signal| previous_handler.call(signal) }
        else
          Signal::INT.reset
        end
      end
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
      TAIL_LINES         =  5
      @display_io : IO?

      def initialize(@stdout : IO, @stderr : IO, @interval : Time::Span = DEFAULT_FLUSH_INTERVAL)
        @stdout_buffer = IO::Memory.new
        @stderr_buffer = IO::Memory.new
        @stdout_fragment = ""
        @stderr_fragment = ""
        @last_lines = [] of TailLine
        @last_rendered = [] of TailLine
        @rendered_lines = 0
        @display_io = select_display_io
        @display_mode = !@display_io.nil?
        @stdout_passthrough = !@stdout.tty? && @display_io != @stdout
        @stderr_passthrough = !@stderr.tty? && @display_io != @stderr
        @mutex = Mutex.new
        @closed = false
      end

      # Append bytes destined for stdout.
      def append_stdout(bytes : Bytes) : Nil
        @mutex.synchronize do
          @stdout_fragment = consume_bytes(bytes, @stdout_fragment, false) if @display_mode
          @stdout_buffer.write(bytes) if @stdout_passthrough || !@display_mode
        end
      end

      # Append bytes destined for stderr.
      def append_stderr(bytes : Bytes) : Nil
        @mutex.synchronize do
          @stderr_fragment = consume_bytes(bytes, @stderr_fragment, true) if @display_mode
          @stderr_buffer.write(bytes) if @stderr_passthrough || !@display_mode
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
          if @display_mode
            render_tail
            flush_buffer(@stdout_buffer, @stdout) if @stdout_passthrough
            flush_buffer(@stderr_buffer, @stderr) if @stderr_passthrough
            return
          end
          flush_buffer(@stdout_buffer, @stdout)
          flush_buffer(@stderr_buffer, @stderr)
        end
      end

      # Stop flushing and emit any buffered output.
      def close : Nil
        @mutex.synchronize { @closed = true }
        flush
        finalize_display
      end

      # Write a buffered stream into the target IO and clear it.
      private def flush_buffer(buffer : IO::Memory, io : IO) : Nil
        return if buffer.size == 0
        io.write(buffer.to_slice)
        buffer.clear
        io.flush
      end

      private def consume_bytes(bytes : Bytes, fragment : String, is_stderr : Bool) : String
        text = String.new(bytes)
        combined = fragment + text
        parts = combined.split('\n', remove_empty: false)
        new_fragment = parts.pop? || ""
        parts.each { |line| record_line(line, is_stderr) }
        new_fragment
      end

      private def record_line(line : String, is_stderr : Bool) : Nil
        @last_lines << TailLine.new(line, is_stderr)
        if @last_lines.size > MAX_BUFFERED_LINES
          @last_lines.shift(@last_lines.size - MAX_BUFFERED_LINES)
        end
      end

      private def render_tail : Nil
        display_io = @display_io
        return unless display_io

        lines = @last_lines.dup
        lines << TailLine.new(@stdout_fragment, false) unless @stdout_fragment.empty?
        lines << TailLine.new(@stderr_fragment, true) unless @stderr_fragment.empty?
        return if lines.empty?

        lines = lines.last(TAIL_LINES)
        if lines.size < TAIL_LINES
          lines = Array.new(TAIL_LINES - lines.size, TailLine.new("", false)) + lines
        end
        return if lines == @last_rendered

        clear_rendered_lines(display_io) if @rendered_lines > 0
        lines.each_with_index do |line, idx|
          display_io.print(format_line(line))
          display_io.print("\n") if idx < lines.size - 1
        end
        display_io.flush
        @rendered_lines = TAIL_LINES
        @last_rendered = lines
      end

      private def clear_rendered_lines(io : IO) : Nil
        @rendered_lines.times do |idx|
          io.print("\r\033[0m\033[2K")
          io.print("\033[A") if idx < @rendered_lines - 1
        end
      end

      private def finalize_display : Nil
        @mutex.synchronize do
          display_io = @display_io
          return unless display_io
          if @rendered_lines > 0
            clear_rendered_lines(display_io)
            display_io.flush
          end
          @rendered_lines = 0
          @last_rendered.clear
        end
      end

      def restore_cursor : Nil
        @mutex.synchronize do
          display_io = @display_io
          return unless display_io
          return if @rendered_lines == 0
          clear_rendered_lines(display_io)
          display_io.flush
          @rendered_lines = 0
          @last_rendered.clear
        end
      end

      private def format_line(line : TailLine) : String
        return "" if line.text.empty?
        return line.text unless line.stderr
        "\e[31m#{line.text}\e[0m"
      end

      private def select_display_io : IO?
        return @stdout if @stdout.tty?
        return @stderr if @stderr.tty?
        nil
      end

      private record TailLine, text : String, stderr : Bool
    end
  end
end
