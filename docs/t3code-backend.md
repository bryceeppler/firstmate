# T3 Code runtime backend

T3 Code is an experimental backend in which the T3 Code server owns the agent session while Treehouse keeps owning the task worktree.
Firstmate drives the server over its HTTP orchestration API with a CLI-issued bearer; nothing is ever typed into a terminal.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick T3 Code when you already run the T3 Code app and want each task to be a visible T3 thread working in a Treehouse worktree.
T3 Code is explicit-only, does not support secondmate spawns, and runs only the `claude` and `codex` harnesses; every other harness is refused at spawn.

Prerequisites:

- A running T3 Code server, version 0.0.41 or newer, whose `GET /.well-known/t3/environment` descriptor reports the `threadSettlement` capability.
- `node`, which the adapter uses to speak HTTP, and `treehouse`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select T3 Code with local `config/backend` containing `t3code`, `FM_BACKEND=t3code` for one launch, or `--backend t3code` for one task.
It is never auto-detected.

The server origin is read from `~/.t3/userdata/server-runtime.json` (`origin`); `FM_T3CODE_ORIGIN` overrides it.
Before any spawn mutates repository state, Firstmate requires the descriptor to pass the version floor and capability check and requires an authorized read of `GET /api/orchestration/shell`.

### Bearer token

Mint a session with the version the descriptor reports:

```sh
npx t3@<serverVersion> auth session issue --json --ttl 30d --label firstmate
```

Write the JSON `token` field to `config/t3code-token` as one line with mode 0600.
The session carries the `orchestration:read` and `orchestration:operate` scopes, and desktop restarts do not revoke it.
A missing token or a 401 refuses with one error that names this mint command with the live server version.

### Provider instances and models

`config/t3code-instances` maps a harness to a T3 provider instance id, one `harness=instanceId` line each; the defaults are `claude=claudeAgent` and `codex=codex`.
A task's `--model` must be a slug in T3's model catalog; an unknown slug leaves the session in `error`.
`--model default` uses the T3 project's default model selection and refuses when the project has none.
`--effort` rides as a provider option, `effort` for claude (`low|medium|high|xhigh|max`) and `reasoningEffort` for codex (`low|medium|high|xhigh`); `default` sends no option, and a value outside a harness's set is refused.

## Task shape and metadata

Each task has one Treehouse worktree, leased durably with `treehouse get --lease --lease-holder <id>`, and one T3 thread whose `worktreePath` is that worktree.
The normal isolation and unlanded-work refusal rules still apply.

```text
backend=t3code
window=fm-<id>
t3_thread_id=<uuid>
t3_project_id=<uuid>
worktree=<absolute Treehouse slot path>
```

`window=` remains the caller-facing Firstmate alias.
`t3_thread_id=` is the backend authority used by every operation and cleanup path.

## Current lifecycle and safety

Spawn matches the project by real path against the T3 projects' `workspaceRoot` (creating one with `project.create` when absent), leases the worktree, creates the thread on it with `thread.create` (branch, worktree path, `full-access` runtime mode, the model selection), installs the harness hooks, records metadata, and then starts the launch turn with `thread.turn.start` carrying the encoded brief.
Exact command payloads are owned by `bin/backends/t3code.sh`.

`fm-peek.sh` renders `[role] text` for the recent messages followed by a `t3code: session=<status> turn=<state>` line.
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and its doorbell is a `thread.turn.start` on the thread.
Sent while a turn runs, Claude treats that as a steer into the live turn.
Escape and Ctrl-C are both a `thread.turn.interrupt`; Enter is a no-op and Ctrl-U is unsupported.

The watcher and `fm-crew-state.sh` read the server's own session status through one table in the adapter, and both native verdicts are trusted ahead of every harness gate and hook record (source `t3code-native`), so a codex crew settles from T3's status even though codex has no verified hook writer; only an unreadable server falls through to the ordinary contract.
T3 launches Claude with the `user,project,local` setting sources, so the worktree `.claude/settings.local.json` busy hooks fire as on every other backend.

Cleanup keeps all shared Firstmate safety checks.
Before the slot returns to the pool, teardown stops the session and archives the thread (`thread.session.stop`, then `thread.archive`), because a live thread whose worktree path disappears re-creates that worktree on its next turn.
The kill is idempotent, so an already archived or deleted thread is the end state, and an unreachable server refuses the teardown rather than returning a slot a live thread still points at.
Archiving keeps the transcript visible in T3 Code.
T3 renames a thread's branch on the first turn only when it matches `t3code/<8hex>` or `t3code/<uuid>`, so Treehouse branches are left alone.

## Switching back to Herdr

Write `herdr` to `config/backend` and every new spawn uses the Herdr backend again.
In-flight tasks keep the backend recorded in their own `state/<id>.meta`, so they are supervised and torn down through T3 Code until they finish.
The branch can be left with `git switch main`.

## Active limits

- T3 Code is explicit-only and experimental, refuses secondmate spawns, and runs only `claude` and `codex`.
- There is no channel for the pane-typed exports, so `GOTMPDIR`, `FM_TASK_ID`, and `TRACEPARENT` never reach a T3-launched agent; the per-task temp root is still created and removed, but Go builds do not use it and trace context is not delivered.
- A mid-turn steer on Codex is forwarded to the app-server turn start and is unverified.
- Ctrl-U is unsupported.
- The version floor ignores a prerelease tag, so the verified `0.0.41` nightly passes.

## Regression entry points

```sh
tests/fm-backend-t3code.test.sh
tests/fm-backend.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#t3-code) records the live probe.
