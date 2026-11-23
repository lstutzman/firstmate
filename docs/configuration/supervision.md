# Supervision

Part of the [configuration reference](../configuration.md).

## Calm preference (config/calm)

The Pi Calm extension and the Claude Code Calm mod share the local, gitignored `config/calm` preference under the effective Firstmate home.
One `/calm` choice therefore applies on either harness.
Both resolve the home in this order: `FM_HOME`, `FM_ROOT_OVERRIDE`, then the tracked code root derived from their own path under it.
When `FM_CONFIG_OVERRIDE` is present for tests or specialized setup, it selects the config directory directly.

### Values and default

| Value or file state | Result |
| --- | --- |
| `on` | Calm on. |
| `off` | Calm off. |
| Absent, unreadable, or unrecognized | Defaults to off. |

Both written values end with one newline.
`max` is a legacy value from a removed third presentation level.
Its behavior is now ordinary Calm, so it is still read as `on`.
A home upgraded from `max` keeps Calm on rather than dropping to off.

### Saving and reloading the preference

Each `/calm` command saves the new choice before changing live presentation.
A failed write leaves the current choice unchanged and is not reported as a saved preference.
Pi replaces the file atomically; the Claude Code mod uses the plugin API's plain file write.
The Pi extension reloads this preference on every Pi `session_start`, including startup, new, resume, fork, and reload reasons.

The Claude Code mod reloads it on every `session.start`, including same-process session replacement.
It also loads the preference lazily before any row that can draw ahead of that event, including during `claude --continue` restoration.
This preference is local to each Firstmate home and is not part of secondmate inherited configuration.

## Pi repeated-read containment

The tracked `.pi/extensions/fm-primary-read-repetition.ts` extension provides an optional read-loop safeguard for a Linux Pi primary.
It is off by default, including when configuration is absent or omits `enabled`.
When enabled, it stops the owning primary after three identical recognized reads return the same successful result within fifteen minutes.
It blocks the next call before execution and requires fresh interactive or RPC user input to resume.
Extension input and marked operational follow-ups cannot reset that stop, including the turn-end guard's recovery message.
The stopped owner also cancels compaction so the aborted turn cannot start a separate compaction request.
Changing results, errors and nonzero exit codes break the repetition sequence.
An identical call already in flight is temporarily blocked without being counted as a completed success.

Optional `config/read-repetition.json` configures the guard at extension load:

```json
{"enabled": true, "repeatLimit": 3, "windowMs": 900000}
```

`repeatLimit` must be an integer from 2 through 32, and `windowMs` an integer from 1000 through 86400000.
An absent file uses `enabled: false`, `repeatLimit: 3` and `windowMs: 900000`; malformed JSON, unknown keys or invalid values report an extension-load error instead of silently substituting limits.
`enabled: false` registers no guard handlers.
Configuration changes require the next extension load.

Ownership requires the effective home, current directory, session directory and primary PID marker to match this primary, with the session lock naming its process or a verified ancestor.
Workers, supervision branches, foreign owners and nested capability probes remain outside the guard.
Linux ancestry uses bounded `ps` queries, including when a wrapper holds the lock.
Enabled configuration on macOS or Windows reports an unsupported-platform load error; those platforms have no protection claim.
Missing ownership evidence leaves the guard inactive without writing session history or aborting another session.
A proven owner records `fm-read-repetition-activation-v1` in its Pi session journal with the effective limits and restored latch state; extension discovery alone is not evidence of activation.

