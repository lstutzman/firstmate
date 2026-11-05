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
- Not work: a duplicate, a fixed-live bug, noise, a finding the code reviewer rated low, a finding the source already put in Linear.
  A finding needing a product or spec call, an unclear one and one fixed on staging only come to Lee as a decision and are not filed.

## How severity and priority are scored

| Source | critical | high | medium | low |
|---|---|---|---|---|
| Nightly E2E failure | none | run is the staging tip | an older run | won't fix |
| Nightly code review | none | reviewer critical | reviewer high | reviewer medium |
| Bug sweeper | production bump only | P1, critical or high | P2 or medium | anything else |
| Nightly E2E run invalid | always | | | |

- Production bump: when the sweeper's payload says the bug was seen in production (its `environment` field), the finding moves up one step, low to medium to high to critical.
  The code never infers production from a bug's text, so a payload with no `environment` field gets no bump.
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
  A new finding updates its cluster's item, and a finding on the reviewer's resolved list is ticked off.
- The cluster rule: group by the first 2 directory parts of the finding's file, split a group of more than 25 findings one level deeper (again while a subgroup still has more than 25), fold subgroups of fewer than 10 back into "(parent) (other)", and fold any group still under 3 findings into "(first part) (misc)".
  The code keeps these four numbers as named constants.
  The path decides the group, and the counts only decide where it splits or folds.
  A finding keeps its cluster once assigned, so the same file keeps landing in the same item as findings come and go.
- Each item has one Type, one Source and one area label.
  The area label comes from the finding's file path or component, and falls back to the triage label when nothing fits.
  A nightly E2E failure's path is always a spec file, so for it the feature labels (calculators, deal-finder, authentication, api and so on) are tried first, on the spec path and then the finding's words, and `testing` is only its fallback.
  The Surgeon never creates a label.
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

## What starts by itself

- A real, untracked critical, high or medium finding from the nightly E2E, the code review or the bug sweeper starts on its own once its Linear item exists and its score reaches the minimum.
  Critical and high start on first sight; medium starts once it has been found 3 times.
- PropertyCompass2 findings go to the Navigator.
  Findings in a fleet repository go to the Quartermaster.
  Both use the same start path as the progress officer, so each office's own check delivers its requests.
- Nothing else starts.
  Medium findings seen fewer than 3 times, low findings, clusters and invalid E2E runs only get filed.
- A real security bug starts like any other at its severity, as the fleet rule wants high and critical security fixes started at once: a password hash compared with `==` or an API key logged in plaintext is a code fix, not a credential action.

## What only files, and holds for Lee

These classes never start, whatever the severity.
A finding that matches one is still filed, and the digest carries one keyed needs-decision line for the run that names it.
Each class is matched by the action it asks for, not by a word appearing anywhere, so a shallow copy or a password hash bug still starts.

- Payments or billing: any payments, billing, invoice, refund or Stripe work.
- Legal text: terms, privacy policy, cookie banner, licence text.
- Product decisions: a product decision, or changing prices, pricing, plan limits or the paywall.
- Member-facing copy: changing, updating or rewording the wording, copy or text shown to members (or member-facing copy).
- Credentials: creating, rotating, revoking or resetting a secret, API key, token or service password.
- Production actions: deploying, restarting or promoting to production, or changing production data, config or settings.
- Data-rewriting changes: dropping or renaming a table or column, updating or deleting existing rows, removing an enum value.

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
