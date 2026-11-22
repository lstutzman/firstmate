# Lavish review boards

Part of the [configuration reference](../configuration.md).

### Crew-hosted Lavish review boards

**Arm and confirm a listener**

A live task that hosts a Lavish board owns its listener, so firstmate must never arm that board.
After opening the artifact as required above, the worker arms it with `bin/fm-procevent-lavish.sh arm <artifact.html> --for <task-id>` and never runs `lavish-axi poll` itself.

`arm` prints `armed` only after the process-event owner confirms this registration generation's listener is running, and otherwise returns nonzero without that line.

- The confirmation is the same live claim or launch-stamp evidence `reconcile` already uses, bounded by `FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS`, and a failed confirmation retires a source that never started unless `retire` refuses because something may still own it, in which case the registration stays for `reconcile` or a human.
- An earlier registration's listener that releases the board inside the confirm window lets the new registration start, and `arm` then reports `armed` as usual.
- When a live listener from an earlier registration of the same board still holds it when the window ends, `arm` exits zero with `still-listening` instead of `armed`, because that earlier listener keeps serving the board and the new registration takes effect only after the source is retired and armed again.
- The arm is refused unless that task id has valid, identity-matching endpoint metadata, because a board whose owner has no endpoint would collect feedback nobody can be told about.

**Acknowledge a round by re-arming**

The registration persists as one task-owned source record, while each captured nonterminal round remains open until the worker re-arms and the existing handled marker acknowledges that round.
Re-arm acknowledges that round and registers the next listener: the board is armed once while no record exists, and a further arm by the same owner is refused unless an unacknowledged nonterminal round is waiting, so an open round is never replaced before its owner acknowledges it.

**Post an agent reply**

Re-arm never acquires, releases, or hands off the source claim.
It may carry `--agent-reply-file <path>`.
With lavish-axi 0.1.80 or newer, the reply is posted through `lavish-axi reply` under the source lock only after the arm passes its endpoint, ownership, and pending-round checks, and the server's acceptance is awaited before the listener is registered or armed.
An arm refused for endpoint, ownership, or pending-round eligibility never posts the reply, and a failed or timed-out reply stops the arm before it registers a listener or acknowledges the round, so the worker cannot hand the board back as ready and can retry the same arm.
If Lavish accepts the reply but the local registration then fails, retrying the arm posts that reply again; this rare duplicate is a known, benign limitation.

Older compatible Lavish versions keep the prior behavior: the reply is staged into the listener and sent through `poll --agent-reply`, which cannot confirm acceptance before its long-poll returns.
That compatibility path does not provide the synchronous handoff guarantee: a crash after the listener consumes its staged reply but before its poll posts it can lose that round's reply.
Only a version probe that confirms an older compatible release selects that path.
When `lavish-axi` is missing, its version cannot be read, or it is below the board floor, a reply-carrying arm fails without posting or registering a new listener; the worker's original reply file remains available for retry.
The Lavish version floors and feature probe are owned by `bin/fm-bootstrap.sh`.

**Deliver feedback to the worker**

- The captured result is stored with immutable task-owner routing evidence and delivered directly to that task's steering inbox, without a firstmate `check` wake for the captain's words.
- The doorbell rings only when that idempotent write creates a fresh inbox record; filing the note into `handled/` is the worker's own acknowledgement of the delivery, so a later reconcile never moves an already-filed note back into the active inbox or re-rings its owner, and re-delivery of a note still open in the inbox is left to the steering inbox's own re-ring ladder.
- A task-owned source with an unhandled capture is not relaunched, so delivery failure cannot consume a round and start another poll.
- That record is the only ownership evidence there is, so while any captured round of it is unacknowledged every retirement path refuses - the runner's own terminal retirement and an explicit `retire` alike - and the refusal names the acknowledgement that releases it.

**Conclude a terminal round**

- A terminal result, including `session_ended`, an empty End, or missing, is delivered to the owner with an explicit stop-and-conclude instruction and is never auto-rearmed.
- That round keeps the board with its owner: the source record is not retired while the terminal capture is unacknowledged, so no second armer can take the board, and acknowledging it with `bin/fm-procevent.sh handled <source-id> <sequence>` is what concludes and retires it.
- That conclude retains the registration it is retiring, removes it, then records the acknowledgement and restores the registration if that record cannot be written, so a failed conclude never leaves the round open with its owner gone.
- An interruption between those two durable steps leaves the board unregistered with its terminal round still open, which nothing relaunches and the same `handled` call finishes.
- It concludes only a round that is still open, so a repeated acknowledgement of an already-closed round reports `already-handled` and never touches whatever registration holds the board by then.

