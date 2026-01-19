# Tasks

This file tracks technical-debt tasks that should be handled in-repo (Crystal-first) to preserve auditability and long-term self-hosting goals.

- Replace external `patch` invocation in `Bootstrap::SysrootRunner::SystemRunner#apply_patches` with a minimal Crystal patch applier for the patch formats we generate.
- Decide whether build failure reports should optionally capture per-step stdout/stderr (and how to bound storage) to better support build-plan iteration and back-annotation.
- Simplify the host-side `bq2` build so it doesn't require the current cross-compile/`clang` link workaround (capture the needed env/linker defaults in code or tooling). Working command:
  `CC="clang -fuse-ld=lld" LD=ld.lld CLANG="clang++ -fuse-ld=lld" crystal build --cross-compile --static --target=aarch64-alpine-linux-musl src/main.cr -o bin/bq2; clang -stdlib=libc++ --rtlib=compiler-rt -fuse-ld=lld bin/bq2.o -o bin/bq2 -L/usr/lib -lssl -lcrypto -lz -lpcre2-8 -lgc -lrt -lunwind -lm`
