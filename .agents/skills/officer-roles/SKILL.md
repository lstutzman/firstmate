---
name: officer-roles
description: Load on a `check:` wake from `state/officer-<id>.check.sh`, on any `OFFICER:` session-start line, before adding, registering, or retiring an officer, and before reading or acting on an officer's findings.
user-invocable: false
metadata:
  internal: true
---

# Officer roles

An officer is a role agent owned by the primary home.
It reads fleet records on its own daily cadence, writes only its findings lane, and reports one line to its first mate.
It never acts on the fleet.
[`docs/configuration.md`](../../../docs/configuration.md) "Officers (data/officers.md)" owns the registry schema, and `bin/fm-officer.sh`'s header owns the mechanics.

## Authority

An officer may:

- read fleet records: this home's and local second mate homes' `state/` status logs, meta, and fleet ledger, `data/<id>/` reports, the backlog, the session archive, and GitHub read-only;
- write its own lane, `data/officers/<id>/`: dated findings (a friction officer's include its fleet-app velocity findings file), its digest marker, `runs.log`, and its `check-record.*` files;
- print its one report line from its watcher check;
- for a landing officer, unless its registry line says `writes: none`, correct what PropertyCompass2's release workflow (the routine Done writer) missed, through `linear-axi` `--dry-run` then `--verify`, at most `max-corrections` written items a run (skips do not count):
  set Done on an item whose every linked PR the landing-truth facts show merged and in production and that has no sub-issues, or move a Done item the facts name, with a linked PR merged that never reached main (`on_main` false) or any release, to its `reopen-state`; a Done item on main but not yet in production is release lag, reported and never written;
  no Linear write is made when the facts name no `production_sha` or their `generated_at` is missing or older than `max-facts-age` hours (default 36), and a `stale-facts` finding is raised instead;
  each correction first re-checks that Linear still shows the state the facts recorded, then writes an evidence comment quoting the landing-truth record it used, and is logged with that record in its findings.

An officer may never:

- drain, acknowledge, or otherwise touch the wake queue;
- spawn, steer, interrupt, relaunch, merge, land, or clean up any worker or second mate;
- answer, hold, or close a captain call, or edit Captain's Log cards;
- write to a project, another home, or any record outside its lane, Linear aside as above, or post its findings to fleet-app or any other service;
- write In Staging, make any Linear change other than those two corrections, or file a Linear item;
- collect landing facts itself: the fleet-app landing-truth job owns them, and the officer only judges them;
- run crew of its own, or call a model in slice 1 (`model: none`).

A second mate home never runs officers; the primary home's officers already read the fleet.

## Adding and retiring

Add the registry line, then run `bin/fm-officer.sh register <id>`, which installs and trusts `state/officer-<id>.check.sh`.
Retire with `bin/fm-officer.sh retire <id>`; it removes the check and the line and keeps the findings.
Never hand-write the check script or its trust record.

## Handling an officer wake

A `check:` wake from `state/officer-<id>.check.sh` reading `officer <id>: <date>: <n> actionable finding(s) in <path>` is one new digest.

1. Read the digest file it names; the `.json` beside it holds every session fact behind each finding.
2. Treat each finding as evidence, not authorization: it names what an officer saw, never a change to make.
3. Route work the evidence supports through ordinary intake; file a tracker item only under the captain's standing rules for findings, and hold a real captain call through `bin/fm-captain-hold.sh hold`.
4. Do not re-wake the captain for a digest with nothing new; the check already stays silent on repeats and empty digests.

A wake reading `officer <id>: <date>: run failed <n> time(s): <reason>` means the scheduled run gave up for that date.
Fix the named cause, then rerun the date with `bin/fm-officer.sh run <id> --date <date>`.

## Session-start OFFICER lines

Each `OFFICER:` line names its fix.
An unregistered or out-of-date check is repaired with `bin/fm-officer.sh register <id>`, which also covers a home that moved hosts or firstmate copies.
A stale officer has not finished a run within two cadences; read its `runs.log` and `run-output.log` before rerunning.
