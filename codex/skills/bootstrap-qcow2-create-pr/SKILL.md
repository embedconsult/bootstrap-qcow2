---
name: bootstrap-qcow2-create-pr
description: Create or update GitHub pull requests for bootstrap-qcow2 using the in-repo Crystal helper Bootstrap::CodexUtils.create_pull_request (no gh/CLI dependencies). Use when automating PR creation from inside the container or sysroot namespace.
---

# Create a PR using `Bootstrap::CodexUtils`

Use the in-repo helper to create PRs via the GitHub REST API without relying on `gh`.

## Preconditions

- You have a branch pushed to `origin` (e.g. `codex/my-branch`).
- A GitHub token exists in `/work/.git-credentials` (or pass an explicit path to `create_pull_request`).

## Create the PR

From the repo root (`/work/bootstrap-qcow2` when live-bound):

```sh
CRYSTAL_CACHE_DIR=/tmp/crystal_cache crystal eval '
  require "./src/codex_utils"
  puts Bootstrap::CodexUtils.create_pull_request(
    "embedconsult/bootstrap-qcow2",
    "PR title",
    "codex/my-branch",
    "master",
    "PR body text",
    Path["../.git-credentials"]
  )
'
```

## Notes

- If the API call fails, the helper raises with the HTTP status/body to copy into debugging output.
- Updating an existing PR body/title requires a PATCH request; reuse the same token/headers pattern (see `src/codex_utils.cr`).
