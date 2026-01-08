# bootstrap-qcow2

[![CI](https://github.com/jkridner/bootstrap-qcow2/actions/workflows/ci.yml/badge.svg)](https://github.com/jkridner/bootstrap-qcow2/actions/workflows/ci.yml)

Build reproducible QCOW2 and chroot images with Crystal-first tooling. The sysroot builder targets aarch64 by default, caches upstream source tarballs, and stages a chroot that can rebuild the sysroot inside itself using a Crystal coordinator. Alpine’s 3.23.2 minirootfs is the current bootstrap seed, but the builder is designed so the starting rootfs, architecture, and package set remain swappable once a self-hosted rootfs is available.

## Installation

1. Install Crystal 1.18.2 or newer.
2. Run `shards install` (no postinstall steps are required).

## Usage

Generate a chrootable sysroot tarball (default workspace: `data/sysroot`) with the helper entrypoint:

```bash
crystal run src/sysroot_builder_main.cr -- --output sysroot.tar.gz
```
Pass `--skip-sources` to omit cached source archives when you only need the base rootfs and coordinator.

The tarball includes:
- Alpine minirootfs 3.23.2 (aarch64 by default)
- Cached source archives for core packages (musl, busybox, clang/LLVM, etc.)
- A serialized build plan consumed by the coordinator
- Coordinator entrypoints at `/usr/local/bin/sysroot_runner_main.cr`

Inside the chroot you can rebuild packages with the coordinator:

```bash
crystal run /usr/local/bin/sysroot_runner_main.cr
```

## Development

- Format Crystal code with `crystal tool format`.
- Run specs with `crystal spec`.
- CI: GitHub Actions (`.github/workflows/ci.yml`) runs format + specs on push/PR; triggerable from the Actions tab.
- To run privileged namespace specs locally, set `BOOTSTRAP_QCOW2_PRIVILEGED_SPECS=1` after enabling the kernel settings described below.

## Namespace setup for rootfs execution

To run build or coordinator executables inside the staged rootfs using user+mount namespaces, the host kernel must allow unprivileged user namespaces and mount namespaces. Ensure the following are enabled in your kernel configuration:

- `CONFIG_USER_NS` (user namespaces)
- `CONFIG_UTS_NS` (optional, for `sethostname`)
- `CONFIG_MOUNT_NS` (mount namespaces)
- `CONFIG_PID_NS` (optional, if you plan to isolate PIDs)

Many distros also gate unprivileged user namespaces behind a sysctl. Enable it before running the coordinator:

```bash
sudo sysctl -w kernel.unprivileged_userns_clone=1
```

When you run a coordinator executable in the rootfs, the expected flow is:

1. Unshare user + mount namespaces via `Bootstrap::Syscalls.unshare`.
2. Write `/proc/self/setgroups`, `/proc/self/uid_map`, and `/proc/self/gid_map` via `Bootstrap::Syscalls.write_proc_self_map`.
3. Make the rootfs mount private, then bind-mount the rootfs onto itself (for pivoting) using `Bootstrap::Syscalls.mount` with `MS_PRIVATE | MS_REC` and `MS_BIND | MS_REC`.
4. Use `Bootstrap::Syscalls.pivot_root` (or `Bootstrap::Syscalls.chroot` if pivoting is not required), then `Bootstrap::Syscalls.chdir("/")`.
5. Execute the coordinator entrypoint inside the rootfs (e.g. `crystal run /usr/local/bin/sysroot_runner_main.cr`).

The namespace helper in `src/namespace_wrapper.cr` is intended to wrap steps 1–2; a caller is responsible for the mount and pivot/chroot steps so the rootfs becomes the execution context.
`Bootstrap::Syscalls` raises `RuntimeError.from_errno` on syscall failures, so callers should expect exception-driven error reporting when kernel settings or privileges are missing.

## Contributing

1. Fork it (<https://github.com/your-github-user/bootstrap-qcow2/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jason Kridner](https://github.com/your-github-user) - creator and maintainer
