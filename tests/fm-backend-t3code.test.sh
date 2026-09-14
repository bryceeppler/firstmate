#!/usr/bin/env bash
# tests/fm-backend-t3code.test.sh - fake-T3-server unit tests for the T3 Code
# adapter primitives in bin/backends/t3code.sh and their dispatcher routing.
# The fake is a node http server on 127.0.0.1:0 answering from a per-case
# world.json and logging every request; FM_T3CODE_ORIGIN points the adapter at
# it, so no test ever reads ~/.t3 or reaches a live server.
# shellcheck disable=SC2016  # $1/$2 inside single quotes belong to the bash -c snippet t3_run forwards.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-t3code-tests)
SERVER_DIR="$TMP_ROOT/server"
mkdir -p "$SERVER_DIR"
cat > "$SERVER_DIR/t3-fake.js" <<'JS'
const http = require("http");
const fs = require("fs");
const path = require("path");
const dir = process.argv[2];
const state = () => fs.readFileSync(path.join(dir, "case"), "utf8").trim();
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => { body += chunk; });
  req.on("end", () => {
    const caseDir = state();
    const world = JSON.parse(fs.readFileSync(path.join(caseDir, "world.json"), "utf8"));
    const url = new URL(req.url, "http://fake");
    const parsed = body ? JSON.parse(body) : null;
    fs.appendFileSync(path.join(caseDir, "requests.log"), JSON.stringify({
      method: req.method, path: url.pathname, query: Object.fromEntries(url.searchParams),
      auth: req.headers.authorization || "", body: parsed,
    }) + "\n");
    const send = (status, obj) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(obj));
    };
    if (url.pathname === "/.well-known/t3/environment") return send(200, world.descriptor);
    if ((req.headers.authorization || "") !== `Bearer ${world.token}`) {
      return send(401, { _tag: "EnvironmentUnauthorizedError", code: "unauthorized", reason: "bearer rejected" });
    }
    if (url.pathname === "/api/orchestration/shell") return send(200, world.shell);
    const thread = url.pathname.match(/^\/api\/orchestration\/threads\/([^/]+)$/);
    if (thread) {
      const hit = (world.threads || {})[thread[1]];
      if (!hit) return send(404, { _tag: "EnvironmentThreadNotFound", code: "thread_not_found", reason: "no such thread" });
      return send(200, { thread: hit });
    }
    if (url.pathname === "/api/orchestration/dispatch") {
      const reply = (world.dispatch || {})[parsed.type] || { status: 200, body: { sequence: 1 } };
      return send(reply.status, reply.body);
    }
    send(404, { reason: "unknown path" });
  });
});
server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(path.join(dir, "port"), String(server.address().port));
});
JS
printf '%s' "$TMP_ROOT" > "$SERVER_DIR/case"
node "$SERVER_DIR/t3-fake.js" "$SERVER_DIR" &
SERVER_PID=$!
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
for _ in $(seq 1 100); do
  [ -s "$SERVER_DIR/port" ] && break
  sleep 0.1
done
[ -s "$SERVER_DIR/port" ] || fail "fake T3 server did not publish its port"
ORIGIN="http://127.0.0.1:$(cat "$SERVER_DIR/port")"
TOKEN=tok-firstmate

# t3_case <name> [session-status-or-empty] -> sets CASE_DIR, CONFIG, LOG, REPO
# The default world has one project rooted at $REPO with a Claude default
# model, one thread `thread-live` in the given session status, and the token.
t3_case() {
  local name=$1 status=${2:-ready}
  CASE_DIR="$TMP_ROOT/$name"
  CONFIG="$CASE_DIR/config"
  LOG="$CASE_DIR/requests.log"
  REPO="$CASE_DIR/repo"
  mkdir -p "$CONFIG" "$REPO"
  : > "$LOG"
  printf '%s\n' "$TOKEN" > "$CONFIG/t3code-token"
  printf '%s' "$CASE_DIR" > "$SERVER_DIR/case"
  t3_world "$(t3_thread_json thread-live "$status" null)"
}

