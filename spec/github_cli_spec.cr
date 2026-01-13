require "./spec_helper"
require "json"

struct FakeGitHubClient
  include Bootstrap::GitHubCLI::Client

  def fetch_feedback(repo : String, pr_number : Int32, credentials_path : Path, per_page : Int32) : Bootstrap::CodexUtils::PullRequestFeedback
    Bootstrap::CodexUtils::PullRequestFeedback.new(
      review_comments: [Bootstrap::CodexUtils::Comment.new(author: repo, body: pr_number.to_s)],
      issue_comments: [] of Bootstrap::CodexUtils::Comment,
      reviews: [] of Bootstrap::CodexUtils::Comment,
    )
  end

  def create_comment(repo : String, pr_number : Int32, body : String, credentials_path : Path) : String
    "#{repo}/#{pr_number}:#{body}"
  end

  def create_pr(repo : String, title : String, head : String, base : String, body : String, credentials_path : Path) : String
    "#{repo}/#{head}->#{base}:#{title}"
  end
end

describe Bootstrap::GitHubCLI do
  # Specs below
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
    previous = ENV["GITHUB_REPOSITORY"]?
    begin
      ENV["GITHUB_REPOSITORY"] = "org/repo"
      output = IO::Memory.new
      Bootstrap::GitHubCLI.run_pr_feedback(["--pr", "1"], client: FakeGitHubClient.new, io: output).should eq 0
      JSON.parse(output.to_s)["review_comments"].as_a.first["author"].as_s.should eq "org/repo"
    ensure
      if previous
        ENV["GITHUB_REPOSITORY"] = previous
      else
        ENV.delete("GITHUB_REPOSITORY")
      end
    end
  end

  it "runs github-pr-comment and prints the comment url" do
    previous = ENV["GITHUB_REPOSITORY"]?
    begin
      ENV["GITHUB_REPOSITORY"] = "org/repo"
      output = IO::Memory.new
      Bootstrap::GitHubCLI.run_pr_comment(["--pr", "2", "--body", "hi"], client: FakeGitHubClient.new, io: output).should eq 0
      output.to_s.lines.last?.try(&.chomp).should eq "org/repo/2:hi"
    ensure
      if previous
        ENV["GITHUB_REPOSITORY"] = previous
      else
        ENV.delete("GITHUB_REPOSITORY")
      end
    end
  end

  it "runs github-pr-create and prints the pr url" do
    previous = ENV["GITHUB_REPOSITORY"]?
    begin
      ENV["GITHUB_REPOSITORY"] = "org/repo"
      output = IO::Memory.new
      Bootstrap::GitHubCLI.run_pr_create(["--title", "t", "--head", "h"], client: FakeGitHubClient.new, io: output).should eq 0
      output.to_s.lines.last?.try(&.chomp).should eq "org/repo/h->master:t"
    ensure
      if previous
        ENV["GITHUB_REPOSITORY"] = previous
      else
        ENV.delete("GITHUB_REPOSITORY")
      end
    end
  end
end
