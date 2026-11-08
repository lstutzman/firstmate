# Ship's Surgeon rubric

This is the Surgeon's rubric: what it treats as work, how it scores it, what it starts by itself, and what it only files.
Lee reads and edits this file, and `bin/fm-officer-surgeon.py` reads the lines under "Settings the code reads" on every run.
A rubric can only narrow what the code allows.
The reserved classes below are fixed in the code, so no line here can admit one.

## What counts as work

- A failed test in the nightly E2E run that is not noise: its triage class does not say flaky, load, host or infra, and its rerun did not pass.
- A finding in the nightly code review at critical, high or medium.
- A bug from the bug sweeper that is new or regressed.
- A nightly E2E run that is itself invalid (the run broke, no test result to read).
  This is work even though no test failed.
- A `defect` in the nightly visual review's findings file: a contradictory or impossible number, a raw internal name, missing core data, truncated or overflowing text, or a tie or zero shown as best.
  The review is the PropertyCompass2 script in `scripts/visual-review`, whose README owns the file format.
  Findings that share a fingerprint (the same rubric item on the same route, however many viewports show it) are one finding with every screenshot listed.
- Not work: a duplicate, a fixed-live bug, noise, a finding the code reviewer rated low, a finding the source already put in Linear.
  A finding needing a product or spec call, an unclear one and one fixed on staging only come to Lee as a decision and are not filed.
- Held for Lee, never filed and never started: a visual-review finding whose class is anything but `defect`.
  The findings file sets the class; today the held ones are the wording and product rubric items `jargon`, `repeated-or-developer-copy`, `empty-state-clutter` and `source-text-outside-sources`.
  Member-facing copy and product choices are Lee's.

## How severity and priority are scored

| Source | critical | high | medium | low |
|---|---|---|---|---|
| Nightly E2E failure | none | run is the staging tip | an older run | won't fix |
| Nightly code review | none | reviewer critical | reviewer high | reviewer medium |
| Bug sweeper | production bump only | P1, critical or high | P2 or medium | anything else |
| Nightly E2E run invalid | always | | | |
| Nightly visual review defect | none | file severity high | file severity medium | file severity low |

- Production bump: when the sweeper's payload says the bug was seen in production (its `environment` field), the finding moves up one step, low to medium to high to critical.
  The code never infers production from a bug's text, so a payload with no `environment` field gets no bump.
- A visual-review defect takes the severity the findings file gives it, and a finding with none stated is medium.
  A held visual-review finding is always low, so it never raises the high-severity wake.