t3_thread_json() {  # <id> <session-status|none> <archivedAt-json>
  local id=$1 status=$2 archived=$3 session
  if [ "$status" = none ]; then session=null; else session="{\"threadId\":\"$id\",\"status\":\"$status\",\"activeTurnId\":null,\"lastError\":null}"; fi
  printf '{"id":"%s","projectId":"proj-1","archivedAt":%s,"latestTurn":{"turnId":"turn-1","state":"completed"},"session":%s,"messages":[{"id":"m1","role":"user","text":"do the thing"},{"id":"m2","role":"assistant","text":"done"}]}' \
    "$id" "$archived" "$session"
}

t3_world() {  # <threads-json-entries...> (each a thread object; keyed by its id)
  local entries='' t
  for t in "$@"; do
    [ -z "$entries" ] || entries="$entries,"
    entries="$entries\"$(printf '%s' "$t" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).id)')\":$t"
  done
  cat > "$CASE_DIR/world.json" <<EOF
{"token":"$TOKEN",
 "descriptor":{"serverVersion":"0.0.41-nightly.20260914.1707","capabilities":{"threadSettlement":true}},
 "shell":{"projects":[{"id":"proj-1","title":"repo","workspaceRoot":"$REPO","deletedAt":null,"defaultModelSelection":{"instanceId":"claudeAgent","model":"claude-sonnet-5"}}],"threads":[]},
 "threads":{$entries},
 "dispatch":{}}
EOF
}

t3_world_set() {  # <js-mutation over `w`>
  node -e '
const fs = require("fs");
const file = process.argv[1];
const w = JSON.parse(fs.readFileSync(file, "utf8"));
eval(process.argv[2]);
fs.writeFileSync(file, JSON.stringify(w));
' "$CASE_DIR/world.json" "$1"
}

t3_run() {  # <bash snippet run after sourcing fm-backend.sh with t3code loaded> [positional args...]
  local snippet=$1
  shift
  FM_T3CODE_ORIGIN="$ORIGIN" FM_CONFIG_OVERRIDE="$CONFIG" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3code || exit 1; '"$snippet" "$ROOT" "$@"
}

t3_request() {  # <line-number> <js expression over `r`>
  sed -n "${1}p" "$LOG" | node -e '
const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
const v = eval(process.argv[1]);
process.stdout.write(typeof v === "string" ? v : String(JSON.stringify(v)));
' "$2"
}

t3_dispatch_types() {
  node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
process.stdout.write(lines.filter((r) => r.path === "/api/orchestration/dispatch").map((r) => r.body.type).join(" "));
' "$LOG"
}

test_missing_token_names_mint_command() {
  local out status
  t3_case missing-token
  rm -f "$CONFIG/t3code-token"
  out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check must fail without a token"
  assert_contains "$out" "npx t3@0.0.41-nightly.20260914.1707 auth session issue --json --ttl 30d --label firstmate" \
    "a missing token must name the mint command with the live server version"
  assert_contains "$out" "$CONFIG/t3code-token" "a missing token must name the token file"
  pass "fm_backend_t3code_runtime_check: a missing token names the mint command"
}

test_rejected_token_names_mint_command() {
  local out status
  t3_case bad-token
  printf 'stale\n' > "$CONFIG/t3code-token"
  out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check must fail on 401"
  assert_contains "$out" "401" "a rejected token must surface the 401"
  assert_contains "$out" "npx t3@0.0.41-nightly.20260914.1707 auth session issue --json" \
    "a rejected token must name the mint command"
  pass "fm_backend_t3code_runtime_check: a 401 names the mint command"
}

