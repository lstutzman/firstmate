# Progress officer reference

Part of the [configuration reference](../configuration.md).

### Progress officer

The progress officer finds unstarted work and initiates it through executable requests firstmate runs under Lee's standing authority of 2026-10-26.
It reads this home's and every registered local or remote second mate home's Markdown backlog and task status, Linear issues and their parents, open PRs in `repos`, and the fleet app's Top of Mind asks.
Remote home reads run the same read-only scanner over SSH.
Each run reads Top of Mind once over HTTPS; the progress script's header owns endpoint selection and timeout.
A fetch or payload failure adds a `Top of Mind coverage-incomplete` entry and contributes no asks from that source; the officer never reuses cached asks or blocks other discovery on that failure.
Each row's `kind` is `ask` or `statement`; a row without `kind` is an ask, and any other value fails payload validation.
A statement never becomes a start candidate, supplies no `requested-feature` authority, and names no requested roots; it only adds evidence to work it matches.
Every `not-started` ask and every `under-way` or `waiting` ask is checked against current home records and open PRs.
A waiting ask is listed with the reason `waiting (Top of Mind status)` and is never automatically started.
A not-started or under-way ask with no recorded work in flight becomes a start candidate under the existing classes and exclusions; a matching task, Linear identifier, work title (ignoring punctuation and case), or link joins the ask to that work instead of creating another start, and a matching Linear issue joins the ask to every home record that links that issue.
Team Linear identifiers named anywhere in a fresh ask are read as requested-root subtrees for that run.
The digest's Top of Mind section lists each ask's start request or its reason for waiting, including the held task, active task or PR, other owner home, or completed or unknown work.
Matched work keeps its own owner home and disposition.
Unmatched work naming a scanned home, by path or directory name, is attributed to that home; unmatched work naming any other home is listed with that home's name for routing rather than started.
The cursor-paginated team listing reads open issues only (triage, backlog, unstarted, and started) and supplies each issue's state, priority, URL, project, and description, which the listing cuts at 200 characters.
Only requested-root subtrees receive full issue and child reads, retaining completed intermediate parents; before any Linear-backed item starts, its full description and parent chain are read in rank order, and a candidate whose read fails or exceeds the request budget is not started and is named as a coverage gap without deferring the candidates that were checked.
Only identifiers that match the configured `team` key, such as `PC-123`, count as Linear links; other tokens of that shape, such as `CVE-2026-12345`, are ignored.
Linear's unblocked listing, read for backlog and unstarted issues only, supplies dependency exclusions.
The dated JSON's `linear_coverage` records pages fetched, items seen, CLI requests, hierarchy reads, rate-limit retries, listed descriptions left truncated, and start candidates left unverified; the digest and run log print the same counts and specific failure causes.
The request budget counts `linear-axi` invocations, not Linear API calls: the CLI fetches each listed issue's state, team, assignee, and project separately, so a 100-item page costs about 300 to 400 API requests.
The progress script's header owns request, page, and backoff bounds, including the CLI's unpageable sub-issue limit.
`linear-axi` reports every Linear limit as `RATE_LIMITED` with no reset time, so after the short 30, 60, and 120 second backoff a fourth consecutive limit counts as the hourly quota exhausted: the run stops Linear reads at once, names the gap with a resume time one hour later, and records it in the lane's `linear-resume-after.json`.
Later runs skip Linear discovery, naming that gap, until the resume time passes.
A capped or failed Linear read is a per-item coverage gap: checked items still produce start requests, while items whose full description or parent checks fail remain excluded and are named in coverage.
A missing or unreadable registered home, an unsupported non-Markdown backlog, or open-PR discovery that fails for every configured repository leaves the duplicate-start check unable to pass for any item, so that run emits no start requests and its coverage names the reason.
Each repository's open-PR list is read once per run.
A blank answer is a repository with no open PRs. A rate-limited answer is retried with 2, 8, then 30 second waits, and any other failed listing is retried once.
A repository that still fails holds only its own starts, and its coverage entry and the run log name that repository and its redacted cause.
A start's repository is its project, else the one the office routing rungs name, with each configured repository standing in for an office: a linked repository, the repository's name in the text, or a team Linear id for PropertyCompass2. A team item in the Fleet project or with the `area:fleet` label is claimed by no repository for this check.
While any repository's list is missing, a start that no repository claims is held too and named in each gap's coverage entry.
Filler waits for complete coverage.
The installed `linear-axi` cannot return or filter issue labels, so the officer reads them from Linear's GraphQL API with the fleet credential from `linear-token header --print-to-pipe`, never printing it.
One filtered query returns the open team issues that carry a start-class label (`security`, `security-scan`, `scheduled-review`, `Bug`, `bug-sweep`), with all of their labels.
A failed label read is named as `Linear labels unavailable` with its cause, and filler waits for it.
A requested root that cannot be read skips only its own subtree and is named; a stopped run (request budget, deadline, or quota) still ends the hierarchy reads.
The pass reads current records; the common officer scheduler's date names the run rather than a historical snapshot.

