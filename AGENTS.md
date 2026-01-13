# AGENTS

## Scope
These instructions apply to the entire repository unless overridden by a nested `AGENTS.md`.

## Project direction
- Primary goal: build a reproducible QCOW2 disk image that boots via EFI across multiple architectures, with **aarch64** as the first-class target.
- Boot flow expectations: EFI launches a Linux kernel with a built-in initramfs that contains every tool needed to rebuild the image from source.
- Language and tooling constraints: implement tooling in **Crystal** (no new shell scripting) and keep external runtime dependencies to an absolute minimum.
- Compiler preferences: use **LLVM/Clang** for any required C/C++ code; avoid adding dependencies outside the LLVM/Clang stack. Plan to retire CMake in later phases.
- Default to Clang/LLVM toolchains for C/C++ builds (including userland libs); use GCC only when strictly necessary for bootstrapping or compatibility.
- Self-hosting trajectory: the environment should be capable of building complete versions of Crystal and Fossil; long-term direction is to migrate version control to Fossil/SQLite and ultimately replace Linux with a Crystal-based kernel inspired by Tanenbaum.

## Environment requirements (for namespace + build tooling)
- Unprivileged user namespaces enabled: `kernel.unprivileged_userns_clone=1`, `kernel.apparmor_restrict_unprivileged_userns=0`, AppArmor label `unconfined`.
- No seccomp/NoNewPrivs restrictions that block setgroups/uid_map or socket creation.
- Host `/dev` must allow bind-mounting core device nodes and writing to them (`/dev/null`, `/dev/zero`, `/dev/random`, `/dev/urandom`, `/dev/tty` when present). `/dev` should be a writable `devtmpfs` or equivalent; device nodes must be writable inside the user namespace. Provide /dev as dev-enabled (e.g., `mount -o remount,dev /dev` on bare metal, or container flag `--tmpfs /dev:rw,exec,dev,nosuid`); if dev is forced off, namespace setup will fail fast with guidance.
- Mounting proc/sys/dev/tmpfs inside the unshared mount namespace must be permitted (requires CAP_SYS_ADMIN in the user namespace).
- Outbound HTTP/DNS required to fetch sources when running `crystal run src/main.cr`.
- No synthetic device nodes: /dev/null, /dev/zero, /dev/random, /dev/urandom (and /dev/tty when present) must be bind-mountable and writable inside the user namespace; nodev must not block these binds. If running in a container, provide /dev as tmpfs with dev,nosuid,exec (e.g., Docker: `--tmpfs /dev:rw,exec,dev,nosuid` plus device passthrough or `--privileged --security-opt seccomp=unconfined` to drop nodev).
- Single namespace strategy: we always bind host devices (no synthetic nodes, no tmpfs /dev fallback). If binds fail, preflight will pend specs and raise clear NamespaceErrors; fix the host/runtime rather than adding workarounds.
- Ensure `/dev` inside the container is dev-enabled.
- Namespace tooling binds `./codex/work` to `/work` for use by Codex; `/workspace` should come from the rootfs itself. For namespace setup we now follow the LFS kernfs pattern: bind-mount host `/dev` recursively, mount proc/sys inside the namespace, and keep a single path rather than synthesizing /dev.

## Contribution guidelines
- Favor readable, declarative Crystal code; prefer small, focused modules over sprawling scripts.
- Avoid adding new shell scripts or Bash-centric tooling. If orchestration is required, implement it as Crystal CLI utilities.
- Keep dependency additions rare and justified in commit/PR context; prefer vendoring source or Crystal shards that align with the LLVM/Clang toolchain.
- When touching build steps, prefer deterministic, offline-friendly workflows that keep generated artifacts reproducible.

## Testing and quality
- Run `crystal tool format` on modified Crystal files.
- Run `shards build` to ensure `bq2` builds and symlink postinstall completes before commits/PRs.
- Always run `crystal spec` to verify no test failures.
- Tests that cannot pass in the current environment should utilize `pending`, but this is never an excuse for not writing tests that should pass when the environment allows.
- Add or update automated checks (Crystal specs or integration exercises) for all public methods and evaluate any changes in build logic, boot flow, or image layout.
- Document architecture-specific behaviors or assumptions (especially for aarch64) near the code that enforces them.
- Document all methods. Use the documentation style of the Crystal's standard library API.
- Always document the source of magic numbers. Use authoritative sources.

## Build Plan iteration (in-container)

