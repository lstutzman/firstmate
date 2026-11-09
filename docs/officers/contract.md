# Officer contract

This is the one page every registered officer follows when it finds work: find it, file it in Linear, triage it, and start it or hold it for Lee.
Fleet rules section 8 gives every officer authority to create and update Linear items under this contract and its own rubric file.
This page owns the contract; `bin/fm-officer-linear.py`'s header owns the mechanics, and each officer's `docs/officers/<id>-rubric.md` owns what that officer counts as work.
The Ship's Surgeon was first to adopt it ([`surgeon-rubric.md`](surgeon-rubric.md)), then the friction officer ([`friction-rubric.md`](friction-rubric.md)), the library officer ([`library-rubric.md`](library-rubric.md)), the page-check officer ([`page-check-rubric.md`](page-check-rubric.md)), the corpus officer ([`corpus-rubric.md`](corpus-rubric.md)) and the progress officer ([`progress-rubric.md`](progress-rubric.md)), which files nothing and only triages and starts.

## The four steps

1. Find: the officer's script reads its sources and classifies each finding as real, won't fix, or needs a decision.
   The officer's script header owns how; the contract only needs each real finding to carry a severity, a source, a stable key (or a title and location to fingerprint) and, for a bug or code-review finding, the safe form of the fix when the source gives one.
2. File: every real finding that no Linear item tracks yet is filed once, in team PC, by the shared library, as a line on its area's bundle item (see Bundles).
3. Triage: the filed item gets a priority from its severity and a score from how often it has been found; the digest shows both.
4. Start: a finding the rubric admits, whose score reaches the rubric minimum, goes to the owning office as a start request; a finding in a reserved class is held for Lee.

## Bundles

Automated findings are filed in far fewer, larger items, so one worker fixes a bundle in one pull request that is tested once (Lee, main chat, 2026-11-09).

- A bundle is one open Linear item per officer, source family and feature area, titled `Automated findings: <area> (<source family>)`, plus ` part N` for a later part.
  Fleet and PropertyCompass2 findings never share a bundle.
- Its body is a checklist grouped by file (`### <file>` headings, sorted), one line per finding: its `<officer-id>-fp:<sha256>` fingerprint, a one-line title, its severity and any note.
  Its `Severity:` line names its worst open finding, and a create takes that finding's priority.
- A new finding is appended to its area's open bundle and never becomes an item of its own.
  A new bundle is made only when the area has no open bundle with room.
- A bundle holds at most the registry's `bundle-cap` open findings (default 15, roughly what one worker fixes and tests in one pull request); the next finding opens the next part.
  A bundle a worker has started (Linear state type `started`) takes no new line, so its next finding opens the next part too.
- A finding marked resolved is ticked, never removed.
- A bundle a person closed is never written again: its findings still reported go to the area's open bundle, each line noting `recurred, was in <id>`.
- Each finding keeps its own found count, so its score still rises as it is seen again; a finding already on its bundle is not a new sighting, and a bundle has no Found line.
- An open bundle with a finding still reported is read once a day, so a bundle a person closed or started is noticed.
- A bundle starts as one item: one start request, which asks for every open line in one pull request.
  A line in a reserved class holds its whole bundle for Lee, whatever that line's own score.
- What stays single, never bundled: a finding an officer marks single (the Surgeon's invalid nightly E2E run, which blocks promotion), and anything already tracked by an item of its own.
  An existing single item a finding was filed in keeps its Found line until a person closes it (or it is folded into its bundle as a duplicate); the finding then goes to its area bundle naming it.
  Bugs from members, Lee's own items and production incidents are not filed by these officers.
- `bin/fm-officer-surgeon.py fold` folds the Surgeon's existing open items into bundles; it is a dry run unless given `--apply` (see its `--help`).

## File

- Search before creating: the fingerprint first (`<officer-id>-fp:<sha256>` in the item's description, and the lane's `filed-fingerprints.json`), then a text search of the title.
- Ask local-jev whether a text-search candidate is the same issue.
  It is a duplicate only at a confidence above 0.85; a lower near match is filed and its line names the near match.
  Without local-jev only the fingerprint decides, and the digest says so.
- A duplicate raises the item's one machine-kept line, `Found: N times (first <date>, last <date>, by <officer-id>)`, in place, and adds one comment on that day's first sighting and no more.
- Every Linear write is `--dry-run` and then `--verify`.
  A failed verify is never retried blindly.
  Linear rewrites a stored body, so a mismatch can mean the write landed: the item is taken as written when the error names it, else when the team's issue list holds one new open item of exactly its title in the same project (Linear's full-text search matches neither fingerprints nor these titles; a doubled write's extra items are named in the filing's `verify` note for a person to close), and only then recorded failed.
