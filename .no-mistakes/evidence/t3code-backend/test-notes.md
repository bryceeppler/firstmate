# Targeted validation

The MCP test file passed against the fake V2 server.
The adapter test file passed through worker-environment coverage, then refused its secondmate fixture because the fixture was inside the product code root.
Both secondmate launch cases passed when rerun against an unchanged copy of the product under a sibling fixture directory within this worktree.
Secondmate teardown initially hit the same directory boundary and passed for both harnesses after the same fixture correction.
The remaining adapter cases passed, including archive ordering, unreachable-server refusal, lost launch replies, and lease retention.
Backend selection and non-T3 inbox metadata checks passed.
No implementation or tracked test changes were required.

A real Codex 0.162.1 app-server loaded the installed TOML overlay and executed printenv with the expected task ID and inbox.
Cleanup restored the original CRLF configuration bytes and left the Git index unchanged.
A disposable real T3 nightly server, started with telemetry disabled and all data under the worktree, reported telemetry off through the Linux listener probe.
That server was stopped in the same evidence command.
The existing T3 server refused an intentionally invalid bearer with HTTP 401 and its actual environment reported telemetry on.
No sign-in, sign-out, pairing, or production credential mutation was performed.

The configured live guard skipped because this worktree has no T3 OAuth credential.
No credential path was supplied during this turn.
Herdr lab preparation refused because its tripwire requires a running default session and this host has none.
No Herdr lab was provisioned and no default session or fleet pane was changed.

The pre-review helper at 263d9fbc reproduced a typed read-back failure with exit 3 and no archive.
The current helper attempted archive and exited 1 instead, including when archive failed.
Separate spawn-level fake-server checks confirmed that neither outcome returned the lease or published task metadata.
A fake server missing only t3_thread_list was refused by the capability gate.
These fault-injection checks are not live agent evidence.

All transient worktree fixtures and disposable runtime state were removed after testing.
No renderer or visual layout changed, so evidence consists of CLI and native protocol responses.
