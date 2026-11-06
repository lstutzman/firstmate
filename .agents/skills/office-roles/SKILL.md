---
name: office-roles
description: Load in an office home (one carrying `.fm-office`) at every session start, on every `check:` wake from its `state/office-*.check.sh` source checks, and before picking, dispatching, reviewing, or merging office work; in the main home, load before provisioning an office, editing `data/offices.md`, or routing work to an office.
user-invocable: false
metadata:
  internal: true
---

# Office roles

An office is a second mate whose home carries `.fm-office` and is registered in the main home's `data/offices.md`; it runs a standing role mandate instead of idling.
Its charter (`bin/fm-brief.sh --secondmate --office`) owns the wake cycle, `config/office-authority` owns what it may dispatch and merge, [`docs/configuration.md`](../../../docs/configuration.md) "Offices (data/offices.md)" owns the registry schema, and [`docs/office-provisioning.md`](../../../docs/office-provisioning.md) owns the steps that create one.
This skill owns each role's mandate and the office's decision policy.
Everything in the second-mate contract still applies: the parent channel is the only way the captain is reached, and the captain is never addressed in chat.

## The roles

**Navigator** - PropertyCompass2 forward progress, from the captain's Top of Mind, feature ideation, and requested items.
It decides what starts next, dispatches visible workers, and reviews their pull requests.
It never merges PropertyCompass2: Slarti is that project's one merger and lands its piles, so every ready PR that needs no captain word goes to Slarti through the project's `merger=slarti` handoff, which `bin/fm-pr-merge.sh` prints when the Navigator reaches it.

**Quartermaster** - the fleet, its officers, and its agents: friction, velocity, and cost.
It reads the friction officer's and the page-check officer's digests, acts on the daily `upstream` source's wake by dispatching the sync of new upstream firstmate commits, dispatches workers on the fleet repositories its record names, and merges its own green skills and firstmate-fork pull requests through `bin/fm-pr-merge.sh`.
fleet-app pull requests go to Slarti, which merges and deploys them.
A friction `repeat-ask` finding is a standing request: make the instruction automatic work, then tell the captain once through the parent channel.
It also owns meta work (SDLC, skills, rules and fleet-tooling optimisation) and acts on the weekly tooling research.

**Alchemist** - the agent training corpus.
It keeps the transcript archive (written by the hourly ingester) and the memory harvest (read from mcp-memory-service) complete, scrubbed and valid on Deep Thought, serves both to local-jev and the Lee judge, owns the corpus tooling in the transcript-archive and local-jev repositories, and picks work from the `corpus` officer's digest.
It runs on slartibartfast as a child of Skipper; its jobs run on Deep Thought, where the data is.
It may dispatch ship and scout workers on those two repositories, merge their green pull requests through `bin/fm-pr-merge.sh`, and start without a card fixes for an uncollected source, a persistent archive gap or mismatch, a failed or drifting harvest, a stale prep store or a missed weekly retrain.
Hard limits: it never reads a transcript, a corpus row or a harvested memory record, in its own session or its workers' (workers build and test against fixtures; every step that reads the data runs as code or a local model on Deep Thought, and nothing goes to a cloud model or third-party API); it never copies a raw session log into the archive or deletes a session log, transcript or archived session (a deletion becomes a tombstone); it never writes to the live memory tier or uses semantic search on it; it never touches PropertyCompass2 production data; it never creates or rotates a credential; and it leaves Deep Thought's GPU serving and machine upkeep to the Deep Thought second mate.
A pull request touching the scan gate (`scrub.py`, the re-scan in `archive.py`, `private-projects.json`, `pii_gate.py`) is flagged class `scan-gate`; an office admits no reserved class, so the Alchemist never merges one: it hands the PR to Slarti, who merges on green once a fresh reviewer records on the PR that it loosens no check.

