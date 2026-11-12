# Secondmates and offices

Part of the [configuration reference](../configuration.md).

## Offices (data/offices.md)

An office is a second mate that runs a standing role mandate instead of idling.
`bin/fm-office.sh`'s header owns the mechanics; this section owns the registry schema.
Offices live in the primary home's `data/offices.md`, one line per office, in the same line family as [Officers](officers.md#officers-dataofficersmd), whose grammar `bin/fm-registry-line-lib.sh` owns:

```text
- <id> - <one-sentence mandate> (role: <role>; runs-on: <hosts>; dispatch: <projects>; merge: none | <projects>; merge-via: none | <project>=<home>,...; auto-merge-classes: none; wip: 1-9; tick: every Nh; sources: <sources>; added YYYY-MM-DD)
```

| Field | Meaning |
| --- | --- |
| `<id>` | The id of a second mate registered in `data/secondmates.md`; the office's home is that mate's home |
| `role` | `navigator`, `quartermaster`, `alchemist` or `librarian`; any other role name is refused |
| `runs-on` | Comma-separated hosts; the second mate's `host:` (or this host, for a local route) must be in it, and `macbook` is refused |
| `dispatch` | Comma-separated project names; each must be listed in the office home's `data/projects.md` |
| `merge` | `none`, or the projects the office merges: a subset of `dispatch`, each carrying `admission=<name>` in the office home's `data/projects.md` |
| `merge-via` | `<project>=<home>` pairs for projects another home merges: a subset of `dispatch`, disjoint from `merge`, each carrying `merger=<home>` in the office home's `data/projects.md` |
| `auto-merge-classes` | Must be `none`; no class auto-merges yet |
| `wip` | The most live tasks the office may run at once, 1 to 9; a landing task, a ship whose ready PR is handed to another home's merger with nothing left open, holds no place, while [project capacity](../configuration.md#project-capacity-configproject-capacity) and [landing lag](projects-and-forges.md#landing-lag-dataprojectsmd-landing-lag-token) still bound every spawn (`bin/fm-office-authority-lib.sh` owns the definition) |
| `tick` | `every Nh` (N from 1 to 24) |
| `sources` | Comma-separated `tick`, `upstream`, `ratchet`, `research`, `lane:<officer-id>` or `lane:<officer-id>:high`; each officer id must be listed in `data/officers.md` |

