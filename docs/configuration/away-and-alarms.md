# Away mode and alarms

Part of the [configuration reference](../configuration.md).

## Away-mode supervisor backend (FM_SUPERVISOR_BACKEND / FM_SUPERVISOR_TARGET)

The `/afk` sub-supervisor injects escalation digests into firstmate's own endpoint independently of where new task endpoints are spawned.
It supports `tmux`, `herdr`, and `rex` supervisor panes and `t3code` supervisor threads.

Set `FM_SUPERVISOR_BACKEND=tmux|herdr|rex|t3code` and `FM_SUPERVISOR_TARGET=<target>` to override both axes explicitly.
For tmux, accepted targets are `%pane-id`, `@window-id`, `session:@window-id`, a bare session, `session:window-name`, `session:index`, `session:index.pane-index`, and the supported `=session:=window` exact-marker forms; the `fm_backend_target_exists` header in `bin/fm-backend.sh` owns this grammar.
For herdr, the target is `"<session>:<pane-id>"`; for Rex it is `<session-uuid>:<block-uuid>`, with both kind prefixes removed; and for t3code it is the thread id.
Without overrides, backend detection uses `$TMUX_PANE` first, then `HERDR_ENV=1` with `HERDR_PANE_ID`, then `TERM_PROGRAM=rex` with both `REX_SESSION` and `REX_BLOCK`, then `HC_TERMINAL_ID` with `HC_TERMINAL_SOCKET` (resolving `hc`), then a cwd match over T3's live threads only when T3 Code is explicitly selected, then falls back to `tmux`.
T3 discovery requires explicit `FM_BACKEND=t3code` or `config/backend=t3code` and the `config/t3code-token` credential from the [T3 sign-in](../t3code-backend.md#sign-in) under the effective config directory before making a T3 call.

That keeps a nested tmux or Herdr pane on its own transport, matching the runtime backend's innermost-first rule.
Target detection uses `FM_SUPERVISOR_TARGET`, then `$TMUX_PANE`, then `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` under herdr, then the prefix-stripped `REX_SESSION` and `REX_BLOCK` under Rex, then `"${HC_SESSION:-default}:${HC_TERMINAL_ID}"` when both hc terminal markers are present, then the thread id from that T3 cwd match, then the legacy `firstmate:0` tmux fallback with a warning.

Selecting or discovering any other supervisor backend, including `hc`, `zellij`, `orca`, `cmux`, or `tern`, refuses at daemon startup instead of trying tmux injection primitives against a non-tmux pane.

## Away-mode wedge alarm channels (config/wedge-alarm)

When away-mode injection wedges past `FM_MAX_DEFER_SECS`, the sub-supervisor raises a loud, rate-limited alarm.
Beyond the durable `state/.subsuper-inject-wedged` marker and the tmux status-line flash, it attempts a configured backend-independent active alert that can reach the captain even when every pane and its backend status-line is unreadable.

### Channels and overrides

`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive.

Directives are `off` (a position-independent kill switch that disables every active alert), `auto`/`default`, `osascript` (macOS Notification Center banner), `herdr` (herdr UI notification), and `command:<cmd>` (run `<cmd>` via `sh -c`, summary on `$1` and stdin).
An absent file means `auto`, i.e. default-on on macOS: the alarm exists precisely so a wedged away-mode primary is never silent, and it fires at most once per max-defer window after a genuine wedge.

A missing or failing channel logs and falls through to the next, never crashing the daemon.
See [`wedge-alarm.md`](../wedge-alarm.md) for the current channel reference, [`verification/supervision.md`](../verification/supervision.md#wedge-alarm-channels) for active evidence, and [`examples/wedge-alarm`](../examples/wedge-alarm) for a copyable config.

## Lee-step host (config/lee-step-host)

The optional local, gitignored `config/lee-step-host` names, on its first non-blank line not beginning with `#`, the machine the captain reads Lee steps on (main's session), not the machine the worker or script runs on.
`bin/fm-lee-step.sh` compares the target host of a command the captain must run by hand with it, case-insensitively and ignoring a `user@` prefix or domain suffix.
It prints `bash <script>` only when the file is set and they match, because ssh to the machine one is already on has no key.
Otherwise, including when the file is absent, it prints `ssh -t <host> '...'`, which works from any machine, so a step is never shown as a local command on the wrong machine.
Every step also names why no agent can run it, `--cause sudo|credential|policy|tool|physical`, the same values a `blocked` or `needs-decision` line carries as `[cause=...]`.
A `--cause sudo` step is refused unless `--no-recipe <why>` states that no `fleet-admin` recipe covers it, because root work runs as `sudo -n fleet-admin <recipe>` and a new root ability ships as a recipe; the reason is printed on the step.
With the file unset the command prints an ssh line even for the machine the session is on, and says on stderr that `config/lee-step-host` fixes that.
`bin/fm-worktree-assert.sh <task-id>` is the matching check for a worker session restored after a restart: it refuses, naming the exact directory, unless the current directory is the worktree the task record names.

## Fleet quota and secondmate alarm (config/fleet-alarm.json)

The opt-in alarm reports Claude weekly quota pressure, stale or unavailable quota readings, and registered second mates holding work without recent communication.
Idle second mates are healthy.
In-flight work whose child is done with a PR waiting on merge (`counts.waiting_on_merge` in the home summary; `bin/fm-fleet-snapshot.sh`'s header owns when a child qualifies) is not held work, so it neither invalidates the inventory nor makes its second mate silent. The same holds for a held in-flight item with no child that declares an external wait that has not passed its hold-until (`counts.external_wait_in_flight`).
A second mate waiting on an open captain decision is also healthy: with at least one captain-hold row in its open decisions, it is not silent, whatever its in-flight count and even with a live worker beside the hold, because that decision is already on the Captain's Log.
A second mate whose own latest line is a `needs-decision` with no `resolved` line for its key is parked on an answer and is not silent, whatever the key names, unless a child is asking it something. A `paused` line that follows the mate's own plain `needs-decision` asks (not a `blocked` line or a `[handoff=<home>]` ask) is judged as a declared pause below: a dated one counts until its `until` time is more than the silence window past, and an undated one counts within the `working_ceiling_multiple` ceiling, or the `external_wait_ceiling_hours` ceiling when it is tagged `[cause=external]`.
A second mate without a captain-hold row is not silent either when the keys of its own open `needs-decision` lines together name every in-flight item it holds that is not waiting on merge or on an external wait (each key is the item id, or `captain-hold-<id>-<n>`); a `blocked` line never exempts, and a truncated child list or one in-flight item no open ask names keeps the silence check live.
A second mate whose own latest line is `working` or `paused`, while it holds work and has no open question to main (an open external merge handoff, a `needs-decision` keyed `merge-handoff-<n>` whose text starts with `[handoff=<home>]`, waits on another home and is not a question to main), is on a long task that reports sparingly and is not silent either: a `paused` line with an `until` time counts until that time is more than the silence window (`silent_minutes`, default 60) past, and any other such line counts while it is younger than `working_ceiling_multiple` (default 6) silence windows, so 6 hours by default. A `paused` line tagged `[cause=external]` with no `until` time is a declared wait and counts instead while it is younger than `external_wait_ceiling_hours` (default 24); the alarm reads a line's `until` time only from an `until <YYYY-MM-DDTHH:MMZ>` token or a `[until=<YYYY-MM-DDTHH:MMZ>]` tag before the line's first colon, never from a date-only phrase such as `until 2026-11-13`. A plain informational `done` line does not end a declared pause: when the latest line is `done`, the most recent earlier `working`, `paused`, `blocked` or `needs-decision` line decides, and a `paused` one is judged by its own age and `until` time as above. Only `working`, `blocked`, `needs-decision` or a new `paused` line supersedes it. The silence check still uses the age of the latest line, so the `done` line counts as the mate speaking.
The alarm stays for a mate that holds work with no open captain hold and a latest line that is anything else, a declared pause whose clearing time is long past, a `working` or open-ended `paused` line older than the `working_ceiling_multiple` ceiling, or an undated `paused [cause=external]` line older than `external_wait_ceiling_hours`.
An open status-sourced decision (a child asking its own second mate) still alarms unless the mate also holds that same task id as a captain-hold row, which makes it the mate waiting on the captain (such an ask is suppressed for as long as the hold stays open, including a later, unrelated ask from that child), or, while the mate's deciding line is a `paused` line whose `until` time is not more than the silence window past, unless the summary's endpoints list that child as `parked`; a truncated `decisions_open` list, or an invalid summary still alarms; a summary whose only invalidity is unavailable child liveness (`child_current_unavailable`) still qualifies.
It reads quota through `cpa-usage-axi`, using `config/cpa-usage-host` for remote reads, and reads published home summaries for registered second mates without building a full fleet snapshot.
Remote summary reads share the alarm deadline, each getting an equal share of the budget left among the remote reads still to come (local mates never consume a share), and fall back to the parent-side route-keyed cache.
Missing, malformed, or stale home summaries from reachable homes produce an inventory alert; the configured stale-data threshold applies to summaries too.
An unreachable home without usable cached inventory is recorded quietly as not collected, including an offline laptop.
An incomplete child-liveness observation preserves the independently complete in-flight work count; other inventory contradictions still alert with their reason.
An in-flight item whose child is done (`terminal_in_flight`) is complete, not a contradiction, when the second mate holds that same task id as a captain-hold row and its open-decision list is not truncated.
Without a captain-hold row, an in-flight item whose child is done is normal work between the child's `done` line and the merge and clean-up, so it does not invalidate the inventory while every such done line is younger than `done_grace_hours` (default 2). The line's age is the endpoint's `age_seconds` plus the time since the summary was generated. Past that, the alarm raises a `done-uncleaned` finding, `Done task not merged and cleaned up`, naming each task and its age. The summary publishes `age_seconds` only for a done state read from the child's own `done` status line; a done endpoint with no known done time (an unstamped line, or a done state from a passed no-mistakes run) stays inside the grace period. A `terminal_in_flight` that names a child that is not done keeps the inventory alert. A done or failed no-mistakes ship whose branch has a live newest run (`run_active` in the summary) is mid-validation and is never `terminal_in_flight`; `bin/fm-fleet-snapshot.sh`'s header owns the rule.
A no-mistakes worker's pre-validation `done: ... ready for /no-mistakes` is a pipeline handoff, not a finished child, and does not count as `terminal_in_flight`, while the branch has a live run or the CLI reports no run for it. A done ship parked as a ready branch (`ready_branch=` and no `pr=`) is waiting for a PR place by design: it is not `terminal_in_flight`, so it raises no `done-uncleaned` finding (`bin/fm-fleet-snapshot.sh`'s header owns the predicate).
An inventory alert waits until the same finding appears in `persist_polls` consecutive polls of a channel (default 2), so an item that is missing on one poll and present on the next raises nothing.
The timer's `needs-decision` line carries a `[cause=...]` tag, `decision` for quota pressure and `tool` for an unreadable reader or inventory, so the friction officer groups it with other blocked lines.
A silent second mate is an external wait, not a question for the captain: the timer appends a `paused` line tagged `[cause=external]` that names the second mate, says it is expected back when it reports again, and carries an `until` recheck time `stale_minutes` ahead, so firstmate rechecks it then instead of holding the task.
If the second mate is still silent when that time passes, the next timer poll re-emits the wait once as `needs-decision [cause=external]`, naming the second mate, how long it has been down and the recovery it was expected by, so it reaches the captain; later polls do not repeat it, and it resolves when the condition clears.
A silent second mate whose home becomes unreachable, or whose inventory cannot be read, still counts as holding for that recheck.
A question line that loses every alarm except silent second mates is resolved and replaced by the paused wait.
The quota alarm fires when mean remaining weekly capacity across non-stale Claude readings falls below the pool threshold, or a carrying account is at or above its own proxy threshold while no non-stale account below its own threshold is serving and the finding has persisted for `persist_polls` polls (traffic failed to move).
Each account's threshold comes from the quota proxy's own routing settings: `routing.quota-threshold` (default 100) and the per-account `routing.quota-thresholds` (account emails compared lower-case), in percent.
The alarm reads them from the proxy's fixed config file, `~/.config/cli-proxy-api/config.yaml` in the home directory of the host that serves the quota reads, local or over SSH.
Only those routing keys are extracted on that host; the rest of the file holds secrets and is never returned, printed, logged or stored.
When the file cannot be read, has no valid routing block, or writes the thresholds in a form the reader does not parse (an inline map such as `quota-thresholds: {...}`, or an account whose value sits on its own line), `seven_day` (default .9) is the fallback for every account, and the alarm text says `seven_day fallback` and that the proxy config is unreadable.
A carrying-account finding alarms once, and stays quiet while its weekly reset is within `carrying_reset_hours` (default 6) and mean remaining weekly capacity stays above `carrying_pool_floor` (default 0.4).
It alerts again when either condition stops holding; the pool-near-empty alarm is unaffected.
Every Claude account with successful Claude-model requests in the last 60 minutes is carrying; several accounts can qualify, and failed-only traffic does not qualify.
A card that carries a quota alarm ends with a `Claude quota context (not an alarm; proxy view)` line naming the accounts serving in the last 15 minutes (with each one's weekly use, or `reading stale/unknown`), the pooled weekly headroom across non-stale accounts, and the non-stale accounts at or above their own threshold as rotated out; cards for other alarms, such as a silent second mate, leave it off, and pressure alone on an idle account does not trigger an alarm.
With no successful traffic in the last 60 minutes, the carrying condition is skipped; with none in the last 15 minutes, the card says so; the pool condition still applies either way.
The quota reader does not expose enabled status, so the pool uses reading freshness rather than verified account enablement.
Mean remaining capacity does not predict how long the pool can sustain a workload.
Silence is measured from the later of the second mate's spawn and its newest stamped parent-channel line that main did not append itself; main's own answers, hold transfers, and no-reply or remote-reply continuity escalations do not count.
The watcher republishes home summaries on its own, so a fresh summary does not prove the agent is awake.
A spawn-failure line main writes at launch falls inside the spawn window; a legacy mate with no `spawn_gen` and no stamped line of its own alarms on the first check.
A Claude account with no reading is reported as unknown and left out of the pool mean.
Accounts with no reading for seven days are treated as retired: they raise no stale alarm, stay out of the pool mean, and are reported once as a count of ignored accounts that does not keep the Captain's Log card open.
Older home-summary producers without `counts.in_flight` use their active-worker, hold, and decision counts, which cannot identify a program with no active worker.
Update second mates before relying on coverage of those programs.
Not-collected homes preserve their own prior silence and inventory-failure receipts; only such a kept receipt stops the timer from resolving an open alarm.

Each poll also reads the [PR drain](projects-and-forges.md#pr-drain-open-pr-drain-rule) state of every clone under the home's `projects/`, inside the same reader budget, and announces only a change from what that channel last announced: the check prints one line, which reaches main as its check wake, and the timer appends a `working [key=pr-drain-<owner>-<repo>]` line on drain-on and a `resolved` line with the same key on drain-off, each naming the repository and its eligible count and asking main to relay the change to every home.
Repeated polls in one state stay quiet, and an unknown read keeps the last announced state.
Each clone's read gets an equal share of the reader budget still left, and a clone whose read failed, ran out of budget or found GitHub unreadable is named after `PR drain unread:` at the end of the timer's `RUN-RESULT` summary; an undecided history (no 24 or more, and no S or fewer, in the window) is a normal answer and is not named.
Each poll also compares the eligible open PR count (the count the drain reads: each landing pile and its members counted once, and no draft, promotion PR, PR waiting for the captain or PR labelled `held`) of every clone whose project declares [CI slots](projects-and-forges.md#ci-slots-configci-slots) with that number, announcing only a change: the timer appends a `working [key=ci-slots-over-<owner>-<repo>]` line when the open PRs exceed the slots and a `resolved` line with the same key when they are back at or under them, each naming both numbers, and the check prints one line; a clone with no slots, or whose count or slots cannot be read, is skipped quietly.

Each poll also reads every secondmate's queue counts from its home summary: more than `queue_depth` (default 30) unheld queued items raises `queue-depth:<home>`, and an oldest unheld item more than `queue_age_days` (default 14) old raises `queue-age:<home>`.
Held rows are not counted, a home with nothing but a queue is still checked, and a summary without the counts raises nothing.
A queue finding is a report for its home, not a question for the captain, so it never joins the `needs-decision [key=fleet-alarm]` line.
The timer appends one `working [key=queue-depth-<home>]` or `[key=queue-age-<home>]` line and sends the same text to that home's inbox, again only when the finding reaches a new peak: the unheld count enters a band of 10 above the highest it reported, or the oldest age a band of 7 days above its highest.
A finding that improves sends nothing and keeps its peak, and one that clears appends a `resolved` line with its key, so crossing the threshold again reports afresh.
`bin/fm-backlog-reconcile.py` is the sweep those alarms point at.

Each poll also scans this host's own process table for orphaned build and test processes, and never stops anything.
A process counts when it is a dotnet build or test process (MSBuild, VBCSCompiler or testhost, with or without the dotnet host in front), node running vitest, jest or playwright, or a browser Playwright launched from its own cache or profile directory, its parent is PID 1 or its session leader is gone, and it is older than `orphan_proc_hours` (default 3, next to the other thresholds in `config/fleet-alarm.json`).
A change in that count is announced once per channel as above: the check prints one line, and the timer appends a `working [key=orphan-procs-<host>]` line with the count, resident memory and oldest age, then a `resolved` line with the same key once the count is back to zero.
An unreadable process table keeps the last announced state.

`bin/fm-fleet-alarm.py` owns the configuration keys, defaults, command syntax, reader budget, deduplication receipts, and timer-file generation.
`tests/fm-fleet-alarm.test.sh` exercises the alarm with offline quota and summary fixtures and the real fleet-ledger publisher.
The alarm uses the custom-check contract on every primary tool; its independent timer runs the same check without starting another fleet supervisor.
The two paths have separate delivery receipts so a regular check cannot suppress the timer's alert.
The timer publishes keyed `needs-decision` status through the existing fleet activity ledger for Captain's Log readers, and publishes `resolved` when all conditions clear.
Each timer run also prints one `RUN-RESULT` stdout line for the fleet app's Runs page: the open alert count and quota context, or a `skipped` outcome when another alarm run holds the lock.
That publication still requires a working machine, scheduler, ledger storage, and Captain's Log reader; it cannot alert during a machine outage.

From the primary home's stable code directory, set `FM_HOME` to the primary home, then register the check:

```sh
export FM_HOME="$PWD"
python3 bin/fm-fleet-alarm.py arm
```

To alert while the primary's monitor is stopped, turn on the fleet activity ledger and install one user timer.
No command needs sudo.
The generated timer captures the installation shell's `PATH` and the primary home; regenerate it after changing those paths.
Existing scheduler files are never overwritten.

```sh
mkdir -p "$FM_HOME/config"
touch "$FM_HOME/config/fleet-ledger"
```

On macOS:

```sh
python3 bin/fm-fleet-alarm.py timer-files darwin "$HOME/Library/LaunchAgents"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.firstmate.fleet-alarm.plist"
```

On Linux:

```sh
python3 bin/fm-fleet-alarm.py timer-files linux "$HOME/.config/systemd/user"
systemctl --user daemon-reload
systemctl --user enable --now firstmate-fleet-alarm.timer
```

To turn off independent alerts, run `launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.firstmate.fleet-alarm.plist"` on macOS or `systemctl --user disable --now firstmate-fleet-alarm.timer` on Linux.
To turn off the registered check too, run `bash bin/fm-check-unregister.sh fleet-alarm` with the same `FM_HOME`.
Neither action removes the alarm's history or turns off the ledger for other producers.

## Turn-end pane-churn absorb (config/turnend-churn-absorb)

The optional local, gitignored `config/turnend-churn-absorb` presence flag opts this home into a default-off third form of positive work evidence in watcher triage.
With it present, every referenced task must independently show positive work evidence, and an eligible bare turn-ended task that lacks authoritative proof may satisfy that requirement when its pane content changed since the previous poll.

### Evidence and time limit

It stays opt-in because the other two proofs read a verdict the harness itself vouches for while this one infers execution from rendered bytes; with the flag absent triage behaves exactly as it did before.
`FM_TURNEND_CHURN_ABSORB_SECS` is a positive integer number of seconds, defaults to `900`, and bounds how long one endpoint's turn-ends may ride that evidence before surfacing anyway.

An invalid value fails closed and surfaces the wake.
The bound is required rather than cosmetic because churn and pane staleness read the same pane.

The flag is a home-local supervision-noise preference and is not inherited by secondmate homes, which run their own crew mix.
[`architecture.md`](../architecture.md) owns the triage contract and `bin/fm-watch.sh`'s `signal_turnend_panes_churned` owns the exact evidence and fail-closed boundaries.

## Parked-gate wait deferral (config/wedge-defer-parked-gate)

The optional local, gitignored `config/wedge-defer-parked-gate` presence flag opts this home into a default-off further form of wait evidence in the watcher's wedge timer.

### When a waiting gate defers an alarm

With it present, a provably-working pane about to escalate is also deferred to the `FM_PAUSE_RESURFACE_SECS` recheck cadence when its crew's own current state is a validation gate whose answer is owed to the supervisor and whose decision for that run is still open, and the recheck names the supervisor and the action that clears the lane instead of reporting a suspected wedge.
It stays opt-in because the other evidence is a written record of the lane's silence - the worker's own declaration or firstmate's backlog captain hold - while this is derived from a pipeline's gate state, so which lanes give up the escalation ladder for it is a home's choice.

With the flag absent the wedge timer spends no fold or current-state read for it, writes no record, and keeps the unchanged escalation schedule, reasons, and `demand-deep-inspection` wording.
The flag is a home-local supervision-noise preference and is not inherited by secondmate homes, which supervise their own crew and own that trade separately.

[`architecture.md`](../architecture.md) owns the wait-evidence contract and which records may take the ladder away; `bin/fm-watch.sh`'s `wedge_wait_evidence` owns the exact derivation and its fail-closed boundaries.

## Wedge evidence guards (config/wedge-evidence-guards)

The optional local, gitignored `config/wedge-evidence-guards` file opts this home into consulting operator-owned [Jev guards](../jev-guards.md) before the watcher wedge-escalates a quiet live pane.
It lists one absolute guard executable path per line, and blank lines and `#` comments are skipped.
The file and every listed executable must be regular files owned by the watcher's user and not group or world writable, or they are never run.

### When a guard defers an alarm

Only at the wedge threshold, after the declared-wait, worktree-write, dead-endpoint, and opt-in validating-run checks have all let the escalation through, the watcher runs each guard as `<guard> --json` with `FM_GUARD_TASK` and `FM_GUARD_ENDPOINT` set, bounded by `FM_WEDGE_GUARD_TIMEOUT_SECS`.
The first guard that prints one JSON object with `status` `CRITICAL` and a non-empty `recommendation` defers that escalation by one window, without advancing the escalation count.
After `FM_WEDGE_GUARD_DEFER_MAX` consecutive deferrals the escalation fires anyway, and its reason names the guard and the first line of its recommendation.
A timeout, non-zero exit, malformed output, `OK`, `WARNING`, or `UNKNOWN` changes nothing, and a dead or missing endpoint is reported before any guard is asked.
A guard's answer is evidence only and never authorizes a decision, merge, cleanup, or any other action.

With the file absent the watcher runs no guard, writes no record, and keeps the unchanged escalation schedule, reasons, and `demand-deep-inspection` wording.
The file is home-local and not inherited by secondmate homes.

### Example operator family

Firstmate ships no default guard for this; host-specific families belong to the operator's own layer.
For example, an operator whose workers hold numbered tickets in a local queue directory could list a guard like this:

```sh
#!/bin/sh
# CRITICAL while this task holds a queue ticket whose recorded job is alive.
ticket="$HOME/queue/$FM_GUARD_TASK.ticket"
if [ -f "$ticket" ] && kill -0 "$(head -n 1 "$ticket")" 2>/dev/null; then
  echo '{"name":"ticket-dir","status":"CRITICAL","recommendation":"queue ticket held by a live job"}'
else
  echo '{"name":"ticket-dir","status":"OK","recommendation":"no live queue ticket"}'
fi
```

`bin/fm-watch.sh`'s `wedge_guard_evidence` and `wedge_defer_guard` own the exact invocation, deferral record, and fail-open boundaries.

## Worker-declared wait deferral (config/wedge-defer-worker-wait)

The optional local, gitignored `config/wedge-defer-worker-wait` presence flag opts this home into a default-off form of wait evidence in the watcher's wedge timer.
With it present, a provably-working pane about to escalate is deferred to the `FM_PAUSE_RESURFACE_SECS` recheck cadence when its newest status line is the worker's own still-open `blocked:` or `needs-decision:` line, and the recheck names firstmate and that verb's clearing action instead of reporting a suspected wedge.
Lines under supervisor-reserved keys do not count, the escalation count does not rise, and any newer status line or a newer acknowledged steering-inbox record ends the deferral, so an answered lane that never resumes returns to the ladder.
The away-mode daemon honors the same evidence before it escalates a possible-wedge wake.

With the flag absent the wedge timer spends no read for it and keeps the unchanged escalation schedule, reasons, and `demand-deep-inspection` wording.
The flag is a home-local supervision-noise preference and is not inherited by secondmate homes.
[`architecture.md`](../architecture.md) owns the wait-evidence contract and `bin/fm-classify-lib.sh`'s `status_worker_wait_verb` owns which lines count.

## Superseded declared-wait wake (config/paused-wait-supersession)

The optional local, gitignored `config/paused-wait-supersession` presence flag opts this home into a default-off check in the watcher's declared-wait handling.
With it present, a pane whose worker's newest wait line is a `paused:` declaration is surfaced ahead of the `FM_PAUSE_RESURFACE_SECS` recheck cadence when its crew's own current state shows the wait no longer explains the quiet: the run is parked at a human-owed gate with no open `needs-decision` for that run, or the run is terminal.
Each superseding state surfaces once per declaration and run on both the idle and busy paths, and repeats use the same bounded recheck cadence.
It stays opt-in because it adds a wake reason that fires ahead of that cadence and spends a current-state read on each paused poll, so which lanes pay that read for earlier notice is a home's choice.

With the flag absent the watcher spends no current-state read for it and keeps the unchanged declared-wait cadence and wording. The flag affects the foreground watcher only; away mode keeps today's declared-wait pause cadence.
The flag is a home-local supervision-noise preference and is not inherited by secondmate homes.
[`architecture.md`](../architecture.md) owns the declared-wait contract and `bin/fm-watch.sh`'s `paused_wait_superseded` owns the exact derivation, reasons, and throttle.

## Silent paused rechecks (config/paused-recheck-silent)

The optional local, gitignored `config/paused-recheck-silent` presence flag opts this home into a default-off quiet form of the declared-wait recheck.
With it present, the watcher's `FM_PAUSE_RESURFACE_SECS` recheck of a worker's `paused:` declaration queues no wake when the declaration is unchanged since its first recheck wake, the agent is confirmed alive (a secondmate's liveness is never read), its declared `until` time is not yet due, and the task has no open decision.
The watcher records the recheck in the declaration's existing throttle marker, so the recheck cadence is unchanged.
A first sight, a changed status line, a due declared time, and an open decision still wake.
Captain-held transfers are not affected.

With the flag absent, every recheck wakes as before.
The flag is a home-local supervision-noise preference and is not inherited by secondmate homes.
`bin/fm-watch.sh`'s `handle_paused_stale` owns the exact condition.

## Validating-run deferral (config/wedge-defer-validating)

The optional local, gitignored `config/wedge-defer-validating` presence flag opts this home into a default-off deferral in the watcher's wedge timer.
With it present, a provably-working pane about to escalate is deferred to the `FM_PAUSE_RESURFACE_SECS` recheck cadence when its crew's attributed no-mistakes run step is `validating (running)` or `validating (fixing)`, because the worker is correctly idle behind its own drive call while the pipeline executes the round.
The recheck names that run instead of reporting a suspected wedge, the escalation count does not rise, and a run that is parked, terminal, ci-monitoring, absent or unreadable keeps the ladder.
The away-mode daemon has no such deferral of its own.

With the flag absent the wedge timer spends no current-state read for it and keeps the unchanged escalation schedule, reasons, and `demand-deep-inspection` wording.
The flag is a home-local supervision-noise preference and is not inherited by secondmate homes.
[`architecture.md`](../architecture.md) owns the deferral contract and `bin/fm-classify-lib.sh`'s `crew_run_is_validating` owns which verdicts count.

## Pause ceiling (config/pause-ceiling)

The optional local, gitignored `config/pause-ceiling` presence flag opts this home into a default-off ceiling on declared `paused:` waits.
With it present, a dated pause becomes overdue once more than `FM_PAUSE_RESURFACE_SECS` has passed since its `until` time.
An undated pause becomes overdue once it is older than `FM_PAUSE_UNDATED_MAX_SECS` (default 86400 seconds), aged from its own `[at=]` stamp or, when the line has none, from the status file's last change.
An overdue pause appends one stable `blocked [key=paused-overdue-<task>]` decision to the task's status log, asking the captain to decide or release the wait, and raises one stale wake in place of the pause recheck.
It never enters the wedge escalation ladder and never interrupts, kills, or tears anything down.
The decision then stays quiet through pane churn and through resolutions of other keys, and closes when the worker appends a status event other than another `blocked:` line or a repeat of the same pause, or when a `resolved` line closes that key.
The watcher raises it, and under an away or quiet posture record the away-mode daemon raises it and reports it once.
Teardown removes the task's `state/.paused-overdue-<task>` record.

With the flag absent no pause is ever overdue, no such decision opens, and declared waits keep the unchanged `FM_PAUSE_RESURFACE_SECS` recheck cadence.
The flag is a home-local supervision preference and is not inherited by secondmate homes.
`bin/fm-classify-lib.sh`'s `status_pause_is_overdue` owns the thresholds, and `bin/fm-watch.sh`'s `pause_overdue_reconcile` and `bin/fm-supervise-daemon.sh`'s `reconcile_overdue_pause` own when the decision closes.
