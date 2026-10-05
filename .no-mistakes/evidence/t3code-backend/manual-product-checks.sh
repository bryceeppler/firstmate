#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.gate-test-tmp/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_BACKEND TMUX HERDR_ENV CMUX_WORKSPACE_ID ZELLIJ
. bin/fm-backend.sh
printf 'Scenario: explicit backend selection while a real T3 server is running\n'
default_backend=$(fm_backend_name)
printf 'No configured backend: %s\n' "$default_backend"
[ "$default_backend" != t3code ]
printf 't3code\n' > "$LAB/config/backend"
[ "$(fm_backend_name)" = t3code ]
printf 'config/backend=t3code: %s\n' "$(fm_backend_name)"
[ "$(FM_BACKEND=herdr fm_backend_name)" = herdr ]
printf 'Per-launch FM_BACKEND=herdr overrides t3code config: %s\n' "$(FM_BACKEND=herdr fm_backend_name)"
fm_backend_validate_harness t3code claude
fm_backend_validate_harness t3code codex
if output=$(fm_backend_validate_harness t3code omp 2>&1); then exit 1; else printf '%s\n' "$output"; fi
printf 'RESULT: explicit selection and unsupported-harness refusal verified\n\n'
fm_backend_source t3code
printf 'Scenario: live T3 capability discovery and missing-bearer refusal\n'
fm_backend_t3code_api GET /.well-known/t3/environment > "$LAB/descriptor.json"
node - "$LAB/descriptor.json" <<'JS'
const fs=require('fs'); const d=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
console.log(JSON.stringify({serverVersion:d.serverVersion,orchestrationProtocolVersion:d.orchestrationProtocolVersion,threadAutoSettleOptOut:d.capabilities.threadAutoSettleOptOut}));
if(d.orchestrationProtocolVersion!==1 || !d.capabilities.threadAutoSettleOptOut) process.exit(1);
JS
if output=$(fm_backend_runtime_check t3code 2>&1); then exit 1; else printf '%s\n' "$output"; fi
[[ "$output" == *'has no bearer token'* ]]
[[ "$output" == *'npx t3@0.0.45 auth session issue'* ]]
printf 'RESULT: missing credential refused against real server, with version-specific recovery instructions\n\n'
printf 'Scenario: protected tracked Codex environment overlay and cleanup\n'
REPO="$LAB/project"
mkdir -p "$REPO/.codex"
git -C "$REPO" init -q
printf 'model = "gpt-6-sol"\n' > "$REPO/.codex/config.toml"
git -C "$REPO" add .codex/config.toml
git -C "$REPO" -c user.name=Test -c user.email=test@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm initial
cp "$REPO/.codex/config.toml" "$LAB/original.toml"
bin/fm-t3code-codex-env.sh check "$REPO"
bin/fm-t3code-codex-env.sh install "$REPO" FM_TASK_ID=live-gate-worker FM_TASK_INBOX="$LAB/state/live-gate-worker.inbox" COMPACT_ADVISER_DISABLE=1
python3 - "$REPO/.codex/config.toml" <<'PY'
import json, sys, tomllib
with open(sys.argv[1], 'rb') as f: config=tomllib.load(f)
assert config['model']=='gpt-6-sol'
assert config['shell_environment_policy']['set']['FM_TASK_ID']=='live-gate-worker'
print(json.dumps(config))
PY
mkdir "$LAB/codex-home"
python3 - "$REPO" "$LAB/codex-home" <<'NATIVE'
import json, os, pathlib, selectors, subprocess, sys
repo, home = sys.argv[1:]
pathlib.Path(home, 'config.toml').write_text(f'[projects.{json.dumps(repo)}]\ntrust_level = "trusted"\n')
print(subprocess.check_output(['codex', '--version'], text=True).strip())
with pathlib.Path(home, 'stderr.log').open('w') as errors:
    server=subprocess.Popen(['codex', 'app-server', '--stdio'], cwd=repo, env=dict(os.environ, CODEX_HOME=home), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=True)
    try:
        def request(number, method, params):
            server.stdin.write(json.dumps(dict(id=number, method=method, params=params))+'\n'); server.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(server.stdout, selectors.EVENT_READ)
                while selector.select(20):
                    response=json.loads(server.stdout.readline())
                    if response.get('id')==number:
                        assert 'error' not in response, response
                        return response['result']
            raise TimeoutError(method)
        request(1, 'initialize', {'clientInfo': {'name': 'fm-gate-config-check', 'version': '1'}})
        result=request(2, 'config/read', {'cwd':repo, 'includeLayers':True})
        assert result['config']['model']=='gpt-6-sol'
        assert result['config']['shell_environment_policy']['set']['FM_TASK_ID']=='live-gate-worker'
        print('Native Codex config/read:', json.dumps({key:result['config'][key] for key in ['model','shell_environment_policy']}))
        result=request(3, 'command/exec', {'cwd':repo, 'command':['/usr/bin/printenv','FM_TASK_ID'], 'timeoutMs':10000, 'sandboxPolicy':{'type':'dangerFullAccess'}})
        assert result=={'exitCode':0,'stdout':'live-gate-worker\n','stderr':''}, result
        print('Native Codex command/exec:', json.dumps(result))
    finally:
        server.terminate(); server.wait(timeout=10)
NATIVE
git -C "$REPO" add -A
git -C "$REPO" diff --cached --exit-code
printf 'Real git add -A preserved the committed project configuration\n'
bin/fm-t3code-codex-env.sh cleanup "$REPO"
cmp "$LAB/original.toml" "$REPO/.codex/config.toml"
[ ! -e "$REPO/.git/fm-t3code-codex-env.json" ]
[ "$(git -C "$REPO" ls-files -v .codex/config.toml)" = 'H .codex/config.toml' ]
printf 'RESULT: original bytes and Git flag restored, overlay journal removed\n\n'
printf 'Scenario: refuse taking over existing project shell policy\n'
printf '\n[shell_environment_policy]\ninherit = "none"\n' >> "$REPO/.codex/config.toml"
git -C "$REPO" add .codex/config.toml
git -C "$REPO" -c user.name=Test -c user.email=test@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm policy
cp "$REPO/.codex/config.toml" "$LAB/policy.toml"
if output=$(bin/fm-t3code-codex-env.sh install "$REPO" FM_TASK_ID=forbidden 2>&1); then exit 1; else printf '%s\n' "$output"; fi
[[ "$output" == *"already defines [shell_environment_policy]"* ]]
cmp "$LAB/policy.toml" "$REPO/.codex/config.toml"
[ ! -e "$REPO/.git/fm-t3code-codex-env.json" ]
printf 'RESULT: existing policy remains byte-identical and no journal created\n\n'
printf 'Herdr live prerequisite probe\n'
SESSION=$(bin/fm-herdr-lab.sh name t3-merge-test)
if output=$(FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" bin/fm-herdr-lab.sh prepare "$SESSION" 2>&1); then
  printf 'Unexpected available Herdr lab: %s\n' "$SESSION"
  FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" bin/fm-herdr-lab.sh teardown "$SESSION"
  exit 1
else
  printf '%s\n' "$output"
  [[ "$output" == *'herdr is required'* ]]
fi
printf 'HERDR UNTESTED: required executable absent; no session provisioned\n'
