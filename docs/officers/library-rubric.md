# Library officer rubric

This is the library officer's rubric: what it treats as work, how it scores it, what it starts by itself, and what it only files.
Lee reads and edits this file, and `bin/fm-officer-library.py` reads the lines under "Settings the code reads" on every run.
A rubric can only narrow what the code allows.
The reserved classes below are fixed in the code, so no line here can admit one.

## What counts as work

- The weekly librarian audit's findings, judged into buckets by `bin/fm-officer-library.py`: safe to ship (a docs change one pull request can carry), code work, needs Lee, and on hold.
- Safe, code and needs-Lee findings are work and are filed once in Linear.
- Not work: a finding on hold (nothing to ship yet) and the run's count of decisions for Lee; neither is filed.

## How severity and priority are scored

- Severity is the audit's own (high, medium or low).
  A safe docs finding is filed as medium at least, so it can reach the start score by being found again.
- Linear priority follows severity: high is High, medium and low are Medium.
- The found count is a priority lever: score = severity weight x log2(1 + found), with weights critical 8, high 4, medium 2, low 1.
  The found count rises once per audit run, on the item's `Found:` line, so a finding the audit keeps raising scores higher.
  The score orders what is filed and what starts, and the digest shows each finding's found count and score.

## Where findings are filed

- Team PC, Type Chore, Source `scheduled-review` (the weekly audit), label `documentation`, else the team's triage label; no Linear project for PropertyCompass2 work.
- At most 3 new items per audit run (fleet rules section 8).
  What the cap leaves unfiled is named in the digest, highest score first, and the next audit run files it.
- Each item carries the `librarian-fp:<sha256>` marker.
  Duplicates, the `Found:` line, recurrences of closed items and the call budget are the shared [filing rules](contract.md#file).
- The item body holds the audit's kind, path, title and proposed change, and no report text.

## What starts by itself

- A safe-to-ship finding starts once its item exists and its score reaches the minimum below: a high finding on first sight, a medium one when the audit has found it three times.
- The request goes to the office whose dispatch list names the repository (the Navigator for PropertyCompass2), else to the main home.
  The Librarian office reads the same digest and ships its own docs pull request, at most one per repository per run, so the request asks only that this item is not missed.

## What only files, and holds for Lee

These never start by themselves, whatever the score:

- Needs-Lee findings: a conflict, an instruction or hook file, a disposition naming Lee, an owner, an approval or a decision, and any delete, removal, retirement or archive.
  They are filed, and the digest carries one keyed needs-decision line for the run, never one per item.
- Code work, which needs its own brief.
- The seven reserved classes: payments or billing, legal text, product decisions, member-facing copy, credentials, production actions and data-rewriting changes.
  A safe finding that matches one is still filed, and the digest carries one keyed needs-decision line for the run.

## Settings the code reads

These lines can narrow the code's allowances and nothing else.
A value the code does not allow is ignored and named as a coverage gap.
`start-min-score` can be raised above 4 and never lowered.
A missing rubric means nothing starts, and the run says so.
Audit findings are docs and code-health items, not bugs or code-review findings, so pattern memory is off.

- start-severities: medium, high, critical
- start-sources: audit
- start-min-score: 4
- pattern-memory: off
- hold-classes: payments-billing, legal, product, member-copy, credentials, production-actions, data-rewriting
