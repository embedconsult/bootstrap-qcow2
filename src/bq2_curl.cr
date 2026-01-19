require "file_utils"
require "http/client"
require "uri"

module Bootstrap
  # Minimal HTTP client with curl-like flags for internal tooling.
  module Bq2Curl
    # Conservative default to avoid redirect loops; override with --max-redirects.
    DEFAULT_MAX_REDIRECTS = 10

    # Run the bq2-curl command with *args* and return a shell-style exit code.
    def self.run(args : Array(String)) : Int32
      output : Path? = nil
      method = "GET"
      data : String? = nil
      follow_redirects = false
      headers = HTTP::Headers.new
      max_redirects = DEFAULT_MAX_REDIRECTS

      parser, remaining, help = CLI.parse(args, "Usage: bq2-curl [options] URL") do |p|
        p.on("-o FILE", "--output=FILE", "Write response body to FILE") { |val| output = Path[val] }
        p.on("-I", "--head", "Issue a HEAD request and print response headers") { method = "HEAD" }
        p.on("-L", "--location", "Follow redirects") { follow_redirects = true }
        p.on("-X METHOD", "--request=METHOD", "Override the request method") { |val| method = val.upcase }
        p.on("-H HEADER", "--header=HEADER", "Add an HTTP header (repeatable)") { |val| add_header(headers, val) }
        p.on("-d DATA", "--data=DATA", "Request body data (prefix with @ to read a file)") { |val| data = val }
        p.on("--max-redirects=N", "Maximum redirects to follow (default: #{DEFAULT_MAX_REDIRECTS})") { |val| max_redirects = val.to_i }
      end
      return CLI.print_help(parser) if help

      if remaining.empty?
        STDERR.puts "URL is required"
        return 1
      end

      url = remaining.first
      body = resolve_body(data)
      method = "POST" if body && method == "GET"

      response = request_with_redirects(method, url, headers, body, follow_redirects, max_redirects)
      if method == "HEAD"
        print_headers(response)
        return 0
      end

      if output
        FileUtils.mkdir_p(output.parent) if output.parent
        File.open(output, "w") { |io| IO.copy(response.body_io, io) }
      else
        IO.copy(response.body_io, STDOUT)
      end
      0
    rescue ex
      STDERR.puts ex.message
      1
    end

    # Parse a header line and append it to *headers*.
    private def self.add_header(headers : HTTP::Headers, raw : String) : Nil
      parts = raw.split(":", 2)
      raise "Invalid header #{raw.inspect}" if parts.size < 2
      headers.add(parts[0].strip, parts[1].strip)
    end

    # Resolve a request body string, supporting @file syntax.
    private def self.resolve_body(data : String?) : String?
      return nil unless data
      return data unless data.starts_with?("@")
      path = data[1..]
      raise "Body file path is missing" if path.empty?
      File.read(path)
    end

    # Execute an HTTP request with optional redirect handling.
    private def self.request_with_redirects(method : String,
                                            url : String,
                                            headers : HTTP::Headers,
                                            body : String?,
                                            follow_redirects : Bool,
                                            max_redirects : Int32) : HTTP::Client::Response
      redirects = 0
      current_url = url
      current_method = method
      current_body = body

      loop do
        response = HTTP::Client.exec(current_method, current_url, headers: headers, body: current_body)
        return response unless follow_redirects && redirect?(response.status_code)
        raise "Redirect missing Location header" unless response.headers["Location"]?
        raise "Too many redirects" if redirects >= max_redirects

        current_url = resolve_redirect(current_url, response.headers["Location"])
        current_method, current_body = redirect_method(current_method, current_body, response.status_code)
        redirects += 1
      end
    end

    # True if *status* is an HTTP redirect response code.
    private def self.redirect?(status : Int32) : Bool
      status == 301 || status == 302 || status == 303 || status == 307 || status == 308
    end

    # Resolve a redirect target against the original URL.
    private def self.resolve_redirect(base : String, location : String) : String
      base_uri = URI.parse(base)
      target = URI.parse(location)
      return target.to_s if target.scheme
      base_uri.resolve(target).to_s
    end

    # Normalize method/body changes for a redirect response.
    private def self.redirect_method(method : String, body : String?, status : Int32) : {String, String?}
      return {method, body} if status == 307 || status == 308
      if status == 303
        return {"GET", nil}
      end
      return {"GET", nil} if method == "POST"
      {method, body}
    end

    # Print response headers for a HEAD request.
    private def self.print_headers(response : HTTP::Client::Response) : Nil
      response.headers.each do |key, value|
        STDOUT.puts "#{key}: #{value}"
      end
    end
  end
end
