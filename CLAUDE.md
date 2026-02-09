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

A reproducible disk-image builder written in Crystal. It produces a bootable QCOW2 that can rebuild itself from source, host Fossil repositories via cloud providers (DigitalOcean, etc.), and serve as a self-contained development environment. The single busybox-style binary `bq2` dispatches all subcommands (`sysroot-builder`, `sysroot-namespace`, `sysroot-runner`, `curl`, `pkg-config`, `git-remote-https`, etc.).

Primary architecture: **aarch64**. Secondary: x86_64.

### Project outcomes

The project is done when these three things work end-to-end:

1. **Crystal self-hosts.** The Crystal compiler inside the QCOW2 can rebuild itself from source using the in-image LLVM/Clang toolchain.
2. **Fossil self-hosts.** Fossil inside the QCOW2 can rebuild itself and serve repositories (clone, push, UI) using both Fossil-native and Git-compatible protocols.
3. **Bootable, deployable image.** The QCOW2 boots via EFI, runs a minimal `cloud-init` for provider setup (SSH keys, networking, hostname), and is ready to host Fossil services on DigitalOcean or equivalent infrastructure.

Everything else -- build phases, dependency management, namespace tooling -- exists to reach these outcomes.

## Repository layout

```
src/                  Crystal source (~8k lines); sysroot_builder.cr is the largest file
spec/                 Crystal specs (~16 files)
patches/              Upstream patches organized by package-version
data/                 Dockerfiles, BIOS binaries, CA bundle, genimage config
c/                    C++ stubs for in-process LLVM integration
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
- `src/git_remote_https.cr` -- Crystal-native Git smart HTTP remote helper
- `c/src/inproc_llvm.cc` -- in-process Clang/LLD C++ stubs

## Simplification principles

Every change should make this codebase smaller, clearer, or more self-contained. Prefer deleting code over adding it. Prefer inlining over indirection. The right question before any addition is: "can this be removed instead?"

1. **One way to do things.** Eliminate alternate code paths that exist for historical reasons. The build plan + state + runner model is the sole execution path; remove anything that bypasses it (e.g., `SysrootResumeAll` is legacy and should be folded in or deleted).

2. **Logical cohesion over line counts.** `sysroot_builder.cr` is large because it declares all packages, phases, and their relationships in one place. That is acceptable if the structure makes each package's build pattern visible and easy to emulate. When extracting code, split on clear responsibility boundaries: `SysrootWorkspace` owns path resolution; `SysrootBuildState` owns plan/overrides loading; `SysrootBuilder` owns the package list and phase definitions. Do not split just to shorten a file -- split when a distinct concept has emerged that readers would benefit from seeing in isolation.

3. **No dead code.** Commented-out blocks, unused methods, backwards-compatibility shims for removed features -- delete them. If something is needed later, git has it.

4. **Crystal over shell.** Any remaining shell-outs (`Process.run("tar", ...)`, `Process.run("patch", ...)`) are candidates for replacement with Crystal implementations. `tarball.cr` already has a pure-Crystal tar reader; `patch_applier.cr` replaces the external `patch` command. Continue this pattern.

5. **Document magic numbers at the declaration site.** Every version constant, configure flag, and URL in `sysroot_builder.cr` should have a brief comment citing the authoritative source or explaining why that value was chosen.

### Human readability as a design metric

The codebase is optimized for human comprehension, not development velocity. Apply these criteria when evaluating changes:

- **Naming clarity.** A reader encountering a method or variable for the first time should understand its purpose from the name alone. Avoid abbreviations beyond well-established ones (`env`, `dir`, `io`). Prefer `sysroot_target_triple` over `triple`.
- **Locality of reasoning.** A reader should be able to understand a build step by reading one contiguous section. Avoid spreading a single package's configuration across multiple files or indirection layers. The per-package pattern in `SysrootBuilder#packages` and `#phase_specs` should remain scannable so that adding or modifying a package requires reading and changing one place.
- **Explicit data flow.** Prefer passing values as parameters over reading global or instance state. When a method uses a value, that value should be visible in the call site or the method signature, not buried in a side-channel.
- **Proportional complexity.** The complexity of the code for a task should be proportional to the complexity of the task itself. A simple file copy should be a simple statement. A complex LLVM configuration should be clearly structured but does not need to be hidden behind abstractions.
- **Consistent patterns.** Every package build follows the same PackageSpec -> PhaseSpec -> BuildStep pipeline. When a new package is added, a reader should be able to copy an adjacent entry and modify it. Divergent patterns for special cases erode this.

