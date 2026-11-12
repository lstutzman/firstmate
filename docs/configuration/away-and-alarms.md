# Away mode and alarms

Part of the [configuration reference](../configuration.md).

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
In-flight work whose child is done with a PR waiting on merge (`counts.waiting_on_merge` in the home summary; `bin/fm-fleet-snapshot.sh`'s header owns when a child qualifies) is not held work, so it neither invalidates the inventory nor makes its second mate silent.
A second mate waiting on an open captain decision is also healthy: with at least one captain-hold row in its open decisions, it is not silent, whatever its in-flight count and even with a live worker beside the hold, because that decision is already on the Captain's Log.
A second mate without a captain-hold row is not silent either when the keys of its own open `needs-decision` lines together name every in-flight item it holds that is not waiting on merge (each key is the item id, or `captain-hold-<id>-<n>`); a `blocked` line never exempts, and a truncated child list or one in-flight item no open ask names keeps the silence check live.
A second mate whose own latest line is `working` or `paused`, while it holds work and has no open question to main, is on a long task that reports sparingly and is not silent either: a `paused` line with an `until` time counts until that time is more than the silence window (`silent_minutes`, default 60) past, and any other such line counts while it is younger than `working_ceiling_multiple` (default 6) silence windows, so 6 hours by default. A `paused` line tagged `[cause=external]` with no `until` time is a declared wait and counts instead while it is younger than `external_wait_ceiling_hours` (default 24); the alarm reads a line's `until` time only from an `until <YYYY-MM-DDTHH:MMZ>` token, never from a date-only phrase such as `until 2026-11-13`.
The alarm stays for a mate that holds work with no open captain hold and a latest line that is anything else, a declared pause whose clearing time is long past, a `working` or open-ended `paused` line older than the `working_ceiling_multiple` ceiling, or an undated `paused [cause=external]` line older than `external_wait_ceiling_hours`.
An open status-sourced decision (a child asking its own second mate) still alarms unless the mate also holds that same task id as a captain-hold row, which makes it the mate waiting on the captain (such an ask is suppressed for as long as the hold stays open, including a later, unrelated ask from that child); a truncated `decisions_open` list, or an invalid summary still alarms; a summary whose only invalidity is unavailable child liveness (`child_current_unavailable`) still qualifies.
It reads quota through `cpa-usage-axi`, using `config/cpa-usage-host` for remote reads, and reads published home summaries for registered second mates without building a full fleet snapshot.
Remote summary reads share the alarm deadline and fall back to the parent-side route-keyed cache.
Missing, malformed, or stale home summaries from reachable homes produce an inventory alert; the configured stale-data threshold applies to summaries too.
An unreachable home without usable cached inventory is recorded quietly as not collected, including an offline laptop.
An incomplete child-liveness observation preserves the independently complete in-flight work count; other inventory contradictions still alert with their reason.
An in-flight item whose child is done (`terminal_in_flight`) is complete, not a contradiction, when the second mate holds that same task id as a captain-hold row and its open-decision list is not truncated.
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