### Progress officer triage

The progress officer follows the shared [officer contract](../officers/contract.md) with its rubric [`docs/officers/progress-rubric.md`](../officers/progress-rubric.md), which owns the triage rules; it finds no work and files nothing in Linear.
Before it writes the start request for an item another officer filed (the description carries that officer's `<officer-id>-fp:<sha256>` marker), it names the owning office, the Navigator for PropertyCompass2 and the Quartermaster for the Fleet project, and sends the request to that office's home.
With `writes: linear` it also raises the item's Linear priority from its score (the severity fixed when the lane first saw the item, from the filer's `Severity:` line or else what its priority then stood for, times log2(1 + the `Found:` line's count): 8 or more is Urgent, 4 or more High, else Medium), through `linear-axi` `--dry-run` then `--verify`, within `max-linear-calls`.
It only raises a priority, and never touches an item that is assigned or whose priority differs from what the lane's `triage-state.json` last recorded, which is how a person's change shows.
The ranked list re-sorts on the new priority, and each request carries a `triage` record (filed by, severity, found count, score, priority before and after, the action).
Only an item read in full (`issue view --full`, which carries its assignee) is triaged; any other is a named coverage gap, and is still held for Lee when the text that was read asks for a reserved class.
An officer-filed item that asks for a reserved class is held for Lee instead of started, as one keyed `needs-decision` line, `progress-holds-<date>`, in the digest.
A missing or unreadable rubric, `triage: off`, an exhausted call budget or a rate limit stops only the priority write and is named as a coverage gap; which items start does not change.

The deterministic classifier uses these authorizing classes, in this order:

| Class | Recorded evidence |
| --- | --- |
| `security`, `cve` | `kind: security` or `kind: cve`, a title beginning `Security`, or a CVE identifier in the title |
| `code-review`, `bug` | `kind: code-review` or `kind: bug`, or a title beginning `[scheduled-review]`, `Code review finding`, `Code review fix`, or `Bug` |
| `security`, `code-review`, `bug` by Linear label | A `security` or `security-scan` label (security), a `scheduled-review` label (code-review), or a `Bug` or `bug-sweep` label (bug), unless the item also carries a `billing` or `compliance` label |
| `requested-feature`, `requested-fleet` | A Top of Mind ask defaults to `requested-feature` unless its matching work has a more specific class; `kind: feature` or `kind: fleet` with `requested-by: Lee`; a Linear item named in `requested` or linked from such a backlog row, or its descendants, defaults to `requested-feature` unless its own recorded class is more specific |

Backlog metadata uses the existing parenthesized tags, for example `(kind: bug)` and `(severity: high)`.
The same tags in a Linear title or description, and the same title prefixes on a Linear title, classify a Linear-only item.
Lee accepted this in the review decision of 2026-10-26: "restore classification of Linear items from their free-text tags (the (requested-by: Lee) and (kind: feature|fleet) tags and the Security/Bug/CVE title prefixes), so Linear-only items in those classes can start again, as Lee accepted."
The accepted risk is that anyone with write access to the Linear team can make an item start automatically by writing those tags or prefixes, including a `requested-by: Lee` claim Lee never made.
To keep such starts visible, every record carries `tag_source`, naming where its authority came from, and the digest prints it:

| `tag_source` | Authority |
| --- | --- |
| `backlog` | A tag or title prefix on a backlog row this fleet wrote |
| `top-of-mind` | A fresh Top of Mind ask, never a statement, that supplies the requested-feature authority |
| `task-meta` | The title in a task's `state/<id>.meta` file when the task has no backlog row; such tasks are already in flight and never start |
| `linear-label:<label>` | A Linear label on the issue, read through the GraphQL API |
| `linear-free-text:kind`, `linear-free-text:requested-by` | A tag in the Linear issue's title or description |
| `linear-title-prefix:Security`, `linear-title-prefix:CVE`, `linear-title-prefix:Code review`, `linear-title-prefix:Bug`, `linear-title-prefix:scheduled-review` | The Linear title prefix, or a CVE identifier in the Linear title |
| `requested-root:<id>` | The registered `requested` root the item descends from |
| `standing-authority:filler` | The filler pass, in the dated JSON's `filler` object |

Unclassified records carry `tag_source: null`.
`requested` records an existing Lee request; registering a root never authorizes inventing a new feature.
Within each class tier, Linear priority or backlog severity ranks urgent/critical, high, medium, low, then unspecified; identifiers and home names break ties.
Open work with no recorded class is counted as `unclassified` unless it explicitly requests a decision or action from Lee while open and unstarted.
For unclassified items, topic words in titles, paths, feature names such as Business Health or `/business-health`, and descriptive notes never constitute a Lee request.
An imperative addressed to Lee, such as `Lee to choose the export format`, is an explicit request; a dated citation such as `Lee, 2026-10-14: approved the copy` is not, and an existing captain hold remains held.
In-flight work and recorded starts never become new asks for their own wording; finished unclassified work is dropped.
This slice uses `model: none` throughout.

Held, blocked, already carded, in-flight, completed, or open-PR-linked work is excluded from starts.
Unresolved keyed status calls remain open across later `working` lines.
The same Linear identifier produces at most one start request across homes.
Before ranking, a candidate filter drops what is not a work item: any start candidate whose whole text is a release note such as `same release as PR N` (optionally after a label such as `Note:`) or a date or status stamp such as `Last updated: November 2026`, and a Top of Mind ask whose text is a pasted shell command.
A command needs shell structure: a leading `$ ` prompt, or a known command word (optionally after `sudo`) followed by a flag, a path, or an `=` assignment, or later by `&&`, a pipe into a command, or a redirect to a path, so `curl timeouts in importer`, `make retries > 3 configurable` and `Ship glossary same release as PR 4593` stay work; backlog and Linear titles are work items by construction and are never dropped as commands.
A dropped ask is set aside before matching, so it never joins, reclassifies, or starts other work.
A second copy of a start (the same Linear identifier, or the same home and id) is dropped as a duplicate.
A Top of Mind ask whose title matches a row's title once punctuation and case are ignored joins that work instead of becoming a candidate, and an ask that matches no row but matches an open PR's title is dropped as a duplicate of that PR; fleet records keep their own identity, so two backlog rows that share a title both remain candidates.
Every dropped item is listed in `excluded` and the digest with its reason, and a dropped ask also in the Top of Mind section; nothing is dropped silently.
Code-review findings and bugs start under their recorded class even when their titles or descriptions mention business, product, wording, legal, payments, billing, pricing, or restricted operations.
Only an explicit ask overrides that classification: an `Ask Lee:`, `Ask for Lee:`, `Lee ask:`, `Decision for Lee:`, `Need Lee:`, or `Needs Lee:` line (a spaced ` - ` may replace the colon), or a `Needs Lee to ...` marker, identifies the decision or action Lee must take.
Bulleted lines and Markdown headings or bold markers may wrap those prefixes.
A bare `Decision:` line records a decision already made and is not an ask.
Words in an old classifier reason, such as “Outside automatic-start authority: delete” or “Lee decides the legal choice,” do not constitute an ask.
For requested-feature, requested-fleet, security, and CVE items, whether recorded in Linear or the backlog, whole-word business, product, wording, legal, payments, billing, and pricing matches in the item's own title still go to `asks_for_lee`, excluding matches within known feature names and slash paths.
Titles of those items naming merges, production, credentials, rotation, data rewrites, destructive actions, and spending are outside automatic-start authority and also go to `asks_for_lee`.
A note such as `needs Lee's merge word for payments/trials` gates merging, not starting: it creates no ask, and otherwise eligible work with no linked PR starts; its linked PR is still read, so an open, closed-unmerged, or unreadable PR excludes it and a merged PR drops it.
Other explicit asks retain a generic decision-or-action reason.
A start whose ancestor is itself listed in `asks_for_lee` is held in `excluded` until Lee answers; an in-flight, held, or startable ancestor holds nothing; its recorded holds and dependencies also still exclude starts.
Before publishing a merge-word ask or a direct merge request with a GitHub PR URL, the officer reads that PR through `gh-axi`, including PR URLs found in a local card's linked Linear description, and drops the item only when every referenced PR is merged; this holds whether the item's class comes from its own tags, its linked Linear issue, or a requested root.
A PR closed without merging keeps the item listed with the reason “PR closed unmerged: check whether still needed”.
An unreadable PR remains listed, and coverage names the failed PR read rather than treating it as closed.
Open-PR and merge-ask PR reads share the run deadline; once it has passed they are skipped and named as coverage gaps.
This reconciliation changes only the officer's report, never the underlying task or Captain's Log card.
For a queued local task, its backlog identifies the home; a Linear-only item defaults to the primary home until ordinary intake routes it by registered scope.

When coverage is complete and no startable or in-flight work in the start classes remains, the officer rotates one extra bug sweep, code review, librarian pass, or ideation pass by run date.
That filler request uses the same standing authority and firstmate intake as the ranked work.

A home declines a start request by replying to its note with `fm-inbox.sh reply <id> 'declined: <why>'`; only a reply whose body starts with `declined:` counts, and an acceptance or any other reply does not. While the request's evidence is unchanged the officer does not re-send it to that home: it moves out of `start_requests` into `excluded` with the decline, the remaining starts are re-ranked, a declined filler becomes `null`, and the digest's Declined line and `declined` count record it. A decline lapses after 14 days, and the request is then sent again. Only a local home's inbox is read, so a request for a remote `start-home` is never skipped.

Each run writes `<date>.md`, `<date>.json`, `<date>.start-requests.sh`, and the stable `progress-state.json` in its findings lane. A run that exhausts the Linear quota also writes `linear-resume-after.json` there.
The dated JSON file contains the complete discovery report under [progress-run.schema.json](../schemas/progress-run.schema.json), schema version 1, source `progress-officer`.

| JSON field | Meaning |
| --- | --- |
| `schema_version`, `source` | `1` and `progress-officer` |
| `date`, `generated_at` | Run date and actual UTC observation timestamp |
| `doing`, `done` | Work in the start classes currently in flight, and work recorded completed or canceled; completed Linear-only history is not listed |
| `start_requests` | Ranked authorized work waiting for firstmate, or the `start-home` office it is addressed to, to dispatch |
| `asks_for_lee` | Explicit asks of Lee, title-gated choices and work outside automatic-start authority, and merge asks whose PRs are not all merged, each with its reason; these need Captain's Log cards |
| `excluded` | Evidence that prevents a new start, including existing cards and incomplete discovery |
| `unclassified` | Count of open items with no recorded start class; they are not listed |
| `declined` | Count of start requests not re-sent because their target home declined them with unchanged evidence (see below) |
| `filler` | The extra discovery pass, or `null` |
| `coverage` | Read failures or unsupported inputs; an empty array means all configured sources were read |
| `top_of_mind` | One line per fresh Top of Mind ask: the ask and its start request or the reason it is listed instead |
| `linear_coverage` | Linear discovery counts described under [Progress officer](#progress-officer) |

Each work record has `id`, `title`, `owner_home`, nullable `linear_id`, all linked `linear_ids`, nullable `authorising_class`, nullable `tag_source`, `reason`, `evidence`, numeric `priority` (0 means unspecified), nullable `rank`, and nullable `execute`.
Optional `link`, `links` (every URL a Top of Mind ask links), `project`, `linear_only` (true when the record comes from Linear alone, so its `project` is a Linear project), `outcome`, and `captains_log_key` preserve source context for the page projection.
A start request with an optional `unrouted` reason is one that no rule places with an office (see [`start-home`](officers.md#officers-dataofficersmd)), so it stays with this home.
Only start requests have a one-based `rank` and an `execute` object; filler also carries `execute`.
The execution object contains `action: start`, `request_id`, `env.FM_HOME` (this home, or the [`start-home`](officers.md#officers-dataofficersmd) office the request is addressed to), and an argument array `argv` for the existing idempotent `fm-inbox.sh note` intake.
The adjacent shell handoff runs the quoted argument arrays addressed to this home in rank order, followed by filler when present; requests addressed to an office are not in it.
The request identifier is stable for the same item and date, so retries replay the original inbox note; a later date may retry work still unstarted.

Firstmate executes the handoff without another decision about whether to start authorized work.
Before executing, check `generated_at`: rerun a digest older than 36 hours, and recheck current holds, open PRs, and work in flight before dispatching each request.
Firstmate routes and dispatches through ordinary intake, including registered scope, capacity limits, quota routing, project delivery rules, and `fm-spawn.sh`; capacity or quota delays stay queued.
Officer evidence never becomes a quotation attributed to Lee in a worker's intent.
If Lee later stops requested work, keep its branch parked rather than discarding it.
Each `start-home` office's `lane:<officer-id>` (or `:high`) wake source delivers the requests addressed to its own home: the office's check reads the dated JSON and runs only requests whose `env.FM_HOME` is that office's home, in rank order, through its own `fm-inbox.sh note` with the recorded arguments, never a program named in the file.
It delivers nothing from a digest whose `generated_at` is more than 36 hours old, stops at the first request it cannot deliver, and retries on the next check; the stable request identifier makes every retry a replay, so each request becomes one inbox note.
The office then judges and dispatches each note under the `office-roles` skill as ordinary routed work.
An ask that no rule places stays in this home's handoff and the Markdown digest's request line says why, with local-jev's label and confidence when it answered; it is never dropped.
For example, `start-home: navigator,quartermaster` sends PropertyCompass2 work to the Navigator and fleet work to the Quartermaster; each office must list `lane:progress` in its `sources:`, and `repos:` must name every repository whose open PRs should stop a duplicate start, the fleet repositories included.
The officer writes only its findings lane and never executes the handoff itself.

The fleet app pulls `progress-state.json` for a separate progress officer page; this does not replace Captain's Choice or Captain's Log.
This file follows Slarti's page contract in [progress-state.schema.json](../schemas/progress-state.schema.json); it contains no executable requests, ranks, or discovery details.
Writes use a temporary file in the same directory and an atomic rename.
Its top-level fields are:

| Field | Meaning |
| --- | --- |
| `schema_version`, `officer` | `1` and the registered officer id |
| `written_at` | Actual UTC observation time |
| `stale_after_minutes` | Optional age limit; this daily officer emits 2880 minutes, matching its two-cadence health window |
| `summary` | Optional one-line counts, including coverage gaps and the page's display bounds |
| `doing` | At most 30 entries with `id`, `description`, `started_at`, and optional `link`, `project`, and `source` |
| `done` | At most 50 entries, newest observation first; an outcome already in the previous dated run that has left the page is not added again; with `id`, `description`, `at`, `outcome` (`ok`, `failed`, or `skipped`), and optional `link`, `detail`, and `source` |
| `asking` | At most 30 entries: `instruction` entries have `key`, `kind`, `question`, `waiting_on`, `link`, and optional `asked_at`; `captains_log` references carry only `key`, `kind`, and `link` |

Each page `id` and `key` is the Linear issue key plus a hash of the work item's own home and id, so several work items under one issue get distinct ids that stay the same across runs.
Page times describe when the officer first observed the work, outcome, or request, and persist across successive observations while the entry remains present.
Descriptions say that the officer is watching or recording work rather than claiming it performed another worker's action.
The optional `source` on `doing` and `done` maps security/CVE to `cve`, code-review to `review`, bug to `bug`, requested-feature to `feature`, requested-fleet to `fleet`, and filler to `filler`.
Unknown sources omit that optional field.
Waiting starts and filler appear as instructions with `waiting_on: firstmate`; new Lee choices say `Needs a Captain's Log card`.
An existing captain-held backlog row links to its exact card key when `captains-log` is configured; the page repeats no question or answer from that card.
Source links use the recorded HTTPS issue or PR URL, falling back to the configured repository when local-only work has no HTTPS record.
The dated report retains all entries when the page's limits omit some.
[`tests/fixtures/progress/state-v1.json`](../../tests/fixtures/progress/state-v1.json) preserves Slarti's sample, and the progress officer tests check both that sample and actual output against the page schema.