test_missing_origin_names_runtime_file() {
  local out status
  t3_case no-origin
  out=$(FM_T3CODE_ORIGIN='' HOME="$CASE_DIR" FM_CONFIG_OVERRIDE="$CONFIG" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3code; fm_backend_t3code_runtime_check' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check must fail without an origin"
  assert_contains "$out" "$CASE_DIR/.t3/userdata/server-runtime.json" "the refusal must name the runtime file"
  assert_contains "$out" "FM_T3CODE_ORIGIN" "the refusal must name the override"
  pass "fm_backend_t3code_runtime_check: no origin names the runtime file and the override"
}

test_version_floor_refuses_old_server() {
  local out status
  t3_case old-server
  t3_world_set 'w.descriptor.serverVersion = "0.0.40"'
  out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check must refuse a server below 0.0.41"
  assert_contains "$out" "requires a T3 server >= 0.0.41; this one reports 0.0.40" "the floor refusal must name both versions"
  t3_world_set 'w.descriptor.serverVersion = "0.0.41-nightly.20260914.1707"; w.descriptor.capabilities = {}'
  out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check must refuse a server without threadSettlement"
  assert_contains "$out" "threadSettlement" "the capability refusal must name the capability"
  t3_world_set 'w.descriptor.capabilities = { threadSettlement: true }'
  out=$(t3_run 'fm_backend_t3code_runtime_check' 2>&1) || fail "runtime_check must accept the verified nightly: $out"
  assert_contains "$(cat "$LOG")" '"path":"/api/orchestration/shell"' "runtime_check must prove authorization against the shell snapshot"
  pass "fm_backend_t3code_runtime_check: version floor, capability, and authorization gates"
}

test_project_ensure_matches_realpath_or_creates() {
  local out id
  t3_case project-ensure
  mkdir -p "$CASE_DIR/link-parent"
  ln -s "$REPO" "$CASE_DIR/link-parent/repo-link"
  out=$(t3_run 'fm_backend_t3code_project_ensure "$1"' "$CASE_DIR/link-parent/repo-link") || fail "project_ensure failed: $out"
  [ "$out" = proj-1 ] || fail "project_ensure should match the existing project through the symlink, got '$out'"
  [ -z "$(t3_dispatch_types)" ] || fail "a matched project must not dispatch project.create"
  mkdir -p "$CASE_DIR/other"
  id=$(t3_run 'fm_backend_t3code_project_ensure "$1"' "$CASE_DIR/other") || fail "project_ensure create failed"
  case "$id" in ????????-????-????-????-????????????) ;; *) fail "project_ensure should print a uuid for a new project, got '$id'" ;; esac
  [ "$(t3_dispatch_types)" = project.create ] || fail "an unmatched project must dispatch project.create"
  [ "$(t3_request 3 'r.body.projectId')" = "$id" ] || fail "project.create must carry the printed project id"
  [ "$(t3_request 3 'r.body.workspaceRoot')" = "$CASE_DIR/other" ] || fail "project.create must carry the realpath workspaceRoot"
  [ "$(t3_request 3 'r.body.title')" = other ] || fail "project.create title should be the directory name"
  [ -n "$(t3_request 3 'r.body.commandId')" ] && [ -n "$(t3_request 3 'r.body.createdAt')" ] || fail "project.create must carry commandId and createdAt"
  pass "fm_backend_t3code_project_ensure: matches by realpath, otherwise creates with the verified payload"
}

test_model_selection_table() {
  local out
  t3_case model-selection
  out=$(t3_run 'fm_backend_t3code_model_selection claude claude-fable-5-1 high proj-1')
  [ "$out" = '{"instanceId":"claudeAgent","model":"claude-fable-5-1","options":[{"id":"effort","value":"high"}]}' ] \
    || fail "claude effort should ride options id effort, got '$out'"
  out=$(t3_run 'fm_backend_t3code_model_selection codex gpt-5.6-sol xhigh proj-1')
  [ "$out" = '{"instanceId":"codex","model":"gpt-5.6-sol","options":[{"id":"reasoningEffort","value":"xhigh"}]}' ] \
    || fail "codex effort should ride options id reasoningEffort, got '$out'"
  out=$(t3_run 'fm_backend_t3code_model_selection claude claude-sonnet-5 default proj-1')
  [ "$out" = '{"instanceId":"claudeAgent","model":"claude-sonnet-5"}' ] || fail "effort default must omit options, got '$out'"
  out=$(t3_run 'fm_backend_t3code_model_selection claude default max proj-1')
  [ "$out" = '{"instanceId":"claudeAgent","model":"claude-sonnet-5","options":[{"id":"effort","value":"max"}]}' ] \
    || fail "model default should take the project default and still apply effort, got '$out'"
  out=$(t3_run 'fm_backend_t3code_model_selection codex gpt-5.6-sol max proj-1' 2>&1) && fail "codex max must be refused"
  assert_contains "$out" "cannot pass effort 'max' to harness 'codex'" "the codex max refusal must name the harness and value"
  out=$(t3_run 'fm_backend_t3code_model_selection pi x high proj-1' 2>&1) && fail "a non-T3 harness must be refused"
  assert_contains "$out" "only the claude and codex harnesses" "the harness refusal must name the supported set"
  t3_world_set 'w.shell.projects[0].defaultModelSelection = null'
  out=$(t3_run 'fm_backend_t3code_model_selection claude default default proj-1' 2>&1) && fail "model default with no project default must be refused"
  assert_contains "$out" "has no default model; pass --model" "the default-model refusal must name the fix"
  printf 'claude=claude-pool\n' > "$CONFIG/t3code-instances"
  out=$(t3_run 'fm_backend_t3code_model_selection claude claude-fable-5-1 default proj-1')
  [ "$out" = '{"instanceId":"claude-pool","model":"claude-fable-5-1"}' ] || fail "config/t3code-instances must override the instance id, got '$out'"
  pass "fm_backend_t3code_model_selection: effort option ids per harness, default handling, instances file"
}