- A won't-fix finding is always low.
- Linear priority follows severity: critical is Urgent, high is High, medium and low are Medium.
- An invalid nightly E2E run is critical and promotion-blocking.
  One item per job carries the whole outage: each day the run stays invalid bumps that item's Found count, so the count records how long it lasted, and a same-day rerun adds nothing.
  It shows as a high finding in the digest, and it never starts by itself because the usual fix (resetting an account's keys) is a credential action.
  A missing E2E input is never silent: it is either this item or a named coverage gap.

## Where findings are filed

- Every real finding is filed.
  A medium or higher finding gets its own Linear item.
- Low code-review findings are clustered by component, one Linear item per cluster, with each finding's file and fingerprint listed inside as a tick box.
  Findings from a fleet repository (firstmate, skills, fleet-app) cluster apart from PropertyCompass2 ones, and their cluster items go in the Fleet project with `area:fleet`.
  A new finding updates its cluster's item, and a finding on the reviewer's resolved list is ticked off.
- The cluster rule: group by the first 2 directory parts of the finding's file, split a group of more than 25 findings one level deeper (again while a subgroup still has more than 25), fold subgroups of fewer than 10 back into "(parent) (other)", and fold any group still under 3 findings into "(first part) (misc)".
  The code keeps these four numbers as named constants.
  The path decides the group, and the counts only decide where it splits or folds.
  A finding keeps its cluster once assigned, so the same file keeps landing in the same item as findings come and go.
- Each item has one Type, one Source and one area label.
  The area label comes from the finding's file path or component, and falls back to the triage label when nothing fits.
  A nightly E2E failure's path is always a spec file, so for it the feature labels (calculators, deal-finder, authentication, api and so on) are tried first, on the spec path and then the finding's words, and `testing` is only its fallback.
  The Surgeon never creates a label.
- A visual-review defect is one item, with the Source `scheduled-review`, the type Bug and an area label taken from its route (the same path rules), falling back to `ui-ux` and then to the triage label.
  Its description lists every screenshot and carries `visual-review-fp:<hex>`, the findings file's own fingerprint, beside the Surgeon's.
  The item also names each screenshot's path: the real path when the registry line names the capture directory and the file is there, else the relative path.
  When the registry line names the capture directory, the Surgeon attaches each screenshot to a newly filed item with `linear-attach <issue> <file> --verify`, never on a duplicate bump, and counts each call against the Linear call budget.
  A missing `linear-attach`, a missing or refused screenshot file, exit 3 (the app token lacks upload rights, Lee's call) and exit 75 (rate limited, which stops attaching for the run) are each a named coverage gap; a run that attaches everything reports none.
  A screenshot that was not attached, other than a missing file, stays pending in the lane's state and is retried first on every later run within the same call budget, so exit 3 is reported again each run until Lee changes the token; one still pending 7 days after it was first left is dropped with a named coverage gap saying it was abandoned.
  When the registry line names no capture directory, nothing is attached, and every run that files one says so in a `Coverage gap:` line.
- A finding with no source key is fingerprinted from its normalised title and location (digits dropped), so it is filed like any other.
- Linear calls are counted.
  A run stops its Linear work at its call budget, and the digest names everything left unfiled (call budget, create cap, rate limit), which the next run files.
  Nothing is dropped silently.

## Duplicates and the found count

- Before filing, the Surgeon searches for the finding's fingerprint, then searches the title and asks local-jev "is this the same issue?" about each candidate.
  Only a confidence above 0.85 counts as a duplicate.
  Below that the finding is filed new and the near match is noted in it.
  Without local-jev, only the fingerprint decides, and the digest says so.
- A duplicate raises the existing item's one machine-maintained line, `Found: N times (first <date>, last <date>, by surgeon)`, in place.
  The Surgeon never reopens an item a person closed: when the existing item (from the ledger, the fingerprint search or local-jev) is closed (its state type is completed or canceled), the finding is a recurrence, so a new item is filed with its own Found line, the line `Recurrence of <old id> (closed as <state>)` and a related link to the old item, and the ledger points at the new one.
  A closed cluster item is treated the same way: it is never updated again, and the cluster's next change files a new cluster item that names it.
  It adds one comment, on the item's first sighting of the day, and never a second the same day.
- A finding already on its own cluster's list is not a new sighting.
- The found count is a priority lever: score = severity weight x log2(1 + found), with weights critical 8, high 4, medium 2, low 1.
  The score orders what is filed and started (highest first), and the digest shows it.
  A start also needs a score of at least the minimum below, 4.
  A high or critical finding reaches it on first sight (4 and 8 at found 1); a medium finding reaches it at found 3 (2 x log2 4), and a low one never starts.
- A duplicate whose found count lifts its score to that minimum starts the existing item, the same as a new finding.
  An item is started or held once, and the Surgeon records it, so no later day asks for it again.

## Patterns worth remembering

- For each new review or bug-sweep finding the Surgeon keeps one pattern line: the anti-pattern and the safe form.
  Where the source gives no safe form, the line says so.
- Patterns are deduped by their normalised title, then by local-jev above 0.85 (same pattern, count goes up).
- New patterns leave in three ways.
  One batched start request goes to the Navigator, asking for the lines to be appended to PropertyCompass2 `.agents/skills/sdlc-review/references/quality-patterns.md` through a normal PR.
  The Surgeon never writes PropertyCompass2 itself.
  The digest lists them for the office to capture to the memory tier, tagged pattern plus the project, because no scriptable path to the memory service exists yet.
  A pattern that a tool could check (an unchecked null, SQL built from input) also gets a proposed analyzer or lint rule in the digest.

## Review misses

This is a note for the Surgeon's office, because the Surgeon itself is model-free and never runs the command.
When a filed production or staging bug names the merged PR that introduced it, and a no-mistakes run reviewed that PR, the office records the bug as a review miss:
`no-mistakes eval miss ingest <run> --finding '<json>'`, with an `id`, the `file` and `line` where the bug sits, a `severity`, an `action` and a `description` that names the bug and the fix PR.
Use the run's last green review pass; the command refuses a run whose last pass was blocking.
Run the ingest on the machine that holds the run's no-mistakes state, so the miss lands in that machine's eval store.
Never copy a case folder between machines: a copied folder is not registered in the store's `registry.sqlite`, so `eval sets`, `eval report` and `eval run` skip it without an error.
After the ingest, check that the case count or gold count rose in `no-mistakes eval sets`.
A bug whose PR merged before its first no-mistakes run has no run to label, so it is not recorded.
When the reviewer's model or instructions change, replay with `no-mistakes eval run --cases labeled --candidate <agent,model=...[,effort=...]>`, which spends model tokens, then read `no-mistakes eval report`.
`eval report` alone only restates the stored scores.

## What starts by itself

- A real, untracked critical, high or medium finding from the nightly E2E, the code review or the bug sweeper starts on its own once its Linear item exists and its score reaches the minimum.
  Critical and high start on first sight; medium starts once it has been found 3 times.
- PropertyCompass2 findings go to the Navigator.
  Findings in a fleet repository go to the Quartermaster.
  Both use the same start path as the progress officer, so each office's own check delivers its requests.
- Fixes never chain: a failure in work the Surgeon's own start caused starts nothing new.
  An item is started once (the `handled` check in `plan_starts`, `bin/fm-officer-linear.py`), so a later failure of the same item only raises its Found line.
- Repeated failure stops at 3 starts: a closed item that recurs is a new item, so the Surgeon counts the items started per fingerprint.
  Once 3 have started (`START_ATTEMPT_CAP` in `bin/fm-officer-linear.py`), the next is filed but not started.
  It goes to the owning office as a capped-repeat start request (kind `surgeon-fix-cap`) on the same lane a start takes, never into `asks_for_lee`.
  The office dispatches no fourth fix and files the keyed `needs-decision` `surgeon-<issue>-fix-cap`, so Lee decides the next step.
  Three separates a bad first attempt from a wrong diagnosis, and few enough that a stuck finding reaches a person within days.
  The office dispatches no more than 3 fixes for one finding either (`office-roles` "Picking work"); the test is `test_a_finding_that_keeps_coming_back_stops_at_three_starts`.
- Nothing else starts.
  Medium findings seen fewer than 3 times, low findings, clusters, invalid E2E runs and every visual-review finding only get filed (or, for a held visual finding, announced).
- A real security bug starts like any other at its severity, as the fleet rule wants high and critical security fixes started at once: a password hash compared with `==` or an API key logged in plaintext is a code fix, not a credential action.

## What only files, and holds for Lee

The visual review is not a start source: its defects are filed and counted, and a person or the owning office picks them up from Linear.
Its held findings are announced once as one keyed needs-decision, `surgeon-visual-held-<date>`, that names each route and rubric item, and a finding already announced is not put to Lee again.
A findings file that is missing, unreadable, of a schema version other than 2, or unchanged since the last run is a named coverage gap, never silence.
So is a file whose review was incomplete (a non-empty `errors` list, or `run.images_failed`, `run.images_deferred` or `run.malformed_findings_dropped` above zero), and a row without a route, a rubric item and a 64-hex `fingerprint`, which is skipped.
The Surgeon trusts each row's own `fingerprint` and `class`; it keeps no copy of the held rubric items.
A file the lane already read adds only the defects no item exists for yet, so an old file is never counted as a new sighting.

These classes never start, whatever the severity.
A finding that matches one is still filed, and the digest carries one keyed needs-decision line for the run that names it.
Each class is matched by the action it asks for, not by a word appearing anywhere, so a shallow copy or a password hash bug still starts.

- Payments or billing: any payments, billing, invoice, refund or Stripe work.
- Legal text: terms, privacy policy, cookie banner, licence text.
- Product decisions: a product decision, or changing prices, pricing, plan limits or the paywall.
- Member-facing copy: a request to change, update or reword the wording, copy or text shown to members.
- Credentials: a request, opening the title (after any bracketed tag such as `[P1]`) or a sentence of the summary or cause, to rotate, revoke, regenerate or reissue a secret, API key, token or service password ("Rotate SendGrid API key"), or to create or reset one ("Reset the signing key"); a bug in token or key handling ("Reset token not invalidated", "Token revoke leaves refresh tokens valid") is a code fix and starts.
- Production actions: deploying, restarting or promoting to production, or changing production data, config or settings.
- Data-rewriting changes: dropping or renaming a table or column, a migration, backfill or script that updates or deletes existing rows, removing an enum value; an endpoint bug that deletes or updates rows is a code fix and starts.

## Settings the code reads

These lines can narrow the code's allowances and nothing else.
A value the code does not allow is ignored and named as a coverage gap.
`start-min-score` can be raised above 4 (a single high finding, or a medium one found 3 times) and never lowered, and `pattern-memory: off` turns the pattern requests off.
A missing rubric means nothing starts, and the run says so.

- start-severities: medium, high, critical
- start-sources: nightly, review, sweeper
- start-min-score: 4
- pattern-memory: on
- hold-classes: payments-billing, legal, product, member-copy, credentials, production-actions, data-rewriting
