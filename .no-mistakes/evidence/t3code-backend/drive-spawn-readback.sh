#!/usr/bin/env bash
set -u
t3_validation_readback_lease() {
  for archive in success failure; do
    local id="t3readback-$archive" out rc
    t3_case "spawn-readback-$archive"
    t3_world_set 'w.failTools={t3_thread_read:{code:"thread_not_found",message:"projection has not caught up"}}'
    if [ "$archive" = failure ]; then t3_world_set 'w.failTools.t3_thread_organize={code:"unavailable",message:"archive unavailable"}'; fi
    t3_worker_setup "$id"
    out=$(t3_worker_spawn "$id" claude --model claude-sonnet-5); rc=$?
    printf '%s\n' "$out" > "/home/bryce/.no-mistakes/evidence/01M4KJ3DAC2WMJ6DWY73BKM6PW/spawn-readback-$archive.log"
    cp "$LOG" "/home/bryce/.no-mistakes/evidence/01M4KJ3DAC2WMJ6DWY73BKM6PW/spawn-readback-$archive-requests.jsonl"
    expect_code 1 "$rc" 'unproven launch refuses spawn'
    [ "$(t3_log_line_of 'r.tool === "treehouse" && r.args.indexOf("return") === 0')" -eq 0 ] || fail 'unproven launch returned its lease'
    [ "$(t3_dispatch_types)" = 't3_thread_launch t3_thread_organize' ] || fail 'read-back failure must launch once then attempt archive'
    assert_absent "$CASE_DIR/state/$id.meta" 'unproven launch cannot publish metadata'
    pass "spawn read-back failure retains lease with archive $archive"
  done
}
export -f t3_validation_readback_lease
TMPDIR="$PWD/.validation-tmp" FM_TEST_ONLY=t3_validation_readback_lease timeout --kill-after=5s 50s bash tests/fm-backend-t3code.test.sh
