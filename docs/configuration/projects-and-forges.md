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

## Merger home (data/projects.md merger= token)

A project entry may name the one home that merges its PRs with `merger=<home>`, the merging home's secondmate id or `main` for the primary home, for example `- PropertyCompass2 [no-mistakes +yolo merger=slarti] - ...`.
`bin/fm-pr-merge.sh` then refuses a merge from any other home before any forge call, naming the merger and printing the one command that hands the PR to it.
In a secondmate home that command appends a stamped `needs-decision [key=merge-handoff-<PR number>] [cause=external]: [handoff=<home>] <PR URL> is ready to merge` line to the home's parent channel (the destination `fm_parent_channel_destination` in [`bin/fm-parent-channel-lib.sh`](../../bin/fm-parent-channel-lib.sh) resolves), and the main home relays it to the merger; in a home with no parent it is `bin/fm-send.sh fm-<home>` with that same line.
`bin/fm-pr-check.sh` publishes that same line itself when a ship task's PR is registered in any other home, once per PR and head, delivered the same way: on the parent channel, or with `bin/fm-send.sh fm-<home>` in a home with no parent; a secondmate home with a local parent route whose parent records the merger as a secondmate instead delivers it straight into the merger's inbox through that parent home's `bin/fm-send.sh` (fire-and-forget, one delivery id per PR head) and leaves only a silent `working` line on the parent channel, falling back to the keyed `needs-decision` line when the delivery fails; a task held for the captain and the merger home itself publish none, and its header owns the rules.
A no-mistakes worker releases its own run with `no-mistakes axi handoff` before its checks-green done line, as its brief's done step says.
Once a handed-off no-mistakes ship reports that PR checks green, `bin/fm-pr-check.sh` also runs `no-mistakes axi handoff` in the task's copy, unless `no-mistakes axi status` there already reads handed_off, at registration or on the watcher's next check sweep (`fm-pr-check.sh release`), so the run stops holding one of the machine's pipeline slots while it waits for the merger; each PR head is attempted once and a failed attempt is reported once (a `check: nm-release:` wake from the sweep), and the same header owns the rules.
On a Herdr or Rex home the watcher's check sweep (`bin/fm-tree-park.sh sweep`) also returns a handed-off ship's copy to the pool once its worker reported the PR and any no-mistakes run was released, when the copy is clean and its head is the pushed PR head, keeping the task record, and a later text steer to the task leases a fresh copy at the PR's current head, which a restack may have moved, and relaunches the worker before the steer is recorded; a park that fails after stopping the worker is reported once as a `check: tree-park:` wake, and that script's header owns the rules.
The watcher's check sweep also runs `bin/fm-nm-stall-check.sh sweep`, which reads `no-mistakes axi status` in each local no-mistakes ship's copy and raises one `check: nm-stall:` wake when a run has sat pending with no step started for 5 minutes while a run slot is free, or parked at a gate for 30 minutes with no answer.
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
It refuses a squash or rebase before any forge call, naming the project and the token, in any spelling the caller passes: `--squash`, `--rebase`, `--method squash`, `--method=rebase`, and gh's short flags `-s` and `-r`.
A merge commit adds no squash summary, even with `config/pr-squash-summary` present.
A project with no `merge=` token keeps today's defaults exactly: squash on GitHub, and the repository's own style on Forgejo.
`merge=commit` is the only value, and a malformed value refuses the merge rather than falling back to the default it exists to stop.
Like `merger=`, the token is read from the merging home's own `data/projects.md`, which is not inherited, so every home that could merge the project must carry it on its own registry line.
`bin/fm-project-mode.sh --merge-method <name>` reads the binding back, and its header owns the grammar and refusals.

## Landing lag (data/projects.md landing-lag= token)