test_thread_create_and_turn_start_payloads() {
  local id selection
  t3_case thread-lifecycle
  selection='{"instanceId":"claudeAgent","model":"claude-sonnet-5"}'
  id=$(t3_run 'fm_backend_t3code_thread_create proj-1 fm-task1 fm/task1 "$1" "$2"' "$REPO" "$selection") || fail "thread_create failed"
  case "$id" in ????????-????-????-????-????????????) ;; *) fail "thread_create should print a uuid, got '$id'" ;; esac
  [ "$(t3_request 1 'r.body.type')" = thread.create ] || fail "thread_create must dispatch thread.create"
  [ "$(t3_request 1 'r.body.threadId')" = "$id" ] || fail "thread.create must carry the printed thread id"
  [ "$(t3_request 1 'r.body.branch')" = fm/task1 ] || fail "thread.create must carry the branch"
  [ "$(t3_request 1 'r.body.worktreePath')" = "$REPO" ] || fail "thread.create must carry the worktree path"
  [ "$(t3_request 1 'r.body.runtimeMode')" = full-access ] || fail "thread.create must run full-access"
  [ "$(t3_request 1 'r.body.interactionMode')" = default ] || fail "thread.create must use the default interaction mode"
  [ "$(t3_request 1 'r.body.modelSelection')" = "$selection" ] || fail "thread.create must carry the model selection verbatim"
  [ "$(t3_request 1 'r.auth')" = "Bearer $TOKEN" ] || fail "dispatch must carry the configured bearer"
  t3_run 'fm_backend_t3code_turn_start "$1" "$(printf "line one\nline two")" "$2"' "$id" "$selection" || fail "turn_start failed"
  [ "$(t3_request 2 'r.body.type')" = thread.turn.start ] || fail "turn_start must dispatch thread.turn.start"
  [ "$(t3_request 2 'r.body.message.text')" = $'line one\nline two' ] || fail "turn_start must carry the text verbatim"
  [ "$(t3_request 2 'r.body.message.role')" = user ] || fail "turn_start message role must be user"
  [ "$(t3_request 2 'r.body.message.attachments')" = '[]' ] || fail "turn_start must send empty attachments"
  [ -n "$(t3_request 2 'r.body.message.messageId')" ] || fail "turn_start must mint a messageId"
  [ "$(t3_request 2 'r.body.modelSelection')" = "$selection" ] || fail "turn_start must forward the model selection when given"
  t3_run 'fm_backend_t3code_turn_start "$1" steer' "$id" || fail "turn_start without selection failed"
  [ "$(t3_request 3 'r.body.modelSelection')" = undefined ] || fail "a steer without a selection must omit modelSelection"
  pass "fm_backend_t3code_thread_create/turn_start: verified command payloads"
}

