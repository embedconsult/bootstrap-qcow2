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
- For every task, add documentation updates and specs for all public functions (use `pending` where kernel settings or privileges are required), and rerun `crystal spec` plus `crystal tool format`.

## PR/commit expectations
- Commit messages should summarize the behavioral change and the architecture(s) affected.
- PR summaries should call out: target architectures, EFI/boot impacts, new dependencies (if any), and how the change advances self-hosting or Crystal-only tooling.
