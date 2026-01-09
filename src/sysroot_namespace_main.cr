require "./sysroot_namespace_main_lib"

# Entry-point invoked on the host to enter a user/mount namespace before
# handing off to the sysroot coordinator.
Log.setup_from_env
Bootstrap::SysrootNamespaceMain.run
