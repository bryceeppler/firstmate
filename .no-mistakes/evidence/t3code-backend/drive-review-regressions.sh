#!/usr/bin/env bash
set -u
. "$PWD/tests/lib.sh"
. "$PWD/tests/t3-fake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-regressions)
trap 't3_fake_stop; fm_test_cleanup' EXIT
EV=/home/bryce/.no-mistakes/evidence/01M4KJ3DAC2WMJ6DWY73BKM6PW
CRED="$TMP_ROOT/credential"
t3_fake_start "$TMP_ROOT/server"
t3_fake_case "$TMP_ROOT/case"
t3_fake_credential "$CRED"
mkdir -p "$TMP_ROOT/project" "$TMP_ROOT/worktree"
node bin/fm-t3-mcp.mjs project-ensure --root "$TMP_ROOT/project" --token-file "$CRED" > "$TMP_ROOT/project.json"
PROJECT=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).projectId)' "$TMP_ROOT/project.json")
SEL='{"instanceId":"codex","model":"gpt-6-sol"}'
t3_fake_set 'w.failTools={t3_thread_read:{code:"thread_not_found",message:"projection lag"}}'
for version in baseline current; do
  HELPER="$ROOT/bin/fm-t3-mcp.mjs"
  [ "$version" != baseline ] || HELPER="$ROOT/.validation-tmp/pre-review-mcp.mjs"
  : > "$T3_FAKE_LOG"
  node "$HELPER" launch --project "$PROJECT" --title regression --model-selection "$SEL" --worktree "$TMP_ROOT/worktree" --token-file "$CRED" > "$EV/readback-$version.json" 2> "$EV/readback-$version.stderr"
  RC=$?
  printf '%s read-back exit=%s mutations=%s\n' "$version" "$RC" "$(t3_fake_mutations)"
  cp "$T3_FAKE_LOG" "$EV/readback-$version-requests.jsonl"
  if [ "$version" = baseline ]; then expect_code 3 "$RC" 'baseline reproduces definite typed failure';
  else
    expect_code 1 "$RC" 'current read-back must stay uncertain'
    assert_contains "$(t3_fake_mutations)" t3_thread_organize 'current attempts archive'
  fi
done
t3_fake_set 'w.failTools.t3_thread_organize={code:"unavailable",message:"archive unavailable"}'
node bin/fm-t3-mcp.mjs launch --project "$PROJECT" --title regression-archive-failure --model-selection "$SEL" --worktree "$TMP_ROOT/worktree" --token-file "$CRED" > "$EV/readback-archive-failed.json" 2> "$EV/readback-archive-failed.stderr"
expect_code 1 "$?" 'failed read-back and failed archive stay uncertain'
t3_fake_set 'w.failTools={}; w.tools=["t3_thread_launch","t3_thread_send","t3_thread_read","t3_thread_wait","t3_thread_interrupt","t3_thread_organize","t3_project_list","t3_project_create","t3_environment_read"]'
node bin/fm-t3-mcp.mjs status --token-file "$CRED" > "$EV/missing-thread-list.json" 2> "$EV/missing-thread-list.stderr"
expect_code 4 "$?" 'missing thread list must refuse'
assert_contains "$(cat "$EV/missing-thread-list.stderr")" 'lacks t3_thread_list' 'gate names the exact missing capability'
printf 'Current helper retains uncertainty even when archive fails, and refuses a server missing only t3_thread_list.\n'