## Reducing external dependencies

The project currently downloads 25+ upstream source tarballs. The long-term trajectory is to reduce this set to the minimum required for a self-hosting Crystal + Fossil + LLVM environment.

### Core dependencies (long-lived, invest in deeper integration)

| Dependency | Role | Integration direction |
|---|---|---|
| **LLVM/Clang/LLD** | Compiler toolchain for Crystal and C/C++ | Deeper Crystal integration via in-process LLVM (see build time section). Maintain Python-removal patches. Minimize build surface. |
| **Crystal** | Primary language; self-hosting compiler | The environment must be able to rebuild Crystal from source. |
| **Fossil** | Version control and repository hosting | Primary VCS for the deployed image. Use Fossil's built-in Git import/export (`fossil git export`, `fossil import --git`) to bridge Git workflows. Explore replacing the `git` package with Fossil's Git-compatible features where feasible. |
| **SQLite** | Required by Fossil | Retained as long as Fossil needs it. |
| **musl** | C library | Essential. Minimal surface. |
| **Linux headers** | Kernel interface | Essential. Headers only. |

### Near-term targets for removal or replacement

| Dependency | Status | Path forward |
|---|---|---|
| **CMake** | Required by LLVM | Replace with direct Ninja/Makefile generation in Crystal once LLVM build is stable. Track upstream LLVM efforts to reduce CMake dependency. |
| **m4** | Used by autotools packages | Eliminate when autotools packages are replaced with Crystal-driven builds or CMake. |
| **GNU Make** | Build orchestration | Already partially replaced by Crystal step runner. Continue migrating build logic into `step_runner.cr` strategies. |
| **git** | tools-from-system phase | Fossil supports Git interop (`fossil git export`, `fossil import --git`, Git-over-HTTP serving). Migrate to using Fossil's Git bridge + Crystal `git-remote-https` helper; remove the standalone git package when no workflow depends on it directly. |
| **Python** | LLVM build dependency | Already patched out (6 LLVM patches disable Python). Maintain these patches on LLVM upgrades. |

### Bootstrap seed

**Alpine minirootfs** is the current bootstrap seed and must remain available as an option for cold-start bootstrapping. The `@seed` parameter keeps the seed swappable. Once the generated rootfs can rebuild itself, Alpine becomes unnecessary for day-to-day use, but its code path should not be removed -- someone bootstrapping from scratch will need it.

### Principles for dependency decisions

- Every external package must justify its presence. If Crystal can do the job at acceptable complexity, prefer Crystal.
- When an external package is retained, pin the version, provide a SHA256, and minimize the build surface (disable tests, docs, optional features).
- Source tarballs are cached in `data/sysroot/sources/` and checksummed in `data/sysroot/cache/checksums/`. Never skip verification.
- Move dependency fetching for Crystal shards into a dedicated download phase so `shards install` never requires network during build.

## Reducing build time

Full sysroot builds are dominated by LLVM/Clang compilation. Prioritize changes that shrink LLVM build time or avoid rebuilding it.

### Strategies in priority order

1. **In-process LLVM (eliminate process spawning).** The largest per-compilation overhead is spawning `clang`, `clang++`, and `lld` as separate processes -- thousands of times across the build. The `c/src/inproc_llvm.cc` stub already provides `inproc_clang()` and `inproc_link_via_clang()` entry points that call Clang's `clang_main` directly with `CLANG_SPAWN_CC1=0`. The path forward: link `bq2` against `libclang-cpp` and `libLLVM` shared libraries, expose these C entry points to Crystal via `lib` FFI bindings in `src/inproc_llvm.cr`, and add an `inproc-clang` step runner strategy that invokes compilation without `fork`/`exec`. This saves process startup, dynamic linker, and LLVM re-initialization costs on every compile. Start with a single-file proof (compile one `.c` file via `inproc_clang` from Crystal) and expand to full build integration. Shared LLVM libraries (already configured) make this viable without duplicating LLVM in memory.