Goal: iterate on sysroot/rootfs build issues inside the running container, then back-port working changes into `src/sysroot_builder.cr` so builds remain reproducible.

- Host build: `shards build` then `./bin/bq2 --install`.
- Generate a bootstrap rootfs (includes `/var/lib/sysroot-build-plan.json`): `./bin/sysroot-builder --no-tarball`.
- Enter rootfs for iteration: `./bin/sysroot-namespace --rootfs data/sysroot/rootfs -- /bin/sh`.
- Inside rootfs, build the CLI from staged source: `cd /workspace/bootstrap-qcow2 && shards build`.
- Run phases:
  - Default (first phase only): `./bin/bq2 sysroot-runner`
  - Select phase: `./bin/bq2 sysroot-runner --phase rootfs-from-sysroot`
  - Narrow to a package: `./bin/bq2 sysroot-runner --phase sysroot-from-alpine --package musl`
- Capture lessons-learned:
  - On failure, the runner writes a JSON report under `/var/lib/sysroot-build-reports` (override with `--report-dir`, disable with `--no-report`).
  - Use the report to decide the next tweak (flags/env/DESTDIR), then apply it via an overrides file.
- Fast iteration with overrides (no rebuild required):
  - Create/edit `/var/lib/sysroot-build-overrides.json` (or pass `--overrides PATH`).
  - Re-run the affected phase/package until it works.
  - Once stable, back-port the overrides into `SysrootBuilder.phase_specs` (or its helpers) and delete the overrides file so the clean build stays deterministic.

## PR/commit expectations
- Commit messages should summarize the behavioral change and the architecture(s) affected.
- PR summaries should call out: target architectures, EFI/boot impacts, new dependencies (if any), and how the change advances self-hosting or Crystal-only tooling.
- Ensure PR summaries cover all changes made on the branch, not just the latest commit.
- For GitHub PR automation, prefer using the in-repo helper `Bootstrap::CodexUtils.create_pull_request(repo, title, head, base, body, credentials_path = "../.git-credentials")`. It reads the x-access-token from `.git-credentials` and POSTs to the GitHub REST API; inject a custom HTTP sender when testing. Avoid external CLI dependencies.
- Default PR base is `master` unless explicitly requested otherwise; set the head branch accordingly before calling `create_pull_request`.

## Rootless userns + pivot_root procedure

Goal:
Run a foreign Linux rootfs as a normal user using userns + mntns + pivot_root for development and bootstrapping.
Isolation is functional, not security-driven.

### Preflight (fail fast)

- Kernel config: CONFIG_USER_NS, CONFIG_MOUNT_NS, CONFIG_PROC_FS, CONFIG_SYSFS, CONFIG_TMPFS
- Sysctl: kernel.unprivileged_userns_clone=1
- Sysctl (AppArmor): kernel.apparmor_restrict_unprivileged_userns=0
- AppArmor: process must be unconfined

### Namespace setup (mandatory order)

1. unshare(CLONE_NEWUSER)
2. Write ID maps:
   - echo deny > /proc/self/setgroups
   - write /proc/self/uid_map and /proc/self/gid_map
3. unshare(CLONE_NEWNS)
4. Disable mount propagation:
   - mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL)

All mounts must be namespace-local. Nothing propagates to the host.

### Mount plan (prefer bind mounts)

Prepare <newroot>/{proc,sys,dev,dev/shm}.

/proc
  Bind-mount host /proc → <newroot>/proc, then remount with
  MS_NOSUID | MS_NODEV | MS_NOEXEC. Avoid a read-only remount because
  EPERM was observed during the remount attempt on some kernels.

/sys
  Bind-mount host /sys → <newroot>/sys, then remount read-only.

/dev
  tmpfs on <newroot>/dev

  Bind-mount only:
  - /dev/null
  - /dev/zero
  - /dev/random
  - /dev/urandom
  - /dev/tty (optional)
  - /dev/fd + stdio via /proc/self/fd

  tmpfs on <newroot>/dev/shm

No mknod. No /dev/pts. No host /dev.

### pivot_root behavior

- Perform pivot_root(<newroot>, <newroot>/.pivot_root)
- chdir("/")
- /.pivot_root handling:
  - Removing it is optional
  - It may be kept for explicit developer access to the host filesystem
  - Tooling must not depend on it implicitly

Mount namespace lifetime = process lifetime.
All mounts disappear when the process exits.

### Invariants

- No sudo at runtime
- No persistent mounts
- No AppArmor mediation of this tool
- Any dependency on host paths must be explicit and intentional
