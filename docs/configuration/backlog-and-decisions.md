# Backlog and decisions

Part of the [configuration reference](../configuration.md).

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
A home may instead select another tasks-axi adapter such as Beads through its own `.tasks.toml` or `TASKS_AXI_BACKEND`; firstmate still uses only tasks-axi verbs for routine backlog reads and mutations, and the adapter maps `start` and evidence-bearing `done` transitions to its native statuses and evidence fields.

### Captain holds on Beads

Captain-hold row creation is owned by [`bin/fm-captain-hold.sh`](../../bin/fm-captain-hold.sh) `hold`: when no work item exists, it creates an ordinary backlog row (`--kind captain` metadata; Beads native type `task`) and then applies the captain hold.
Captain rows have no Beads due semantics, so that create path waives a Beads `due.required` setting rather than passing a synthetic `--due`; `--until` remains the optional hold deferral.

Do not register a Beads `types.custom` `captain` type for this: captain is a hold kind, and the fleet Beads `due.required` policy for ordinary work stays in the federated beads config.

### Automatic dispatch and completion

When the automatic transition gate applies, dispatch and completion each move the work item in the same run that creates or removes its task record.
The ordinary successful path therefore keeps the backlog and live task set in sync ([`bin/fm-backlog-transition-lib.sh`](../../bin/fm-backlog-transition-lib.sh)).
Under that gate, dispatch accepts only an unheld, unblocked Queued or In flight item in this home; a missing, Done, held, or dependency-blocked item is refused before any endpoint or local copy is created.

[`bin/fm-tasks-axi.sh`](../../bin/fm-tasks-axi.sh) refuses `add --start` and its `create --start` alias.
Either would place a row In flight without a task record, status file, or inbox, counting it as live work that nobody is doing.
The wrapper still passes through the documented direct transition `tasks-axi start <id>`.
Completion refuses to report success until the item is closed, and session start reconciles this home's own books after an interrupted run.

When a spawn is interrupted after launch delivery began, its exit path re-reads the paired task record and the backlog row under the same per-task lock as the commit, repairs a row the commit believed it had moved, and reports only what was verified or honestly attempted, never intent phrased as outcome ([`bin/fm-spawn.sh`](../../bin/fm-spawn.sh); [`tests/fm-backlog-atomicity.test.sh`](../../tests/fm-backlog-atomicity.test.sh)).

### Which backlog receives a transition

Automatic transitions run from the configured data directory's parent, letting that home's effective tasks-axi configuration address its selected adapter while keeping relative scout-report links rooted there.
A markdown backlog is additionally addressed by an explicit `--file` at `<data>/backlog.md`, so the change lands in the home that owns the task regardless of the caller's working directory.

Any other configured adapter is addressed by that root alone, because `--file` would override the adapter's own workspace path.

### Exemptions and refusal conditions

The gate does not apply to persistent secondmates, manual-backend homes, or markdown homes without a backlog file.
Those retain their existing persistent-agent, manual, or ad-hoc lifecycle behavior.
Configured non-markdown adapters remain active without that file.
Migrated-hold resolution on a beads home reads its graph path, binary, and prefix from the root `.tasks.toml` `[beads]` section only, and refuses (rc=2) when the beads backend is selected elsewhere (a `TASKS_AXI_BACKEND` override or user-level config) with no root-level `[beads]` section.

On an automatic-backend home, missing or incompatible `tasks-axi`, an unresolvable configured data directory, or one containing a control byte fails lifecycle work before mutation.
An unreadable backend configuration can refuse lifecycle work before the no-backlog exemption applies; repair the configuration named in the diagnostic ([backend resolution contract](../../bin/fm-tasks-axi-lib.sh)).

### Handoffs between homes

Secondmate handoffs bypass that routine-backend choice: `fm-backlog-handoff.sh` keeps only its own fleet-level validation and delegates the item move to `tasks-axi mv`; its [script header](../../bin/fm-backlog-handoff.sh) owns route-specific wake outcomes and remote outbox release.
It moves in-scope `## Queued` items only and refuses `## In flight` and historical `## Done` records, which stay with their home for pruning or archiving.

Handoff item bodies must use at least two leading spaces, and the helper refuses a selected item with a single-space or tab-indented continuation rather than risk orphaning it.
Because bootstrap requires `tasks-axi` on `PATH` on every profile, that delegation works fleet-wide, and the `config/backlog-backend=manual` knob governs firstmate's own hand-editing of its backlog, not this validated helper.

### Required tools and manual mode

Compatible means the installed build passes the shared version and feature probe owned by [`bin/fm-tasks-axi-lib.sh`](../../bin/fm-tasks-axi-lib.sh), including the atomic multi-ID move required by handoff delegation.
Bootstrap requires compatible `tasks-axi` on every profile; see "Toolchain" below for required-tool diagnostics and silent default-backend behavior.

Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not required-tool diagnostics.
A `manual` home owns its backlog file outright: the lifecycle transitions above are skipped there, dispatch and completion never fail over the file's contents, and a completed teardown prints the hand edit that is owed instead.

