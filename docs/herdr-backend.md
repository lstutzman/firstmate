# Herdr runtime backend

This page covers running Firstmate workers on the Herdr runtime backend: setup, where tasks appear, how they are cleaned up, how input reaches them, and how their liveness is read.
Operators who choose Herdr, or who verify Firstmate against it, need it.

Herdr is an agent-native terminal backend with native per-pane agent state and push events.
This backend uses the existing `herdr` product line, not the separate preview products herdr-core (`hc`) and herdr-app.
Those previews are not upgrades to `herdr` 0.9.x and are not currently supported by this adapter.
Firstmate requires Herdr protocol 14 or newer.
Broad backend verification covers versions 0.7.1, 0.7.3, 0.7.4, 0.7.5, and 0.8.0.
Protocol-16 features remain gated by availability.
Default-on presentation spaces have a higher floor of Herdr 0.8.0 for the reason given under [Presentation spaces](#presentation-spaces).
Herdr provides the terminal session while Treehouse continues to provide task worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared backend selection and metadata semantics.

## Find a topic

| What you want to know | Start here |
| --- | --- |
| Install Herdr and select it | [Setup](#setup) |
| Why a command ran on a different `herdr` client | [Client selection](#client-selection) |
| Where task tabs appear and how to watch them | [Watching and task containers](#watching-and-task-containers) |
| The one-task workspaces, their setting, and their cleanup | [Presentation spaces](#presentation-spaces) |
| Grouping tasks by project with status tags and a sorted agents list | [Project groups](#project-groups) |
| The captain's bare Terminal workspace and the one-agent-per-workspace check | [Terminal workspace and agent placement](#terminal-workspace-and-agent-placement) |
| Why a seeded default tab is or is not closed | [Default-tab prune safety](#default-tab-prune-safety) |
| What task metadata records for a Herdr endpoint | [Endpoint metadata](#endpoint-metadata) |
| How text and keys reach a worker and how delivery is confirmed | [Current transport behavior](#current-transport-behavior) and [Composer and injection safety](#composer-and-injection-safety) |
| What happens after a Herdr server restart and how liveness is judged | [Restart and liveness behavior](#restart-and-liveness-behavior) |
| Keeping Firstmate from starting a server a service manager owns | [Externally managed servers](#externally-managed-servers) |
| How blocked transitions arrive and what happens without protocol 16 | [Push events and polling fallback](#push-events-and-polling-fallback) |
| Where the away daemon runs and how it stops | [Away-mode supervisor support](#away-mode-supervisor-support) |
| Stopping or deleting Herdr sessions during verification | [Destructive lab safety](#destructive-lab-safety) |
| Known limits and the test suite | [Active limits](#active-limits) and [Regression entry points](#regression-entry-points) |

## Setup

Pick Herdr when you want native busy, idle, and blocked state and accept the [active limits](#active-limits) below.

Prerequisites:

- Herdr protocol 14 or newer, installed from [herdr.dev](https://herdr.dev).
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).
- `python3` only for optional protocol-16 presentation-space ordering, native event subscription, and opt-in [project groups](#project-groups) agent-view transport.

Herdr is Apache-2.0 licensed.
Releases before 0.8.0 were dual-licensed AGPL-3.0-or-later or commercial.
Firstmate invokes its CLI as a separate process.

### Selecting Herdr

Select Herdr in any of these ways:

- Local `config/backend` containing `herdr`.
- `FM_BACKEND=herdr` for one launch.
- An explicit request to Firstmate.

[`remote-secondmates.md`](remote-secondmates.md#launch-or-recover) owns remote second-mate backend selection, placement, and readiness.

Herdr is also auto-detected when the primary runs natively under `HERDR_ENV=1` and is not inside tmux.
A tmux pane nested inside Herdr resolves to tmux because the innermost multiplexer wins.
An auto-detected Herdr spawn stays silent, matching the verified tmux default path.

### Spawn preflight and CI

Spawn stops before creating a Herdr container or acquiring a task worktree when `herdr`, `jq`, or the protocol floor is unavailable.
No separate first-run provisioning is required.

The required CI lane uses the pinned installers in `bin/fm-install-herdr.sh` and `bin/fm-install-treehouse.sh`.
Those script headers own release assets, checksums, download bounds, and post-install gates.
Real harness credential tests remain opt-in rather than part of default CI.

## Client selection

Each operation routed through the adapter's session-scoped CLI helper starts with the first `herdr` on `PATH`, unless that session has already selected another client.

A host can carry more than one client, such as a self-updated copy in `~/.local/bin` beside a package-managed one.
A client older than the running server can receive error code `protocol_mismatch` on operational commands.

### Recovering from a protocol mismatch

On a `protocol_mismatch` refusal, the adapter:

1. Reads `status --json --session <name>` from each distinct `herdr` on `PATH`, in order.
2. Adopts the first one the running server reports compatible.
3. Retries the command on it once.

The choice is reused only for later calls to the same session in that process.
Another session starts with the `PATH` default.
A later mismatch forces selection again, so a changed server can return to that default.

Selection also follows these rules:

- Ordinary adapter operations make no selection read on the happy path.
- Status that supplies neither `.server.compatible` nor both client and server protocols leaves compatibility unknown.
- No other failure triggers a reselection.

`fm-remote-doctor.sh` reports the client selected for the remote session.
Removing or upgrading the shadowing client is the durable fix.
`bin/backends/herdr.sh` "client selection" owns the mechanics.

## Watching and task containers

Every agent session runs alone in its own workspace, never as a tab or pane of another workspace.
A crewmate or scout therefore always gets a workspace of its own, whatever the home's presentation setting (fleet rules section 1: the captain's standing rule that all sessions live only in a single workspace each).
A secondmate or office is the one session its own home workspace holds.

A crewmate's or scout's own workspace is nested under its dispatching home's workspace on every path: a fresh spawn, a relaunch or reclaim, and every fallback from the presentation projection.
Herdr 0.9.5 has no parent field on a workspace, so nesting is presentation only: the child is labeled `└ <task> · p:<token>` and sits in the contiguous block right after the home workspace, the same shape the [presentation projection](#presentation-spaces) uses.
No path creates a flat `<home label> workers` workspace any more.
The parent is the launcher's own exact workspace, or, for a seat with no Herdr pane, the workspace labeled for the home in the table below.
A home with no such workspace gets one created at the home directory through the launcher-home placement, and the worker nests under it.
When two or more workspaces carry the home's label and no launcher identity picks one, the worker nests under the lowest-numbered and the spawn prints one warning naming every candidate.
A spawn stops with a named error only when no parent can be had: Herdr cannot list or create workspaces, or a claimed launcher identity is stale, contradictory or cross-session.

| Home | Workspace label |
| --- | --- |
| Primary | `firstmate` |
| Secondmate | `2ndmate-<secondmate-id>`, derived from its validated `.fm-secondmate-home` marker |
| Office | Its bare capitalised role name, such as `Quartermaster` or `Navigator`, read from the parent home's `data/offices.md` line for the office id |

A secondmate launched by the primary receives a narrowly scoped home override during container creation.

Each task tab is labeled `fm-<id>`, except an office's own session, whose tab carries the same bare role name as its workspace on every path that creates it: the nested create, the destroyed-endpoint reclaim, and the presentation projection.
A projection journal written before that still records `fm-<id>` and stays valid; its reclaim checks the old tab under that label, then gives the replacement tab and the journal the role name.
A tab label is display only: no lookup depends on it once a task's record holds its Herdr ids.

### Watching tasks

Attach to the selected named Herdr session and switch to the relevant home workspace to watch its task tabs.
Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without attaching.

### Focus

Workspace and tab creation use `--no-focus`.
The first workspace in a completely empty Herdr session must become focused, because no prior target exists.
Later task creation does not intentionally steal focus.

### Placement beside the launcher

Herdr does not enforce workspace or tab label uniqueness, so a label can never decide where a worker goes.

Herdr 0.7.5 exports `HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_SESSION`, `HERDR_SOCKET_PATH`, `HERDR_TAB_ID`, and `HERDR_WORKSPACE_ID` into every process it manages a pane for.
A Firstmate or secondmate agent's own commands inherit them.
Older injection shapes are unverified, so a claimed launcher pane without the injected socket identity cannot be trusted.

The identity is validated before every crewmate or scout spawn, but it never selects the worker's workspace: the worker always gets a fresh workspace of its own, so it appears next to the launcher's workspace, never inside it.
Duplicate labels elsewhere in the session are irrelevant, and the globally focused workspace is never the target.
A `--secondmate` launch stands up that secondmate home's own workspace.

### Unresolvable launcher identity

A claimed parent identity that cannot be resolved exactly stops the spawn before any worker endpoint exists, rather than falling back to a label search.
That covers:

- A missing or unusable socket identity.
- A launcher pane that cannot be read, including a destroyed pane, which Herdr answers with `pane_not_found`. The refusal says it could not be read.
- A launcher pane id that Herdr resolves to a different pane (such as a legacy id form), or a pane record with no tab or workspace. The refusal calls the pane id stale and names `HERDR_PANE_ID`, `HERDR_TAB_ID`, and `HERDR_WORKSPACE_ID` as the variables to refresh in the shell.
- A pane and tab that disagree about their workspace.
- A workspace missing from the session.
- A pane belonging to another named session or Herdr server.

### Firstmate running outside Herdr

Firstmate running outside Herdr entirely has no launcher identity to validate, and its workers get a workspace of their own exactly like any other.

Avoid naming a personal workspace `firstmate`, `2ndmate-<id>`, or an office role name such as `Quartermaster` or `Navigator`, because the adapter cannot distinguish that label collision from its own container.

An office workspace still labeled `2ndmate-<id>`, and its `2ndmate-<id> workers` workspace, is renamed in place to the role label the next time that office's workspace is looked up, so a live office keeps its workspace and workers.
The rename happens only when exactly one workspace holds the old label and none holds the new one.
A projected worker journaled under the old parent label still reclaims its workspace.

An older secondmate workspace using `firstmate-<id>` is not migrated automatically.
Rename it manually before expecting new tasks or recovery to use it.

### Recovery and existing tasks

Recovery and list-live find a home's tasks by the Herdr session, workspace, tab, and pane ids in that home's own task records, never by a tab label.
A record is listed only while Herdr reports its recorded pane in the recorded tab and workspace, so a reused pane id elsewhere never matches.
A primary therefore lists the secondmates and offices it spawned, whose records it holds, and never a secondmate's own workers.
An `fm-<id>` tab in the first workspace matching the home label is still listed by that label only when no record for that id holds Herdr ids, which covers an orphan and a task recorded before ids were kept.
The one recovery that does place new work is the control plane's reclaim of a destroyed endpoint.
It mints the replacement tab in a fresh workspace of its own, like any other crewmate or scout, while pinning the herdr session the task's record names ([`agent-control.md`](agent-control.md) "Reclaiming a task whose endpoint is gone").

Existing task operations use recorded endpoint ids and do not move a live task when labels change.
A crewmate's or scout's workspace holds only that task, so closing its last tab can remove the workspace; a respawn creates a fresh one.

## Presentation spaces

Each new crewmate or scout is placed in a disposable one-task workspace by default, on Herdr 0.8.0 and newer.
This section calls that one-task workspace the projection.
A home that turned the projection off, or an unconfigured home below that release, uses the journal-free nested layout described under [Watching and task containers](#watching-and-task-containers).
When a home with the projection on still cannot journal a task, for example on a contended presentation lock, an unreachable session server, or a recovery it cannot bind exactly, the task goes to a fresh nested workspace of its own, labeled and ordered as described under [Watching and task containers](#watching-and-task-containers), with no journal.
It waits up to about 30 seconds for a busy presentation lock so it can be ordered under its home, and if the lock never frees it stays nested by label without ordering.
Every such session gets its own workspace, because a workspace holds one session only; an existing `<home> workers` workspace from before this rule is never adopted.
It is created unfocused, and a claimed launcher identity is still validated first.
An absent parent is created and a duplicated one resolves to the lowest-numbered, as described there; only an untrustworthy launcher identity or an unreachable Herdr stops the spawn.
Before the task tab is created, the spawn refuses a workspace that already holds any tab besides the one Herdr seeded, with a message naming the workspace and that tab.

### Setting values

The local gitignored `config/herdr-presentation-spaces` file controls the projection.

| File state | Result |
| --- | --- |
| Absent | Leaves the choice to the version floor below (the unconfigured default). |
| `off` | Opts the home out. |
| `on` | Forces the projection on, as a deliberate opt-in. |
| Empty | A deliberate opt-in, the same as `on`. |
| Any other value | Warns and follows the unconfigured default rather than failing a spawn over a purely visual setting. |

Values are compared with whitespace stripped and case ignored.

The empty file is the historical presence-based opt-in form.
So every home that had already enabled the projection stays enabled with no migration step.
No previously enabled home can be turned off by the default or by the floor.

A home that never created the file gains the projection at its next Herdr spawn on a supported release.
That flip is deliberate.
It reaches only the Herdr backend, because no other runtime backend has a projection path.

### Why the default needs Herdr 0.8.0

Projecting each task into its own workspace makes every task cleanup a workspace-emptying removal.
That is the only removal shape Herdr's pre-0.8.0 focus defect touches.
The focus-safe removal plan below can only avoid the defect while the closing pane's shell can be proved lone, childless, and idle.

A persistent child of that shell - a `gitstatusd`, a `zsh-async` worker, or `direnv` - fails that proof permanently and forces the plain explicit close.
On those releases, that close moves the active workspace for roughly a seventh of a second before the restore backstop pulls it back, once per task cleanup.

An unconfigured home is therefore projected only on a release at or above the 0.8.0 floor.
On those releases every workspace-removal primitive preserves focus, and that proof stops being load-bearing.

Below the floor, an unconfigured home uses the journal-free nested layout instead.
It warns once per home per detected release, naming the running release and the upgrade that restores the projection.
That one-warning-per-release record is a `state/.herdr-presentation-floor-<release>` marker.
Deleting it only makes the same warning appear again.
An upgrade or downgrade re-announces itself because the release is part of the key.

### How the floor is checked

The floor reads two sources:

- The installed client's protocol and version.
- The selected named session's server signals, while that server is running.

Both applicable releases must pass.
When status positively reports no running server, the floor uses only the client, because that client will start it.

The unconfigured default is rechecked after the server is started or adopted, and before any presentation journal or workspace is created.
An unreadable server state or release is treated as unsupported rather than guessed at.

An explicit `on` is honored below the floor, so a home that deliberately opted in is never silently downgraded.
That home accepts the documented focus move, and the exact prior-tab restore stays its backstop.

The floor has a single owner, the spawn-time gate.
So cleanup for a projection that already exists always runs and never strands a workspace, whatever release the home is on now.

Upgrading Herdr to 0.8.0 or newer is the fix.
Writing `off` is the immediate mitigation for a home that cannot upgrade yet.

### Secondmate homes

The setting is inherited into secondmate homes through the normal configuration-convergence owner.
The default needs no special convergence.
The primary's absent file and the secondmate's absent file both mean the same unconfigured default.
So leaving the file absent converges a secondmate to that same default rather than turning it off.
Only an explicit primary `off` propagates the opt-out.

A secondmate agent itself always stays in its ordinary parent workspace; only children launched by that home are eligible.
An unconverged opt-out keeps the default projection in that home until convergence.

### Presentation journal

Presentation is a best-effort visual projection, never task ownership or lifecycle authority.
A presentation journal is the per-task record in this home's `state/` that binds a task to its projected workspace.

Only a fresh task with neither metadata nor an existing presentation journal is eligible for projected creation.
Creation proceeds in this order:

1. Firstmate atomically publishes a three-field version 1 journal containing a random 128-bit base64url token, before asking Herdr to create anything.
2. After the new workspace converges to one exact task endpoint beneath one exact parent workspace id, the journal advances to a version 2 binding.
   That binding records the physical home, named session, endpoint, parent, and immutable expected labels.

Another parent with the same presentation label does not prevent publication or participate in restart reclaim.

The token is visible in the workspace title, because Herdr exposes no verified hidden persistent field.
Neither token, title, nor journal authorizes send, capture, task ownership, Treehouse return, or general recovery.

### Owning parent and tabs

The owning parent is the same parent every nested worker uses, resolved as described under [Watching and task containers](#watching-and-task-containers): the launcher's own exact workspace, or the home-labeled workspace for a Firstmate outside Herdr.
Projected children are never collapsed back into that parent.
The parent is the placement and ordering reference the projection is bound under.

The task tab, under its label from [Watching and task containers](#watching-and-task-containers), is created in the exact new workspace returned by Herdr.
Only the exact seeded default tab returned by the same workspace-create response can be pruned.
Before and after create, prune, order, abort cleanup, and normal cleanup, Firstmate verifies exact workspace, tab, pane, and active-focus ids.
An ambiguous response grants no mutation or cleanup authority.

### Ordering

Protocol 16 exposes `workspace.move` over the named session socket but no CLI subcommand.
`bin/backends/herdr-workspace-move.py` sends only that whitelisted method and verifies the complete returned workspace order.

Projected children are placed in one contiguous block immediately after their owning home when all of these are verifiable:

- The session layout.
- The protocol.
- The socket.
- `python3`.
- The account-private per-session lock.

Existing legacy child labels may extend an already adjacent block read-only but are never renamed or migrated.
A foreign, ambiguous, detached, or manually interleaved child makes ordering skip with a warning rather than rewriting the layout.

Ordering failure never fails the task spawn.
Firstmate does not retry, adopt, reuse, close, delete, or rename anything in response to an unavailable method, lock contention, ambiguous socket, lost response, failed move, or verification mismatch.
The worker keeps its nested label and stays in Herdr's current order.

### Cleanup and focus safety

Normal task metadata remains the sole endpoint authority after creation.
Cleanup closes only the exact recorded task pane and never calls `workspace close`.
For a leased task copy, cleanup confirms that exact pane is gone before it reaps worktree processes or returns the copy.
If the pane remains or its absence is ambiguous, cleanup retains the task records and copy for a retry.

Herdr 0.7.5's explicit close moves focus to a neighbor whenever it empties a non-focused workspace.
Its pane-death removal preserves the focused workspace whenever the dying workspace sits behind it or the focused workspace is last.
Both behaviors are fixed in Herdr 0.8.0, and the exact rules live in the adapter header of `bin/backends/herdr.sh`.

Projected cleanup therefore:

- Runs under the same session lock.
- Refuses to delete the tab a live foreground client is viewing.
- Treats a workspace-emptying close as a focus-safe removal.

A focus-safe removal takes these steps:

1. Verify the close would empty the workspace.
2. When needed, reposition the doomed workspace behind the focused one through the verified `workspace.move` transport.
3. Prove the pane holds one lone idle shell.
4. End that shell, so Herdr removes the emptied workspace through its focus-preserving pane-death path.

The persisted `.focused` pointer is not a live viewer.
When `herdr terminal title clear` reports `no_foreground_client`, cleanup proceeds on that tab because no human is attached, and skips restoration of the tab it destroys.

Herdr currently has no atomic client-aware mutation.
So a fresh target-focus and foreground-client checkpoint runs immediately before each move, signal, or explicit close.
When a live viewer has switched to another tab, that fresh tab becomes the restore target.
A client can still attach or switch focus in the residual checkpoint-to-mutation window.
A durable atomic close is deferred until Herdr exposes that primitive.

The repositioning move-to-last preserves every surviving workspace's relative order.
Removal is confirmed against the exact moved workspace rather than inferred from pane disappearance.
An unconfirmed removal then makes one verified attempt, under the same session lock, to roll the doomed workspace back to its exact original position.
If that rollback cannot restore the verified original order, cleanup warns loudly and leaves the retained records for inspection rather than retrying the shared-layout mutation.

The pane-death signals are pid-exact.
The escalation re-reads the pane's process information and refuses unless the same shell pid still passes the strict bare-idle ownership proof, so an exited and reused pid is never signaled.

A move-plan ambiguity, unsupported or failed move, or unproved shell falls back to the plain explicit close.
Exact tab restoration remains the backstop whenever a surviving tab must be preserved.
So degraded behavior is never worse than the pre-mitigation sub-second restore.

### Ordinary removal and cleanup locking

Ordinary non-projected task removal:

- Serializes through the same session lock.
- Applies the same focus-safe plan when its close would empty a non-focused workspace.
- Keeps the legitimate plain close when the target is the active tab.
- Refuses an unlocked close if the lock cannot be acquired.

Task cleanup acquires that session lock before the task's isolated copy is returned.
So a contended lock refuses up front while the copy, every durable record, and the endpoint are all intact for a plain rerun.

Forced secondmate cleanup recursively preflights every Herdr child endpoint and acquires every affected named-session lock before mutating any child.
It then retains each child's durable identity unless that exact pane returns structured not-found after its close.

### When task records are erased

Durable task records are erased only once the exact pane is confirmed gone through its structured presence.
After every close path, only a structured not-found response counts as gone.
A present or unknown result retains every record with a visible, retryable error.
Missing or malformed endpoint identity and missing confirmation machinery are ambiguity, never proof of a gone pane, and refuse record removal the same way.
If lock, snapshot, pane identity, or restoration is ambiguous, cleanup warns and preserves the journal for manual inspection.
Once the exact pane is confirmed gone, teardown retires the task's own journal when it binds that same pane, or when it is a version 1 attempt whose token-bearing projected workspace is itself confirmed gone, because nothing then remains for the session-start sweep to correlate; a journal bound to any other pane, or a version 1 attempt whose workspace is still present or unreadable, stays for that sweep.
A spawn that aborts after its own projected create, such as one whose Treehouse slot never becomes an isolated worktree, closes its exact panes and then retires the journal it published under the same rule: the journal must still carry that spawn's token and no workspace in the named session may carry it, so a same-id retry is a fresh projected create rather than a journal-free fallback.

### Restart recovery

A fresh ship or scout leases its task copy durably with `treehouse get --lease` from the spawn process and creates the pane inside it; [Where a restored worker resumes](#where-a-restored-worker-resumes) owns why.
The lease outlives the pane: teardown closes the exact pane before it returns the lease, because returning the copy ends the pane's top-level shell and Herdr would then remove the pane outside the focus-preserving close.
An aborted spawn returns the lease only when Herdr confirms the task pane gone; otherwise it names the `treehouse return` command.

Recovery is deliberately conservative and presentation-only.
An existing journal suppresses another projected create.
Before any recovery mutation, Firstmate holds both the task spawn lock and the named-session presentation lock.
That presentation lock lives in a namespace private to the OS account, so another account on the same host running its own Firstmate on Herdr cannot block this account's spawn, recovery, or teardown.
A namespace at this account's name that another account owns, or that is not mode 700, is still refused and is never adopted, chowned, or removed.

A same-identity version 2 binding may replace one exact agent-free restart husk in place.
A husk is a restored same-labeled tab with a missing pane or no registered agent, as [Restart and liveness behavior](#restart-and-liveness-behavior) describes.
The replacement is allowed only when all of these agree:

- The physical home.
- The session.
- The metadata endpoint.
- The unique token match.
- The workspace shape and labels.
- The parent identity and placement.
- The non-target focus snapshot.

The replacement tab and pane are created and verified before the old pane is rechecked and closed.
Then the journal advances atomically to the replacement endpoint before metadata publication.
The reclaim path never moves, closes, deletes, or renames a workspace and never touches a parent, sibling, captain, or foreign pane.
A failed replacement rolls back only the exact response-derived new pane when focus-safe verification permits it.

These cases fall back to a journal-free nested workspace without mutating the old projection when duplicate-agent risk is positively absent:

- Version 1 journals.
- Dead or missing panes.
- Duplicate or absent tokens.
- Renamed or detached spaces.
- Cross-home mismatches.
- Inconsistent endpoint bindings.
- Active target tabs.
- Ambiguous identity or focus.

A live or unknown recorded or token-matched endpoint refuses duplicate launch.

### Startup cleanup of restored projections

Locked session start has one narrower cleanup for a restored projected child that is no longer current task state.
It runs only when the current home has at least one ordinary presentation journal, and it considers only that home.
A primary never recursively sweeps a secondmate home.

Discovery starts from the exact current `└ <concise-task> · p:<22-character-token>` grammar, but a title or token alone is never mutation authority.
A candidate must meet all of these conditions:

- The title must contain exactly one token occurrence across the named-session snapshot.
- The title must equal the title derived from exactly one valid presentation journal in this home's own `state/`.
- A version 2 journal additionally must bind this exact physical home, named session, workspace, tab, and pane.
- The task's ordinary metadata must be absent.
- The candidate must have exactly one tab and exactly one pane.

Firstmate then cleans up the candidate in this order:

1. Acquire the existing task-id spawn lock, and then the shared named-session presentation lock.
2. Inside both locks, take one exact snapshot.
3. Require one unambiguous non-target focus and the exact title, token, tab, and pane shape.
4. Positively confirm no registered agent.
5. Read Herdr's process information for the exact named-session pane and apply the process proof below.
6. Immediately revalidate the same journal, metadata absence, workspace title and token uniqueness, one-tab and one-pane topology, exact pane relationship, absent agent, process proof, and non-target focus.
7. Call the existing exact-pane focus-preserving close helper.
   It closes only that pane, never a workspace.
8. Retire the matching journal only after the exact pane is positively confirmed gone.

The process proof requires all of these:

- One recognized idle shell as both the shell process and the sole foreground process-group member.
- An operating-system process-table row for that shell.
- No child process.
- A sleeping or idle shell state.

The proof retries strict single samples for a bounded settle window, because an idle interactive shell transiently hosts short-lived prompt helpers.
A genuinely busy pane fails every sample.
Any foreground command, child process, active shell job, unknown shell, unreadable process table, missing field, or API error preserves the pane.

An unconfirmed close retains the journal.
A confirmed close may retire it even when focus restoration reported an error after the close.
A second run finds no matching title or journal and is a no-op.

Any of these preserves the candidate and lets session startup continue with at most a concise warning:

- A malformed or missing title or token.
- A duplicate token.
- Zero or multiple journal matches.
- A cross-home version 2 binding.
- Current metadata.
- A registered or unknown agent.
- An extra tab or pane.
- An active target.
- A busy lock.
- A changed revalidation.
- An unreadable check.
- Any error.

### Operational compromises

- Grouping is best-effort; only an exact same-identity version 2 binding survives a Herdr restart in place.
- A failed journal publication or projected workspace create stops that spawn instead of falling back to a journal-free workspace.
  So a Herdr create failure surfaces as a spawn failure in every Herdr home, rather than only in homes that opted in.
  Every earlier degradation on the fresh projected-create path (no session server, contended presentation lock) still warns and continues as a nested workspace without a journal.
  An absent parent is created and a duplicated one resolves to the lowest-numbered with a warning; an untrustworthy launcher identity or an unreachable Herdr stops the spawn with a named error instead.
- Recovery of an existing presentation journal refuses by default when the shared presentation lock is contended, rather than falling back to a journal-free workspace.
  Pass `fm-spawn.sh --herdr-resume-lock-wait` to opt that recovery into waiting for the lock instead, so concurrent recoveries can serialize.
  The flag applies to a fresh ship or scout spawn that recovers a journal.
  The multi-task path forwards the flag to each per-pair spawn.
  `fm-spawn.sh --relaunch` and `--secondmate` take no exact-resume presentation-order lock, so the flag has no effect there.
  Dead-owner reclaim still stops the wait when a holder crashed.
  Unbounded blocking on the session lock is never the default.
- Existing layouts are not force-renamed or rearranged.
- Missing or ambiguous restart bindings fall back to a fresh nested workspace without a journal while the old projection remains untouched.
- Crashes, lost responses, failed exact-pane cleanup, or human renames can leave quarantined spaces.
  Session start removes only the exact home-local, uniquely journal-correlated, childless idle-shell shape above.
- Spaces have no cross-home cleanup path, and a secondmate child can clean up only from its exact home.
- Every stale-looking space outside that narrow startup proof still requires manual cleanup in Herdr's UI after human inspection.
- Regaining a dedicated space after degradation requires stopping the journal-free task, manually checking the stale projection, and clearing its journal before a genuinely fresh launch.
- The visible token is only a restart-stable correlator and never substitutes for the exact binding.

### Presentation tests

| Test | What it covers |
| --- | --- |
| `tests/fm-backend-herdr-presentation-e2e.test.sh` | Multi-home ordering, concurrency, lock contention, legacy coexistence, focus preservation, exact same-identity restart replacement, ambiguous bindings and tokens, and exact-pane cleanup through the guarded lab path. |
| `tests/fm-herdr-session-cleanup.test.sh` | Every discovery, ownership, topology, process, locking, revalidation, focus, retirement, and continue-on-error boundary. |
| `tests/fm-herdr-session-cleanup-e2e.test.sh` | The restored-shell cleanup in a guarded non-default named lab. |
| `tests/fm-backend-herdr-focus-flash-e2e.test.sh` | Reproduces the raw explicit-close focus steal on the installed release, and proves the focus-safe emptying-close plan removes a doomed workspace with no wrong-focus interval. |
| `tests/fm-backend-herdr-stale-active-tab-e2e.test.sh` | Proves a persisted-focused tab still closes when no foreground client is attached. |
| `tests/fm-herdr-attached-viewer-live-e2e.test.sh` | Proves the other half against a real attached viewer, which `bin/fm-herdr-lab.sh viewer start` supplies over a pty sized before the fork. |

[`verification/runtime-backends.md`](verification/runtime-backends.md#workspace-removal-focus-safety) owns the active versioned evidence for the focus-flash test.
[`verification/runtime-backends.md`](verification/runtime-backends.md#attached-foreground-viewer) owns the active versioned evidence and the re-run trigger for the attached-viewer test.

## Project groups

Project groups are an opt-in display layer that shows each task's project group and status in Herdr's sidebar and sorts Herdr's agents list by group and then by status.
They are off by default, and without the setting nothing in this page's other sections changes.
They are display-only: no tag or view is task, endpoint, ownership, or cleanup authority.

### Turning project groups on

The local gitignored `config/herdr-project-groups` file controls them.
It is inherited into secondmate homes, because the agents view is one per Herdr server and every home's tasks share it.

| File content | Result |
| --- | --- |
| Absent | Off. No producer runs and no Herdr call is made. |
| `off` | Off, the same as absent. |
| `on`, or empty | On, with one group per project, named after the task's project directory. |
| Rule lines | On, with the groups and group order the rules define. |

Blank lines and lines starting with `#` are ignored.

### Group rules

Each rule line is a group name followed by selectors, separated by whitespace.
The order in which a group name first appears is that group's display order, and a group may span several lines.
Group names use letters, digits, `.`, `_`, `+`, and `-`, at most 32 characters.

| Selector | Matches |
| --- | --- |
| `task:<prefix>` | A task id equal to `<prefix>` or starting with `<prefix>-`. |
| `repo:<name>` | A task whose project directory is named `<name>`. |
| `*` | Every task. |

Task-id selectors win over repository selectors, which win over `*`, across all lines; within one selector kind the first matching line wins.
A task that no rule matches is grouped by its project directory and listed after every rule group.
An invalid group name or an unknown selector is ignored with a warning.

Example, grouping by area of work and keeping a catch-all last:

```text
# config/herdr-project-groups
Web       task:web task:shop repo:storefront
Backend   task:api repo:api-server
Ops       task:deploy task:infra
Other     *
```

### Tags and status order

For each ship and scout task recorded in the home with Herdr endpoint metadata, Firstmate reports display-only metadata tokens under the source `firstmate`:

| Token | On | Value |
| --- | --- | --- |
| `fm_group` | pane and projected workspace | The group name. |
| `fm_state` | pane and projected workspace | The display status. |
| `fm_task` | pane | The task id. |
| `fm_sort` | pane | `<group order>.<group>.<status rank>.<task>`, at most 80 characters. |
| `fm_group_order` | projected workspace | `<group order>.<group>`, the key that [placement](#placement-inside-the-group) compares. |

Workspace tokens go only to the task's own projected workspace: an exact version 2 [presentation journal](#presentation-journal) binding the task's recorded session, workspace, and pane, whose live workspace holds that single pane.
A task without a journal has no exact binding, so it gets pane tokens only.

The display status comes from the task's status log through the shared classifier that `bin/fm-classify-lib.sh` owns, in this rank order:

| Rank | `fm_state` | Status log |
| --- | --- | --- |
| 1 | `needs-captain` | An open decision, or a captain-held transfer. |
| 2 | `problem` | `blocked` or `failed`. |
| 3 | `running` | Anything else, including `working`, `paused`, and no status yet. |
| 4 | `done` | `done`. |

It is the worker's latest declaration, not the reconciled current state that `bin/fm-crew-state.sh` owns, and it can lag one watcher poll behind the log.
Herdr's own agent status dot stays live beside it.

The watcher reconciles every task once per poll cycle, and a spawn tags its new task at once.
A reconcile reads each session's workspace and pane lists once and reports only tokens whose live value differs.
Whenever it reports a pane token, it also sets the agents view: `agent.view.set` with source `firstmate`, label `projects`, and sort by the `fm_sort` token, then workspace order.
Herdr keeps neither tokens nor the agents view across a server restart, so the next reconcile after a restart reports them again.
Agents without an `fm_sort` token, such as Firstmate itself or another tool's agents, sort after the tagged ones.
Herdr exposes no CLI for the agents view, so `bin/backends/herdr-agent-view.py` sends only those two whitelisted requests over the named session socket.

Tags and the agents view need Herdr protocol 22, verified with Herdr 0.9.5; the wire schema comes from Herdr 0.9.3, which speaks the same protocol.
An older client warns once per protocol and the feature stays inactive.

`bin/fm-herdr-groups.sh` owns the commands, including `plan` to preview groups and statuses without touching Herdr and `clear` to remove this home's tags and the agents view after turning the feature off.

### Sidebar rows

Herdr shows custom tokens only where its own configuration names them.
Firstmate never edits Herdr's configuration on its own.
`bin/fm-herdr-groups.sh sidebar-config` prints these suggested rows, and `sidebar-config --apply <path>` appends them to that Herdr configuration file after copying it to `<path>.bak-<epoch>`, refusing when the file already defines sidebar rows:

```toml
[ui.sidebar.spaces]
rows = [
  ["state_icon", "workspace"],
  [{ token = "$fm_group", bold = true }, "$fm_state"],
]

[ui.sidebar.agents]
rows = [
  ["state_icon", { token = "$fm_group", bold = true }, "$fm_state", "$fm_task"],
]
```

Run `herdr server reload-config` afterwards to apply them.
Colors can be added with Herdr's inline token styles.

### Placement inside the group

With project groups on, a new projected task is placed inside its owning parent's child block right after the last child whose `fm_group_order` token sorts at or before its own, instead of at the block end.
A child without that token counts as sorting before it, so untagged children never move behind a new task.
Everything else is [Ordering](#ordering) unchanged: one verified move of the new workspace only, never an existing child, a parent, or a foreign workspace, and every ambiguity leaves the new task where Herdr created it.
A task whose group changes later keeps its position until it ends.

### Verification status

The tags, the agents view, and the placement are covered by offline tests against a scripted Herdr CLI and socket helper (`tests/fm-herdr-groups.test.sh` and the ordering cases in `tests/fm-backend-herdr.test.sh`).
They were also exercised against a real Herdr 0.9.5 server (protocol 22) in a guarded lab session: after one watcher poll `herdr pane list` showed the `fm_*` tokens on each task pane, the agents list header read `projects` with tasks ordered by group and then status, a newly spawned projected task landed after the other tasks of its group with only that workspace moving and no focus change, and `fm-herdr-groups.sh clear` removed the tokens and the view.
To repeat the check on a live session, turn the feature on, wait one watcher poll, and confirm the same four results.

## Terminal workspace and agent placement

Every machine keeps exactly one Herdr workspace labelled `Terminal`: a bare shell at the home directory with one tab and one pane, which belongs to the captain and never hosts an agent.
Every agent runs alone in its own workspace, never in an extra tab or pane of another workspace.
`fm-spawn` gives every crewmate and scout, including a relaunch, a workspace of its own (see [task containers](#watching-and-task-containers)), so the check reports only sessions that were placed by hand or before that rule.
`bin/fm-herdr-terminal-check.sh` enforces both at locked session start in every Herdr home, primary or secondmate, in the BOOTSTRAP section of the digest; a healthy machine prints nothing.

- A label matches `Terminal` with or without the leading `[n] ` prefix that some Herdr versions add (`[5] Terminal`).
- When the session has no workspace labelled `Terminal`, the check creates one without taking focus and runs nothing in it.
- One machine-wide lock per host and Herdr session, outside every home (under `XDG_RUNTIME_DIR`, else `TMPDIR`; `FM_HERDR_TERMINAL_LOCK` overrides it), guards the Terminal part, so exactly one home creates the workspace and a home that finds the lock held skips it.
- When several carry that label, or the single one holds an agent or more than one tab or pane, the check reports it and changes nothing.
- Agents that Herdr itself recognizes (`herdr agent list`) and that share a workspace with another agent, or sit in the `Terminal` workspace, are reported on one summary line with their count and the first three; an agent alone in its workspace is not flagged, even beside extra non-agent tabs or panes. The home reports the line to main.
- The check never closes, moves, kills, or renames a workspace, tab, pane, or process, and never starts a Herdr server.
- A home whose backend is not Herdr prints nothing.

`tests/fm-herdr-terminal-check-e2e.test.sh` covers creation, an existing Terminal, a secondmate home creating it and skipping while the lock is held, duplicate Terminals, and the flagged placements in a guarded non-default named lab.

## Default-tab prune safety

`herdr workspace create` seeds one default tab.
Firstmate prunes it only after a real task tab exists and only when the same create response supplied the seeded tab id.
An adopted workspace never supplies that id and can never enter the prune path, regardless of labels or tab count.
Immediately before close, Firstmate rechecks the exact tab, expected seed label, and native agent state.
A working seed pane is never closed.

This created-versus-adopted gate is a destructive safety boundary.
A prior label heuristic could adopt a captain-owned workspace named `firstmate` and close its live seed-shaped tab.
The current structural gate removes label inference from cleanup authority.
`tests/fm-backend-herdr-prune-safety-e2e.test.sh` reproduces the collision in an isolated named session and proves the adopted pane remains untouched.

## Endpoint metadata

```text
backend=herdr
window=<session>:<pane-id>
herdr_session=<session>
herdr_workspace_id=<workspace-id>
herdr_tab_id=<tab-id>
herdr_pane_id=<pane-id>
```

A Herdr pane id contains a colon, so the adapter splits `window=` on the first colon only.
The recorded pane is the operational fast path.
Workspace and tab ids support verification, cleanup, and list-live discovery, and are never inferred from mutable labels during normal operation.

## Current transport behavior

### Named server and session routing

The adapter starts and polls a named server before workspace, tab, pane, or agent calls.
Every Herdr invocation goes through `fm_backend_herdr_cli`, which sets the environment and passes an explicit trailing `--session <name>`.
An environment variable alone is not reliable when another Herdr server is running.
An empty session name is refused before any Herdr call, by `fm_backend_herdr_cli` and by every adapter function that takes an optional session, rather than reaching the live default session.
Leaving that optional session out still selects the ambient `HERDR_SESSION`, or `default`.

When the selected named server is not running, the adapter launches it without these inherited values:

- Firstmate home and directory overrides.
- Harness identity markers.
- The supervision-model override.

Herdr passes its server startup environment to every later pane, so retaining those values could misroute panes for another Firstmate home or harness.
An already-running server is reused without restart or environment changes.
Explicit named-session routing and unrelated launch environment remain intact.

### Sending text and keys

Literal text and Enter are separate operations on `fm-send.sh`'s typed plane.
Ordinary local text steers instead use the durable steering inbox and send only its best-effort constant doorbell through this adapter.
Spawn-time fixed commands may use Herdr's atomic run primitive.
Enter, Escape, and Ctrl-C are supported.

Typed-plane slash input, and dollar-prefixed skill input for Codex, uses the shared harness-aware settle before the first Enter, so a completion popup cannot consume it.
Typed-plane text is typed once; only Enter is retried.

### Claude composer proof

When native `agent get` identity is Claude, the adapter types only into an empty composer.
A Claude composer that already holds text, or cannot be read, before the send is refused with nothing typed.
Before that Enter, the adapter continues only when the selected composer shows the typed payload, or only Claude paste placeholders with no literal remainder.
Every herdr adapter composer read (`fm_backend_herdr_composer_state`, `fm_backend_herdr_composer_content`) captures the full visible viewport, never a bounded tail.
An overlay Claude renders between the composer and the pane bottom - the slash-command popup is the verified shape - pushes the composer outside a tail window, and the composer is by definition inside the viewport.
[`bin/fm-task-inbox-lib.sh`](../bin/fm-task-inbox-lib.sh) owns the separate shared inbox pending-line confirmation read.
Dated measurement: docs/verification/runtime-backends.md "Claude exit behind the slash-command popup".

That comparison ignores whitespace and U+2063, the invisible mark that starts operational inputs and ends the from-firstmate label.
It ignores U+2063 because Claude's Herdr read-back never shows it.

A composer that holds a shorter suffix, or a placeholder plus a literal remainder, does not receive Enter.
Instead:

1. The adapter presses Ctrl+U until the shared classifier reads the composer as empty.
2. It then reports `send-failed`, so a resend starts from a clean composer.

Ctrl+C is not used for this, because Claude documents it as interrupting a running operation.
If the composer cannot be verified empty again, the submit reports `unknown` instead, because text may still be in the composer.

Other harnesses, and panes with no native identity, skip this proof and keep the type-then-Enter path.
They skip it because their paste placeholders and composer shapes are not live-verified.

### Submit confirmation

On an idle or done native baseline, submit confirmation proceeds in this order:

1. Wait for `working` or `blocked` across a bounded polling window.
2. If native status stays idle, use the shared composer verdict as the next positive signal.
   A cleared composer is delivery, and proven pending text retries Enter.
3. After the retry budget, `fm_composer_queued_enter_verdict` treats proven pending text plus a generating busy signal as a queued delivered Enter.
   It keeps an idle pending composer as a genuine swallow.

On an already active or unreadable baseline, the adapter falls back to conservative composer clearance.
That fallback adds a pre-Enter rendered-footer transition when the baseline is unavailable.
A fully unreadable target stops retrying and reports unknown.

`blocked` is not treated as a queued-Enter busy signal, so a Cursor pane that reports blocked in every state does not receive that conversion.

### Harnesses with no idle baseline

Some harnesses never present a legibly idle native baseline at all, so the composer fallback is their only path.

Cursor is one such harness:

- Herdr reports a Cursor pane `blocked` in every state.
- Cursor's mid-turn composer renders its placeholder beside a right-aligned busy token.
  That token is composer content, and therefore `pending` on a composer that holds no user text.

That fallback alone reported every delivered steer as unconfirmed.
So it is paired with a rendered-footer transition.
The pane's verified busy footer is read once before the first Enter, and an idle-to-busy transition across that Enter confirms the submit.
It is the same semantic signal the native path uses and the same one the tmux submit core reads.

A pane already mid-turn cannot borrow a rendered-footer transition as proof of this delivery.
After retries, only proven pending text plus native `working` can establish that its Enter was accepted and queued.

The composer verdict itself is deliberately unchanged.
A right-aligned status token on the composer row stays content for every other caller, including the away-mode pre-injection guard.

The poll density bounds the residual possibility of an extremely fast complete turn.
A missed native transition falls through to the composer verdict rather than reporting a false swallow.

### Capture size

`pane read --lines N` can return empty output when N is below the viewport height.
The capture owner requests at least 200 lines from Herdr and trims locally to the caller's bound.
This generous floor is required for the small bounded reads that remain: peek and watch tails, the rendered busy-footer read, and the shared steering-inbox pending-line read.
The adapter's own composer reads are exempt because they read the visible viewport instead, which takes no line count (see [Claude composer proof](#claude-composer-proof)).

### Native idle state

Herdr's native agent state can read idle while a harness waits on its own long foreground tool.
The shared crew-state path therefore accepts a native `busy` as evidence of activity.
It never accepts a native `idle` as evidence that a worker has stopped; the task's own semantic busy state (`bin/fm-busy-lib.sh`) decides that.
A human-blocked permission dialog has no busy banner and still surfaces.

## Composer and injection safety

Herdr has no direct cursor-row primitive.
The adapter is a thin capture.
It hands the visible pane's ANSI viewport plus Herdr's capability facts to the fleet-wide classifier in `bin/fm-composer-lib.sh`, which owns every shape:

- Bordered boxes.
- Bare agent-glyph rows, including muse's `⟩`, which the adapter's retired local pattern silently omitted.
- opencode's left bar.
- The Pi separator region this adapter pioneered, admitted only when native `agent get` identity is exactly Pi and state is idle or done.
- Cortex Code's titled rounded top rule, admitted only when native `agent get` identity is exactly `cortex`, which the adapter reads lazily and only when the classifier answers `need-identity` for a titled rounded box holding an agent prompt glyph; the same box on any other pane stays ambiguous, and Cortex is [verified](verification/cortex.md) on Herdr for crewmates and scouts only.

### Pi composer states

A blocked Pi is parked on an interactive prompt, so its blank composer region is a menu's and not a free composer's.
That state defers instead of proving emptiness.
A working Pi, pending middle row, missing identity, incomplete separator pair, or over-tall candidate remains unknown or pending.
Identity stays a lazy second read, consulted only when a separator pair could change the verdict.

### Placeholder and ghost text

ANSI capture preserves de-emphasized placeholder style.
`bin/fm-composer-lib.sh` is the fleet-wide owner that strips dim or faint runs and dark truecolor placeholders while retaining bright typed input.

If the ANSI capture ever fails, the plain fallback declares itself unstyled.
The classifier then degrades a glyph row carrying trailing text to `unknown` instead of misreading ghost suggestions as typed input.
That safely defers injection and eventually raises the wedge alarm.

### Away-mode injection

A bare shell prompt is never an empty agent composer.
Away-mode injection proceeds only on an affirmative `empty` result, never on unknown.
This prevents a dead agent pane from receiving and possibly executing an escalation as shell input.

### Operational input markers

The current operational envelope starts with U+2063 and `FIRSTMATE_OP: `.
The separate routed-request carrier uses `[fm-from-firstmate]` plus U+2063.
U+2063 survives Herdr terminal input as text, unlike the legacy ASCII control separator that could erase the visible routing label.
Claude Code itself then removes it from the submitted prompt, so a Claude Code primary receives away-mode escalations as the owner's record-backed doorbell instead.
`bin/fm-operational-input.sh` owns current operational construction and parsing, and the AFK skill owns legacy away-input compatibility.
No Herdr-specific copy of that protocol exists.

## Restart and liveness behavior

### Externally managed servers

By default Firstmate starts a session's Herdr server itself, headless, whenever an operation finds it not running.
That is wrong when a service manager, such as a systemd user unit, owns the server.
During a unit restart or a `server live-handoff`, `status` can briefly report not running, and a server Firstmate started would race the owner and split panes across two servers.

The owner opts out by writing marker files into the session directory, the directory holding the socket that `herdr --session <name> status --json` reports as `.server.socket`:

| Marker | Written by the owner | Firstmate behavior |
| --- | --- | --- |
| `firstmate-server-owner` | Once, for as long as it owns the server; the first line names the owner | Uses a running server; never starts a stopped one, and waits a bounded time for it to report running, then fails naming the owner |
| `firstmate-server-replacing` | Only for the duration of a restart or handoff | Never starts or uses a server, even one that reports running; waits a bounded time for the marker to clear and the server to report running, then fails naming the marker |

The wait is up to 60 checks half a second apart, 30 seconds in all.
A replacement marker that clears with no owner marker hands the session back to the default, so Firstmate starts the server if it is still down.
A replacement marker left behind fails every operation naming its path, so the owner must remove it when the replacement ends.
Every operation checks the session directory for a replacement marker once, even when the server reports running, so a replacement marker holds callers off the old server as well as the new one.
That check reuses the `status` read Firstmate already makes, which reports the socket even while the server is stopped ([verification](verification/runtime-backends.md#session-directory)); a Herdr whose `status` omits the socket cannot carry the markers and keeps the default behavior.

### Husks after a server restart

Stopping and restarting a named Herdr server preserves workspace, tab, pane, and label ids.
The underlying harness processes and live agent registrations do not survive.
A restored same-labeled tab with a missing pane or no registered agent is a husk.

Create replaces only a confidently dead or no-agent husk, creates the replacement before closing the old tab, and refuses live or unknown states.
This prevents closing the workspace's last tab before a replacement exists.
A crewmate or scout respawn gets a fresh workspace, so its earlier husk sits in another workspace that the label check never sees.
Once the new tab exists, the spawn closes the earlier endpoint at the exact pane the task's own record names, only while Herdr still reports that pane in the recorded workspace and tab, and only when that pane is proven to hold no agent; it never searches by label.
Closing it removes the husk's workspace too only when the husk was the last thing in it.
A pane that is gone, live, stale-agent or unknown is left alone with a one-line note.
An office tab still labeled `fm-<id>` from before offices took their role name counts as that office's tab, so a live one still refuses a second session and a husk is still replaced.
A relaunch keeps the same tab, so it renames that exact tab from `fm-<id>` to the role name in place.

Because the ids survive a restart, a task's record finds its restored tab again with no extra identifier.

### Where a restored worker resumes

Herdr saves a pane at its creation cwd and resumes the agent there, and a shell that later changes directory never changes it.
So a fresh Herdr ship or scout spawn leases its Treehouse slot from the spawn process (`treehouse get --lease --lease-holder <task>`) and creates the pane in that worktree, rather than typing `treehouse get` into a pane created in the project clone.
A restored worker then resumes in its own worktree, not in the clone whose parent home `CLAUDE.md` would make Claude Code ask to approve an external import.
The spawn returns that lease only if it fails before the task record is published, and only after closing its own pane; after that, teardown returns it like any other.
Workers spawned before this change keep the cwd they were created with until they are respawned or reclaimed.
Relaunch, secondmate, and the other backends keep their current flow.

### Stale agent registrations

A registration alone never proves an agent.
Herdr keeps a Pi registration after the Pi process has exited to a plain shell, whenever a nested interactive shell sits under the pane's top shell.
In that case `agent get` still reports `agent=pi` with its last status.
That nested shell is the shape an interactive `treehouse get` leaves behind (Herdr ship and scout spawns no longer create it, but older workers and the other backends do; measured on Herdr 0.9.0 - [verification](verification/runtime-backends.md) "Stale agent registration"; upstream issue #4115).

So before a registered agent counts as live, the pane classifier reads `pane process-info` and the real process table.
It uses the shared harness-process classifier in `bin/fm-agent-process-lib.sh`, the same rule the tmux adapter proves liveness with:

| What the process view shows | Verdict |
| --- | --- |
| A harness in the foreground process group, or still a descendant of the pane shell | The registration stays live. |
| A foreground that is nothing but shells, with no harness descendant | A `stale-agent` pane: agent-free, with that explicit reason. |
| A foreground holding anything else | The registration stays live, but only after the same bounded settle window the idle-shell proof uses. |
| An unreadable process view | The pane is `unknown`, trusting neither the registration nor its absence. |

The settle window exists because an idle shell transiently hosts prompt helpers such as starship in its foreground group.
The first agent or shell sample in that window decides.

No registered status outranks the process view, because an agent killed mid-turn leaves `working` behind just as a quit one leaves `idle`.
The native busy verdict is verified the same way, so a shell-only pane never reads busy.

### Process-view version support

The `pane process-info` subcommand that this process-level proof depends on is present in every supported release client from the 0.7.1 floor upward (measured 2026-09-10 on the pinned 0.7.1, 0.7.3, 0.7.4, and 0.7.5 release clients - [verification](verification/runtime-backends.md) "Stale agent registration").
The response shape the adapter parses (`result.type` of `pane_process_info`, `process_info.shell_pid`, and `foreground_processes` entries carrying `name`, `argv0`, `argv`, and `cmdline`) is verified live only on Herdr 0.9.0.
The idle-shell proof's narrower parse was previously verified on 0.7.5.
A server response below 0.9.0 has not been measured for this parse.
An unreadable or unparseable process view reads `unknown`, which refuses lifecycle verbs and recovery rather than trusting the registration.

### Agent-liveness probe

The generic Herdr agent-liveness probe reuses that pane classifier, then applies one recovery-only exception.

| Pane read | Probe verdict |
| --- | --- |
| A structurally gone pane, or a pane read from a session positively reported as having no running server | `missing` |
| A restored agent-less shell, or a stale registration over a shell-only pane | `dead` |
| A registered agent with a live process | `alive` |
| Every other unexpected read | `unreadable` |

Neither the stopped-server exception nor the stale-registration verdict widens husk detection or any close authority.
Those paths still refuse an unreadable pane.
A `stale-agent` pane is reused by recovery, never closed as a husk, because the shell it holds may be a nested worktree shell.

Native registration still identifies Pi by name where tmux would see a generic interpreter.
The process-level proof only decides whether that registration is backed by a running process.
`tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh` pins the live-Pi versus leftover-shell distinction.
[`verification/runtime-backends.md`](verification/runtime-backends.md#agent-lifecycle-control) owns the versioned evidence.

The session-start sweep and the watcher's dedicated secondmate liveness tick use this probe.
Idle secondmates remain exempt from stale-pane escalation.
[Secondmate endpoint recovery](architecture.md) owns the shared supervision mechanism.

## Agent status authority and relaunch

A pane has ONE status authority, and for Pi with the integration installed that authority is the lifecycle hooks - Herdr then skips screen detection for the pane, which is the `full_lifecycle_hook_authority` reason `herdr agent explain` prints for it.
That authority is bound to a session identity, and in the crew shape the registration outliving its process ([above](#restart-and-liveness-behavior)) is that same binding: the record stays, the agent it named is gone.

An agent started FRESH in such a pane reports a new session and Herdr ignores its reports, so the pane stays frozen at whatever the previous agent last reported - a crewmate running its pipeline reads `idle` until its task ends, and nothing from outside repairs it (measured 2026-09-21 on Herdr 0.9.1 against a real Pi; `pane report-agent-session` and `pane report-agent` for `herdr:pi` are accepted without being applied unless the reporter is the registered pane agent, and `pane release-agent` on the stale record changes nothing).
A fresh spawn never meets this: it gets a new pane with nothing bound.

So a **relaunch** preserves the binding instead of fighting it: before the Pi-family launch line is composed, `bin/fm-spawn.sh` reads the pane's recorded session reference through `fm_backend_herdr_pane_agent_session_ref` and passes it back as Pi's own `--session <path-or-id>` (`relaunch_resume_args`; `bin/fm-control-lib.sh`'s `fm_control_relaunch_resume_flag` owns which adapters and which registration labels qualify).
The replacement therefore starts on the exact identity the authority is bound to, and its `working`/`idle`/`blocked` reports land again.
The reference is the endpoint's own record, never a guess about which session is recent, and only a `pi` label may supply it: a registration belonging to another adapter is ignored, as is an unreadable, missing, or malformed one, in which case the relaunch is the ordinary fresh session it always was.
A relaunch that changes harness AWAY from Pi is not repaired by this and keeps the pre-existing behavior; only the adapter the authority belongs to can resume its session.

The session file may not exist any more: Pi creates it at exactly that path, so the identity survives either way.
The read grants no send, close, or lifecycle authority of its own - it is a read of Herdr's record.
The portable halves are pinned by `tests/fm-backend-herdr.test.sh` (the read, against a canned CLI) and `tests/fm-control.test.sh` (the per-adapter rule), and `tests/fm-control-herdr-smoke.test.sh` exercises the relaunch path against the real binary; the versioned live measurement, including the reproduction and the resume that lifts it, is [`verification/runtime-backends.md`](verification/runtime-backends.md) "Pane status authority across a relaunch".

## Push events and polling fallback

Protocol 16 can subscribe to `pane.agent_status_changed` over one bounded Unix-socket reader.
`bin/fm-transition-lib.sh` owns the backend-neutral transition vocabulary and policy.
The Herdr adapter subscribes before reconciling current levels, buffers edges during reconciliation, and returns fresh blocked transitions for this home's panes.

The watcher maps the pane back to the task and skips these:

- Secondmate endpoints.
- Declared `paused:` waits, because the worker's declared wait already accounts for its quiet.
  It is left to the watcher's own bounded pause cadence.
- Verified `captain-held` transfers.
  A captain-held transfer remains silent without rechecks while the away-posture record exists.

### Polling fallback

The push path only shortens latency.
Polling runs every cycle and remains the permanent fallback when any of these is unavailable:

- Protocol 16.
- The event schema.
- Python.
- The connection.
- The subscription.
- Repeated reader execution.

There is still one watcher process; the event reader is a bounded child of that watcher.

`tests/fm-backend-herdr-eventwait-smoke.test.sh`, `tests/fm-transition-lib.test.sh`, and `tests/fm-supervision-events.test.sh` cover capability, subscribe-then-reconcile ordering, dedupe, exemptions, and polling fallback.

## Away-mode supervisor support

[Away-mode supervisor configuration](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target) owns supported backends and detection.
For Herdr, target existence, native state, capture, composer state, and verified submit all route through the shared backend dispatcher and the explicit named-session CLI owner.
The pane-independent max-defer alert is configured in [`wedge-alarm.md`](wedge-alarm.md).

### Where the daemon runs

- Harnesses with native tracked background execution can run the daemon in their terminal.
- Pi and pi-signed no longer launch the away daemon; their ordinary supervision session continues under the posture record.
- A non-Pi home that runs the supervision host also skips the daemon for `/afk`; see [supervision-host.md](supervision-host.md).
- For another harness without native tracked background execution, `bin/fm-afk-launch.sh` runs the daemon in a Herdr workspace, as described next.

In that last case, `bin/fm-afk-launch.sh`:

1. Creates a dedicated unfocused Herdr workspace.
2. Runs the daemon there with an explicit supervisor target and backend.
3. Records the exact daemon pane.
4. Closes only that pane on stop.

It never splits the captain's active tab and never uses shell `&`.
Recovery reconciles only the recorded exact id.

### Stopping the daemon

On stop:

1. The daemon receives termination while `state/.afk` still exists, so its final flush can run.
2. The recorded terminal is closed.
3. The AFK flag is removed last.

A fresh entry clears stale transient escalation caches, while durable queue and task records remain authoritative.

## Destructive lab safety

Never use ambient `herdr server stop` for Firstmate verification.
An environment-only session selection can silently reach a different running server.
The ambient stop command has no explicit target.

`bin/fm-herdr-lab.sh` is the sole supported lifecycle helper for isolated verification.
The helper:

- Provisions only non-default names beginning with `fm-lab-`.
- Supplies an explicit `--session` Herdr option before any `--` delimiter in allowed task commands.
- Refuses caller-supplied session flags and server/session lifecycle subcommands.
- Performs destructive stop/delete only through its guarded lifecycle actions.

Immediately before every destructive call it re-queries the named session and refuses empty, missing, literal `default`, or `default:true` identities.
Its before/after tripwire requires the live default-session snapshot to remain byte-identical.

The helper's header and `--help` own exact commands.
Tests use thin compatibility wrappers in `tests/herdr-test-safety.sh` and never duplicate the destructive policy.

## Active limits

- Presentation ordering needs protocol 16 and Python and is best-effort only.
- Project groups need protocol 22 and Python, are tested offline, and were checked live once against Herdr 0.9.5 on protocol 22.
- Mutable labels can collide; they are never placement or destructive authority.
- Ghost and placeholder recognition uses ANSI de-emphasis when available; an unstyled glyph row carrying trailing non-idle text fails safely to `unknown`.
- Supervisor transport support is separate from task-spawn support; see [away-mode supervisor configuration](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target).

## Regression entry points

```sh
tests/fm-backend-herdr.test.sh
tests/fm-composer-lib.test.sh
tests/fm-herdr-submit-confirm-live-e2e.test.sh
tests/fm-backend-herdr-smoke.test.sh
tests/fm-backend-herdr-prune-safety-e2e.test.sh
tests/fm-backend-herdr-respawn-idem-e2e.test.sh
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh
tests/fm-backend-herdr-launcher-workspace-e2e.test.sh
tests/fm-backend-herdr-presentation-e2e.test.sh
tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh
tests/fm-herdr-pi-stale-registration-live-e2e.test.sh
tests/fm-backend-herdr-eventwait-smoke.test.sh
tests/fm-control-herdr-smoke.test.sh
tests/fm-herdr-session-cleanup.test.sh
tests/fm-herdr-session-cleanup-e2e.test.sh
tests/fm-herdr-groups.test.sh
tests/fm-herdr-terminal-check-e2e.test.sh
tests/fm-herdr-attached-viewer-live-e2e.test.sh
tests/fm-afk-inject-herdr-e2e.test.sh
tests/fm-afk-pi-herdr-return-e2e.test.sh
```

Real Herdr tests use the named lab helper and default-session tripwire.
[`verification/runtime-backends.md`](verification/runtime-backends.md#herdr) records the active version, CLI, projection, event, and lifecycle evidence without task-specific chronology.
