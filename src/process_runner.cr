require "file_utils"
require "time"

module Bootstrap
  # Run processes with throttled output to reduce IO overhead during builds.
  # When attached to a TTY, only the last few lines are rendered at a
  # controlled rate to avoid scrolling.
  class ProcessRunner
    # Linux TIOCGWINSZ ioctl request value from /usr/include/asm-generic/ioctls.h.
    TTY_IOCTL_GET_WINSIZE = 0x5413_u64

    lib LibC
      struct Winsize
        ws_row : UInt16
        ws_col : UInt16
        ws_xpixel : UInt16
        ws_ypixel : UInt16
      end

      fun ioctl(fd : Int32, request : UInt64, arg : Winsize*) : Int32
    end

    # Result wrapper for a timed process invocation.
    record Result,
      status : Process::Status,
      elapsed : Time::Span,
      output_path : String? = nil

    # Flush output at most 2 times per second.
    # Source: build output throttling requirement (2 Hz).
    DEFAULT_FLUSH_INTERVAL = 0.5.seconds

    # Run *argv* with throttled stdout/stderr, returning status + elapsed time.
    def self.run(argv : Array(String),
                 env : Hash(String, String) = {} of String => String,
                 input : IO = STDIN,
                 stdout : IO = STDOUT,
                 stderr : IO = STDERR,
                 flush_interval : Time::Span = DEFAULT_FLUSH_INTERVAL,
                 capture_path : String? = nil,
                 capture_on_error : Bool = false) : Result
      started = Time.monotonic
      capture_io = nil
      if capture_path
        FileUtils.mkdir_p(File.dirname(capture_path))
        capture_io = File.open(capture_path, "w")
      end
      status = run_with_throttled_output(argv, env, input, stdout, stderr, flush_interval, capture_io)
      capture_io.try(&.flush)
      capture_io.try(&.close)
      output_path = nil
      if capture_path
        if capture_on_error && status.success?
          File.delete(capture_path) if File.exists?(capture_path)
        else
          output_path = capture_path
        end
      end
      Result.new(status, Time.monotonic - started, output_path)
    end

    # Run a command with throttled stdout/stderr output.
    private def self.run_with_throttled_output(argv : Array(String),
                                               env : Hash(String, String),
                                               input : IO,
                                               stdout : IO,
                                               stderr : IO,
                                               flush_interval : Time::Span,
                                               capture_io : IO?) : Process::Status
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
      capture_mutex = capture_io ? Mutex.new : nil
      begin
        spawn do
          drain_stream(stdout_io, capture_io, capture_mutex) { |bytes| throttler.append_stdout(bytes) }
          done.send(nil)
        end
        spawn do
          drain_stream(stderr_io, capture_io, capture_mutex) { |bytes| throttler.append_stderr(bytes) }
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
    private def self.drain_stream(io : IO, capture_io : IO?, capture_mutex : Mutex?, &block : Bytes ->) : Nil
      # 8 KiB read size matches common pipe buffers for steady throughput.
      buffer = Bytes.new(8192)
      while (read = io.read(buffer)) > 0
        if capture_io
          if capture_mutex
            capture_mutex.synchronize { capture_io.write(buffer[0, read]) }
          else
            capture_io.write(buffer[0, read])
          end
        end
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
        @fragment_seq = 0_u64
        @stdout_fragment_seq = 0_u64
        @stderr_fragment_seq = 0_u64
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
          if @display_mode
            @stdout_fragment = consume_bytes(bytes, @stdout_fragment, false)
            @fragment_seq &+= 1
            @stdout_fragment_seq = @fragment_seq
          end
          @stdout_buffer.write(bytes) if @stdout_passthrough || !@display_mode
        end
      end

      # Append bytes destined for stderr.
      def append_stderr(bytes : Bytes) : Nil
        @mutex.synchronize do
          if @display_mode
            @stderr_fragment = consume_bytes(bytes, @stderr_fragment, true)
            @fragment_seq &+= 1
            @stderr_fragment_seq = @fragment_seq
          end
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
        if (fragment = select_fragment_line)
          lines << fragment
        end
        return if lines.empty?

        lines = lines.last(TAIL_LINES)
        if lines.size < TAIL_LINES
          lines = Array.new(TAIL_LINES - lines.size, TailLine.new("", false)) + lines
        end
        return if lines == @last_rendered

        columns = terminal_columns
        clear_rendered_lines(display_io) if @rendered_lines > 0
        lines.each_with_index do |line, idx|
          display_io.print(format_line(line, columns))
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

      private def format_line(line : TailLine, columns : Int32?) : String
        return "" if line.text.empty?
        text = columns ? truncate_to_columns(line.text, columns) : line.text
        return text unless line.stderr
        "\e[31m#{text}\e[0m"
      end

      private def select_display_io : IO?
        return @stdout if @stdout.tty?
        return @stderr if @stderr.tty?
        nil
      end

      private def select_fragment_line : TailLine?
        stdout_fragment = @stdout_fragment
        stderr_fragment = @stderr_fragment
        return nil if stdout_fragment.empty? && stderr_fragment.empty?
        if stdout_fragment.empty?
          return TailLine.new(stderr_fragment, true)
        end
        if stderr_fragment.empty?
          return TailLine.new(stdout_fragment, false)
        end
        if @stdout_fragment_seq >= @stderr_fragment_seq
          TailLine.new(stdout_fragment, false)
        else
          TailLine.new(stderr_fragment, true)
        end
      end

      private def terminal_columns : Int32?
        display_io = @display_io
        return nil unless display_io
        if display_io.is_a?(IO::FileDescriptor)
          winsize = LibC::Winsize.new
          if LibC.ioctl(display_io.fd.to_i, TTY_IOCTL_GET_WINSIZE, pointerof(winsize)) == 0
            columns = winsize.ws_col.to_i
            return columns if columns > 1
          end
        end
        env_columns = ENV["COLUMNS"]?
        return nil unless env_columns
        value = env_columns.to_i?
        return nil unless value
        value > 1 ? value : nil
      end

      private def truncate_to_columns(text : String, columns : Int32) : String
        # Leave the last column empty to avoid terminal auto-wrapping.
        max_columns = columns > 1 ? columns - 1 : columns
        return text if max_columns <= 0
        return text if text.size <= max_columns
        String.build do |io|
          count = 0
          text.each_char do |char|
            break if count >= max_columns
            io << char
            count += 1
          end
        end
      end

      private record TailLine, text : String, stderr : Bool
    end
  end
end
