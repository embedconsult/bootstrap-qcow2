# bootstrap-qcow2

[![CI](https://github.com/jkridner/bootstrap-qcow2/actions/workflows/ci.yml/badge.svg)](https://github.com/jkridner/bootstrap-qcow2/actions/workflows/ci.yml)

Build reproducible QCOW2 and chroot images with Crystal-first tooling. The sysroot builder targets aarch64 by default, caches upstream source tarballs, and stages a chroot that can rebuild the sysroot inside itself using a Crystal coordinator. Alpine’s 3.23.2 minirootfs is the current bootstrap seed, but the builder is designed so the starting rootfs, architecture, and package set remain swappable once a self-hosted rootfs is available.

## Project plan and architecture direction

The objective of this project is to create a Crystal runtime environment that can be booted via an EFI executable in a QCOW2 disk image, and that can regenerate itself from source entirely within the image. Crystal is chosen for its human-readable syntax, high-level expressiveness, and ability to compile into low-level, minimal-overhead executables with strong performance characteristics.

Human-readability is the most important outcome, with source-based reproducibility an absolute imperative. The project starts with a minimal, bootable environment and iteratively reduces binary dependencies while expanding the amount of the toolchain implemented in Crystal. Any new or retained dependency must be justifiable in terms of clarity, auditability, and its role in the migration toward a single comprehensible syntax. The intent is to progressively remove unnecessary code and to refactor the remaining code into smaller, clearer, and more accessible components. Applying best-available human-readability metrics to guide these improvements is encouraged.

This project acknowledges that prior generations achieved significant functionality with modest resources and far fewer layers. Today’s baseline depends on large, complex systems such as Linux and LLVM. That is an acceptable starting point, but the long-term direction is to migrate toward a system where both code and data are expressed in a single, consistent syntax, and where the runtime becomes comprehensible end-to-end.

During the interim, reliance on externally-authored and compiled tools (for example `bash`, `make`, `cmake`, or `clang`) should be minimized. Whenever practical, their responsibilities should be migrated into Crystal through statically or dynamically linked function calls, and the necessary data should be extracted programmatically from upstream sources. Any newly generated imperative or declarative operations must be expressed in Crystal, with APIs and macros used to improve clarity rather than convenience.

## Installation

1. Install Crystal 1.18.2 or newer.
2. Run `shards install` (no postinstall steps are required).

## Usage

### Build the CLI

```console
shards build
./bin/bq2 --install # creates symlinks
```

### Build the directory layout and write the plan

```console
$ bin/sysroot-builder
Prepared sysroot workspace at data/sysroot
Wrote build plan at data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-plan.json

To validate self-hosting with the published 0.3.3 seed rootfs tarball, generate an alternate plan with:

```console
$ bin/sysroot-builder --seed bq2-rootfs-0.3.3
```
$ tree data/sysroot/seed-rootfs/
data/sysroot/seed-rootfs/
├── bq2-rootfs
│   ├── var
│   │   └── lib
│   │       └── sysroot-build-plan.json
│   └── workspace
└── opt
    └── sysroot

7 directories, 1 file
```

### Build the target rootfs

#### Just build everything

If you just try to build everything, it should take about an hour on a really fast machine right now.

```console
$ bin/sysroot-runner
```

####

```console
$ bin/sysroot-status
plan_path=/home/ubuntu/workspace/bootstrap-qcow2/data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-plan.json
state_path=/home/ubuntu/workspace/bootstrap-qcow2/data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-state.json
report_dir=/home/ubuntu/workspace/bootstrap-qcow2/data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-reports
next_phase=host-setup
next_step=download-sources
```

#### Run a single phase

```console
$ bin/sysroot-runner --phase host-setup
2026-02-23T14:41:25.685363Z   INFO - Finished prefetch-shards
2026-02-23T14:41:25.700043Z   INFO - All build steps completed
2026-02-23T14:41:25.700046Z   INFO - Completed phase host-setup
```

#### Run individual steps

```console
$ bin/sysroot-runner --phase sysroot-from-alpine --package alpine-resolv-conf
2026-02-23T15:12:35.841817Z   INFO - Running plan /home/ubuntu/workspace/bootstrap-qcow2/data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-plan.json with overrides /home/ubuntu/worksp
ace/bootstrap-qcow2/data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-overrides.json (namespace=Host)
2026-02-23T15:12:35.842025Z   INFO - Entering namespace seed for phase sysroot-from-alpine
2026-02-23T15:12:35.843592Z   INFO - Executing phase sysroot-from-alpine (namespace=seed)
2026-02-23T15:12:35.843595Z   INFO - **** Build a self-contained sysroot using Alpine-hosted tools. ****
2026-02-23T15:12:35.843597Z   INFO - Executing 1 build steps
2026-02-23T15:12:35.843602Z   INFO - Building alpine-resolv-conf in  (phase=sysroot-from-alpine)
2026-02-23T15:12:35.843624Z   INFO - Starting write-file build for alpine-resolv-conf in (no chdir) (cpus=48)
2026-02-23T15:12:35.843696Z   INFO - Finished alpine-resolv-conf
2026-02-23T15:12:35.843820Z   INFO - All build steps completed
2026-02-23T15:12:35.843822Z   INFO - Completed phase sysroot-from-alpine
$ bin/sysroot-runner --phase sysroot-from-alpine --package alpine-apk-add
...
2026-02-23T15:13:23.713723Z   INFO - Entering namespace seed for phase sysroot-from-alpine
2026-02-23T15:13:23.715271Z   INFO - Executing phase sysroot-from-alpine (namespace=seed)
2026-02-23T15:13:23.715274Z   INFO - **** Build a self-contained sysroot using Alpine-hosted tools. ****
2026-02-23T15:13:23.715276Z   INFO - Executing 1 build steps
2026-02-23T15:13:23.715282Z   INFO - Building alpine-apk-add in  (phase=sysroot-from-alpine)
2026-02-23T15:13:23.715305Z   INFO - Starting apk-add build for alpine-apk-add in (no chdir) (cpus=48)
2026-02-23T15:13:23.715323Z   INFO - apk add --no-cache bash binutils clang libgcc libstdc++-dev libressl-dev crystal lld llvm-libs linux-headers make musl-dev patch zlib-dev pcre2-dev gc-dev
 yaml-dev perl python3 shards
2026-02-23T15:13:41.093045Z   INFO - Finished alpine-apk-add
2026-02-23T15:13:41.093296Z   INFO - All build steps completed
2026-02-23T15:13:41.093300Z   INFO - Completed phase sysroot-from-alpine
```

#### Execute a command in the new namespace

```console
$ bin/sysroot-namespace
Entering namespace with rootfs=data/sysroot/seed-rootfs
Bind mounts:
Command: /bin/sh --login
Executing command: /bin/sh --login
ip-172-31-1-184:/#
```

#### Continue where you left off

```console
$ bin/sysroot-status
plan_path=/home/ubuntu/workspace/bootstrap-qcow2/data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-plan.json
state_path=/home/ubuntu/workspace/bootstrap-qcow2/data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-state.json
report_dir=/home/ubuntu/workspace/bootstrap-qcow2/data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-reports
current_phase=sysroot-from-alpine
next_phase=sysroot-from-alpine
next_step=m4
$ bin/sysroot-runner
```

#### On failure

```console
$ bin/sysroot-status
plan_path=/home/ubuntu/workspace/bootstrap-qcow2/data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-plan.json
state_path=/home/ubuntu/workspace/bootstrap-qcow2/data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-state.json
report_dir=/home/ubuntu/workspace/bootstrap-qcow2/data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-reports
current_phase=sysroot-from-alpine
next_phase=sysroot-from-alpine
next_step=llvm-project-stage2
last_failure=sysroot-from-alpine/llvm-project-stage2
last_failure_report=/bq2-rootfs/var/lib/sysroot-build-reports/20260223T154034.392Z-sysroot_from_alpine-llvm_project_stage2-d64a9325.json
```

#### Change the plan without starting over

```console
$ shards build
Dependencies are satisfied
Building: bq2
$ bin/sysroot-builder-overrides
Wrote build plan overrides to /home/ubuntu/workspace/bootstrap-qcow2/data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-overrides.json
Overrides phases=4
$ bin/sysroot-runner
2026-02-23T18:20:15.075526Z   INFO - Applying build plan overrides from /home/ubuntu/workspace/bootstrap-qcow2/data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-overrides.json
2026-02-23T18:20:15.077316Z   INFO - Running plan /home/ubuntu/workspace/bootstrap-qcow2/data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-plan.json with overrides /home/ubuntu/worksp
ace/bootstrap-qcow2/data/sysroot/seed-rootfs/bq2-rootfs/var/lib/sysroot-build-overrides.json (namespace=Host)
2026-02-23T18:20:15.077641Z   INFO - Entering namespace seed for phase system-from-sysroot
2026-02-23T18:20:15.079295Z   INFO - Executing phase system-from-sysroot (namespace=seed)
2026-02-23T18:20:15.079298Z   INFO - **** Rebuild sysroot packages into /usr inside the new rootfs (prefix-free). ****
2026-02-23T18:20:15.079304Z   INFO - Executing 17 build steps
...
2026-02-23T22:17:34.701593Z   INFO - **** Strip the sysroot prefix and emit a prefix-free rootfs tarball. ****
2026-02-23T22:17:34.701595Z   INFO - Executing 1 build steps
2026-02-23T22:17:34.701601Z   INFO - Building rootfs-tarball in / (phase=finalize-rootfs)
2026-02-23T22:17:34.701624Z   INFO - Starting tarball build for rootfs-tarball in / (cpus=48)
2026-02-23T22:17:34.701671Z   INFO - Running in /: tar -czf /workspace/bq2-rootfs-0.3.3.tar.gz --exclude=var/lib --exclude=var/lib/** --exclude=workspace --exclude=worksp
ace/** --exclude=work --exclude=work/** --exclude=proc --exclude=proc/** --exclude=sys --exclude=sys/** --exclude=dev --exclude=dev/** --exclude=run --exclude=run/** --ex
clude=tmp --exclude=tmp/** --exclude=.bq2-rootfs -C / .
2026-02-23T22:18:32.049728Z   INFO - Finished in 57.348s (exit=0): tar -czf /workspace/bq2-rootfs-0.3.3.tar.gz --exclude=var/lib --exclude=var/lib/** --exclude=workspace
--exclude=workspace/** --exclude=work --exclude=work/** --exclude=proc --exclude=proc/** --exclude=sys --exclude=sys/** --exclude=dev --exclude=dev/** --exclude=run --exc
lude=run/** --exclude=tmp --exclude=tmp/** --exclude=.bq2-rootfs -C / .
2026-02-23T22:18:32.049737Z   INFO - Finished rootfs-tarball
2026-02-23T22:18:32.050064Z   INFO - All build steps completed
2026-02-23T22:18:32.050085Z   INFO - Completed phase finalize-rootfs in 57.348s
2026-02-23T22:18:32.051877Z   INFO - Completed sysroot run in 57.352s

```

## Build an EFI application from Crystal

Use the `efi-app-builder` command to emit a `.efi` binary by cross-compiling to a Windows COFF object and linking it as `efi_application`:

```bash
./bin/bq2 efi-app-builder --input src/hello-efi.cr --output out/hello-efi.efi --arch aarch64
```

Supported architectures are `aarch64` and `x86_64`. Use `--keep-object` to retain the intermediate `.obj` file for linker/debug inspection.

## Busybox-style CLI (`bq2`)

The single executable (`bin/bq2`) dispatches subcommands by argv[0] or the first argument. Symlinks in `bin/` mirror the subcommands (create them with `./bin/bq2 --install`).

```bash
shards build
./bin/bq2 --install

# Build the sysroot tarball
./bin/sysroot-builder --output sysroot.tar.gz
# Or via the main binary:
./bin/bq2 sysroot-builder --output sysroot.tar.gz

# Enter the sysroot namespace
./bin/sysroot-namespace --rootfs data/sysroot/rootfs -- /bin/sh
# Or:
./bin/bq2 sysroot-namespace --rootfs data/sysroot/rootfs -- /bin/sh

	# Inside the sysroot, build the CLI from staged source and run the plan
	cd /workspace/bootstrap-qcow2-master
	shards build
	./bin/bq2 --install
	./bin/bq2 sysroot-runner
	# Run the rootfs validation phase (installs into /workspace/rootfs as a staging DESTDIR)
	./bin/bq2 sysroot-runner --phase rootfs-from-sysroot
	# Or run every phase in order:
	./bin/bq2 sysroot-runner --phase all

# Default (no args): show resume status + help (use sysroot --resume to continue a build)
./bin/bq2
```

#### Iterating (overrides + state)

During iterative, in-container debugging, treat the plan JSON (`/var/lib/sysroot-build-plan.json`) as immutable and apply changes via:
- `/var/lib/sysroot-build-overrides.json` for runtime-only tweaks to flags/env/install paths
- `/var/lib/sysroot-build-state.json` for bookmark/progress tracking (auto-updated by `sysroot-runner`)
- `/var/lib/sysroot-build-reports/*.json` for failure reports

The `rootfs-from-sysroot` phase uses `DESTDIR=/workspace/rootfs` to assemble a candidate rootfs tree without changing the running sysroot; that staged tree is what later gets validated (and eventually entered via `pivot_root`) once the sysroot toolchain is stable.

After a full successful round, back-port overrides into `src/sysroot_builder.cr`, delete overrides/state, and retry from scratch to validate reproducibility.

This is intended for clean, sudo-less development workflows, not as a security boundary. The
namespace runner still has access to host files that are reachable from the sysroot rootfs,
and it requires kernel support for unprivileged namespaces to work at all. If your kernel
disables user namespaces, enable the setting explicitly.

#### Resuming `sysroot` workflows (host)

`bq2 sysroot` resumes by default. Use `./bin/bq2 sysroot --no-resume` to restart from
scratch, or `./bin/bq2 sysroot --resume` to be explicit about resuming. The resume logic
selects the earliest incomplete stage in the following order:

1. `plan-write` (workspace/plan missing)
2. `sysroot-runner` (plan present, state missing or in-progress)

The `host-setup` phase (download/extract/populate seed) runs inside `sysroot-runner`.

If a state file exists but its plan digest does not match the current plan, the resume logic
refuses to guess and requires a manual cleanup or rerun from scratch. Running `./bin/bq2`
with no arguments now prints the resume decision before the help output; it provides more
host-side context than `bin/sysroot-status`, which only inspects a state file.

## Development

- Format Crystal code with `crystal tool format`.
- Run specs with `crystal spec`.
- CI: GitHub Actions (`.github/workflows/ci.yml`) runs format + specs on push/PR; triggerable from the Actions tab.
- API docs are published via GitHub Pages after each push to `main`:
  <https://jkridner.github.io/bootstrap-qcow2/>

## Contributing

1. Fork it (<https://github.com/embedconsult/bootstrap-qcow2/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jason Kridner](https://github.com/jadonk) - creator and maintainer
