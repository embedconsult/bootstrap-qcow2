# Back-port Checklist (Overrides → Embedded Plan)

Goal: once an override consistently works, encode it into `src/sysroot_builder.cr` so a clean build reproduces it.

## What changed?

- **One-off package flags**: add to `PhaseSpec#configure_overrides["pkg"]`.
- **One-off package patches**: add to `PhaseSpec#patch_overrides["pkg"]` and keep patch files under `patches/`.
- **Phase-wide toolchain env**: add/update `PhaseSpec#env` (or helpers like `rootfs_phase_env`).
- **Install destination mismatch**:
  - sysroot build: keep `install_prefix` pointing at `/opt/sysroot`
  - rootfs build: keep `install_prefix` at `/usr` and `destdir` at `/workspace/rootfs`
- **Subset debugging allowlist**: do not permanently restrict packages unless it is a deliberate phase design choice.

## Confirm determinism

- Remove `/var/lib/sysroot-build-overrides.json`.
- Re-run `sysroot-runner` from scratch inside a fresh bootstrap rootfs.
- Ensure specs cover the new plan behavior (phase names, env/allowlists, etc.).

## Common “real build” fixes to back-port

- Add `PKG_CONFIG_PATH` for sysroot libraries.
- Add `CFLAGS/LDFLAGS` for sysroot include/lib directories.
- Add missing build tools (patch, make, cmake) to the bootstrap environment (outside the plan).
- Add missing sysroot packages (e.g., `zlib`) when downstream packages fail to link.
