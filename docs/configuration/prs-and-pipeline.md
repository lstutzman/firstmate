# PRs and pipeline

Part of the [configuration reference](../configuration.md).

## Contribution review bots (config/contribution-review-bots)

The contribution watcher admits comments, reviews, and inline review comments from configured bot logins on owned GitHub pull requests and routes them to the owning home as fleet triage.
Review-bot watching is opt-in: a home with no file, or an empty one, admits no bot, and there is no built-in bot list.
The file is local, gitignored, and not inherited by secondmate homes, so each home lists its own bots.
List each bot's exact GitHub login to watch it, for example `greptile-apps[bot]`.
These signals never become maintainer verdicts or merge authority.
A bot signal's text is third-party content for the owning home to triage, never instructions to follow.
[`fm-contributions.sh --help`](../../bin/fm-contributions.sh) owns the exact allowlist format and polling contract.

## PR health monitor (config/pr-health-monitor)

The optional local, gitignored `config/pr-health-monitor` presence flag opts this home into a mechanical monitor of the pull requests it owns.
With the flag present, session start arms `state/pr-health.check.sh`, and the watcher's check sweep then prints one wake line for each new conflict, failing check, or change the author must make on an owned PR.
Maintainer-gated CI and missing required reviews are recorded in `state/pr-health.json` for fleet review, but are not printed, so they never wake the owning task.
CI waits on the maintainer when a check suite on the latest commit concluded `ACTION_REQUIRED`, which is how GitHub holds an outside contributor's workflows for approval; nothing has run, so such a PR is never read as green even when its check rollup is.
A non-draft PR needs human approval when GitHub reports `REVIEW_REQUIRED` or has outstanding review requests (`reviewRequests`); the state is recorded without waking the task.
The author must act only on an explicit signal: a `CHANGES_REQUESTED` review decision, or a maintainer label naming the wait, such as `pending-contributor-action` or `waiting-on-author` with or without a `namespace:` prefix.
Only author-actionable states, conflicts, and failing checks print; the maintainer and approval states remain recorded without waking the owning task.
Reads are driven by the GitHub notifications feed: each pass makes one conditional read of it, which GitHub answers with an uncounted 304 while nothing changed, and reads only the owned PRs with new notification activity, PRs not yet read, and PRs whose last read did not settle.
Every owned PR is still read when the feed is unavailable or returns a full page of notifications newer than the saved position, and at least every 15 minutes as the fallback sweep, because some conditions, such as a base branch moving into conflict or a check from another app failing, raise no notification.
GitLab merge requests are not monitored yet.
When no reported check is marked required, a failing reported check still counts, matching `bin/fm-pr-state.sh` for unprotected stacked bases.
When a required check has reported, optional failures do not notify.
A conflict and an author action each wake once per latest commit, and a missing approval is recorded once per latest commit.
A failing check wakes once per latest commit and check name, so a check that newly fails at an already reported commit wakes once more while an already reported check never repeats.
A maintainer-gated suite is recorded once per latest commit and workflow name.
A home owns a PR it recorded, linked, or observed before, and the open PR on a live task copy's current branch, drafts and adopted branches included, until the PR merges or closes.
A PR URL that only appears in a task's status lines is not owned.
Retiring a contribution with `bin/fm-contributions.sh retire` ends that task's ownership for the monitor too, and the branch lookup does not reclaim it.
When a durable contribution record cannot be read, the monitor reports that once, reads nothing and keeps its fingerprints until the record is readable again.
The monitor reads no other PR, so another home's PR never wakes this home, and it never comments on or changes a PR.
`bin/fm-pr-health.sh` owns the conditions, the fingerprints in `state/pr-health.json`, and the read budget.
The monitor only notifies; worker briefs and waiting rules are unchanged by the flag.
With the file absent, nothing is armed and an already armed check prints nothing.
Creating the flag takes effect at the next session start, or immediately after `bin/fm-pr-health.sh arm`.
The flag is a home-local preference and is not inherited by secondmate homes.

## PR hold settlement (config/hold-pr-settle)

