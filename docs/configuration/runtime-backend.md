# Runtime backend

Part of the [configuration reference](../configuration.md).

## Runtime backend (config/backend / FM_BACKEND)

For spawn-capable adapters, the runtime session-provider backend controls where task windows/endpoints are created, captured, sent to, watched, and killed.

| Runtime backend | Verification status | Reference |
| --- | --- | --- |
| `tmux` | Verified reference backend | [`docs/tmux-backend.md`](../tmux-backend.md) |
| `herdr` | Has its own required CI lane | [`docs/herdr-backend.md`](../herdr-backend.md) |
| `zellij` | Experimental; no dedicated real-backend CI lane | [`docs/zellij-backend.md`](../zellij-backend.md) |
| `orca` | Experimental; no dedicated real-backend CI lane | [`docs/orca-backend.md`](../orca-backend.md) |
| `cmux` | Experimental; no dedicated real-backend CI lane | [`docs/cmux-backend.md`](../cmux-backend.md) |
| `paseo` | Experimental; no dedicated real-backend CI lane | [`docs/paseo-backend.md`](../paseo-backend.md) |
| `rex` | Experimental; no dedicated real-backend CI lane | [`docs/rex-backend.md`](../rex-backend.md) |
| `t3code` | Experimental; no dedicated real-backend CI lane | [`docs/t3code-backend.md`](../t3code-backend.md) |
| `tern` | Experimental; no dedicated real-backend CI lane | [`docs/tern-backend.md`](../tern-backend.md) |
| `hc` | Experimental; the `tests-hc` lane runs the hc family against the pinned build | [`docs/hc-backend.md`](../hc-backend.md) |

Treehouse remains the worktree provider for tmux, herdr, zellij, cmux, paseo, rex, t3code, tern, and hc, since herdr, zellij, cmux, paseo, rex, t3code, tern, and hc are session providers only; Orca provides both the task worktree and terminal endpoint.

### Backend selection order

New spawns choose the backend in this order:

1. An explicit `--backend` flag authorized for that exact task by a present captain instruction or the task's own accepted brief.
   A later task cannot inherit that authority by analogy.
2. `FM_BACKEND`.
3. The first non-empty line of local, gitignored `config/backend`.
4. Runtime auto-detection from `$TMUX`, `HERDR_ENV=1`, `TERM_PROGRAM=rex` with `REX_BLOCK`, cmux runtime signals, or the Herdr app signal.
5. Default `tmux`.