- Each item has one Type, one Source (a Source label from Lee's set, named in the officer's rubric: agent, captain, bug-sweep, scheduled-review or slack-desk) and one area label.
  A fleet finding (the officer's project is `Fleet`, or the finding names firstmate, skills or fleet-app) goes in the Fleet project, and the library sets its area label to `area:fleet` whatever the officer's own labels say; `area:fleet` on any other finding stops it being filed.
  This holds for every item the library creates, an officer's grouped items included: a group never mixes fleet and PropertyCompass2 findings, and a fleet group is created like a fleet finding.
  The officer's own label lookup does not cover `area:fleet`; if team PC lacked it, Linear's dry run would refuse the item and the digest would report it failed.
  An officer never creates a label; a missing label means the finding is reported and not filed.
- An officer filing under this contract never closes or deletes an item, and never changes the state, priority, labels, assignee or title of one that exists; the one exception is the progress officer's triage below.
  The only text it edits is the Found line and its own bundles' checklists; `fold --apply` alone also marks the Surgeon's folded originals Duplicate of their bundle.
  An item a person closed is never reopened: a repeat finding goes to its area bundle with a line that names the closed item (a finding an officer keeps single files a new item that says `Recurrence of <id>` and links the old one).
  The page-check officer is the one exception: its repeat of a closed item or bundle raises nothing new, files nothing and never starts it ([`page-check-rubric.md`](page-check-rubric.md)).
- The registry line sets the per-run create cap (`max-creates`, which counts bundles), the bundle size (`bundle-cap`) and the Linear call budget (`max-linear-calls`).
  Whatever the cap, the budget or a rate limit leaves unfiled is named in the digest with its reason, highest score first, and the next run files it from the ledger.
  Nothing is dropped silently.

## Triage

- Linear priority follows severity: critical is Urgent (1), high is High (2), medium and low are Medium (3).
- The found count is a priority lever.
  The score is the severity weight (critical 8, high 4, medium 2, low 1) multiplied by log2(1 + found), and it orders what is filed and what starts.
  The digest shows each finding's found count and score.
- The progress officer triages an officer-filed item (one carrying an `<officer-id>-fp:<sha256>` marker) before it starts it: it raises the item's Linear priority from its score (8 or more is Urgent, 4 or more High, else Medium), never lowers it, never touches an item that is assigned or whose priority a person changed, and names the owning office in the start request.
  Until an item is triaged, the severity-derived priority above stands.
  [`progress-rubric.md`](progress-rubric.md) owns the rules, and `bin/fm-officer-linear.py`'s `triage_issue` is the one write.

## Start

- A finding starts only when it is real, untracked and filed, its source and severity are ones the rubric admits, its score reaches the rubric's minimum (never below 4), and it matches no reserved class.
- The start request uses the progress officer's start-request path, so the owning office's own check delivers it: the Navigator for PropertyCompass2, the Quartermaster for fleet repositories.
  A finding that names no repository belongs to the officer's own project: PropertyCompass2 unless the officer declares `Fleet`.
  A Fleet finding with no repository is never given one; it stays a Linear-only item and goes to the Quartermaster, as does a finding naming firstmate, skills or fleet-app.
  An item is started or held once; a later day never asks for it again.
- The reserved classes are fixed in the library and always hold, whatever a rubric says.
  A finding that matches one is still filed, and the run's digest carries one keyed `needs-decision` line (`<officer-id>-holds-<date>`) naming them.
  Each is matched by the action it asks for, not by a word appearing anywhere.

  | Class | The finding asks for |
  |---|---|
  | `payments-billing` | payments, billing, invoice, refund, Stripe or direct debit work |
  | `legal` | terms, privacy policy, cookie banner or licence text |
  | `product` | a product decision or change, or changing prices, plan limits or the paywall |
  | `member-copy` | changing the wording, copy or text shown to members |
  | `credentials` | rotating, revoking, regenerating, reissuing, creating or resetting a secret, key, token or password |
  | `production-actions` | deploying, restarting or promoting to production, or changing production data, config or settings |
  | `data-rewriting` | dropping or renaming a table or column, a migration or script that updates or deletes existing rows, removing an enum value |

- A rubric can only narrow.
  It can drop a severity or source from the allowed set, raise the start minimum, and turn pattern memory off; a value the code does not admit is ignored and named as a coverage gap, and a `hold-classes` line that omits a class still holds it.
  That is why an edit to a rubric needs no merge word: it cannot grant authority.

## Pattern memory

For a bug or code-review finding, the specific bad pattern is remembered so it is not repeated.

- One line per pattern: the anti-pattern and the safe form.
- Patterns are deduped like findings (normalised title, then local-jev above 0.85), and a repeat raises the pattern's count.
- A new pattern leaves in three ways: a batched start request, the digest for capture to the memory tier tagged `pattern` and the project, and, for a mechanical pattern, a proposed analyzer or lint rule.
  A PropertyCompass2 pattern's request goes to the Navigator to append the lines to PropertyCompass2's `.agents/skills/sdlc-review/references/quality-patterns.md` through a normal PR.
  A pattern from fleet code never goes to that file: its request goes to the Quartermaster, to add the lines to the review guidance of the repository it came from, or a check, through a normal PR; it is tagged with the named repository, or `Fleet` when none is named.
  The officer never writes either repository itself.

## The rubric file

`docs/officers/<id>-rubric.md` is short and Lee-editable, and the library reads it on every run.
It has these headings, in plain words: what counts as work, how severity and priority are scored, where findings are filed, what starts by itself, and what only files and holds for Lee.
The last section is `## Settings the code reads`, a list of `- key: value, value` lines:

| Key | Meaning | Default |
|---|---|---|
| `start-severities` | severities that may start | the officer's allowed set |
| `start-sources` | sources that may start | the officer's allowed set |
| `start-min-score` | lowest score that starts | 4 (never lower) |
| `pattern-memory` | `off` stops pattern requests | on |
| `hold-classes` | the reserved classes, listed for the reader | all seven (always held) |

A missing or unreadable rubric means nothing starts by itself, and the run says so.

## Adopting the contract

An officer adopts it in one change:

- add its `docs/officers/<id>-rubric.md`, using the headings above;
- load `bin/fm-officer-linear.py`, declare an `Officer` with its id, label, rubric file, allowed sources and project, and file through `Filer` (`file_single`, or `item_labels` and `create` with the item's project for anything it groups); a finding's own repository, else the officer's project, decides both filing and routing: Fleet work (the `Fleet` project or a fleet repository) is filed in the Fleet project and its starts and patterns go to the Quartermaster, and anything else is filed with no Linear project;
- add `writes: linear`, `max-creates`, `max-linear-calls` and `start-home` to its registry line ([Officers](../configuration.md#officers-dataofficersmd)), and have `bin/fm-officer.sh` pass them to its script as it does for the Surgeon;
- name its Source label in the rubric, one of Lee's set, so it exists in team PC; the library sets `area:fleet` and the Fleet project for fleet work itself;
- prove it with tests that run the officer through `bin/fm-officer.sh` against a fake `linear-axi`, as `tests/fm-officer-surgeon.test.sh` does.
