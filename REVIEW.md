# Review: Changes Since `my-fixes` Branch

**Branch:** `revamp-of-my-fixes` vs `my-fixes`
**Scope:** 69 commits, 31 files changed, +2908 / -3168 lines
**Date:** 2026-02-09

---

## 1. Summary of Changes

The `revamp-of-my-fixes` branch is a substantial refactoring of the sysroot build
pipeline. The core change is extracting a monolithic runner/builder design into
focused, single-responsibility modules:

| New/Major File | Lines | Purpose |
|---|---|---|
| `src/step_runner.cr` | +574 | Individual build-step execution (download, extract, patch, build) |
| `src/patch_applier.cr` | +395 | Pure-Crystal unified diff patch applier |
| `src/tar_writer.cr` | +196 | Gzipped tarball writer |
| `src/sysroot_runner.cr` | net -778 | Slimmed orchestration layer |
| `src/sysroot_builder.cr` | net -580 | Plan generation focused |
| `src/sysroot_build_state.cr` | net -155 | Persistence/resume state rework |
| `src/sysroot_workspace.cr` | refactored | Namespace-aware path management |

Additional changes: CI workflow updated to build a sysroot workspace + upload
artifact instead of the old chroot test, `CLAUDE.md` added, and various bug-fix
commits for LD_LIBRARY_PATH, report paths, and resume semantics.

---

## 2. Open PRs Evaluated Against Stated Goals

### PR #93 — "Simplify all the Codex mess" (`revamp-of-my-fixes` → `my-fixes`)
**Status:** Open, 70 commits, 31 files, +2908/-3168
**No description provided.**

This is the umbrella PR that aggregates all work. As a simplification effort, it
partially succeeds: the extraction of `StepRunner`, `PatchApplier`, and
`TarWriter` genuinely reduces complexity in the runner and builder. However,
several pieces remain incomplete (see Critical Issues below), and the commit
history is messy with many WIP/merge/revert commits that obscure the intent. The
stated goal of "simplifying the Codex mess" is only partly achieved because:
- Multiple commented-out code blocks remain throughout `sysroot_runner.cr`
- The `run_plan(state : SysrootBuildState, ...)` overload is entirely
  non-functional (body commented out)
- `run_status` CLI command is entirely commented out
- Specs reference methods (`load_or_init`, `load`) that don't exist

**Verdict: Architecturally sound refactoring, but NOT merge-ready due to
compilation bugs and incomplete methods.**

---

### PR #111 — "Restore persisted SysrootBuildState, add specs, and allow explicit report_dir for run_steps"
**Status:** Open, 2 commits, 7 files, +136/-60
**Target:** `revamp-of-my-fixes`

**Stated goals:**
1. Restore persisted progress during `SysrootBuildState` initialization
2. Track overrides digest changes for resume correctness
3. Add specs for persistence and resume semantics
4. Allow explicit `report_dir` parameter in `run_steps`

**Evaluation:**
- The PR description acknowledges the test suite **does not pass** — it reports
  `undefined constant SysrootBuildstate` (the typo at `sysroot_runner.cr:67`)
- The PR adds the `load_or_init` and `load` class methods that specs depend on,
  but the base branch (`revamp-of-my-fixes`) HEAD still doesn't have them
- The PR correctly adds a `restore_from` helper and digest-based override
  tracking — this is needed functionality
- **This PR directly addresses the most critical gap** in the revamp, but itself
  has a known compile error it cannot fix (the typo is in the base branch)

**Verdict: Right intent, blocks on bugs in revamp-of-my-fixes itself.**

---

### PR #94 — "Normalize sysroot plan paths and runner dry-run output"
**Status:** Open, 10 commits, 21 files, +927/-833
**Target:** `revamp-of-my-fixes`

**Stated goals:**
1. Make plan namespace-agnostic so sysroot-runner can replay regardless of
   current namespace
2. Move execution semantics into StepRunner
3. Give `sysroot-runner --dry-run` the ability to print StepRunner payloads

**Evaluation:**
- This is a predecessor PR that was partially superseded by work merged directly
  into `revamp-of-my-fixes`
- Many of its changes (workspace normalization, StepRunner extraction) already
  landed in the base branch via other merges
- The dry-run JSON payload feature appears to be partially present
- **Likely stale** — last updated 2026-02-05, 4 days before current HEAD

**Verdict: Probably superseded. Should be diffed against current HEAD to
determine if any unique changes remain, or closed.**

---

### PR #96 — "Codex/fix sysroot builder plan generation 48u3a9"
**Status:** Open, 14 commits, 21 files, +952/-1309
**Target:** `revamp-of-my-fixes`
**No description provided.**

**Evaluation:**
- This is the same branch as merged PR #95 ("Refactor Sysroot workspace, phase
  schema, and runner/step tooling"), which was already merged into
  `revamp-of-my-fixes`
- Shares branch name `codex/fix-sysroot-builder-plan-generation-48u3a9`
- **Stale/duplicate** — the work landed via PR #95

**Verdict: Should be closed. Work already merged.**

---

### PR #92 — "Add outer-rootfs marker override and stabilize sysroot-runner defaults spec"
**Status:** Open, 1 commit, 5 files, +112/-24
**Target:** `my-fixes` (not revamp-of-my-fixes)

**Stated goals:**
1. Allow `BQ2_OUTER_ROOTFS_MARKER` env override for test environments
2. Make sysroot-runner defaults spec deterministic in CI

