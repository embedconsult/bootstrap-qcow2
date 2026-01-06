# bootstrap-qcow2

[![CI](https://github.com/jkridner/bootstrap-qcow2/actions/workflows/ci.yml/badge.svg)](https://github.com/jkridner/bootstrap-qcow2/actions/workflows/ci.yml)

Build reproducible QCOW2 and chroot images with Crystal-first tooling. The sysroot builder targets aarch64 by default, caches upstream source tarballs, and stages a chroot that can rebuild the sysroot inside itself using a Crystal coordinator. Alpine’s minirootfs is the current bootstrap seed, but the builder is designed so the starting rootfs, architecture, and package set remain swappable once a self-hosted rootfs is available.

## Installation

1. Install Crystal 1.18.2 or newer.
2. Run `shards install` (no postinstall steps are required).

## Usage

Generate a chrootable sysroot tarball (default workspace: `data/sysroot`) with the helper entrypoint:

```bash
crystal run src/sysroot_builder_main.cr -- --output sysroot.tar.gz
```

The tarball includes:
- Alpine minirootfs (aarch64 by default)
- Cached source archives for core packages (musl, busybox, clang/LLVM, etc.)
- A serialized build plan consumed by the coordinator
- Coordinator entrypoints at `/usr/local/bin/sysroot_runner_main.cr`

Inside the chroot you can rebuild packages with the coordinator (uses `Process.chroot` instead of the `chroot` binary):

```bash
crystal run /usr/local/bin/sysroot_runner_main.cr
```

## Development

- Format Crystal code with `crystal tool format`.
- Run specs with `crystal spec`.
- CI: GitHub Actions (`.github/workflows/ci.yml`) runs format + specs on push/PR; triggerable from the Actions tab.

## Contributing

1. Fork it (<https://github.com/your-github-user/bootstrap-qcow2/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jason Kridner](https://github.com/your-github-user) - creator and maintainer
