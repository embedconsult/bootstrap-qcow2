require "./spec_helper"
require "json"

describe Bootstrap::GitHubCLI do
  it "parses repo from common git remote url formats" do
    Bootstrap::GitHubCLI.repo_from_url?("https://github.com/embedconsult/bootstrap-qcow2.git").should eq "embedconsult/bootstrap-qcow2"
    Bootstrap::GitHubCLI.repo_from_url?("git@github.com:embedconsult/bootstrap-qcow2.git").should eq "embedconsult/bootstrap-qcow2"
    Bootstrap::GitHubCLI.repo_from_url?("https://x-access-token:token@github.com/embedconsult/bootstrap-qcow2.git").should eq "embedconsult/bootstrap-qcow2"
    Bootstrap::GitHubCLI.repo_from_url?("not-a-github-url").should be_nil
  end

  it "infers repo from .git/config remote origin url" do
    with_tempdir do |dir|
      previous_gh = ENV["GITHUB_REPOSITORY"]?
      previous_bq2 = ENV["BQ2_GITHUB_REPO"]?
      begin
        ENV.delete("GITHUB_REPOSITORY")
        ENV.delete("BQ2_GITHUB_REPO")

        git_dir = dir / ".git"
        FileUtils.mkdir_p(git_dir)
        File.write(
          git_dir / "config",
          <<-CFG
          [remote "origin"]
            url = https://github.com/embedconsult/bootstrap-qcow2.git
          CFG
        )
        Bootstrap::GitHubCLI.infer_repo(dir).should eq "embedconsult/bootstrap-qcow2"
      ensure
        if previous_gh
          ENV["GITHUB_REPOSITORY"] = previous_gh
        else
          ENV.delete("GITHUB_REPOSITORY")
        end
        if previous_bq2
          ENV["BQ2_GITHUB_REPO"] = previous_bq2
        else
          ENV.delete("BQ2_GITHUB_REPO")
        end
      end
    end
  end

  it "runs github-pr-feedback and prints JSON" do
    token = "github_pat_TEST"
    credentials = "https://x-access-token:#{token}@github.com"
    file = File.tempfile("git-credentials")
    begin
      file.print(credentials)
      file.flush

      get_stub = ->(url : String, headers : HTTP::Headers) do
        case url
        when "https://api.github.com/repos/org/repo/pulls/1/comments?per_page=100&page=1"
          HTTP::Client::Response.new(200, [{"user" => {"login" => "reviewer"}, "body" => "inline", "path" => "src/main.cr"}].to_json)
        when "https://api.github.com/repos/org/repo/issues/1/comments?per_page=100&page=1"
          HTTP::Client::Response.new(200, [{"user" => {"login" => "commenter"}, "body" => "thread"}].to_json)
        when "https://api.github.com/repos/org/repo/pulls/1/reviews?per_page=100&page=1"
          HTTP::Client::Response.new(200, [{"user" => {"login" => "approver"}, "body" => "LGTM", "state" => "APPROVED"}].to_json)
        else
          HTTP::Client::Response.new(404, {"error" => "unexpected url #{url}"}.to_json)
        end
      end

      output = IO::Memory.new
      Bootstrap::GitHubCLI.run_pr_feedback(
        ["--repo", "org/repo", "--pr", "1", "--credentials", file.path, "--pretty"],
        io: output,
        http_get: get_stub
      ).should eq 0

      parsed = JSON.parse(output.to_s)
      parsed["review_comments"].as_a.first["author"].as_s.should eq "reviewer"
    ensure
      file.close
    end
  end

  it "runs github-pr-comment and prints the comment url" do
    token = "github_pat_TEST"
    credentials = "https://x-access-token:#{token}@github.com"
    file = File.tempfile("git-credentials")
    begin
      file.print(credentials)
      file.flush

      post_stub = ->(url : String, headers : HTTP::Headers, body : String) do
        url.should eq "https://api.github.com/repos/org/repo/issues/2/comments"
        headers["Authorization"].should eq "token #{token}"
        JSON.parse(body)["body"].as_s.should eq "hi"
        HTTP::Client::Response.new(201, {"html_url" => "https://example.com/comment"}.to_json)
      end

      output = IO::Memory.new
      Bootstrap::GitHubCLI.run_pr_comment(
        ["--repo", "org/repo", "--pr", "2", "--body", "hi", "--credentials", file.path],
        io: output,
        http_post: post_stub
      ).should eq 0

      output.to_s.lines.last?.try(&.chomp).should eq "https://example.com/comment"
    ensure
      file.close
    end
  end

  it "runs github-pr-create and prints the pr url" do
    token = "github_pat_TEST"
    credentials = "https://x-access-token:#{token}@github.com"
    file = File.tempfile("git-credentials")
    begin
      file.print(credentials)
      file.flush

      post_stub = ->(url : String, headers : HTTP::Headers, body : String) do
        url.should eq "https://api.github.com/repos/org/repo/pulls"
        headers["Authorization"].should eq "token #{token}"
        JSON.parse(body)["title"].as_s.should eq "t"
        JSON.parse(body)["head"].as_s.should eq "h"
        JSON.parse(body)["base"].as_s.should eq "master"
        HTTP::Client::Response.new(201, {"html_url" => "https://example.com/pr"}.to_json)
      end

      output = IO::Memory.new
      Bootstrap::GitHubCLI.run_pr_create(
        ["--repo", "org/repo", "--title", "t", "--head", "h", "--credentials", file.path],
        io: output,
        http_post: post_stub
      ).should eq 0

      output.to_s.lines.last?.try(&.chomp).should eq "https://example.com/pr"
    ensure
      file.close
    end
  end
end
