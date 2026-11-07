---
name: officer-roles
description: Load on a `check:` wake from `state/officer-<id>.check.sh`, on any `OFFICER:` session-start line, before adding, registering, or retiring an officer, and before reading or acting on an officer's findings.
user-invocable: false
metadata:
  internal: true
---

# Officer roles

An officer is a role agent owned by the primary home.
It reads fleet records on its own cadence (daily, or every N hours), writes only its findings lane, and reports one line to its first mate.
It never acts on the fleet.
[`docs/configuration.md`](../../../docs/configuration.md) "Officers (data/officers.md)" owns the registry schema, and `bin/fm-officer.sh`'s header owns the mechanics.

## Authority

An officer may:

- read fleet records: this home's and local second mate homes' `state/` status logs, meta, and fleet ledger, `data/<id>/` reports, the backlog, the session archive, GitHub read-only, and, for a friction officer, the Captain's Log cards and tap replies fleet-app serves at `GET /api/captains-log` and `GET /api/captains-log/replies`; a progress officer also reads Linear and registered remote homes read-only; a surgeon officer also reads the fleet app's `GET /api/runs`, each live nightly job's latest result and `GET /api/sweeper-results`; a page-check officer reads each fleet-app page's `GET` endpoint, this home's status logs, the standing rules in `data/captain-shared.md`, and a card's PR state through `gh-axi api GET`, all read-only; a corpus officer reads only the counts, timestamps and names its script returns from each corpus input, over `ssh -o BatchMode=yes` (never a transcript, a corpus row or a harvested memory record); a library officer reads the librarian-audit job's newest `result.json` and `findings.json`;
- write its own lane, `data/officers/<id>/`: dated findings (including the friction officer's velocity file, the progress officer's state and executable start requests, the page-check officer's `state.json`, and the corpus and library officers' `reported.json`, with the corpus officer's `nights.json`), its digest marker, `runs.log`, and its `check-record.*` files;
- print its one report line from its watcher check;
- for a surgeon officer, only when its registry line says `writes: linear`, file Linear items in team PC from nightly runs, bug-sweep results and test runs: `linear-axi` `--dry-run` then `--verify`, at most `max-creates` new items a run (default 100) and `max-linear-calls` calls (default 450), exactly one Type (Bug), one Source and one area label looked up in team PC and derived from the finding, and a `surgeon-fp:<sha256>` fingerprint in the description that it searches for first (then a local-jev duplicate check above 0.85) so a finding is never filed twice; a duplicate raises the item's one `Found:` line and adds at most one comment a day; a failed label lookup reports the finding instead, and one rate-limit answer stops every Linear call in the run; what it may start and what it holds for Lee is `docs/officers/surgeon-rubric.md`;
- for a friction, corpus or library officer, only when its registry line says `writes: linear`, file and update Linear items in team PC under [`docs/officers/contract.md`](../../../docs/officers/contract.md) and its own rubric ([`friction-rubric.md`](../../../docs/officers/friction-rubric.md), [`corpus-rubric.md`](../../../docs/officers/corpus-rubric.md), [`library-rubric.md`](../../../docs/officers/library-rubric.md)): `linear-axi` `--dry-run` then `--verify`, a fingerprint search before every create, a duplicate's one `Found:` line, and at most `max-creates` new items a run (the library officer's run is one audit run, capped at 3; the corpus officer files only counts, names and timestamps, never a transcript, corpus row or memory record); it never closes, deletes or re-prioritises an item a person touched;
- for a progress officer, only when its registry line says `writes: linear`, raise the Linear priority of an item another officer filed (its `<officer-id>-fp:<sha256>` marker) from its score before starting it, through `docs/officers/contract.md` and `docs/officers/progress-rubric.md`: `--dry-run` then `--verify`, only up, never on an item that is assigned or whose priority a person changed, at most `max-linear-calls` calls; it files nothing;
- for a page-check officer, only when its registry line says `writes: linear`, file and update Linear items through `docs/officers/contract.md` and `docs/officers/page-check-rubric.md`: `--dry-run` then `--verify`, a fingerprint search first, the `Found:` line and the per-run `max-creates` cap, never closing, deleting or re-prioritising an item a person touched;
- for a landing officer, unless its registry line says `writes: none`, correct what PropertyCompass2's release workflow (the routine Done writer) missed, through `linear-axi` `--dry-run` then `--verify`, at most `max-corrections` written items a run (skips do not count):
  set Done on an item whose every linked PR the landing-truth facts show merged and in production and that has no sub-issues, or move a Done item the facts name, with a linked PR merged that never reached main (`on_main` false) or any release, to its `reopen-state`; a Done item on main but not yet in production is release lag, reported and never written;
  no Linear write is made when the facts name no `production_sha` or their `generated_at` is missing or older than `max-facts-age` hours (default 36), and a `stale-facts` finding is raised instead;
  each correction first re-checks that Linear still shows the state the facts recorded, then writes an evidence comment quoting the landing-truth record it used, and is logged with that record in its findings.

