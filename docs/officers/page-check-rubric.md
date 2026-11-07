# Page-check officer rubric

This is the page-check officer's rubric: what it treats as work, how it scores it, what it starts by itself, and what it only files.
Lee reads and edits this file, and `bin/fm-officer-page-check.py` reads the lines under "Settings the code reads" on every run.
A rubric can only narrow what the code allows.
The reserved classes below are fixed in the code, so no line here can admit one.

## What counts as work

- A defect on a fleet-app page: something the page shows that it should not, or fails to show.
  Every open finding is one item, keyed by its kind, page and object, so the same defect is the same item every run.
- `standing-rule`: a card or suggestion Lee is shown that a standing rule in `data/captain-shared.md` already settles.
- `stale-card`: a shown card past its snooze date, unanswered for a week, already answered, naming a merged or closed PR, or whose status line was settled elsewhere.
- `shown-after-done`: a card shown although its record was settled by a captain answer or is closed in the app's own card record.
- `page-old`: a page older than its normal cadence allows, a failing job on the Runs page, or a page that is unreachable, unreadable or never published.
- Every finding is filed once in Linear, so its found count can grow while nobody fixes it.
- Not work: a live decision (a merged PR whose production or activation action is still open, or a routing acknowledgement that is not a captain answer), which the officer never flags.

## How severity and priority are scored

| Finding | Linear severity |
|---|---|
| A page that is unreachable, unreadable or never published, or an unreadable Runs page or app health | high |
| A page past its normal cadence, a failing job, a page with no publish time, a card shown after it was settled | medium |
| A card a rule settles, or any other stale card | low |

- Linear priority follows severity: high is High, medium and low are Medium.
  Nothing is critical, because a stale page is never an outage.
- The found count is a priority lever: score = severity weight x log2(1 + found), with weights critical 8, high 4, medium 2, low 1.
  The found count is the number of days the finding was seen, kept on the Linear item's `Found:` line.
  The score orders what is filed and what starts, and the digest shows each finding's found count and score.

## Where findings are filed

- Team PC, project Fleet, label `area:fleet`, Type Bug, Source `agent`, the label Lee's Linear setup gives a worker filing on his behalf; the officer's identity is in each item's fingerprint marker and description.
- Duplicates, the `Found:` line, recurrences of closed items and the call budget are the shared [filing rules](contract.md#file).
- The item body carries the page, the kind, the object id, the evidence and the route.
  It carries no card question or answer, because Linear is third-party storage; the card is named by its id.

## What starts by itself

- A `page-old` or `shown-after-done` finding starts once its item exists and its score reaches the minimum below: a high finding on first sight (4 at found 1), a medium finding at found 3.
- The request goes to the Quartermaster, who owns the fleet repositories; fleet-app merges stay with Slarti through the existing merge handoff.
- A request is repeated on every run of the same day until the day ends, and a later day never asks twice.
- A page-old or shown-after-done finding is a bug in fleet code, so once its item exists its bad pattern is remembered once: the kind and the page or Runs job as the anti-pattern and the route as the safe form, with no timestamps and never a card's id or words.
  A new pattern goes to the Quartermaster in one batched pattern-memory start request and in the digest's `patterns` for memory capture; a repeat of the same finding adds no second line, and the same defect on another card or page sighting raises the pattern's count.
  `standing-rule` and `stale-card` findings are not bug patterns and are never remembered.

## What only files, and holds for Lee

These never start by themselves, whatever the score:

- `standing-rule` and `stale-card` findings: the card is cleared by cl-keeper, and the rule is Lee's, so the officer never starts a fix for either.
- The seven reserved classes: payments or billing, legal text, product decisions, member-facing copy, credentials, production actions and data-rewriting changes.
  The check judges what the started fix would change, so it reads the finding's own kind, page, evidence and route, and the object id only when the object is the fix target (a page or a Runs job), never a card's id or question:
  a settled card asking for a production deploy that the app re-shows is a fleet-app page fix, and starts like any other.
  A finding whose own fix is in a reserved class is still filed, and the digest carries one keyed needs-decision line for the run.

## Settings the code reads

These lines can narrow the code's allowances and nothing else.
A value the code does not allow is ignored and named as a coverage gap.
`start-min-score` can be raised above 4 and never lowered.
A missing rubric means nothing starts, and the run says so.
Page-old and shown-after-done findings are filed as bugs, so pattern memory is on, as Lee asked for bugs: "for bugs and code review findings, the specific bad pattern should be remembered so it is not repeated" (main chat, 2026-11-05T18:06:23Z).

- start-severities: high, medium
- start-sources: page-old, shown-after-done
- start-min-score: 4
- pattern-memory: on
- hold-classes: payments-billing, legal, product, member-copy, credentials, production-actions, data-rewriting