test_capture_renders_messages_and_status() {
  local out
  t3_case capture running
  out=$(t3_run 'fm_backend_t3code_capture thread-live 40')
  [ "$out" = $'[user] do the thing\n[assistant] done\nt3code: session=running turn=completed' ] \
    || fail "capture should render [role] text then the status line, got '$out'"
  out=$(t3_run 'fm_backend_t3code_capture thread-live 1')
  [ "$out" = 't3code: session=running turn=completed' ] || fail "capture must honour the line bound, got '$out'"
  [ "$(t3_request 1 'r.query.turnLimit')" = 5 ] || fail "capture must read with turnLimit=5"
  t3_run 'fm_backend_t3code_capture thread-gone 40' 2>/dev/null && fail "capture of a missing thread must fail"
  pass "fm_backend_t3code_capture: renders the transcript tail and the session line"
}

test_send_key_mapping() {
  local out
  t3_case send-key running
  t3_run 'fm_backend_t3code_send_key thread-live Escape; fm_backend_t3code_send_key thread-live C-c' || fail "Escape and C-c should succeed"
  [ "$(t3_dispatch_types)" = "thread.turn.interrupt thread.turn.interrupt" ] || fail "Escape and C-c must each dispatch thread.turn.interrupt, got '$(t3_dispatch_types)'"
  [ "$(t3_request 1 'r.body.threadId')" = thread-live ] || fail "interrupt must name the thread"
  t3_run 'fm_backend_t3code_send_key thread-live Enter' || fail "Enter must be a no-op success"
  [ "$(t3_dispatch_types)" = "thread.turn.interrupt thread.turn.interrupt" ] || fail "Enter must dispatch nothing"
  out=$(t3_run 'fm_backend_t3code_send_key thread-live C-u' 2>&1) && fail "C-u must be refused"
  assert_contains "$out" "unsupported T3 key 'C-u'" "the refusal must name the key"
  pass "fm_backend_t3code_send_key: Escape and C-c interrupt, Enter no-ops, others refuse"
}

test_send_text_submit_verdicts() {
  local out
  t3_case send-text ready
  out=$(t3_run 'fm_backend_t3code_send_text_submit thread-live "hello" 3 0.01 0.01')
  [ "$out" = empty ] || fail "an accepted turn.start must report empty, got '$out'"
  t3_world_set 'w.dispatch["thread.turn.start"] = { status: 409, body: { _tag: "X", code: "session_busy", reason: "turn already queued" } }'
  out=$(t3_run 'fm_backend_t3code_send_text_submit thread-live "hello" 3 0.01 0.01' 2>/dev/null)
  [ "$out" = send-failed ] || fail "a rejected turn.start must report send-failed, got '$out'"
  pass "fm_backend_t3code_send_text_submit: empty on accept, send-failed on rejection"
}