An officer may never:

- drain, acknowledge, or otherwise touch the wake queue;
- spawn, steer, interrupt, relaunch, merge, land, or clean up any worker or second mate;
- answer, hold, or close a captain call, or edit Captain's Log cards;
- write to a project, another home, or any record outside its lane, Linear aside as above, or post its findings to fleet-app or any other service (the fleet app pulls a friction officer's velocity findings file and a progress officer's `progress-state.json` from its lane);
- write In Staging, or make any Linear change other than the landing officer's two corrections, the surgeon's creates, the friction, corpus and library officers' contract filing, the page-check officer's filing and the progress officer's priority raise above (the surgeon edits only its own cluster items and a duplicate's `Found:` line, comments at most once a day on a duplicate, and never closes or deletes an item);
- collect landing facts itself: the fleet-app landing-truth job owns them, and the officer only judges them;
- run crew of its own, or call a model in slice 1 (`model: none`).

A second mate home never runs officers; the primary home's officers already read the fleet.

## Adding and retiring

Add the registry line, then run `bin/fm-officer.sh register <id>`, which installs and trusts `state/officer-<id>.check.sh`.
Retire with `bin/fm-officer.sh retire <id>`; it removes the check and the line and keeps the findings.
Never hand-write the check script or its trust record.

Before registering an officer, answer these design questions in its registry notes or rubric:

1. What triggers it?
2. What does it do, and which services does it read and write?
3. What does it trigger next?
4. Where does a human re-enter?
5. What stops two runs doing the same work?

Every officer is a ticket source and starts work, so also answer what stops it filing the same ticket twice.
The answers to 5 and the duplicate question already exist: the stable key or fingerprint search, the local-jev duplicate check above 0.85 and the found count in `docs/officers/contract.md`, and the handled-once start rule.
A new officer points at them and states only what it adds.
(Adapted from mattpocock/skills, MIT, the software-factory skill.)

## Handling an officer wake

A `check:` wake from `state/officer-<id>.check.sh` reading `officer <id>: <date>: <n> actionable finding(s) in <path>` is one new digest.
The officer's `consumer:` field decides who that digest wakes: main only when `main` is listed, and each listed office through its own `lane:<id>` source, which that office handles under `office-roles`; the failure line always wakes main.
Main leaves a digest it is not a consumer of to that office.

1. Read the digest file it names; the `.json` beside it holds every session fact behind each finding.
2. Treat ordinary findings as evidence, not authorization; progress start requests use the standing authority and execution contract in [Progress officer](../../../docs/configuration.md#progress-officer), and surgeon start requests the same execution contract under [`docs/officers/surgeon-rubric.md`](../../../docs/officers/surgeon-rubric.md).
3. Route work the evidence supports through ordinary intake; file a tracker item only under the captain's standing rules for findings, and hold a real captain call through `bin/fm-captain-hold.sh hold`.
4. Do not re-wake the captain for a digest with nothing new; the check already stays silent on repeats and empty digests.
5. An office captures its outcome for each finding it acts on under `office-roles` "Capturing officer-finding outcomes".

An officer's digest line reaches main only when its registry `consumer:` field lists `main` (the default), and reaches an office through that office's `lane:<officer-id>` wake source; the failure line always reaches main.
A surgeon digest's `findings` are intake findings (real, won't fix, or needs a decision, with `tracked` and `filing` fields), and its `archive_findings` are the session join's.

For a progress, surgeon, friction, corpus or library digest, firstmate runs the adjacent `<date>.start-requests.sh` to enqueue the automatic starts addressed to its home, then processes those inbox notes through ordinary intake without another prioritization decision; a `start-home` office's own lane check delivers the requests addressed to it.
Apply the linked contract's freshness and readiness checks first; route its `asks_for_lee` to Captain's Log cards through the ordinary hold path.
The officer itself still never spawns or steers; executing the handoff and dispatching are firstmate's actions.

For a page-check digest, route each finding by its `route` line: cl-keeper closes or corrects the named card, and a page owner fixes a stale or failing page; the officer itself never edits a card or a page.
Read the friction digest's `repeat-ask` findings as a standing request: make the instruction automatic work, then tell Lee once.

A wake reading `officer <id>: <key>: run failed <n> time(s): <reason>` means the scheduled run gave up for that run key (a date, or an interval officer's `YYYY-MM-DDTHH` slot).
Fix the named cause, then rerun it with `bin/fm-officer.sh run <id> --date <key>`.

## Session-start OFFICER lines

Each `OFFICER:` line names its fix.
An unregistered or out-of-date check is repaired with `bin/fm-officer.sh register <id>`, which also covers a home that moved hosts or firstmate copies.
A stale officer has not finished a run within two cadences; read its `runs.log` and `run-output.log` before rerunning.
