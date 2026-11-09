# Corpus officer rubric

This is the corpus officer's rubric: what it treats as work, how it scores it, what it starts by itself, and what it only files.
Lee reads and edits this file, and `bin/fm-officer-corpus.py` reads the lines under "Settings the code reads" on every run.
A rubric can only narrow what the code allows.
The reserved classes below are fixed in the code, so no line here can admit one.

## What counts as work

- Every open finding of the daily corpus check, each from counts, timestamps and names only:
  an uncollected source (a source the ingester did not collect in its last two runs),
  an archive gap (a host whose archive missed or held an out-of-date copy of session logs on two Bosun nights),
  a failed or drifting memory harvest,
  a stale prep store,
  and a missed or failed weekly retrain.
- Not work: a source skipped because its host is offline, a coverage gap (an unreachable host or a missing file), and a missing memory harvest result (the officer could not read the harvest).
  The digest names them and nothing is filed.

## How severity and priority are scored

| Finding | Linear severity |
|---|---|
| Archive gap, failed memory harvest | high |
| Uncollected source, harvest drift, stale prep store, missed or failed retrain | medium |

- Linear priority follows severity: high is High, medium is Medium.
  Nothing is critical, because a corpus gap never takes anything down.
- The found count is a priority lever: score = severity weight x log2(1 + found), with weights critical 8, high 4, medium 2, low 1.
  The found count rises once per night the finding is still open, on the Linear item's `Found:` line.
  The score orders what is filed and what starts, and the digest shows each finding's found count and score.

## Where findings are filed

- Team PC, project Fleet, label `area:fleet`, Type Chore, Source `agent`; the officer's identity is in each item's `corpus-fp:<sha256>` marker and description.
- Each finding is one line on its class's [bundle](contract.md#bundles), keyed by its class and subject, so the same gap is the same line every night.
- Duplicates, recurrences of closed items and the call budget are the shared [filing rules](contract.md#file).
- A line carries the class, subject, severity, the repository the fix lands in and, when the fix may touch them, the scan gate files; an older single item's body carries the summary built from counts, timestamps and names.
  It never carries a transcript, a corpus row or a memory record: the officer never reads one.

## What starts by itself

- A finding starts once its item exists and its score reaches the minimum below: a high finding on first sight, a medium one when it has stayed open for three nights.
- The request goes to the office whose dispatch list names the finding's repository: `transcript-archive` for an uncollected source, an archive gap and the memory harvest, `local-jev` for the prep store and the retrain.
  No registered office dispatches either repository until the Alchemist is registered, so each request goes to the main home, and it moves to the Alchemist once that office lists them.
- An archive gap, a failed harvest and harvest drift may be fixed in the scan gate files (`scrub.py`, the re-scan in `archive.py`, `private-projects.json`, `pii_gate.py`).
  Their start request says so: the corpus-owning office never merges that pull request, it goes to Slarti, who merges it on green once a fresh reviewer records that it loosens no check.

## What only files, and holds for Lee

These never start by themselves, whatever the score:

- A change that loosens, skips or deletes a scan gate check, which needs Lee's word (fleet rules section 3).
- The seven reserved classes: payments or billing, legal text, product decisions, member-facing copy, credentials, production actions and data-rewriting changes.
  A finding that matches one is still filed, and the digest carries one keyed needs-decision line for the run.

## Settings the code reads

These lines can narrow the code's allowances and nothing else.
A value the code does not allow is ignored and named as a coverage gap.
`start-min-score` can be raised above 4 and never lowered.
A missing rubric means nothing starts, and the run says so.
Corpus findings are not bugs or code-review findings, so pattern memory is off.

- start-severities: medium, high, critical
- start-sources: not-collected, archive-gap, harvest-failed, harvest-drift, prep-stale, retrain-missed
- start-min-score: 4
- pattern-memory: off
- hold-classes: payments-billing, legal, product, member-copy, credentials, production-actions, data-rewriting