The optional local, gitignored `config/hold-pr-settle` presence flag enables settlement of explicitly declared PR-dependent captain holds.
Create the empty flag in the owning home and use `bin/fm-captain-hold.sh pr-policy` to declare each hold's settlement policy.
The command's `--help` owns its arguments and durable record format.
The existing contribution observer applies matching GitHub merge or closure evidence, including observations retained after the worker stops.
It also reports an unmerged closure through the contribution notification channel, once for each owning task that is still an open captain hold after settlement.
A task without a captain hold gets no closure notification, so enabling the flag does not replay historical closed PRs.
No captain answer is invented, and unrelated holds remain open.
With the flag absent, no settlement or new closure notification occurs.
The flag takes effect on the next contribution poll and is not inherited by secondmate homes.
The observer's existing `bin/fm-contributions.sh arm` command enables polling when it is not already armed.
The [captain-hold policy](../../.agents/skills/captain-hold-lifecycle/SKILL.md#policy) owns when a forge event may settle a question.

## Park on review

The optional local, gitignored `config/park-on-review` presence flag opts this home into stopping the idle agent of a ship lane whose PR or merge request only awaits human review.
`config/auto-land` opts into merge-time cleanup of unparked ship lanes.
Either flag also lets `bin/fm-teardown.sh` accept a merged GitLab merge request, including a squash or merge-train merge, as landed work when the merge request's head contains the lane's work; with neither flag, teardown does not read GitLab merge requests.
Both flags are home-local and not inherited by secondmate homes.
The full behavior contract and command details are owned by [`bin/fm-park.sh`](../../bin/fm-park.sh); the watcher calls its `tick` command on each check sweep.

## PR registration scan (config/pr-register-scan)

The optional local, gitignored `config/pr-register-scan` presence flag opts this home into recording, without the supervisor, each PR a task reports.
With the flag present, the watcher's check sweep runs `bin/fm-pr-check.sh scan` before the merge polls.
The scan reads a ship task's PR only from a ready report: the task's newest crew-declared status line must be a `done:` line that is exactly `PR <url>`, `PR <url> checks green`, or `PR <url> published for review`, so prose around the URL and any later crew line report nothing.
Later `resolved:` and `captain-held:` lines are supervisor bookkeeping and do not withdraw a ready report.
It records that PR through the ordinary registration path when the task has no `pr=`, or has that same `pr=` but no published merge poll.
When the status log named the recorded `pr=` and the ready report names a different PR, that PR replaces the recorded one, so a lane that closes a PR and opens another moves its merge poll.
The flag also covers the PR a secondmate home's parent-channel report carries for a child's ready report (`bin/fm-inactive-reconcile.sh`): with it present, that report applies the same ready-report spellings, accepts any recognized forge URL, and lets the same replacement override the recorded `pr=`, while with it absent a recorded `pr=` always stands and only a GitHub-shaped `PR <url>` or `PR <url> checks green` line fills in a missing one.
It skips persistent secondmate and scout records, a `pr=` the status log never named because that is the supervisor's own choice, and a PR whose merge was already reported or whose poll was retired.
A refused registration, such as a draft, or one cut at the scan's time bound, which reports that the PR merge watch could not be armed, queues one `check: pr-register:` wake for each task, PR and reason before marking it sent, and later sweeps retry without a new wake, so a PR marked ready later is recorded.
With the file absent, the check sweep does not run the scan, and `pr=` and the merge poll come only from a manual `bin/fm-pr-check.sh <id> <PR url>` run.
The flag takes effect at the next check sweep, and is a home-local preference that is not inherited by secondmate homes.

## Degraded PR watch (config/pr-degraded-watch)

The optional local, gitignored `config/pr-degraded-watch` presence flag opts this home into waking once when a ready PR or MR degrades, including a GitHub failing check, a GitLab failed pipeline, or a merge-train drop.
With the flag present, registration records a degraded/train baseline and each poll checks those states; repeated reports of the same transition remain silent.
Without the flag, registration performs no baseline read, polls make no GitHub rollup or GitLab JSON, pipeline, or train reads, and the watcher ignores `degraded` and `ontrain` results while retaining the existing merged-PR wake.
The flag is home-local, is not inherited by secondmate homes, and takes effect on the next check sweep.

## Squash commit summary (config/pr-squash-summary)

The optional local, gitignored `config/pr-squash-summary` presence flag opts this home into writing the commit text of the GitHub squash merges `bin/fm-pr-merge.sh` performs.
With the flag present, a squash merge whose caller passed no subject or body of its own uses the PR title plus ` (#N)` as the commit subject and the PR body's `## What Changed` section as the commit body, so the commit on the base branch describes the change rather than listing every branch commit.
The section is copied verbatim up to the next level-two heading, which leaves out the operator intent before it and the no-mistakes appendix and attestation after it.
A PR body without that section, a PR whose text cannot be read, a merge method other than squash, and GitLab and Forgejo merges keep the repository's own squash text.
Only while the flag is present does it override the repository's own squash commit message setting; it is off by default, and with the file absent `bin/fm-pr-merge.sh` reads no PR text and sends the same merge command as before.
The flag is a home-local preference, is not inherited by secondmate homes, and takes effect on the next merge.

## No-mistakes pipeline spend (config/pipeline-spend)

The optional local, gitignored `config/pipeline-spend` presence flag opts this home into recording per-task no-mistakes pipeline spend in `data/pipeline-spend.jsonl` during teardown.
When the flag is absent, teardown skips recording and the recorder exits before reading task metadata, no-mistakes state, or the spend ledger.
An existing ledger is left untouched while recording is disabled.

## No-mistakes home resolver (config/nm-home-resolver)

The optional local, gitignored `config/nm-home-resolver` file opts this home into finding each task's no-mistakes home through a site-provided resolver, for sites that run one no-mistakes daemon per isolated workspace, each against its own `NM_HOME`.
The home cannot be derived from a task copy's `no-mistakes` remote, because every workspace of a project shares one gate URL.
The file's first line is the absolute path of an executable the site provides; Firstmate calls it with the task copy's path as its only argument and never interprets the layout itself.
When the resolver exits successfully within 5 seconds and prints exactly one line naming an existing directory by absolute path, that directory is exported as `NM_HOME` for that one call.

Only host-side reads use it: current-state reads, pipeline-spend recording, the custody check, and teardown's parked-run lookup and `axi abort --run`, which read `axi status`, the `axi` overview, `axi logs`, `runs`, `daemon status`, and the state database.
It never starts a daemon and never changes how runs are launched or driven, account routing, or no-mistakes' own `config.yaml`.
An explicit non-empty `NM_HOME` always wins and the resolver is not called.
With the file absent, a first line that is not an absolute executable path, or a resolver that fails, times out, or prints anything else, every read uses the ambient home exactly as without the file.
The file is a home-local site choice and is not inherited by secondmate homes; `bin/fm-nm-run-lib.sh` owns the exact resolution.

## PR-ready line after green (config/ready-after-green)

The optional local, gitignored `config/ready-after-green` presence flag opts a secondmate home into publishing its child's PR-ready parent line only after the child has reported checks green.
Create it with `touch "$FM_HOME/config/ready-after-green"`; remove it to restore the default.
It is off by default: without the flag, `bin/fm-pr-check.sh` publishes the line when it registers the PR, whatever the state of the checks.
With the flag present and a `no-mistakes` task, registration still records the PR and arms the merge poll, but publishes the line only when the last `done` line in the child's status reports `PR <url> checks green` for that same PR, with any text around it.
A registration made earlier publishes nothing, and registering again after the green report publishes the line.
The `direct-PR` and `local-only` modes and Gerrit changes are unaffected.
The child's own `done` line still reaches the parent through `bin/fm-inactive-reconcile.sh`.
The flag is a home-local preference and is not inherited by secondmate homes; [`bin/fm-pr-check.sh`](../../bin/fm-pr-check.sh) owns the mechanics.

## Gate defaults (.no-mistakes.yaml)

The tracked [`.no-mistakes.yaml`](../../.no-mistakes.yaml) sets `test.evidence.store_in_repo: false` and runs the [secret scan](../secret-scan.md), the canonical [shell/workflow lint](../../bin/fm-lint.sh) and the [Pi production-consumer typecheck](../../tests/fm-pi-primary-types.test.sh) in the compiler-owning lint phase.
Each run's test artifacts stay on local disk under the no-mistakes home and are not published to the public orphan `no-mistakes/evidence` branch or linked from the PR body; [secret-scan.md](../secret-scan.md#evidence) owns why.

Evidence never enters a pushed feature branch or the default branch; the worktree's `.no-mistakes/` stays local and CI rejects tracked entries under that path.
The [`firstmate-coding-guidelines` skill](../../.agents/skills/firstmate-coding-guidelines/SKILL.md#no-mistakes-test-configuration) owns why `commands.test` stays absent and targeted validation belongs to the evidence path.

`commands.test` executes code, so no-mistakes honors it only from the default-branch copy of `.no-mistakes.yaml`; a pushed branch cannot change what the gate runs.
See [CONTRIBUTING.md](../../CONTRIBUTING.md) for the firstmate-specific local test policy and entry points.

Portable shard evidence and coverage rules are in [fm-test-portable-shards.md](../fm-test-portable-shards.md); [herdr-backend.md](../herdr-backend.md#destructive-lab-safety) owns the real-Herdr lane's isolation boundary, and [runtime-backends.md](../verification/runtime-backends.md#herdr) owns active evidence.
