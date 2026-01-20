require "base64"
require "http/client"
require "openssl/lib_ssl"
require "path"
require "uri"

module Bootstrap
  # Minimal Git remote helper for HTTPS fetch over the smart HTTP protocol.
  module GitRemoteHttps
    # Limit redirects to avoid loops; matches curl defaults.
    MAX_REDIRECTS = 10
    # Git smart HTTP service name for fetch operations.
    SERVICE_NAME = "git-upload-pack"
    # Git smart HTTP service name for push operations.
    RECEIVE_SERVICE_NAME = "git-receive-pack"
    # Capabilities requested during upload-pack negotiation.
    REQUEST_CAPABILITIES = "thin-pack ofs-delta agent=bq2-git-remote-https"
    # Capabilities requested during receive-pack negotiation.
    PUSH_CAPABILITIES = "report-status agent=bq2-git-remote-https"
    # User-Agent string for outbound HTTP requests.
    USER_AGENT = "bq2-git-remote-https"
    # 40-char zero object id used for ref creation/deletion.
    ZERO_OID = "0" * 40
    # Enable debug logging when set to any non-empty value.
    DEBUG_ENV = "BQ2_GIT_REMOTE_HTTPS_DEBUG"

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
      @credentials : Array(URI)
      @debug : Bool

      def initialize(@remote_name : String, url : String)
        @base_url = url
        @refs = {} of String => String
        @refs_loaded = false
        @debug = debug_enabled?
        @credentials = read_credentials
        debug_log("remote=#{@remote_name} base_url=#{sanitize_url(@base_url)}")
        debug_log("ssl libressl=#{LibSSL::LIBRESSL_VERSION} openssl=#{LibSSL::OPENSSL_VERSION}")
        debug_log("ssl_cert_file=#{ENV["SSL_CERT_FILE"]?} ssl_cert_dir=#{ENV["SSL_CERT_DIR"]?}")
        debug_log("credentials loaded=#{@credentials.size}")
      end

      # Main command loop for the remote-helper protocol.
      def run : Nil
        while line = STDIN.gets
          line = line.rstrip("\n")
          case
          when line.empty?
            next
          when line == "capabilities"
            write_capabilities
          when line.starts_with?("option ")
            handle_option(line)
          when line.starts_with?("list")
            write_refs
          when line.starts_with?("fetch ")
            wants = read_fetch_requests(line)
            fetch_pack(wants)
          when line.starts_with?("push ")
            pushes = read_push_requests(line)
            push_refs(pushes)
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
        STDOUT.puts "push"
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

      private struct PushSpec
        getter src : String?
        getter dst : String
        getter force : Bool

        def initialize(@src : String?, @dst : String, @force : Bool)
        end

        def delete? : Bool
          @src.nil? || @src.not_nil!.empty?
        end
      end

      # Read push requests from stdin, starting with *first_line*.
      private def read_push_requests(first_line : String) : Array(PushSpec)
        requests = [] of PushSpec
        line = first_line
        loop do
          break if line.empty?
          parts = line.split(" ", 2)
          raise "Invalid push request: #{line}" unless parts.size == 2
          spec = parts[1]
          force = false
          if spec.starts_with?("+")
            force = true
            spec = spec[1..]
          end
          if spec.starts_with?(":")
            dst = spec[1..]
            requests << PushSpec.new(nil, dst, force)
          else
            src, dst = spec.split(":", 2)
            dst = src if dst.nil?
            requests << PushSpec.new(src, dst, force)
          end
          next_line = STDIN.gets
          break unless next_line
          line = next_line.rstrip("\n")
        end
        requests
      end

      # Perform an upload-pack request for *wants* and stream the pack to stdout.
      private def fetch_pack(wants : Array(String)) : Nil
        raise "No fetch targets provided" if wants.empty?
        body = build_upload_pack_request(wants)
        response = http_post(upload_pack_url, body)
        raise "git-upload-pack failed with status #{response.status_code}" unless (200..299).includes?(response.status_code)
        io = response_body_io(response)
        discard_ack_packets(io)
        IO.copy(io, STDOUT)
      end

      private struct PushUpdate
        getter old_oid : String
        getter new_oid : String
        getter refname : String

        def initialize(@old_oid : String, @new_oid : String, @refname : String)
        end
      end

      # Perform a receive-pack request for *requests* and emit helper status lines.
      private def push_refs(requests : Array(PushSpec)) : Nil
        raise "No push targets provided" if requests.empty?
        load_refs unless @refs_loaded
        updates = requests.map do |req|
          old_oid = @refs[req.dst]? || ZERO_OID
          new_oid = req.delete? ? ZERO_OID : resolve_local_oid(req.src.not_nil!)
          PushUpdate.new(old_oid, new_oid, req.dst)
        end
        body = build_receive_pack_request(updates)
        response = http_post_receive_pack(receive_pack_url, body)
        raise "git-receive-pack failed with status #{response.status_code}" unless (200..299).includes?(response.status_code)
        statuses = parse_receive_pack_status(response_body_io(response))
        updates.each do |update|
          if status = statuses[update.refname]?
            if status
              STDOUT.puts "error #{update.refname} #{status}"
            else
              STDOUT.puts "ok #{update.refname}"
            end
          else
            STDOUT.puts "error #{update.refname} missing status"
          end
        end
        STDOUT.puts
      end

      # Resolve a local ref name or object id to a 40-char SHA.
      private def resolve_local_oid(ref : String) : String
        output = IO::Memory.new
        status = Process.run("git", ["rev-parse", "--verify", ref], output: output, error: STDERR)
        raise "git rev-parse failed for #{ref}" unless status.success?
        oid = output.to_s.strip
        raise "Invalid oid for #{ref}: #{oid}" unless oid.size == 40
        oid
      end

      # Build a stateless receive-pack request body for the ref updates.
      private def build_receive_pack_request(updates : Array(PushUpdate)) : IO::Memory
        body = IO::Memory.new
        updates.each_with_index do |update, idx|
          line = "#{update.old_oid} #{update.new_oid} #{update.refname}"
          line += "\u0000#{PUSH_CAPABILITIES}" if idx == 0
          line += "\n"
          body << pkt_line(line)
        end
        body << "0000"
        if updates.any? { |update| update.new_oid != ZERO_OID }
          pack_io = build_pack_data
          IO.copy(pack_io, body)
        end
        body.rewind
        body
      end

      # Build a pack containing all local objects for transmission.
      private def build_pack_data : IO::Memory
        pack_io = IO::Memory.new
        status = Process.run("git", ["pack-objects", "--stdout", "--all"], output: pack_io, error: STDERR)
        raise "git pack-objects failed" unless status.success?
        pack_io.rewind
        pack_io
      end

      # Parse the receive-pack response into ref status results.
      private def parse_receive_pack_status(io : IO) : Hash(String, String?)
        statuses = {} of String => String?
        first = read_pkt_line(io)
        if first
          clean = first.rstrip("\n")
          clean = clean.split('\0', 2)[0] if clean.includes?('\0')
          debug_log("receive-pack line=#{clean.inspect}")
          raise "git-receive-pack error: #{clean}" if clean.starts_with?("ERR ")
          if clean.starts_with?("unpack ") && clean != "unpack ok"
            raise "git-receive-pack failed: #{clean}"
          end
        end
        while (line = read_pkt_line(io))
          clean = line.rstrip("\n")
          clean = clean.split('\0', 2)[0] if clean.includes?('\0')
          debug_log("receive-pack line=#{clean.inspect}")
          break if clean.empty?
          if clean.starts_with?("ok ")
            ref = clean[3..].strip
            statuses[ref] = nil
          elsif clean.starts_with?("ng ")
            parts = clean.split(" ", 3)
            ref = parts[1]? || clean
            msg = parts[2]? || "push rejected"
            statuses[ref] = msg
          elsif clean.starts_with?("ERR ")
            raise "git-receive-pack error: #{clean}"
          end
        end
        statuses
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
        io = response_body_io(response)
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

      # Compose the receive-pack URL for the remote.
      private def receive_pack_url : String
        base = @base_url.chomp("/")
        "#{base}/#{RECEIVE_SERVICE_NAME}"
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

      # Issue an HTTP POST for receive-pack requests.
      private def http_post_receive_pack(url : String, body : IO::Memory) : HTTP::Client::Response
        headers = HTTP::Headers{
          "Content-Type" => "application/x-git-receive-pack-request",
        }
        request_with_redirects("POST", url, body, headers: headers)
      end

      # Execute a request with redirect handling.
      private def request_with_redirects(method : String,
                                         url : String,
                                         body : String | IO | Nil,
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
          rewind_body(current_body)
          debug_log("request #{current_method} #{sanitize_url(sanitized_url)} headers=#{debug_header_summary(request_headers)} body=#{debug_body_size(current_body)}")
          response = begin
            HTTP::Client.exec(current_method, sanitized_url, headers: request_headers, body: current_body)
          rescue ex
            debug_log("request failed: #{ex.class}: #{ex.message}")
            raise ex
          end
          debug_log("response status=#{response.status_code}")
          return response unless redirect?(response.status_code)
          raise "Redirect missing Location header" unless response.headers["Location"]?
          raise "Too many redirects" if redirects >= MAX_REDIRECTS

          current_url = resolve_redirect(current_url, response.headers["Location"])
          debug_log("redirect to #{sanitize_url(current_url)}")
          current_method, current_body = redirect_method(current_method, current_body, response.status_code)
          redirects += 1
        end
      end

      private def rewind_body(body : String | IO | Nil) : Nil
        return unless body
        if body.is_a?(IO)
          body.rewind
        end
      end

      private def response_body_io(response : HTTP::Client::Response) : IO
        response.body_io? || IO::Memory.new(response.body)
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
      private def redirect_method(method : String, body : String | IO | Nil, status : Int32) : {String, String | IO | Nil}
        return {method, body} if status == 307 || status == 308
        return {"GET", nil} if status == 303 || method == "POST"
        {method, body}
      end

      # Apply basic auth from the URL userinfo into headers, returning a sanitized URL.
      private def apply_basic_auth(url : String, headers : HTTP::Headers) : String
        uri = URI.parse(url)
        user = uri.user
        pass = uri.password
        auth_source = "userinfo"
        if user && pass.nil?
          if credential = credential_for(uri, user)
            pass = credential.password
            auth_source = "credentials"
          end
        elsif user.nil?
          if credential = credential_for(uri, nil)
            user = credential.user
            pass = credential.password
            auth_source = "credentials"
          end
        end
        if user
          debug_log("auth source=#{auth_source} user=#{user} host=#{uri.host}")
          token = "#{user}:#{pass || ""}"
          headers["Authorization"] = "Basic #{Base64.strict_encode(token)}"
          uri.user = nil
          uri.password = nil
        end
        uri.to_s
      end

      # Read .git-credentials entries from known locations.
      private def read_credentials : Array(URI)
        credentials = [] of URI
        credential_paths.each do |path|
          next unless File.exists?(path)
          File.read_lines(path).each do |line|
            entry = line.strip
            next if entry.empty? || entry.starts_with?("#")
            begin
              uri = URI.parse(entry)
              next unless uri.user
              credentials << uri
            rescue
              next
            end
          end
        end
        credentials
      end

      private def credential_paths : Array(Path)
        paths = [] of Path
        if home = ENV["HOME"]?
          paths << (Path[home] / ".git-credentials")
        end
        work_creds = Path["/work/.git-credentials"]
        paths << work_creds unless paths.includes?(work_creds)
        paths
      end

      # Find the best matching credential entry for the target URI.
      private def credential_for(target : URI, user : String?) : URI?
        candidates = [] of URI
        @credentials.each do |cred|
          next unless cred.scheme == target.scheme
          next unless cred.host == target.host
          if cred.port && target.port && cred.port != target.port
            next
          end
          if user && cred.user != user
            next
          end
          if cred.path && !cred.path.empty?
            target_path = target.path || ""
            next unless target_path.starts_with?(cred.path)
          end
          candidates << cred
        end
        candidates.max_by { |cred| cred.path.try(&.size) || 0 }
      end

      private def debug_enabled? : Bool
        value = ENV[DEBUG_ENV]?
        !value.nil? && !value.empty?
      end

      private def debug_log(message : String) : Nil
        return unless @debug
        STDERR.puts "[git-remote-https] #{message}"
      end

      private def sanitize_url(url : String) : String
        uri = URI.parse(url)
        uri.user = nil
        uri.password = nil
        uri.to_s
      rescue
        url
      end

      private def debug_header_summary(headers : HTTP::Headers) : String
        keys = [] of String
        headers.each do |key, _value|
          next if key.downcase == "authorization"
          keys << key
        end
        keys.sort!
        content_type = headers["Content-Type"]?
        content_length = headers["Content-Length"]?
        summary = "keys=#{keys.join(",")}"
        summary += " content-type=#{content_type}" if content_type
        summary += " content-length=#{content_length}" if content_length
        summary
      end

      private def debug_body_size(body : String | IO | Nil) : String
        return "none" unless body
        case body
        when String
          body.bytesize.to_s
        when IO::Memory
          body.size.to_s
        else
          "stream"
        end
      end
    end
  end
end
