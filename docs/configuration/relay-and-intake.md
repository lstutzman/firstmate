# Relay and intake

Part of the [configuration reference](../configuration.md).

## Mail plane (.env)

The mail plane (bin/fm-mail.sh) reads unseen IMAP messages and sends one SMTP message.

**Polling and delivery guarantees**

Its `poll` command surfaces each new message as a durable `check: mail <uid>` wake, which is also what the standing received-mail check runs each watcher cycle.
Poll emission is exactly-once-recovering: a published wake always carries a durable journal record, and a poll interrupted before recording its uid is healed from that journal, so inbound mail is never silently missed.

A duplicate wake is possible if the process is killed between the queue append and the journal write and the drain acknowledges that row before the next poll heals it, or under a triple write fault that leaves a queued row with no durable record; neither case drops mail.

**Connection and activation**

IMAP and SMTP use implicit TLS on the default ports 993 and 465 (`IMAP4_SSL` / `SMTP_SSL`).
STARTTLS and port 587 are not supported.

It is off unless the home's gitignored `.env` provides the connection values.
This section is the single owner of the mail-plane configuration schema; for direct invocations, environment values override `.env`, matching the Relay contract.

Required, in the home's gitignored `.env`:

```sh
FM_MAIL_USER=   # IMAP/SMTP login
FM_MAIL_PASS=   # IMAP/SMTP password
FM_IMAP_HOST=   # IMAP server hostname
FM_SMTP_HOST=   # SMTP server hostname
```

`FM_IMAP_PORT` (default 993), `FM_SMTP_PORT` (default 465), `FM_MAIL_TIMEOUT` (default 20 seconds), and `FM_MAIL_POLL_MAX_WAKES` (default 20, valid 1..200) are optional.
The per-poll wake cap bounds the wakes of one `poll` run; header fetches scan a larger bounded window of new unseen uids plus already-surfaced retry-set uids, so a flood or large backlog still makes bounded progress every poll, keeping the durable wake queue bounded without ever dropping mail.

**Unfetchable headers**

A message whose header cannot be fetched is surfaced with a degraded summary instead of being skipped, so it is never missed and cannot block later mail.
A later poll retries that fetch and, on success, surfaces the real sender and subject; a persistently unfetchable message stays degraded without repeating that wake.

**Arm unattended polling**

A home that wants mail polled unattended arms the standing check in the live home: `bin/fm-mail-check.sh arm`.
Arming writes `state/mail.check.sh` and registers it with the watcher's slow-check cadence (`FM_CHECK_INTERVAL`), so the plane's `poll` runs on its own: new mail still surfaces as `check: mail <uid>` wakes from the poll, and the standing check itself also prints a line (and the watcher turns that line into a wake) unless the poll is a proven no-op.

Same-line silence is only for a proven no-op: a successful poll with no new mail, or a repeated identical pre-wake failure that cannot have queued mail.
A fail-closed poll that already queued a wake, and a timeout, always print so the watcher wakes to drain it.

`FM_MAIL_CHECK_BUDGET` (default 15, valid 5..25) bounds one standing poll and is cut down to fit `FM_CHECK_TIMEOUT`.
`bin/fm-mail-check.sh disarm` removes the standing check.

## Relay (.env)

Relay lets a firstmate instance answer public mentions and act on normal reversible mention requests through firstmate's normal lifecycle.
It covers both public surfaces the relay supports: `@myfirstmate` mentions on X, and mentions of the myfirstmate bot in a Discord server where it is installed.

Both surfaces are the same opt-in and the same machinery - one pairing token, one relay poll, and one reply path - so everything below applies to Discord mentions unless a line names a platform explicitly.

**Activation, consent, and routing**

It is off unless the firstmate home's gitignored `.env` contains a non-empty `FMX_PAIRING_TOKEN`.
The pairing token both identifies the relay tenant and records opt-in consent for autonomous public replies and eligible lifecycle actions.

Destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner/captain, while its surrounding conversation context may still include other public accounts.

**Endpoint and environment overrides**

`FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`, mainly for developers pointing at a local relay.
For direct client invocations, environment values override `.env`; bootstrap activation still keys off `.env` presence so watcher artifacts are explicit local opt-in state.

`FMX_ENV_FILE` can point direct poll/reply client invocations at another `.env`-style file, but it does not change bootstrap activation.

To turn it on:

