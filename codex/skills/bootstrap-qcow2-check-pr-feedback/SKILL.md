---
name: bootstrap-qcow2-check-pr-feedback
description: Fetch and summarize GitHub PR feedback for bootstrap-qcow2 (issue comments, review comments, and reviews) using Bootstrap::CodexUtils, to manually check for new review notes after someone completes a PR review.
---

# Check PR feedback (manual trigger)

Use this after a reviewer finishes leaving comments to pull the latest feedback into the container.

## Fetch feedback

From the repo root:

```sh
CRYSTAL_CACHE_DIR=/tmp/crystal_cache crystal eval '
  require "./src/codex_utils"
  feedback = Bootstrap::CodexUtils.fetch_pull_request_feedback(
    "embedconsult/bootstrap-qcow2",
    42,
    credentials_path: Path["../.git-credentials"],
  )
  puts feedback.to_pretty_json
'
```

## Notes

- Requires GitHub API access; the helper reads the token from `/work/.git-credentials` by default.
- Endpoints queried:
  - `/pulls/:number/comments` (review comments on diffs)
  - `/issues/:number/comments` (PR conversation thread)
  - `/pulls/:number/reviews` (submitted reviews)
