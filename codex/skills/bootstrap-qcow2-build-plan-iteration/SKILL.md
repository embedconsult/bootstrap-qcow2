---
name: bootstrap-qcow2-build-plan-iteration
description: Use when iterating on bootstrap-qcow2 sysroot/rootfs builds inside a container or chroot: replay phased build plans with `sysroot-runner`, apply runtime overrides, triage failures via generated reports, and back-port working changes into `src/sysroot_builder.cr` so builds are reproducible from scratch.
---

# bootstrap-qcow2 Build Plan Iteration

## Overview

Iterate on sysroot/rootfs build failures with minimal restarts by:
- Running a single phase or package subset.
- Applying runtime-only overrides (flags/env/allowlists) from a JSON file.
- Capturing failure context into machine-readable reports.
- Back-porting stable fixes into `src/sysroot_builder.cr` (`phase_specs` / overrides) and deleting runtime overrides.

## Quick Start (host → rootfs → runner)

1. Build the CLI and symlinks:
   - `shards build`
   - `./bin/bq2 --install`
2. Generate a bootstrap rootfs directory:
   - `./bin/sysroot-builder --no-tarball`
3. Enter the bootstrap rootfs:
   - `./bin/sysroot-namespace --rootfs data/sysroot/rootfs -- /bin/sh`
4. Inside the rootfs, build the staged repo (so the runner matches current source):
   - `cd /workspace/bootstrap-qcow2 && shards build`
5. Inspect what will run (no execution):
   - `./bin/bq2 sysroot-runner --dry-run`
6. Run just what you need:
   - Default (first phase only): `./bin/bq2 sysroot-runner`
   - A phase: `./bin/bq2 sysroot-runner --phase rootfs-from-sysroot`
   - A single package: `./bin/bq2 sysroot-runner --phase sysroot-from-alpine --package musl`

## Iteration Loop (try → learn → back-port)

### 1) Run with reports enabled

Keep reporting on while iterating so failures are captured automatically:
- Reports: `/var/lib/sysroot-build-reports/*.json`
- Disable: `--no-report`
- Custom path: `--report-dir PATH`

### 2) Read the latest failure report

Each report records:
- Phase name + environment + install destination (`install_prefix`, optional `destdir`)
- Step name + strategy + workdir
- Any captured command/exit code (when the failure came from a subprocess)
- The exception message

### 3) Apply a runtime override (no rebuild required)

Edit `/var/lib/sysroot-build-overrides.json` and rerun only the failing subset:
- Default overrides path: `/var/lib/sysroot-build-overrides.json`
- Custom path: `--overrides PATH`
- Disable overrides: `--no-overrides`

Useful override types:
- Add configure flags (e.g., `--disable-something`, `--with-sysroot=...`)
- Add env vars (e.g., `CC`, `CFLAGS`, `LDFLAGS`, `PKG_CONFIG_PATH`)
- Narrow phase packages (avoid rebuilding everything while debugging)

See `references/overrides-template.json` for a starting point.

### 4) Re-run only what changed

Minimize iteration time:
- Filter package(s): `--package NAME` (repeatable)
- Filter phase: `--phase NAME`
- Confirm selection: `--dry-run`

### 5) Back-port stable fixes into the embedded plan

Once an override is confirmed:
- Move it into `src/sysroot_builder.cr` (prefer phase-level defaults where possible).
- Add/adjust specs under `spec/` for the updated plan logic.
- Delete the runtime overrides file so the from-scratch build remains deterministic.

Where to back-port:
- Phase-level defaults: `SysrootBuilder#phase_specs` (env, install locations, allowlists)
- Per-package flags/patches: `PhaseSpec#configure_overrides` / `PhaseSpec#patch_overrides`

## Notes and Gotchas

- Preserve step order when filtering to a subset. The plan order can encode build dependencies.
- Prefer minimal deltas in overrides. If the fix needs many env vars/flags, it usually indicates a missing dependency or incorrect phase selection.
- Rootfs validation phase installs into `DESTDIR` (default: `/workspace/rootfs`). Use this to test pivot_root/userns later without clobbering the bootstrap environment.

## References

- `references/overrides-template.json`: Minimal runtime overrides starter.
- `references/backport-checklist.md`: What to back-port and where.
