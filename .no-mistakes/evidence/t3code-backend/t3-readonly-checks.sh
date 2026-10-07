#!/usr/bin/env bash
set -euo pipefail
home="$PWD/.test-phase-tmp/readonly-home"
mkdir -p "$home/config"
trap 'rm -rf "$home"' EXIT
export FM_HOME="$home"
unset FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_BACKEND TMUX HERDR_ENV CMUX_WORKSPACE_ID
. bin/fm-backend.sh
fm_backend_source t3code
printf 'Real T3 server descriptor:\n'
fm_backend_t3code_api GET /.well-known/t3/environment
printf '\nUnconfigured home backend with T3 running: '
backend=$(fm_backend_name)
printf '%s\n' "$backend"
[ "$backend" = tmux ]
printf 'Explicit T3 selection: '
FM_BACKEND=t3code
backend=$(fm_backend_name)
printf '%s\n' "$backend"
[ "$backend" = t3code ]
unset FM_BACKEND
printf 'Unsupported harness refusal:\n'
if fm_backend_validate_harness t3code pi; then exit 1; fi
printf 'Real server runtime/auth preflight:\n'
set +e
fm_backend_t3code_runtime_check
rc=$?
set -e
printf 'preflight_exit=%s\n' "$rc"
[ "$rc" -ne 0 ]
printf 'Unauthenticated thread read:\n'
set +e
fm_backend_t3code_thread_read 11111111-1111-4111-8111-111111111111 1
rc=$?
set -e
printf 'read_exit=%s\n' "$rc"
[ "$rc" -eq 2 ]
