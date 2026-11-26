# Home and state

Part of the [configuration reference](../configuration.md).

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.

| Location | What it contains | Default relationship |
| --- | --- | --- |
| Firstmate repo root | Shared code, including the scripts in this repo's `bin/` | Most scripts also use this as the operational home when `FM_HOME` is unset. |
| Operational home | Private `state/`, `data/`, `config/`, and `projects/` | Selected by `FM_HOME`. |
| Projects directory | Local project clones | Under the operational home; `FM_PROJECTS_OVERRIDE` can select a different directory for tests and specialized harness setup. |

When `FM_HOME` is unset, most scripts use the repo root as the home.
When it is set, scripts still run from this repo's `bin/`, while `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.

### Root and directory overrides

`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.

Normal `bin/fm-send.sh` sends require `FM_HOME` to be set before resolving a
target, but
`bin/fm-send.sh --help` prints its usage without resolving a target or requiring
`FM_HOME`.
Normal sends do not use the general fallback, because a steer must not silently
resolve against the wrong home.
These variables override individual operational directories for tests and specialized harness setup:

| Variable | Directory selected |
| --- | --- |
| `FM_STATE_OVERRIDE` | Runtime state |
| `FM_DATA_OVERRIDE` | Durable private records |
| `FM_PROJECTS_OVERRIDE` | Local project clones |
| `FM_CONFIG_OVERRIDE` | Local configuration |

### Relative paths and lifecycle safety

Before `fm-brief.sh`, `fm-spawn.sh`, or `fm-afk-launch.sh` saves a path or passes it to another process, it handles each applicable `FM_HOME`, `FM_STATE_OVERRIDE`, or `FM_DATA_OVERRIDE` directory as follows:

- Resolve relative directories against the caller's working directory.
- Preserve accepted absolute spellings unchanged.
- Reject an unresolvable relative directory and name the offending variable.

`fm-spawn.sh` additionally rejects control bytes in those raw directory inputs before shell or filesystem normalization can change which path the backlog gate checks.
Lifecycle access to a backlog, task record, or pending-close record must resolve within its configured data or state root, and a final-component symlink is refused even when its target remains within that root.

Bootstrap applies the same relative `FM_HOME` resolution only when embedding that home in the generated Relay poll shim.
`fm-contributions.sh arm` resolves a relative `FM_CONFIG_OVERRIDE` against the caller's working directory and embeds the resulting absolute config directory in its generated check, so later watcher polls keep the same review-bot policy.
Other transient consumers retain their existing shell-relative behavior.

### Backend labels and containers

| Backend | Effect of the operational home |
| --- | --- |
| herdr | `FM_HOME` determines the adapter's workspace label. |
| zellij | `FM_HOME` determines the readable home prefix in visible tab titles, but does not split containers; use `FM_ZELLIJ_SESSION` for a separate session; the full home label also includes a short hash of the resolved `FM_ROOT` path. |
| cmux | `FM_HOME` determines the default config path and readable home prefix in workspace titles; `FM_CONFIG_OVERRIDE` overrides where `config/cmux-socket-password` is read; the full home label also includes a short hash of the resolved `FM_ROOT` path; there is no per-home container split. |
| tern | `FM_HOME` determines the readable home prefix used with the shared home-tag session label (via `bin/fm-backend-hometag-lib.sh`); the full home label also includes a short hash of the resolved `FM_ROOT` path. |
| hc | `FM_HOME` determines the home tag in each task terminal's `firstmate.home` label and the default Herdr.app space (via `bin/fm-backend-hometag-lib.sh`); `HC_SESSION` selects the core. |

`fm-spawn.sh` explicitly sets `FM_HOME` in the worker's environment on launch and relaunch, because a pane-owning daemon may not inherit the spawning process's current environment.
Ship and scout workers receive the spawning process's resolved active home, including when `FM_HOME` is supplied only for that invocation; secondmates receive their own operational home.

## Operational home layout and state

This section is the single owner of the top-level operational-home layout.
Producer script headers and their help own exact child-file fields and mutation contracts.
The tracked code root contains shared instructions, skills, documentation, workflows, and `bin/`.
Each effective `FM_HOME` contains private operational directories.

`data/` holds durable private fleet records:

- Project and secondmate registries.
- Captain preferences and optional shared captain preferences.
- Learnings, backlog, briefs, scout reports, optional task status archives, and the optional per-task no-mistakes pipeline-spend ledger.
- The standing-commitments register in `data/standing-commitments.json` (`{"version":1,"rows":[...]}`): one row per "from now on", "every time" or "standing" promise a home makes about its own behaviour, with Lee's words, a typed enforcement point and a typed read-only verification; `bin/fm-commitment.sh` owns the row fields and spec grammar, and the page-check officer evaluates every unretired row of every home it reads.
- Worker complaints in `data/agent-complaints.jsonl`, one JSON line per `bin/fm-complain.sh` call (`bin/fm-complain.sh` owns the fields); the friction officer reads it from each scanned home.
- Explicitly installed content-addressed extension packages under `data/extensions/packages/`.

`state/` holds runtime records:

- Task metadata, append-only status events, and endpoint signals.
- Watcher and wake-queue coordination, away-mode state, and generated Relay artifacts.
- Inactive terminal-outcome receipts under `state/terminal-outcomes/`.
- Enabled extension working namespaces under `state/extensions/`.
- Parent-side remote ledger copies under `state/secondmate-summary-cache/`, refreshed by the fleet snapshot and, every `FM_REMOTE_SUMMARY_INTERVAL_SECS`, by the watcher's remote-summary refresh (`bin/fm-fleet-snapshot.sh --remote-summary-refresh`).
- One-shot Bearings reconcile requests under `state/reconcile-notify/`.
- Private secondmate config-reread generations with their retry and quarantine state.
- Per-task steering-inbox records under `state/<id>.inbox/` (`bin/fm-task-inbox-lib.sh`).
- Parent-owned secondmate pending-reply records under `state/pending-replies/` (`bin/fm-pending-reply-lib.sh`).
- Verified gzip archives of aged process-event sequences and settled pending-reply records under `state/archive/` (`bin/fm-retention.sh`, which the watcher runs once a day).

`config/` holds local gitignored operating choices, including explicit extension bindings under `config/extensions.d/`.

`projects/` holds local project clones.
Firstmate reads these clones, but changes them only through the narrow guarded and concrete captain-approved exceptions in `AGENTS.md`.
Untracked files and directories whose names begin with `scratchpad` are also gitignored, so temporary scratch does not make porcelain-based secondmate sync guards treat a home as dirty.

### Format and lifecycle references

- `bin/fm-spawn.sh` owns the base task-metadata fields it emits, while the runtime-backend section below owns backend-specific fields and selector interpretation.

- [`bin/fm-contributions.sh`](../../bin/fm-contributions.sh) owns durable published-contribution records under each task, observation bounds, equivalent triage-label configuration, the [review-bot setting above](prs-and-pipeline.md#contribution-review-bots-configcontribution-review-bots), the opt-in `FM_CONTRIBUTIONS_REPLY_AGE` setting (seconds, unset by default) that turns on re-raising unanswered review threads after that age, and the authenticated contribution check.

- The producing PR and Relay helpers own the fields they append, [`bin/fm-classify-lib.sh`](../../bin/fm-classify-lib.sh) owns status-event vocabulary, optional emission-time syntax, and legacy unknown-time handling, and `bin/fm-crew-state.sh` owns current-state reconciliation.

- The [`bin/fm-fleet-snapshot.sh` header](../../bin/fm-fleet-snapshot.sh) owns the snapshot's event-time and age fields, including secondmate parent-event projections.

- Wake, watcher, away-mode, and Relay-specific state mechanics remain with their named scripts and reference sections rather than being duplicated into one exhaustive state tree here.

### Session-start references

- `bin/fm-session-start.sh`'s header is the single owner of session-start ordering, composed commands, digest contents, and the digest's startup mechanism.

- `bin/fm-startup-network.sh`'s header owns the deferred startup stage that keeps every external-network call and the potentially slow inactive-outcome scan off that digest's blocking path, including its state files and the safety argument for running them later.

- `docs/sessionstart-nudge.md` owns the native session-open adapter tiers that run or nudge the digest command, and the source routing between them.

- `AGENTS.md` retains the run-once and read-once operator rules, lock-refusal safety, installation consent, and direct-report recovery boundaries because those facts apply at every session start.

- Ordinary dead-direct-report recovery is owned by `stuck-crewmate-recovery`, while persistent-secondmate recovery is owned by `secondmate-provisioning`.

## Trace context propagation (config/trace-context / FM_TRACE_CONTEXT)

The optional local, gitignored `config/trace-context` presence flag enables default-off native W3C trace-context propagation.

### Precedence and session boundary

`FM_TRACE_CONTEXT` overrides the file: `1`/`on`/`true`/`yes` enables, any other non-empty value disables, and unset or empty defers to the file.
Each locked home session resolves those inputs once, and all spawns from that home use the frozen decision until a new session starts.

### Secondmate propagation

When launching a Secondmate, the primary copies the presence flag into its home and passes the primary session's frozen decision as a non-empty `FM_TRACE_CONTEXT=on|off` override for the Secondmate's own session start.
A Secondmate on a remote route is covered the same way: the primary resolves and records that task's carrier, and the configured host exports it and receives the same enablement snapshot.

The presence flag is session-scoped enablement, so it transfers at launch and is left unchanged by live convergence into a running home.
See [`trace-context.md`](../trace-context.md) for carrier semantics, supported routes, the manual fleet-restart requirement, the session boundary, and safety limits; `bin/fm-trace-context-lib.sh`'s header owns the exact mechanics, and [`verification/trace-context.md`](../verification/trace-context.md) records repeatable evidence.

## Fleet activity ledger (config/fleet-ledger)

See [`fleet-ledger.md`](../fleet-ledger.md) for the opt-in setup, record contract, and limits.

## Firstmate role (config/firstmate-role)

The optional local, gitignored `config/firstmate-role` declares this home's relationship to the firstmate repository itself.
Every home defaults to **user/operator** with no firstmate-upstream publication authority: ordinary project work and `/updatefirstmate` pulls are unaffected, but without an explicit grant no ship task on the firstmate repository may carry a publishing contract.
For the agent's local diagnosis, workaround, and draft-only response to a firstmate bug, see [`firstmate-self-repo`](../../.agents/skills/firstmate-self-repo/SKILL.md#when-a-firstmate-bug-surfaces-in-ordinary-use).

The file holds exactly one directive line, with blank lines and `#` comment lines ignored:

