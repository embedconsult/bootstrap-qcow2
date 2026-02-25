require "log"
require "./bootstrap_qcow2"
require "./alpine_setup"
require "./cli"
require "./efi_app_builder"
require "./sysroot_builder"
require "./sysroot_namespace"
require "./sysroot_runner"
require "./seed_healthcheck"
require "./curl_command"
require "./pkg_config_command"
require "./git_remote_https"
require "./github_cli"

Log.setup_from_env
exit Bootstrap::CLI.run
