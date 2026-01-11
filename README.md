# bootstrap-qcow2

[![CI](https://github.com/jkridner/bootstrap-qcow2/actions/workflows/ci.yml/badge.svg)](https://github.com/jkridner/bootstrap-qcow2/actions/workflows/ci.yml)

Build reproducible QCOW2 and chroot images with Crystal-first tooling. The sysroot builder targets aarch64 by default, caches upstream source tarballs, and stages a chroot that can rebuild the sysroot inside itself using a Crystal coordinator. Alpine’s 3.23.2 minirootfs is the current bootstrap seed, but the builder is designed so the starting rootfs, architecture, and package set remain swappable once a self-hosted rootfs is available.

## Installation

1. Install Crystal 1.18.2 or newer.
2. Run `shards install` (no postinstall steps are required).

## Usage

### `src/sysroot_builder_main.cr`

Utilize an existing rootfs tarball (download if necessary) and add sources to be utilized in building a new rootfs.

The default workspace is: `data/sysroot`

The workspace is made up of:
* rootfs - the output rootfs
* cache - checksums for the various downloads
* sources - downloaded tarballs

Run the helper entrypoint (use `--no-tarball` to skip creating the tarball):

```bash
crystal run src/sysroot_builder_main.cr -- --output sysroot.tar.gz
```
Pass `--skip-sources` to omit cached source archives when you only need the base rootfs and coordinator.

The rootfs output includes:
- Alpine minirootfs 3.23.2 (aarch64 by default)
- Cached source archives for core packages (musl, busybox, clang/LLVM, etc.)
- A serialized build plan consumed by the coordinator
- Coordinator entrypoints at `/usr/local/bin/sysroot_runner_main.cr`

### `src/sysroot_runner_main.cr`

Perform the source build operations inside the new rootfs.

```bash
crystal run /usr/local/bin/sysroot_runner_main.cr
```

### `src/sysroot_namespace_main.cr`

Enter the sysroot without sudo when the kernel allows unprivileged user namespaces
(`/proc/sys/kernel/unprivileged_userns_clone=1`). The rootfs defaults to
`data/sysroot/rootfs` unless overridden.

Preflight host checks (reports missing kernel/sysctl/LSM prerequisites):

```bash
crystal run src/sysroot_namespace_check_main.cr --
```

```bash
crystal run src/sysroot_namespace_main.cr -- --rootfs data/sysroot/rootfs -- crystal run /usr/local/bin/sysroot_runner_main.cr
```

This is intended for clean, sudo-less development workflows, not as a security boundary. The
namespace runner still has access to host files that are reachable from the sysroot rootfs,
and it requires kernel support for unprivileged namespaces to work at all. If your kernel
disables user namespaces, enable the setting explicitly.

## Development

- Format Crystal code with `crystal tool format`.
- Run specs with `crystal spec`.
- CI: GitHub Actions (`.github/workflows/ci.yml`) runs format + specs on push/PR; triggerable from the Actions tab.
- API docs are published via GitHub Pages after each push to `main`:
  <https://jkridner.github.io/bootstrap-qcow2/>

## Contributing

1. Fork it (<https://github.com/your-github-user/bootstrap-qcow2/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jason Kridner](https://github.com/your-github-user) - creator and maintainer
