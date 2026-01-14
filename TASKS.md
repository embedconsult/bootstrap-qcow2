# Tasks

This file tracks technical-debt tasks that should be handled in-repo (Crystal-first) to preserve auditability and long-term self-hosting goals.

- Replace external `patch` invocation in `Bootstrap::SysrootRunner::SystemRunner#apply_patches` with a minimal Crystal patch applier for the patch formats we generate.
- Decide whether build failure reports should optionally capture per-step stdout/stderr (and how to bound storage) to better support build-plan iteration and back-annotation.