| Directive | Effect |
| --- | --- |
| `user` | The default; identical to an absent file. |
| `maintainer <host>/<owner>/<repo>` | This home may dispatch publishing work that targets the one named firstmate upstream. |

A scope names the publication target repository (where a pull request lands), normalized to lowercase for comparison, not a push destination.
A fork maintainer contributing to the parent repository uses per-task consent rather than a second standing scope.
Write the primary home's file by hand; firstmate never grants itself a role, and the file never travels through git.
Supported secondmate propagation writes or removes the inherited copy as described below.
A malformed, unreadable, or symlinked file - including one with a second directive anywhere - resolves to user/operator; the role fails closed rather than guessing.

Authority is also available for one task at a time: `--upstream-consent <host>/<owner>/<repo>` on `bin/fm-brief.sh`, `bin/fm-spawn.sh`, and `bin/fm-promote.sh` records the captain's explicit approval in the task's delivery contract and metadata without changing the home's role.
Role is never inferred from GitHub identity, forge permissions, remotes, repository ownership, authentication state, environment, or CI.
`bin/fm-role.sh report` prints the resolved role with no network call, and the session-start digest shows it in the HOME ROLE subsection.

`bin/fm-role-lib.sh` owns the fail-closed parser, self-repository detection, and the gate that `bin/fm-brief.sh`, `bin/fm-spawn.sh`, and `bin/fm-promote.sh` apply.
The publication target is selected from the first configured remote whose `remote.<name>.gh-resolved` value is exactly `base`, including custom remote names, otherwise from the first configured remote in the order `upstream`, `github`, `origin`; selection is offline, and `bin/fm-role-lib.sh` owns URL and local-path normalization.
An unreadable or URL-less marked remote is not replaced by a fallback remote, and an undeterminable target never authorizes a task, even under task consent.
A task's project counts as the firstmate repository when it shares the code root's lineage - the same git common dir, or a root commit of the code root's history, which every fork, the parent, and any clone of either share - computed offline; undeterminable lineage (for example a shallow clone sharing no root commit) is refused, even under task consent.
Secondmate homes inherit the primary's resolved role, never its raw file: a primary file that resolves to user for any reason propagates as revocation.
In a secondmate home the file is honored only while the inheritance receipt `config/.fm-inherit-firstmate-role.generation` proves the exact bytes the primary last published (`bin/fm-config-inherit-lib.sh`); a role file with no matching receipt or a stale grant authorizes nothing.
The receipt prevents accidental publication through supported paths; it proves consistency, not provenance, and is not a security boundary against a process that deliberately forges local records.