A project entry may limit how long its oldest ready PR may wait to land with `landing-lag=<hours>`, a positive whole number of hours, for example `- PropertyCompass2 [no-mistakes +yolo merger=slarti landing-lag=48] - ...`.
While any ready PR for the project on this machine has waited longer than that, `bin/fm-spawn.sh` launches no new ship for it: it creates nothing, leaves the backlog item queued, prints one `deferred:` line naming the oldest ready PR and its age, and exits 75, exactly like a [project capacity](../configuration.md#project-capacity-configproject-capacity) deferral.
A PR's wait starts when `bin/fm-pr-check.sh` first records it as ready, and ready PRs in every local home on this machine count, while remote homes do not.
Only a ready PR that can land counts: one whose task records `yolo=off` waits for the captain's merge word, so it does not count, and neither does one whose task's row in its home's backlog is held for the captain (`bin/fm-captain-hold.sh`) or has an unresolved `blocked-by` dependency.
A ship spawned with `--landing-exempt` is never held, and that flag is how a fix or landing work is marked; a relaunch, a scout, and a secondmate are never held either.
When a ready PR's wait is unknown, because it was recorded before ready times existed or its home's backlog cannot be read, the spawn goes ahead with one `warning:` line, unless another ready PR is already known to exceed the limit.
A value that is not a whole number of hours refuses every fresh ship spawn for the project until it is corrected.
A project with no `landing-lag=` token is never held, and the token is read from the spawning home's own `data/projects.md`, so each home that dispatches the project carries it on its own line.
Two parts of the admission rule are known limits, by the captain's decision, until firstmate has a signal for them: a paused landing is not read, and a ready PR held for a release day counts like any other. A merged PR also counts until its task is cleaned up, so choose a limit with those in mind.
[`bin/fm-project-capacity-lib.sh`](../../bin/fm-project-capacity-lib.sh) owns which records count and how an unreadable signal is handled, and `bin/fm-project-mode.sh --landing-lag <name>` reads the limit back.

## PR drain (open-PR drain rule)

A project whose clone's origin is on github.com is in PR drain from the moment its repository has 20 or more open PRs until its open count reaches 0.
The state is derived from GitHub on every read, so every home on every machine sees the same answer with no shared marker: below 20 and above 0, the PRs closed in the last 14 days are walked back from now to whichever of 20 or 0 came last, and no write ever reaches the repository.
While a repository is in drain, `bin/fm-spawn.sh` launches no fresh ship for it unless the brief declares a class with `bin/fm-brief.sh --pr-drain <class>`: an exemption class (`production-outage`, `cve`, `security`, `wolverine`, `lee-research`, `lee-explicit`, `officer`, `scheduled`) or a landing job (`restack`, `red-gate-fix`, `returned-pr-fix`, `review`).
An undeclared ship is deferred exactly like a [project capacity](../configuration.md#project-capacity-configproject-capacity) deferral: one `deferred:` line naming the repository, its open count and the flag, exit 75, nothing created and the item still queued.
When GitHub cannot be read, or 14 days of history hold neither 20 nor 0 (or hold 1000 or more closed PRs, the GitHub search cap), the state is unknown and the spawn launches with one `warning:` line; scouts, relaunches and secondmates are never held.
Every ship brief that opens a pull request (no-mistakes or direct-PR on a forge with pull requests) and declares no `--pr-drain` class carries a PR drain check in its Definition of done: just before opening a new pull request the worker runs `bin/fm-pr-drain.py state` in its worktree, and while that prints `on` it pushes its branch only, opens no pull request and reports the branch; at `off`, `unknown` or `none` it opens the pull request as usual. A worker whose branch already has an open pull request, such as an unclassed fix to a returned or red PR, skips the check and finishes through its Definition of done, /no-mistakes included.
A ship brief scaffolded with `--project` while its repository is in drain also gets a `# PR drain` section saying so, unless its class is `production-outage`, `cve`, `security` or a landing job; for the other exemption classes that section carries the same check.
A brief declaring `lee-explicit` (the captain's own explicit instruction) is refused at spawn unless its `## Captain's intent` section holds at least one double-quoted span and an ISO-8601 UTC timestamp such as `2026-11-16T18:19:06Z` on the same line or the line before it; the refusal names what is missing, and the quote itself is not verified.
A brief declaring `security` (a high or critical security fix, which starts at once) must name its Linear item with `bin/fm-brief.sh --linear <PC-n>`, and while the repository is in drain `bin/fm-spawn.sh` refuses it unless a read-only Linear query shows that item carries the label `security` (any case) and priority Urgent (1) or High (2); the refusal names the item and what is missing, including when Linear cannot be read, and no launch happens on an unverified item. Out of drain, or when the drain state is unknown, it launches like any other brief with no Linear read.
[`bin/fm-pr-drain.py`](../../bin/fm-pr-drain.py) owns the state, the window and the accepted classes, and the fleet alarm announces each change ([Fleet quota and secondmate alarm](away-and-alarms.md#fleet-quota-and-secondmate-alarm-configfleet-alarmjson)).

## CI slots (config/ci-slots)

The optional local, gitignored `config/ci-slots` declares, per project, the total concurrent gate and admission slots across every host (S), so the ready open-PR queue (P) never outgrows them, because a longer queue drains slower as its branches fall behind staging.
It holds one `<project> <slots>` line per project, in the same format as [project capacity](../configuration.md#project-capacity-configproject-capacity): the project's registered name, then a positive whole number, with `#` comments and blank lines ignored.
The main home writes it (for PropertyCompass2 today, `PropertyCompass2 4`, Slarti's 2 slots plus Deep Thought's 2; to be confirmed with Slarti), and the inherited-local-material push copies it to every second-mate home, local and remote, so each dispatching home reads its own copy.
A project with no line is never held.
The slots hold PR openings, never ship starts (captain, 2026-11-21): `bin/fm-spawn.sh` reads neither S nor the cap, so a ship always starts and builds to a finished, verified branch.
A brief for a ship of a project that declares S carries a CI slots check that the worker runs just before it opens a pull request, as it does the [PR drain](#pr-drain-open-pr-drain-rule) check: `python3 bin/fm-pr-drain.py gate . <project>`.
While it prints `hold`, the worker opens no pull request and does not run `/no-mistakes`, pushes the branch, reports `done: branch <branch> pushed, no PR (CI slots)` and stops, and firstmate opens the pull request when a place frees.
The worker's own tests and gate ran before it parked the branch, and the no-mistakes review runs when the branch is released, so nothing reaches a pull request unvalidated.
Firstmate records that parked branch with `bin/fm-ready-branch.sh <task> <branch>`, which appends `ready_branch=<branch>` to the task record, and a recorded ready branch frees the ship's [project capacity](../configuration.md#project-capacity-configproject-capacity) place exactly as a recorded ready PR does, so parked branches never fill the places.
`bin/fm-ready-branch.sh list` prints `<task> <branch> <project>` for each recorded ready branch with no PR; on every heartbeat and after any PR of the project lands, firstmate re-runs the gate and, while it prints `open`, releases parked branches by steering or relaunching each ship's worker to run `/no-mistakes` on the branch, which validates it and opens the PR ([ship landing](../../.agents/skills/ship-landing/SKILL.md)).
Each released worker re-runs its own pre-PR gate check, which is the race guard, and on `hold` simply parks again; a brief overshoot of S by a PR opened at the same time from another home is accepted.
The gate holds when P, the ready open PRs on the project's GitHub repository less drafts and less PRs waiting for the captain's merge word, reaches S, or when every open PR reaches the open-PR cap.
A draft PR is left out of P because GitHub says so (`isDraft`).
A PR waiting for the captain's merge word is left out only on positive evidence from a task record in a local home: the task recorded `yolo` that is not on, which waits for the captain's merge word by definition, or its backlog row is held for the captain and not done.
A PR no local record shows to be waiting counts, and so does a PR whose task lives in a remote home, which is never walked.
A PR held for a release day (Wednesday) counts too: firstmate has no signal for it, so the gate leaves out only the classes it can detect.
That Wednesday-hold signal is tracked as a follow-up under Linear FLEET-145 (backlog item `wednesday-hold-signal`).
An unreadable declaration or GitHub reads as `unknown`, and the worker opens the pull request as usual.
An unreadable task record leaves no PR out as held, so every ready PR counts and the gate can hold.
The open-PR cap is separate from S because drafts and held PRs still fall behind staging and cost rebase work.
`config/open-pr-cap` holds one `<project> <cap>` line per project in the same format and is inherited the same way; a project that declares S and no cap line gets a cap of 12 (captain, 2026-11-21), and a project with no S has none.
The cap counts every open PR, drafts and held ones included, and the gate reports it as `open-PR cap reached`.
A brief declaring one of these `bin/fm-brief.sh --pr-drain` classes carries no CI slots check: `production-outage`, `cve`, `security`, `lee-explicit`, and the landing jobs `restack`, `red-gate-fix`, `returned-pr-fix` and `review`, which open no new PR.
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
