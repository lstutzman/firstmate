# Improvement officer rubric

This is the improvement officer's rubric: what it measures, what each stage means, and the answers to the officer design questions.
Lee reads and edits this file.
`bin/fm-officer-improvement.py` reads none of it, because the officer files nothing, scores nothing and starts nothing, so no setting here can widen what it does.
The shared [officer contract](contract.md) does not apply to it for the same reason: it adopts none of the filing, triage or start steps.
Lee's aim for it (22 October 2026): "turn our SDLC and First Mate, Second Mate fleet into a proper software factory and to reduce friction, reduce cost to PR times".

## What counts as work

- The metric is per PR, end to end: the time and cost from work started to running in production, split into 11 stages: work, pr_ready, review, gate_queue, gate_run, pile_wait, merge, staging_deploy, staging_checks, release_cut, production.
- A PR is measured once, on the run that first sees it in production (fresh landing-truth facts), or, when the facts are absent or stale, on the run for the day it merged, with production reported as unconfirmed.
- Every record names every stage as measured or unmeasured.
  An unmeasured stage names the source it lacks, and its time is never estimated.
- Cost is model dollars from the session archive's `pr_urls` and `cost_usd`, plus gate machine minutes from the gate-usage records.
  A session that names several PRs has its cost and tokens split evenly across them, and each PR's cost entry records the split (`split_across`), so the shares add up to what was spent.
  Lee minutes and per-PR account usage have no source, so they are reported as unmeasured.
- The weekly digest (a Sunday run date) gives the median and the worst five PRs end to end, each stage's median against the week before, and the stage that grew most.
  All of these count only PRs promoted to main; a merged-only record (the facts were absent or stale that day) is listed apart, with its count, as not yet measurable to production.
  It proposes nothing: the consumer office reads the digest and proposes at most three changes as cards, then measures each one after it lands.

## How stages are measured

- Each stage is the interval between two named events, from the sources in the script header (`bin/fm-officer-improvement.py`), and the header owns the exact rule for each.
- Five stages have no source yet: gate_queue (the gate request time), pile_wait (pile order files), staging_deploy and staging_checks (their timestamps), and production (the deploy time).
- release_cut is the merge to promotion to main, and it holds the staging deploy and staging checks, which the facts do not time apart.
- The end event is promotion to main when the facts give it, else the merge, because production has no timestamp in the facts today.
- A PR belongs to a task only through that task's own ready signal: a `task.pr_ready` ledger record, or a status-log `done:` line in the ready-signal shape (`PR <url>`). A pile, restack, merger or review log that only mentions the PR is ignored, and a PR with no ready signal has its work and end-to-end times unmeasured.
- The first run that reads fresh facts keeps only PRs merged in the window and records the rest as the lane's baseline, which no later run counts.
- gate_run counts only gate runs on the PR's final head or merge sha, so a run on an earlier head or a pile candidate is not counted.
  It is a lower bound and its record says so.

## Where findings are filed

- Nowhere.
  The officer writes its own lane only: one dated `<date>.json` and `<date>.md` per run, and `prs.json` (the measured PRs).
- It reads GitHub with `gh-axi api GET` only, at most `max-pr-lookups` calls a run, and it never writes to GitHub, Linear, fleet-app or any other service.
  `writes: none` is the only value its registry line accepts.

## What starts by itself

- Nothing.
  The officer writes no start request and spawns, steers and messages nobody.
- A daily run reports no actionable finding, so it wakes nobody.
  The weekly run reports one (the weekly summary), so a consumer wakes once a week.
  Coverage gaps (a source absent, stale or unreadable, or the lookup cap reached) are low-severity findings in the digest and wake nobody.

## What only files, and holds for Lee

- Nothing is filed and no captain call is held or answered here.
- Changes the weekly digest points at that touch a reserved class (payments, legal text, product, member copy, credentials, production actions, data-rewriting changes) stay with Lee under fleet rules section 2.
  The office that proposes them follows that rule, and the officer never acts on them.

## Design questions

Each answer points at the mechanism that already exists, and states only what this officer adds.
(Adapted from mattpocock/skills, MIT, the software-factory skill.)

1. What triggers it?
   The registry `cadence` (`daily HH:MM`): the watcher check starts the run for yesterday's date at the first check after that time ([Officers](../configuration/officers.md#officers-dataofficersmd)).
   The weekly digest is the run whose date is a Sunday.
2. What does it do, and which services does it read and write?
   It reads GitHub (read-only), the fleet-app landing-truth facts file, each readable home's fleet ledger and status logs, the gate-usage records and the archive manifests' counts, and it writes its lane only.
   It calls no model (`model: none`), and `officer-roles` owns the read list.
3. What does it trigger next?
   Nothing by itself.
   A consumer office (named by the registry `consumer:` field) reads the weekly digest and proposes at most three changes through ordinary intake.
4. Where does a human re-enter?
   At the office's proposals, which become Captain's Log cards through the ordinary hold path ([Officer handling](../../.agents/skills/officer-roles/SKILL.md)).
   The officer never holds, answers or closes a captain call.
5. What stops two runs doing the same work?
   The lane's `.run.lock` and the per-date run key in `bin/fm-officer.sh`, and the first-seen date in `prs.json`: a PR is dated to the run that first saw it, and a rerun of a date rewrites identical bytes.

The duplicate question (what stops it filing the same ticket twice) has no work to answer: it files no ticket.
If a later slice files cards, it uses the stable-key search, the local-jev check above 0.85 and the found count in the [contract](contract.md#file), and the handled-once start rule.

## Settings the code reads

None.
The registry line carries the officer's settings (`repos`, `facts`, `gate`, `archive`, `window-days`, `max-pr-lookups`, `max-facts-age`), and the [Officers](../configuration/officers.md#improvement-officer) reference owns them.
