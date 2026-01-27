require "log"
require "./bootstrap-qcow2"
require "./alpine_setup"
require "./cli"
require "./build_plan_utils"
require "./sysroot_builder"
require "./sysroot_all_resume"
require "./sysroot_namespace"
require "./sysroot_runner_lib"
require "./curl_command"
require "./pkg_config_command"
require "./git_remote_https"
require "./github_cli"

Log.setup_from_env
exit Bootstrap::CLI.run
