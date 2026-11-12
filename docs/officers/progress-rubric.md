# Progress officer rubric

This is the progress officer's rubric: what it treats as work, how it triages and scores items other officers filed, what it starts by itself, and what it only holds for Lee.
Lee reads and edits this file, and `bin/fm-officer-progress.py` reads the lines under "Settings the code reads" on every run.
A rubric can only narrow what the code allows.
The reserved classes below are fixed in `bin/fm-officer-linear.py`, so no line here can admit one.

## What counts as work

- The officer finds no work of its own.
  It starts work that is already authorised and unstarted, and it files nothing in Linear.
- Authorised, unstarted work is the existing classes in [Progress officer](../configuration/officers-progress.md#progress-officer): `security` and `cve`, `code-review` and `bug`, and `requested-feature` and `requested-fleet`, by tag, title prefix, Linear label or requested root.
  This rubric does not change what starts; the code owns that list, and Lee's standing authority of 2026-10-26 is its source.
- Work is excluded, never started, when it is held, blocked, carded, already in flight, finished, covered by an open PR in `repos`, or waiting on an ask to Lee.
- An item another officer filed is recognised by its `<officer-id>-fp:<sha256>` marker in the description, the shared [officer contract](contract.md#file).
  The Source label alone is not enough, because workers file items with `agent` too and the officer cannot read labels beyond the start classes.

## How items are triaged and scored

- Before an officer-filed start candidate's request is written, the officer sets its Linear priority from its score and names its owner office.
- The score is the shared one: severity weight (critical 8, high 4, medium 2, low 1) multiplied by log2(1 + found), and the found count is the item's `Found:` line.
  The severity is the filing officer's `Severity:` line in the description; without one it is what the item's priority stood for when the officer first saw it: Urgent is critical, High is high, Medium is medium, and none or Low is low.
  It is fixed at first sight in the lane's `triage-state.json`, so the officer's own priority writes never raise it; only a new Found sighting raises the score.
- The priority follows the score: 8 or more is Urgent (1), 4 or more is High (2), anything lower is Medium (3).
  The found count is the lever: an item nobody has fixed climbs each time an officer sees it again.
- The officer only raises a priority.
  It never lowers one, and it never changes anything else about the item.
- It never re-prioritises an item a person touched: one that is assigned, or whose priority differs from what the progress lane last left it at.
  A priority a person changed before the officer first saw the item cannot be told apart from the filing officer's own, so that one is treated as the officer's.
- The owner office is the Navigator for PropertyCompass2 work and the Quartermaster for the Fleet project, and the request goes to that office's home.
- Within a class, the ranked list orders by the new priority.

## Where nothing is filed

- Linear's only write is the priority above, `--dry-run` then `--verify`, counted against the registry line's `max-linear-calls` and stopped by one rate-limit answer.
- A failed write is a named coverage gap on that item; its start request still goes out at the priority it had.
- An item whose description was not read in full is not triaged and is a named coverage gap; it is still held for Lee when the text that was read asks for a reserved class.
- The shared [filing rules](contract.md#file) do not apply, because the officer creates nothing.

## What starts by itself and what only holds for Lee

- An officer-filed item starts exactly as any item of its class does today, after triage.
- The seven reserved classes never start by themselves: payments or billing, legal text, product decisions, member-facing copy, credentials, production actions and data-rewriting changes.
  An officer-filed item that asks for one (matched by the action, in its title and description) is held, and the digest carries one keyed needs-decision line for the run, `progress-holds-<date>`.
  The existing checks on titles of other items (the `asks_for_lee` rules in [Progress officer](../configuration/officers-progress.md#progress-officer)) are unchanged.

## Settings the code reads

These lines can narrow the code's allowances and nothing else.
`triage: off` stops the priority write; the owner office, the ranking and the reserved-class hold stay.
A missing rubric stops the priority write too, and the run names it as a coverage gap; the existing starts and the reserved-class hold go on.

- triage: on
- hold-classes: payments-billing, legal, product, member-copy, credentials, production-actions, data-rewriting