The recognizer counts Pi's native `read`, `grep`, `find` and `ls` tools plus a conservative subset of ordinary shell reads.
It recognizes a narrow SSH read shape without executing or interpreting its command.
Supported shell forms include simple `cat`, bounded `head`/`tail`, `sed -n N,Mp`, pipeline `cut -cN-M`, selected `grep` options, `nl -ba` with optional `-vN` line numbering, `wc -l`/`-c` and `od -An -tx1c`/`od -An -c`.
One outer parenthesized group may contain a sequence of recognized reads separated by semicolons or newlines, including `cd /project`, read pipelines and unquoted backslash-newline continuations.
Every stage must be recognized; nesting, brace groups, shell substitutions, redirections other than `2>&1`, additional shell interpreters and unknown programs or options are uncounted.
Ungrouped multiline shell commands and polling tools are also uncounted.
An unrecognized stage makes the entire shell command uncounted, even if its output repeats hundreds of times.
This is a repetition detector, not command authorization or comprehensive loop detection.
History contains bounded hashes, labels and timestamps rather than read arguments or output; the stopped latch survives reload and compaction.
SDK-generated temporary paths in truncated Bash footers are normalized only when matching truncation metadata identifies them.

The extension uses the existing tracked-file distribution and trusted Pi project auto-discovery described in the [setup guide](../../README.md).
The supported interception surface is Pi's own session event pipeline, including RPC sessions; its tool-call, result, input, session and compaction-veto hooks must all execute.
Other primary harnesses, worker interruption and tool execution in a separate native adapter are outside this extension's protection.
An adapter's `firstmate:native-tools` registration does not forward this interception or abort contract.
The stop is stored as a displayed custom message, but a native app may filter that message; an abort alone does not prove that its detailed notice was shown.
Current SDK and installed-harness evidence is recorded in [runtime backend verification](../verification/runtime-backends.md#pi-repeated-read-containment).

### Migrating an ignored local guard

The managed entrypoint and `lib/fm-primary-read-repetition-policy.ts` intentionally differ from the local workaround's `fm-read-repetition-guard.ts` and `lib/fm-read-repetition.ts`.
An update therefore preserves those old ignored files and `config/read-repetition.json`, including with an updater from before this feature.
If the legacy entrypoint is present, enabling the managed guard refuses to register its handlers and reports the migration needed; a broken symlink at that path also refuses activation.
The legacy extension may still run under its own rules until it is migrated.
Before enabling the managed guard, preserve both legacy files and any existing configuration in a private backup outside Pi's extension discovery directories, then move the legacy entrypoint outside `.pi/extensions`.
Retain the backup and deliberately review the existing configuration before setting `enabled: true` and reloading extensions normally.
No automatic migration, removal, overwrite, reload or live-process change occurs.
For a locally installed file at either new managed path, preflight the update and use Git's `--no-overwrite-ignore` fast-forward option; an older updater does not protect arbitrary ignored-path collisions.

## Pi supervision branch

On a Pi primary, an in-process supervision branch handles eligible task-local wake rows and selected heartbeat reviews.
Main-only rows stay on the captain-facing path.
[docs/pi-supervision-branch.md](../pi-supervision-branch.md) defines its conversation lifecycle, row eligibility, mixed-queue dispatch, heartbeat routing, and pre-drain recheck.
Supervision is default-on: once a Pi primary session owns this home's fleet lock, the branch is eligible for every task with no captain grant file required.

Bash absorbs a genuinely no-op heartbeat before it reaches Pi.
Every watcher-failure alarm stays on the captain-facing main path.
If the branch breaks, wakes still fall back to main in both postures.
The legacy `state/.afk` daemon flag has no effect on Pi.

### Attended and away authority

While the away-posture record `state/.afk-contract` exists:

- The branch takes every actionable row.
- No processing turn opens on the parked main.
- Main's standing authority moves to the branch through the guarded scripts, each retaining its own gate.

[docs/pi-supervision-branch.md](../pi-supervision-branch.md#postures) defines that posture.

While attended, the branch cannot merge a PR, land local work, freshly spawn, or answer a decision.
These are the bounds set by the captain-approved architecture.
Every existing captain gate remains unchanged in either posture.
Homes on other primary harnesses do not load the Pi branch extension; shared per-task lease behavior is owned by `bin/fm-lease-lib.sh`.

`AGENTS.md`'s `state/` inventory routes the branch's runtime files to their format and lifecycle owners.

### Outcome delivery and acknowledgement

While attended, a captain-facing branch outcome (verdict `captain`) is saved as one exact visible transcript entry keyed by sequence.
It then opens one processing turn on main for that sequence.
The turn stays open until main acknowledges the sequence through its `fm_branch_processed` tool.
While away, the entry is saved, but processing waits until the away-posture record is archived.
The branch prompt's "Verdict: routine or captain" section owns the distinction between captain-facing, unsolicited routine, and unchanged-review outcomes.

The generated [Pi supervision protocol](../supervision-protocols/pi.md) owns main's event ownership, acknowledgement duty, and conversational treatment for merged outcomes, while the persisted entry itself owns captain visibility.
A task-level routine no-change outcome or a no-change heartbeat explicitly reported with `silent=true` is delivered without a rendered note; the branch prompt owns task-level eligibility, and every other routine outcome still appends a rendered, sailboat-prefixed note.

## Pi supervision branch model and effort (config/supervision-branch-model, config/supervision-branch-effort)

The branch can run on a cheaper model than main because supervision is an easier job than the captain's own conversation.
It can also use a lower reasoning effort because supervision needs less reasoning than that conversation.

### Choose a model and effort

The Pi `/supervision-model` command settles both in one flow: it opens a selector over the models that Pi reports with configured credentials and that this home's stored credentials let the isolated supervision branch resolve, plus a first "Follow main" entry, and then a second picker for the branch's reasoning effort.
In Pi's terminal TUI, the model step uses Pi's bounded scrolling list with its input and fuzzy filtering primitives, the same list primitive Pi's `/model` picker scrolls: typing filters the entries, "Follow main" stays the first entry whenever it still matches, and a long catalog scrolls inside the dialog instead of running off the terminal.

The non-TUI RPC, JSON, and print modes have no custom-component surface and keep Pi's generic selector without search, where terminal overflow does not apply.
The effort list is a handful of levels and stays on Pi's plain selector dialog.

Both picks change the supervision branch alone and never the captain's own conversation model or effort.

### Saved settings and available models

The command saves the model pick in gitignored `config/supervision-branch-model` and the effort pick in gitignored `config/supervision-branch-effort`.
Both live under the effective Firstmate home, resolved in this order: `FM_HOME`, `FM_ROOT_OVERRIDE`, then the tracked code root derived from the extension path.
When `FM_CONFIG_OVERRIDE` is present for tests or specialized setup, it selects the config directory directly.
Firstmate keeps no model catalog of its own.
The list is the intersection of what Pi reports when the picker opens and what a fresh isolated branch runtime can run.

A provider that exists only because an extension registered it inside the captain's session, such as pi-devin-auth's `devin`, is offered and can be pinned or followed like any other; [pi-supervision-branch.md](../pi-supervision-branch.md#cost-model-and-the-byte-stable-prefix) owns how that registration reaches the isolated branch runtime.
Stored OAuth and API-key credentials retain their native credential type because Firstmate never copies, converts, installs, or overwrites credentials for the branch runtime.

### Model file format and default

The model file holds one `<provider>/<model-id>` line followed by one newline.
Parsing splits at the first `/`, so a provider-qualified model id such as `openrouter/anthropic/claude-sonnet-4-5` survives intact.
An absent, unreadable, or unparseable file means no pin.
The branch then follows main's current model, applied explicitly and live whenever main changes models mid-session.

### Following a native Codex model

When main uses `codex-native`, following main explicitly selects the same model through ordinary Pi's `openai-codex` provider, so the background branch owns an independent Pi conversation.
If that ordinary Pi model is unavailable, the branch refuses to build and returns the notification to main; it never inherits the main native thread or silently selects a different model.

Picking "Follow main" under a `codex-native` main reports that same `openai-codex` model, or that same refusal, because the command and the branch build share one follow rule.
A `codex-native` branch pin is refused and excluded from the picker.

### Applying and changing a model pin

A valid pin wins over main and remains unaffected by main's model changes.
Picking "Follow main" removes the file, and the command writes a pin at mode `0600` and replaces it atomically so a failed write leaves the current choice unchanged rather than claiming persistence.

The file decides the branch model on every build: the new conversation opened at each main session start, and a reopen after a model or effort change within a session.
It overrides the model Pi would otherwise restore from the reopened branch session, so the choice survives both cases.
That override is what keeps "Follow main" honest: a branch conversation that ran under an earlier pin still records that model, so clearing the file explicitly applies main's model rather than letting the reopened session restore the old one.

### Unavailable models

For ordinary Pi providers, an unpinned build passes no model override only when main's model is unknown or this home's stored credentials cannot run it in the isolated branch runtime.
This preserves the behavior from before the file existed.
Model choice never loses the wake.
If main's model could not be applied, the command reports that failure instead of reporting a change that did not take effect.
If a pin names a model Pi cannot return because it is unknown or has no configured credentials, the branch refuses to build.
It sends the accepted wake back to the watcher's captain-facing main path, as any other unreachable branch does.
It never silently falls back to main's model.

Picking also releases the live branch so the next wake reopens this session's own branch conversation under the new model without waiting for a session replacement.

### Effort file format and available levels

The effort file holds one Pi thinking level followed by one newline.
Model and effort pins are independent: a captain may pin either, both, or neither.
The effort step follows the model step because the effective branch model determines which levels exist.
The menu uses Pi's own supported-level list.
Models without extended levels do not offer them; a non-reasoning model offers only `off`.

The picker keeps no effort catalog of its own; when main's model cannot be resolved, it first resolves the model recorded by the most recent branch conversation and uses Pi's supported levels for that effective model.
If neither model can be resolved, the picker invents no levels and the command says that the branch's effective effort cannot be determined.

### Applying and changing an effort pin

An absent, unreadable, or unrecognized file means no effort pin.
The branch then follows main's current effort, applied explicitly and live whenever main changes effort mid-session.
A valid pin wins over main and remains unaffected by main's effort changes.

Picking "Follow main" removes the file, and the command writes an effort pin at mode `0600` and replaces it atomically, exactly as it writes a model pin.
The effort file's current state decides the branch effort on every branch build, on the same create-and-reopen contract as the model pin and for the same reason: a reopened branch conversation records the effort it last ran under, so only an explicit override keeps "Follow main" honest.

Only when main's own effort cannot be read either does an unpinned build fall back to passing no effort override at all, which is the behavior from before this file existed.

### Unsupported effort levels

Pi maps an unsupported pinned level to the branch model's nearest supported level.
Effort never causes the branch to refuse a build.
The captain's raw pick is kept so it applies again on a model that supports it, and the command reports the level the branch will actually use.
An effort token Pi would not recognize at all is treated as no pin rather than passed to that clamp, which would otherwise collapse a typo into the model's lowest level.

### Cancellation and inheritance

Cancelling the model picker cancels the whole command and changes neither choice.
Cancelling only the effort picker keeps the standing effort choice and still applies the model pick from the same run.
The command's closing message reports both choices as they will take effect.

Both choices are local to each Firstmate home and are not part of secondmate inherited configuration, the same as the Calm preference; a secondmate home pins its own supervision model and effort with its own `/supervision-model`.

## Supervision host (config/supervision-host)

Two optional local, gitignored files control the supervision host for this home: `config/supervision-host-off` opts the home out, and `config/supervision-host` opts a home in and selects its engine.
The host runs the supervision branch's contract on a headless engine session beside a non-Pi primary.
[docs/supervision-host.md](../supervision-host.md) defines its design, current scope, and verified engines.
A Claude, Cursor, OpenCode, omp, Grok, or Codex primary can run the host.

A present `config/supervision-host-off`, whatever it holds, opts the home out on every primary.
Otherwise a Claude primary runs the host by default: with no `config/supervision-host` it runs exactly as with an empty one, at the Claude engine's default model.
A Cursor, OpenCode, omp, Grok, or Codex primary runs the host only while `config/supervision-host` exists and the home is not opted out.
A home that does not run the host behaves exactly as it does without it, and a Pi primary keeps its in-process supervision branch whatever either file says.
`fm_supervision_host_enabled` in `bin/fm-supervision-engine-lib.sh` implements this gate for every reader.

While the home runs the host, the primary's arm owner runs it in place of the watcher arm.
The host handles wakes on the engine under the [posture rules](../supervision-host.md#postures), including an away record and attended operation on a Claude or Cursor primary with a verified dialog mirror.
On that home, `/afk` launches no away daemon; see [Quiet mode](../supervision-host.md#quiet-mode) for `/quiet`'s attended statement and fallback.
The same gate governs the primary's dialog-mirror hooks (`bin/fm-host-mirror.sh`), which record on a Claude or Cursor primary ([supervision-host.md](../supervision-host.md#the-dialog-mirror)).
Grok's arm command is rendered at session start, so a change to its host mode takes effect at its next session start; the other arm owners check the gate at every arm.

### Engine selection

`config/supervision-host` may be empty or hold one line `<engine> [<model>]`:

- empty or `default` selects the primary harness's own engine at that engine's default model (`sonnet` for the Claude engine);
- `<engine> [<model>]` names a verified engine, currently only `claude`, and optionally the engine's own model name or alias; `default <model>` selects the primary harness's engine with that model.

Only Claude has a verified engine of its own, so a Cursor, OpenCode, omp, Grok, or Codex home names `claude` in the file.

### Failures, when changes apply, and inheritance

An unverified engine, a primary without a verified engine, or a malformed line leaves the host without an engine.
It takes no wake, so every wake reaches main as it would without the host.
Each away-posture wake includes a line naming the problem.
The running host reads both files at every wake, so an engine change or an opt-out takes effect at the next wake without a restart.

The opt-out is inherited into secondmate homes: a primary that opts out also opts its secondmates out, and clearing it restores each mate's own host setting at its next spawn or convergence.
The primary-authoritative propagation contract, including removal of a mate's local opt-out when the primary has none, is owned by [`secondmate-provisioning`](../../.agents/skills/secondmate-provisioning/SKILL.md).
`config/supervision-host` is local to each home and not inherited, because each home's engine and model are its own choice.
While the home runs the host, main's lease-checked commands also take the per-task lease lock, so a claim by the host's engine cannot race a mutation main already started (`bin/fm-lease-lib.sh`).

### Acknowledged hand-back (config/supervision-handoff-ack)

Create the empty, home-local `config/supervision-handoff-ack` file to enable acknowledged hand-backs on a Claude primary that runs the supervision host.
The flag is off when absent, is not inherited, and has no effect on other primaries or the host-off Stop path.
The host reads its presence at each hand-back, so enabling it needs no session restart.
Removing it stops further retries and leaves the current watcher for the ordinary next park.
[Supervision host](../supervision-host.md#acknowledged-hand-back) owns the acknowledgement, retry transport, and limits.

## Codex native Stop park (config/codex-stop-park)

Create the empty, home-local `config/codex-stop-park` file to let a Codex primary wait for watcher wakes outside the model between turns.
The feature is off when the file is absent, and every Codex session then keeps the bounded foreground checkpoint protocol.
With the file present, only an interactive native Codex session on the verified CLI version that holds this home's session lock parks; every other session keeps the foreground checkpoint.
The supervision protocol is chosen when the session starts, so create or remove the file before starting the Codex session.
The file is local to each home and is not inherited by secondmate homes.
[The Codex protocol](../supervision-protocols/codex.md) owns the parked operating protocol, and `bin/fm-codex-stop-park.sh` owns version selection, registration, and failure fallback.

## Wake auto-acknowledge (config/wake-auto-ack)

Create the empty, home-local `config/wake-auto-ack` file to let a supervisor's `bin/fm-wake-drain.sh --summary` acknowledge a batch of wakes that need no action.
The summary mode prints one line per wake with its kind, subject, the current state that decides it, and a verdict of `no-action` or `ACTION`, then the usual `WAKE_ACK_REQUIRED` command.
It is the supervision protocols' drain command, so the supervisor needs no second read to see whether a wake needs it.
With the file present, a main-actor `--summary` drain whose every row is `no-action` and whose presentation printed nothing else acknowledges the batch through the ordinary acknowledgement path and prints one `WAKE AUTO-ACKED` line.
A batch with one `ACTION` row, or any unread status, record divergence, due default, branch outcome or supervision alarm, acknowledges nothing.
An OPEN DECISIONS section does not block it only when its folded text is byte-identical to the one last presented to a model, which `state/.wake-open-decisions-presented` records as a hash; a new, changed or removed decision line wakes the model, and the unchanged section still prints on the next real drain.
A recovery episode with no queued rows, the case behind a `check: rearm-resurface` wake, is retired the same way when nothing else printed.
On a Claude primary that does not run the supervision host, the Stop hook applies the same decision before it wakes the model: `bin/fm-wake-drain.sh --quiet-ack` classifies the queued wakes and, when every one is `no-action`, acknowledges them in code and the hook re-arms the watcher without a model turn; any wake that needs judgement wakes the model as it does without the file, with nothing consumed.
The next `--summary` drain reports how many wakes were acknowledged that way and their kinds from `state/.wake-auto-acked`, once.
Every classified wake is also counted in `state/.wake-classified.jsonl` (`ts`, `seq`, `kind`, `verdict`, `auto_acked`), so the real no-action share can be measured.
The feature is off when the file is absent, is local to each home and is not inherited by secondmate homes, and the plain drain never acknowledges.
The classifier is `bin/fm-wake-summary.sh`, whose header owns the exact no-action cases; its verdict is the whole handling of such a wake.
Creating the file is a captain-class change to what a supervisor skips, so main routes it to the captain.

## Warm-cache compaction (config/warm-compact)

Create the home-local `config/warm-compact` file to compact an idle Claude primary and the supervision host's engine conversation before their prompt cache expires.
A session that sits idle past the cache lifetime re-writes its whole context at the cache-write price on its next turn.
Compacting while the cache is still warm reads the old context at the read price, so the next turn writes only the summary.

The feature is off when the file is absent.
The file is local to each home and is not inherited.
The host reads it at every check, so creating or removing it needs no restart.
By default it acts only on a home that runs the [supervision host](#supervision-host-configsupervision-host) beside a Claude primary, because the host's park is the primary's idle episode.
A home with the host switched off (`config/supervision-host-off`) opts in to the same compaction with `no-host=1`: the Claude Stop hook's park then does what the host does for the primary, and the engine conversation does not exist there.

The file may be empty or hold these lines, each optional:

- `idle-seconds=<n>` is the idle time before a session is due (default 2700).
- `min-context-tokens=<n>` is the context size below which a session is never due (default 80000).
- `no-host=1` lets the Stop hook's park compact the primary on a home that runs no supervision host (default: off, so the plain file changes nothing there).

Blank lines and lines that start with `#` are ignored, and an unusable value keeps its default.
Context size is the last request's `input + cache_read + cache_creation` usage in the session's transcript.

A session is compacted when all of these hold:

- The home opted in.
- The session has been idle for `idle-seconds`: the primary since its turn ended (on the `no-host=1` path, since its transcript last changed, because one park can span several captain turns), the engine conversation since its last handled turn.
- Its context is at least `min-context-tokens`.
- It was not already compacted in this idle episode.
  The host remembers a primary compaction for one park.
  On the `no-host=1` path the Stop hook process remembers it for its park.
  It records an engine compaction in the engine record, so a later host does not repeat it.
- For the engine conversation, the next turn would resume it: the same engine, model, and prompt key, and below the rotation limit.
  An abandoned compaction is not recorded, so a later check retries it.
- For the primary, the agent reads idle and the composer reads provably empty.
  A busy agent, a non-empty composer, or an unproven state defers the compaction; nothing is typed.

The `no-host=1` path checks every minute while the hook's park runs, and only while that hook process still owns the watcher claim and no away record exists.
A home with no work under way has no park, so it is never compacted by this path.

The primary receives `/compact` through the backend's verified submit primitive (`fm_backend_send_text_submit`), the one the away-mode daemon injects through.
The engine conversation receives `/compact` as one resumed, bounded headless turn.
A compaction is housekeeping: it adds no wake, outcome, or close line, and it is recorded only in the host's log (the `no-host=1` path records nothing).
A compacted primary still picks up pending wakes and decisions from disk, because a wake is a record the next drain reads, not conversation state.

This feature does not set `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` or any other autocompact setting.
`bin/fm-warm-compact-lib.sh` owns the guards, with coverage in [`tests/fm-warm-compact.test.sh`](../../tests/fm-warm-compact.test.sh) and the opt-in live guard [`tests/fm-warm-compact-herdr-live-e2e.test.sh`](../../tests/fm-warm-compact-herdr-live-e2e.test.sh).

## Watcher backstop timer

`bin/fm-watch-backstop.sh` rings a home's own session when its supervision stays down with nothing inside the session to re-arm it, such as an idle resumed Claude session ([watcher continuity](../watcher-continuity.md#out-of-session-backstop)).
When it cannot ring the session, it raises one wedge-alarm alert per stale episode ([wedge alarm](../wedge-alarm.md)).
Install one user timer per home; no command needs sudo.
The session records its endpoint at session start and on resume, so the timer needs no endpoint configuration.
Run this once from the home's stable code directory, with `FM_HOME` set to the home:

```sh
FM_HOME="$PWD" bin/fm-watch-backstop.sh install
```

On Linux it writes a systemd user service and timer into `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user` and runs `systemctl --user enable --now` on the timer.
On macOS it writes a launchd agent into `$HOME/Library/LaunchAgents` and bootstraps it unless it is already loaded.
The generated files capture the installation shell's `PATH` and the home, and the unit names carry a per-home `<slug>`.
The command is idempotent: running it again leaves unchanged files alone and enables the same timer, so nothing is duplicated. When the code directory or the captured `PATH` has moved, it rewrites the files that differ and reloads the timer (on macOS it boots the agent out and back in). If the scheduler still holds an older copy, for example because an earlier run failed after rewriting the files, a rerun reloads it too.
Session start's bootstrap runs `bin/fm-watch-backstop.sh verify`, which prints one `WATCH_BACKSTOP:` line naming this install command when the home has a recorded endpoint and the scheduler reports its timer as not installed or not enabled.
It never installs anything itself.
`bin/fm-watch-backstop.sh timer-files <linux|darwin> <dir>` writes the same files into another directory without touching a scheduler.
To turn it off and remove its files, run `FM_HOME="$PWD" bin/fm-watch-backstop.sh uninstall`, which touches only this home's own units.
Retiring a second mate runs the same removal for the retired home (`bin/fm-teardown.sh`); an ordinary task cleanup never removes a timer.

## Waiting worker spends no turns (config/wait-no-turns)

The optional local, gitignored `config/wait-no-turns` presence flag opts this home into keeping a waiting worker from spending turns until it is answered.
With it present, ship and scout briefs gain the `# Waiting` section and the foreground no-mistakes drive text, every brief's inbox section keeps the natural-checkpoint check and adds that a waiting worker does not poll or list its inbox because a waiting instruction rings, a pending-reply recovery waits while that mate is actually waiting, meaning its latest status event is a declared pause, a captain hold or an open keyed decision (and escalates once, as a held decision, after `FM_PENDING_REPLY_HOLD_ESCALATE_SECS` of that wait), while a mate that carries open decisions but has reported later work is still reposted once, and a fire-and-forget steer whose doorbell did not land gets one later ring.
With the file absent, generated briefs omit the waiting section and the no-poll inbox line, the drive text backgrounds the call, recovery sends even while the mate is waiting, and a fire-and-forget steer is not owed a retry ring.
The flag is a home-local preference and is not inherited by secondmate homes.