2. **LLVM build scope reduction.** The current config already disables 80+ LLVM tools and all sanitizers/fuzzers. Continue auditing: disable any LLVM component not required by Crystal's compiler or the Clang/LLD toolchain. Each disabled tool saves compilation and link time.

3. **Shared library preference.** Build LLVM/libc++/libunwind as shared libraries (already configured). This reduces link time compared to static builds and avoids redundant code in every linked binary.

4. **Single-architecture LLVM target.** Only build the LLVM backend for the target architecture (`-DLLVM_TARGETS_TO_BUILD=AArch64` or `X86`). Never build "all" targets.

5. **Resume-aware builds.** The build state model (`sysroot-build-state.json`) supports resuming from the last successful step. Ensure all strategies are idempotent so interrupted builds resume correctly without re-running completed steps.

6. **Source caching and skip-on-resume.** Tarball downloads are cached. Source extraction is skipped when build directories already exist (resume mode). Protect this behavior; do not regress it.

7. **Parallel make.** Ensure `MAKEFLAGS=-jN` and `CMAKE_BUILD_PARALLEL_LEVEL` are set appropriately in phase environments. Check that the sysroot and system phases both pass these through.

8. **Host binary build.** Crystal compilation of `bin/bq2` takes ~30s. This is acceptable. Do not add Crystal shards that increase compile time without strong justification. The project has zero shard dependencies by design.

9. **Eliminate redundant rebuilds.** Some packages appear in multiple phases (e.g., musl, busybox, linux-headers in both sysroot and rootfs phases). Verify that rootfs-phase rebuilds are necessary for correctness; if a sysroot-built artifact can be reused, skip the rebuild.

10. **ccache or build artifact caching.** For iterative development, consider caching object files across builds. This is lower priority than in-process LLVM but can help during phase iteration when only a few source files change.

## Fossil integration

Fossil is a key project outcome, not just a dependency. The deployed QCOW2 image should be able to host Fossil repositories with web UI and serve them to both Fossil and Git clients.

### Fossil's Git interop features

Fossil has built-in Git bridging that can reduce or eliminate the need for standalone `git`:

- `fossil git export` -- export a Fossil repo to a Git repo
- `fossil import --git` -- import a Git repo into Fossil
- Fossil can serve Git-compatible HTTP endpoints for clone/fetch
- `fossil clone` supports both Fossil-native and Git-over-HTTP protocols

### Integration plan

- Use Fossil as the primary VCS inside the QCOW2 image.
- Use `git-remote-https` (Crystal implementation in `src/git_remote_https.cr`) for any remaining Git HTTPS operations during build.
- Use Fossil's Git bridge features for interop with GitHub and other Git-hosted upstreams.
- Long-term: the deployed image serves Fossil repos via its built-in HTTP server, with `cloud-init` handling provider-specific setup.

## LLVM integration in Crystal

LLVM and Crystal are both long-lived codebases in this project. Deeper integration is welcome and encouraged.

### In-process compilation architecture

The current `c/` directory contains C++ stubs (`inproc_llvm.cc`) that call `clang_main` directly. The Crystal-side `src/inproc_llvm.cr` is a placeholder. The intended architecture:

1. **C++ layer** (`c/src/inproc_llvm.cc`): thin `extern "C"` wrappers around Clang and LLD entry points. Initialize LLVM targets once. Set `CLANG_SPAWN_CC1=0` to prevent Clang from re-execing itself.
2. **Crystal FFI** (`src/inproc_llvm.cr`): `lib` bindings to the C entry points. Provide a `compile(args)` method that builds an argv and calls `inproc_clang`.
3. **Step runner strategy**: an `inproc-clang` strategy in `step_runner.cr` that replaces `Process.run("clang", ...)` with the in-process call for C/C++ compilation steps.

This eliminates fork/exec overhead per compilation unit and keeps LLVM loaded in memory across the entire build. The shared library configuration (`-DLLVM_BUILD_LLVM_DYLIB=ON`, `-DLLVM_LINK_LLVM_DYLIB=ON`) means the memory cost is shared, not duplicated.

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