Each source is a watcher check in the office home's own `state/`, so it wakes the office and never main.
`bin/fm-office.sh register-sources`, run in the office home, installs and trusts one `state/office-<source>.check.sh` per listed source, and `bin/fm-office.sh check <source>` is its body; the script's header owns what each prints and when it stays silent.
`tick` fires once per slot of the office's `tick` cadence when a place under `wip` is free and work could start; `lane:<officer-id>` fires once per new digest of that officer in the parent home (on a remote office, in the copy the parent pushed); `lane:<officer-id>:high` fires only for findings the digest's `.json` marks high or critical; either also delivers a progress, surgeon, friction, corpus or library digest's start requests addressed to the office (see [Progress officer](officers-progress.md#progress-officer), [Surgeon](officers.md#surgeon), the friction officer's started-by-default findings above, the [Corpus officer](officers.md#corpus-officer) and the [Library officer](officers.md#library-officer)).
`upstream` is the daily check for new commits on the firstmate upstream: the optional local `config/firstmate-upstream` holds one line, `<remote-or-url> [<branch>] [<fork-ref>]` (branch defaults to `main`, fork-ref to `origin/main`), and the source wakes the office once per new upstream head with the commit count, the merge-base..head range and the newest subjects; it is silent when the fork already has everything, when the file is absent, and on a transient fetch failure (a failure lasting 24 hours is reported once).
It is the one source that contacts another host, and `bin/fm-office.sh` owns its attempt cadence and records.
The check only wakes the office; the sync itself is ordinary dispatched work.
`ratchet` is the daily clock of firstmate's lint ratchet: once per UTC day, while `bin/fm-lint-ratchet.exceptions` in the office's code root still lists a file, it wakes the office with the next file (`bin/fm-lint-ratchet.sh next`) and the count left, and it is silent when the list is empty; [Office provisioning](../office-provisioning.md) step 10 lists it on the Quartermaster's line.
While a ratchet PR for that file is still open the office skips the day; otherwise it dispatches one ordinary ship worker for that file, which fixes it until `bin/fm-lint-ratchet.sh check <file>` passes, retires it with `bin/fm-lint-ratchet.sh retire <file>`, and opens one pull request.
On the Quartermaster's line only, the `tick` check also runs `bin/fm-session-weight.sh`, which wakes the office at most once per UTC day with one line when a `claude` or `codex` process is older than 24 hours or on a retired model (default pattern `claude-opus-4`, overridable in the local `config/session-weight-retired`); it infers context from account-level request sizes, never per session, and never signals a process (its header owns the details).

`research` is the weekly tooling-research lane: once per complete run directory under `config/tooling-research-runs` (default the Slarti home's `data/tooling-research/runs`) it appends the run's "Lines for knowledge.md" to `config/tooling-research-knowledge` (default `data/tooling-research/knowledge.md`) and writes a digest of the run's proposals, with once a week the adopted-or-not follow-through of the `data/*/report.md` reports of the main and office homes.
It leaves out the run's bookmark copy, delivers none of the runs already present when it first runs, lists any line it could not place in the digest, and reports a helper failure once failures span an hour.
It starts and files nothing, and a malformed `suggestions.json` is reported rather than guessed; `bin/fm-office.sh` owns the wake line and `bin/fm-office-research.py` the mechanics and records; [Office provisioning](../office-provisioning.md) step 11 lists it on the Quartermaster's line.

A local office home also carries a `.fm-office` marker holding the office id and a `data/charter.md` with a `# Office authority` heading.
`bin/fm-brief.sh <id> --secondmate --office <id>` writes that role charter, a standing mandate that replaces the second mate's idle-by-default clauses, and `bin/fm-home-seed.sh ... --office <id>` seeds the home with the marker, the merge tokens and admission copies its line needs, and its source checks; each script's header owns its checks and refusals, and the `office-roles` skill owns each role's mandate.
[Office provisioning](../office-provisioning.md) gives the ordered steps that create the offices.
`bin/fm-office.sh list` prints each office and its gap count.
Session start runs `bin/fm-office.sh ensure`, which prints one `OFFICE:` line per gap and nothing when the registry and the homes agree.
It also prints one `OFFICE: pool:` line when clones of one project (same origin URL) under `~/fm-homes` differ on `max_trees` in their untracked `treehouse.toml`, because treehouse shares one pool directory per project but counts it against each clone's own cap.
When the seed (`bin/fm-home-seed.sh`, or `bin/fm-remote-home-provision.sh` on a remote host) clones a project and a peer clone on the host already has a `treehouse.toml`, it copies that file in, taking the largest `max_trees` and the other keys from the first peer found, and never overwrites an existing one; it also lists `/treehouse.toml` in the new clone's `.git/info/exclude` so the copy never makes the clone read as dirty to fleet sync (`bin/fm-treehouse-toml-lib.sh`; `FM_TREEHOUSE_PEER_ROOTS` overrides the default `~/fm-homes` search root).
An absent `data/offices.md` means no offices.
In a primary home (it keeps `data/offices.md` and has no `.fm-secondmate-home` or `.fm-office` marker), `ensure` also prints `OFFICE: approved office <role> not provisioned` for every role in `FM_OFFICE_ROLES` (`bin/fm-office-authority-lib.sh`) that has neither a `data/offices.md` line nor a valid deferral; the watcher repeats that as a `check: office-provisioning` wake at most once a day until it is gone.
`bin/fm-office.sh unprovisioned` runs that check alone against the home `FM_HOME` names, so pointing it at a scratch copy of a primary home shows the alarm for a role missing from that copy's `data/offices.md`.
`list` and `ensure` only read: they seed, publish, spawn and grant nothing.

### Office deferrals (data/office-deferrals.md)

A deferral records that the captain chose not to build an approved office yet.
It is one line per role in the registry line family:

```text
- <role> - "<the captain's quoted words>" (said: <where and when>; until: YYYY-MM-DD; added YYYY-MM-DD)
```

`<role>` must be a known office role, the words must be quoted, and `said` is required; `until` is optional and the deferral holds through that UTC date, after which the alarm returns.
The fields must not contain parentheses, because the line's last ` (` opens them; write a relay citation as `said: main chat, relayed by main, corr <id>`, and a line with parentheses inside its fields is reported with that cause.
A malformed or expired line is reported as `OFFICE: deferral <role> ... defers nothing` and never silences the alarm.

An office acts only inside the authority record the main home publishes into it as `config/office-authority`, proven by the receipt `config/.fm-inherit-office-authority.generation`; `bin/fm-office-authority-lib.sh`'s header owns the record grammar, the receipt rule, the admission digest, and which home receives which record.
The main home builds each destination's record from that destination's own line, so every other second mate receives an absence and a plain second mate gains no file; every inheritance push (a second-mate spawn, the bootstrap sweep, `bin/fm-config-push.sh`) publishes it, and `bin/fm-office.sh publish <id>` publishes one local office's record now.
The record pins each merge project's admission config from the main home's master copy in `config/admission/`, so republishing never blesses an edit made in the office home.
In an office home, `bin/fm-spawn.sh` and `bin/fm-pr-merge.sh` refuse whatever that record does not cover, and refuse everything when the record is missing or unproven or the home's office signals disagree; their headers own each check.
An office never lands locally: `bin/fm-merge-local.sh` refuses every local landing in an office home, and the parent home lands local-only work.
An office on a remote host (`runs-on` names the second mate's remote `host:`) is seeded by `bin/fm-remote-home-seed.sh --office`, and `bin/fm-office.sh publish <id>` pushes its record and receipt through the remote inherit push.
It cannot read the parent's files, so the same push carries `config/office-feed`, a copy of its own `data/offices.md` line and of each lane officer's digest, `.json` and start requests addressed to it; every source check there reads that copy, and a missing, mismatched or over 36-hour-old copy leaves them silent.
`bin/fm-office-feed-lib.sh` owns the copy's format, and `bin/fm-office.sh`'s header owns when it is sent.
These checks only refuse, and a home that is not an office never runs them.

### Office status (data/office-status.json)

`bin/fm-office.sh status` runs inside an office home and projects that home's own work onto `data/office-status.json`, the file the fleet app's Status page pulls.
It reads only the home's `data/backlog.md`, `data/office-decisions.md` and `state/<task>.meta`, writes only `data/office-status.json` and `state/office-status.seen.json`, prints nothing on success, and does nothing in a home without a `.fm-office` marker.
`bin/fm-office-status.py` owns the mechanics.

```json
{
  "schema_version": 1,
  "office": "navigator",
  "title": "Navigator",
  "written_at": "2026-11-04T10:05:00Z",
  "cards": [
    { "id": "pc-4701-fix", "title": "...", "state": "working", "link": "https://github.com/...", "since": "2026-11-03T00:00:00Z" },
    { "id": "pc-4712", "title": "...", "state": "next", "link": "", "waiting": "Lee" },
    { "id": "pc-4690-fix", "title": "...", "state": "done", "link": "https://github.com/...", "done_at": "2026-11-04T09:40:00Z" }
  ],
  "decisions": [
    { "date": "2026-11-05", "source": "10-article research, rank 8", "finding": "...", "call": "Needs Lee: ...", "action": "Asked Lee, key alert-wakes-agent" }
  ]
}
```

| Lane | Source in the office home | Rule |
| --- | --- | --- |
| `working` | Every `## In flight` item | `link` is the task's `pr=` from its meta record, else the first `https://` URL in the row; `since` is the row's `since` date at 00:00 UTC |
| `next` | The first 10 `## Queued` items, in backlog order | `link` is the first `https://` URL in the row, or empty; `waiting` is `"Lee"` when the row carries `hold-kind: captain`, else empty |
| `done` | `## Done` items first seen done within the last 24 hours | `link` is the first `https://` URL in the row, or empty; `done_at` is the time the status check first saw the item done, not its completion time |

`office` is the `.fm-office` marker and `title` is that id with its first letter capitalized.
`title` on a card is the row text without its trailing `(key: value)` groups and URL, cut to 200 characters.
Cards are ordered working, then next, then done (newest first).

`decisions` lists the findings the office judged important, projected from the home's `data/office-decisions.md`, so they show on the Status page and not only in notes.
That file holds a markdown table with the columns `Date | Source | Finding | Call | Action`; cells split on unescaped `|` only, and `\|` inside a cell reads as `|`; the header, separator and any line that is not a five-cell row with an ISO `YYYY-MM-DD` date and a non-empty finding and call are skipped, and an absent or unreadable file gives an empty list.
Each object carries its five cells as plain text (a link in a cell stays as written), ordered newest date first (rows of the same date newest line first) and capped at 20.
The key was added to schema version 1; readers that ignore unknown keys are unaffected.
Filing a decision stays with the office; this projection only reads the file.

The backlog records only a date (`merged` or `done`) for a finished item, so the check keeps the time it first saw each done item in `state/office-status.seen.json`, a JSON object of item id to UTC time, replaced atomically.
A done card shows while that first-seen time is at most 24 hours old, then leaves, which the page shows as a finished card leaving.
The stamp outlives the card, so a later run never brings an expired card back, even after `data/office-status.json` is deleted; stamps older than 7 days are pruned.
An item with no stamp is stamped and shown only when its recorded date is today or yesterday (UTC); an item dated before yesterday is treated as expired and never stamped, so a missing or corrupt seen file, which is read as empty, cannot bring old items back.

The projection is replaced atomically (temp file in `data/`, then rename).
A run whose cards match the existing file leaves it alone unless its `written_at` is older than `FM_OFFICE_STATUS_REFRESH_SECS` (default 900), so a quiet office still reports in well inside the reader's 30-minute staleness limit.
A failure prints one line to stderr, exits 1 and leaves the previous file in place.
`FM_OFFICE_NOW` pins the clock for tests.

`bin/fm-office.sh arm-status`, run once in the office home, makes `status` that home's silent watcher check.
It writes `state/office-status.check.sh` (mode 0700, a shim that exports the home's absolute path as `FM_HOME` and execs `fm-office.sh status`) and binds it with `bin/fm-check-register.sh office-status`, so every watcher sweep refreshes the file and prints nothing unless the projection fails.
Running it again rewrites the same bytes.
`bin/fm-office.sh disarm-status` retires the check through `bin/fm-check-unregister.sh office-status`.
Both refuse, with one stderr line and exit 1, in a home without a `.fm-office` marker.
