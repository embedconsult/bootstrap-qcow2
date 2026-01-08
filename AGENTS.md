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
- All code must be human-readable: Human-readable code MUST be written for a technically literate human who has a reasonable mental model of what a computer is and the general classes of operations a machine can perform (e.g., data movement, arithmetic and logic, control flow, memory access, and I/O), without requiring knowledge of any specific instruction set architecture. Such code MUST allow the reader to infer, from the high-level structure and naming alone, the types of machine-level operations implied by each section, follow the natural flow of execution without detailed simulation, and progressively build an accurate understanding of behavior through reading the code and its comments. Code that obscures intent, relies on implicit knowledge, or requires external explanation to understand its operational flow SHOULD NOT be considered human-readable.

## Testing and quality
- Run `crystal tool format` on modified Crystal files.
- Add or update automated checks (Crystal specs or integration exercises) when changing build logic, boot flow, or image layout.
- Document architecture-specific behaviors or assumptions (especially for aarch64) near the code that enforces them.
- For every task, add documentation updates and specs for all public functions; when specs depend on kernel privileges, detect availability and run success paths when possible, otherwise fall back to `pending`. Always rerun `crystal spec` and `crystal tool format`.

## PR/commit expectations
- Commit messages should summarize the behavioral change and the architecture(s) affected.
- PR summaries should call out: target architectures, EFI/boot impacts, new dependencies (if any), and how the change advances self-hosting or Crystal-only tooling.
