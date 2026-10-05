#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.local-test-tmp/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME=$LAB
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_BACKEND TMUX HERDR_ENV CMUX_WORKSPACE_ID
. "$ROOT/bin/fm-backend.sh"
printf 'Running T3 environment descriptor:\n'
curl -fsS --max-time 5 http://127.0.0.1:3773/.well-known/t3/environment
printf '\nBackend with a running T3 server and no opt-in: '
actual=$(fm_backend_name)
printf '%s\n' "$actual"
[ "$actual" = tmux ]
printf 't3code\n' > "$LAB/config/backend"
printf 'Backend after explicit local opt-in: '
actual=$(fm_backend_name)
printf '%s\n' "$actual"
[ "$actual" = t3code ]
printf 'Backend after explicit environment override: '
actual=$(FM_BACKEND=tmux fm_backend_name)
printf '%s\n' "$actual"
[ "$actual" = tmux ]
fm_backend_source t3code
set +e
output=$(fm_backend_runtime_check t3code 2>&1)
rc=$?
set -e
printf 'Missing bearer refusal (exit %s):\n%s\n' "$rc" "$output"
[ "$rc" -ne 0 ]
[[ "$output" = *'has no bearer token'* ]]
[[ "$output" = *'t3@0.0.45 auth session issue'* ]]
mkdir -p "$LAB/projects/fixture" "$LAB/data/lab-auth"
cat > "$LAB/data/lab-auth/brief.md" <<'BRIEF'
# Task
## Captain's intent
Exercise T3 authentication refusal.
## Firstmate spec
Do not launch without a valid bearer.
BRIEF
set +e
output=$("$ROOT/bin/fm-spawn.sh" lab-auth "$LAB/projects/fixture" --scout --harness codex --backend t3code 2>&1)
rc=$?
set -e
printf 'Scout launch without a bearer (exit %s):\n%s\n' "$rc" "$output"
[ "$rc" -ne 0 ]
[[ "$output" = *'has no bearer token'* ]]
[ ! -e "$LAB/state/lab-auth.meta" ]
printf 'No task endpoint metadata was created by the refused launch.\n'
printf 'intentionally-invalid-live-validation-bearer\n' > "$LAB/config/t3code-token"
chmod 600 "$LAB/config/t3code-token"
set +e
output=$(fm_backend_runtime_check t3code 2>&1)
rc=$?
set -e
printf 'Real-server rejected bearer refusal (exit %s):\n%s\n' "$rc" "$output"
[ "$rc" -ne 0 ]
[[ "$output" = *'401'* ]]
[[ "$output" = *'t3@0.0.45 auth session issue'* ]]
printf 'Lab cleaned on exit. No T3 project or thread mutation was submitted.\n'
