---
name: bq2-iterate
description: Automate bootstrap-qcow2 sysroot iteration when the user says "iterate" or "resume iteration"; detect Alpine seed/BQ2 seed/inner rootfs, run sysroot-runner in the background, apply overrides, and back-annotate fixes into SysrootBuilder with a clean commit.
---

# BQ2 iteration autopilot

Use this when the user says "iterate" or "resume iteration". The goal is to run sysroot-runner until the current phase completes, then back-annotate overrides and commit.

## Detect rootfs context and paths

1. Find the rootfs prefix:
   - If `/var/lib/sysroot-build-plan.json` exists, you are inside the workspace rootfs. Use `rootfs_prefix=""` and `rootfs_root="/"`.
   - Else if `/workspace/rootfs/var/lib/sysroot-build-plan.json` exists, you are in the outer rootfs. Use `rootfs_prefix="/workspace/rootfs"` and `rootfs_root="/workspace/rootfs"`.
   - Else if `/work/bootstrap-qcow2/data/sysroot/rootfs/var/lib/sysroot-build-plan.json` exists, use `rootfs_prefix="/work/bootstrap-qcow2/data/sysroot/rootfs"`.
   - Otherwise, stop and ask for the rootfs location.

2. Define canonical paths (prefix with `rootfs_prefix`):
   - `plan=/var/lib/sysroot-build-plan.json`
   - `overrides=/var/lib/sysroot-build-overrides.json`
   - `state=/var/lib/sysroot-build-state.json`
   - `reports=/var/lib/sysroot-build-reports`
   - `logs=/var/lib/sysroot-build-logs`

3. Locate the repo root (first match wins):
   - `/work/bootstrap-qcow2`
   - `/workspace/bootstrap-qcow2`
   - `/workspace/bootstrap-qcow2-*`
   - `/home/ubuntu/workspace/bootstrap-qcow2`

4. Ensure `bq2` entrypoints exist:
   - If `bin/bq2` is missing, run `shards build` (use `CRYSTAL_CACHE_DIR=/tmp/crystal_cache` if needed) and `./bin/bq2 --install`.
   - If `shards` is missing, try `/opt/sysroot/bin/shards` and keep PATH consistent. If it is still missing, report and stop.

## Determine the current phase

- Prefer `bin/sysroot-status` if available. If not, use `bin/bq2 sysroot-status`.
- If you are outside the rootfs, pass `--rootfs="${rootfs_root}"` (or `-w /workspace` for the default workspace rootfs).
- Parse `next_phase=` and use that as the target phase. Always iterate until that phase completes.

## Run the runner in the background

- Always launch with explicit paths and log capture. Use `nohup` and record PID + log path.
- Example (fill variables):

```sh
log_dir="${rootfs_prefix}/var/lib/sysroot-build-logs"
mkdir -p "$log_dir"
log="$log_dir/sysroot-runner-$(date -u +%Y%m%dT%H%M%SZ)-${phase}.log"
nohup "${repo}/bin/sysroot-runner" \
  --plan "${rootfs_prefix}${plan}" \
  --state-path "${rootfs_prefix}${state}" \
  --overrides "${rootfs_prefix}${overrides}" \
  --report-dir "${rootfs_prefix}${reports}" \
  --phase "${phase}" \
  > "$log" 2>&1 &
```

- If the runner fails due to namespace restrictions, rerun with escalated permissions.

## Observe, override, and relaunch

1. Tail the log to find the failure point.
2. Read the newest failure report:
   - `latest=$(ls -t "${rootfs_prefix}${reports}"/*.json | head -n 1)`
   - Inspect `error`, `step`, `phase`, `command`, and `configure_flags`.
3. Update `${rootfs_prefix}${overrides}` with the smallest change that fixes the error.
4. Rerun the runner for the same phase. Repeat until the phase completes.

## Phase completion check

- Re-run `sysroot-status` and verify `next_phase` changes away from the phase you targeted.
- If it has not advanced, continue iterating.

## Back-annotate and commit

Once the phase completes with overrides in place:

1. Translate overrides into `src/sysroot_builder.cr` and related helpers.
2. Add/remove patches in `patches/` as needed.
3. Remove overrides/state in the rootfs and rerun from scratch when feasible.
4. Run:
   - `crystal tool format`
   - `shards build`
   - `crystal spec`
5. Commit with a message describing the behavior change and affected arch.

Keep all changes Crystal-native and avoid new shell scripts.
