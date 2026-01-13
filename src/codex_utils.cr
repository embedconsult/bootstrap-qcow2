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

    # Aggregated view of pull request feedback across the conversation thread,
    # inline review comments, and submitted reviews.
    struct PullRequestFeedback
      getter review_comments : Array(Comment)
      getter issue_comments : Array(Comment)
      getter reviews : Array(Comment)

      def initialize(@review_comments : Array(Comment) = [] of Comment,
                     @issue_comments : Array(Comment) = [] of Comment,
                     @reviews : Array(Comment) = [] of Comment)
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "review_comments" { json.array { @review_comments.each { |item| item.to_json(json) } } }
          json.field "issue_comments" { json.array { @issue_comments.each { |item| item.to_json(json) } } }
          json.field "reviews" { json.array { @reviews.each { |item| item.to_json(json) } } }
        end
      end

      def to_pretty_json : String
        JSON.parse(to_json).to_pretty_json
      end
    end

    # Summarized GitHub comment/review entry.
    struct Comment
      getter author : String
      getter body : String
      getter created_at : String?
      getter path : String?
      getter state : String?

      def initialize(@author : String,
                     @body : String,
                     @created_at : String? = nil,
                     @path : String? = nil,
                     @state : String? = nil)
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "author", @author
          json.field "body", @body
          json.field "created_at", @created_at if @created_at
          json.field "path", @path if @path
          json.field "state", @state if @state
        end
      end
    end

    # Fetch all comment/review feedback for a pull request.
    def self.fetch_pull_request_feedback(repo : String,
                                         pr_number : Int32,
                                         credentials_path : Path = Path["../.git-credentials"],
                                         http_get : Proc(String, HTTP::Headers, HTTP::Client::Response)? = nil) : PullRequestFeedback
      token = extract_github_token(credentials_path)
      headers = github_headers(token)
      get = http_get || ->(url : String, headers : HTTP::Headers) { HTTP::Client.get(url, headers: headers) }

      review_comments = fetch_pull_request_review_comments(repo, pr_number, headers, get)
      issue_comments = fetch_pull_request_issue_comments(repo, pr_number, headers, get)
      reviews = fetch_pull_request_reviews(repo, pr_number, headers, get)

      PullRequestFeedback.new(
        review_comments: review_comments,
        issue_comments: issue_comments,
        reviews: reviews,
      )
    end

    private def self.github_headers(token : String) : HTTP::Headers
      HTTP::Headers{
        "User-Agent"    => "codex-cli",
        "Authorization" => "token #{token}",
        "Accept"        => "application/vnd.github+json",
      }
    end

    private def self.fetch_pull_request_review_comments(repo : String,
                                                        pr_number : Int32,
                                                        headers : HTTP::Headers,
                                                        http_get : Proc(String, HTTP::Headers, HTTP::Client::Response)) : Array(Comment)
      url = "https://api.github.com/repos/#{repo}/pulls/#{pr_number}/comments"
      response = http_get.call(url, headers)
      raise "GitHub API request failed (status #{response.status_code}): #{response.body}" unless (200..299).includes?(response.status_code)
      JSON.parse(response.body).as_a.map do |item|
        Comment.new(
          author: item["user"]["login"].as_s,
          body: item["body"].as_s,
          created_at: item["created_at"]?.try(&.as_s?),
          path: item["path"]?.try(&.as_s?),
        )
      end
    end

    private def self.fetch_pull_request_issue_comments(repo : String,
                                                       pr_number : Int32,
                                                       headers : HTTP::Headers,
                                                       http_get : Proc(String, HTTP::Headers, HTTP::Client::Response)) : Array(Comment)
      url = "https://api.github.com/repos/#{repo}/issues/#{pr_number}/comments"
      response = http_get.call(url, headers)
      raise "GitHub API request failed (status #{response.status_code}): #{response.body}" unless (200..299).includes?(response.status_code)
      JSON.parse(response.body).as_a.map do |item|
        Comment.new(
          author: item["user"]["login"].as_s,
          body: item["body"].as_s,
          created_at: item["created_at"]?.try(&.as_s?),
        )
      end
    end

    private def self.fetch_pull_request_reviews(repo : String,
                                                pr_number : Int32,
                                                headers : HTTP::Headers,
                                                http_get : Proc(String, HTTP::Headers, HTTP::Client::Response)) : Array(Comment)
      url = "https://api.github.com/repos/#{repo}/pulls/#{pr_number}/reviews"
      response = http_get.call(url, headers)
      raise "GitHub API request failed (status #{response.status_code}): #{response.body}" unless (200..299).includes?(response.status_code)
      JSON.parse(response.body).as_a.map do |item|
        body = item["body"]?.try(&.as_s?) || ""
        Comment.new(
          author: item["user"]["login"].as_s,
          body: body,
          created_at: item["submitted_at"]?.try(&.as_s?),
          state: item["state"]?.try(&.as_s?),
        )
      end
    end
  end
end