**Ownership and recovery**

- A second armer is refused with the current owner named, and the source list derives `listening`, `round-open`, or `dead` from the claim and handled captures without a second ownership record.
- If the hosting worker cannot be recovered, relaunch a worker to re-host first; guarded firstmate adoption is an explicit last resort only after the old claim is proved dead.
- The cross-home gap between worker rounds remains an accepted residual until lavish-axi's exclusive listener lands.
- The interim crew instruction emitted by `bin/fm-brief.sh` points workers at this arm-and-acknowledge contract.

**Register deterministic condition and action watches**

The `when` adapter (`bin/fm-procevent-when.sh`) registers a deterministic condition and action once.
Its blocking child polls the condition without waking firstmate.
A stable true fires the action at most once.
One terminal outcome is then durably captured and published as a wake, which remains eligible for re-announcement until handled.

The (condition, action) spec is stored privately under `state/when/` and hash-bound by a trust record the same way `bin/fm-check-register.sh` binds a custom check, while the spec separately binds the resolved action executable's bytes; a mutated or unregistered spec or a changed action executable is refused before the action runs, and that binding is reloaded from disk immediately before each fire rather than trusted from when polling started.
A repo update that fast-forwards an in-repo action's bytes in place would otherwise desync every already-armed watch's trust binding with no tampering involved; `bin/fm-procevent-when.sh rebind-all` re-hashes and republishes the binding for every registered watch whose action lives under `FM_ROOT`, including one already polling, so it keeps firing across such an update instead of being refused on its next fire.

Every failure path - a mutated spec or action executable, a condition error past its budget, an expired deadline, a failed action, or an earlier fire whose outcome was never captured - produces a terminal captured outcome that wakes firstmate rather than a silent retry, and a durable single-fire marker claimed before the action makes restarts and re-polls unable to fire it twice.
The adapter automates only the exact deterministic subset: anything needing judgment, and anything destructive, irreversible, or security-sensitive, keeps the ordinary check-fires-then-firstmate-decides flow, and the adapter's header and `--help` own its commands, flags, and outcome document.

**Capture and publish results**

This section is the single owner of the runner's operating contract.

