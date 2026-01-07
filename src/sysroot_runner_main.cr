require "./sysroot_runner_lib"

# Entry-point invoked inside the chroot. By keeping this file tiny, we ensure
# the coordinator logic remains in `sysroot_runner_lib.cr`, which is covered by
# formatting and specs.
Bootstrap::SysrootRunner.run_plan
