require "http/client"
require "json"
require "uri"

module Bootstrap
  # Utility helpers for interacting with Codex-adjacent services.
  module CodexUtils
    # Extracts a GitHub token from a git-credentials file. Supports the standard
    # x-access-token entry format used by the CLI.
    #
    # Raises when the credentials file is missing or no token is present.
    def self.extract_github_token(credentials_path : Path = Path["../.git-credentials"]) : String
      content = File.read(credentials_path)
      if match = content.match(/x-access-token:([^@]+)@github\.com/)
        return match[1]
      end
      if match = content.match(/github_pat_[A-Za-z0-9_]+/)
        return match[0]
      end
      raise "GitHub token not found in #{credentials_path}"
    rescue File::NotFoundError
      raise "GitHub credentials not found at #{credentials_path}"
    end

    # Creates a pull request in *repo* (owner/name) using the provided fields.
    # Returns the PR HTML URL on success and raises on API errors.
    def self.create_pull_request(repo : String,
                                 title : String,
                                 head : String,
                                 base : String,
                                 body : String,
                                 credentials_path : Path = Path["../.git-credentials"],
                                 http_post : Proc(String, HTTP::Headers, String, HTTP::Client::Response)? = nil) : String
      token = extract_github_token(credentials_path)

      payload = {
        "title" => title,
        "head"  => head,
        "base"  => base,
        "body"  => body,
      }.to_json

      headers = HTTP::Headers{
        "User-Agent"    => "codex-cli",
        "Authorization" => "token #{token}",
        "Accept"        => "application/vnd.github+json",
      }

      sender = http_post || ->(url : String, headers : HTTP::Headers, body : String) { HTTP::Client.post(url, headers: headers, body: body) }
      response = sender.call("https://api.github.com/repos/#{repo}/pulls", headers, payload)

      unless (200..299).includes?(response.status_code)
        raise "GitHub PR creation failed (status #{response.status_code}): #{response.body}"
      end

      data = JSON.parse(response.body)
      data["html_url"].as_s
    end
  end
end
