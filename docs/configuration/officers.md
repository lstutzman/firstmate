# Officers

Part of the [configuration reference](../configuration.md).

## Officers (data/officers.md)

An officer is a role agent the primary home owns: it reads fleet records on its own cadence, writes only its findings lane, and reports one line to its first mate.
The `officer-roles` skill owns what an officer may and may never do and how its report is handled; `bin/fm-officer.sh`'s header owns the mechanics.
Every local-jev question an officer asks, and what it did with the answer, is kept as a [local-jev receipt](../local-jev-receipts.md) on the machine that ran the pass.

Officers live locally in the primary home's `data/officers.md`, one line per officer:

```text
- <id> - <role sentence> (role: <role>; cadence: daily HH:MM | every Nh; model: none; <role fields>; added YYYY-MM-DD)
```

| Field | Meaning |
| --- | --- |
| `<id>` | Lowercase letters, digits, and dashes, at most 40 characters; names the lane `data/officers/<id>/` and the check `state/officer-<id>.check.sh` |
| `role` | `triage`, `surgeon`, `landing`, `friction`, `progress`, `pagecheck`, `corpus`, or `library` |
| `cadence` | `daily HH:MM` in the home's local time: the run for yesterday's date starts at the first watcher check after that time. Or `every Nh` (N from 1 to 24): the run key is the slot `YYYY-MM-DDTHH`, slots start at local midnight and repeat every N hours until the next midnight, and the first watcher check in a slot starts that slot's run on current records. `bin/fm-registry-line-lib.sh` owns the grammar; `ensure` allows two of the officer's own periods between finished runs |
| `model` | `none`; model scoring is a later slice, and any other value is refused |
| `consumer` | Optional comma-separated `main` and office ids, default `main`; each office id must be a local office in `data/offices.md` whose `sources` lists `lane:<officer-id>`, or `lane:<officer-id>:high` only when `main` is also listed (the `:high` form wakes the office only for high or critical findings, so without `main` it would drop the other findings), and whose home has the matching `office-lane-<officer-id>` or `office-lane-<officer-id>-high` check registered by `bin/fm-office.sh register-sources`; `register` refuses and `ensure` reports a consumer that misses this, and the check then wakes main as if main were listed. The check prints the `officer <id>: ... actionable finding(s)` digest line, which wakes main, only when `main` is listed, so an office that reads the digest through its own [wake source](secondmates-and-offices.md#offices-dataofficesmd) can take it from main; the failure line is always printed |
| `archive` | Triage, surgeon and friction: the session archive directory, or `<host>:<dir>` to read it over `ssh -o BatchMode=yes`. Corpus, required: the corpus folder that holds `transcript-archive/` and `memory-harvest/`, as a directory or `<host>:<dir>` |
| `ask-days` | Friction, optional: how many days of Lee's typed messages the repeated-ask finding compares; default 7 |
| `app` | Pagecheck and surgeon, required: the fleet app's `https://` base URL, read with `GET` only |
| `rules` | Pagecheck only, optional: the file holding the standing rules (see [Page-check officer](#page-check-officer)); default this home's `data/captain-shared.md` |
| `stale-days` | Pagecheck only, optional: days a card may stay asked and unanswered before it is stale, except a Later-band or pinned card, which is never aged; default 7 |
| `remind-hours` | Pagecheck only, optional: hours before an unfixed finding is counted as new again; default 24 |
| `hosts` | Triage, surgeon and friction, optional: comma-separated hosts the archive is expected to cover; a missing one is a coverage finding. Corpus, optional: the hosts whose Bosun `last-result.json` archive counts it reads |
| `harvest` | Corpus, optional: the memory harvest's `last-result.json`, a path or `<host>:<path>`; default `memory-harvest/last-result.json` under `archive` |
| `prep` | Corpus, optional: local-jev's prep `ready.json`, a path or `<host>:<path>`; default `slartibartfast:Documents/GitHub/local-jev/data/prep/ready.json`, where the prep timer runs |
| `local-jev` | Corpus, optional: the local-jev checkout whose `results/weekly/history.jsonl` and `results/judge/` it reads, a directory or `<host>:<dir>`; default `deepthought:Documents/GitHub/local-jev` |
| `audit` | Library, optional: the librarian-audit job's `runs/` folder; default `~/fm-homes/slarti/data/librarian-audit/runs` |
| `bosun-hosts` | Friction, optional: comma-separated hosts whose Bosun `last-result.json` the `bosun-unsure` class reads over `ssh -o BatchMode=yes`; unset turns the class off |
| `captains-log` | Optional `https://` URL ending `/api/captains-log`: friction reads its cards with one `GET`, and its tap replies with one `GET <url>/replies`, and reports either unreachable as a coverage gap; progress uses its corresponding `/captains-log` page URL to link existing held cards without copying their questions |
| `facts` | Landing only: the fleet-app landing-truth facts file (`schema_version` 2 with exactly the top-level keys `schema_version`, `generated_at`, `staging_sha`, `production_sha`, `records` keyed `<repo>#<pr>`, and `items` mapping each Linear id to its record keys; any other version or layout fails the run), as a path, `<host>:<path>` read over `ssh -o BatchMode=yes`, or an `https://` URL |
| `team` | Landing, progress, surgeon, friction, corpus, library and pagecheck, optional: the Linear team key to read (a surgeon, friction, corpus, library or pagecheck officer that writes must use `PC`); default `PC` |
| `repos` | Progress only, required: comma-separated GitHub `owner/repo` names whose open PRs prevent duplicate starts |
| `requested` | Progress only, optional: comma-separated Linear root identifiers for features or fleet work Lee has already requested; children inherit that recorded authority at any depth |
| `writes` | Landing, optional: `corrections` (default) lets the officer reopen false-Done items and report release-path misses (every linked PR in production but the item not Done or Released) with one comment each on PC-4688, never writing Done or Released; `none` turns Linear writes off |
| `max-corrections` | Landing only, optional: the most items one run may reopen or report as release-path misses; default 10. A miss already reported for the same item and PRs is not re-checked or counted. An item skipped on its re-check does not count, and a run re-checks at most five items per allowed correction |
| `reopen-state` | Landing only, optional: the state a Done item moves to when its linked PR never reached main (`on_main` false) or any release; default `In Progress`; `In Staging`, `Done` and `Released` are refused. A Done item on main but not yet in production is release lag and is only reported |
| `max-facts-age` | Landing only, optional: the oldest facts, in hours since their `generated_at`, the officer writes to Linear from; default 36. Older or missing `generated_at`, or facts with no `production_sha`, make no Linear write and raise a `stale-facts` finding |
| `done-window` | Landing only, optional: how many Linear Done items one run lists, in one paged read, to find Done items no landing fact names; default 100, and 0 skips that read |
| `start-home` | Progress, surgeon, friction, corpus, library and pagecheck, optional: comma-separated office ids. Each must pass the same checks as a `consumer` office, because the office's own lane check delivers the start requests for its projects, except that a `lane:<officer-id>:high` source needs no `main` consumer, since that check delivers them either way; a request whose project is in that office's `dispatch:` list is addressed to that office's home instead of this one; the surgeon treats a request with no project as PropertyCompass2 work, and for the progress officer a request with no project (every Top of Mind ask, and every Linear-only item, whose `project` is a Linear project rather than a repository) is placed in this order: the repository of a linked GitHub URL, a project name in the ask's words, a Linear id in the officer's team (PropertyCompass2), each matched against the offices' `dispatch:` projects, then the ask's source (a "Start fix:" tap, a velocity or friction finding, goes to the office whose `role` is `quartermaster`), where the first of these that names any office decides and one that names two offices is ambiguous; when none does, local-jev, the local classifier (the local-jev skill's `jev.py`, or the script named by `FM_LOCAL_JEV`), which is sent only the ask's words, picks among the offices' roles (no `main` option; each described for the role and its `dispatch:` projects), the pick must reach confidence 0.7, and one more local-jev question keeps the ask with this home when it concerns neither the PropertyCompass2 app nor the agent fleet (below 0.2 it fits no office scope). Every ask placed either way then gets two local-jev hold checks, each keeping it with this home: whether it is a constraint, answer, approval or decision rather than a request for work (0.85 or more; skipped for a "Start fix:" tap, the captain's own start), and whether it is a change to pricing, legal text, payments or spending (0.85 or more). Any other outcome, including an unreachable local-jev (after which the run stops asking it), leaves the request with this home and records an `unrouted` reason on it, with no cloud model call. An office that fails those checks gets no requests, so its projects' requests stay with this home |
| `run-host` | Corpus and surgeon, optional: an ssh host name on which `run` executes the role pass instead of this machine; this home still decides and starts every run, and the host keeps no timer, check or registration. The host's firstmate checkout must be at the same commit as this home's, else the attempt fails `host code mismatch`; before that check a checkout that is behind is fast-forwarded, after fetching the host's code root (`~/Documents/GitHub/firstmate`) from its origin, and one that is dirty, diverged, ahead, on another branch than the default, or whose commit is not on that origin is left untouched and fails with the cause (`preflight` reports a behind checkout without fetching or moving anything); an unreachable host fails it as `run host unreachable` and never falls back to a local run. A line with `rubric`, `visual-findings` or `visual-captures` (files in this home) is refused, as is `run-host` on any other role until the home-file mirror is extended for friction, pagecheck and progress (phase 2). Absent, the pass runs here as before; `bin/fm-officer.sh`'s header owns the mechanics and what the pass reads from where |
| `run-host-code` | With `run-host`, optional: the host's firstmate checkout, a plain path relative to its home directory or absolute; default `fm-homes/<run-host>` |
| `writes` (surgeon, friction, corpus, library, pagecheck, progress) | Surgeon, friction, corpus, library, pagecheck and progress, optional: `none` (default) files nothing; `linear` files Linear items as described under [Surgeon](#surgeon), [Friction officer and Linear](#friction-officer-and-linear), [Corpus officer](#corpus-officer), [Library officer](#library-officer) and [Page-check officer and Linear](#page-check-officer-and-linear) (a friction, corpus or library officer starts nothing without it); a progress officer files nothing, and `linear` only lets it raise the priority of the officer-filed items it starts, see [Progress officer](officers-progress.md#progress-officer) (`max-creates` does not apply to it) |
| `max-creates` | Surgeon, friction, corpus, library and pagecheck, optional: the most new items one run attempts to create (bundles and single items, not bundle updates or found-count edits); default 100. A failed create counts only once its dry run passed. The library officer counts per audit run, defaults to 3 and holds a larger value to 3 |
| `bundle-cap` | Surgeon, friction, corpus, library and pagecheck, optional: the most open findings one bundle item holds before the area's next finding opens the next part; default 15, at least 1 ([bundles](../officers/contract.md#bundles)) |
| `max-linear-calls` | Surgeon, friction, corpus, library, pagecheck and progress, optional: the most `linear-axi` calls one run makes; default 450. The run stops its Linear work there, names what is left, and the next run continues; it is not a rate-limit pause |
| `triage-label` | Surgeon, optional: the team PC label an item gets when no area label fits its file path or component; default `triage`. A label missing from team PC means the finding is reported and not filed |
| `jev` | Surgeon, friction, corpus, library and pagecheck, optional: the local-jev helper used for duplicate checks; default `~/.claude/skills/local-jev/jev.py`. Without it only the fingerprint decides |
| `rubric` | Surgeon, friction, corpus, library, pagecheck and progress, optional: the rubric file; default `docs/officers/surgeon-rubric.md`, `docs/officers/friction-rubric.md`, `docs/officers/corpus-rubric.md`, `docs/officers/library-rubric.md`, `docs/officers/page-check-rubric.md` or `docs/officers/progress-rubric.md` |
| `visual-findings` | Surgeon, optional: the absolute path of the nightly visual review's findings file on this machine (PropertyCompass2 `scripts/visual-review/README.md` owns the format; only version 2 is read). Without it the visual source is off. A configured file that is missing, unreadable, of another version, unchanged since the last run, or reporting review errors or failed, deferred or dropped images is a `Coverage gap:` line |
| `visual-captures` | Surgeon, optional, needs `visual-findings`: the absolute path of the capture directory the findings file's `screenshot` paths are relative to, so an item can name a screenshot's real path and the Surgeon can attach it with `linear-attach` |
| `area` | Surgeon, no longer used: accepted and ignored, because each item's area label now comes from its finding |
| `staging-repo` | Surgeon, optional: the git remote whose `refs/heads/staging` is the staging tip, read with `git ls-remote`; default `git@github.com:lstutzman/PropertyCompass2.git`, and an empty value is refused |

Example:

```text
- triage - Joins each day's archived sessions to firstmate tasks and outcomes (role: triage; cadence: daily 06:00; archive: deepthought:/srv/pc-corpus/transcript-archive; hosts: slartibartfast,macbook,deepthought,mac-mini; model: none; added 2026-10-24)
- landing - Reconciles Linear against landing evidence (role: landing; cadence: daily 06:30; facts: slartibartfast:/home/lee/services/landing-truth/latest.json; team: PC; writes: corrections; model: none; added 2026-10-24)
- surgeon - Joins archived sessions to tasks, then reads the nightly runs and the bug sweeper and files untracked real findings in Linear (role: surgeon; cadence: daily 06:00; archive: deepthought:/srv/pc-corpus/transcript-archive; hosts: slartibartfast,deepthought; app: https://fleet.example.ts.net; team: PC; writes: linear; max-creates: 100; max-linear-calls: 450; consumer: main,navigator; start-home: navigator,quartermaster; model: none; added 2026-11-04)
- friction - Finds what slowed agents down, above all waits on Lee, files each in Linear and starts the standing-work fixes (role: friction; cadence: daily 06:15; archive: deepthought:/srv/pc-corpus/transcript-archive; hosts: slartibartfast,macbook,deepthought,mac-mini; team: PC; writes: linear; max-creates: 100; max-linear-calls: 450; consumer: quartermaster; start-home: quartermaster; model: none; added 2026-10-24)
- progress - Starts authorised unstarted work through firstmate (role: progress; cadence: daily 07:00; team: PC; repos: example/project; requested: PC-123; writes: linear; max-linear-calls: 450; start-home: navigator,quartermaster; model: none; added 2026-10-26)
- page-check - Checks every fleet-app page for cards a standing rule settles, stale cards, cards shown after they were settled, and old pages (role: pagecheck; cadence: every 2h; app: https://fleet.example.ts.net; writes: linear; start-home: quartermaster; model: none; added 2026-10-31)
- corpus - Checks the agent training corpus is complete, scrubbed and current: archive coverage, the memory harvest, local-jev's data and retrains (role: corpus; cadence: daily 08:15; archive: deepthought:/srv/pc-corpus; hosts: slartibartfast,deepthought; team: PC; writes: linear; max-creates: 100; max-linear-calls: 450; model: none; consumer: alchemist; added 2026-11-05)
- library - Judges the weekly librarian audit: what is safe to ship and what needs Lee (role: library; cadence: daily 11:30; team: PC; writes: linear; max-creates: 3; max-linear-calls: 450; model: none; consumer: librarian; start-home: navigator; added 2026-11-05)
```

After adding a line, run `bin/fm-officer.sh register <id>` to install and trust its watcher check; `bin/fm-officer.sh retire <id>` removes the check and the line and keeps the findings.
Session start runs `bin/fm-officer.sh ensure`, which prints one `OFFICER:` line per gap.
After giving a line `run-host`, and before its next scheduled run, run `bin/fm-officer.sh preflight <id>`: it checks, read-only, that the host can carry that officer's pass, prints one `ok` or `FAIL` line per check and exits non-zero on any failure (the script's header lists the checks).
A second mate home never runs officers: `register` and `run` refuse there, and `ensure` reports any registry it finds.
The friction officer also writes `<date>.velocity-findings.json`, a fleet-app velocity findings file (`FINDINGS_SCHEMA` schema version 1, source `friction-officer`) for the velocity audit page (`/runs/velocity-audit`); it never posts that file itself.
Fix-forward evidence is a second velocity source: the ship brief's rule 9 has a worker whose PR fixes a regression from an earlier merged PR put one line, `Fixes-regression-from: <full PR URL>`, in its body, and `bin/fm-fix-forward-count.sh` counts, per fleet merge-table repository over the last 7 days, the merged PRs, those carrying the line, and reverts (titles starting `Revert`), as text or with `--json`.
The fleet fixes forward, so reverts alone read near zero; the linked fixes show whether merge-on-green is letting regressions through.
The counter is read-only (`gh repo view` and `gh pr list`) and is not yet scheduled, and the script header owns its options.
Each finding in it carries a stable `id`, its `events` count, a read-only `state` and the `actions` the page may draw for it; the file carries `totals` of the day's events and findings, and `bin/fm-officer-friction.py`'s header owns how the state is read.
`state` is one of `open` (action `start-fix`), `started` (carries `link` and `task` when known, or `reopen: true` when neither is, which offers `reopen`), `fixed` (carries `fixed`: `{link, merged_at}` of the merged fix), `reported-again` (the fix merged and the finding was seen after it; carries `fixed`, offers `start-fix`), `started-by-default` (offers `object`; carries `request_id`) and `settled` (carries `rule`: `{text, source}`, the standing-rule line quoted and where it sits).
A finding whose fix is standing work (fleet rules section 2: a velocity finding goes ahead unless Lee objects within a day, reserved classes excepted) is never offered a bare Start fix: it is `started-by-default`, and the digest's `start_requests` (also written as `<date>.start-requests.sh` for this home) hold the start note for the `start-home` office whose `dispatch:` list names the fleet repositories (the Quartermaster), else this home, delivered by that office's lane check like a progress start; it needs `writes: linear` and the finding's Linear item (see [Friction officer and Linear](#friction-officer-and-linear)).
An `Object` reply on the finding's card keeps it from starting by default.
The same pass handles the fleet app's velocity-audit card taps, so main no longer relays them by hand: a Captain's Log reply on a `velocity-vs-<yyyymmdd>-<n>` card is read from the replies feed the officer already reads, and `bin/fm-velocity-taps.py`'s header owns what each choice does.
`Create item for later` (older `Accept`) files the Linear item (Improvement, Source agent, `area:fleet`, project Fleet, keyed by the suggestion id so a repeat tap files nothing twice) and answers the reply with its id through `fleet-axi captains-log ack` then `answer`, which is how the page shows "firstmate has it" and the Linear id.
`Create and fix now` does the same and adds one start note for the card's `owner`: the `start-home` office whose role is that owner (the Quartermaster, in practice), else main, which names the owner when it is slarti, deepthought, gilligan, Lee or not recognised, or when the suggestion matches a reserved class.
The note is a `start_requests` row in the digest, delivered by the office's lane check like any friction start.
`Let's discuss` leaves one note for main and files nothing, and the reply stays unanswered until main answers it after the conversation.
`Not for us` (older `Reject`) is only acknowledged, and `Object` sends the owning office one keyed note naming the card so it stops its work.
It needs `writes: linear` and a `captains-log` URL on the officer's registry line, runs only when a velocity reply was read, files and calls within what the Linear pass left of the run's `max-creates` and `max-linear-calls` (its calls count in the digest's Linear total), and runs with the friction officer's cadence, so a tap is handled at its next run.
A line in a home's `data/captain-shared.md` that says "standing rule" or "standing exception" settles a finding only when it names the finding's `id` (alone or as `friction-<id>`) or its key written `settles: <cause>/<sub>`, for example `settles: policy/merge-word`; a finding about one tool, hook or service also needs the line to name it, or the key written `settles: <cause>/<sub>/<name>`. No looser wording settles a finding.
The fleet app pulls the file from the officer's lane, a fleet-app follow-up that Slarti owns.
With `bosun-hosts` set, the friction officer also runs the `bosun-unsure` class: it answers the Bosun's `rule-settles` unsure items from fleet rules section 6 and writes the answers to `bosun-answers.json` in its lane, never into the velocity file, which fleet-app pulls.
A file or log item that is a session log or transcript is answered keep, never delete; a branch or copy item is never treated as one. It lists the items no rule settles in its digest for the Quartermaster and reports an unreachable host as a coverage gap there, never in the velocity file; `bin/fm-officer-friction.py`'s header owns the answer shape and rules.
Each branch or copy answer carries the full `sha` it was decided on; the Bosun must refuse an answer whose `sha` no longer matches the tip or HEAD it finds, and re-check live worktrees, open pull requests, unpushed work and uncommitted or untracked work itself before a delete (the script header owns the contract).
The officer itself reads a copy's `git status --porcelain` before it answers delete, and keeps any copy with uncommitted or untracked work; as in the Bosun's own rule c check (fleet-app `src/bosun/cleanup.ts`), that excludes git-ignored files.
The Bosun reading `bosun-answers.json` is a fleet-app follow-up.
The triage and friction officers read this home and each local second mate home in `data/secondmates.md`, read-only; turning on the [fleet activity ledger](../configuration.md#fleet-activity-ledger-configfleet-ledger) and [trace context](../configuration.md#trace-context-propagation-configtrace-context--fm_trace_context) lets them resolve tasks that were already cleaned up.

### Surgeon

The Ship's Surgeon is the triage pass plus intake.
It files, dedupes, scores and starts through the shared library `bin/fm-officer-linear.py`, whose contract every officer follows: [`docs/officers/contract.md`](../officers/contract.md) owns it.
`bin/fm-officer-surgeon.py`'s header owns the classification tables and severity rules, `bin/fm-officer-linear.py`'s header owns the Linear steps, and [`docs/officers/surgeon-rubric.md`](../officers/surgeon-rubric.md) owns what counts as work, how it is scored, what starts and what holds for Lee; `bin/fm-officer-triage.py` stays because the friction pass imports it.
Its digest keeps the session join's findings under `archive_findings` and puts the intake findings in `findings`, so a `severity: high` (or `critical`) there, which the `lane:surgeon:high` [wake source](secondmates-and-offices.md#offices-dataofficesmd) counts, means a high intake finding and never an archive coverage gap.
Intake reads the fleet app with `GET` only: `/api/runs`, the latest result of each live nightly E2E or code-review job, and `/api/sweeper-results`.
A red nightly E2E finding is high only when its run's `sha` is the current staging tip, and medium for an older run; an unreadable tip or a result with no `sha` rates it medium and adds a coverage gap.
An invalid nightly E2E run (the run itself broke) is one critical, promotion-blocking item per job while it stays invalid; each day bumps its Found line.
A sweeper bug whose `environment` is production moves up one severity step; the environment comes from the bug or, since `/api/sweeper-results` carries none, from the cluster in the sweeper's own run bundle (`<run id>/bundle.json` under `$PC_SWEEPER_RUNS`, default `~/services/pc-sweeper/runs`). Text is never read for the word, so a cluster with no `environment` from either source gets no bump and the digest names a coverage gap.
A sweeper cluster whose newest `last_seen` is more than 3 days before the run is stale: won't fix, never offered as fresh ([surgeon-rubric.md](../officers/surgeon-rubric.md)).
A finding the source already put in Linear is `tracked` and never filed again; for a sweeper cluster that includes an item an earlier sweeper run filed or updated, read once per run from `/api/sweeper-results/<run id>` and kept in the lane's `review-state.json`, and an earlier run that cannot be read is a coverage gap and is read again next run.
With `visual-findings`, intake also reads the nightly visual review's findings file: a `defect` is a real finding at the file's severity, one per fingerprint with every screenshot listed, filed like the others but never started; anything else (the wording and product rubric items) is held for Lee as one keyed needs-decision `surgeon-visual-held-<date>` and is neither filed nor started.
With `visual-captures`, the bundle a defect is newly added to also gets each of its screenshots attached through `linear-attach`; a failed attach is a coverage gap and is retried on later runs for 7 days ([surgeon-rubric.md](../officers/surgeon-rubric.md) owns the rules).
A real finding whose source gave no key is fingerprinted from its normalised title plus location.
With `writes: linear`, the Surgeon files each real, untracked finding in team PC as a line on its source family's feature-area [bundle](../officers/contract.md#bundles); an invalid nightly E2E run keeps a single item of its own.
Each item has the type Bug, one Source (`scheduled-review` or `bug-sweep`; a visual-review defect is `scheduled-review`) and one area label derived from the finding (the `triage-label` when none fits).
Fingerprinting, duplicate detection, the `Found:` line, recurrences of closed items and what the Surgeon never touches are the shared [filing rules](../officers/contract.md#file); its own bundles are the only text it edits besides the Found line.
`bin/fm-officer-surgeon.py fold --out <lane>` plans folding the Surgeon's existing open items into bundles; only `--apply` writes ([surgeon-rubric.md](../officers/surgeon-rubric.md)).
Every Linear call is counted against `max-linear-calls`.
One rate-limit answer from Linear stops the run's Linear calls and writes `linear-resume-after.json` in the lane; runs before that time make no Linear call.
The lane also keeps `bundles.json` (each bundle's item and lines), `review-state.json` (the weekly burn-down), `found.json` (found counts, each bundled finding's under `members`) and `patterns.json`.
The digest adds a weekly burn-down line (open, new and fixed reviewer findings), the start requests, one keyed needs-decision line for findings held in a reserved class, one capped-repeat start request (kind `surgeon-fix-cap`) to the start-home office for each finding stopped after 3 started fixes ([surgeon-rubric.md](../officers/surgeon-rubric.md)), which the office hands to Lee as a keyed needs-decision instead of a fourth fix, and the bad patterns found.
Pattern memory keeps every bad pattern in `patterns.json` but hands one on (the Navigator start request, the memory capture and the lint proposal) only once it has a stated safe form and has been seen on at least two findings.
A pattern line is whole sentences, built from the finding's full title and fix and cut at a sentence or clause boundary, never at a character count, and it never carries a placeholder for a missing fix.
A one-off pattern, or one whose findings never state a fix, stays in the store and counts up; it is handed on the run it first recurs with a fix.
A line stored by an older version (clipped or placeholder) is rebuilt from the next matching finding and its reported and captured marks are cleared, so it is handed on once it qualifies, never re-sent as it was.
Real critical and high findings, and medium findings found at least 3 times, that the rubric admits are written as `start_requests` in the dated JSON, the same shape the progress officer uses, so `start-home:` offices deliver their own and this home's go in the adjacent `<date>.start-requests.sh`.

### Corpus officer

The corpus officer checks the agent training corpus for its office, the Alchemist, which sees counts, manifests and digests only.
It reads the transcript-archive ingester's results, the memory harvest's result, local-jev's prep store and weekly retrain history, the judge's result names, and each `hosts` machine's Bosun archive counts.
It never opens, prints, copies or parses a transcript, a corpus row or a harvested memory record: for a `<host>:<path>` input it sends its own script to that host over `ssh -o BatchMode=yes`, and only the documented counts, timestamps and names come back.
`bin/fm-officer-corpus.py`'s header owns the inputs, the fields read and the finding classes: a source not collected for two runs, an archive gap on two Bosun nights, a failed or drifting harvest, a stale prep store, and a missed weekly retrain.
Each finding is reported once by its fingerprint in the lane's `reported.json`, and the lane's `nights.json` remembers each Bosun night's gap count.
An unreachable host or a missing file is a coverage gap, never a failed run; a missing memory harvest result is a coverage note, because the officer could not read the harvest.
With `writes: linear` it also files under the shared [officer contract](../officers/contract.md), and [`docs/officers/corpus-rubric.md`](../officers/corpus-rubric.md) owns what counts as work, how it is scored, what starts and what holds for Lee; `bin/fm-officer-corpus.py`'s header owns the mechanics.
It reads the registry's `writes`, `team` (`PC` only), `max-creates`, `bundle-cap`, `max-linear-calls`, `jev`, `rubric` and `start-home`.
Each open finding becomes a line on its class's [bundle](../officers/contract.md#bundles), a Chore in team PC, in the Fleet project with `area:fleet` (Source `agent`, marked `corpus-fp:<sha256>`), and its found count rises once a night; a line holds only the finding's class, subject, severity, repository and scan-gate note, never a transcript, a corpus row or a memory record.
A finding whose score reaches the rubric minimum is written to `start_requests` (digest `source` `corpus-officer`) for the `start-home` office whose `dispatch:` list names its repository (`transcript-archive` or `local-jev`), else this home, since no office dispatches either until the Alchemist is registered; an office's lane check delivers it.
A request for a finding whose fix may touch the scan gate files (an archive gap, a failed or drifting harvest) names the scan-gate route: the corpus-owning office never merges that pull request, and it goes to Slarti on a fresh reviewer's no-loosening record.

### Library officer

The library officer judges the weekly librarian audit for its office, the Librarian; the fleet-app `librarian-audit` job collects, and the officer only judges.
It reads the newest dated run folder under `audit`, that run's `result.json` and `findings.json`, and nothing else.
`bin/fm-officer-library.py`'s header owns the rules that put each finding in one bucket: needs Lee, safe to ship, code work, or on hold; the run's decisions for Lee are one needs-Lee item.
Each item is reported once by its fingerprint, and its digest line counts the new items outside on hold.
It has no Library staleness input while Markdown-to-HTML conversion is skipped.
With `writes: linear` it also files under the shared [officer contract](../officers/contract.md), and [`docs/officers/library-rubric.md`](../officers/library-rubric.md) owns what counts as work, how it is scored, what starts and what holds for Lee; `bin/fm-officer-library.py`'s header owns the mechanics.
It reads the registry's `writes`, `team` (`PC` only), `max-creates` (default 3, the fleet rules section 8 cap per audit run, not per day; a larger value is held to 3), `bundle-cap`, `max-linear-calls`, `jev` and `start-home`.
Each new safe, code and needs-Lee finding becomes a line on its audit kind's [bundle](../officers/contract.md#bundles), a Chore in team PC (Source `scheduled-review`, marked `librarian-fp:<sha256>`), grouped by path, and its found count rises once per audit run; the cap of 3 counts new bundle items.
A safe finding whose score reaches the rubric minimum is written to `start_requests` (digest `source` `library-officer`) for the `start-home` office that dispatches PropertyCompass2 (the audit covers PropertyCompass2 only, so no finding goes to the Fleet project), else this home, and an office's lane check delivers it; needs-Lee items become one keyed needs-decision per audit run.

### Page-check officer

The page-check officer keeps the fleet app's pages current without Lee asking.
It is a role of its own rather than part of the friction officer because it reads live pages every few hours, while the friction officer needs a harvested archive day and so can only run once a day; the friction officer still owns Lee's repeated asks (below).
`bin/fm-officer-page-check.py`'s header owns the checks and the table of pages with their normal gaps.
It only reads: one `GET` per page through `curl`, this home's status logs, and `gh-axi api GET` for the state of a PR a card names.
Its only writes are the Linear filing and the closing of its own settled or unrecurred items, described under [Page-check officer and Linear](#page-check-officer-and-linear), and only with `writes: linear`.

Its findings are one of four kinds, each naming the page and the object so firstmate can route the fix:

| Kind | Meaning | Routed to |
| --- | --- | --- |
| `standing-rule` | A card Lee is shown that a standing rule already settles | cl-keeper closes it citing the rule |
| `stale-card` | A shown card that is past its snooze date, unanswered for `stale-days` (never a Later-band card, which cl-keeper parked on purpose), already answered, naming a closed PR or a merged PR that the card's ask is about, or settled by a later `resolved` status line; a card that names a merged PR but asks for something else (a Linear status, a production or activation action), or whose captain has not answered, is not stale (the script header owns both exceptions) | cl-keeper closes or corrects it |
| `shown-after-done` | A card shown although its record is settled: a status line resolved by a captain answer before the card was raised again (a routing resolve does not count), or the app's own card record for the Bosun source is closed | cl-keeper closes it; the source that re-raised it is fixed |
| `page-old` | A page older than its normal gap (Bosun's results: 26 hours), never published, unreachable or unreadable (including JSON of an unexpected shape), a live Runs job whose health is failing, or a live Runs job whose latest finished run has no summary (a run still in progress is not itself judged, and a never-run job is not flagged) | the page's owner fixes the feed |

Standing rules are lines in the `rules` file of the form `- standing-rule <id> /<regex>/ - <rule text>`; the case-insensitive regex is matched against a card's words, and every other line of the file is ignored.
A rule becomes a check by adding one such line next to its prose in `data/captain-shared.md`.
A rules file with no such line is a coverage note in the digest, because the `standing-rule` check then covers nothing.

The run keeps `state.json` in its lane, when each finding was last reported.
Its digest line counts only findings not reported in the last `remind-hours`, so an unchanged page set is silent every slot while a finding nobody fixed returns daily.
The digest file lists every open finding, the new ones marked.
An unreachable app is a finding, not a failed run.

### Page-check officer and Linear

With `writes: linear` the page-check officer follows the shared [officer contract](../officers/contract.md) with its rubric [`docs/officers/page-check-rubric.md`](../officers/page-check-rubric.md), which owns what counts as work, how a finding is scored and what starts.
Every open finding is filed once in team PC, project Fleet, with the labels Bug, `agent` (Source) and `area:fleet`, as a line on its page's [bundle](../officers/contract.md#bundles), grouped by route; a finding seen on a later day raises its own found count, which is the priority lever.
A finding whose bundle or older single item a person closed is not filed again and never starts.
The shared [filing rules](../officers/contract.md#file) own duplicates, recurrences and the call budget, and the item names a card by its id and never carries the card's words.
A `page-old` or `shown-after-done` finding whose item exists is handed to the Quartermaster as a start request; that routing needs `start-home: quartermaster` on the registry line, as in the example above, and without it the request goes to the home running the officer.
A `standing-rule` or `stale-card` finding is filed so its card is cleared and never starts a fix.
The reserved-class check judges what the started fix would change, so it reads the finding's own kind, page, evidence and route, and the object id only when the object is the fix target (a page or a Runs job), never a card's id or question; a finding whose fix is in a reserved class is held as one keyed `needs-decision` line in the digest.
A `page-old` or `shown-after-done` finding is a bug, so its bad pattern (the kind and the page or Runs job, with the route as the safe form, and no timestamps or card id) is remembered once and handed on in the digest's `patterns` and one batched pattern-memory start request.
The officer also closes a single item it filed itself once its card settles or its finding has not recurred for two checks; [the rubric](../officers/page-check-rubric.md#closing-its-own-items) owns the conditions.
Without `writes: linear` nothing is filed, closed or started.
`bin/fm-officer-page-check.py`'s header owns the filing and the start requests.

### Friction officer and Linear

With `writes: linear` the friction officer follows the shared [officer contract](../officers/contract.md) with its rubric [`docs/officers/friction-rubric.md`](../officers/friction-rubric.md), which owns what counts as work, how a finding is scored and what starts.
Every finding that is not a product choice or a retired tool, settled, started or fixed is filed once in team PC, project Fleet, with the labels Improvement, `agent` (Source) and `area:fleet`, as a line on its category's [bundle](../officers/contract.md#bundles) (tooling, waiting, environment or other); a repeat night raises the finding's own found count, which raises its score.
A bundle's start is one request that carries each started-by-default finding's start marker and asks for every friction id on it in the task's backlog line, so each finding reads back as started and its merge is read back.
The shared [filing rules](../officers/contract.md#file) own duplicates, recurrences and the call budget, and the item body holds counts and identifiers only, never a transcript line.
The Source label is `agent`, from Lee's Source set, and the officer never creates a label: a finding is reported and not filed while a label is missing from team PC.
A standing-work finding (the groups fleet rules section 2 starts by default) whose item exists is handed to the Quartermaster as a start request, and a finding in a reserved class is held as one keyed `needs-decision` line in the digest.
Without `writes: linear` nothing starts by default, each card offers Start fix, and the digest names the gap.
`bin/fm-officer-friction.py`'s header owns the finding states and the start requests.

### Repeated asks (friction officer)

The friction officer also compares Lee's typed instructions across the last `ask-days` days of the session archive (interactive and worker sessions, never a worker's launch brief, which quotes him).
Only text Lee typed counts: a user-role record the harness injected, such as a peer or agent message, hook context, a tool result, a sub-agent prompt or a compaction summary, is skipped, as is guidance the harness wraps into a typed message (such as a `<system-reminder>` block), so Claude Code's own built-in text is never read as Lee repeating himself; `typed_text` in `bin/fm-officer-friction.py` owns the exact markers.
It sees only what the archive holds: a message Lee gave somewhere that is not archived as a Claude Code transcript is not counted.
Each instruction is dated by its own message time in the archive's timezone, not by the day whose manifest lists the session, and a session listed on several days is read once, so one long chat holding asks on different days counts each ask on the day Lee gave it.
An instruction given on two or more days, one of them the run's day, becomes a `repeat-ask` finding with Lee's scrubbed sentence for each day, so a repeat becomes automatic work instead of Lee repeating himself.
Instruction words such as make sure, need, should, always, never and please are not content words, and neither are the "up" of "up to date" or common dictated-speech words such as want, know, think, really, hey, okay, actually, thing and stuff.
Two instructions are the same when they share at least three content words and at least 70% of the shorter one's words.
They are also the same when both ask for upkeep and share at least two other content words: keep, update, current, date, fresh, maintain, look, check, review, watch, track, monitor and stale, and their -ed and -ing forms, all count as one upkeep word.
So "keep the captain's log up to date" and "make sure the captain's log keeper is looking at all pages" are one instruction, while "make sure the captain's log renders on mobile" asks for no upkeep and is not.
Session text stays on the machines that already hold it and is never sent to a model or service.
