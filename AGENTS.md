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

## Contribution guidelines
- Favor readable, declarative Crystal code; prefer small, focused modules over sprawling scripts.
- Avoid adding new shell scripts or Bash-centric tooling. If orchestration is required, implement it as Crystal CLI utilities.
- Keep dependency additions rare and justified in commit/PR context; prefer vendoring source or Crystal shards that align with the LLVM/Clang toolchain.
- When touching build steps, prefer deterministic, offline-friendly workflows that keep generated artifacts reproducible.

## Testing and quality
- Run `crystal tool format` on modified Crystal files.
- Add or update automated checks (Crystal specs or integration exercises) when changing build logic, boot flow, or image layout.
- Document architecture-specific behaviors or assumptions (especially for aarch64) near the code that enforces them.

## PR/commit expectations
- Commit messages should summarize the behavioral change and the architecture(s) affected.
- PR summaries should call out: target architectures, EFI/boot impacts, new dependencies (if any), and how the change advances self-hosting or Crystal-only tooling.

## Rootless userns + pivot_root procedure

Goal:
Run a foreign Linux rootfs as a normal user using userns + mntns + pivot_root for development and bootstrapping.
Isolation is functional, not security-driven.

### Preflight (fail fast)

- Kernel config: CONFIG_USER_NS, CONFIG_MOUNT_NS, CONFIG_PROC_FS, CONFIG_SYSFS, CONFIG_TMPFS
- Sysctl: kernel.unprivileged_userns_clone=1
- AppArmor: process must be unconfined
- All dev executables live under /home/** (AppArmor flags=(unconfined))

### Namespace setup (mandatory order)

1. unshare(CLONE_NEWUSER | CLONE_NEWNS)
2. Write ID maps:
   - echo deny > /proc/self/setgroups
   - write /proc/self/uid_map and /proc/self/gid_map
3. Disable mount propagation:
   - mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL)

All mounts must be namespace-local. Nothing propagates to the host.

### Mount plan (prefer bind mounts)

Prepare <newroot>/{proc,sys,dev,dev/shm}.

/proc
  mount("proc", "<newroot>/proc", "proc",
        MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL)

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

- Perform pivot_root(<newroot>, <newroot>/.oldroot)
- chdir("/")
- /oldroot handling:
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
