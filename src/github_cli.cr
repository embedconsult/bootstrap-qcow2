require "json"
require "option_parser"
require "path"
require "./cli"
require "./codex_utils"

module Bootstrap
  # GitHub-oriented CLI helpers built on `Bootstrap::CodexUtils`.
  module GitHubCLI
    DEFAULT_BASE = "master"

    # Returns `owner/repo` when *url* is a GitHub remote URL.
    def self.repo_from_url?(url : String) : String?
      if match = url.match(/github\.com[:\/]([^\/]+)\/([^\/]+?)(?:\.git)?$/)
        return "#{match[1]}/#{match[2]}"
      end
      nil
    end

    # Attempt to infer an `owner/repo` value from the working directory.
    #
    # Checks the following sources in order:
    # - `GITHUB_REPOSITORY` (Actions-compatible)
    # - `BQ2_GITHUB_REPO`
    # - `.git/config` remote "origin" URL (walking up from the current directory)
    def self.infer_repo(start : Path = Path[Dir.current]) : String?
      return ENV["GITHUB_REPOSITORY"]? if ENV["GITHUB_REPOSITORY"]?
      return ENV["BQ2_GITHUB_REPO"]? if ENV["BQ2_GITHUB_REPO"]?

      config = find_git_config(start)
      return nil unless config
      infer_repo_from_git_config(config)
    end

    # Fetch PR feedback and print as JSON.
    def self.run_pr_feedback(args : Array(String),
                             io : IO = STDOUT,
                             http_get : Proc(String, HTTP::Headers, HTTP::Client::Response)? = nil) : Int32
      repo = infer_repo
      pr_number : Int32? = nil
      pretty = false
      out_path : String? = nil
      credentials_path = File.exists?("/work/.git-credentials") ? Path["/work/.git-credentials"] : Path["../.git-credentials"]
      per_page = 100

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 github-pr-feedback [options]") do |p|
        p.on("--repo REPO", "GitHub repo (owner/name). Defaults from repo/env when possible") { |val| repo = val }
        p.on("--pr NUM", "Pull request number") { |val| pr_number = val.to_i }
        p.on("--credentials PATH", "GitHub credentials file (default: #{credentials_path})") { |val| credentials_path = Path[val] }
        p.on("--per-page N", "GitHub API page size (default: #{per_page})") { |val| per_page = val.to_i }
        p.on("--pretty", "Pretty-print JSON output") { pretty = true }
        p.on("--out PATH", "Write JSON to PATH instead of stdout") { |val| out_path = val }
      end
      return CLI.print_help(parser) if help

      raise "--pr is required" unless pr_number
      raise "--repo is required (could not infer it)" unless repo
      repo_name = repo.not_nil!

      feedback = CodexUtils.fetch_pull_request_feedback(
        repo_name,
        pr_number.not_nil!,
        credentials_path: credentials_path,
        per_page: per_page,
        http_get: http_get
      )
      json = pretty ? feedback.to_pretty_json : feedback.to_json
      if output_path = out_path
        File.write(output_path, json)
      else
        io.puts json
      end
      0
    end

    # Post a PR thread comment (issue comment).
    def self.run_pr_comment(args : Array(String),
                            io : IO = STDOUT,
                            http_post : Proc(String, HTTP::Headers, String, HTTP::Client::Response)? = nil) : Int32
      repo = infer_repo
      pr_number : Int32? = nil
      body : String? = nil
      body_file : String? = nil
      credentials_path = File.exists?("/work/.git-credentials") ? Path["/work/.git-credentials"] : Path["../.git-credentials"]

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 github-pr-comment [options]") do |p|
        p.on("--repo REPO", "GitHub repo (owner/name). Defaults from repo/env when possible") { |val| repo = val }
        p.on("--pr NUM", "Pull request number") { |val| pr_number = val.to_i }
        p.on("--body TEXT", "Comment body") { |val| body = val }
        p.on("--body-file PATH", "Read comment body from PATH") { |val| body_file = val }
        p.on("--credentials PATH", "GitHub credentials file (default: #{credentials_path})") { |val| credentials_path = Path[val] }
      end
      return CLI.print_help(parser) if help

      raise "--pr is required" unless pr_number
      raise "--repo is required (could not infer it)" unless repo
      repo_name = repo.not_nil!

      if body_file
        body = File.read(body_file.not_nil!)
      end
      raise "Missing comment body (use --body or --body-file)" unless body

      url = CodexUtils.create_issue_comment(
        repo_name,
        pr_number.not_nil!,
        body.not_nil!,
        credentials_path: credentials_path,
        http_post: http_post
      )
      io.puts url unless url.empty?
      0
    end

    # Create a pull request on GitHub.
    def self.run_pr_create(args : Array(String),
                           io : IO = STDOUT,
                           http_post : Proc(String, HTTP::Headers, String, HTTP::Client::Response)? = nil) : Int32
      repo = infer_repo
      title : String? = nil
      head : String? = nil
      base = DEFAULT_BASE
      body : String? = nil
      body_file : String? = nil
      credentials_path = File.exists?("/work/.git-credentials") ? Path["/work/.git-credentials"] : Path["../.git-credentials"]

      parser, _remaining, help = CLI.parse(args, "Usage: bq2 github-pr-create [options]") do |p|
        p.on("--repo REPO", "GitHub repo (owner/name). Defaults from repo/env when possible") { |val| repo = val }
        p.on("--title TITLE", "PR title") { |val| title = val }
        p.on("--head BRANCH", "Head branch (e.g. codex/my-branch)") { |val| head = val }
        p.on("--base BRANCH", "Base branch (default: #{base})") { |val| base = val }
        p.on("--body TEXT", "PR body") { |val| body = val }
        p.on("--body-file PATH", "Read PR body from PATH") { |val| body_file = val }
        p.on("--credentials PATH", "GitHub credentials file (default: #{credentials_path})") { |val| credentials_path = Path[val] }
      end
      return CLI.print_help(parser) if help

      raise "--repo is required (could not infer it)" unless repo
      raise "--title is required" unless title
      raise "--head is required" unless head
      repo_name = repo.not_nil!

      if body_file
        body = File.read(body_file.not_nil!)
      end
      body ||= ""

      url = CodexUtils.create_pull_request(
        repo_name,
        title.not_nil!,
        head.not_nil!,
        base,
        body.not_nil!,
        credentials_path: credentials_path,
        http_post: http_post
      )
      io.puts url
      0
    end

    private def self.find_git_config(start : Path) : Path?
      current = start.expand
      loop do
        candidate = current / ".git/config"
        return candidate if File.exists?(candidate)
        break if current == current.parent
        current = current.parent
      end
      nil
    end

    private def self.infer_repo_from_git_config(config_path : Path) : String?
      in_origin = false
      File.read_lines(config_path).each do |line|
        stripped = line.strip
        if stripped.starts_with?("[") && stripped.ends_with?("]")
          in_origin = stripped == %[ [remote "origin"] ].strip
          next
        end
        next unless in_origin
        next unless stripped.starts_with?("url")
        _key, value = stripped.split("=", 2)
        next unless value
        url = value.strip
        return repo_from_url?(url)
      end
      nil
    rescue ex : File::Error
      nil
    end
  end
end
