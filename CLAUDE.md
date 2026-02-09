# CLAUDE.md

Quick-reference for Claude Code sessions in this repository.

## Build, test, format

```bash
shards build                    # builds bin/bq2
./bin/bq2 --install             # creates symlinks in bin/
crystal tool format             # format all Crystal files
crystal tool format --check     # verify formatting (CI gate)
crystal spec                    # run all tests
```

CI runs: format check, specs, `shards build`, sysroot workspace generation, artifact upload.

## What this project is

A reproducible disk-image builder written in Crystal. It produces a bootable QCOW2/chroot that can rebuild itself from source. The single busybox-style binary `bq2` dispatches all subcommands (`sysroot-builder`, `sysroot-namespace`, `sysroot-runner`, `curl`, `pkg-config`, `git-remote-https`, etc.).

Primary architecture: **aarch64**. Secondary: x86_64.

## Repository layout

```
src/                  Crystal source (~8k lines); sysroot_builder.cr is the largest file
spec/                 Crystal specs (~16 files)
patches/              Upstream patches organized by package-version
data/                 Dockerfiles, BIOS binaries, CA bundle, genimage config
c/                    Minimal C++ for LLVM bindings (experimental)
codex/                Codex AI agent skills
.github/workflows/    CI (ci.yml) and docs (docs.yml)
```

Key source files:
- `src/main.cr` -- entry point; requires all CLI modules
- `src/cli.cr` -- busybox-style dispatch registry
- `src/sysroot_builder.cr` -- package list, phase specs, workspace prep
- `src/sysroot_runner.cr` -- plan executor inside namespace
- `src/sysroot_namespace.cr` -- rootless user/mount namespace setup
- `src/build_plan.cr` -- BuildPlan/BuildPhase/BuildStep data structures
- `src/tarball.cr` -- download, checksum, and pure-Crystal tar extraction
- `src/patch_applier.cr` -- Crystal-native patch application
- `src/step_runner.cr` -- per-step strategy dispatch (autotools, cmake, etc.)

## Simplification principles

Every change should make this codebase smaller, clearer, or more self-contained. Prefer deleting code over adding it. Prefer inlining over indirection. The right question before any addition is: "can this be removed instead?"

1. **One way to do things.** Eliminate alternate code paths that exist for historical reasons. The build plan + state + runner model is the sole execution path; remove anything that bypasses it (e.g., `SysrootResumeAll` is legacy and should be folded in or deleted).

2. **Small files, small functions.** `sysroot_builder.cr` is 1500+ lines. When touching it, extract coherent sections (package list, LLVM flags, phase env helpers) into focused modules. Do not create new abstractions for one-time operations.

3. **No dead code.** Commented-out blocks, unused methods, backwards-compatibility shims for removed features -- delete them. If something is needed later, git has it.

4. **Crystal over shell.** Any remaining shell-outs (`Process.run("tar", ...)`, `Process.run("patch", ...)`) are candidates for replacement with Crystal implementations. `tarball.cr` already has a pure-Crystal tar reader; `patch_applier.cr` replaces the external `patch` command. Continue this pattern.

5. **Document magic numbers at the declaration site.** Every version constant, configure flag, and URL in `sysroot_builder.cr` should have a brief comment citing the authoritative source or explaining why that value was chosen.

## Reducing external dependencies

The project currently downloads 25+ upstream source tarballs. The long-term trajectory is to reduce this set to the minimum required for a self-hosting Crystal + LLVM environment.

### Near-term targets for removal or replacement

| Dependency | Status | Path forward |
|---|---|---|
| **CMake** | Required by LLVM | Replace with direct Ninja/Makefile generation in Crystal once LLVM build is stable. Track upstream LLVM efforts to reduce CMake dependency. |
| **m4** | Used by autotools packages | Eliminate when autotools packages are replaced with Crystal-driven builds or CMake. |
| **GNU Make** | Build orchestration | Already partially replaced by Crystal step runner. Continue migrating build logic into `step_runner.cr` strategies. |
| **Alpine minirootfs** | Bootstrap seed | Acceptable until self-hosted rootfs is viable. Keep the seed swappable (`@seed` parameter). |
| **Python** | LLVM build dependency | Already patched out (6 LLVM patches disable Python). Maintain these patches on LLVM upgrades. |
| **git** | tools-from-system phase | Replace with Crystal `git-remote-https` + Fossil for version control. |

