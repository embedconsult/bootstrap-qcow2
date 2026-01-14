require "./spec_helper"
require "json"

describe Bootstrap::CodexUtils do
  it "extracts the GitHub token from git-credentials" do
    token = "github_pat_TEST"
    credentials = "https://x-access-token:#{token}@github.com"
    file = File.tempfile("git-credentials")
    begin
      file.print(credentials)
      file.flush

      Bootstrap::CodexUtils.extract_github_token(Path[file.path]).should eq token
    ensure
      file.close
    end
  end

  it "creates a pull request and returns the URL" do
    token = "github_pat_TEST"
    credentials = "https://x-access-token:#{token}@github.com"
    file = File.tempfile("git-credentials")
    begin
      file.print(credentials)
      file.flush

      response_body = {"html_url" => "https://github.com/org/repo/pull/1"}.to_json
      captured_request = nil
      post_stub = ->(url : String, headers : HTTP::Headers, body : String) do
        captured_request = {url, headers, body}
        HTTP::Client::Response.new(201, response_body)
      end

      url = Bootstrap::CodexUtils.create_pull_request(
        "org/repo",
        "title",
        "head-branch",
        "main",
        "body",
        credentials_path: Path[file.path],
        http_post: post_stub
      )

      url.should eq "https://github.com/org/repo/pull/1"
      request = captured_request.not_nil!
      request[0].should eq "https://api.github.com/repos/org/repo/pulls"
      request[1]["Authorization"].should eq "token #{token}"
      JSON.parse(request[2])["title"].as_s.should eq "title"
    ensure
      file.close
    end
  end

  it "creates an issue comment and returns the URL" do
    token = "github_pat_TEST"
    credentials = "https://x-access-token:#{token}@github.com"
    file = File.tempfile("git-credentials")
    begin
      file.print(credentials)
      file.flush

      response_body = {"html_url" => "https://github.com/org/repo/issues/40#issuecomment-1"}.to_json
      captured_request = nil
      post_stub = ->(url : String, headers : HTTP::Headers, body : String) do
        captured_request = {url, headers, body}
        HTTP::Client::Response.new(201, response_body)
      end

      url = Bootstrap::CodexUtils.create_issue_comment(
        "org/repo",
        40,
        "hello",
        credentials_path: Path[file.path],
        http_post: post_stub
      )

      url.should eq "https://github.com/org/repo/issues/40#issuecomment-1"
      request = captured_request.not_nil!
      request[0].should eq "https://api.github.com/repos/org/repo/issues/40/comments"
      request[1]["Authorization"].should eq "token #{token}"
      JSON.parse(request[2])["body"].as_s.should eq "hello"
    ensure
      file.close
    end
  end

  it "fetches pull request feedback via the GitHub API" do
    token = "github_pat_TEST"
    credentials = "https://x-access-token:#{token}@github.com"
    file = File.tempfile("git-credentials")
    begin
      file.print(credentials)
      file.flush

      calls = [] of Tuple(String, HTTP::Headers)
      get_stub = ->(url : String, headers : HTTP::Headers) do
        calls << {url, headers}
        case url
        when "https://api.github.com/repos/org/repo/pulls/40/comments?per_page=1&page=1"
          HTTP::Client::Response.new(200, [
            {"user" => {"login" => "reviewer"}, "body" => "inline", "path" => "src/main.cr", "created_at" => "t"},
          ].to_json)
        when "https://api.github.com/repos/org/repo/pulls/40/comments?per_page=1&page=2"
          HTTP::Client::Response.new(200, [
            {"user" => {"login" => "reviewer2"}, "body" => "inline2", "path" => "src/other.cr", "created_at" => "t1"},
          ].to_json)
        when "https://api.github.com/repos/org/repo/pulls/40/comments?per_page=1&page=3"
          HTTP::Client::Response.new(200, "[]")
        when "https://api.github.com/repos/org/repo/issues/40/comments?per_page=1&page=1"
          HTTP::Client::Response.new(200, [
            {"user" => {"login" => "commenter"}, "body" => "thread", "created_at" => "t2"},
          ].to_json)
        when "https://api.github.com/repos/org/repo/issues/40/comments?per_page=1&page=2"
          HTTP::Client::Response.new(200, [
            {"user" => {"login" => "commenter2"}, "body" => "thread2", "created_at" => "t3"},
          ].to_json)
        when "https://api.github.com/repos/org/repo/issues/40/comments?per_page=1&page=3"
          HTTP::Client::Response.new(200, "[]")
        when "https://api.github.com/repos/org/repo/pulls/40/reviews?per_page=1&page=1"
          HTTP::Client::Response.new(200, [
            {"user" => {"login" => "approver"}, "body" => "LGTM", "state" => "APPROVED", "submitted_at" => "t3"},
          ].to_json)
        when "https://api.github.com/repos/org/repo/pulls/40/reviews?per_page=1&page=2"
          HTTP::Client::Response.new(200, [
            {"user" => {"login" => "approver2"}, "body" => "OK", "state" => "COMMENTED", "submitted_at" => "t4"},
          ].to_json)
        when "https://api.github.com/repos/org/repo/pulls/40/reviews?per_page=1&page=3"
          HTTP::Client::Response.new(200, "[]")
        else
          HTTP::Client::Response.new(404, {"error" => "unexpected url #{url}"}.to_json)
        end
      end

      feedback = Bootstrap::CodexUtils.fetch_pull_request_feedback(
        "org/repo",
        40,
        credentials_path: Path[file.path],
        per_page: 1,
        http_get: get_stub
      )

      feedback.review_comments.size.should eq 2
      feedback.review_comments.first.author.should eq "reviewer"
      feedback.review_comments.first.path.should eq "src/main.cr"

      feedback.issue_comments.size.should eq 2
      feedback.issue_comments.first.author.should eq "commenter"

      feedback.reviews.size.should eq 2
      feedback.reviews.first.state.should eq "APPROVED"

      calls.size.should eq 9
      calls.each do |(_url, headers)|
        headers["Authorization"].should eq "token #{token}"
      end
    ensure
      file.close
    end
  end
end
