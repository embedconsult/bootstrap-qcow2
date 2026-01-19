require "base64"
require "http/client"
require "uri"

module Bootstrap
  # Minimal Git remote helper for HTTPS fetch over the smart HTTP protocol.
  module GitRemoteHttps
    # Limit redirects to avoid loops; matches curl defaults.
    MAX_REDIRECTS = 10
    # Git smart HTTP service name for fetch operations.
    SERVICE_NAME = "git-upload-pack"
    # Capabilities requested during upload-pack negotiation.
    REQUEST_CAPABILITIES = "thin-pack ofs-delta agent=bq2-git-remote-https"
    # User-Agent string for outbound HTTP requests.
    USER_AGENT = "bq2-git-remote-https"

    # Run the git-remote-https helper with *args* and return a shell-style exit code.
    def self.run(args : Array(String)) : Int32
      if args.size < 2
        STDERR.puts "Usage: git-remote-https <name> <url>"
        return 1
      end
      Session.new(args[0], args[1]).run
      0
    rescue ex
      STDERR.puts ex.message
      1
    end

    # Streaming protocol session for a single remote.
    class Session
      def initialize(@remote_name : String, url : String)
        @base_url = url
        @refs = {} of String => String
        @refs_loaded = false
      end

      # Main command loop for the remote-helper protocol.
      def run : Nil
        while line = STDIN.gets
          line = line.rstrip("\n")
          case
          when line == "capabilities"
            write_capabilities
          when line.starts_with?("option ")
            handle_option(line)
          when line.starts_with?("list")
            write_refs
          when line.starts_with?("fetch ")
            wants = read_fetch_requests(line)
            fetch_pack(wants)
          when line == "quit"
            break
          else
            STDERR.puts "Unsupported command: #{line}"
            STDOUT.puts "unsupported"
          end
          STDOUT.flush
        end
      end

      # Advertise supported helper capabilities.
      private def write_capabilities : Nil
        STDOUT.puts "fetch"
        STDOUT.puts "option"
        STDOUT.puts
      end

      # Respond to a remote-helper option command.
      private def handle_option(_line : String) : Nil
        STDOUT.puts "ok"
      end

      # Fetch and emit the remote ref list.
      private def write_refs : Nil
        load_refs unless @refs_loaded
        @refs.each do |ref, sha|
          STDOUT.puts "#{sha} #{ref}"
        end
        STDOUT.puts
      end

      # Read fetch requests from stdin, starting with *first_line*.
      private def read_fetch_requests(first_line : String) : Array(String)
        wants = [] of String
        line = first_line
        loop do
          break if line.empty?
          parts = line.split(" ", 3)
          wants << parts[1] if parts.size >= 2
          next_line = STDIN.gets
          break unless next_line
          line = next_line.rstrip("\n")
        end
        wants
      end

      # Perform an upload-pack request for *wants* and stream the pack to stdout.
      private def fetch_pack(wants : Array(String)) : Nil
        raise "No fetch targets provided" if wants.empty?
        body = build_upload_pack_request(wants)
        response = http_post(upload_pack_url, body)
        raise "git-upload-pack failed with status #{response.status_code}" unless (200..299).includes?(response.status_code)
        io = response.body_io
        discard_ack_packets(io)
        IO.copy(io, STDOUT)
      end

      # Build a stateless upload-pack request body for the requested object ids.
      private def build_upload_pack_request(wants : Array(String)) : String
        String.build do |io|
          wants.each_with_index do |oid, idx|
            line = idx == 0 ? "want #{oid} #{REQUEST_CAPABILITIES}\n" : "want #{oid}\n"
            io << pkt_line(line)
          end
          io << pkt_line("done\n")
          io << "0000"
        end
      end

      # Fetch and cache refs from the remote info/refs endpoint.
      private def load_refs : Nil
        response = http_get(info_refs_url)
        raise "info/refs failed with status #{response.status_code}" unless (200..299).includes?(response.status_code)
        io = response.body_io
        first = read_pkt_line(io)
        if first && first.starts_with?("# service=#{SERVICE_NAME}")
          read_pkt_line(io) # flush
        elsif first
          parse_ref_line(first, first: true)
        end
        idx = 0
        while (line = read_pkt_line(io))
          break if line.empty?
          parse_ref_line(line, first: idx == 0)
          idx += 1
        end
        @refs_loaded = true
      end

      # Parse a single ref line into the cached ref map.
      private def parse_ref_line(line : String, first : Bool) : Nil
        clean = line.rstrip("\n")
        sha, ref = clean.split(" ", 2)
        return unless sha && ref
        if first && ref.includes?('\0')
          ref = ref.split('\0', 2)[0]
        end
        @refs[ref] = sha
      end

      # Drain ack/NAK pkt-lines before the pack stream.
      private def discard_ack_packets(io : IO) : Nil
        while (line = read_pkt_line(io))
          break if line.empty?
          raise "git-upload-pack error: #{line}" if line.starts_with?("ERR ")
        end
      end

      # Read a single pkt-line from *io*.
      private def read_pkt_line(io : IO) : String?
        len_bytes = Bytes.new(4)
        return nil if io.read(len_bytes) == 0
        len = String.new(len_bytes).to_i(16)
        return "" if len == 0
        payload = Bytes.new(len - 4)
        io.read_fully(payload)
        String.new(payload)
      end

      # Encode a payload string into pkt-line form.
      private def pkt_line(payload : String) : String
        "%04x%s" % {payload.bytesize + 4, payload}
      end

      # Compose the info/refs URL for the remote.
      private def info_refs_url : String
        base = @base_url.chomp("/")
        "#{base}/info/refs?service=#{SERVICE_NAME}"
      end

      # Compose the upload-pack URL for the remote.
      private def upload_pack_url : String
        base = @base_url.chomp("/")
        "#{base}/#{SERVICE_NAME}"
      end

      # Issue an HTTP GET with redirect support.
      private def http_get(url : String) : HTTP::Client::Response
        request_with_redirects("GET", url, nil)
      end

      # Issue an HTTP POST with redirect support.
      private def http_post(url : String, body : String) : HTTP::Client::Response
        headers = HTTP::Headers{
          "Content-Type" => "application/x-git-upload-pack-request",
        }
        request_with_redirects("POST", url, body, headers: headers)
      end

      # Execute a request with redirect handling.
      private def request_with_redirects(method : String,
                                         url : String,
                                         body : String?,
                                         headers : HTTP::Headers? = nil) : HTTP::Client::Response
        redirects = 0
        current_url = url
        current_method = method
        current_body = body
        current_headers = headers

        loop do
          request_headers = current_headers || HTTP::Headers.new
          request_headers["User-Agent"] = USER_AGENT
          sanitized_url = apply_basic_auth(current_url, request_headers)
          response = HTTP::Client.exec(current_method, sanitized_url, headers: request_headers, body: current_body)
          return response unless redirect?(response.status_code)
          raise "Redirect missing Location header" unless response.headers["Location"]?
          raise "Too many redirects" if redirects >= MAX_REDIRECTS

          current_url = resolve_redirect(current_url, response.headers["Location"])
          current_method, current_body = redirect_method(current_method, current_body, response.status_code)
          redirects += 1
        end
      end

      # True if *status* is an HTTP redirect response code.
      private def redirect?(status : Int32) : Bool
        status == 301 || status == 302 || status == 303 || status == 307 || status == 308
      end

      # Resolve a redirect target against the original URL.
      private def resolve_redirect(base : String, location : String) : String
        base_uri = URI.parse(base)
        target = URI.parse(location)
        return target.to_s if target.scheme
        base_uri.resolve(target).to_s
      end

      # Normalize method/body changes for a redirect response.
      private def redirect_method(method : String, body : String?, status : Int32) : {String, String?}
        return {method, body} if status == 307 || status == 308
        return {"GET", nil} if status == 303 || method == "POST"
        {method, body}
      end

      # Apply basic auth from the URL userinfo into headers, returning a sanitized URL.
      private def apply_basic_auth(url : String, headers : HTTP::Headers) : String
        uri = URI.parse(url)
        user = uri.user
        pass = uri.password
        if user
          token = "#{user}:#{pass || ""}"
          headers["Authorization"] = "Basic #{Base64.strict_encode(token)}"
          uri.user = nil
          uri.password = nil
        end
        uri.to_s
      end
    end
  end
end