test_status_table() {
  local status expect got
  t3_case status-table
  for status in starting:busy:alive running:busy:alive ready:idle:alive idle:idle:alive interrupted:idle:alive stopped:idle:dead error:unknown:dead none:idle:alive; do
    t3_world "$(t3_thread_json thread-live "${status%%:*}" null)"
    expect=${status#*:}
    got="$(t3_run 'fm_backend_t3code_busy_state thread-live'):$(t3_run 'fm_backend_t3code_agent_state thread-live')"
    [ "$got" = "$expect" ] || fail "session ${status%%:*} should classify $expect, got $got"
  done
  t3_world "$(t3_thread_json thread-live ready '"2026-09-14T00:00:00.000Z"')"
  got="$(t3_run 'fm_backend_t3code_busy_state thread-live'):$(t3_run 'fm_backend_t3code_agent_state thread-live')"
  [ "$got" = unknown:missing ] || fail "an archived thread should classify unknown:missing, got $got"
  t3_run 'fm_backend_t3code_target_exists thread-live' && fail "an archived thread must not exist"
  [ "$(t3_run 'fm_backend_t3code_composer_state thread-live')" = unknown ] || fail "an archived thread's composer is unknown"
  got="$(t3_run 'fm_backend_t3code_busy_state thread-gone'):$(t3_run 'fm_backend_t3code_agent_state thread-gone')"
  [ "$got" = unknown:missing ] || fail "HTTP 404 should classify unknown:missing, got $got"
  got="$(FM_T3CODE_ORIGIN=http://127.0.0.1:9 FM_CONFIG_OVERRIDE="$CONFIG" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3code; printf "%s:%s" "$(fm_backend_t3code_busy_state thread-live)" "$(fm_backend_t3code_agent_state thread-live)"' "$ROOT")"
  [ "$got" = unknown:unreadable ] || fail "an unreachable server should classify unknown:unreadable, got $got"
  t3_world "$(t3_thread_json thread-live ready null)"
  t3_run 'fm_backend_t3code_target_exists thread-live' || fail "a live thread must exist"
  [ "$(t3_run 'fm_backend_t3code_composer_state thread-live')" = empty ] || fail "a live thread's composer is always empty"
  pass "t3code status table: every session status, archived, 404, and unreachable rows"
}

test_kill_stops_then_archives_and_tolerates_gone() {
  t3_case kill running
  t3_run 'fm_backend_t3code_kill thread-live' || fail "kill of a live thread should succeed"
  [ "$(t3_dispatch_types)" = "thread.session.stop thread.archive" ] || fail "kill must stop then archive, got '$(t3_dispatch_types)'"
  [ "$(t3_request 2 'r.body.threadId')" = thread-live ] && [ -n "$(t3_request 2 'r.body.createdAt')" ] || fail "session.stop must carry threadId and createdAt"
  [ "$(t3_request 3 'r.body.createdAt')" = undefined ] || fail "thread.archive carries no createdAt"
  : > "$LOG"
  t3_run 'fm_backend_t3code_kill thread-gone' || fail "kill of a deleted thread (404) is success"
  [ -z "$(t3_dispatch_types)" ] || fail "a 404 thread must dispatch nothing"
  t3_world "$(t3_thread_json thread-live ready '"2026-09-14T00:00:00.000Z"')"
  : > "$LOG"
  t3_run 'fm_backend_t3code_kill thread-live' || fail "kill of an archived thread is success"
  [ -z "$(t3_dispatch_types)" ] || fail "an archived thread must dispatch nothing"
  t3_world "$(t3_thread_json thread-live running null)"
  t3_world_set 'w.dispatch["thread.archive"] = { status: 500, body: { reason: "boom" } }'
  t3_run 'fm_backend_t3code_kill thread-live' 2>/dev/null && fail "a failed archive must fail the kill"
  pass "fm_backend_t3code_kill: stop then archive, idempotent on archived and 404, loud on failure"
}

test_dispatcher_routes_and_validates_t3code_meta() {
  local state id out thread=1b6d0a1e-1e5a-4c2a-9c3b-0123456789ab
  t3_case dispatcher ready
  t3_world "$(t3_thread_json "$thread" ready null)"
  id=t3taskz1
  state="$CASE_DIR/state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=$REPO" "project=$REPO" "harness=claude" "kind=scout" \
    "backend=t3code" "t3_thread_id=$thread" "t3_project_id=proj-1"
  out=$(t3_run 'fm_backend_capture t3code "$1" 1' "$thread") || fail "dispatcher capture failed"
  [ "$out" = 't3code: session=ready turn=completed' ] || fail "dispatcher must route capture to the adapter, got '$out'"
  t3_run 'fm_backend_target_exists t3code "$1"' "$thread" || fail "dispatcher target_exists must route to the adapter"
  [ "$(t3_run 'fm_backend_busy_state t3code "$1"' "$thread")" = idle ] || fail "dispatcher busy_state must route to the adapter"
  [ "$(t3_run 'fm_backend_agent_state t3code "$1"' "$thread")" = alive ] || fail "dispatcher agent_state must route to the adapter"
  [ "$(t3_run 'fm_backend_composer_state t3code "$1" fm-x' "$thread")" = empty ] || fail "dispatcher composer_state must route to the adapter"
  [ "$(t3_run 'fm_backend_send_text_submit t3code "$1" hi 1 0 0 fm-x' "$thread")" = empty ] || fail "dispatcher send_text_submit must route to the adapter"
  out=$(t3_run 'fm_backend_validate_task_endpoint "$1" "$2" && printf "%s %s" "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET"' "$state/$id.meta" "$id") \
    || fail "a well-formed t3code record must validate: $out"
  [ "$out" = "t3code $thread" ] || fail "validation must bind the thread id as the target, got '$out'"
  [ "$(t3_run 'fm_backend_resolve_selector "$1" "$2"' "fm-$id" "$state")" = "$thread" ] || fail "fm-<id> must resolve to t3_thread_id"
  [ "$(t3_run 'fm_backend_of_selector "$1" "$1" "$2"' "$thread" "$state")" = t3code ] || fail "a raw thread id selector must inherit backend=t3code"
  fm_write_meta "$state/$id.meta" "window=fm-$id" "endpoint_task_id=$id" "worktree=$REPO" "project=$REPO" "backend=t3code"
  out=$(t3_run 'fm_backend_validate_task_endpoint "$1" "$2"' "$state/$id.meta" "$id" 2>&1) && fail "a record without t3_thread_id must refuse"
  assert_contains "$out" "missing t3_thread_id" "the refusal must name the missing field"
  fm_write_meta "$state/$id.meta" "window=fm-$id" "endpoint_task_id=$id" "worktree=$REPO" "project=$REPO" "backend=t3code" "t3_thread_id=thread;rm"
  t3_run 'fm_backend_validate_task_endpoint "$1" "$2"' "$state/$id.meta" "$id" 2>/dev/null && fail "a thread id outside the uuid charset must refuse"
  [ "$(t3_run 'fm_backend_required_tools t3code')" = 'node treehouse' ] || fail "t3code requires node and treehouse"
  pass "fm-backend dispatcher: routes every t3code primitive, validates and resolves t3_thread_id records"
}

test_busy_classify_trusts_native_idle_and_busy() {
  local state id out
  t3_case busy-classify running
  id=t3busyz1
  state="$CASE_DIR/state"; mkdir -p "$state"
  out=$(FM_T3CODE_ORIGIN="$ORIGIN" FM_CONFIG_OVERRIDE="$CONFIG" bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/fm-busy-lib.sh"; fm_busy_classify t3code thread-live claude "$1" "$2"' "$ROOT" "$id" "$state")
  [ "$out" = "busy t3code-native" ] || fail "a running t3code session with no record must classify busy t3code-native, got '$out'"
  t3_world "$(t3_thread_json thread-live ready null)"
  out=$(FM_T3CODE_ORIGIN="$ORIGIN" FM_CONFIG_OVERRIDE="$CONFIG" bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/fm-busy-lib.sh"; fm_busy_classify t3code thread-live claude "$1" "$2"' "$ROOT" "$id" "$state")
  [ "$out" = "idle t3code-native" ] || fail "a ready t3code session with no record must classify idle t3code-native, got '$out'"
  t3_world "$(t3_thread_json thread-live error null)"
  out=$(FM_T3CODE_ORIGIN="$ORIGIN" FM_CONFIG_OVERRIDE="$CONFIG" bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/fm-busy-lib.sh"; fm_busy_classify t3code thread-live claude "$1" "$2"' "$ROOT" "$id" "$state")
  [ "$out" = "unknown missing" ] || fail "an error session must fall through to unknown missing, got '$out'"
  pass "fm_busy_classify: t3code native busy and idle are both trusted without a record"
}

test_control_lib_tables() {
  bash -c '. "$0/bin/fm-control-lib.sh"; fm_control_backend_supports_key t3code Escape && fm_control_backend_supports_key t3code Enter && fm_control_backend_supports_key t3code C-c && ! fm_control_backend_supports_key t3code C-u && fm_control_backend_state_verified t3code' "$ROOT" \
    || fail "control-lib must accept Enter/Escape/C-c, refuse C-u, and treat t3code as state-verified"
  pass "fm-control-lib: t3code key set and state-verified membership"
}

test_missing_token_names_mint_command
test_rejected_token_names_mint_command
test_missing_origin_names_runtime_file
test_version_floor_refuses_old_server
test_project_ensure_matches_realpath_or_creates
test_model_selection_table
test_thread_create_and_turn_start_payloads
test_capture_renders_messages_and_status
test_send_key_mapping
test_send_text_submit_verdicts
test_status_table
test_kill_stops_then_archives_and_tolerates_gone
test_dispatcher_routes_and_validates_t3code_meta
test_busy_classify_trusts_native_idle_and_busy
test_control_lib_tables