Absent or `tasks-axi` selects the tasks-axi path.
On the default markdown adapter, tasks-axi and manual edits produce the same `## In flight`, `## Queued`, and `## Done` sections.

### Using a separate operational home

The tracked `.tasks.toml` paths resolve against the directory tasks-axi runs in, not `FM_HOME`, so a bare `tasks-axi` run from the code root addresses the code root's `data/` whenever the home lives elsewhere.
tasks-axi replaces its target by renaming a temporary file over it.
If the target is a symlink, the write replaces it with a regular file.
Linking the code-root copy into the home therefore forks the queue on the first write instead of keeping the copies in sync.

Run every routine Firstmate backlog command through [`bin/fm-tasks-axi.sh`](../../bin/fm-tasks-axi.sh).
Like lifecycle transitions, it addresses this home's backlog and archive from any working directory.
It also guards note edits: an `update` that sets a body is refused when the existing note cannot be read or the new body drops its text, unless `--replace` or `--archive-body` is given, and `--append <text>` adds a line after the existing note ([body-edit contract](../../bin/fm-tasks-axi.sh)).
Bootstrap reports a code-root `data/backlog.md` or `data/done-archive.md` that is not this home's own file as a `BACKLOG_RECONCILE: code-root ...` line, even in a read-only session.

## Open-decision reminders (config/open-decision-reminders)

The optional local, gitignored `config/open-decision-reminders` presence flag enables a default-off watcher backstop for unanswered keyed `needs-decision` and `blocked` records.
On each poll, the watcher queues at most one `check: open decision overdue: <task> key=<key> age=<seconds>s` wake for the oldest eligible overdue key, independently of pane state or supervision-branch classification.
Declared `paused:` waits and tasks already held for the captain are exempt.
A `captain-hold-<task>-<n>` key, which a secondmate's `bin/fm-captain-hold.sh hold` relays on its parent channel, is exempt by that key prefix alone, because the captain already holds that decision.
When that hold was set with `--until YYYY-MM-DD`, the relayed line carries a structured `[until=YYYY-MM-DD]` field before its first colon, and the key re-arms from 00:00 UTC on that date; a malformed field re-arms it at once.
A hold set with `--origin-key <key>` also carries a structured `[origin-key=<key>]` field there, naming the plain `needs-decision` key the open hold already covers so a consumer can card the hold alone; the key fold and every other reader ignore the field, and a hold with no origin key recorded for its occurrence carries none (a re-hold of the same occurrence keeps the recorded key).
Note text never decides either exemption.
Resolving a key stops its reminders, and a later opening starts a new reminder episode.
Republishing a still-open key with a new `[at=<epoch>]` but the same verb and note keeps its first opened time and reminder schedule instead of restarting them, while a changed verb or note, or a resolution followed by a reopen with the same text, starts a new episode.
Only explicit keys with valid source `[at=<epoch>]` timestamps can be aged.

`FM_OPEN_DECISION_OVERDUE_SECS` defaults to `1800` seconds.
Repeats start at that interval, double after each repeat, and cap at `FM_OPEN_DECISION_BACKOFF_MAX_SECS`, which defaults to `14400` seconds.
Both settings must be canonical positive integers of at most nine digits, with the cap at least the threshold.
Invalid settings stop the watcher with an error when the flag is present.
Pass them in the watcher's environment, or export them in `config/watch.env` for watchers started through `bin/fm-watch-arm.sh`.
The flag is home-local and is not inherited by secondmate homes.
`bin/fm-watch.sh`'s `open_decision_reminder_tick` owns the per-key schedule, which persists across watcher restarts.

## Captain-hold deadline defaults (config/captain-hold-defaults)

The optional local, gitignored `config/captain-hold-defaults` file holds one word that sets what `bin/fm-captain-hold.sh answer <id> --deadline-default` does for a due deadline default.
`dry-run` (also the behavior when the file is absent, empty or says anything else) only appends what it would have answered, when and for which task to `state/captain-hold-default.log` and answers nothing.
`live` records the owner-generated words through the guarded answer path, labelled as not the captain's.
Going live is this one-line change; the wake drain lists due calls in both modes.
An optional `config/admission/captain-hold-defaults.rules` file, in the `bin/fm-reserved-classify.sh` rules format, classifies the paths a call declares with `hold --touches`; a flagged path or a missing file with `--touches` refuses the default.
[`captain-hold-lifecycle.md`](../captain-hold-lifecycle.md#deadline-defaults) owns the mechanism and the `bin/fm-captain-hold.sh` header owns the fields and refusals.
The file is home-local and is not inherited by secondmate homes.
