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
It reads the friction officer's and the page-check officer's digests, dispatches workers on the fleet repositories its record names, and merges its own green skills and firstmate-fork pull requests through `bin/fm-pr-merge.sh`.
fleet-app pull requests go to Slarti, which merges and deploys them.
A friction `repeat-ask` finding is a standing request: make the instruction automatic work, then tell the captain once through the parent channel.

Both run on slartibartfast or Deep Thought only, never the MacBook, and run at most `wip` tasks at once on the `tick` cadence their registry lines set.

`alchemist` and `librarian` are reserved role names: registry placeholders with no charter and no authority, which chartering, seeding, and `bin/fm-office.sh ensure` refuse until their own design lands.

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

Until the progress officer addresses start requests to an office's own home, an office never runs a `<date>.start-requests.sh` whose `FM_HOME` is not its own home, because that file enqueues into the main home.
In that interval the main firstmate consumes the progress digest and routes in-scope starts to the office as ordinary routed work.

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