## Treehouse pool report (config/treehouse-pool-report)

The optional local, gitignored `config/treehouse-pool-report` presence flag opts this home into a read-only Treehouse pool hygiene report at bootstrap.
With the flag present and the Treehouse state directory and `jq` available, bootstrap prints `TREEHOUSE_POOL_REPORT:` findings, covering the default pools and each local secondmate home's own pools under `fm-secondmate/`, for pools with unavailable project paths, unowned slots older than `FM_POOL_ORPHAN_DAYS`, duplicate-origin project clones (a secondmate home's own pool is never counted as a duplicate), and `project-*` or `scratch-project-*` pools without an active owner or lease; the `treehouse` executable is not required.
The report never changes a pool or slot; pruning or other pool cleanup remains an explicit operator action.
With the file absent, bootstrap reads no Treehouse state and prints no pool report.
Only the file's presence is read, at each bootstrap run.
The flag is a home-local preference and is not inherited by secondmate homes.

## Task status archive (config/status-archive)

The optional local, gitignored `config/status-archive` presence flag opts this home into retaining task status history during teardown.
Create it with `touch "$FM_HOME/config/status-archive"`; remove it to disable future archival and pruning.
It is off by default: without the flag, teardown deletes status logs as before and leaves existing archives untouched.
The flag applies to teardown run by this home, including forced retirement of its secondmate children; it is not inherited by other homes.
Each opted-in archival prunes owned logs older than 30 completed days by mtime; housekeeping failures warn and never abort teardown.
Age-based retention works independently of the selected backlog backend and keeps histories available for a predictable audit period.
[`architecture.md`](../architecture.md#task-status-archives) describes archive locations and isolation from live state; [`bin/fm-teardown.sh`](../../bin/fm-teardown.sh) owns the mechanics.

## Record hygiene report (config/record-hygiene)

The optional local, gitignored `config/record-hygiene` presence flag opts this home into reporting its own inconsistent task records.
Create it with `touch "$FM_HOME/config/record-hygiene"`; remove it to stop the report.
With the flag present, session-start bootstrap prints a `RECORD_HYGIENE:` line for each inconsistency, and the watcher heartbeat runs the scan in the background and raises one `check: record hygiene:` notification when its findings change.
It is off by default: without the flag, session start and the heartbeat print no report, move no files, and perform no record-hygiene reads.
The flag takes effect at the next session start or heartbeat, and is a home-local preference that is not inherited by secondmate homes.
[`architecture.md`](../architecture.md#task-status-archives) owns scan scope and status-log archiving; [`bin/fm-record-hygiene-lib.sh`](../../bin/fm-record-hygiene-lib.sh) owns the mechanics.

## Record export (config/record-export-root)

The optional local, gitignored `config/record-export-root` file contains exactly one absolute directory path and opts this home into a private copy of a fixed record allowlist.
The setting is off by default and is not inherited by secondmate homes.
When the file is absent, sync exits without export work, teardown follows its existing path, and spawn, watcher, presentation, classification, and snapshot readers remain unaware of exports.
When the file is present, `python3` is required and an unreadable config directory or file is a hard failure rather than an opt-out.

The configured path must name a dedicated root outside and disjoint from the effective home, config, data, and state trees.
Its parent must already exist, while the final root may be absent so the exporter can create it.
An existing root is accepted only when its strict versioned ownership marker names this canonical home, so one root cannot serve multiple homes.
The exporter refuses an unmarked pre-existing directory, an owner mismatch, unknown managed artifacts, or unsafe object types instead of changing a broad or shared directory.
Exporter-owned directories use mode `0750`, and exported files use mode `0640`.

Run `bin/fm-record-export.sh sync` to publish the currently present allowlisted files through `<export-root>/live/`:

```text
data/{projects.md,backlog.md,done-archive.md}
data/<task>/{brief.md,report.md,status*.log}
state/fleet-ledger.jsonl
state/<task>.{meta,status}
state/<task>.inbox/{,handled/}NNN.msg
```

Sync skips hidden names in `state/`, such as `.startup-network.status`, because they are Firstmate records rather than task records.
The command is one-shot and starts no network transfer, daemon, timer, or watcher.
It does not recursively copy `data/` or `state/`, accept arbitrary sources, discover secrets, or redact content.
The exporter opens source and destination components relative to verified directory descriptors with no-follow semantics, then rechecks source identity and content before publication.
Sync builds a complete immutable generation, flushes its files and directories, and atomically replaces `live` with a relative symlink to that generation.
Consumers that need one consistent snapshot resolve `live` once and read that immutable generation rather than resolving the pointer separately for each file.
Superseded live generations remain selectable for 30 completed days before a later sync removes them.
The published generation is exact, so a later sync retracts allowlisted files that are no longer live and represents a pending-to-handled message move only at its current path.

Enabled teardown commits metadata, the live status when present, and pending and handled inbox messages under `<export-root>/archive/<task>/<spawn_gen>/` before those source records are retired.
Direct archive calls acquire the task metadata lock, while teardown calls under the same lock it already holds, so the exact source set is re-enumerated immediately before commit.
Each attempt builds a fresh sibling staging directory, flushes every copied file, directory, and manifest, and publishes the complete generation with one descriptor-relative rename.
`manifest.v1.json` carries the version, capture time, completeness, source-relative names, byte counts, and SHA-256 values.
Retries parse that JSON with duplicate-key rejection, require the exact v1 fields and types, and verify a one-to-one mapping between manifest entries and archived regular files.
A reused task ID writes its distinct `spawn_gen` rather than overwriting an earlier generation.
Only strictly valid committed generations older than 30 completed days are pruned by manifest mtime, matching task status archive retention, and scan failures warn without undoing a successful capture.
If the archive cannot commit, teardown reports the reason and stops before deleting metadata, status, or inbox sources.
Removing `config/record-export-root` is the explicit escape hatch back to ordinary teardown behavior.

Briefs and handled inbox messages carry captain text, and every exported record can contain other sensitive operational data.
Keep the export root private and never serve it directly.
The schema is versioned for compatible readers, but it is not a Firstmate command API and no Firstmate reader consumes it.
[`architecture.md`](../architecture.md#read-only-record-exports) describes the mechanism boundary; [`bin/fm-record-export.sh`](../../bin/fm-record-export.sh) owns the exact allowlist, schema, path checks, publication, and retention mechanics.

## Captain Preferences (data/captain.md / data/captain-shared.md)

Domain-local preferences for one captain's fleet live locally in each home's `data/captain.md`; it is gitignored and printed in the session-start context digest after `data/projects.md` and optional `data/secondmates.md`.
Before changing it, inspect the current file and curate the matching bullet in place under the internal [`stow` skill's](../../.agents/skills/stow/SKILL.md) tiering and archive contract; add a new bullet only for a genuinely new durable preference.

Shared captain preferences that apply across secondmate domains live only in the primary home's optional `data/captain-shared.md`.
`secondmate-provisioning` owns its propagation contract, including the required header, read-only secondmate copies, quarantine diagnostics, and the rollout rule that existing homes trim `data/captain.md` by hand after first propagation rather than deleting private content automatically.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and printed after the captain-preference files in the session-start context digest.
The file is created lazily on first learning and follows the internal [`stow` skill's](../../.agents/skills/stow/SKILL.md) aging-tier and cold-archive contract: inspect the current file first and curate it instead of appending forever.

There is no shared learnings file by captain decision.

## External memory tiers (Memory layering section)

A home may declare memory stores outside firstmate, such as MCP-served knowledge stores, as authoritative for named classes of knowledge.
The declaration lives in a `Memory layering` heading inside `data/captain.md`, or inside the primary home's `data/captain-shared.md` when every secondmate home should inherit it; a local `data/captain.md` declaration wins for that home when both exist.
No declaration means firstmate's local files under `data/` are the only memory owners, which is the default.

Each declared tier states, in plain prose or a table:

- its destination, named precisely enough for an agent to reach it, such as a connector's tool-name prefix;
- the knowledge classes it is authoritative for, such as decisions and corrections, or people and references;
- its correction rule, such as append-only supersession instead of edit or delete;
- any capture etiquette, such as capture first and report what was captured.

For example, one home declares a Palimpsest MCP store authoritative for reasoning continuity (decisions, hypotheses, corrections), an OpenBrain MCP store authoritative for retrievable facts (people, projects, references), and its own `data/` as a disposable per-machine cache; those stores are that home's choice, not a template default.

The declaration is per-home untracked state under `data/`, like every other captain preference, so no clone or update carries it.
A fresh primary home has no declaration until the captain re-declares the `Memory layering` section there from their own records.
Until then local files are the only memory owners.

[`AGENTS.md`](../../AGENTS.md) section 6 owns what a declaration changes about knowledge routing, and the internal [`stow` skill](../../.agents/skills/stow/SKILL.md) owns how curation reads the declaration and protects tier-owned entries from pruning.
The section counts toward the startup memory budget like the rest of its file, so keep it to the mapping rather than restating these rules.

## Startup memory budget (config/startup-memory-budget)

`config/startup-memory-budget` is the primary-authoritative per-home allowance for the startup prompt-memory surface: `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md` together.
The locked mutable bootstrap path materializes its visible default of `7500` estimated tokens in a primary home when the file is absent.

### Set and validate the budget

To select another allowance, replace the primary home's file with one valid positive value in the exact format below; the next locked bootstrap convergence or `bin/fm-config-push.sh` propagates it to registered secondmates.
A secondmate does not create an independent default and instead receives the primary value through the inherited-local-material contract in [`secondmate-provisioning`](../../.agents/skills/secondmate-provisioning/SKILL.md).

The file must be one positive base-10 integer followed by exactly one newline in a regular, single-linked file beneath a non-symlinked `config/` directory.
Malformed, multi-line, symlinked, hardlinked, special, or otherwise unsafe values are rejected rather than treated as a default.

### Accounting and curation

Use `bin/fm-startup-memory-budget.sh read` to validate and print the effective value, or `bin/fm-startup-memory-budget.sh report` to account for the three files.
The stable local estimate is `ceil(UTF-8 bytes / 3)` per file, a conservative portable approximation rather than a provider-exact tokenizer.

An inherited `data/captain-shared.md` counts in a secondmate's total but remains primary-owned and read-only there.
The internal [`/stow` skill](../../.agents/skills/stow/SKILL.md) owns curation and its automatic secondmate cascade, which accounts every home against this same per-home allowance separately rather than against a fleet total.

The helper's header owns exact parsing, publication, and report output mechanics.

### Daily startup growth check

A home can arm a lightweight daily growth monitor with `bin/fm-startup-growth-check.sh arm`.
It writes `state/startup-growth.check.sh` and binds it through the existing authenticated watcher-check mechanism, so no extra daemon or scheduler is installed.
Registering it is a reason to watch on the same terms as the [watched-tool check](tools.md#watched-tool-updates-configwatched-toolsjson), so an armed home keeps needing a watcher after its last task is torn down.
Use `bin/fm-startup-growth-check.sh disarm` to remove the check and its local report record.

The check evaluates at most once per day and stays silent when nothing meaningful changed.
A due evaluation uses file metadata and byte sizes before any content inspection: it asks `bin/fm-startup-memory-budget.sh report` for the budget verdict over `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`, watches the `data/projects.md` and `data/secondmates.md` that session start also prints in full for growth without entering that budget total, and separately watches the tracked startup/instruction owner files described by the script header.
`bin/fm-startup-memory-budget.sh` remains the sole owner of the budget total and its verdict, so the check never re-derives either: when that owner annotates an overrun caused by the primary-owned `data/captain-shared.md` alone, a secondmate home is not woken about an overrun it cannot act on.
A secondmate home is likewise not notified about per-file growth of that same primary-owned `data/captain-shared.md`, which it receives read-only; the growth is still observed and recorded, and a primary home reports it normally.
Those tracked bytes are code and instruction-surface size, not prompt-memory cost.
The check does not run session-start, bootstrap, network checks, model calls, repository refreshes, `/stow`, or full preference/learnings rereads.

Growth is measured against a per-file baseline retained in the check's own state record, so accumulation that stays under one day's threshold is still caught once it adds up; reporting a file rebases its baseline to the reported size, so accepted growth then stays silent.
A surface observed for the first time is baselined silently, including the first content of an optional file that did not exist yet when the check was armed, and an established baseline survives that file disappearing and coming back.
The fixed growth thresholds are inspectable in the script header: 2048 bytes for tracked startup/instruction files and 250 estimated tokens for the printed startup-memory files.
Budget overrun, unsafe or unreadable inputs, missing required tracked owner files, or material growth are reported once and deduplicated until the finding changes or clears; the report line is delivered before the check advances its own record, so a state-publication failure can repeat a finding but never swallow one.
That one line goes out through the shared per-line digest cut, so an over-long finding set carries the repo's `[truncated]` marker instead of ending mid-finding, while deduplication keeps comparing the full uncapped set.
Older bulk learning files remain reference-only; this monitor neither loads nor merges them.
A reported review need is only a recommendation, not cleanup authority.

## Stow pass horizon (config/stow-pass-horizon)

`config/stow-pass-horizon` is an optional local, gitignored presence flag that opts this home in to the pass-count decay horizon in the internal [`/stow` skill](../../.agents/skills/stow/SKILL.md).
Without it a `/stow` pass decays memory entries on their wall-clock horizons alone - 30 days for `aging`, 7 days for `perishable` - which is the default and unchanged behavior.

With it, an entry is also stale after 10 passes (`aging`) or 3 passes (`perishable`) that evaluated it without reinforcing it, whichever horizon it reaches first.
Opt in for a home that stows often enough that entries never sit unreinforced for a wall-clock horizon, so memory only grows against the startup-memory budget above; a home that stows rarely already exceeds its date horizon on a single pass and gains nothing.

The flag is per home and is not inherited by secondmate homes, because stow cadence is a property of the home doing the stowing.
Only the file's presence is read, so its contents are ignored; remove it to return to the default contract on the next pass.

The skill text owns the marker spelling, the tick order, and the reinforcement rule.

## Stow guard (config/stow-guard)

`config/stow-guard` is an optional local, gitignored file that asks a Claude primary to run `/stow` while there is still room before context compaction.
Without the file the session is unchanged.

With the file present, the Claude Stop hook `bin/fm-stow-guard.sh` blocks one turn end and tells that session to run the existing `/stow` skill.
It asks when the newest context reading in the transcript tail is at least `tokens` (default 300000), once per crossing, and again only after a later reading falls below two-thirds of that line.
It also asks when the newest `/stow` it has seen is at least `hours` old (default 24), and then not again for an hour.
That age ask is skipped when a `/stow` timestamp cannot be read.
The stored state is what makes each ask once per crossing, so a continuation stop is handled like any other stop.
A hook error does not block the turn, and the hook never compacts the session itself.
It runs for a plain Claude primary checkout of this home.
It stays silent in a crew worktree and in a marked secondmate home, because a Stop block there leaves the parent recording that mate as idle while it is still working.
The file is per home and is not inherited.
Blank lines and lines that start with `#` are ignored.
Optional lines are `tokens=<n>` and `hours=<n>`.
An unusable value keeps its default.
Remove the file to turn the ask off.
The script header owns the transcript read, the state file, and the block message.

## Self-update source (config/self-update-source)

The optional local, gitignored `config/self-update-source` changes where `/updatefirstmate` takes the running firstmate from, and nothing else.
It suits a home that runs its own fixes before upstream merges them, by following a branch that holds upstream's default branch plus those fixes, for example a `carry` branch on a fork.
It holds one line, `<remote> <branch>`, for example `fork carry`, naming a remote that already exists in this repository and a branch on that remote.
When the file is absent, `/updatefirstmate` fast-forwards from `origin` exactly as before.

When it is present, [`bin/fm-update.sh`](../../bin/fm-update.sh) fetches only that branch and fast-forwards the primary to it under the same guards as the origin path: a dirty, off-default, or diverged primary is skipped and left untouched, so the named branch must only ever move forward.
Local secondmate homes then advance to the primary's resulting default-branch commit, the same commit the startup secondmate sync follows, and a standalone-clone home that lacks that commit imports it from the primary first.
A remote secondmate's host runs its own update against its own code root, so a remote home follows the named branch only when that code root has the same file; otherwise it keeps following its own origin.
Worker spawns, review diffs, the cleanup landed-work test, lint, and default-branch detection keep using `origin`, so work started in this home still branches from, and is judged against, upstream.
An unreadable or malformed file, an unknown remote, or an invalid branch name stops the whole update before anything moves and names the file; it never falls back to `origin`.
The file is per home and is not inherited by secondmate homes.
To stop following the branch, remove the file; a primary already ahead of `origin` is then reported as diverged until it is brought back by hand.
The script's header owns the exact parsing and the per-home outcome lines.