- Process-event commands resolve the state root to its physical directory before validating it and deriving paths, so a home reached through a symlinked ancestor behaves like its physical spelling while an unsafe target directory remains refused.
- Registration writes one private record under `state/procevent/`, and a completed result plus its immutable adapter identity are captured under `state/procevent-inbox/` before any announcement or event can reference it.
- By default, results are published as ordinary `check` wakes carrying the source id and committed result sequence through the existing durable wake queue, so the runner adds no second notification control plane.
- The self-announcing adapter exception and its fail-safe ordering are defined below.
- The watcher delivers a queued result on its ordinary cycle by reporting it as an actionable `check` wake, so a default or fallback publication reaches firstmate through the same rewake path every other wake uses and never waits for a manual drain.
- A queued `check` delivery is reported at most once per captured source and sequence while any records for that key remain queued.
- A durable handled acknowledgement stops future source re-announcement, while a record already queued remains under the durable queue's authority until the ordinary drain's sequence-bound post-handling acknowledgement consumes it.
- By default, a runner releases its claim after one poll; an adapter that opts into `relisten` keeps that runner and claim across empty waits, captured results, and a same-command re-arm that lands between polls, adopting a replacement registration only when the registered command is unchanged and the claim still belongs to it.
  A failed relisten check releases the claim; the runner never refreshes its own home lease.
  The `bin/fm-procevent.sh` header owns the exact seam, and [remote secondmates](../remote-secondmates.md#how-remote-lines-are-mirrored) owns the reply listener's behavior.

**Reconcile sources**

Discovery is never a timer.
Each registered source has its own child process blocking on that source.
On every cycle, the watcher's `reconcile`:

- Republishes every captured result without a durable handled acknowledgement, regardless of earlier publication.
- Restarts a source whose owner is gone.
- Stops this home's runner if its registration disappeared unexpectedly.

In supported steady state, a home with no registered source runs nothing, generates no state, and keeps its ordinary cadence.

**Suppress only adapter-confirmed no-op results**

Whether a captured result is a routine no-op is adapter knowledge too, and the runner names no adapter-specific condition for it either.

- Before publishing, the runner asks the immutable captured owner through the built-in `silent` command or external `result.silent` operation and treats exit 0 as the only silence verdict: the result is recorded as durably handled and never announced, so it neither wakes a handler now nor returns on a later reconcile.
- The task-owned terminal exception is evaluated first, so an empty terminal board round goes to its owner's steering inbox for the required conclusion instead of entering this generic silence path.
- A missing command, an error, any other exit, or a silence the runner cannot durably record all publish the `check` wake exactly as before, so an adapter with no notion of a no-op needs no change and an unknown or degraded result always reaches its handler.
- For built-ins, silence remains independent of the keyed-answer feed below: suppressing an announcement never suppresses the captain's own answer.

**Lavish silence rules**

- For Lavish that verdict covers two shapes - a session the adapter classifies `ended` that carries no queued content block at all, which is a review surface closed with nothing said, and `browser_disconnected` (classified `disconnected`), which carries no answer while the session remains open.
- Any recognized top-level `prompts` or `feedback` block counts as content regardless of its declared count, and a malformed header makes the result indeterminate rather than empty.
- A `Send & End` close carrying the captain's answer arrives as `status: feedback` with `session_ended`, so it classifies `feedback` and is announced unchanged, as is any `ended` result that still carries content, and every `waiting`, `missing`, `unknown`, or unreadable result.

**Retire terminal sources**

Whether a captured result ends its source is adapter knowledge, never the runner's.
After capture, the runner asks the immutable captured owner whether the result is terminal.
It uses the built-in `terminal` command or external `result.terminal` operation.
Under the default ordering, this happens after the initial `check` publication.

- Exit 0 retires the registration.
  The exception is a task-owned board, whose owner must first acknowledge the round as defined above.
- Retirement drops only the exact registration generation captured by the claim.
  Under one source boundary, it releases that claim only after removal succeeds.
- A missing command, an error, or any other exit keeps the source armed.
  An adapter with no notion of ending needs no change.

- A failed terminal removal stays durably terminal and is completed by ordinary reconciliation without restarting its poll, while a concurrently replaced registration survives and becomes independently runnable after the old claim releases.
- Any registration refuses to replace an external registration while its prior runner claim is live, uncertain, orphaned, or terminal-pending; replacement becomes eligible only after that generation is proved gone or its terminal retirement completes.
- A source that has ended therefore captures at most one terminal result, is never restarted, and leaves no recurring poll work.
- For ordinary sources, explicit `retire` stays the supported and idempotent path afterwards; a task-owned board instead refuses `retire` until its owner concludes the open terminal round with `handled`.
- For Lavish that verdict covers an ended session, a missing session, and the final feedback of a `Send & End` review, which the published poll marks with `session_ended` before it returns only empty ended sessions.

**Apply built-in results automatically**

Applying a captured result through code is a built-in adapter seam, and some built-in results carry no judgement at all: they must simply be applied idempotently to this home's own durable state.
Leaving that to a handler means it can silently not happen, so immediately after the terminal check above the runner calls `bin/fm-procevent-<adapter>.sh autohandle <source-id> <sequence> <result-file>` and lets the built-in adapter apply and acknowledge its own result.

That call runs strictly after terminal retirement, because a handling adapter re-arms its own next source and retiring afterwards would drop that fresh registration and leave the source silently dead.
Exit 0 means the adapter fully applied and acknowledged the result; a missing command, an error, or any other exit is not a capture failure but leaves the result unacknowledged and therefore still eligible for re-announcement, so a handler receives it exactly as before and an adapter with no such command needs no change.

**Adapter-controlled announcement order**

The built-in `bin/fm-procevent-<adapter>.sh self-announcing` command declares announcement order:

| Response | Runner behavior |
| --- | --- |
| Exit 0 | The adapter declares that every result its autohandle fully applies is announced through its own durable downstream channel; the runner applies first, then publishes a `check` wake only for results still unhandled. |
| Any other response | Keep strict publish-before-apply ordering; autohandle runs only after this capture's own wake was successfully appended to the durable queue. |

The remote-secondmate reply adapter declares itself self-announcing: a captured reply reaches its local status mirror and settles its correlated pending-reply expectation without any handler step, the mirrored status bytes are the single wake for one remote note through the same signal classification a local secondmate's append gets, and only a capture the adapter could not fully apply is published as a `check` wake, whose adapter handling remains idempotent.
The [remote-secondmate channel contract](../remote-secondmates.md#normal-operation) owns replay suppression and its bounded upgrade exception; a replay that adds no mirror bytes stays quiet.

**Feed keyed captain answers**

Keyed captain answers from built-in adapters use one more seam of the same kind, and the runner still decides nothing about them.
Some built-in sources carry the captain's answer to a captain-held task, and what such an answer means is owned once by `bin/fm-captain-hold.sh`'s keyed-answer intake rather than by any channel.

- A built-in source bound with `bin/fm-captain-hold.sh bind` therefore has each captured result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>`, and whatever that prints is piped straight into that intake.
- A binding can select one decision origin or the script's cross-origin mode; the command header owns the exact forms and key interpretation.
- The built-in adapter reports only what the captain chose; the intake owns every rule about what happens next, so the runner names no adapter, parses no result, and carries no decision rule, and a future built-in answer source needs nothing here beyond an `answers` command and a binding.

**Reconcile selections and handling boundaries**

- The reserved Reconcile selection uses the parallel optional `reconciles` adapter command and binding-verified `reconcile-requests` intake rather than entering keyed answers; [`captain-hold-lifecycle.md`](../captain-hold-lifecycle.md#reconcile-re-check-reality-never-a-blind-close) owns those semantics.
- Feeding is independent of handling: it never acknowledges a result and never suppresses a wake, because recording the answer or request is transcription while acting on it is firstmate's judgement.
- An unbound built-in source, a built-in adapter without the corresponding command, and a failure on either side all leave the capture untouched and still announced.
- External binding responses never enter either authority-bearing intake.

**Machine-wide source ownership**

Ownership is machine-wide per canonical source, because separate homes can share one underlying source store.

- Claims live under `$XDG_STATE_HOME/firstmate/procevent-claims` (override with `FM_PROCEVENT_CLAIM_ROOT`).
- Each claim binds its caller-reported home and runner PID to a process identity, unique claim generation, exact registration-file generation, and resolved state-root identity.
- Registration, acquisition, replacement, retirement, and generation-bound release are serialized at one machine-wide boundary per source.
- A live identity-matched owner is never displaced, and release removes only the exact generation the caller acquired.

**Prove ownership before stopping a runner**

- Every stop proves ownership before its first signal: the live runner's recorded process identity must match and it must still lead its process group.
- Once that stop has proved ownership and sent TERM, its own escalation to KILL checks only whether the proved group still has members; it does not re-read the leader's identity or group membership, which can change or become unreadable as TERM ends the leader.
- This proof belongs only to that stop's own escalation and cannot authorize another caller that encounters an unproved group.

**Recover orphaned claims**

A stale claim whose process group still has members is one `reconcile` never displaces, and the two shapes it comes in recover differently.
`reconcile` preserves such a claim without signalling the ambiguous group or starting a replacement: the group check probes the runner's own process group, which contains its polling source child, so surviving members can mean that child is still attached to the session the source collects from, and a replacement would put a second destructive poller on it.

`list` reports both shapes as `orphaned`.

**Reused PID with surviving group members**

When the recorded pid is alive under a different identity but the group still has members, the claim boundary itself does not consult the process group.
In this case, `bin/fm-procevent.sh start <source-id>` reclaims the claim only if it can tidy the dead generation's reservation records.
Otherwise it refuses with `cannot claim source`.

Tidy-up is waived only for a generation proved gone.
This generation does not meet that condition.
That hand-run command is the recovery path, taken by someone who has checked that nothing is still polling the source.

That asymmetry between the automatic path and the deliberate one is the design rather than an inconsistency, and it is not a claim-level invariant: nothing below `reconcile` enforces it.

**Dead leader with surviving group members**

If the leader died from anything other than the stop's own signal and its group still has members, `start` does not reclaim the claim.
It reports `already owned` and changes nothing.

`retire`, `reconcile`, `sweep-home`, and the guard all refuse the surviving group permanently, so the source stops listening.
Recovery there is a human verifying whether the dead runner's polling child is still attached to the source; once that process group is empty the generation reads as gone and the next `reconcile` reclaims the source on its own.

Nothing automatic signals that group, and whether it may ever be signalled remains an open decision; the repaired guard does not close this gap.

**Report stranded claims**

The first `reconcile` that strands either kind of claim generation publishes a durable `check` wake.
It names the source and the recovery step:

- For a reused pid, the `start` command.
- For a leaderless group, the check to make.

Later cycles stay silent for the same generation.
A genuinely new stranded claim announces again.

**Reclaim a generation proved gone**

Reclaiming a generation that IS gone is not gated on tidying anything that generation left behind: its capture-reservation records, its staging file, or the registry directory a claim recorded for them.
Every one of those is keyed by claim token and every replacement claims a fresh one, so a leftover that can no longer be located or removed - a state-root identity a claim recorded before its home was re-created, or a recorded registry directory that no longer resolves to a directory - is stale bytes rather than an ownership hazard.

Making any of them a precondition is what leaves a provably dead runner owning its source permanently, because none of those conditions clears on its own.

- Ordinary release and reclamation still attempt reservation cleanup and require it unless both owner staleness and whole-group absence prove the generation gone.
- The narrow live-owner terminal-self-retirement path also attempts cleanup but tolerates its own still-in-flight reservation, which the runner removes on the normal end-of-capture path; exact home, PID, and claim-token ownership remains mandatory before the claim is released.

**Stop refusals and residual races**

- If identity cannot be established before the first signal, or a surviving owned group cannot be proved stopped, the operation preserves the registration and claim for safe retry rather than adding a second owner.
- A live PID whose identity no longer matches is refused before the first signal.
- Identity and process-group verification cannot be made atomic with signalling in portable shell: the reaper signals only a target it has verified as the recorded generation, but PID and group reuse remain possible in the narrow interval between verification and the signal.
- Launch pacing is the primary host-wedge protection; watchdog cleanup is a backstop.

**Retire a secondmate home**

- Supported secondmate retirement preflights each target home's bounded `sweep-home` command before destructive teardown, snapshots its registrations outside the target, then runs the sweep at that home's final deletion or return boundary.
- If deletion or return fails, teardown restores those registrations and reconciles them before returning the refusal.
- If restoration or rearming also fails, teardown returns a distinct status and reports the retained registration backup path for manual recovery instead of hiding the retired waits.
- The sweep retires local registrations and machine-wide claims whose recorded state-root identity matches that home's resolved state root through the same identity-checked, generation-bound retirement path, and leaves foreign-home claims untouched.
- Teardown refuses with the home, lease, routing evidence, registrations, claims, and runners retained when identity is uncertain, ownership is unreadable or unreleased, or relevant state exists without a sweep-capable child script.

**Recover from unsupported manual deletion**

Raw manual deletion of a Firstmate home is unsupported because it can orphan a blocking child.
To recover, restore that home's tracked `bin/fm-procevent.sh`, run `FM_HOME=<home> <home>/bin/fm-procevent.sh sweep-home`, then rerun the supported teardown.

The owning-home lease below bounds how long such an orphan can run, but it is a backstop, not a substitute for the supported path.

**Home lease and its limits**

A runner is bound to the HOME that owns it, not to the one session that armed it.
That granularity is deliberate: a persistent source is meant to outlive the turn and the session that armed it, so binding a runner to its arming session would stop exactly the sources this mechanism exists to keep running.

Any activity in the same home refreshes the lease, so a replacement session, another watcher, or an ordinary inspection command keeps a runner of that home alive; a runner whose SOURCE is no longer wanted in a live home is stopped by reconcile when that source is retired, independently of the lease.
The lease is therefore the backstop for a home that is GONE - the torn-down test sandbox this change exists to bound - and not a per-session ownership check.

KNOWN LIMIT: while any activity continues in a home whose original owning session has ended, that activity refreshes the lease and a runner of that home keeps running until its source is retired or the home goes away.

**Keep and guard the lease**

Detaching a runner into its own process group is what lets a persistent source outlive the turn that armed it, and on its own it is also what lets a runner outlive its whole home: reparented to init, it keeps its blocking child - and every process that child spawns - running with nothing left to reap it.

- So a home's process-event state carries a lease that registration, attached start, reconciliation, acknowledgement, listing, and detached launch by a non-runner caller through `reconcile` or `ensure-listening` refresh, and the watcher's reconcile cycle is what keeps it fresh in a live home.
- An attached public `start` continues refreshing the lease while its caller remains attached.
- Each runner fails closed unless a small guard starts successfully beside it in a separate process group.
- That guard accepts the lease only while the state root retains the device/inode identity recorded by the runner's claim, and initiates the verified stop after two consecutive reads cannot prove that identity and lease freshness, so one unreadable read cannot kill a live runner.
- Those two reads are spaced half a check interval apart, so the pair the debounce requires completes inside one check interval instead of costing two of them.

**Detection and stop timing**

For a runner whose ownership can still be proved, the nominal detection bound is the lease plus one check interval.
The verified stop then runs within its own grace period.
The lease age is compared in whole seconds, so the configured lease is honoured until that age reads one second past it.

Scheduling delays or failed inspection and signalling can extend the whole bound.
That grace is a ceiling rather than a delay every stop pays: two seconds for the ordinary signal and two more for the forced one, spent only by a group that outlives the signal it was sent, which is why a healthy runner's stop completes in a fraction of a second.

The group signal reaches the blocking child and everything under it exactly as retirement does.

**Prevent accidental self-refresh**

- A runner exports the inherited `FM_PROCEVENT_IN_RUNNER` marker and every lease refresh is skipped under it, so a runner and its ordinary children do not certify their own owner, and the next reconcile in a live home simply starts a replacement runner.
- That no-self-refresh rule is CONFUSED-AGENT-GRADE, the same deliberate captain-decided grade `bin/fm-lease-lib.sh` documents: it stops the accidental case this boundary exists for, an orphaned or test-scaffolding source tree that would otherwise keep its own owner alive.
- A source that DELIBERATELY strips the marker from its environment can still refresh the lease, so adversarial-grade unforgeability is explicitly out of scope here and tracked as separate follow-up design work.
- Scope is the owning state root and one runner generation, never a script or process name, so a live source in another home is untouched: that home refreshes its own lease.

**Lease and launch pacing settings**

| Setting | Default | Range | Purpose |
| --- | --- | --- | --- |
| `FM_PROCEVENT_OWNER_LEASE_SECONDS` | 600 | 1..86400 | How long a runner continues without activity in its owning home. |
| `FM_PROCEVENT_OWNER_CHECK_SECONDS` | 15 | 1..3600 | Guard detection interval; it reads the lease and recorded state-root identity twice per interval, half an interval apart, so both debounce reads fit inside one interval. |
| `FM_PROCEVENT_LAUNCH_FLOOR_SECONDS` | 1 | 1..3600 | Minimum time between consecutive launches of one registration generation's stored command; bounds immediately returning sources during the lease window. |

The generation's first launch is immediate, later launches share its monotonic pacing timestamp, a timestamp from before a reboot is treated as expired, and replacing the registration starts a fresh pacing generation.

**Confirm detached launches**

`FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS` (default 3, range 1..600) bounds how long `reconcile` waits for the runners it just started to prove they are running: never less than the configured value, and at most one second more, because the wait is measured on a whole-second clock.

- Starting a runner is detached and its errors are not visible to the caller, so `reconcile` reports a start only after the source is observed owned or its launch-pacing stamp has advanced or appeared, and reports every unconfirmed launch as `failed=` and a non-zero exit instead.
- Both signals are durable evidence a runner claimed: ownership is the only evidence a runner still blocked on its source ever shows, and the stamp - written after the claim and before the source command runs, and removed only by registration replacement - covers a runner that claimed, ran and exited between two polls.
- A healthy launch therefore confirms on the first poll and the window only bounds a launch that has not yet proved itself - one that died before claiming, or one merely too slow to claim inside the window; confirmation cannot tell those apart, and a launch that proves itself on a later cycle closes its failure episode without a retraction wake.
- Confirmation takes the source lock only once a claim exists, because a runner needs that lock to claim and polling it earlier would starve the launch being confirmed.
- All of a cycle's launches share one window, so a home full of sources that cannot start costs the same bounded wait as one.

**Keep confirmation below the watcher interval**

Keep this window well below `FM_POLL`.
`bin/fm-watch.sh` runs `reconcile` once per supervision cycle, so a source that cannot start makes every cycle wait up to the confirm window before the rest of that cycle runs.

Raising the confirm window lengthens every supervision cycle and delays wake delivery by up to that much.

**Report launch failures**

A detached launch that never confirms is reported as `failed=` with a non-zero exit on every `reconcile`, rather than counted as `started` and retried silently as though it were healthy, so a wedged source stays visible instead of presenting as armed.
The `failed=` count reaches only the command's caller because `bin/fm-watch.sh` discards `reconcile` output and exit status.
For that reason, `reconcile` also publishes a durable `check` wake once per failure episode, with key `procevent:<id>:launch-failed:<registration-identity>-<episode-nonce>`.
Later cycles stay silent for that episode until a launch confirms.
A later fresh failure gets a fresh key, because the watcher never re-surfaces a key it has already surfaced.

- The announcement changes nothing about the launch: `reconcile` keeps relaunching the source every cycle exactly as before, and nothing is retried differently, throttled, or recovered from that signal.
- The wake reports only the observed failure: the launch did not prove that it took the claim within the window.
- If the failure persists, inspect the source command and adapter binary named in the registration.
  The wake names both, along with the attached `bin/fm-procevent.sh start <source-id>` command that reproduces the refusal on stderr.
  The detached launch discards that output.
- A later cycle that finds the source owned ends the episode automatically.
  A runner that was merely slow to claim needs no operator action.
- A source stranded on a claim nothing may automatically displace is announced the same way, once per stranded claim generation, as described above.
- `bin/fm-watch.sh` surfaces both under their own headlines - `process-event source stranded` and `process-event source failed to start` - rather than as a captured result.

An extension invocation cleanup refusal prevents a replacement launch and increments `uncertain=` instead of `failed=`.
It also publishes one durable wake per source failure episode using the `launch-failed` key family and `process-event source failed to start` headline.
The payload points to the extension host's cleanup diagnostic in the source's home and effective state root, without copying package diagnostics into the wake.
Reconciliation preserves the registration and retries cleanup on later cycles.
Successful reconciliation cleanup, an attached start that acquires the claim, or reconciliation observing a live owner clears the cleanup announcement marker, so another refusal on the same registration receives a fresh wake key.
Retirement removes the marker as well.

**Reject unusable settings**

A value this command cannot use is refused by name before anything is launched, the same way `FM_PROCEVENT_LAUNCH_FLOOR_SECONDS` and `FM_PROCEVENT_MAX_OUTPUT_BYTES` are refused, so a mistyped window can never present as a fleet of sources that cannot start.
`bin/fm-watch.sh` validates the same value when it arms and refuses to arm on an unusable one, naming the variable and the range: under a running watcher that refusal would otherwise repeat on every cycle into a discarded stdout and leave the whole home disarmed while presenting as supervised, whereas a watcher that will not arm is loud through the liveness guard.

**Limit captured output**

`FM_PROCEVENT_MAX_OUTPUT_BYTES` (default 1048576) bounds a single captured result while the source runs; oversized output is drained but truncated with a stderr notice rather than staged or published whole or dropped.

**Durability guarantees and limits**

The runner proves exactly one durability boundary: output that reached the runner is stored at mode `0600` before any event referencing it is published, and a captured result with no durable handled acknowledgement remains eligible for bounded re-announcement across any number of drains and restarts, not only the crash window right after capture.

- `bin/fm-procevent.sh handled <source-id> <sequence>` is the only thing that stops re-announcement: a generation-keyed, private, path-safe, durable, and idempotent acknowledgement that atomically checks and deduplicates by the exact source and sequence, so a paired effect gated on its first-time-vs-repeat report is never authorized twice.
- Default and fallback `check` publication is still best-effort, so the same source and sequence can repeat even before any restart; handlers deduplicate that identity rather than assuming a wake is unique.
- The runner proves nothing about the source side, and the handled acknowledgement proves nothing about a paired external effect performed before it: a crash between that effect and the acknowledgement call can still repeat the effect on replay, so this is never a generic exactly-once guarantee.
- The published `lavish-axi poll` clears feedback destructively before returning it, so a result lost between that clearing and the runner reading process output is unrecoverable.
- Never describe this path as at-least-once, no-loss, or lossless.

`docs/verification/process-event-sources.md` holds the measurements and `.agents/skills/process-event-sources/SKILL.md` owns the handling procedure.
