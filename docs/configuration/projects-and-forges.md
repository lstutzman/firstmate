# Projects and forges

Part of the [configuration reference](../configuration.md).

## Linear-required projects (config/linear-required-projects)

The optional local, gitignored `config/linear-required-projects` lists, one project name per line, the projects whose ship and scout briefs must name their Linear item; blank lines and `#` comments are ignored.
For a listed project, `bin/fm-brief.sh` stops a ship brief before writing anything unless the call passes `--linear <PC-n>`; a ship brief has no opt-out.
A scout brief for a listed project also accepts `--no-linear "<reason>"` instead, which records `Linear item: none (<reason>)` under the brief's `## Captain's intent`; `--no-linear` is scout-only and conflicts with `--linear`.
When `bin/fm-spawn.sh` refuses a brief whose forge or PR-text binding disagrees with the registry, its re-scaffold command carries the brief's quoted `--linear <PC-n>`.
An absent file, or a project not listed in it, changes nothing.
For the Navigator and Deep Thought homes, add the line `PropertyCompass2` to the file.
`bin/fm-brief.sh`'s header owns the matching rule.

## Forge selection (data/projects.md forge= token)

A project with no `forge=` token is served by the GitHub tooling, `gh` and `gh-axi`, exactly as before the token existed, and the token changes nothing for existing entries.
A remote-backed project on a Forgejo or Gitea server is registered with `forge=forgejo`, one value of the same closed `forge=` binding that Gerrit uses; `bin/fm-project-mode.sh`'s header owns its grammar, values, and refusals, and `bin/fm-project-mode.sh --forge <name>` reads it back.
Firstmate passes the binding to `bin/fm-brief.sh --forge` at intake the same way it passes `--mode`, and `bin/fm-spawn.sh` refuses a brief whose forge disagrees with the registry; on `forgejo` the generated ship brief names `tea` instead of `gh-axi`.
The URL-driven provider dispatch in [`bin/fm-pr-lib.sh`](../../bin/fm-pr-lib.sh) recognizes a GitHub, GitLab, Gerrit, or Forgejo PR/MR/change URL once one exists, regardless of this token.

A Forgejo (or Gitea) project needs `tea` on `PATH` plus a `tea login` registered for that project's host (`tea login add`); the login is matched to a PR's host automatically, never configured per project.
A GitLab project needs no forge token, only `glab` on `PATH`, authenticated via `glab auth login`.
[`docs/gitlab-merge-watch.md`](../gitlab-merge-watch.md) and [`docs/forgejo-tea-integration.md`](../forgejo-tea-integration.md) hold the empirically verified CLI behavior each provider's watch and merge path depends on.

A project whose reviews are created by a review tool that uploads its own snapshot of the worker's commits is registered `[direct-PR forge=external]`; it is never detected, ships `direct-PR` only, carries no yolo, and needs the [external review tool](#external-review-tool-configexternal-reviewmd-configexternal-review-url-configexternal-review-backup) configuration below.
[`docs/external-review-forge.md`](../external-review-forge.md) is the design.

## Merger home (data/projects.md merger= token)

A project entry may name the one home that merges its PRs with `merger=<home>`, the merging home's secondmate id or `main` for the primary home, for example `- PropertyCompass2 [no-mistakes +yolo merger=slarti] - ...`.
`bin/fm-pr-merge.sh` then refuses a merge from any other home before any forge call, naming the merger and printing the one command that hands the PR to it.
In a secondmate home that command appends a stamped `needs-decision [key=merge-handoff-<PR number>] [cause=external]: [handoff=<home>] <PR URL> is ready to merge` line to the home's parent channel (the destination `fm_parent_channel_destination` in [`bin/fm-parent-channel-lib.sh`](../../bin/fm-parent-channel-lib.sh) resolves), and the main home relays it to the merger; in a home with no parent it is `bin/fm-send.sh fm-<home>` with that same line.
`bin/fm-pr-check.sh` publishes that same line itself when a ship task's PR is registered in any other home, once per PR and head, delivered the same way: on the parent channel, or with `bin/fm-send.sh fm-<home>` in a home with no parent; a secondmate home with a local parent route whose parent records the merger as a secondmate instead delivers it straight into the merger's inbox through that parent home's `bin/fm-send.sh` (fire-and-forget, one delivery id per PR head) and leaves only a silent `working` line on the parent channel, falling back to the keyed `needs-decision` line when the delivery fails; a task held for the captain and the merger home itself publish none, and its header owns the rules.
A no-mistakes worker releases its own run with `no-mistakes axi handoff` before its checks-green done line, as its brief's done step says.
Once a handed-off no-mistakes ship reports that PR checks green, `bin/fm-pr-check.sh` also runs `no-mistakes axi handoff` in the task's copy, unless `no-mistakes axi status` there already reads handed_off, at registration or on the watcher's next check sweep (`fm-pr-check.sh release`), so the run stops holding one of the machine's pipeline slots while it waits for the merger; each PR head is attempted once and a failed attempt is reported once (a `check: nm-release:` wake from the sweep), and the same header owns the rules.
On a Herdr or Rex home the watcher's check sweep (`bin/fm-tree-park.sh sweep`) also returns a handed-off ship's copy to the pool once its worker reported the PR and any no-mistakes run was released, when the copy is clean and its head is the pushed PR head, keeping the task record, and a later text steer to the task leases a fresh copy at the PR's current head, which a restack may have moved, and relaunches the worker before the steer is recorded; a park that fails after stopping the worker relaunches it and is reported once as a `check: tree-park:` wake, and that script's header owns the rules.
The same sweep, and `bin/fm-ready-branch.sh` when it records one, parks a ship whose pushed branch waits for a CI slot with no PR, under the same safety checks but with the pushed branch as the proof instead of a PR head.
The watcher's check sweep also runs `bin/fm-nm-stall-check.sh sweep`, which reads `no-mistakes axi status` in each local no-mistakes ship's copy and raises one `check: nm-stall:` wake when a run has sat pending with no step started for 5 minutes while a run slot is free (running runs are counted machine-wide against `max_concurrent_runs`; an unreadable count is reported as unknown, never as free), or parked at a gate for 30 minutes with no answer.
A gate wake names the gate and who owes the answer: the captain through firstmate when a finding's action is ask-user, otherwise the task's own worker.
Each task, run and state wakes once, the state clears as soon as the run moves, and the check only reads: it never cancels, restarts or answers a run.
The thresholds, the slot rule and the record are owned by the script's header.
The same check sweep then closes a stopped finished task's Herdr workspace, a parked one included, and keeps its record ([`herdr-backend.md`](../herdr-backend.md#closing-a-finished-tasks-workspace)).
A home's own id is its seeded `.fm-secondmate-home` marker, and a home without one is `main`, so a fleet has exactly one primary home.
The binding is read from the merging home's own `data/projects.md`, which is not inherited, so every home that could merge the project must carry the same `merger=<home>` token on its own registry line; a home whose line lacks it is not refused.
A project with no `merger=` token keeps every home's merge authority exactly as before, and `yolo` still decides whether the merger home merges without the captain's word.
`bin/fm-project-mode.sh --merger <name>` reads the binding back, and its header owns the grammar and refusals.

## Merge method (data/projects.md merge= token)

A project entry may declare that it takes merge commits only with `merge=commit`, for example `- PropertyCompass2 [no-mistakes +yolo merger=slarti merge=commit] - ...`.
Use it when something downstream reads the merge commit's parents, because a squash or rebase destroys them.
`bin/fm-pr-merge.sh` then merges with a merge commit when the caller names no method, on GitHub and Forgejo, and for a `--stack` merge.
It refuses a squash or rebase before any forge call, naming the project and the token, in any spelling the caller passes: `--squash` or `--rebase` with or without a value, `--method` with a missing or non-merge value, and any single-dash short-flag cluster carrying `s` or `r` (`-s`, `-r`, `-sb text`, `-s=true`).
A merge commit adds no squash summary, even with `config/pr-squash-summary` present.
A project with no `merge=` token keeps today's defaults exactly: squash on GitHub, and the repository's own style on Forgejo.
`merge=commit` is the only value, and a malformed value refuses the merge rather than falling back to the default it exists to stop.
Like `merger=`, the token is read from the merging home's own `data/projects.md`, which is not inherited, so every home that could merge the project must carry it on its own registry line.
`bin/fm-project-mode.sh --merge-method <name>` reads the binding back, and its header owns the grammar and refusals.

## Landing lag (data/projects.md landing-lag= token)

A project entry may limit how long its oldest ready PR may wait to land with `landing-lag=<hours>`, a positive whole number of hours, for example `- PropertyCompass2 [no-mistakes +yolo merger=slarti landing-lag=48] - ...`.
While any ready PR for the project on this machine has waited longer than that, `bin/fm-spawn.sh` launches no new ship for it: it creates nothing, leaves the backlog item queued, prints one `deferred:` line naming the oldest ready PR and its age, and exits 75, exactly like a [project capacity](capacity.md#project-capacity-configproject-capacity) deferral.
A PR's wait starts when `bin/fm-pr-check.sh` first records it as ready, and ready PRs in every local home on this machine count, as do those a remote home reports in its cached home summary (less than two hours old, otherwise skipped with one `warning:` line).
Only a ready PR that can land counts: one whose task records `yolo=off` waits for the captain's merge word, so it does not count, and neither does one whose task's row in its home's backlog is held for the captain (`bin/fm-captain-hold.sh`) or has an unresolved `blocked-by` dependency.
A ship spawned with `--landing-exempt` is never held, and that flag is how a fix or landing work is marked; a relaunch, a scout, and a secondmate are never held either.
When a ready PR's wait is unknown, because it was recorded before ready times existed or its home's backlog cannot be read, the spawn goes ahead with one `warning:` line, unless another ready PR is already known to exceed the limit.
A value that is not a whole number of hours refuses every fresh ship spawn for the project until it is corrected.
A project with no `landing-lag=` token is never held, and the token is read from the spawning home's own `data/projects.md`, so each home that dispatches the project carries it on its own line.
One part of the admission rule is a known limit, by the captain's decision, until firstmate has a signal for it: a paused landing is not read. A PR another home holds counts unless it carries the `held` label (see below). A merged PR also counts until its task is cleaned up, so choose a limit with those in mind.
[`bin/fm-project-capacity-lib.sh`](../../bin/fm-project-capacity-lib.sh) owns which records count and how an unreadable signal is handled, and `bin/fm-project-mode.sh --landing-lag <name>` reads the limit back.

## PR drain (open-PR drain rule)

A project whose clone's origin is on github.com is in PR drain from the moment its repository has 24 or more eligible open PRs until its eligible count is at or below its CI slots S (0 when it declares none; Lee, 2026-11-21).
An eligible PR is a ready (non-draft) open PR that is not a promotion PR (head branch `staging`) and is not waiting for the captain's merge word on positive local evidence ([CI slots](#ci-slots-configci-slots) owns that signal), and does not carry the `held` label (`HELD_LABEL` in `bin/fm-pr-drain.py`).
The state is derived from GitHub on every read, so every home on every machine sees the same answer with no shared marker: between S and 24, the PRs closed in the last 14 days (closed drafts and promotion PRs left out) are walked back from now to whichever of 24 or S came last, and no write ever reaches the repository.
A drain holds PR openings only, never ship starts (Lee, 2026-11-21): `bin/fm-spawn.sh` launches a ship for a drained repository as usual, with or without a class, so work for the next release keeps building while the drain lasts.
A class declared with `bin/fm-brief.sh --pr-drain <class>` exempts the ship's PR opening from the hold: an exemption class (`production-outage`, `cve`, `security`, `wolverine`, `lee-research`, `lee-explicit`, `officer`, `scheduled`) or a landing job (`restack`, `red-gate-fix`, `returned-pr-fix`, `review`).
When GitHub cannot be read, or 14 days of history hold neither 24 nor S (or hold 1000 or more closed PRs, the GitHub search cap), the state is unknown and a worker opens its pull request as usual; scouts, relaunches and secondmates are never held.
Every ship brief that opens a pull request (no-mistakes or direct-PR on a forge with pull requests) and declares no `--pr-drain` class carries a PR drain check in its Definition of done: just before opening a new pull request the worker runs `bin/fm-pr-drain.py state` in its worktree, and while that prints `on` it pushes its branch only, opens no pull request and reports the branch; at `off`, `unknown` or `none` it opens the pull request as usual. A worker whose branch already has an open pull request, such as an unclassed fix to a returned or red PR, skips the check and finishes through its Definition of done, /no-mistakes included.
A ship brief scaffolded with `--project` while its repository is in drain also gets a `# PR drain` section saying so, unless its class is `production-outage`, `cve`, `security` or a landing job; for the other exemption classes that section carries the same check.
A brief declaring `lee-explicit` (the captain's own explicit instruction) is refused at spawn unless its `## Captain's intent` section holds at least one double-quoted span and an ISO-8601 UTC timestamp such as `2026-11-16T18:19:06Z` on the same line or the line before it; the refusal names what is missing, and the quote itself is not verified.
A brief declaring `security` (a high or critical security fix, which starts at once) must name its Linear item with `bin/fm-brief.sh --linear <PC-n>` to keep its exemption: while the repository is in drain, `bin/fm-spawn.sh` runs a read-only Linear query and keeps the exemption only when that item carries the label `security` (any case) and priority Urgent (1) or High (2). Otherwise the ship still launches, with a `warning:` line that names the item and what is missing (including when Linear cannot be read), and loses only its exemption: its launch brief carries the PR drain check, and the [CI slots](#ci-slots-configci-slots) check when the project declares slots, so its PR opening waits like any ship's. A brief that opens no pull request (local-only, Gerrit or external review) gets no Linear read and no added check. Out of drain, or when the drain state is unknown, it launches like any other brief with no Linear read.
[`bin/fm-pr-drain.py`](../../bin/fm-pr-drain.py) owns the state, the window and the accepted classes, and the fleet alarm announces each change ([Fleet quota and secondmate alarm](away-and-alarms.md#fleet-quota-and-secondmate-alarm-configfleet-alarmjson)).

## CI slots (config/ci-slots)

The optional local, gitignored `config/ci-slots` declares, per project, the total concurrent gate and admission slots across every host (S), so the ready open-PR queue (P) never outgrows them, because a longer queue drains slower as its branches fall behind staging.
It holds one `<project> <slots>` line per project, in the same format as [project capacity](capacity.md#project-capacity-configproject-capacity): the project's registered name, then a positive whole number, with `#` comments and blank lines ignored.
The main home writes it (for PropertyCompass2 today, `PropertyCompass2 4`, Slarti's 2 slots plus Deep Thought's 2; to be confirmed with Slarti), and the inherited-local-material push copies it to every second-mate home, local and remote, so each dispatching home reads its own copy.
A project with no line is never held.
The slots hold PR openings, never ship starts (captain, 2026-11-21): `bin/fm-spawn.sh` reads neither S nor the cap, so a ship always starts and builds to a finished, verified branch.
A brief for a ship of a project that declares S carries a CI slots check that the worker runs just before it opens a pull request, as it does the [PR drain](#pr-drain-open-pr-drain-rule) check: `python3 bin/fm-pr-drain.py gate . <project>`.
While it prints `hold`, the worker opens no pull request and does not run `/no-mistakes`, pushes the branch, reports `done: branch <branch> pushed, no PR (CI slots)` and stops, and firstmate opens the pull request when a place frees.
The worker's own tests and gate ran before it parked the branch, and the no-mistakes review runs when the branch is released, so nothing reaches a pull request unvalidated.
Firstmate records that parked branch with `bin/fm-ready-branch.sh <task> <branch>`, which appends `ready_branch=<branch>` to the task record, and a recorded ready branch frees the ship's [project capacity](capacity.md#project-capacity-configproject-capacity) place exactly as a recorded ready PR does, so parked branches never fill the places.
After recording, `bin/fm-ready-branch.sh` returns the ship's pool copy through `bin/fm-tree-park.sh park` when the copy is clean, on the recorded branch, and equal to the pushed branch, so a parked branch holds no pool slot either; otherwise it prints `copy kept: <why>` and the watcher's sweep retries later.
`bin/fm-ready-branch.sh list` prints `<task> <branch> <project>` for each recorded ready branch with no PR, parked or not; on every heartbeat and after any PR of the project lands, firstmate re-runs the gate and, while it prints `open`, releases parked branches by steering each ship's worker, which leases a fresh copy at the pushed branch and relaunches the worker to run `/no-mistakes` on the branch, which validates it and opens the PR ([ship landing](../../.agents/skills/ship-landing/SKILL.md)).
Each released worker re-runs its own pre-PR gate check, which is the race guard, and on `hold` simply parks again; a brief overshoot of S by a PR opened at the same time from another home is accepted.
The gate holds when the open PRs on the project's GitHub repository, the ready ones less promotion PRs and with each landing pile counted once, reach the open-PR cap (PRs waiting for the captain's merge word and PRs labelled `held` count toward it, as below), `min(2 x S, 16)` unless declared (captain, 2026-11-21: 2 x S gives the speculative train enough queued PRs; S alone starved it). S itself no longer holds a PR opening: it is the drain exit and the fleet alarm's P comparison.
A draft PR is left out because GitHub says so (`isDraft`), and a promotion PR because its head branch is `staging`.
A PR waiting for the captain's merge word is left out only on positive evidence from a task record in a local home: the task recorded `yolo` that is not on, which waits for the captain's merge word by definition, or its backlog row is held for the captain and not done.
A PR of a ship in a remote home is read the same way from that home's cached summary, when it is less than two hours old; a missing or older copy is skipped with one `warning:` line and never changes the gate.
A PR no record shows to be waiting counts.
A PR another home holds (Slarti's Wednesday pile, a Navigator PR waiting for the captain's merge word) carries the GitHub label `held` (`HELD_LABEL` in `bin/fm-pr-drain.py`, the one definition).
The home that holds the PR sets the label at hold time and the same home removes it when the hold ends; firstmate sets and removes nothing.
The label leaves the PR out of the CI-slot count only: the drain's eligible count, `open` (P) and so the S comparison; it never frees a place under the open-PR cap, so labelled PRs still count toward the gate's cap, and the gate reports them as `N PR(s) labelled held use no CI slot but are counted`.
A PR that a task record shows waiting for the captain's merge word is treated the same way: it uses no CI slot but counts toward the cap, whether or not it is labelled (captain, 2026-11-22T12:51:39Z, card open-pr-cap-recorded-holds: "PRs held for Lee's word now count toward the open-PR cap"), and the gate reports it as `N PR(s) waiting for the captain's merge word`.
A PR that is both recorded and labelled counts once.
`bin/fm-pr-drain.py` counts every PR through one function, so `state`, `open` and `gate` read the same eligible PRs; the gate adds the held PRs to that count for the cap.
The gate reads the label from the open-PR list it already makes, with no extra GitHub call per PR.
An unreadable declaration or GitHub reads as `unknown`, and the worker opens the pull request as usual.
An unreadable task record leaves no PR out as held, so every ready PR counts and the gate can hold.
`config/open-pr-cap` holds one `<project> <cap>` line per project in the same format and is inherited the same way; a project that declares S and no cap line gets `min(2 x S, 16)`, and a project with no S has none.
The cap counts ready open PRs with each landing unit once, leaving out drafts and promotion PRs, and the gate reports it as `open-PR cap reached`.
A landing pile (a ready PR whose head branch starts `landing/pile-`) and the member PRs its body names in one `Member: PR n` or `Members in order: PR n and PR m` clause are one landing unit, counted as the pile.
The pile is counted because it is the PR that takes the CI slot: one exact-head gate runs on its merged tree, and its members wait unmerged inside it.
Only the member clause is read, so the pile that a nested pile is laid on is not mistaken for a member, and a draft pile folds nothing.
The drain's walk-back over closed PRs applies the same rule, and the gate reports the folded members as `N member PR(s) are counted in the landing pile`.
A brief declaring one of these `bin/fm-brief.sh --pr-drain` classes carries no CI slots check: `production-outage`, `cve`, `security` (unless its Linear item loses the exemption, above), `lee-explicit`, and the landing jobs `restack`, `red-gate-fix`, `returned-pr-fix` and `review`, which open no new PR.
The other drain classes (`wolverine`, `lee-research`, `officer`, `scheduled`) carry it, and a scout never does.
A promoted scout's instructions carry it too.
A malformed file makes the gate read `unknown`; it never refuses a spawn.
The fleet alarm announces a change only: a `working [key=ci-slots-over-<owner>-<repo>]` line when P, drafts left out, exceeds S and a `resolved` line with that key once P is back at or under S, each naming P and S ([Fleet quota and secondmate alarm](away-and-alarms.md#fleet-quota-and-secondmate-alarm-configfleet-alarmjson)).
[`bin/fm-project-capacity-lib.sh`](../../bin/fm-project-capacity-lib.sh) owns the file formats, the cap default and the held signal, [`bin/fm-pr-drain.py`](../../bin/fm-pr-drain.py) owns the open count, the gate and the exempt classes, [`bin/fm-ci-slots-held.sh`](../../bin/fm-ci-slots-held.sh) reads the held signal, [`bin/fm-ready-branch.sh`](../../bin/fm-ready-branch.sh) records and lists parked ready branches, and `bin/fm-project-mode.sh --ci-slots <name>` and `--open-pr-cap <name>` read S and the cap back.

## Admission by class (data/projects.md admission= token, config/admission/)

A project entry may name an admission config with `admission=<config>`, for example `- PropertyCompass2 [no-mistakes +yolo merger=slarti admission=pc2] - ...`, so that `bin/fm-pr-merge.sh` merges a PR only after the captain has answered for every class of change that needs the captain's word.
The name points at this home's `config/admission/<config>`, a LOCAL, gitignored file with one `command=` line naming the project's own diff classifier, one `classes=` line listing the classes that need the captain's word, and an optional `clear=` line listing the verdict words that need nothing:

```
command=scripts/ci/classify-diff.sh --risk --stdin
classes=payments legal-text data-rewriting-migration protected-gate production
clear=none
```

The classifier runs in the home's copy of the project, never the PR's head, so a PR cannot rewrite the classifier that judges it.
It reads the PR's changed paths on stdin, one per line and including a renamed file's old path, and prints verdict words on stdout; every word must appear in `classes=` or `clear=`, and at least one must be printed, so a classifier that ignores its mode and prints another verdict refuses rather than admitting every change.
For each flagged class the merge is refused until task `<task-id>-admit-<pr-number>-<class>`, held with the title `Admit <pr-url>: <class>`, carries the captain's answer, recorded through `bin/fm-captain-hold.sh answer`; the refusal names each class and prints the exact `hold` and `answer` commands.
An answer is bound to its PR and to the classes it was given for, not to a head: a later push that flags no new class keeps it, while a different PR or a newly flagged class needs the captain's word again.
The answer is the captain's words: as with any captain hold, firstmate merges only when those words say yes.
A missing or malformed config, a classifier that fails or prints an empty or undeclared verdict, an unreadable or incomplete changed-file list, and a forge other than GitHub all refuse the merge rather than skipping the check, and neither `yolo`, `--attended-override`, nor the away posture skips it.
An optional `route.<class>=handoff:<home>` line hands a flagged class to merger home `<home>` instead of the captain: the merge is refused even with a captain answer, and in place of the `hold` and `answer` commands the refusal prints the `[handoff=<home>]` merger-handoff line, keyed `merge-handoff-<pr-number>` so `bin/fm-decision-sweep.sh` settles it once the PR merges, telling that home to merge only after a fresh reviewer who did not write the change records on the PR that it loosens no check (a change that loosens one goes to the captain); routed classes that name more than one home refuse with no handoff, because one PR has one merger.
The routed class must be one of `classes=`, a route naming the `authority` class is a config error that refuses every merge, and a route naming the merging home itself refuses with no handoff, so a route never admits or merges anything in its own home.
A class with no route keeps the captain-answer path above, and in an office the route is pinned by the same `admission-sha256` as the rest of the config.
For example, a `config/admission/transcript-archive` (and `local-jev`, the same with its own rules file) for the Alchemist office hands the scan gate to Slarti and keeps deploy and unit changes with the captain:

```
command=/path/to/bin/fm-reserved-classify.sh --rules /path/to/config/admission/transcript-archive.rules
classes=authority scan-gate
clear=none
route.scan-gate=handoff:slarti
```

```
**/scrub.py scan-gate
**/archive.py scan-gate
**/private-projects.json scan-gate
**/pii_gate.py scan-gate
deploy/** authority
systemd/** authority
```

A master in the main home may write each home path as the literal token `@OFFICE_HOME@`: `bin/fm-home-seed.sh --office` copies the config with the token replaced by the office home, `bin/fm-office.sh publish` pins the digest of the master with the same replacement so it equals the digest of the office's own copy, and the main home reads the token as itself; a `--rules` path of `@OFFICE_HOME@/config/admission/<file>` reads the master's own `<file>`, and a master with literal paths is copied unchanged and seeds only the office home it names.
A project with no `admission=` token merges exactly as before, and like `merger=` the token is read from the merging home's own registry, which is not inherited.
`bin/fm-admission-lib.sh` owns the config format and classifier contract, `bin/fm-pr-merge.sh`'s header owns the merge-time check, and `bin/fm-project-mode.sh --admission <name>` reads the binding back.

### Path-rule classifier (bin/fm-reserved-classify.sh)

A project with no diff classifier of its own can use `bin/fm-reserved-classify.sh --rules <rules-file>` as its `command=`, for example `command=/path/to/bin/fm-reserved-classify.sh --rules /path/to/config/admission/firstmate.rules`.
The rules file is a LOCAL file in this home with one `<glob> <class>` rule per line; `#` comments and blank lines are ignored.
For each changed path the first matching rule decides its class, and a path matching no rule is clear.
The classifier prints the flagged classes sorted and one per line, or `none` when nothing is flagged, so `clear=none` and a `classes=` line naming every class the rules use complete the admission config.
Globs match the whole path and are case sensitive: `*` and `?` stay inside one path segment, `**` crosses segments (and `**/` also matches no directory), and `{a,b}` offers alternatives.
A rules file that is missing, has a line that is not exactly `<glob> <class>`, has an unbalanced brace, has a glob the platform's regex engine will not compile (BSD/macOS rejects an empty brace alternative such as `config{,.local}.json`, which glibc accepts), or names a class outside `[A-Za-z0-9._-]` (or `none`) makes the classifier exit 1 with nothing printed, so the merge is refused rather than admitted.
A path rule sees only paths, never content, so it cannot tell a data-rewriting change from an additive one; such classes stay with the captain.
`bin/fm-reserved-classify.sh`'s header owns the glob syntax and the refusal rules.

## Project git hooks (data/projects.md hooks= token)

A project entry may declare its own git hook installer with `hooks=<repo-relative path>`, for example `- PropertyCompass2 [no-mistakes +yolo hooks=scripts/install-git-hooks.sh] - ...`.
The installer must be a tracked file in the clone and only set the clone's `core.hooksPath`; only the token declares it, and firstmate never infers an installer from file names.
A clone whose installer never ran has no project hooks, so every commit made there skips the project's own pre-commit checks.
Project initialization runs the installer once after the clone exists, and `bin/fm-fleet-sync.sh` runs it after a successful refresh of any clone whose hooks are not live, printing one `<project>: hooks: repaired` or `<project>: hooks: failed: <reason>` line.
Fleet sync skips a clone it does not refresh (dirty, off its default branch, stuck, offline, or with no origin), so its hooks stay inert until `bin/fm-project-hooks.sh ensure <project>` runs by hand.
Session start prints a `HOOKS_INERT:` diagnostic for each registered clone whose declared hooks are not live, naming that command, and for each clone whose `hooks=` token is refused.
Live means the clone's own config sets `core.hooksPath` and the directory it names exists; the check ignores the `GIT_CONFIG_*` override that every firstmate-launched session injects.
A project with no `hooks=` token is never touched, and the registry is not inherited, so every home that clones the project must carry the token.
`bin/fm-project-mode.sh --hooks <name>` reads the binding back and refuses a malformed value, and `bin/fm-project-hooks.sh`'s header owns the check and repair.

## Ready evidence (data/projects.md ready-evidence= token, config/ready-evidence/)

A project entry may name a ready-evidence command set with `ready-evidence=<name>`, for example `- PropertyCompass2 [no-mistakes +yolo merger=slarti ready-evidence=pc-ready] - ...`.
The command set is the local, gitignored bash file `config/ready-evidence/<name>` in the same home, run from the project clone with the PR or review URL as `$1` and the named head as `$2`, under `bash -e -o pipefail` so every command in it must succeed.
It runs only where a done is registered: `bin/fm-pr-check.sh`, including the merge-time re-record that runs before the merge, and `bin/fm-review-check.sh`.
Each run records its verdict in the task's metadata as one `ready_evidence=<pass|fail> <head> <url> [<line>]` line, and a fail refuses the registration.
Every other done check, such as `bin/fm-crew-state.sh` and fleet snapshots, only reads that record and never runs a command: a recorded fail reads blocked with its line, and a done whose URL or head has no matching record reads blocked as not yet checked until registration runs the evidence.
The file lives in captain-private config rather than the project or the worker's copy, because a worker that can edit its own evidence check has no check.
A missing file, a missing clone, a malformed token, or a run longer than `FM_READY_EVIDENCE_TIMEOUT` seconds is a fail.
A local-only project has no registration step, so it must not register ready evidence.
Like `merger=`, the registry is not inherited, so every home that checks the project's handoffs must carry the token and the file.
A project with no `ready-evidence=` token keeps today's done gate exactly.
`bin/fm-project-mode.sh --ready-evidence <name>` reads the binding back, and `bin/fm-dod-lib.sh`'s header owns how the command set runs.

For PropertyCompass2, whose `scripts/claude-hooks/verify-pr-review.py` reads a PreToolUse payload on stdin and always exits 0, the command set tests the hook's decision and the PR body headings:

```bash
decision=$(printf '{"tool_name":"Bash","tool_input":{"command":"gh pr merge %s --merge --match-head-commit %s"}}' "$1" "$2" \
  | python3 scripts/claude-hooks/verify-pr-review.py)
printf '%s' "$decision" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null \
  || { printf '%s' "$decision" | jq -r '.hookSpecificOutput.permissionDecisionReason'; exit 1; }
body=$(gh pr view "$1" --json body -q .body | tr -d '\r')
for heading in Testing Risk 'How to revert'; do
  grep -Eq "^#+ $heading\$" <<<"$body" || { echo "PR body has no $heading heading"; exit 1; }
done
```

## PR text selection (data/projects.md pr= token)

A project with no `pr=` token keeps today's behavior: the no-mistakes pipeline's `pr` step writes the pull request title and body and refreshes them on every validated push.
A project whose outside maintainer reviews and merges, and whose hand-written PR text the pipeline would overwrite, is registered `[no-mistakes pr=manual]`.
`pr=manual` is the one accepted value, off by default, read like `forge=`: `bin/fm-project-mode.sh --pr <name>` reads it back, and its header owns the grammar and refusals.
It applies to a `no-mistakes` ship on a project with no `forge=` binding only, so the registry refuses it on `direct-PR`, which already leaves the PR text to the worker, on `local-only`, which opens no PR, and beside a forge.
Firstmate passes it to `bin/fm-brief.sh --pr manual` at intake the same way it passes `--forge`, `bin/fm-spawn.sh` refuses a brief whose `pr=` disagrees with the registry, and `bin/fm-promote.sh` reads it from the registry.
The generated brief then has the worker pass `--skip pr,ci` on every `no-mistakes axi run`, write the PR title and body itself, open or update the PR with `gh-axi`, and wait for the PR's checks; `bin/fm-dod-lib.sh` owns that text.
The token is the thin registry form of no-mistakes' own keep-text option, [kunchenguid/no-mistakes#1648](https://github.com/kunchenguid/no-mistakes/issues/1648), and is meant to map onto it once that exists.

## GitHub Enterprise hosts (config/github-hosts)

`config/github-hosts` is an optional local, gitignored file naming the GitHub Enterprise hosts whose pull request URLs this home accepts, one lowercase hostname per line, such as `leadsonline.ghe.com`.
The PR library reads `github-hosts` from `FM_CONFIG_OVERRIDE` when nonempty, otherwise from `$FM_HOME/config`, falling back when `FM_HOME` is unset or empty to `config/` under the library's own code root, captured when the library is sourced.
`github.com` needs no line and is always accepted.
Blank lines, `#` comments, and any other line authorize nothing: only a line equal to the host is a match, so the file cannot be made to allow more than it spells out.
An absent, unreadable, or symlinked file authorizes no Enterprise hosts.

GitHub pull request URLs are otherwise identical on every GitHub host, so a hostname's shape cannot show whether it is a GitHub host or a look-alike such as `github.com.evil`, and [`bin/fm-pr-lib.sh`](../../bin/fm-pr-lib.sh)'s `fm_github_host_allowed` accepts an Enterprise host only when this file names it.
That covers registration through `bin/fm-pr-check.sh`, the merge poll, `bin/fm-pr-merge.sh`, and the merge-outcome and teardown reads, which all carry the parsed host through `gh` and `gh-axi` via `GH_HOST`.
A host named here still needs its own `gh` authentication (`gh auth login --hostname <host>`), exactly as `gh` itself requires.

The file is local to each home and not part of secondmate inherited configuration, so a secondmate home that serves such a project names the host in its own copy.
The host is part of each recorded PR identity, so removing a host while a task's pull request is still open stops that task's merge monitoring rather than pointing it at another host.

## External review tool (config/external-review.md, config/external-review-url, config/external-review-backup)

These optional local, gitignored files configure a home's `forge=external` projects; a home with no such project needs none of them.

| File | Required | Meaning |
| --- | --- | --- |
| `config/external-review.md` | yes, for any `forge=external` scaffold or spawn | Worker instructions for the home's review tool: how to validate, upload, and read review state, and which state is the stopping point. `bin/fm-dod-lib.sh` appends it verbatim to the Definition of done under `## Review tool instructions (home configuration)`. |
| `config/external-review-url` | no | One extended regular expression a ready review URL must match in full. Without it, any `https://` URL with no whitespace, control characters, query, or fragment that is not a forge pull request URL is accepted. |
| `config/external-review-backup` | no | Line 1 names a git remote in the project clone that is the captain's personal backup remote; an optional line 2, `prefix=<ref-prefix>`, sets the backup ref prefix, default `backup/`. |

A missing, unreadable, or empty adapter stops the scaffold or spawn, as does an adapter carrying its own `Delivery contract: mode=` line, because a worker with no upload instructions would otherwise improvise a push.
A backup remote named `origin`, absent from the project clone, or pointing at one of origin's URLs stops the spawn, as does a backup prefix that is empty, invalid, or equal to or starting with the task branch prefix.
The files are static, never executed, and local to each home rather than part of secondmate inherited configuration.
`bin/fm-external-review-lib.sh`'s header owns the readers, and [`docs/external-review-forge.md`](../external-review-forge.md) owns the backup rule and its teardown consequence.
