# Live validation evidence: supervision host observer pane (PR #13 follow-up)

Every lab scenario ran against the real herdr 0.9.3 in an isolated, guarded
lab session (fm-lab-observer-4360-29598, provisioned and torn down through
bin/fm-herdr-lab.sh; the default session's tripwire held) and a disposable
marked lab home. The real `bin/fm-host-observe.sh` and the real
`bin/fm-supervision-host.sh` were driven; only the engine was the host suite's
stub (except a13, which used one real Claude print-mode turn).

| File | Scenarios |
|---|---|
| a2-a4-ensure-open-reuse.txt | non-herdr backend: one deduplicated diagnostic; herdr: open one pane running `follow`; second ensure silent |
| a3b-a6-live-render-reopen-overlap.txt | live [host]/[wake]/[outcome] rendering in the real pane; captain-closed pane reopened; two overlapping ensures open one pane, lock released |
| a7-a8-idle-replace-busy-keep.txt | Ctrl-C'd follower (lone idle zsh) replaced via confirmed close; pane busy with `sleep 600` kept, not closed, no second pane; idle again -> replaced |
| a9-a10-overrides-lock.txt | FM_STATE_OVERRIDE/FM_CONFIG_OVERRIDE carried into the pane (its follower rendered only the relocated ledger); stale lock with dead holder reclaimed; live holder makes ensure yield |
| a11-server-down-restart-restore.txt | lab server stopped: one diagnostic, no server started, deduplicated; after restart herdr restored the pane as a bare zsh and ensure replaced it |
| a12-terminated-mid-create.txt | ensure's process group TERMed while a real create's answer was held 2 s: pane still recorded, follower started, exactly one workspace after the next ensure |
| a13-real-claude-transcript.txt | a real Claude haiku print-mode conversation rendered as [engine] lines by `follow --once` and by the live pane |
| b-real-host-start-reuse.txt | real host start: pane opened 1 s after `start` and recorded in the ledger; a handled wake's [wake]/[outcome]/[host] lines in the pane; turn record's session = engine --session-id; restart reuses silently; no opt-in -> no pane |
| suite-fm-host-observe.log | tests/fm-host-observe.test.sh (21 cases, fake herdr) |
| suite-fm-supervision-host-observer-cases.log | the two new host-suite cases (blocked create never delays the first cycle; turn record names its conversation) |
| z-teardown.txt | no leftover lab processes, guarded teardown, default session intact, lab home disposed |
