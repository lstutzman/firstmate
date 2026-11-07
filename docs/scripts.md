# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each row is one purpose clause only: the script's own header comment is the authoritative description of its behavior, flags, and contracts, so read the header before first use.
If you have changed away from the firstmate home in an interactive shell, invoke these scripts by absolute path through the repo's `bin/` directory; the scripts self-locate internally after they start.
The shared no-mistakes gate lifecycle boundary is summarized in [architecture.md](architecture.md#no-mistakes-gate-authority-boundary), while `docs/sessionstart-nudge.md` covers the silent session-open hook use; `fm-gate-refuse-lib.sh`'s header owns its exact contract.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `fm-session-start.sh`    | Compose lock, bootstrap, and wake drain into the single ordered session-start digest |
| `fm-sessionstart-nudge.sh` | Print the native session-start hook nudge when the primary has not already run the digest |
| `fm-sessionstart-run.sh` | Route a native session-open hook to the full digest, a context re-emit, or the nudge |
| `fm-operational-input.sh` | Construct and parse the canonical cross-language operational-input protocol |
| `fm-bootstrap.sh`        | Detect toolchain and fleet problems, run the locked session-start sweeps, and install approved tools |
| `fm-startup-network.sh`  | Run session start's network checks and inactive-outcome scan off its blocking path, retaining reports and durable findings |
| `fm-fleet-sync.sh`       | Refresh project clones with safe fast-forwards, self-heals, `STUCK:` reports, branch pruning, and bounded recovery from an orphaned `.git/packed-refs.lock` |
| `fm-fleet-snapshot.sh`   | Print structured fleet snapshot JSON and refresh only its parent-side remote-ledger cache (schema `fm-fleet-snapshot.v1`) |
| `fm-home-summary-refresh.sh` | Atomically publish this home's structured summary ledger                         |
| `fm-fleet-ledger.sh`     | Append the opt-in fleet activity ledger's records ([contract](fleet-ledger.md))      |
| `fm-fleet-view.sh`       | Render the fleet snapshot as a human Markdown view                                   |
| `fm-bearings-snapshot.sh` | Project the bounded remote-ledger fleet snapshot to compact TOON; `--include-prs` adds live GitHub enrichment |
| `fm-bearings-board.sh`   | Build and arm the stable interactive `/bearings lavish` fleet board                  |
| `fm-secondmate-reconcile.sh` | Queue Bearings reconcile requests for later supervision delivery and ask each mismatched home through its durable inbox with a per-home cooldown |
| `fm-update.sh`           | Guarded self-update of firstmate and local or remote secondmate homes, reconciling redundant divergence and classifying every live mate left on the target commit for restart or fallback nudge |
| `fm-secondmate-restart.sh` | Persist open conversational work, then restart eligible second mates or report the fallback outcome |
| `fm-secondmate-restart-lib.sh` | Shared second-mate restart capability and persistence-request contract |
| `fm-on.sh`               | Execute one tracked Firstmate command in a configured remote secondmate home, using its job worker except for the doctor bootstrap |
| `fm-remote-job-lib.sh`   | Shared bounded remote job queue, worker readiness, LaunchAgent contract, and filesystem-composed PATH |
| `fm-remote-job-worker.sh` | Long-lived remote queue worker for tracked `fm-*.sh` commands in the account runtime |
| `fm-remote-job-reap-orphans.sh` | Stop remote job workers left running by a pruned code root, never one whose checkout still exists |
| `fm-remote-doctor.sh`    | Check, and with `--fix` repair, one remote account's [second-mate readiness](remote-secondmates.md#readiness-repair-and-the-human-steps) |
| [`fm-backlog-handoff.sh`](../bin/fm-backlog-handoff.sh) | Move queued backlog items into a secondmate home; its header owns route-specific wake outcomes and retries |
| `fm-backlog-receive.sh`  | Idempotently ingest one confined remote handoff outbox through tasks-axi             |
| `fm-captain-hold.sh`     | Hold tasks for the captain, record the captain's answers, gate investigation completion, report record divergence between the status log and the backlog, and apply or log a non-reserved call's deadline default |
| [`fm-pending-reply-sweep.sh`](../bin/fm-pending-reply-sweep.sh) | Dry-run by default; with `--apply`, settle an escalated pending-reply record whose escalation decision is already closed in its parent status log; every still-open escalation is listed for `review` with its reason and closes only when named with `--apply --key <key>` and its delivery was confirmed; other phases, unproven, undelivered-closed and backlog-handoff-named records are never closed; its header owns the rules |
| [`fm-decision-sweep.sh`](../bin/fm-decision-sweep.sh) | Dry-run by default; with `--apply`, mark an open `merge-handoff-<n>` decision resolved once PR `<n>`, the one PR URL it names, is merged, and an open decision or blocker resolved once the PR its `[dep=pr/<owner>/<repo>/<n>]` tag names is merged; the watcher runs `--settle-only --apply` on its own cadence; other decisions whose named PRs all merged are listed for `review` and close only when named with `--apply --key <key>`; closed-unmerged, open, unreadable and `[truncated]` decisions, `captain-hold-` and `pending-reply-` keys, and decisions without a PR URL are never closed; its header owns the rules |
| `fm-decision-hold.sh`    | One-release compatibility shim mapping the retired decision commands onto fm-captain-hold.sh |
| `fm-brief.sh`            | Scaffold ship (explicit `--mode`, plus the project's registered `--forge` and `--pr`), scout, secondmate-charter, office role-charter (`--office`), and Herdr-lab briefs, with Captain's intent and Firstmate spec subsections on ship/scout |
| [`fm-dod-lib.sh`](../bin/fm-dod-lib.sh) | Own ship/scout worker role scope, ship definitions of done, the named-head reachability gate and the recorded ready-evidence gate on ship `done:` acceptance, and the no-mistakes `--intent` contract |
| `fm-brief-heading-lib.sh` | Single owner of reading a brief's sections, shared by the `--intent` contract, spawn and promotion validation, and `fm-dispatch-resolve.sh` |
| `fm-herdr-lab.sh`        | Provision and guardedly operate an isolated, never-default Herdr lab session         |
| `fm-herdr-lab-viewer.py` | The pty engine behind `fm-herdr-lab.sh viewer`: one real foreground Herdr client on a non-zero window grid |
| `fm-hc-lab.sh`           | Provision and guardedly operate an isolated, never-default herdr-core (`hc`) lab session with a fleet-state tripwire and a serve/hold daemon sweep |
| `fm-lab-home.sh`         | Mint disposable lab homes and manage their isolated tmux socket directories       |
| `fm-live-lab.sh`         | Build and operate a disposable live supervision lab; see its header for usage and readiness contract |
| `fm-install-herdr.sh`    | Install CI's exact-version Herdr pin with official asset URL, SHA-256, and protocol checks |
| `fm-install-hc.sh`       | Install the pinned, checksum-verified herdr-core (`hc`) build used by the tests-hc lane and operators |
| `fm-install-treehouse.sh`| Install CI's exact-version Treehouse pin for real-Herdr E2E that needs spawn worktrees |
| `fm-install-pinned.sh` | Install the pinned, SHA-256-verified treehouse or no-mistakes release for fleet bootstrap (pins live in `fm-install-pins.sh`) |
| `fm-herdr-ci-cleanup.sh` | Snapshot and tear down only job-owned `fm-lab-*` sessions in the Herdr CI lane       |
| `fm-hc-ci-cleanup.sh`    | Snapshot and tear down only job-owned `fm-hclab-*` sessions in the herdr-core CI lane |
| `fm-rex-marks.sh`        | Opt-in: turn each Rex task's latest status into one badge and notification on its pane, plus validation progress and an optional tint (`plan`, `sync`, `clear`); the watcher runs `sync` each poll while the option or a cached record exists, and cleanup runs `clear` |
| `fm-osc7501.sh`          | Launch-driven [OSC 7501 worker status bridge](configuration.md#osc-7501-worker-status-reporting); its header owns commands and reporting rules |
| `fm-test-run.sh`         | Behavior-test runner: selection, portable lanes, bounded concurrency, budgets, coverage guard, timing/JSON; refuses to execute in the repository primary checkout when `FM_TASK_ID` marks a task worker |
| `fm-test-isolation-proof.sh` | Concurrent isolation harness and portable candidate set owner |
| `fm-ensure-agents-md.sh` | Manually initialize project agent-memory files (see the helper's header and help) |
| `fm-capacity.sh`         | Report of open lanes against the optional `config/lane-capacity` target and host headroom for queued-work dispatch; `--publish` writes this home's `state/lane-capacity.json` |
| `fm-guard.sh`            | Warn on primary-checkout tangles, main-session pending wakes, and unhealthy supervision |
| `fm-primary-scope-lib.sh` | Shared marker-or-plain-checkout primary-home predicate for tracked hooks             |
| `fm-session-lock-lib.sh` | Shared session-lock ownership from harness ancestry, a trusted Claude session id, or on Windows/Git Bash a published harness pid, for fm-lock.sh and the Claude Stop auto-arm, plus the reclaim verdict recovery callers apply, the ps-free identity fallback behind it, and the read-only lock inspection behind `fm-lock.sh status` and `fm-inbox.sh ready` |
| `fm-procinfo.py`         | Read one pid's ppid, comm, and args through macOS kernel syscalls when the `ps` binary cannot execute |
| `fm-claude-stop-autoarm.sh` | Claude Stop `asyncRewake` hook owning tokenless watcher continuity with single-flight exit-2 rewake (docs/watcher-continuity.md) |
| `fm-turnend-guard.sh`    | Shared primary turn-end guard predicate so no turn ends blind (docs/turnend-guard.md) |
| `fm-turnend-guard-grok.sh` | Grok Stop-hook adapter for the primary turn-end guard                              |
| `fm-kimi-turnend-hook.sh` | Surgically install or remove Kimi's guarded global crew turn-end hook                |
| `fm-arm-pretool-check.sh` | Stable PreToolUse transport for the watcher-arm command policy (docs/arm-pretool-check.md) |
| `fm-arm-command-policy.mjs` | Semantic owner of the watcher-arm PreToolUse policy (docs/arm-pretool-check.md)   |
| `fm-subagent-pretool-check.sh` | Primary-home delegation-shape PreToolUse guard (docs/subagent-guard.md) |
| `fm-supervision-instructions.sh` | Render the session-start primary-harness supervision block or the one-line repair instruction |
| `fm-home-seed.sh`        | Transactionally provision a local secondmate home, or an office home with `--office`, and maintain `data/secondmates.md` |
| `fm-remote-home-seed.sh` | Register and provision a whole secondmate home on an SSH-reachable host              |
| `fm-remote-readiness-lib.sh` | Shared remote second-mate readiness gate: check and, when needed, repair then re-check through `fm-remote-doctor.sh` |
| [`fm-project-origin-lib.sh`](../bin/fm-project-origin-lib.sh) | Accepted origin-form owner shared by both remote provisioning boundaries |
| `fm-spawn.sh`            | Spawn crewmates, scouts, `id=repo` batches, and secondmates on the resolved harness and runtime backend |
| [`fm-approval-failover.sh`](../bin/fm-approval-failover.sh) | Save a captain-approved managed-approval fallback and recover a worker after observed defeated bypass |
| `fm-git-strip-ai-trailers.sh` | Strip known AI commit trailers at commit-msg time and install that hook, plus any forge=external push guard, for a fleet launch |
| `fm-git-push-guard.sh`  | Refuse a forge=external task's pushes to the shared origin and of task-prefixed branches, and write its per-task guard record ([design](external-review-forge.md)) |
| `fm-backend.sh`          | Runtime-backend selection, meta helpers, selector resolution, and operation dispatch |
| `fm-backend-hometag-lib.sh` | Shared per-installation home-tag derivation for zellij tab, cmux workspace, and tern session titles |
| `fm-composer-lib.sh`     | Single fleet-wide owner of composer shapes, capability-aware screen classification, and verdicts |
| `fm-agent-process-lib.sh` | Backend-neutral harness-process name classifier shared by recovery-grade adapters |
| `backends/tmux.sh`       | Verified tmux session-provider adapter                                               |
| `backends/herdr.sh`      | Herdr session-provider adapter with its own required CI lane                         |
| `backends/zellij.sh`     | Experimental zellij session-provider adapter                                         |
| `backends/orca.sh`       | Experimental Orca backend adapter owning both worktree and terminal                  |
| `backends/cmux.sh`       | Experimental cmux session-provider adapter                                           |
| `backends/paseo.sh`      | Experimental Paseo session-provider adapter                                          |
| `backends/rex.sh`        | Experimental Rex session-provider adapter                                            |
| `backends/t3code.sh`     | Experimental T3 Code adapter driving the agent session through `fm-t3-mcp.mjs`       |
| `backends/tern.sh`       | Experimental tern session-provider adapter                                           |
| `fm-config-push.sh`      | Push declared inherited local material to live local or remote secondmates and send the placement-specific config reread when changed |
| `fm-project-mode.sh`     | Resolve a project's registered delivery posture, forge binding, PR-text binding, ship-branch prefix, merger home, landing-lag limit, or ready-evidence name from `data/projects.md` for fleet sync, home seeding, the forge and PR-text agreements a ship spawn or scout promotion applies, the merger-home refusal, landing-lag admission, and the ready-evidence gate |
| `fm-forge-detect.sh`     | Propose a clone's forge binding from its origin remote for project-add intake, never recording it |
| [`fm-merge-local.sh`](../bin/fm-merge-local.sh) | Fast-forward a `local-only` project's local default branch to the approved recorded commit |
| `fm-review-diff.sh`      | Review a crewmate branch or resolved PR head against the authoritative base          |
| `fm-marker-lib.sh`       | Compatibility entry point for the from-firstmate carrier owned by `fm-operational-input.sh` |
| `fm-task-inbox-lib.sh`   | Single owner of durable steering-inbox records, acknowledgement, doorbells, and the delivery-attempt ladder |
| `fm-task-inbox.sh`       | The worker's glob-safe `take` command: print each waiting steering record in order and file it into `handled/` |
| `fm-lee-step.sh`         | Render a command the captain must run by hand: `bash` when `config/lee-step-host` names the target, else `ssh -t`, with the cause no agent can run it |
| `fm-worktree-assert.sh`  | Refuse, naming the exact directory, unless the current directory is the worktree a task record names (a restored worker's first check) |
| `fm-pending-reply-lib.sh` | Parent-owned secondmate pending-reply expectations, recovery, and keyed escalation lifecycle |
| `fm-secondmate-report.sh` | Optional helper that resolves the parent channel itself and appends a correlated status or document-pointer report |
| `fm-extension.mjs`       | Bind, inspect, verify, and strictly invoke trusted external process-event adapter packages |
| `fm-extension-launch-barrier.mjs` | Publish one exact static core-owned invocation group before package code runs |
| `fm-t3-mcp.mjs`          | T3 Code `/mcp` client: captain-run sign-in, capability gate, and the thread verbs the t3code adapter calls (docs/t3code-backend.md) |
| `fm-t3-answer.sh`        | Read or answer a recorded T3 worker's pending questions                              |
| `fm-t3code-codex-env.sh` | Manage the T3 environment overlay on tracked Codex project configuration              |
| `fm-extension.sh`        | Expose extension binding commands through the tracked shell and remote-home command boundary |
| `fm-procevent.sh`        | Register, supervise, capture, classify, acknowledge, and safely retire built-in or explicitly bound process-event sources |
| `fm-procevent-remote-reply.sh` | Relay the remote-secondmate status stream through non-destructive process-event deltas |
| `fm-procevent-quota.sh`  | Wake Firstmate when tracked quota drops below a threshold, is exhausted, or cannot be polled |
| `fm-procevent-when.sh`   | Fire a trust-bound deterministic action at most once when its registered condition holds, then wake with the outcome |
| `fm-gate-refuse-lib.sh`  | Shared gate-context lifecycle boundary for real and lab homes                      |
| `fm-watch-arm.sh`        | Verified home-scoped watcher arm wrapper with loud cycle endings and bounded lifecycle ledger |
| `fm-codex-stop-park.sh`  | On an opted-in home, register verified native Codex sessions and park supervision in the asynchronous Stop hook, delivering wakes through the native thread queue |
| `fm-watch-checkpoint.sh` | Run one bounded foreground watcher checkpoint for Codex-style supervision            |
| `fm-watch.sh`            | Singleton-safe watcher: absorb benign wakes, detect stalled local-secondmate wake queues, and exit on actionable ones |
| `fm-inactive-reconcile.sh` | Reconcile long-inactive direct crewmate terminal outcomes without forge access |
| `fm-retention.sh`        | Daily archive pass: handled process-event sequences older than 72 h are copied into `state/archive/` and their results emptied; settled resolved pending-reply records older than 7 days are archived there and removed; its header owns the rules |
| `fm-afk-contract.sh`     | Own the away-or-quiet record's posture, schema, entry, read-back, archive, and cross-subsystem authority lock |
| `fm-afk-start.sh`        | Run the common sourceable away-mode daemon entry in the foreground                      |
| `fm-afk-launch.sh`       | Own away/quiet entry (same-turn record write, then read-back), exit, rollback, and any backend terminal lifecycle |
| `fm-afk-return.sh`       | Own deterministic return shutdown, the return brief, catch-up evidence, and the firstmate-actionable blocker gate |
| `fm-supervisor-target-lib.sh` | Resolve the shared supervisor target and backend for the daemon and launcher       |
| `fm-supervise-daemon.sh` | Presence-gated away-mode sub-supervisor: self-handle routine wakes, guard injection by the detected primary harness, escalate batched digests, alert on failed delivery |
| `fm-crew-state.sh`       | Print one deterministic current-state line for a crew                                |
| `fm-claude-limit-lib.sh` | Own what Claude Code's usage-limit prompt says on a pane: the stated reset time and the instant it means |
| `fm-limit-resume.sh`     | Recover one crewmate stalled on Claude Code's usage-limit prompt once its stated reset has passed |
| `fm-nm-drive-steer.sh`   | Send a quiet no-mistakes ship one fixed steer when its validation never started or nothing drives its active run |
| `fm-nm-run-lib.sh`       | Single owner of shared no-mistakes run-attribution primitives and rules             |
| `fm-pipeline-spend.sh`   | Attribute a task's no-mistakes pipeline spend to the task and keep it in the private spend ledger |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification          |
| `fm-timeout-lib.sh`      | Single owner of hard-bounded command execution and its fallback watchdog |
| `fm-timing-lib.sh`       | Single owner of the deferred network stage's per-step elapsed-time records, inert unless a run asks for them |
| `fm-supervision-lib.sh`  | Shared in-flight-work-without-fresh-watcher-beacon predicate                         |
| `fm-ff-lib.sh`           | Shared guarded fast-forward/reconcile helper for origin pulls and secondmate syncs, with durable divergence markers |
| `fm-git-retry-lib.sh`    | Bounded retry (3 tries, 2 s then 5 s) of a git fetch or clone that fails only on its first ssh connection; never retries a push rejection or missing ref |
| `fm-lock-lib.sh`         | Shared "is this git lock provably abandoned?" proof used by teardown and fleet-sync   |
| `fm-config-inherit-lib.sh` | Shared primary-to-secondmate inherited local-material propagation and config-reread delivery |
| `fm-tasks-axi.sh`        | Run `tasks-axi` against this home's backlog from any working directory               |
| `fm-tasks-axi-lib.sh`    | Shared backlog-backend selector and `tasks-axi` compatibility probe                  |
| `fm-backlog-transition-lib.sh` | Pair task-record changes with their backlog transitions and replay interrupted closes |
| `fm-quota-axi-lib.sh`    | Shared `quota-axi` compatibility floor and quota snapshot schema validation           |
| `fm-credential-source-lib.sh` | Single owner of the declared credential-source schema and its adapters, read by `fm-dispatch-resolve.sh` and checked by `fm-bootstrap.sh` |
| `fm-quota-choose.sh`     | Choose the first candidate with known positive quota from an ordered harness:model list |
| `fm-vendor-auth-probe.sh`| Run one hard-bounded, non-destructive authentication probe of a named vendor CLI and report the fact |
| `fm-wake-drain.sh`       | Present and acknowledge the current actor's claimed wake rows alongside status, outcome-backstop, decision, divergence, deadline-default, supervision-host outcome, recovery, and supervision checks |
| `fm-wake-grant.sh`       | Serialize Pi supervision-branch wake-row claim activation, publication, release, and deactivation |
| `fm-wake-lib.sh`         | Shared durable wake queue, recovery generations, portable locks, and watcher identity/health helpers |
| `fm-path-lib.sh`         | Fork-free `dirname`/`basename` equivalents with no source-time side effects             |
| `fm-classify-lib.sh`     | Shared wake classification, durable keyed-decision folds and scans, unread status selection, home-owned status-append ranges, and bounded latest-event snapshots |
| `fm-send.sh`             | Steer a task via a durable inbox record plus doorbell, or send a supported key or typed harness invocation through the recorded backend |
| `fm-branch-prompt.sh`    | Emit the shared supervision branch's byte-stable system prompt ([pi-supervision-branch.md](pi-supervision-branch.md), [supervision-host.md](supervision-host.md)) |
| `fm-branch-outcome.sh`   | Own the supervision branch's append-only outcome store, cursors, bounded status-coverage indexes, and session-start replay |
| `fm-lease.sh`            | Claim, release, inspect, and sweep per-task supervision leases                       |
| `fm-lease-lib.sh`        | One owner of the supervision lease contract and the main-only role-partition guards  |
| `fm-control.sh`          | Agent lifecycle control plane: allowlisted `interrupt`, `exit`, and transactional `relaunch` verbs for an exact task id ([agent-control.md](agent-control.md)) |
| `fm-control-lib.sh`      | One executable owner of the control-plane verb allowlist, per-harness interrupt/exit mechanics, per-backend capability, and the endpoint-absence proof both `exit` and `relaunch` read |
| `fm-busy-lib.sh`         | Single owner of the semantic busy-state contract: verdicts, source attribution, per-harness sources, and the optional Pi model-stream evidence and ordering contract |
| `fm-busy-event.sh`       | The only writer of task busy and progress evidence under the contract in `fm-busy-lib.sh`; its header and help own lifecycle and optional stream operations |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for composer capture, verified submit, and the submit-time busy check |
| `fm-peek.sh`             | Print a bounded tail of a crewmate endpoint                                          |
| `fm-check-register.sh`   | Bind an intentional custom watcher check to its current bytes                       |
| `fm-check-unregister.sh` | Retire a custom watcher check and its trust binding by validated task id            |
| `fm-check-lib.sh`        | Validate custom-check registrations and prepare private execution snapshots          |
| `fm-tool-update-check.sh` | Report watched tooling with an update available, and updates installed but left inert by PATH order |
| `fm-watch-backstop.sh`   | Per-home timer check that rings a home's own session once per stale episode when supervision stays down with nothing in the session to re-arm it ([configuration](configuration.md#watcher-backstop-timer)) |
| `fm-fleet-alarm.py`      | Opt-in custom check and independent timer that alarm on Claude weekly quota pressure and silent second mates holding work ([configuration](configuration.md#fleet-quota-and-secondmate-alarm-configfleet-alarmjson)) |
| `fm-startup-growth-check.sh` | Daily metadata-only growth check for startup memory and tracked startup/instruction surfaces |
| `fm-usage-warner.sh`     | Opt-in macOS threshold warner that notifies once when a configured Claude usage window crosses its percentage |
| `fm-pr-lib.sh`           | Own canonical task and PR validation, the branch-to-PR lookup shared by teardown and the PR health monitor, plus private atomic PR-poll publication, merge-notification identity, and retirement |
| `fm-pr-poll.sh`          | Provide the byte-static watcher program for validated pull-request, merge-request, and Gerrit-change poll sidecars |
| `fm-contributions.sh`    | Observe owned publications, retain exact-head judgments, measure required actors, and wake on maintainer or configured review-bot signals |
| `fm-pr-health.sh`        | Opt-in: enroll owned PRs; wake once per latest commit for conflicts, failing checks, and author actions; record maintainer-gated CI and missing required reviews without waking the task, using GitHub notifications plus a fallback sweep (see [configuration.md](configuration.md#pr-health-monitor-configpr-health-monitor)) |
| `fm-pr-check.sh`         | Record validated task `pr=` and `pr_head=` values and the PR's first-recorded `pr_at=` ready time and the project's `ready_evidence=` verdict, then atomically arm a static merge poll and hand a ship PR to its project's `merger=` home when that is another home; refuses GitHub drafts, failed ready evidence, and persistent secondmate records (see [architecture.md](architecture.md)); `scan`, run by the watcher's check sweep when `config/pr-register-scan` is present, records each PR a task's `done:` line reports when no `pr=` exists; `release`, run by every watcher check sweep, releases the no-mistakes run of a green no-mistakes ship whose PR was handed to another home's merger, so the run stops holding a pipeline slot |
| `fm-pr-adopt.sh`         | Write the minimal task record for an open GitHub PR that has no record in this home, then register it through `fm-pr-check.sh` so `fm-pr-merge.sh` can run on it under every unchanged guard ([configuration](configuration.md#task-metadata)) |
| `fm-review-check.sh`    | Record a forge=external task's validated `review=` and `review_head=` and the project's `ready_evidence=` verdict without arming a merge watch ([design](external-review-forge.md)) |
| `fm-external-review-lib.sh` | Shared readers for the forge=external review tool adapter, ready-URL pattern, backup remote, and remote URLs |
| `fm-pr-merge.sh`         | Record PR metadata, merge a task's canonical full GitHub, GitLab, or Forgejo URL or, with `--stack`, a gated GitHub stacked pull request set, refuse a Gerrit change because firstmate never submits one, then refuse an outcome it cannot prove landed or queued |
| `fm-pr-state.sh`         | Read-only: print one line per GitHub pull-request blocker it can see, reporting on checks that have reported rather than verdicting merge-readiness |
| `fm-pr-reviewers.sh`     | Read-only: suggest reviewers from GitHub's own author mapping of recent commits on a pull request's changed files, never requesting one |
| `fm-merge-outcome-lib.sh` | Publish a confirmed merge's durable, role-routed supervision outcome                 |
| `fm-merge-authority-lib.sh` | Resolve merge authority at the gate, persist it against the accepted canonical PR, and identity-check its later poll consumption |
| `fm-admission-lib.sh`    | Load a project's admission config and run its own diff classifier for the merge-time check that flagged classes carry the captain's recorded answer, or are handed to the merger home a route names |
| `fm-reserved-classify.sh` | Generic path-rule admission classifier: map changed paths to class words from a home-local `<glob> <class>` rules file ([configuration](configuration.md#path-rule-classifier-binfm-reserved-classifysh)) |
| `fm-parent-channel-lib.sh` | Resolve a secondmate home's parent channel and append a captain-facing outcome line to it at most once |
| `fm-promote.sh`          | Promote a scout task in place to a protected ship task with an explicit delivery mode, write the ship instructions carrying that mode's definition of done, and supersede the task's brief so a later relaunch cannot revive stale scout delivery text |
| `fm-teardown.sh`         | Fail-closed teardown: return landed ship worktrees, require completed scout deliverables, retire secondmate homes |
| `fm-harness.sh`          | Detect the running harness, resolve crew or secondmate harness, model, and effort, and validate the native-only `ultra` effort |
| `fm-lock.sh`             | Per-home firstmate session lock                                                      |
| `fm-x-lib.sh`            | Shared Relay config, relay, and reply-threading helpers                              |
| `fm-x-poll.sh`           | One bounded Relay poll: stash newly offered mentions, emit their once-only wake, and raise queued public-followup rejection wakes at least once |
| `fm-x-reply.sh`          | Post or dry-run preview a composed Relay reply or follow-up                          |
| `fm-x-dismiss.sh`        | Dismiss a skipped Relay mention at the relay without replying                        |
| `fm-x-link.sh`           | Link a spawned task to its originating Relay mention in task meta                    |
| `fm-x-followup.sh`       | Detect, post, and cap completion follow-ups for a Relay-linked task                  |
| `fm-public-followup-lib.sh` | Shared Relay gate, mirrored deliverable validation, open-loop state, locking, and private transport paths |
| `fm-public-followup.sh`  | Brief, reconcile, and deliver typed public commitments, surface refusals, then rechain or retire retained loops |
| `fm-public-followup-emit.sh` | Validate and report one typed terminal work result into its owning home, or stage it when that home is remote |
| `fm-public-followup-collect.sh` | Read and retire the typed terminal results a remote work home staged for the home that owes the public reply |
| `fm-inbox.sh`            | The captain's out-of-band capture surface: queue a note (optionally idempotent by request id), announce or repair its wake, record a durable primary reply, and emit bounded receipts and primary-readiness JSON |
| `fm-mail.sh`             | General-purpose mail plane: read unseen IMAP mail, send one SMTP message, or surface new mail as a `check` wake via `poll` (configuration in the home's gitignored `.env`) |
| `fm-mail.py`             | The IMAP/SMTP engine behind `fm-mail.sh` |
| `fm-mail-check.sh`       | Standing received-mail poll: `arm` registers a watcher check that runs `fm-mail.sh poll` on the watcher cadence (new mail still wakes via the poll; the check's own line also wakes unless the poll is a proven no-op), `disarm` removes it |
| `fm-officer.sh`          | The officer agent kind: register, retire, run, and health-check the role agents in `data/officers.md`; its watcher check starts each daily run and reports one line per actionable digest to main unless its `consumer:` field hands the digest to an office |
| `fm-office.sh`           | The office registry, wake sources and status: list the offices in `data/offices.md`, at session start report one `OFFICE:` line per gap, (`publish`) push one office's authority record into its home, (in an office home) register and run the office's `tick` and `lane:` watcher checks, (`status`) write the home's `data/office-status.json`, and (`arm-status`, `disarm-status`) register or retire that as the home's silent watcher check |
| `fm-office-status.py`    | Projects an office home's backlog and task records onto `data/office-status.json` (working, next, done cards, and the office decisions list); [Office status](configuration.md#office-status-dataoffice-statusjson) owns the schema |
| `fm-office-authority-lib.sh` | Whether this home is an office and what its published authority record allows, and the per-destination record the main home publishes; `fm-spawn.sh`, `fm-pr-merge.sh` and `fm-merge-local.sh` source it to refuse what the record does not cover |
| `fm-registry-line-lib.sh` | Single owner of the registry line grammar `fm-officer.sh` and `fm-office.sh` source: the line regex, field reader, and cadence and slot helpers |
| `fm-officer-triage.py`   | The triage officer's deterministic daily pass: joins archived sessions to firstmate tasks and outcomes and writes its findings |
| `fm-officer-surgeon.py`  | The Ship's Surgeon's daily pass: the triage session join, then rule-table intake from the fleet app's nightly runs and bug-sweeper results, filing untracked real findings in Linear only when its registry line says `writes: linear`; [Surgeon](configuration.md#surgeon) owns the contract |
| `fm-officer-linear.py`   | The shared library every officer files Linear items, loads its rubric and emits start requests through: fingerprint dedupe with local-jev, the in-place `Found:` line, `--dry-run` then `--verify`, the create cap and call budget, the reserved classes and the found-count score; [Officer contract](officers/contract.md) owns the contract |
| `fm-officer-friction.py` | The friction officer's deterministic daily pass: finds waits on Lee and other agent friction in status logs and the session archive, groups them by root cause with a proposed fix and owner, and writes its findings and a fleet-app velocity findings file |
| `fm-officer-landing.py`  | The landing officer's daily pass: judges the fleet-app landing-truth facts against Linear (false done, false not-done) and, when its registry line allows it and the facts are fresh, closes fully landed items and reopens Done items whose PR never reached main or any release |
| `fm-officer-progress.py` | Finds authorized unstarted work, ranks executable requests for firstmate, and writes the fleet-app progress state; [Progress officer](configuration.md#progress-officer) owns classification and execution |
| `fm-officer-page-check.py` | The page-check officer's timed pass: reads every fleet-app page and flags cards a standing rule settles, stale cards, cards shown after they were settled, and pages older than their normal gap |
| `fm-officer-corpus.py`   | The corpus officer's daily pass: reads counts, timestamps and names only from the training-corpus inputs and reports missed collections, archive gaps, harvest failures or drift, a stale prep store and a missed weekly retrain, filing them in Linear only when its registry line says `writes: linear`; [Corpus officer](configuration.md#corpus-officer) owns the contract |
| `fm-officer-library.py`  | The library officer's daily pass: sorts the newest weekly librarian-audit findings into needs Lee, safe to ship, code work and on hold, filing them in Linear only when its registry line says `writes: linear`; [Library officer](configuration.md#library-officer) owns the contract |
| `fm-voice-relay.py`      | Hold the spoken conversation on this host, answer from the records, and hand real work to `fm-inbox.sh` ([voice-relay.md](voice-relay.md)) |
| `fm-voice-client.py`     | The laptop end of the spoken interface: capture, playback, and turn timing over SSH; audio devices unverified |
| `fm_voice_frame.py`      | The wire format both machines share, copied to the laptop beside the client          |
| `fm_voice_records.py`    | What a spoken answer may read, and the handover that queues real work                |
