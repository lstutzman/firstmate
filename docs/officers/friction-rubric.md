# Friction officer rubric

This is the friction officer's rubric: what it treats as work, how it scores it, what it starts by itself, and what it only files.
Lee reads and edits this file, and `bin/fm-officer-friction.py` reads the lines under "Settings the code reads" on every run.
A rubric can only narrow what the code allows.
The reserved classes below are fixed in the code, so no line here can admit one.

## What counts as work

- Friction is anything that slowed an agent down, above all a step it had to wait for Lee to do.
- Every group the officer finds is one finding: the same cause, sub-cause and tool, service or topic, across all its events.
  The groups are repeated asks (an instruction Lee gives on several days), missing tools, waits on Lee by cause (sudo, credentials, approvals, merge words, steps he runs by hand), service limits, guard and hook refusals, and environment faults.
- Every finding is filed once in Linear, whether or not it clears the card bar or a rule names a fix for it, so its found count can grow.
- Not work: a missing tool the fleet no longer uses (counted in the digest, never filed or fixed) and a finding already settled by a standing rule, started, or fixed.
- A group that is a product or design choice (`decision`) is Lee's to make, so it is not filed and is listed in the digest.

## How severity and priority are scored

| Finding | Linear severity |
|---|---|
| Cleared the card bar (severity and confidence of at least 3) | high |
| Not carded, with a friction severity of 3 or more | medium |
| Anything else | low |

- Linear priority follows severity: high is High, medium and low are Medium.
  Nothing is critical, because friction is never an outage.
- The found count is a priority lever: score = severity weight x log2(1 + found), with weights critical 8, high 4, medium 2, low 1.
  The found count is the number of nights the group was seen, kept on the Linear item's `Found:` line.
  The score orders what is filed and what starts, and the digest shows each finding's found count and score.
- Friction severity 1 to 5 comes from the group itself: Lee named in it, agent waiting of an hour or six, and three or more events.

## Where findings are filed

- Team PC, project Fleet, label `area:fleet`, Type Improvement, Source `agent`, the label Lee's Linear setup gives a worker filing on his behalf; the officer's identity is in each item's fingerprint marker and description.
- Each friction finding is one line on its category's bundle (tooling, waiting, environment or other), keyed by its cause, sub-cause and name, so the same group is the same line every night; the shared [bundle rule](contract.md#bundles) owns the rest.
- Duplicates, recurrences of closed items and the call budget are the shared [filing rules](contract.md#file).
- A line carries the finding's title, severity and fingerprint; an older single item's body carries counts, waits, the root cause, the proposed fix, the owner and effort, and task, status and card identifiers.
  It carries no quoted line from a transcript, a command or a repeated ask, because Linear is third-party storage; a repeated ask's topic goes as a hash.

## What starts by itself

- A finding in the standing-work groups of fleet rules section 2 starts once its item exists and its score reaches the minimum below, unless Lee objects on its card.
  Those groups are guard and hook refusals, service rate limits, missing tools, ssh to the machine itself, a worker resumed in the wrong directory, an agent waiting on something it cannot reach, commands Lee runs by hand with no recorded reason, repeated instructions, and blocked steps with no recorded cause.
- A card-bar finding is high, so it starts on first sight (4 at found 1).
- The request goes to the Quartermaster, who owns the fleet repositories.
- A started finding shows on its card as started by default and offers Object; a fix that merged and a finding seen again starts again.

## What only files, and holds for Lee

These never start by themselves, whatever the score:

- Credentials, approvals and merge words, sudoers rules, the gate-edit and secret-exposure hooks.
- The seven reserved classes: payments or billing, legal text, product decisions, member-facing copy, credentials, production actions and data-rewriting changes.
  A finding that matches one is still filed, and the digest carries one keyed needs-decision line for the run.
- Loosening a guard or gate check.

## Settings the code reads

These lines can narrow the code's allowances and nothing else.
A value the code does not allow is ignored and named as a coverage gap.
`start-min-score` can be raised above 4 and never lowered.
A missing rubric means nothing starts, and the run says so.
Friction findings are not bugs or code-review findings, so pattern memory is off.

- start-severities: high, critical
- start-sources: guard-hook, service-limit, missing-tool, environment, lee-command, repeat-ask, other
- start-min-score: 4
- pattern-memory: off
- hold-classes: payments-billing, legal, product, member-copy, credentials, production-actions, data-rewriting