1. Sign in at [myfirstmate.io](https://myfirstmate.io) with X or Discord.
2. For the Discord surface, use the dashboard's install link to add the myfirstmate bot to a server you administer; the X surface needs no install step.

3. Copy the pairing token from the dashboard into this firstmate home's gitignored `.env` as `FMX_PAIRING_TOKEN=<token>`.
4. Start a new firstmate session so bootstrap picks the token up, then mention `@myfirstmate` on X or mention the bot in a server where it is installed.

The dashboard owns account creation, identity linking, bot installation, and token issuance; this document owns only what the local firstmate home does with the token once it is in `.env`.

**Generated state and watcher cadence**

The locked session-start bootstrap step turns the token into local generated state.
It writes `state/x-watch.check.sh`, a byte-static identity shim for `bin/fm-x-poll.sh`, and `config/x-mode.env`, which exports `FM_CHECK_INTERVAL=30` for watcher processes in that home.
Independent home-local watcher overrides belong in `config/watch.env` as exported shell assignments; `bin/fm-watch-arm.sh` loads it before `config/x-mode.env`, so Relay retains its required cadence and bootstrap never removes non-Relay tuning. Only watchers started through that arm read it: the Codex checkpoint route (`bin/fm-watch-checkpoint.sh` with no `config/supervision-host`) and the away-mode daemon (`bin/fm-supervise-daemon.sh`) start `bin/fm-watch.sh` directly and use the watcher defaults.

The watcher accepts the shim only when its bytes match the expected generated content, then invokes the trusted repository poll script directly instead of executing state-file source.
This section owns the Relay cadence contract:

- A Relay instance polls every 30 seconds instead of the default 300.
- A non-Relay home has no `config/x-mode.env`, so Relay does not change its cadence; it may still opt into watcher tuning through `config/watch.env`.
- When that file exists, the session-start supervision operating block includes the cadence instruction.

The active primary-harness supervision protocol owns how that sourced cadence reaches the watcher process.

**Apply cadence changes**

Because `bin/fm-watch.sh` reads `FM_CHECK_INTERVAL` only at process start, a cadence transition - opt-in while a watcher is already running, or opt-out - is applied by restarting the home-scoped watcher through the emitted harness protocol; bootstrap deliberately never restarts the watcher itself.
While a legacy daemon flag is active the daemon owns the watcher and its default cadence applies; on Pi the away-posture record alone leaves the ordinary Relay watcher cadence active, and daemon-backed Relay cadence remains a deferred follow-up.

When the token is removed or empty, the next locked session-start bootstrap step removes those artifacts.
Steady-state off is silent and writes nothing.

Relay remains additive to non-Relay lifecycle behavior: homes without the generated artifacts keep the default watcher cadence and do not run the Relay poll.
Its request handling remains in Relay-specific `bin/` scripts and the `fmx-respond` skill, while the watcher owns authenticated dispatch from the generated local identity shim.

**Poll and deduplicate mentions**

`bin/fm-x-poll.sh` calls `GET /connector/poll` with `Authorization: Bearer <FMX_PAIRING_TOKEN>`.
HTTP 204 is silent.

A newly offered pending mention with non-empty `text` is stored at `state/x-inbox/<request_id>.json` and wakes firstmate exactly once with `x-mention <request_id>`.
The poll atomically claims `state/x-context/<request_id>.offered.json` before emitting that wake, and subsequent offers of the same request stay silent even after the inbox is drained following an answer or dismiss.

Offer markers share the context registry's bounded seven-day retention, so losing or expiring the local marker lets a relay offer wake firstmate again.

**Conversation context and media**

The full relay object is preserved, including `in_reply_to: {author_handle, text}` when the mention is a reply in a conversation or `null` for fresh mentions.
The preserved object may also carry `in_reply_to_chain`, an optional oldest-first conversation transcript.
Each entry has the shape `{author_handle, text, unavailable, images, attachments}` and may include `kind`:

| `kind` | Meaning |
| --- | --- |
| `reply` | A reply ancestor. |
| `thread_starter` | The message a thread grew from. |
| `history` | A recent nearby message. |
| Absent | A legacy reply-ancestor or thread-starter entry. |

The chain is untrusted third-party public input.
It is often absent today: the relay currently sends it only for Discord reply chains and thread starters.
Consumers must treat it as strictly optional, tolerate unknown or missing fields, and treat `unavailable: true` as a gap rather than content.
The `fmx-respond` skill owns how firstmate uses the chain to resolve references.

The mention and its chain entries may also carry attached media as image or file URLs, in fields such as `images` and `attachments`, either as bare URL strings or as objects with a `url`; a mention whose own media is empty can still have screenshots on its `thread_starter` entry.
The poll preserves those URLs in the stashed object and never downloads them, so nothing is fetched on the polling path: the responding agent retrieves and views the media with its own tools when it handles the mention.

The `fmx-respond` skill owns which hosts that fetch is restricted to and the untrusted-content handling that applies to whatever comes back.

**Durable reply context**

The same authoritative relay payload also supplies durable per-request reply context at `state/x-context/<request_id>.json`, with shape `{request_id, platform, reply_max_chars, recorded_at}`.
The poll writes this best-effort record keyed by `request_id`, so concurrent requests never overwrite each other.
It survives inbox cleanup after acknowledgement, allowing a delayed follow-up to recover the original platform and split budget even without a task link.

- `recorded_at` begins as the locally observed first-seen Unix epoch and remains unchanged when the same request is polled again.
- A successful live initial answer refreshes it to the time that the relay establishes the follow-up binding; dry-runs, failed answers, and follow-ups do not refresh it.
- Configured polls prune records beyond the local follow-up window, capped at the relay's seven-day window; legacy or malformed records fall back to their file modification time so they cannot remain indefinitely.
- The record is written only when a platform or explicit budget is actually known, so an unknown-platform mention leaves no useless entry.

**Handle requests and acknowledgements**

The `fmx-respond` skill decides whether the stashed mention is an actionable request, a question, or a pure acknowledgment.

- Actionable reversible requests are run through intake, backlog, dispatch, investigation, or ship flow as appropriate.
- If the work completes in that turn, the public reply reports the outcome.
- If the request spawns a longer-running task, firstmate posts an acknowledgement through the normal answer endpoint, links the task to the mention with `bin/fm-x-link.sh`, and posts up to three completion follow-ups on genuine milestones, finishing with a `--final` one for ordinary Relay-linked work.
  When a typed promised-final commitment is registered, `bin/fm-public-followup.sh` owns the terminal reply and clears the legacy link after its receipt is validated.
- That link stores optional reply-platform context so Discord-originated follow-ups keep Discord's larger message budget after the inbox file has been drained.

**Resolve the reply platform and budget**

Platform/budget resolution is layered and independent of the task link: a per-axis `FMX_REPLY_PLATFORM` / `FMX_REPLY_MAX_CHARS` override (how `bin/fm-x-followup.sh` passes a recorded link's context) wins.
For either axis without an override, `bin/fm-x-lib.sh:fmx_resolve_reply_context` consults these sources in order:

1. The durable per-request registry.
2. The still-present inbox payload.
3. For a follow-up posted live by request_id only, an authoritative relay lookup through `POST /connector/request-context`: `{request_id}` in, `{platform, reply_max_chars}` back.

This is what keeps a delayed request-id follow-up on the original platform's budget even after the inbox is drained and with no task link surviving; the relay step is confined to the live follow-up path so the answer path and every dry-run stay network-free.

**Link tasks and handle missing context**

The link lives in the current home's `state/<task-id>.meta`.
Work routed to a secondmate has no record here, so `bin/fm-x-link.sh` refuses to link it.
When possible, the refusal names the registered secondmate home containing the task.

It also points to `bin/fm-public-followup.sh register ... --work-home secondmate:<id>`.
This promised-final path is the only follow-up mechanism that binds work in another home.
`bin/fm-x-link.sh` uses the same order when recording a fresh link's context and requires `jq`.
Its request-context lookup is best-effort.
Any of these conditions leaves the context unknown:

- No token or `curl`.
- A non-2xx response.
- An unresolved response.
- A relay version without that endpoint.

The link is still recorded, but `bin/fm-x-link.sh` prints a loud warning.
If either the follow-up platform or explicit budget cannot be authoritatively resolved from any source, `bin/fm-x-reply.sh` refuses with fail-safe exit 8.
Firstmate holds the follow-up and retries once both values are recoverable; it never posts with a local default.

**Carry a link to a successor task**

Fresh links start with `x_followups=0` and the current timestamp; when relinking the same relay request onto a successor task, pass paired `--carry-count <n> --carry-ts <epoch>` flags plus any prior `x_platform=` and `x_reply_max_chars=` as `--carry-platform <x|discord> --carry-max <n>` so the successor preserves the already-consumed follow-up count, original 7-day window, and reply split budget.

**Dismiss mentions**

Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh` before the local inbox file is cleared.
Dismiss sends `POST /connector/dismiss` with `{request_id}`, posts no text, and tells the relay to drop the request instead of re-offering it or falling back to an offline auto-reply; on success it clears that request's durable reply-context record, while the separate offer marker remains for its bounded retention so a brief relay re-offer stays silent.

**Poll errors**

Relay auth or config problems are reported once as `x-mode-error ...` until recovery.
A failed durable offer claim is likewise reported once as `x-mode-error cannot record mention offer` and remains deduplicated through quiet no-pending polls until a later offer confirms an existing valid marker or claims a new one.

**Post replies and follow-ups**

Live replies are posted by `bin/fm-x-reply.sh`, which sends `POST /connector/answer` with `{request_id,text}` for one-message replies.
Add `--image <path>` to attach one local PNG, JPEG, GIF, WebP, BMP, or TIFF as `{media_type,data_base64}` in the relay's optional `image` object.

Completion follow-ups use `bin/fm-x-followup.sh`, which checks the local `state/<id>.meta` link and sends the same payload shape through `POST /connector/followup` by calling `bin/fm-x-reply.sh --followup`, up to three times per link within the window.
Add `--image <path>` there too when a completion follow-up should carry an image.

**Follow-up success, expiry, and retry**

- A successful post increments the local `x_followups=` counter and keeps the link, unless `--final` was passed or the new count reaches the cap, in which case the link is cleared instead; a failed post leaves the link and counter untouched so it can be retried.
- The relay itself rejects a follow-up past its own cap or window with HTTP 409 and may include `{"error":"followup_unavailable"}` in the response body; the client surfaces any follow-up 409 as a distinguishable exit code and uses the body marker only for a sharper diagnostic.
- `fm-x-followup.sh` treats that exit exactly like a locally-detected expiry - clearing the link and skipping quietly rather than retrying - so an older single-follow-up relay or an already-exhausted binding degrades gracefully.
- It treats `fm-x-reply.sh`'s fail-safe refusal (exit 8: platform or explicit budget unresolved) differently: that is a retryable hold, so the link is KEPT and the follow-up is retried once both values can be recovered, never posted with a local default.
- Past-window relay rejections are only guaranteed while the expired binding row still exists on the relay side; after its cleanup sweep, a very-late follow-up call may instead see a benign no-op 200, which is why the local window and cap pruning remains the primary guard.

**Split replies by platform**

- Reply splitting is platform-aware: an explicit relay platform field (`reply_platform`, `platform`, `target_platform`, `source_platform`, or `provider`) wins, otherwise a legacy `tweet_id` beginning with `discord:` selects Discord and a numeric `tweet_id` selects X.
- An explicit relay limit field (`reply_max_chars`, `reply_max_characters`, `message_max_chars`, `message_limit`, or `max_chars`) wins over the platform defaults.
- If the reply exceeds the selected budget, the client splits it into a numbered thread on fenced-code, paragraph, line, and word boundaries and sends `{request_id,text,texts}`, where `texts` is the ordered chunk list and `text` remains the first chunk for older relays.
- When `--image <path>` is present on a split reply, the image rides the first/opener message and later chunks stay text-only.

**Reply and follow-up limits**

| Setting | Default | Limit or behavior |
| --- | --- | --- |
| `FMX_X_REPLY_MAX_CHARS` | 280 | Clamps to a minimum of 50. |
| `FMX_DISCORD_REPLY_MAX_CHARS` | 1900 | Clamps to a minimum of 50; values above Discord's 2000-character limit reset to 1900. |
| `FMX_X_THREAD_MAX` | 25 | Caps oversized reply threads on every platform; truncation marks the last retained message with an ellipsis. |
| `FMX_FOLLOWUP_MAX_AGE_SECS` | 604800 (7 days) | Local completion follow-up window. |
| `FMX_FOLLOWUP_MAX_COUNT` | 3 | Local follow-up cap. |

**Preview with dry-run**

Set `FMX_DRY_RUN` to preview replies and dismissals without posting.
Truthy means anything except unset, empty, `0`, `false`, `no`, or `off`; an explicit environment value wins over `.env`.

- In dry-run, `fm-x-reply.sh` records the would-be payload to `state/x-outbox/<request_id>.json`, including `texts` for a thread and an `endpoint` marker for follow-up previews, prints a `DRY RUN` summary to stderr, echoes the `request_id`, and exits 0.
- When an image is attached, the dry-run record uses compact `{media_type, bytes, source_path}` metadata instead of writing the base64 bytes.
- In dry-run, `fm-x-dismiss.sh` records `{request_id, endpoint:"dismiss"}` to the same outbox path, prints a `DRY RUN` summary, echoes the `request_id`, and exits 0.
- The live answer and follow-up bodies intentionally stay the same shape, including optional `image`; the relay distinguishes them by endpoint, and dismiss stays `{request_id}`.
- These paths need `jq` to build the JSON payload, but they run before token and network checks, so they need neither `FMX_PAIRING_TOKEN` nor `curl`.

### Promised public replies (state/public-followup)

A relay request that spawns real work can leave firstmate owing a specific public reply in a specific thread.
That promise is a typed `kind=public-followup` obligation whose state machine is owned entirely by `tasks-axi public-followup`, while the full private conversation context stays only in `state/x-context/`.

Firstmate's bounded registration retains the obligation's public-safe request binding so a delivered loop can be rechained without the original inbox.
`bin/fm-public-followup.sh` is firstmate's side: it registers a commitment, reconciles typed terminal work results into it, posts the final reply through `bin/fm-x-reply.sh --followup`, and explicitly rechains or retires the retained loop.

Run `bin/fm-public-followup.sh --help` for the exact subcommands and flags.

**Private transport records**

Registration creates this home's private transport under `state/public-followup/` with mode 0700:

| Entry | Purpose and retention |
| --- | --- |
| `registry/` | Bounded private binding for each open public loop; survives delivery with `state=delivered`; only `retire` removes it. |
| `events/` | Typed terminal results awaiting reconciliation. |
| `consumed/` | Accepted-event ledger. |
| `rejected/` | Refusals retained with a one-line reason. |
| `rejection-wakes/` | Each refusal's not-yet-raised wake. |
| `retired/` | Mode-0600 reason-and-time receipt written before removal. |
| `surfaced` | The poll's last-surfaced signature. |
| `outbox/` | Also created in a work home that reports across a machine boundary; described below. |

**Which home posts the reply**

The home that owns the commitment also owns the outward post, because only it holds the relay consent, the request context, and the opaque thread binding.
Work routed elsewhere reports a typed terminal result with `bin/fm-public-followup-emit.sh` and never looks for the thread; when writing directly into the owning home, that emitter refuses a home with no registration for the named obligation.

**Prepare and validate terminal results**

`bin/fm-public-followup.sh brief` pre-fills every deliverable value the binding determines, such as `report_path=data/<work-id>/report.md`, and states the accepted format of every value it cannot know.

- The emitter validates deliverable values and known required keys before publishing, including the relative `report_path` format, and names correctable mistakes at the work home.
- A direct emit reads the obligation from `tasks-axi`; a staged emit cannot read that remote record, so `brief` supplies its required keys in the printed command.
- If those flags are omitted from a staged command, it still checks values but cannot detect missing keys until the owning home's `consume` rejects the event and queues a rejection wake.
- The [emitter header](../../bin/fm-public-followup-emit.sh) and its `--help` own the exact flags and outcome-dependent validation rules.

**Clear legacy links in remote homes**

When that work lives in a REMOTE secondmate home, delivery clears its bound legacy link after validating the public receipt, while retirement clears the link before closing the loop, and both clears run over that route's SSH transport.
Readable remote state proving that no link exists succeeds without a write.
A present link is cleared only when its Relay request identity matches the registration and the state is writable.
Any of these conditions retains the loop for reconciliation:

- An identity mismatch.
- Unreadable or unsafe state.
- An unavailable write or lock.
- An older remote copy.
- A host that never confirms the clear.

**Duplicate and failed results**

A terminal event's id is derived from its identity tuple, so a duplicate report, a retry, or a replay after restart resolves to the same event and changes nothing.
When bound work ends failed or parked, its typed failed result remains deliverable even when the promised final expected a merged pull request, so the owed reply carries the honest failure instead of remaining stranded.

**Collect results across machines**

Work bound to a REMOTE secondmate home reports across a machine boundary, where no local path reaches the owning home.

- `bin/fm-public-followup.sh brief` therefore prints that worker the route's own code root and home with `--stage-in`, so the typed result is staged in `outbox/` in the home where the work actually runs rather than written to a path that only exists on the owning machine.
- The owning home collects staged results for open registrations over the same SSH route it reaches that secondmate on, because that transport only runs in the outbound direction: `consume` pulls them into its own `events/` and then reconciles them exactly as it reconciles a local report.
- Non-open registrations owe no result, so `consume` skips them without contacting their routes; an open registration whose reachable route has nothing staged remains pending without an error.
- Collection is non-destructive until the result is durably held, and the staged copy is retired only afterwards, so a dropped connection can never lose a terminal result.
- For an open registration, a work home that cannot be reached is named in `consume`'s output and keeps the promise open; it is never reported as an empty inbox.

Run `bin/fm-public-followup-collect.sh --help` for the staged-result commands the owning home runs over that route.

**Activation and idle cost**

Activation is the same `.env` `FMX_PAIRING_TOKEN` contract as the rest of Relay, with no second flag.

- A home without that token runs one file test and stops: no `tasks-axi` call, no backlog or request-context scan, and no `state/public-followup/` directory.
- Ordinary startup, polling, cleanup, and silent read-side subcommands also produce no output; commands that require an active relay report that configuration error after the same gate.
- A relay-enabled home with no registered commitment stops at an O(1) directory presence check, so the empty state costs no CLI call and adds no periodic scan.

**Wake on new or rejected results**

Unreconciled terminal results ride the existing 30-second relay poll rather than a new process or timer: `bin/fm-x-poll.sh` compares the pending-event signature against `surfaced` and wakes firstmate once per new result set.

- A terminal event `tasks-axi` refuses during `consume` is quarantined with a reason naming the specific deliverable, outcome, or missing key where one is identifiable, and the same poll wakes the owning home with a `public-followup rejected <event-id> ...` line carrying that reason.
- The refused event stays pending until that wake is recorded, and a queued wake survives a failed read or write to poll output.
- That makes the wake at-least-once rather than exactly-once: a cleanup that fails after the line was already raised - a wake directory that cannot be written, or a refused event that could not be drained - raises the same refusal again on a later poll.
- A repeat carries the same event id and the same reason as the quarantined rejection, which is how an already-handled refusal is recognized.
- Acknowledge it without re-acting; re-emitting an already accepted corrected result is harmless but redundant because its derived event id is already in the accepted ledger.

**Startup, teardown, and retries**

The session-start digest separately prints a "Public commitments" subsection from disk when, and only when, this home is relay-active and still holds an open public loop (a reply still owed, or a delivered loop with nothing owed), so compaction and restart are non-events.
`bin/fm-teardown.sh` refuses to clean up a task while this home still owes a public reply for exactly that work, unless `--force` carries explicit discard approval.

`FM_PF_RETRY_BACKOFF_SECS` (default 900) sets the next-attempt time recorded with a retryable delivery error.
See [verification/public-followup.md](../verification/public-followup.md) for the current maintainer evidence behind restart recovery, failed terminal outcomes, retained-loop disposition, and the relay-disabled zero-overhead guarantee.

## Machine-service intake (state/inbox)

A local service submits one JSON object on standard input to `FM_HOME=<home> bin/fm-inbox.sh service`.
This extends the existing inbox rather than creating another spool or operational prompt kind.
The object has these fields:

| Field | Required value |
| --- | --- |
| `kind` | `dispatch`, `notice`, or `blocked`. |
| `source` | Service identifier. |
| `item_id` | Work-item identifier, such as `PC-3385`. |
| `severity` | `info`, `low`, `medium`, `high`, or `critical`. |
| `evidence_path` | Absolute local path of at most 1024 printable ASCII characters, retained without reading the file. |
| `request_id` | Identifier unique across this home's machine-service requests, including different sources and kinds. |
| `key` | Optional problem key for upward relay. |
| `summary` | Optional non-secret description of at most 200 printable characters on one line, such as the finding category, rule ID, and file path, and whether the sender started work. |

Identifiers and keys contain 1-96 characters: an initial ASCII letter or digit, followed by ASCII letters, digits, `.`, `_`, or `-`.
Every value is a string; unknown fields, duplicate fields, invalid values, a summary containing newlines or control characters, and objects longer than 8192 characters are refused before saving.
Never include secret values, credentials, matched secret text, or evidence contents in any field, including the summary, a filename, or an identifier.
The submitting service is responsible for that restriction; field validation does not detect secrets.
This is a local trusted-producer interface, not an authenticated remote API or a grant of dispatch authority.

The command saves a canonical JSON body in the home's existing `state/inbox/<id>.note`, identified by `source=machine-service` and `service_schema=fm-inbox-service.v1` headers.
The existing inbox receipt, reservation, and announcement mechanisms apply; service reservations use the reserved `service:` prefix, which ordinary `note --request-id` submissions refuse.
The first saved request wins: retrying its `request_id` returns the original record without changing its body, creating another note, or repeating an announced wake, including after acknowledgment.
Use a new request ID for a different event.
Pending records remain until firstmate acknowledges them through the existing inbox drain; handled records and request reservations remain available for replay detection without automatic expiration.
The watcher repairs saved but unannounced requests and relays pending service messages before surfacing their queued check wake.
The [machine-service handling procedure](../secondmate-parent-channel.md#machine-service-handling) owns dispatch, relay, and acknowledgment duties; `bin/fm-inbox.sh --help` owns command syntax, receipts, and exit conventions.

## Spoken interface and captain inbox (config/voice-*, config/inbox-*)

The spoken interface in [`docs/voice-relay.md`](../voice-relay.md) and the model-backed subcommands of `bin/fm-inbox.sh` reach a paid API in a named account, so no region, model id or AWS profile is shipped as a tracked default.
Each is one line in a local, gitignored `config/` file, with an environment variable that overrides it for a single run, and a missing required value refuses with the path to write rather than falling back to a value that belongs to another home.

That configuration is the whole opt-in: an unconfigured home cannot start the relay and cannot run `fm-inbox.sh say` or `ask`, while `note`, `announce`, `reply`, `receipts`, `ready`, `status`, `list` and `drain` need no configuration at all because they make no model call.
The voice handover depends on `note`, so it keeps working in a home that has configured nothing.

| File | Environment | Holds |
| --- | --- | --- |
| `config/voice-region` | `FM_VOICE_REGION` | Bedrock region for the relay's bidirectional session, required by `bin/fm-voice-relay.py`. |
| `config/voice-model` | `FM_VOICE_MODEL` | Speech-to-speech model id, required by `bin/fm-voice-relay.py`. |
| `config/voice-profile` | `FM_VOICE_PROFILE` | AWS profile the relay exports credentials from; absent, or an explicitly empty variable, means it uses only credentials already in its environment. |
| `config/voice-id` | `FM_VOICE_ID` | Output voice id, optional, `matthew` when unset. |
| `config/voice-read-scope` | none | `counts` (the default, and what an absent file means) or `full`; see [`docs/voice-relay.md`](../voice-relay.md) for what each scope may say. |
| `config/voice-read-deny` | none | One plain case-insensitive substring per line; a matching open item is withheld from every list and reduced to a count. |
| `config/inbox-region` | `FM_INBOX_REGION` | AWS region for `fm-inbox.sh say` and `ask`. |
| `config/inbox-stt-model` | `FM_INBOX_STT_MODEL` | Speech-to-text model id, required by `fm-inbox.sh say`. |
| `config/inbox-ask-model` | `FM_INBOX_ASK_MODEL` | Side-question model id, required by `fm-inbox.sh ask`. |
| `config/inbox-profile` | `FM_INBOX_PROFILE` | AWS profile for those two calls; absent, or an explicitly empty variable, means whatever credentials are already in the environment. |

**How configuration files are parsed**

Each account, model and voice file above is read as its first line that is not blank and not a `#` comment, so a comment above the value is fine.
The two read files use different parsing rules:

- `config/voice-read-scope` must contain only the bare word with optional blank space around it.
  A comment header causes a refusal rather than being skipped.
- In `config/voice-read-deny`, every line that is neither blank nor a `#` comment adds one substring.

`FM_VOICE_RELAY` and `FM_VOICE_PYTHON` belong to the laptop rather than to a home, so they have no config file: `bin/fm-voice-client.py` requires the relay path as a flag or that variable and carries no default path.