**Evaluation:**
- Clean, focused PR with passing tests (88 examples, 0 failures)
- Targets `my-fixes` directly, not the revamp branch
- The functionality (env-based marker override) is a legitimate testing
  improvement
- However, with PR #93 pending, merging to `my-fixes` and then having #93
  overwrite it could cause conflicts

**Verdict: Good change, but should probably be retargeted to
`revamp-of-my-fixes` and rebased to avoid conflicts with PR #93.**

---

## 3. Critical Issues Blocking Merge of PR #93

### Bug 1: Typo causes compilation error
**File:** `src/sysroot_runner.cr:67`
```crystal
state ||= SysrootBuildstate.new(workspace: workspace)
#                   ^ should be SysrootBuildState (capital S)
```

### Bug 2: Undefined variable
**File:** `src/sysroot_runner.cr:68`
```crystal
plan = state_for_plan.load_plan(Path[plan_path])
#      ^^^^^^^^^^^^^^ should be `state`
```

### Bug 3: Empty method body
**File:** `src/sysroot_runner.cr:84-108`
The `run_plan(state : SysrootBuildState, ...)` overload has its entire body
commented out. This is called from the CLI entry point at line 248-260. Any
invocation via the `sysroot-runner` command will silently do nothing.

### Bug 4: Missing class methods
Specs reference `SysrootBuildState.load_or_init()` and
`SysrootBuildState.load()` (8+ call sites across 2 spec files), but neither
method exists in `src/sysroot_build_state.cr`. PR #111 would add these, but
hasn't been merged.

### Bug 5: `run_status` entirely commented out
**File:** `src/sysroot_runner.cr:288-299`
The `sysroot-status` subcommand body is entirely commented out and non-functional.

---

## 4. Code Quality Observations

### Positive
- **StepRunner** is well-designed: clean strategy dispatch, SHA256 verification,
  environment merging, and patch delegation
- **PatchApplier** is a solid pure-Crystal implementation with tolerance-based
  hunk matching and already-applied detection
- **TarWriter** fills a real need for the pipeline
- Test coverage for the new modules (patch_applier, step_runner) is reasonable
- The `--no-codegen` build succeeds, indicating type-level soundness for the
  code paths that Crystal can statically verify

### Concerning
- 8+ TODO/WIP comments scattered across key files
- Multiple large blocks of commented-out code in `sysroot_runner.cr` (lines
  95-107, 238-244, 253, 257, 288-299)
- Commit history includes many merge commits, reverts ("Revert codex stupidity",
  "codex is dumb, a lot"), and WIP commits suggesting iteration-by-crisis
  development
- The `sysroot_all_resume.cr` has TODO stubs returning `0` or calling
  `CLI.run_help` as placeholder
- Progress invalidation on overrides change is commented out with a TODO
  (`sysroot_build_state.cr:90`)

### User-Reported Issue
The PR #93 author (jadonk) reported that LD_LIBRARY_PATH isn't set properly for
building `shards` in the "sysroot-from-alpine" phase, and that the overrides
system is too rigid to easily adjust it. A hack fix was committed (`75d6c53`)
and a proper warning was added (#109), but the underlying flexibility issue
remains.

---

## 5. Recommendations

### Immediate (before merging PR #93)
1. **Fix the 2 typos** at `sysroot_runner.cr:67-68` — these are outright bugs
2. **Uncomment or implement** the `run_plan(state:...)` overload body — this
   breaks the primary CLI entry point
3. **Merge PR #111** first (or cherry-pick its `load_or_init`/`load` additions)
   to unbreak the specs
4. **Remove dead commented-out code** or convert to clear TODO issues

### Short-term
5. **Close PRs #94 and #96** as superseded
6. **Retarget PR #92** to `revamp-of-my-fixes`
7. **Squash or rebase** the 69-commit history before merging to `my-fixes` for
   readable history

### Medium-term
8. Resolve the LD_LIBRARY_PATH/overrides flexibility issue properly
9. Complete the `sysroot-status` subcommand
10. Address the 8+ TODO comments
11. Complete the `sysroot_all_resume.cr` stubs

---

## 6. Merged PR Recap (closed, into `revamp-of-my-fixes`)

| PR | Title | Key Change |
|---|---|---|
| #95 | Refactor Sysroot workspace, phase schema, and runner/step tooling | Major extraction — StepRunner, workspace refactor |
| #97 | Add Crystal PatchApplier and integrate into StepRunner | New patch_applier.cr |
| #98 | Refactor sysroot workspace/state wiring and runner workflows | State/runner plumbing |
| #100 | Fix patch hunk offset handling in PatchApplier | Bug fix |
| #101 | Fix host-setup source paths for sysroot downloads | Bug fix |
| #102 | Add spinner feedback for sysroot downloads/extracts | UX improvement |
| #103 | Sysroot: default to running all phases | Runner behavior |
| #104 | sysroot-runner: only create DESTDIR root | Bug fix |
| #105 | Remove obsolete LLVM SmallVector patch | Cleanup |
| #106 | Preserve sysroot state when overrides change | State management |
| #107 | Add --invalidate-overrides option | CLI feature |
| #108 | Fix sysroot failure report paths across namespaces | Bug fix |
| #109 | Warn on sysroot PATH without LD_LIBRARY_PATH | Warning improvement |
| #110 | Skip extracting sources on resume when build dirs exist | Resume optimization |
| #112 | Add CLAUDE.md | Documentation |
