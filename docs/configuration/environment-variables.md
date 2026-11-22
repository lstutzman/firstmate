# Environment variables reference

Part of the [configuration reference](../configuration.md).

## Environment variables

Runtime tuning via environment variables (defaults shown):

Pi worker model-stream observation is optional.
Set `FM_STREAM_SILENT_MAX_SECS=300` before launching workers and their watcher to inspect a foreground request that stops producing substantive content for five minutes.
It must be present in the environment that launches both the worker and its watcher: a value only the watcher sees, such as one added only to `config/watch.env`, instruments no worker, so a worker spawned without it records no stream evidence and keeps the general busy bound.
The interval includes foreground request preparation; the existing wedge delay and declared-wait deferrals still apply before an inspection notification, and no worker is interrupted or restarted.
Background provider/cache warming is excluded, and observation closes at assistant message completion, tool execution start, or settled idle state.
Changed nonempty text, thinking, or tool-call content refreshes stream evidence at most once per second and supplies a separate progress anchor for the general busy bound; empty or unchanged snapshots do not.
New instrumentation is version-gated to Pi 1.2.0 and takes effect on launch or relaunch; stream observation stays off on every unverified version until verified, with a warning and the general busy bound retained.
Observation writes have a five-second subprocess deadline and one-second termination grace; a failed write reports an instrumentation warning while Pi continues.
Unset, empty, zero, negative, malformed, and values longer than nine decimal digits disable the option, including its separate normal-model progress anchor.
`bin/fm-busy-lib.sh` owns stream evidence and ordering; the [real-Pi verification guard](../verification/runtime-backends.md#pi-worker-model-stream-observation) refreshes the vendor evidence.

```sh
FM_HOME=                 # optional operational home for most scripts, unset means this repo root; fm-send requires it explicitly
FM_ROOT_OVERRIDE=        # override firstmate repo root, tangle-guard target, and zellij/cmux/tern home-title hash; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_PROC_ROOT_OVERRIDE=   # alternate /proc root for Linux process-identity readers, mainly for tests
FM_BACKEND=             # optional runtime backend override for new spawns; tmux/herdr/zellij/orca/cmux/paseo/rex/t3code/tern support ship/scout spawns, codex-app is not accepted
FM_T3CODE_ORIGIN=       # optional T3 Code server origin for bin/fm-t3-mcp.mjs login; the default is read from ~/.t3/userdata/server-runtime.json
FM_TRACE_CONTEXT=       # optional trace-context override; see "Trace context propagation"
FM_TASK_ID=             # internal task-worker marker fm-spawn.sh delivers to ship and scout environments, never set by hand; bin/fm-test-run.sh refuses to execute in the repository primary checkout while it is set
FM_TASK_INBOX=          # internal: absolute path of the task's steering inbox (state/<id>.inbox) that fm-spawn.sh exports into every ship, scout, and secondmate launch, never set by hand; the steering doorbell names "$FM_TASK_INBOX"
HERDR_SESSION=default  # herdr-only: named session for normal backend ops; not enough for destructive cleanup (docs/herdr-backend.md)
FM_BACKEND_HERDR_SUBMIT_POLLS=6  # herdr-only: agent-state samples spread across each Enter attempt's budget when confirming a submit (docs/herdr-backend.md "Current transport behavior")
FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6  # herdr-only: minimum per-Enter confirmation budget before polling agent-state after an idle baseline
FM_ZELLIJ_SESSION=firstmate  # zellij-only: named session for normal backend ops and test isolation (docs/zellij-backend.md)
FM_TERN_SESSION=        # tern-only: optional session NAME override for tests/smoke; default fm-<hometag> (docs/tern-backend.md)
FM_BACKEND_TERN_CTL_TIMEOUT=5  # tern-only: seconds bounding each tern ctl call for native agent state (docs/tern-backend.md)
FM_BACKEND_TERN_SUBMIT_POLLS=6  # tern-only: native-state samples across each Enter confirmation budget
FM_BACKEND_TERN_SUBMIT_MIN_SLEEP=0.6  # tern-only: minimum per-Enter confirmation budget before polling native state after an idle baseline
CMUX_SOCKET_PASSWORD=   # cmux-only: socket password fallback when config/cmux-socket-password is absent (docs/cmux-backend.md)
FM_SESSION_START_STATUS_TAIL=5   # state/*.status lines printed per task in the session-start digest; each line is capped by bin/fm-line-cap-lib.sh
FM_SESSION_START_QUEUED_LIMIT=20   # plain queued backlog rows in the session-start digest; in-flight, held, and blocked rows are never bounded and done rows are never listed; a separate `queue:` line states the whole queue's total, unheld count and oldest unheld age regardless of this limit
FM_SESSION_START_ENDPOINT_TIMEOUT=10   # seconds bounding each per-task endpoint liveness read in the session-start digest (bin/fm-session-start.sh); nonpositive or invalid values fall back to 10; a read that hits the bound or dies becomes that task's own `endpoint: error` line and the digest continues
FM_BACKLOG_ROW_TIMEOUT_SECS=10   # seconds bounding each backlog row read (bin/fm-backlog-transition-lib.sh) and the tasks-axi replay of each captain-hold Done-archive row (bin/fm-captain-hold.sh, which stops with 124 on a replay timeout); the archive scan itself is not bounded; nonpositive or invalid values fall back to 10; the first backlog read bound hit latches the sweep so later reads return immediately, each still naming its own item
FM_BOOTSTRAP_DETECT_ONLY=0   # internal/read-only session-start mode: skip bootstrap's mutating sweeps and print advisory TANGLE wording
FM_BOOTSTRAP_NETWORK=all   # internal session-start phase split: all, skip (local steps only), or only (network steps only); see bin/fm-bootstrap.sh
FM_STARTUP_NETWORK_TIMEOUT=120   # seconds bounding the deferred inactive-outcome scan plus network checks, including the lock waits the worker makes before them; hitting it prints an actionable NETWORK_CHECKS line, and a lock a live process still holds at the deadline ends the worker with a failed-rerun record (publication and delivery are bounded by FM_SESSION_START_TIMEOUT the same way)
FM_SECONDMATE_CONVERGENCE_TIMEOUT=75   # shared per-mate deadline in seconds for remote startup tracked-file sync and inheritance push; bin/fm-bootstrap.sh owns its scope and timeout handling
FM_REMOTE_INHERIT_PUSH_JOBS=4   # inherited items one remote inheritance push sends at a time, 1 for strictly one after another; capped at 16 (bin/fm-remote-inherit-push.sh)
FM_TASKS_AXI_COMPATIBLE=   # internal one-hop handoff of an already-computed tasks-axi compatibility verdict (0 or 1); consumed when bin/fm-tasks-axi-lib.sh is sourced
FM_TASKS_AXI_CHECK_REASON=   # internal one-hop handoff of the reason behind that verdict (compatible, version, or the capability probes the build fails); consumed when bin/fm-tasks-axi-lib.sh is sourced, and it keeps the OUTDATED requirement text from repeating the probes
FM_GUARD_READ_ONLY=0    # internal/read-only guard mode: keep alarms but suppress drain, supervision repair, and checkout repair commands
FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # banner continuation line; fm-send.sh overrides it to name the requested message specifically
FM_POLL=15              # seconds between watcher poll cycles
FM_HOME_SUMMARY_INTERVAL=300   # seconds before a live watcher refreshes this home's state/home-summary.json even without a status signal; invalid or zero values use 300
FM_HOME_SUMMARY_TIMEOUT=60     # seconds bounding the complete best-effort home-summary refresh, including lock acquisition, validation, atomic publication, and worker-side failure logging; invalid or zero values use 60
FM_HOME_SUMMARY_ERROR_LOG_MAX_BYTES=65536   # approximate size cap for state/.home-summary-refresh.log before it is trimmed to the newest 200 lines; invalid or zero values use 65536
FM_HOME_SUMMARY_FAILURE_REPORT=2   # recorded publication failures since the ledger's own last publication before session start reports a HOME_SUMMARY line; invalid or zero values use 2
FM_SNAPSHOT_CREW_STATE_TIMEOUT=10   # seconds bounding local per-task current-state and endpoint reads inside bin/fm-fleet-snapshot.sh; remote endpoint liveness is not probed on the snapshot path
FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=8   # maximum local tasks whose current-state and endpoint observations, status-history fold, and row composition run concurrently during snapshot composition
FM_SNAPSHOT_BUDGET=5                # one total seconds budget for all concurrent remote home-ledger reads
FM_SNAPSHOT_CACHE_DIR=$FM_HOME/state/secondmate-summary-cache   # private parent-side cache of successfully fetched remote home ledgers
FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=14  # floored elapsed-day threshold at which an undated captain hold (no hold-until; age from its UTC hold-set timestamp, falling back to since for legacy unstamped holds) is projected as a Charted Next gate instead of a live Captain's Call; 0 applies once the computed age is non-negative
FM_RECONCILE_REQUEST_MAX_BYTES=1048576   # maximum captured Bearings or fleet snapshot accepted for durable reconcile-notify request publication
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_INACTIVE_RECONCILE_SECS=900  # 60..1800-second watcher cadence and inactivity threshold; locked session start also requests an immediate scan in the deferred worker
FM_INACTIVE_RECONCILE_BUDGET_SECS=10  # 1..30-second scan deadline; wedged-scan kill backstop follows one second later
FM_CHECK_INTERVAL=300   # seconds between slow checks (authenticated merge polls, custom checks, or Relay dispatch)
FM_TASK_INBOX_GRACE_SECS=90   # seconds an unhandled steering-inbox message may sit before the watcher attempts doorbell delivery on an idle endpoint; also the minimum spacing between attempts
FM_TASK_INBOX_RING_MAX=3      # watcher delivery attempts without an acknowledgement before the task surfaces as a stale wake for recovery
FM_TASK_INBOX_BUSY_MAX=2      # consecutive busy-deferred due polls before a stuck-busy stale wake; 1..999999999, at most 9 decimal digits, otherwise 2; policy: bin/fm-task-inbox-lib.sh
FM_TASK_INBOX_RING_LOCK_WAIT_SECS=8   # seconds a doorbell ring waits for a concurrent ring into the same pane before deferring to the watcher's re-ring; policy: bin/fm-task-inbox-lib.sh
FM_TASK_INBOX_RING_LOCK_DIR=/tmp/fm-ring-locks-<uid>   # host-wide directory of per-pane ring locks, shared by every home on the machine; policy: bin/fm-task-inbox-lib.sh
FM_TASK_INBOX_DEDUP_WINDOW=200   # newest sequence numbers an idempotent (remote) steering write compares for a matching body; older records are not matched; policy: bin/fm-task-inbox-lib.sh
FM_TASK_INBOX_HANDLED_KEEP=500   # acknowledged records kept in <task>.inbox/handled/; older ones move to <task>.inbox/archive/, never deleted; policy: bin/fm-task-inbox-lib.sh
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script; a cut check wakes with its output so far plus `timed out after <seconds>s`
FM_WATCH_REMOTE_BUDGET=30   # seconds allowed per remote poll the watcher cycle waits on (secondmate liveness probe, pending-reply observation); a poll past it reads as an unreachable host, never a dead one
FM_MAIL_CHECK_BUDGET=15   # seconds allowed for one standing mail poll; valid 5..25, cut to fit FM_CHECK_TIMEOUT
FM_MAIL_POLL_MAX_WAKES=20   # per-poll wake cap for a mail poll; valid 1..200, keeps a flood from flooding firstmate
FM_MAIL_TIMEOUT=20   # mail-plane IMAP/SMTP socket timeout in seconds; invalid or non-positive values become 20
FM_TOOL_UPDATE_INTERVAL=900   # seconds between watched-tool probe sweeps; 0 probes on every run, other values must be 60..86400
FM_TOOL_UPDATE_PROBE_SECS=5   # 1..30 seconds allowed for one version or git probe
FM_TOOL_UPDATE_BUDGET_SECS=20   # 1..120 seconds allowed for a whole watched-tool sweep; cut to fit FM_CHECK_TIMEOUT, and the cut is reported
FM_TOOL_UPDATE_NOW=     # test override for the watched-tool sweep clock; the sweep budget still uses real time
FM_PROCEVENT_MAX_OUTPUT_BYTES=1048576   # bound on one captured process-to-event result
FM_PROCEVENT_CLAIM_ROOT=                # machine-wide source claim root; default $XDG_STATE_HOME/firstmate/procevent-claims
FM_PROCEVENT_OWNER_LEASE_SECONDS=600    # how long a source runner keeps going with no activity in its owning home; 1..86400
FM_PROCEVENT_OWNER_CHECK_SECONDS=15     # a runner guard's detection interval, read twice per interval; 1..3600
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1     # minimum interval between launches of one registration generation's source command; 1..3600
FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=3   # how long reconcile waits for the runners it started to prove they are running; 1..600, keep well below FM_POLL
FM_WHEN_OUTPUT_TAIL_BYTES=8192          # bound on the command-output tail inside one condition->action outcome document
FM_CODEX_WATCH_CHECKPOINT=180   # seconds per foreground watcher checkpoint in Codex primary supervision
FM_CODEX_WATCH_CHECKPOINT_AWAY=3600  # requested away checkpoint bound on a home that runs the supervision host; longer of this and attended bound, capped at 27000
FM_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside fm-crew-state.sh, and per state-database run-inventory read behind a capped AXI overview
FM_TEARDOWN_NM_TIMEOUT=10    # seconds allowed per no-mistakes query or abort inside fm-teardown.sh
FM_LIMIT_RESUME_CHECK_SECS=60   # minimum seconds between watcher requests to bin/fm-limit-resume.sh for one crew parked on Claude Code's usage-limit prompt
FM_CLAUDE_LIMIT_RESET_MARGIN=60   # seconds past the reset time the usage-limit prompt states before bin/fm-limit-resume.sh sends anything
FM_LIMIT_RESUME_COOLDOWN=1800     # seconds within which bin/fm-limit-resume.sh will not recover the same stated reset twice
FM_LIMIT_RESUME_SETTLE=1          # seconds bin/fm-limit-resume.sh waits after the interrupt before re-reading the pane
FM_CREW_STATE_RUNS_LIMIT=200  # plain runs-ledger rows scanned for fallback attribution; does not change the CLI's AXI overview window (selection owner: bin/fm-nm-run-lib.sh)
FM_TEARDOWN_NM_RUNS_LIMIT=200  # recent no-mistakes run rows scanned to prove an unresolved-head parked run belongs to teardown's task
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by watcher triage: the working/paused classification, the wedge timer's parked-gate wait evidence, and its opt-in validating-run deferral
FM_MAIL_USER=      # mail-plane IMAP/SMTP login, from .env or environment (docs/configuration/relay-and-intake.md "Mail plane")
FM_MAIL_PASS=      # mail-plane IMAP/SMTP password
FM_IMAP_HOST=      # mail-plane IMAP server hostname
FM_IMAP_PORT=993   # mail-plane IMAP server port
FM_SMTP_HOST=      # mail-plane SMTP server hostname
FM_SMTP_PORT=465   # mail-plane SMTP server port
FMX_PAIRING_TOKEN=      # Relay pairing token; .env opt-in authorizes replies and eligible lifecycle actions
FMX_RELAY_URL=https://myfirstmate.io   # optional Relay endpoint override, mainly for local relay development
FMX_ENV_FILE=           # optional alternate .env file for direct Relay client invocations; bootstrap still checks $FM_HOME/.env
FMX_DRY_RUN=            # truthy previews Relay replies and dismissals to state/x-outbox/ without posting or requiring a token
FMX_X_REPLY_MAX_CHARS=280   # X reply per-message split budget; values below 50 clamp to 50
FM_DISPATCH_PROVIDER=   # typesafe, openrouter, systemone, or openai; absent preserves the original typesafe key gate ("Typed dispatch resolution")
FM_DISPATCH_MODEL=      # explicit model for the selected provider; required for openrouter, systemone, and openai
FM_DISPATCH_BASE_URL=   # http(s) base of a System One-compatible host; required for systemone
FM_DISPATCH_API_KEY=    # optional systemone key; absent sends no Authorization header
TYPESAFE_API_KEY=       # typesafe dispatch key, from the environment, .env, or the declared credential source ("Typed dispatch resolution"); absent, with no custom base URL or token file and no declared source, means bin/fm-dispatch-resolve.sh is off for the typesafe provider
TYPESAFE_BASE_URL=      # optional System One base URL override for the typesafe provider, wins over config/typesafe-base-url; a non-default URL also turns the resolver on (docs/configuration/dispatch.md "Typed dispatch resolution")
FM_CPA_USAGE_TIMEOUT=10 # overall seconds bound on the resolver's pooled Claude quota read when config/cpa-usage-host exists (docs/configuration/dispatch.md "Typed dispatch resolution")
OPENROUTER_API_KEY=     # OpenRouter dispatch key, from the environment, .env, or the declared credential source
OPENAI_API_KEY=         # OpenAI dispatch key, from the environment or .env
FMX_DISCORD_REPLY_MAX_CHARS=1900   # Discord reply per-message split budget; values below 50 clamp to 50, values above 2000 reset to 1900
FMX_X_THREAD_MAX=25     # maximum messages in one auto-split reply thread
FMX_FOLLOWUP_MAX_AGE_SECS=604800   # local window for posting Relay completion follow-ups (7 days)
FMX_FOLLOWUP_MAX_COUNT=3   # local cap on Relay completion follow-ups per linked mention
FM_PF_RETRY_BACKOFF_SECS=900   # seconds before the next attempt after a retryable promised-public-reply delivery error
FM_LOCK_STALE_AFTER=2   # grace seconds for missing or nonnumeric lock-owner PIDs (minimum 2s); dead numeric PIDs, and live ones whose start time (or, for the watch lock, process identity) no longer matches the holder's recorded value, have no age grace
FM_GUARD_GRACE=300      # beacon freshness threshold for guard verdicts, arm health checks, and the primary turn-end guard; see docs/turnend-guard.md for model-aware exceptions
FM_CLAUDE_AUTOARM_ATTEMPTS=2   # bounded hook-owned arm attempts per Claude auto-arm cycle; accepted values are 1, 2, or 3
FM_CLAUDE_AUTOARM_PARK_SECONDS=27000   # seconds a host-off Claude Stop auto-arm parks (first arm and quiet-ack re-arms together) before ending with a clean park-renewal exit 2; default is the Stop hook timeout in .claude/settings.json minus 1800; see docs/turnend-guard.md
FM_WATCH_BACKSTOP_ALERT_AFTER=2   # undeliverable backstop polls in one stale episode before it raises one wedge-alarm alert (docs/wedge-alarm.md); 0 disables
FM_WATCH_BACKSTOP_STALE_SECS=900   # watcher beacon age at which the out-of-session backstop (bin/fm-watch-backstop.sh) treats a home that needs supervision as down and rings its session
FM_CLAUDE_STOPFAILURE_REWAKE_COOLDOWN=300   # minimum seconds between StopFailure-driven exit-2 continuations; nonnegative integers accepted, invalid or empty values use 300; pacing mechanics: bin/fm-claude-stop-autoarm.sh header
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=800   # milliseconds the --claude turn-end guard waits for watcher health, an open Stop auto-arm generation claim, or a fresh epoch before deciding recovery ownership or failure progression
FM_CLAUDE_AUTOARM_EPOCH_FRESH=15   # seconds a recorded auto-arm outcome remains eligible for the current event epoch's recovery or failure decision
FM_CLAUDE_TURNEND_BLOCK_BUDGET=3   # consecutive --claude guard re-blocks before the verified one-time attended fail-open; safely below Claude Code's 8-block override
FM_ARM_CONFIRM_TIMEOUT=300   # fresh-child confirmation backstop in seconds; default max(FM_GUARD_GRACE, 10), or max(FM_GUARD_GRACE, 30) on Git Bash/MSYS; positive overrides may be shorter; expiry still waits for safe interruption (docs/watcher-continuity.md "Startup interruption window")
FM_ARM_SUCCESSOR_CONFIRM_TIMEOUT=10   # successor confirmation seconds; fm-watch-arm defaults to 10, or 30 on Git Bash/MSYS; Claude Stop auto-arm's outer successor-status wait defaults to 30 on all platforms, plus slack
FM_WATCHER_STARTUP_LOCK_BOUND=60   # per-lock startup wait in seconds for downtime publication during singleton steal and startup recovery transitions; later poll-time recovery checks remain blocking; independent of the arm backstop
FM_ARM_ATTACH_POLL=0.5  # seconds between checks while fm-watch-arm follows an attached watcher cycle (bin/fm-watch-arm.sh header)
FM_OPENCODE_ARM_READY_TIMEOUT_MS=12000   # milliseconds the OpenCode primary watcher plugin waits for an arm attempt to report started, healthy, wake, or failure; default 35000 on Windows; independent of the fresh-child arm backstop
FM_PI_ARM_READY_TIMEOUT_MS=12000   # milliseconds the Pi watcher extension waits for a successor arm to report started or attached; default 35000 on Windows; independent of the fresh-child arm backstop
FM_WATCH_ARM_RETIRE_TIMEOUT_MS=1000   # milliseconds Pi/OpenCode wait for an unready successor arm to exit before abandoning retries
FM_WATCH_REARM_RETRY_BASE_MS=250   # Pi/OpenCode adapter base delay for continuity restoration retries
FM_WATCH_REARM_RETRY_MAX_MS=4000   # Pi/OpenCode adapter cap for exponential continuity retry delay
FM_WATCH_REARM_RETRY_LIMIT=5   # Pi/OpenCode adapter launch-failure retries before surfacing restoration failure
FM_WATCH_CYCLE_LOG_MAX_BYTES=262144   # size cap for the arm-owned watcher lifecycle ledger
FM_WATCH_CYCLE_LOG_KEEP_LINES=1000   # newest complete lifecycle rows considered when the ledger is capped
FM_WATCH_EXTENSION_LOG_KEEP_LINES=0   # opt-in Pi extension diagnostic log (state/.watch-extension.log); unset, empty, non-numeric, zero, or negative disables logging, a positive value keeps that many newest rows; logging never changes supervision behavior
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE if set, else the poll-derived grace (docs/turnend-guard.md "Guard grace and the poll cadence"); seconds before a fresh arm refuses a live holder's stale beacon (attached arms: FM_WATCHER_STALL_BOUND)
FM_WATCHER_STALL_BOUND=       # live-holder stall bound; default and arm/re-arm behavior: docs/turnend-guard.md "Guard grace and the poll cadence"
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_WATCHER_CLEANUP_LOCK_BOUND=   # optional watcher EXIT marker-lock wait; default and validation: docs/watcher-continuity.md
FM_TURNEND_CHURN_ABSORB_SECS=900   # longest one endpoint's bare turn-ends may be deferred on pane-churn evidence alone; only consulted when config/turnend-churn-absorb is present
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # captain-relevant status regex; nonterminal progress verbs remain excluded even when their prose matches
FM_CLASSIFY_PAUSED_VERB=paused     # leading declared-wait status verb; bin/fm-classify-lib.sh owns its meaning and legacy external-wait label; excluded from FM_CAPTAIN_RE and distinct from blocked
FM_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working stale pane escalates, unless that pane's own worker declared a wait that has not elapsed, its task is held for the captain in the backlog, or, where config/wedge-defer-worker-wait arms it, its worker's own newest line is a still-open `blocked:` or `needs-decision:` line, or, where config/wedge-defer-parked-gate arms it, that pane's crew is parked at a validation gate awaiting the supervisor's decision on it that the crew raised under that run's key and nobody has answered yet, or, where config/wedge-defer-validating arms it, that pane's crew has an attributed no-mistakes run whose step is running or fixing, any of which takes the FM_PAUSE_RESURFACE_SECS recheck below instead; stale panes whose crew is not provably working surface immediately unless admitted directly to the declared-wait cadence, while a live idle declared wait still surfaces once before that cadence bounds repeats; at that same escalation moment a recovery-grade agent-state probe (docs/architecture.md owns that dead-record contract) reports a pane whose endpoint is proven `dead` or `missing` once and stops re-escalating it while it stays that way
FM_BUSY_TURN_MAX_SECS=3600         # maximum age without a completed turn, explicit native-harness progress, or opted-in model progress (see the stream option above; bin/fm-watch.sh owns marker selection), before the same wedge escalation used for a provably-working non-busy stale takes over; inspection-only, never an automatic interrupt or restart; a declared external wait, an attended verified captain-held transfer, an attended backlog captain hold on the crew's task, or - where config/wedge-defer-worker-wait or config/wedge-defer-parked-gate arms it - the worker's own still-open newest `blocked:` or `needs-decision:` line or a validation gate of the crew's own awaiting the supervisor's still-unanswered decision, or - where config/wedge-defer-validating arms it - an attributed validation run that is running or fixing, takes the FM_PAUSE_RESURFACE_SECS recheck below instead
FM_STREAM_SILENT_MAX_SECS=         # opt-in Pi worker foreground model-stream silence threshold; off by default; see the option above and bin/fm-busy-lib.sh
FM_NM_START_SETTLE_SECS=120          # seconds the branch head must stay unmoved (the later of the worker's done: stamp and the head commit's committer time) before the automatic no-mistakes start steer is sent or a pre-review run is cancelled for a moved head; 0 turns the wait off; bin/fm-nm-drive-steer.sh owns the rule
FM_PAUSE_RESURFACE_SECS=14400      # four hours between bounded rechecks of a declared external wait or verified captain-held transfer, repeated new-hash stale alarms for an ordinary crew task with an open backlog captain call, and repeated first-sight alarms from an otherwise-unclassifiable pane whose recovery-grade endpoint probe proves its agent alive and whose own status log or task worktree was written within FM_STALE_ESCALATE_SECS (without that progress evidence every new hash still surfaces immediately); a structured until time can make an external-wait recheck occur sooner but cannot extend this bound; this includes a live idle pane after its first inconclusive stale wake, a provably-working pane whose own unelapsed declared wait, backlog captain hold, or, where config/wedge-defer-worker-wait or config/wedge-defer-parked-gate arms it, its worker's own still-open `blocked:` or `needs-decision:` line or unanswered supervisor-owed validation gate, or, where config/wedge-defer-validating arms it, attributed validation run that is running or fixing, defers its FM_STALE_ESCALATE_SECS escalation, and a live busy pane past FM_BUSY_TURN_MAX_SECS, while the away-mode daemon uses the same setting, except for a captain-held transfer (FM_CAPTAIN_HELD_RESURFACE_SECS below), and ages its window against the crew's own latest status line rather than pane busy state; set it in config/watch.env for durable non-Relay tuning of watchers started through bin/fm-watch-arm.sh, while the Codex checkpoint route with no config/supervision-host and the away-mode daemon start the watcher directly and use the default; a captain-held transfer or backlog captain hold is never rechecked while the away-posture record exists, while an armed validation gate awaiting the supervisor's decision keeps this recheck in either posture
FM_PAUSE_UNDATED_MAX_SECS=86400   # seconds before an undated worker pause becomes overdue where config/pause-ceiling arms the pause ceiling; zero or invalid values use 86400; see "Pause ceiling (config/pause-ceiling)" above
FM_CAPTAIN_HELD_RESURFACE_SECS=86400  # one day between away-mode daemon rechecks of a verified captain-held transfer, a wait the captain owes, in place of the FM_PAUSE_RESURFACE_SECS bound; a declared until time moves the recheck to that time, earlier or later than this bound, a captain-held transfer whose every tracked captain task is answered or released rechecks it at once, and an away-posture record still silences it; an open keyed needs-decision that is its crew's latest status event is owed by the supervisor and keeps the FM_PAUSE_RESURFACE_SECS recheck in either posture, and the attended watcher never wedge-escalates it, with no config/wedge-defer-parked-gate opt-in (docs/architecture.md owns which of its paths take the FM_PAUSE_RESURFACE_SECS cadence)
FM_CAPTAIN_HOLD_PROBE_SECS=300     # minimum seconds between the away-mode daemon's bin/fm-captain-hold.sh open probes of one captain-held transfer's tracked tasks
FM_SECONDMATE_WAKE_STALL_SECS=180  # minimum interval with no change of the oldest actionable foreign wake-queue row (it advances as the mate drains, and a queue reprovisioned under the same task id starts a fresh interval at whatever sequence it restarts) before an endpoint-recorded local secondmate produces one durable parent wake-loop-stall notification for that no-progress episode; a mate that is provably inside an active turn (an exact busy verdict) does not escalate until that same no-progress interval reaches FM_BUSY_TURN_MAX_SECS above; a mate whose busy class is exactly idle, whose agent is alive, and whose composer is not pending is rung once so its own home can drain, and the parent notification is withheld until that same row stays frozen for another stall interval; unknown or ring-unsafe panes keep the parent alarm; declared external-wait pause rows are excluded, and zero or invalid values use 180
FM_SECONDMATE_LIVENESS_SECS=60   # seconds between watcher probes of each registered secondmate's recorded endpoint; bin/fm-secondmate-liveness-lib.sh owns recovery actions and refusal rules; zero or invalid values use 60
FM_SECONDMATE_LIVENESS_TIMEOUT=120   # seconds allowed separately for a watcher-driven relaunch's per-home lock wait and its spawn execution; a lock-wait timeout skips recovery without touching the endpoint or recording an attempt; zero or invalid values use 120
FM_SECONDMATE_LIVENESS_MAX_ATTEMPTS=3   # automatic relaunch attempts allowed per mate inside the window before the watcher parks auto-relaunch behind state/.secondmate-relaunch-bound-<id> and escalates once; a later live probe clears the marker and restores the full attempt budget (the ledger keeps its history behind a `rearmed` row); zero or invalid values use 3
FM_SECONDMATE_LIVENESS_WINDOW_SECS=3600   # window the relaunch bound counts state/.secondmate-relaunch-<id> attempt lines over; the file is also the durable per-mate relaunch record; zero or invalid values use 3600
FM_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive provably-working stale escalations on the same unchanged pane before demand-deep-inspection is added
FM_WEDGE_GUARD_TIMEOUT_SECS=5      # seconds one guard from config/wedge-evidence-guards may run before it counts as no answer; zero or invalid values use 5
FM_WEDGE_GUARD_DEFER_MAX=3         # consecutive windows a CRITICAL guard answer may defer one pane's wedge escalation before it fires anyway; invalid values use 3
FM_WEDGE_MAX_ESCALATIONS=0    # optional ceiling on consecutive wedge escalations for one worker window; 0 (the default) leaves the cap off and every escalation produces a wake, and any value from 1 up to 999999999999999999 publishes one terminal PERMANENTLY-WEDGED wake at that count - carrying the same evidence the escalation it replaces carried: the guard verdict, and the `demand-deep-inspection` marker once the count has reached `FM_WEDGE_DEMAND_INSPECT_COUNT` - and then writes the window-scoped state/.wedge-permanent-<key> to silence further wedge escalations for that window whatever hash its pane renders; the wedge path publishes no second terminal wake while the row that episode queued is still unacknowledged, which scopes the suppression to the episode rather than the window so an earlier episode's unconsumed wake cannot silence a later episode's (the away-posture first sight, which releases the markers without ending the episode, can re-open the row within one episode - an over-notify in the safe direction: the queue check bounds duplicate terminal wakes only while the episode marker stands, and the release removed exactly the marker that would have gated the re-fire, so after it a second wake can stand behind an unacknowledged first), the cap marker and the escalation count the cap was counting drop through the one episode-ending reset whose release routes are owned by the cap discussion below, and a fresh wedge escalates normally again; a cap fire also resets the consecutive-deferral budget of a config/wedge-evidence-guards guard, because the guard is not consulted at all while the cap is silencing that window, so its budget must not carry across as if it had been spent, and preserving it would leave a CRITICAL guard that reached its deferral ceiling before the cap fired already at that ceiling on the first escalation after the cap lifts, unable to defer at all; an invalid or out-of-range value uses 0
FM_CAP_HORIZON_SECS=86400    # seconds a fired cap's window-scoped marker keeps silencing the wedge path for that window, after which a new wedge escalates again; an invalid, out-of-range, or zero value uses 86400
FM_ROLLBACK_SENTINEL_TTL_SECS=3600   # seconds a cap-state write failure that could not be rolled back keeps the wedge path silenced through state/.wedge-rollback-failed-<key> - a failed cap-marker write whose own rollback also failed, an escalation count the state dir would not take, whose failed write leaves the ceiling unenforceable, or the cap-fire counter reset whose failed reset leaves the saturated counter standing - so a persistent write failure is observed once per wedge event instead of on every poll; an invalid, out-of-range, or zero value uses 3600
FM_WORKTREE_WRITE_PRUNE='.git node_modules .venv venv __pycache__ .mypy_cache .pytest_cache .ruff_cache .tox target dist build .next .cache vendor'   # directory names the wedge detector's task-worktree write probe skips; the default keeps .git out so a supervisor's own read-only git command can never look like crew progress; set it to the empty string to prune nothing, which widens the probe to the whole depth-bounded tree rather than disabling it
FM_WORKTREE_WRITE_MAXDEPTH=6       # depth that same probe walks below the recorded worktree; it runs only at the moment a wedge escalation would otherwise fire, never on every poll; no probe knob applies to a secondmate, whose recorded worktree is a provisioned home the probe skips entirely
FM_WORKTREE_WRITE_TIMEOUT=10       # wall-clock seconds that one walk may take, so a worktree on a hung mount cannot stall the watcher poll that started it; hitting the bound reads as no write evidence, which leaves the escalation schedule exactly as it was; a value that is not a positive integer falls back to the default
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=     # optional seconds allowed for bootstrap's best-effort clone refresh; unset/blank defaults to max(20, 5 + 3 * origin-backed-project-count)
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_STALE_WORKTREE_LOCK_AGE_SECS=30       # min mtime age before fm-teardown.sh treats a leftover worktree git index.lock as provably stale
FM_TREEHOUSE_RETURN_LOCK_RETRIES=3        # retries after a treehouse return fails on the transient git index.lock signature
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 # seconds fm-teardown.sh waits before each retry after that signature
FM_POOL_ORPHAN_DAYS=30 # age in days before the opt-in Treehouse pool report flags an unowned slot; invalid values use 30
FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # legacy alias for FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3        # fetch retries after fm-fleet-sync.sh hits the orphaned .git/packed-refs.lock signature
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # seconds fm-fleet-sync.sh waits before each of those retries
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # min mtime age before fm-fleet-sync.sh treats a leftover packed-refs.lock as provably stale
FM_BUSY_REGEX=          # optional override for rendered delivery guards and Grok's isolated task-state fallback; converted worker state ignores it
FM_COMPOSER_IDLE_RE=    # optional fleet-wide idle-placeholder regex override (bin/fm-composer-lib.sh); a match alone does not prove emptiness because shape-specific position and ANSI de-emphasis safety gates still apply
FM_COMPOSER_LEFTBAR_FOOTER_RE=   # optional fleet-wide override of the opencode left-bar mode/model footer's regex (bin/fm-composer-lib.sh's FM_COMPOSER_LEFTBAR_FOOTER_RE_DEFAULT, matched against both the ghost-stripped and the ANSI-stripped form of a run's LAST row); an override that cannot match the de-emphasised 1.19.0 footer puts the false `pending` back on an idle pane, so keep the default's required space after the separator and its exact `Build`/`Plan` mode words rather than widening it - widening it is the one path that turns typed text into the `empty` verdict which authorizes typing into a live session; see [runtime backend verification](../verification/runtime-backends.md#2026-10-14-opencode-1190-de-emphasised-modefooter-row-in-the-left-bar-composer)
FM_COMPOSER_CAPTURE_LINES=20   # fleet-wide bound for tail-capture composer reads; it no longer bounds the adapter composer state/content reads on tmux, herdr, or rex, which supply their visible pane instead, while the cmux, orca, Zellij, and Paseo adapters use this small window so stale scrollback banners stay out of the candidate set; it still bounds the shared inbox composer read (bin/fm-task-inbox-lib.sh) on pane backends, and on herdr it also floors how many Ctrl+U presses a refused leftover may take
FM_COMPOSER_PI_MAX_LINES=8     # fleet-wide: maximum rows admitted between Pi's identity-corroborated separator pair; taller or ambiguous candidates stay unknown
FM_COMPOSER_GHOST_LUMA_MAX=128   # fleet-wide: max perceived luminance (0.299R+0.587G+0.114B, 0-255) for a TRUECOLOR foreground to count as de-emphasised ghost/placeholder text and be stripped; dim/faint (SGR 2) is stripped regardless, and a screen whose backend identity is Command Code is read at a fixed 160 instead. Assumes a dark terminal theme (bin/fm-composer-lib.sh's fm_composer_strip_ghost, used by styled adapter reads). The default sits between the two populations it separates: harnesses draw their own de-emphasised composer furniture below it (opencode 1.19.0's mode footer at luminance 119.8 and its cwd row) and typed text above it. While it sits above the furniture the mode cells are stripped as ghost, so the footer's own identifying cells are gone from the ghost-stripped row and only the row's ANSI-stripped form still proves the footer - which is why the left-bar footer rule reads both forms and an idle opencode pane reads `empty` instead of the false `pending` that position produced - while dropping it under the furniture's luminance leaves those cells in the row and the footer then matches the left-bar footer rule in its stripped form too (still `empty`), and raising it over real typed text deletes typed text and reads as the false `empty` that authorizes typing into a live session; the measured luminances and the left-bar footer proof this threshold decides are in [runtime backend verification](../verification/runtime-backends.md#2026-10-14-opencode-1190-de-emphasised-modefooter-row-in-the-left-bar-composer), so move it only against a fresh live capture
FM_COMPOSER_GHOST_GRAY_LUMA_MAX=180   # kiro panes only (a composer read whose caller names the recorded harness kiro; every other harness and a harness-less read ignore it): the higher luminance ceiling a NEAR-ACHROMATIC foreground gets instead of FM_COMPOSER_GHOST_LUMA_MAX, because kiro draws its idle placeholder in grey at 158 while chromatic real glyphs stay out of reach. Applies to a near-achromatic truecolor run and to a 256-colour index in the standard xterm 232-255 greyscale ramp, which is how kiro draws the same grey on a pane with no truecolor; the 6x6x6 cube's r==g==b diagonal is grey arithmetically but is deliberately NOT tested, so this ceiling never reaches it. It only ever RAISES the applicable ceiling - a near-gray run takes the higher of the two, so raising FM_COMPOSER_GHOST_LUMA_MAX past this still widens the strip on gray text
FM_COMPOSER_GHOST_GRAY_SPREAD_MAX=12   # kiro panes only: max channel spread (max channel minus min channel, 0-255) for a TRUECOLOR foreground to count as near-achromatic and take the gray ceiling above; anything more saturated keeps FM_COMPOSER_GHOST_LUMA_MAX. A gray palette index has zero spread by definition, so this knob does not gate it
GROK_HOME=              # optional Grok config home for firstmate's global grok turn-end hook; defaults to ~/.grok
FM_SEND_RETRIES=3       # fm-send typed-plane Enter-retry attempts after typing the line once; agy typed targets use a longer per-harness default owned by bin/fm-send.sh
FM_SEND_SLEEP=0.4       # seconds between fm-send typed-plane submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful typed-plane submit; 0 disables
FM_PENDING_REPLY_GRACE_SECS=120   # seconds after the request turn completes without a correlated parent report before its one recovery repost is eligible, and after the recovery turn completes before the missed-report escalation is eligible; never counted from delivery
FM_PENDING_REPLY_HOLD_ESCALATE_SECS=86400   # seconds a wait-no-turns hold may keep a recovery repost back, counted from the request turn's completion, before the record takes its one held-decision escalation instead (bin/fm-pending-reply-lib.sh); an invalid or zero value falls back to the default
FM_RETENTION_INTERVAL_SECS=86400   # seconds between the watcher's archive passes over the process-event inbox and pending-reply records (bin/fm-retention.sh)
FM_RETENTION_PROCEVENT_SECS=259200   # age of a handled process-event sequence, counted from its handled marker, before its result is archived and emptied; unhandled sequences are never touched
FM_RETENTION_PENDING_REPLY_SECS=604800   # age of a resolved pending-reply record, counted from its resolved_epoch, before it is archived and removed; a record still escalated, unclosed, or named by a backlog-handoff wake is never touched
FM_RETENTION_MAX_ITEMS=5000   # most sequences, and most pending-reply records, one archive pass handles; a larger backlog drains over later passes
FM_DECISION_SWEEP_INTERVAL_SECS=600   # seconds between the watcher's detached settle-only decision sweeps, which close an open decision once the PR it hands off or names as its dependency has merged and wake firstmate naming each close (bin/fm-decision-sweep.sh); a non-numeric value uses 600 and 0 turns the sweep off
FM_EXTERNAL_WAIT_RECHECK_INTERVAL_SECS=300   # seconds between the watcher's detached external-wait re-checks, which read each declared external wait's dependency read-only, wake firstmate once when it clears or its stated recovery time passes, and name a dependency that repeated waits keep naming (bin/fm-external-wait-recheck.sh); a non-numeric value uses 300 and 0 turns it off
# sub-supervisor (bin/fm-supervise-daemon.sh); presence-gated via /afk
FM_SUPERVISOR_BACKEND=             # optional supervisor endpoint backend override; see "Away-mode supervisor backend" for supported backends and detection
FM_SUPERVISOR_TARGET=              # optional supervisor endpoint target override; tmux uses the exact forms owned by fm_backend_target_exists in bin/fm-backend.sh, herdr uses <session>:<pane-id>, t3code uses the thread id, otherwise auto-detected
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_WEDGE_ALARM_CHANNEL=            # override config/wedge-alarm with one active-alert directive for the wedge alarm; off|auto|osascript|herdr|rex|command:<cmd>; absent = auto (macOS -> an OS notification)
FM_WEDGE_ALARM_EXEC=              # notifier seam: route every channel (osascript, herdr, command:) through this command as `<cmd> <channel> <summary>`; "discard" fires nothing; unset in production; the daemon defaults it to "discard" when sourced so no test posts a real notification (docs/wedge-alarm.md)
FM_WEDGE_ALARM_TIMEOUT_SECS=10    # maximum seconds for each osascript, herdr, override, or command: notifier before its watchdog terminates it and continues to the next channel; invalid or zero values use 10
FM_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor endpoint is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale/pause-recheck, and scan passes
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
# supervision host (bin/fm-supervision-host.sh); read only in a home that runs it
FM_SUPERVISION_HOST_PARK_SECONDS=27000   # the host ends its park with a cycle-boundary wake after this long, under the Stop hook's 28800 s timeout
FM_SUPERVISION_HOST_TURN_TIMEOUT=1200    # bound on one engine turn; a turn that hits it hands its wake to main
FM_SUPERVISION_HOST_ROTATE_TURNS=20      # the engine conversation starts fresh after this many turns (and at every main session start)
FM_SUPERVISION_ENGINE_GRACE=30           # seconds between TERM and KILL when an engine turn is stopped
FM_SUPERVISION_HANDOFF_RETRY_SECONDS=300 # with config/supervision-handoff-ack, seconds between the detached owner's delivery retries of an unacknowledged hand-back
# spoken interface and captain inbox; see "Spoken interface and captain inbox" above
FM_VOICE_REGION=        # overrides config/voice-region for one relay run
FM_VOICE_MODEL=         # overrides config/voice-model for one relay run
FM_VOICE_PROFILE=       # overrides config/voice-profile; explicitly empty forces ambient credentials
FM_VOICE_ID=            # overrides config/voice-id; matthew when neither is set
FM_VOICE_RELAY=         # laptop-side path to bin/fm-voice-relay.py on the desktop; required by fm-voice-client.py unless --relay is passed
FM_VOICE_PYTHON=python3 # laptop-side interpreter used to start the relay over ssh
FM_INBOX_REGION=        # overrides config/inbox-region for fm-inbox.sh say and ask
FM_INBOX_STT_MODEL=     # overrides config/inbox-stt-model for fm-inbox.sh say
FM_INBOX_ASK_MODEL=     # overrides config/inbox-ask-model for fm-inbox.sh ask
FM_INBOX_PROFILE=       # overrides config/inbox-profile; explicitly empty forces ambient credentials
```

`FM_WEDGE_MAX_ESCALATIONS` bounds wedge escalations, not detection, so while its markers stand the dead-endpoint report is still consulted ahead of the short-circuit and reports a proven-gone endpoint exactly once per incarnation.
The cap covers the wedge timer, which is where a BUSY pane whose agent is still generating output is escalated once its busy age crosses `FM_BUSY_TURN_MAX_SECS`, including the early crossing an opted-in model-stream silence causes.
It does not cover the first-sight stale surfaces, so a pane that renders a new hash on every poll is re-classified rather than escalated and still emits one stale wake per hash.
That re-classification is itself an episode end, so it also releases the markers: a hash-churning pane is not capped across its own churn either, because every first sight after the cap fired re-opens that window. The away-posture first sight releases the markers without ending the episode, because the away daemon owns the one-shot per stale hash and the episode it was already in resumes on that same hash once the away-posture record goes.
The consecutive-escalation count the ceiling is computed from is written before the escalation it counts is published, except for an opted-in foreground model-stream observation, which writes its count only after that guarded publication attempt resolves, so a close, progress, or replacement during the publication lock wait is never counted; where a configured state dir refuses that write, the wedge path rolls back and silences itself through `FM_ROLLBACK_SENTINEL_TTL_SECS` instead of leaving an unenforceable ceiling that restarts at 1 on every poll; with the cap off the count is only what the wake reason reports, so the failure is logged and the unconfigured schedule is unchanged.
The three cap settings are all bounded above at 999999999999999999, the largest value the watcher's own comparisons can carry, so a value that is not a whole number in range takes that setting's documented default instead: an out-of-range ceiling reads as unset and leaves the ladder uncapped rather than gaining a ceiling the watcher cannot enforce, while an out-of-range horizon or sentinel TTL falls back to its own default.
Apart from a first-sight classification, only a pane that leaves the stale path, an opted-in model-stream episode whose evidence changes, a declared wait (`paused:` or a verified captain-held transfer) as it starts or is lifted, and the turn-end churn absorb clear the markers, and all of them clear them through the one episode-ending reset, which drops the wedge timer and, wherever a cap is configured, the escalation count the cap was counting in the same call.
That shared reset is what makes the release structural rather than a list of sites to keep in step.
At the first-sight routes the reset is also opt-in per site: under a configured cap the count restarts with the released episode, while with the cap at its default 0 the count survives those routes exactly as the pre-cap watcher's did - the timer dropped and re-armed (or dropped alone), the escalation count standing - so a home that has not set anything keeps today's ladder, including the `demand-deep-inspection` prompt for a stuck pane.
An operator can re-engage a capped window at once by deleting its `state/.wedge-permanent-<key>` marker, and a window silenced by a failed cap-state write by deleting its `state/.wedge-rollback-failed-<key>` sentinel; both files are safe to delete, and the window then escalates on the ordinary schedule again.
[`bin/fm-watch-key-lib.sh`'s header](../../bin/fm-watch-key-lib.sh) owns `<key>` derivation and the optional cleanup procedure for obsolete per-endpoint markers.
Turning the cap back off takes effect at once: every cap marker is read only while the cap is configured, so a leftover from an earlier configured run cannot keep a window silent in a home that has turned the cap off.

Upgrading a live home to the bounded `v3.` watcher keys intentionally resets its per-endpoint observation caches once, including stale timers, escalation counts, cap markers, and pause/wait notification throttles.
A previously capped window can start a fresh escalation ladder under the configured cap, and stale or declared-wait notifications can repeat before their new throttles are established.
This reset is harmless to running tasks and durable recovery state: task status, metadata, and wake queues are preserved, and a wedge notification never automatically interrupts, signals, or restarts a worker.
Declared pauses and waits are classified again from their existing evidence.
Their old notification throttles are not carried forward.
Legacy keys can conflate different endpoints, so importing their history could suppress a current endpoint using another endpoint's evidence.

`fm-teardown.sh` retries only Git's `Unable to create '...index.lock': File exists` return failure up to `FM_TREEHOUSE_RETURN_LOCK_RETRIES` times.
`FM_TREEHOUSE_RETURN_LOCK_RETRIES` accepts a nonnegative integer, and an unset, blank, or invalid value uses the default of 3.

`FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` accepts nonnegative whole or fractional seconds between attempts.
When it is unset or blank, `FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS` remains a compatible fallback, and a blank fallback uses the 1-second default.

An invalid nonblank wait falls back to 1 second rather than interrupting teardown.
Teardown never removes a lock during the retry window, and after that window it attempts stale-lock cleanup only for a still-present lock that passes the configured age and live-holder checks.

`fm-fleet-sync.sh` applies the same shape to an orphaned `.git/packed-refs.lock`: it retries only Git's `Unable to create '...packed-refs.lock': File exists` fetch failure up to `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES` times (nonnegative integer; unset, blank, or invalid uses the default of 3), waiting `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS` seconds (nonnegative whole or fractional; invalid falls back to 1 second) before each.
Only after those retries exhaust does it remove the lock, and only when it is provably stale - still present, mtime age at least `FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS` (default 30), and no `lsof` holder of the lock file or of the clone worktree itself (a live `git` keeps that as its cwd even in the window after it closes the lock and before it exits).

A live lock, a missing `lsof`, any failed check, or any other fetch failure keeps today's behavior.
Every wait, retry, and removal is printed to stderr, and a successful recovery also prints one `recovered:` summary line to stdout so a session-start refresh - which discards fleet-sync stderr and relays only stdout - still surfaces it.

The shared staleness proof lives in `bin/fm-lock-lib.sh`, which both `fm-teardown.sh` and `fm-fleet-sync.sh` use.
