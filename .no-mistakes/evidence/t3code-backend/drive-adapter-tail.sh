#!/usr/bin/env bash
set -u
t3_validation_tail() {
  original_root=$ROOT
  ROOT="$FM_VALIDATION_CODE_ROOT"
  test_secondmate_teardown_archives_thread_before_home_removal_without_project_delete
  test_secondmate_teardown_archives_thread_before_home_removal_without_project_delete codex
  test_teardown_refuses_when_t3_is_unreachable
  test_spawn_refuses_launch_settings_t3_cannot_honor claude-permission-mode auto config/claude-permission-mode=auto
  test_spawn_refuses_launch_settings_t3_cannot_honor launch-env-allowlist HOME config/launch-env-allowlist
  test_spawn_abort_returns_lease_only_after_archive ok
  test_spawn_abort_returns_lease_only_after_archive fail
  test_uncertain_thread_launch_keeps_lease
  test_misbound_thread_launch_returns_lease
  test_uncertain_launch_message_keeps_git_hooks
}
export -f t3_validation_tail
export FM_TEST_ONLY=t3_validation_tail
export FM_VALIDATION_CODE_ROOT="$PWD/.validation-tmp/product-root"
export TMPDIR="$PWD/.validation-tmp"
timeout --kill-after=5s 150s bash tests/fm-backend-t3code.test.sh