### Principles for dependency decisions

- Every external package must justify its presence. If Crystal can do the job at acceptable complexity, prefer Crystal.
- When an external package is retained, pin the version, provide a SHA256, and minimize the build surface (disable tests, docs, optional features).
- Source tarballs are cached in `data/sysroot/sources/` and checksummed in `data/sysroot/cache/checksums/`. Never skip verification.
- Move dependency fetching for Crystal shards into a dedicated download phase so `shards install` never requires network during build.

## Reducing build time

Full sysroot builds are dominated by LLVM/Clang compilation. Prioritize changes that shrink LLVM build time or avoid rebuilding it.

### Strategies in priority order

1. **LLVM build scope reduction.** The current config already disables 80+ LLVM tools and all sanitizers/fuzzers. Continue auditing: disable any LLVM component not required by Crystal's compiler or the Clang/LLD toolchain. Each disabled tool saves compilation and link time.

2. **Shared library preference.** Build LLVM/libc++/libunwind as shared libraries (already configured). This reduces link time compared to static builds and avoids redundant code in every linked binary.

3. **Single-architecture LLVM target.** Only build the LLVM backend for the target architecture (`-DLLVM_TARGETS_TO_BUILD=AArch64` or `X86`). Never build "all" targets.

4. **Resume-aware builds.** The build state model (`sysroot-build-state.json`) supports resuming from the last successful step. Ensure all strategies are idempotent so interrupted builds resume correctly without re-running completed steps.

5. **Source caching and skip-on-resume.** Tarball downloads are cached. Source extraction is skipped when build directories already exist (resume mode). Protect this behavior; do not regress it.

6. **Parallel make.** Ensure `MAKEFLAGS=-jN` and `CMAKE_BUILD_PARALLEL_LEVEL` are set appropriately in phase environments. Check that the sysroot and system phases both pass these through.

7. **Host binary build.** Crystal compilation of `bin/bq2` takes ~30s. This is acceptable. Do not add Crystal shards that increase compile time without strong justification. The project has zero shard dependencies by design.

8. **Eliminate redundant rebuilds.** Some packages appear in multiple phases (e.g., musl, busybox, linux-headers in both sysroot and rootfs phases). Verify that rootfs-phase rebuilds are necessary for correctness; if a sysroot-built artifact can be reused, skip the rebuild.

## Code style

- Crystal standard library documentation style for all public methods.
- `crystal tool format` is the authority on formatting.
- Prefer named parameters over positional when a method takes more than 2-3 arguments.
- Use `record` for simple value types. Use `struct` with `JSON::Serializable` for serialized data.
- Tests go in `spec/` mirroring `src/` names. Use `pending` for tests that require namespace/environment support not available in CI, but always write the test body.

## Namespace execution

Builds run in rootless Linux user namespaces (no sudo). Requirements:
- `kernel.unprivileged_userns_clone=1`
- `kernel.apparmor_restrict_unprivileged_userns=0`
- Writable `/dev` with bind-mountable device nodes

The namespace lifecycle is: `unshare(NEWUSER)` -> write uid/gid maps -> `unshare(NEWNS)` -> mount plan -> `pivot_root`. Everything is cleaned up when the process exits.

## Commit and PR conventions

- Commit messages: summarize behavioral change and affected architecture(s).
- PR descriptions: call out target architectures, dependency changes, and how the change advances simplification or self-hosting.
- Use the in-repo `Bootstrap::GitHubUtils.create_pull_request` helper rather than external `gh` CLI.
- Default PR base branch: `master`.