If more than one runtime marker is present, detection resolves innermost-first: `$TMUX` is checked before `HERDR_ENV=1`, which is checked before Rex's `TERM_PROGRAM=rex` with `REX_BLOCK`, which is checked before cmux's primary `CMUX_WORKSPACE_ID` marker and its documented fallback signals - tmux, herdr, or Rex started from inside a cmux terminal is the innermost, currently-executing layer, while cmux itself (a terminal application, not a nestable multiplexer) is checked after those nested runtimes.
The Herdr app signal is checked after cmux; contradictory marker sets keep the earlier surface's verdict instead of switching.
[`docs/hc-backend.md`](../hc-backend.md#runtime-auto-detection) owns what the app-terminal signal means and why an open app window alone is not one.
See [`docs/cmux-backend.md`](../cmux-backend.md#runtime-detection) for why cmux can be selected when `CMUX_WORKSPACE_ID` is absent, and [`docs/rex-backend.md`](../rex-backend.md#auto-detection) for why a nested tmux or Herdr inside a Rex block is never read as Rex.

Auto-detected Herdr and Rex stay silent like tmux, while auto-detected cmux prints a stderr notice naming `config/backend` and `--backend tmux` because cmux remains experimental.
For hc notices, missing-piece handling, and detection metadata, see [Runtime auto-detection](../hc-backend.md#runtime-auto-detection).
T3 Code, Zellij, Orca, Paseo, and tern are never auto-detected; select them by putting the name in a local `config/backend` file, by exporting `FM_BACKEND=<name>`, or by telling the first mate in chat.
Paseo and tern stay explicit-only because their runtime markers leak into every descendant process, so they cannot stand for a selection (see [`docs/paseo-backend.md`](../paseo-backend.md#selection-is-explicit) and [`docs/tern-backend.md`](../tern-backend.md#selection-is-explicit)); bare `HC_TERMINAL_*` markers leak the same way, so hc detection requires the Herdr app's own signal.

### Accepted backends and secondmate limits

Any value other than `tmux`, `herdr`, `zellij`, `orca`, `cmux`, `paseo`, `rex`, `t3code`, `tern`, or `hc` is rejected until another adapter is implemented and verified.
`fm-spawn.sh` accepts `tmux`, `herdr`, `zellij`, `orca`, `cmux`, `paseo`, `rex`, `t3code`, `tern`, and `hc` for ship and scout tasks; `backend=orca`, `backend=cmux`, `backend=paseo`, `backend=tern`, and `backend=hc` all still refuse `--secondmate` until secondmate launch semantics are designed for each, while `backend=t3code` supports secondmates and runs only the `claude` and `codex` harnesses.

`codex-app` is not an accepted runtime backend yet; [`docs/codex-app-backend.md`](../codex-app-backend.md) owns the Codex App boundary.

### Liveness classification

The session-start secondmate liveness sweep and the watcher's secondmate liveness tick use the recovery-grade `fm_backend_agent_state` classifier where verified.
The comment above that function in `bin/fm-backend.sh` is the single owner of its detailed state contract and recovery authorization.

The compatibility helper `fm_backend_agent_alive` continues to collapse those detailed results to `alive`, `dead`, or `unknown` for older callers.

### Dependency and socket checks

- A herdr spawn additionally version-gates against the installed `herdr` binary's protocol and requires `jq`, refusing loudly on an incompatible or missing installation.

- A zellij spawn additionally version-gates against the installed `zellij` binary's version and requires `jq`, refusing loudly when either is missing or the version is older than 0.44.

- A cmux spawn additionally version-gates against the installed `cmux` binary's version, requires `jq`, and requires the control socket to be reachable and accessible (see [`docs/cmux-backend.md`](../cmux-backend.md) "Setup" for the one-time socket-access configuration this needs; Automation mode is the recommended socket control mode, with Password mode supported via `config/cmux-socket-password`), refusing loudly and non-retryably on a `cmuxOnly`/unauthenticated socket.

- A paseo spawn additionally version-gates against the installed `paseo` binary's version, requires `jq`, and starts the daemon with `paseo start` only when it is simply not up yet (see [`docs/paseo-backend.md`](../paseo-backend.md) "Setup"), refusing loudly on a missing CLI, an old version, or an unreachable daemon.

- A rex spawn additionally gates both the `rex` CLI and the running Rex server at API revision 5 or newer and requires `jq` (see [`docs/rex-backend.md`](../rex-backend.md) "Setup"), refusing loudly on a missing CLI, an older API revision, or a server that cannot be reached or started.
- A tern spawn requires `tern` and `jq`, refusing loudly when either is missing (see [`docs/tern-backend.md`](../tern-backend.md) "Setup"); bootstrap reports a missing `tern` as `MISSING_MANUAL` with `https://stencil.so/tern`.
- For hc spawn prerequisites, binary resolution, and compatibility gates, see [`docs/hc-backend.md`](../hc-backend.md#setup).

A backend spawn refusal from a missing dependency, version gate, or unauthenticated socket is terminal for that selected backend; firstmate surfaces it as a blocker instead of silently retrying another backend.

### Task metadata

Task meta records `backend=` only for a non-default backend; an absent `backend=` means `tmux`, preserving existing default-path meta files.

- Every new task records `endpoint_task_id=` as the cleanup binding between the metadata filename and its opaque runtime endpoint.

- A herdr task additionally records `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`.

- A zellij task additionally records `zellij_session=`, `zellij_tab_id=`, and `zellij_pane_id=`.
- A paseo task additionally records `paseo_terminal_id=` and `paseo_workspace_id=`, with the terminal NAME as routing authority (see [`docs/paseo-backend.md`](../paseo-backend.md) "Task shape and metadata").
- A rex task additionally records `rex_server=`, `rex_session_id=`, `rex_window_id=`, and `rex_block_id=`, with the immutable block id as routing authority (see [`docs/rex-backend.md`](../rex-backend.md) "Task shape and metadata").

- An Orca task additionally records `orca_worktree_id=` and `terminal=`, with `window=fm-<id>` kept as the shared firstmate alias.

- A cmux task additionally records `cmux_workspace_id=` and `cmux_surface_id=`.
- A t3code task additionally records `t3_thread_id=` and `t3_project_id=`, with `window=fm-<id>` kept as the shared firstmate alias.

- A tern task additionally records `tern_session_id=`, `tern_tab_id=`, and `tern_block_id=`.
- For hc endpoint fields and automatic-selection provenance, see [Task shape and metadata](../hc-backend.md#task-shape-and-metadata).

- A `bin/fm-pr-merge.sh --update-branch` whose update lands appends `merge_update_branch=<new head> <base tip>`, so a later merge run does not count that one merge commit against the default squash.
- A merge that flattened merge commits under an attended `bin/fm-pr-merge.sh --allow-flatten <reason>` appends `merge_flatten_override=<reason>` to the task record.
- An adopted task, written by `bin/fm-pr-adopt.sh <task-id> <pr-url> --mode no-mistakes --yolo <on|off> [--project <dir>]` for an open GitHub PR that has no task record in this home, records only `worktree=` (a path under `state/` that never exists), `project=`, `kind=ship`, `mode=`, `yolo=`, `adopted=1`, and `adopted_at=`, then `bin/fm-pr-check.sh` adds `pr=` and `pr_head=` from the forge.
  It has no window, endpoint, branch, incarnation, or `office=`, so `bin/fm-pr-merge.sh` decides its merge under every unchanged guard, an office home refuses it, and `bin/fm-teardown.sh` cleans it as a windowless record; the script's header owns the field inventory and its refusals.
  Until that cleanup, `bin/fm-crew-state.sh` reads it as state unknown with its worktree gone, which is expected rather than a stopped worker.

- A parked ship, whose copy `bin/fm-tree-park.sh` returned to the pool while its PR waits on another home's merger or its pushed branch with no PR waits for a CI slot, has no `worktree=` line and records `parked=1`, `parked_branch=`, `parked_head=`, `parked_worktree=`, and `parked_at=` instead; a text steer through `bin/fm-send.sh` restores `worktree=` and drops those fields, and the script's header owns the rules.

### Task selectors

Task selectors for `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` resolve centrally through `fm_backend_resolve_selector`.
A selector containing `:` is passed through as an explicit backend endpoint escape hatch.

Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `fm-<id>` label fallback, so task ids that themselves start with `fm-` route to their own metadata instead of being stripped.
A metadata-routed selector returns the recorded backend target (`terminal=` for Orca, `t3_thread_id=` for T3 Code, otherwise `window=`), and matching explicit targets can still recover the recorded backend when metadata contains the same endpoint.

Only metadata-routed task selectors carry secondmate-marker and Codex-harness context; explicit endpoint escape hatches do not.
These rules are the single owner of the task-selector vocabulary.
Backend guides and other documents refer here instead of restating the resolution order.

### Teardown identity checks

`fm-teardown.sh <id>` takes a task id directly and validates the complete metadata-only endpoint identity before any runtime dispatch or cleanup mutation.
Missing, empty, duplicate, malformed, backend-inconsistent, or task-mismatched endpoint records are preserved and refused.
When the worktree identity is missing, empty, or ambiguous, the refusal also explains how to identify the held copy and restore exactly one `worktree=` line without changing the record automatically.
A parked ship's one `parked_worktree=` line stands in for that identity, and its cleanup has no copy to return.

Legacy tmux metadata remains cleanup-compatible when its exact window name is `fm-<id>`; opaque non-tmux endpoints require their recorded `endpoint_task_id=` binding.

### Herdr homes and presentation

`FM_HOME` determines Herdr's home label: the primary home uses `firstmate`, a secondmate home marked by `.fm-secondmate-home` uses `2ndmate-<secondmate-id>`, and an office home uses its bare capitalised role name, such as `Quartermaster`.
[`herdr-backend.md`](../herdr-backend.md#watching-and-task-containers) owns launcher-bound workspace placement, the label-only fallback, collision handling, and recovery behavior.

The local `config/herdr-presentation-spaces` file instead opts a home out of, or explicitly in to, Herdr's default-on disposable single-task visual projection; [Presentation spaces](../herdr-backend.md#presentation-spaces) owns its accepted values, default, Herdr version floor, migration, behavior, safety limits, recovery contract, and narrow locked session-start cleanup of exact restored idle-shell children.
Every Herdr home also keeps the captain's bare `Terminal` workspace and flags agents that share a workspace; [Terminal workspace and agent placement](../herdr-backend.md#terminal-workspace-and-agent-placement) owns that check.
The setting is inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../../.agents/skills/secondmate-provisioning/SKILL.md).
The local `config/herdr-project-groups` file opts a home in to display-only Herdr project groups; [Project groups](../herdr-backend.md#project-groups) owns its values, rules, tags, inheritance, and limits.

For normal herdr operations, `HERDR_SESSION` selects the named session, but destructive test cleanup must not rely on `HERDR_SESSION` alone.
Use the explicit guarded cleanup path described in [`docs/herdr-backend.md`](../herdr-backend.md) instead of `herdr server stop`.

### Rex attention marks

The local `config/rex-status-marks` file opts a home in to Rex attention marks: `on` sets a program-status badge and a notification on the pane of a Rex worker that needs the captain, plus validation progress in its hover card, and `off` (the default when absent) shows none of them.
[Attention marks](../rex-backend.md#attention-marks) owns the status mapping and its limits.
The local `config/rex-tint` file opts in to a subtle background tint on waiting and failed workers: `off` (the default when absent), `subtle`, or `subtle-light`; [State tint](../rex-backend.md#state-tint) owns its behavior and caveats.

### OSC 7501 worker status reporting

Firstmate launches a worker-side OSC 7501 Program Status Protocol bridge so supporting terminals can display task status even when the harness does not report it natively.
[`bin/fm-osc7501.sh`](../../bin/fm-osc7501.sh)'s header owns passive terminal eligibility and input safety, native-reporter exclusion, signal precedence and activity sources, record fields, and watcher lifecycle.
The local `config/osc7501-status` file gates the feature per home: `on` (the default when absent) or `off`; an unrecognized word reads as off and warns once per value in the next worker pane that passes the header's writable-tty and known-aware-terminal gates.

### Zellij sessions

For normal zellij operations, `FM_ZELLIJ_SESSION` selects the named session and defaults to `firstmate`.
Zellij has no per-home workspace split: primary and secondmate tasks share that one session, and visible tab titles are scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.

Use the guarded cleanup path described in [`docs/zellij-backend.md`](../zellij-backend.md) instead of `kill-all-sessions` or `delete-all-sessions`.

### cmux workspaces

cmux has no session layer at all - one workspace per task, in whatever cmux window is open - and its socket password (when configured) is read from local, gitignored `config/cmux-socket-password` under the effective config directory, never committed.
The caller-facing label remains `fm-<id>`, but the actual cmux workspace title is scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.

Test cleanup must use the guarded path in [`docs/cmux-backend.md`](../cmux-backend.md#current-operation-and-safety), never enumerate-and-close every workspace.

### tern sessions

tern uses one home-tagged session named `fm-<hometag>` (or `FM_TERN_SESSION` in tests) and one keep-open tab/block per task.
The caller-facing endpoint is `<session-id>:<block-id>`; tab titles are `fm-<hometag>-<id>`; ids are 64-bit integers and must keep full precision.
Test cleanup must use the guarded path in [`docs/tern-backend.md`](../tern-backend.md#current-operation-and-safety) and only sessions named `fm-test-*`.
`config/backend` is inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../../.agents/skills/secondmate-provisioning/SKILL.md).
