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
end