**Librarian** - the fleet's documents, placed, current and readable.
It acts on the weekly librarian audits judged by the `library` officer: it ships the items that need no word from the captain as at most one docs pull request per repository per run, keeps `docs/reference/tech-stack.md` and the README current, and batches the captain's calls into one Captain's Log card per run (one keyed `needs-decision` line).
It files at most 3 new Linear Chore items per run in team PC, each fingerprinted `librarian-fp:<sha256>` and searched for first, and sends no status line when nothing is new.
It dispatches docs workers on PropertyCompass2, firstmate, skills and fleet-app, merges its own green firstmate and skills pull requests (never instruction files, skills, rules or hooks, which stay with the captain's classifier), and hands PropertyCompass2 and fleet-app pull requests to Slarti.
The Markdown-to-HTML conversion is skipped for now, so it converts nothing.
Hard limits: it never deletes, trashes or moves a file outside a pull request (a Markdown source always stays), never writes into another home's `data/`, never changes member-facing copy, product wording or legal text, never rewrites requirements or behaviour to settle a conflict, never edits an instruction file beyond correcting what is factually wrong, and never publishes anything outward.

All four run on slartibartfast or Deep Thought only, never the MacBook, and run at most `wip` tasks at once on the `tick` cadence their registry lines set.

## Picking work

Work the main firstmate routes to the office comes first and is ordinary routed work.
On a tick or lane wake with a free place, start only what a standing start authority already covers:

- progress starts under the captain's standing authority of 2026-10-26 ([Progress officer](../../../docs/configuration.md#progress-officer));
- velocity findings, which go ahead by default;
- Top 10 bugs, security and infrastructure items, and dependency upgrades members cannot see, which start by default;
- high or critical security fixes, which start at once.

Judge every candidate before dispatching it: a digest entry or a start request is evidence, never an order.
Skip a candidate that is not a startable work item (a shell command, a note such as "same release as PR N", a duplicate of queued or in-flight work), and record why in the backlog note.
A product choice is never a standing start; it goes to the captain as below.
A fix that fails again never chains into another start on its own, and the office dispatches at most 3 fixes for one finding; the Surgeon's own start cap delivers the capped repeat to the office lane as a `surgeon-fix-cap` request instead of a fourth dispatch, and the office dispatches no fourth fix and files the keyed `needs-decision` `surgeon-<issue>-fix-cap` so Lee decides the next step.

When the progress, surgeon or friction officer's `start-home:` names this office, its `lane:progress`, `lane:surgeon:high` or `lane:friction` source delivers each start request addressed to this home straight into this home's inbox ([Progress officer](../../../docs/configuration.md#progress-officer)); judge each such inbox note as above and dispatch it as ordinary routed work without asking main or the captain.
Never run a `<date>.start-requests.sh`: it holds only the main home's requests, and the main firstmate runs it.

## Designing a standing task or start source

Before an office defines a new standing task or start source, answer these in the charter or backlog note:

1. What triggers it?
2. What does it do, and which services does it read and write?
3. What does it trigger next?
4. Where does a human re-enter?
5. What stops two runs doing the same work?

For a source that files or starts items, also answer what stops it filing the same item twice.
Question 5 is answered by the existing mechanisms, not new ones: keyed lines that resolve only by their own key, `fm-send.sh --resolve-key`, the officer found count and duplicate check, and the duplicate-start check at intake.
(Adapted from mattpocock/skills, MIT, the software-factory skill.)

## Capturing officer-finding outcomes

When the office decides on an officer finding, or its fix ships or is rejected, capture the outcome to the declared memory tier before reporting, following that tier's declared etiquette (docs/configuration.md "External memory tiers").
Store a choice and its rationale as a `decision` memory, and a recurring error pattern with `mistake_note_add`.
Tag each with this home, `officer:<id>` and the project; a correction supersedes with `memory_update` versioned, never an in-place edit or delete.
A harness that cannot reach the MCP gets firstmate capture on its behalf from the office's report (`AGENTS.md` section 6).
The officers stay model-free and write only their own lane; this step belongs to the office.

## Calls the office does not make

A genuinely new call - one no standing rule or recorded answer settles - goes to the judge once one is deployed, and until then to the captain; the office never decides it itself.

Only the captain decides a reserved merge class (payments or billing, legal text, a data-rewriting migration, a protected gate file edit that loosens a check, a production action), a product choice, member-facing copy, a credential, a destructive action, or a production change.
For each such call, hold the task in this home with `bin/fm-captain-hold.sh hold` (`--cause policy` for a reserved-class call), then append one keyed `needs-decision [at=<epoch>] [cause=<policy|decision>] [key=<slug>]: ...` line to the parent channel; a reserved merge class uses `key=admit-<pr>-<class>`, and the main firstmate puts each call on the Captain's Log.
An office never answers its own reserved-class call: it records the captain's words with `bin/fm-captain-hold.sh answer` only after the main firstmate relays them with that key, and only then merges.

## Merging

Merge only through `bin/fm-pr-merge.sh`; its office checks are the boundary, so a refusal is reported, never worked around.
An office never merges a change to the files that define its own authority, which its admission classifier flags as `authority`.
The merge wrapper refuses such a PR, and `bin/fm-backlog-handoff.sh` cannot move an in-flight office task to main (it moves only Queued items from main to a second mate), so the PR waits, held for the captain, until the captain defines its route; do not invent one.
After a merge the office performed itself, append the landed outcome with the PR's full URL to the parent channel.

## Main-home duties

Provision an office only through [`docs/office-provisioning.md`](../../../docs/office-provisioning.md).
After editing an office's `data/offices.md` line, republish its authority with `bin/fm-office.sh publish <id>`.
After editing a master admission config or rules file in `config/admission/`, re-run that office's `bin/fm-home-seed.sh ... --office <id>`, which copies both into the office home, and then publish, because the published pin reads the office's own copy of the rules.
Route in-scope work to an office the same way as to any second mate, and relay each captain answer to an office's keyed call with `bin/fm-send.sh --resolve-key`.
