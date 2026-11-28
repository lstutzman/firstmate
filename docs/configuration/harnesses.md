# Harnesses

Part of the [configuration reference](../configuration.md).

## Harness support

claude, codex, opencode, pi, pi-signed, grok, kimi, cursor, and omp are empirically verified for crewmate and secondmate launches; gemini is verified for crewmate and scout launches only, and [README requirements](../../README.md#requirements) own the set supported for the primary session.

### Harness restrictions and credentials

`fm-spawn.sh` refuses kimi on cmux and Orca at preflight, because answering Kimi's folder-trust dialog needs a verified viewport-only capture those backends lack; [its adapter reference](../../.agents/skills/harness-adapters/references/harness/kimi.md#readiness-gated-start) owns the trust-dialog handling.
It also never answers a Kimi folder prompt that announces project MCP servers, pages what trusting would activate, or is collapsed for a short terminal, so no project MCP server starts without a consent decision that covers it; the launch fails with that reason, and the same adapter reference owns the exact rules.
A cursor secondmate or primary runs the tracked project-scope `.cursor/hooks.json` in its own home and must be launched with `--trust`, or no project hook loads; [`docs/supervision-protocols/cursor.md`](../supervision-protocols/cursor.md) owns its supervision protocol.

Cursor typed-submit confirmation is verified on tmux and Herdr only.
On Zellij, cmux, Orca, Paseo, and tern a typed-plane Cursor send (a harness-native invocation or an explicit backend target; ordinary text steers ride the durable inbox and exit 0 at enqueue) lands, but `fm-send` reports delivery unconfirmed and exits non-zero because their shared submit core does not consult the busy footer; [runtime backend verification](../verification/runtime-backends.md#cursor-agent-cli) owns the evidence and transcript-state boundary.

### Safety-hook capability

`fm-spawn.sh` refuses a ship task on a harness that has no wired safety hooks (the deletion, secret, push, and gate guards), because the fleet rules limit such a harness to a read-only scout; the refusal names a hooked harness, and a scout or secondmate spawn is never refused by this rule.
[`bin/fm-harness-safety-lib.sh`](../../bin/fm-harness-safety-lib.sh) owns the built-in table: claude, codex, and agy are hooked, pi, pi-signed, omp, and kimi are not, and every other harness defaults to not hooked until a harness reference records its guards.
A home states its own answers in `config/harness-safety-hooks`, one `<harness|*> yes|no` line each, where blank lines and `#` comments are ignored and the last matching line wins.

muse is verified for crewmate and scout launches ONLY, and `fm-spawn.sh` refuses it for a secondmate, because muse ships no usable hook surface for a primary session's turn-end supervision; [`docs/verification/muse.md`](../verification/muse.md) owns that evidence.
muse also needs a worker-reachable credential before spawning, and the portable fleet path is the `<config>/muse/auth.json` credential stored by `muse login`, because a caller-only `META_API_KEY` does not cross a long-lived backend daemon.

gemini is likewise refused for secondmates because it has no primary supervision protocol; [its adapter reference](../../.agents/skills/harness-adapters/references/harness/gemini.md) owns the credential precondition, canonical-launch wiring, and raw-launch limitations.
rovo is likewise verified for crewmate and scout launches ONLY, refused for a secondmate for the same reason - no turn-end hook and no primary supervision protocol; [`docs/verification/rovo.md`](../verification/rovo.md) owns that evidence, including the OAuth token's silent background refresh from a stored refresh token and both tmux and herdr pane liveness (herdr placement is verified live, with a Herdr-side agent-detection gap left open for recovery classification).

An agy secondmate or primary runs the tracked project-scope `.agents/hooks.json` in its own home, and `bin/fm-spawn.sh` pre-registers a secondmate home in agy's workspace trust store through `bin/fm-agy-trust.sh`; [`docs/supervision-protocols/agy.md`](../supervision-protocols/agy.md) owns its supervision protocol and [`docs/verification/agy.md`](../verification/agy.md) owns the evidence.
kiro (Kiro CLI, V2 engine only) is likewise verified for crewmate and scout launches ONLY, refused for a secondmate because it has no primary supervision protocol; it is claude-shaped, so its per-task turn-end and busy hooks live in a firstmate-owned agent config the spawn writes under `state/<id>.kiro-home` and reaches by relocating `KIRO_HOME` (never the worktree's own `.kiro/`), with the `--trust-all-tools` modal suppressed by a seeded `chat.disableTrustAllConfirmation` setting; [`docs/verification/kiro.md`](../verification/kiro.md) owns that evidence, and the v3/KAS engine is out of scope and unsupported on Amazon Linux 2.
A kiro hook command must be one unquoted token, so a kiro spawn refuses before launch when that per-task home path contains whitespace or a shell-special character (such as a quote or `$`) and asks for an `FM_HOME` or `FM_STATE_OVERRIDE` free of them.

devin is verified for crewmate and scout launches only; a secondmate is refused because Devin has no verified primary supervision protocol.

Its private worker config disables Claude Code imports (including the captain's hooks) and, unless the home sets `config/keep-ai-trailers` (see "Commit attribution"), Devin commit attribution without editing user or project config; [`fm-devin-config.sh`](../../bin/fm-devin-config.sh) owns these enforced settings and [Devin verification](../verification/devin.md) owns the live evidence and observed model availability.

cortex (Snowflake's Cortex Code) is likewise verified for crewmate and scout launches only; a secondmate is refused because Cortex has no verified primary supervision protocol.
It runs only on the tmux and Herdr backends; a zellij, cmux, orca, paseo, rex, or t3code launch is refused because those backends supply no Cortex pane identity to prove its titled composer empty.
Its busy-state and turn-end hooks reach the worker through a private per-task plugin directory passed with `--plugin-dir`, so no user or project Cortex or Claude config is edited; [`fm-cortex-plugin.sh`](../../bin/fm-cortex-plugin.sh) owns it and teardown removes it.
The launch clears `CLAUDECODE` so Herdr's Claude integration hook cannot claim the pane, and it uses `--dangerously-allow-all-tool-calls`, which also skips the project trust dialog without recording the project in Cortex's trust file.
Cortex loads Claude-compatible hook files with no switch to disable the import, so a worker in a project with Claude hooks runs them.
[Cortex verification](../verification/cortex.md) owns the live evidence, the Herdr pane-claim behavior, and the unverified items.
commandcode (Command Code) is verified for crewmate and scout launches only; a secondmate is refused because Command Code has no verified primary supervision protocol.
It runs only on the tmux and Herdr backends; a zellij, cmux, orca, paseo, or tern launch is refused because those backends supply no Command Code pane identity, without which its idle composer placeholder never reads empty and steering stalls, and a rex launch is refused until Command Code is live-verified there.
Its busy-state wiring is a tracked mod loaded per process with `--mod`, so no user or project Command Code settings are edited; [its adapter reference](../../.agents/skills/harness-adapters/references/harness/commandcode.md) owns the launch facts and [Command Code verification](../verification/commandcode.md) owns the live evidence.

Hermes Agent is verified for crewmate and scout TUI launches on tmux only; primary and secondmate use and other backends are refused.
Its native profile selects the model and reasoning, and the profile's own gateway may run only if it is idle at dispatch.
The [Hermes adapter reference](../../.agents/skills/harness-adapters/references/harness/hermes.md) owns operating limits, [`fm-spawn.sh`](../../bin/fm-spawn.sh)'s header owns the per-spawn profile flag, and [Hermes verification](../verification/hermes.md) owns live evidence.

Polytoken is verified for crewmate and scout launches only; [its adapter reference](../../.agents/skills/harness-adapters/references/harness/polytoken.md) owns the operating contract and [verification record](../verification/polytoken.md) owns the live evidence.
It has no primary or secondmate supervision protocol.
The launch generates a private per-task config directory that mirrors the operator's provider/model configuration and enforces unattended permissions without modifying global configuration.
The first-start license dialog requires an operator decision and is never accepted automatically.

### Verification and primary supervision

New harnesses get verified through a supervised trial task before joining the set.
The verified adapter evidence - each harness's busy-state source, interrupt and exit behavior, skill-invocation syntax, and per-harness quirks - lives in the skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md).

The executable interrupt and exit mechanics live in [`bin/fm-control-lib.sh`](../../bin/fm-control-lib.sh), and [`docs/agent-control.md`](../agent-control.md) owns their lifecycle-control architecture.
Launch mechanics, including the verified command templates, live in [`bin/fm-spawn.sh`](../../bin/fm-spawn.sh).
A Claude worker's launch brief is published as an operational record in the receiving home's state and delivered as a printable doorbell; if publication fails, the spawn reports the failure and launches nothing rather than sending a marker that Claude Code would strip.
Other harnesses retain the typed operational-marker launch path.

Pi-family launches adapt the regular-TUI safeguard to the installed CLI's capabilities; [`fm-spawn.sh --help`](../../bin/fm-spawn.sh) owns the exact version-safe launch mechanics.
Enabled primary-session turn-end guard integrations are tracked as repo-level hook files and documented in [`docs/turnend-guard.md`](../turnend-guard.md).

Kimi remains outside the primary turn-end guard integrations; [`docs/turnend-guard.md`](../turnend-guard.md#compatibility-limits) owns its separate captain-approved crew wake hook.
Primary-session watcher wake protocols are rendered at session start by [`bin/fm-supervision-instructions.sh`](../../bin/fm-supervision-instructions.sh) from [`docs/supervision-protocols/`](../supervision-protocols/).

Claude uses [hook-owned tokenless re-arm cycles](../watcher-continuity.md#claude-stop-hook), Cursor's stop hook parks on the watcher, Grok uses background-notify cycles, Codex selects its mode under the [native Stop park policy](supervision.md#codex-native-stop-park-configcodex-stop-park), Pi and pi-signed use the same two tracked primary extensions, omp uses its own two tracked `.omp/extensions/` files with a blocking `session_stop` turn-end hook, and OpenCode uses its TUI plugin.

### Choose the worker harness

`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches.
When pi-signed is selected, Firstmate preserves `FM_PI_HARNESS=pi-signed` and refuses the launch if the selected executable is unavailable rather than falling back to pi; [`fm-spawn.sh --help`](../../bin/fm-spawn.sh) owns executable resolution and launch mechanics.

Plain Pi launches set `FM_PI_HARNESS=pi`, so a signed primary's environment cannot relabel a plain Pi worker.
When it is absent or contains `default`, crewmates mirror the firstmate's own harness.

### Choose the secondmate harness

`config/secondmate-harness` is a separate local, gitignored file containing the adapter the primary uses to launch secondmate agents, optionally followed by model and effort tokens on the same line. The file belongs to the primary, is not inherited by secondmate homes, and secondmates do not launch secondmates.
Without a `mate <secondmate-id>:` declaration, the first non-empty, non-comment line supplies the default, parsed as `<harness> [<model>] [<effort>]`; later lines and additional tokens retain their legacy ignored behavior.
With an override declaration, at most one non-empty, non-comment line without that prefix supplies the default.
Any number of override lines can pin named secondmates rather than the whole home:

```text
mate <secondmate-id>: <harness> [<model>] [<effort>]
```

Override ids use letters, digits, dots, underscores, and hyphens, and matching is case-sensitive.
A mate line replaces the default line for that exact secondmate id, so raising the default pin cannot migrate a mate the captain pinned separately.
Precedence is the override for that mate's id, then the default line, then `config/crew-harness`, then the primary's own harness.
An override whose harness token is `default` skips the file's default line and falls back to `config/crew-harness`, then the primary's own harness, contributing no model or effort.
Blank lines and `#` comments stay legal anywhere, and a mate line is honored wherever it sits in the file.
In a file that declares an override, a second default line, two overrides for one id, an override with no tokens or more than three, or a `mate` keyword naming an invalid secondmate id is an actionable error: resolution exits nonzero naming the file's line number and prints no token, so malformed pin config cannot resolve to a fallback in silence.
In a file that declares no override, none of that applies: the legacy first-line rule governs, so an existing, already-valid file is read exactly as it was before this grammar existed.

A bare `<harness>` preserves the previous behavior: harness only, with no model or effort launch flag.
When the harness token is absent or `default`, secondmate launch falls back through `config/crew-harness` and then the primary's own harness, and no model or effort is read from that file.

[`fm-harness.sh`](../../bin/fm-harness.sh)'s header owns the resolver commands and optional secondmate-id argument.
Without an id they select the default line only; model and effort output is empty when no token applies.
When the file declares an override, every resolver read validates the whole file, even when no id is supplied or the malformed line concerns another mate.
Every resolution site that knows which mate it is launching passes that id, so spawn, control-plane relaunch, and secondmate restart all land on one decision.
`config/crew-harness` remains a bare adapter-name file and is never parsed for a model.
Changing this pin affects the next secondmate spawn or control-plane relaunch; the relaunch profile rules are owned by [`docs/agent-control.md`](../agent-control.md#transactional-relaunch).
For a separate account choice for one local secondmate, see [per-secondmate account pins](worker-launch.md#per-secondmate-account-pins).
The regression coverage is in [`fm-secondmate-harness.test.sh`](../../tests/fm-secondmate-harness.test.sh), [`fm-control-relaunch.test.sh`](../../tests/fm-control-relaunch.test.sh), and [`fm-secondmate-restart.test.sh`](../../tests/fm-secondmate-restart.test.sh).

### Per-launch overrides and inherited defaults

An explicit harness argument to `fm-spawn.sh` still overrides either config file for that spawn only.
An explicit `--model` or `--effort` overrides the matching token from `config/secondmate-harness`; for a local route, an explicit harness or raw launch command starts with clean model and effort defaults unless those flags are also passed.
An explicit harness also bypasses reading the pin file during spawn or control-plane relaunch, so malformed unused pin configuration cannot block that override. A relaunch supplying explicit `--harness`, `--model`, and `--effort` therefore does not read this configuration.

Remote secondmate routes accept verified harness adapters only and reject raw launch commands.
When `config/crew-dispatch.json` exists, crewmate and scout spawns require an explicit resolved harness instead of automatically falling back to `config/crew-harness`.
Such a spawn also refuses until `bin/fm-dispatch-resolve.sh data/<id>/brief.md` has written that task's record, `data/<id>/dispatch-resolution.json`.
Both paths are under `FM_DATA_OVERRIDE` instead of `data/` when it is set.
When the record is `clear`, the spawn must match its harness, and its model and effort where the record sets them, with no raw launch command, unless `--dispatch-override <reason>` records a task override in `state/<id>.meta` as `dispatch_override=<reason>`.
A model or effort the record leaves empty is not bound, so the documented effort fallback still applies.
When the record is `ambiguous`, `escalate`, `error`, or `off`, the explicit flags from the manual intake are enough.
An `fm-spawn.sh --relaunch` skips this check.

The inherited-local-material contract is owned by [`secondmate-provisioning`](../../.agents/skills/secondmate-provisioning/SKILL.md); its harness-relevant consequence is that a secondmate's own crewmates use the primary's dispatch profiles and static harness value.
Those inherited values are defaults and rules only; `fm-spawn` still permits a consciously chosen explicit runtime outside the config.

`config/secondmate-harness` is not inherited because secondmates do not launch secondmates.

### Installed hooks and launch details

For grok, `fm-spawn.sh` installs one firstmate-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.fm-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.
For Kimi crews, `fm-spawn.sh` runs `fm-kimi-turnend-hook.sh install`, drops a per-task `.fm-kimi-turnend` pointer in the worktree, and records the matching private registry token for teardown.

Kimi continues to use the captain's normal Kimi home, including the existing config, skills, and memory; Firstmate does not create an isolated Kimi home.
The Kimi installer requires an existing regular non-symlink `~/.kimi-code/config.toml`, `python3` with `tomllib`, and `jq`; it validates but never serializes the captain's TOML and refuses before writing when the config is missing, malformed, or surprising or when either tool requirement is unavailable.

Its `remove` action excises only the marker-delimited Firstmate region and removes Firstmate's hook files.
For Pi and pi-signed secondmate launches, `fm-spawn.sh` starts the selected executable with `-e` pointed at the secondmate home's own tracked `.pi/extensions/fm-primary-pi-watch.ts` and `.pi/extensions/fm-primary-turnend-guard.ts`, both already present from the secondmate home's git worktree, plus the parent home's `state/<id>.pi-ext.ts` busy extension.
Pi-family secondmates can start unattended in Firstmate-seeded homes without accepting project trust manually; [`fm-spawn.sh --help`](../../bin/fm-spawn.sh) owns the capability requirement, session-only approval scope, and older-version fallback, with [regression evidence](../verification/runtime-backends.md#pi-seeded-secondmate-project-trust).

For omp secondmate launches, `fm-spawn.sh` names only the parent home's `state/<id>.omp-ext.ts` busy extension with `-e`: omp auto-discovers the home's tracked `.omp/extensions/` with no trust gate, and naming a discovered file with `-e` as well loads it twice; every omp launch also carries the tracked `.omp/fm-worker-overlay.yml` posture overlay through `--config`, which [`fm-spawn.sh --help`](../../bin/fm-spawn.sh) owns.

For a Claude secondmate, `fm-spawn.sh` writes the busy hooks into the parent home's `state/<id>.claude-settings.json` and passes that file as Claude Code's one `--settings` value.
The same file carries `feedbackDrafts`, the composer-writing plugin override that [the Claude adapter reference](../../.agents/skills/harness-adapters/references/harness/claude.md#composer-ghost) explains, and, unless `config/keep-ai-trailers` is present, the attribution policy every other Claude launch puts in its inline `--settings` JSON.
Claude Code applies `--settings` for that session and does not write the file into the mate home.
A key the file sets overrides the same key in user, project, and local settings.
A key it omits keeps the file-based value, so a `.claude/settings.local.json` already in the home is left untouched.
Hook entries merge across settings files rather than replacing each other, so the home's tracked Stop guard still runs beside these hooks.
The CLI reference documents the one file-or-JSON flag, the settings page documents session precedence, and the hooks page documents the hooks merge: <https://code.claude.com/docs/en/cli-reference>, <https://code.claude.com/docs/en/settings>, <https://code.claude.com/docs/en/hooks>.
[`fm-spawn.sh`](../../bin/fm-spawn.sh) owns the file and the flag.

### Codex automatic approval review

Codex crewmate, scout, and secondmate launches default to `--dangerously-bypass-approvals-and-sandbox`.
The local, gitignored `config/codex-approval-mode` accepts one whitespace-trimmed token: absent or `bypass` retains that default; `approve-for-me` selects `--approve-for-me`.
Malformed values and unreadable files refuse before spawn mutation, and the setting applies to relaunches and is inherited into secondmate homes.
`backend=t3code` always runs Codex at T3's `full-access`, so it refuses `approve-for-me` before mutation; [`t3code-backend.md`](../t3code-backend.md#active-limits) owns that backend limit.
The fallback uses a model reviewer in the workspace-write sandbox, which starts with network access disabled and reviews writes outside the working directory.
It remedies a managed policy that leaves bypass launches with user-reviewed approvals even when its sandbox bypass applies.
Firstmate targets current CLIs rather than detecting versions or emulating older approval flags.
Crew and scout launches still request hook disablement and retain their notification wiring, while secondmates retain their primary-session hooks.
A managed policy can override the requested hook disablement, so it may still require an operator's hook review.
See the [current verification and limits](../verification/runtime-backends.md#codex-automatic-approval-review) for observed task-channel and network access.

## Claude permission mode (config/claude-permission-mode)

The optional local, gitignored `config/claude-permission-mode` selects the permission flag for Firstmate-built Claude command lines: crewmates, scouts, Claude secondmates, and control-plane relaunches.

### Accepted values and refusals

The token is the file's whitespace-trimmed content.

| Token | Launch permission flag |
| --- | --- |
| `auto` | `--permission-mode auto` |
| `bypass` | `claude --dangerously-skip-permissions` |

An absent file defaults to bypass, preserving `--dangerously-skip-permissions` for unconfigured homes.
Auto uses a model reviewer and avoids managed policies that block bypass-permission sessions.
It is selected by an explicit setting or the firstmate-invoked failover below.
Only the permission flag changes between the two modes.
The environment prefix, session settings, model, effort flags, and the task-channel `--add-dir` grant below stay the same in both.

Every Firstmate-built Claude command line, in both modes, also passes `--add-dir` for exactly this task's Firstmate channel directories, resolved to real paths: a secondmate gets the parent home's `state/<id>.inbox` it reads its steers from; a ship or scout worker gets this home's `state/operational-inbox` (its launch record), `state/<id>.inbox` (its steers), `data/<id>` (its brief and report), and the code root's `.agents/skills`.
The grant exists because Claude Code path-checks the Read/Glob/Grep file tools against cwd plus `--add-dir`, and since 2.1.257 the first outside read in `auto` mode parks the pane on a one-time interactive question, while a "Block" answer there writes `permissions.blockReadsOutsideWorkingDirectories` into user settings and then refuses the same reads under bypass too.
It never covers the whole `state/` or anything wider.

Any other value or an unreadable file refuses every spawn from that home, whichever harness it would launch.
This happens before any endpoint, worktree, or task record exists.
The diagnostic names the accepted values; Firstmate never falls back to a permission posture the captain did not choose.

### When changes apply and inheritance

`bin/fm-spawn.sh` reads the file on every spawn and relaunch, so a change takes effect at the next launch without a restart.
Both approval-mode files follow the primary-authoritative [`secondmate-provisioning`](../../.agents/skills/secondmate-provisioning/SKILL.md) inherited-local-material contract.
T3 Code owns its provider command and always uses `full-access`, so `backend=t3code` accepts the default `bypass` posture and refuses `auto` before mutation; [`t3code-backend.md`](../t3code-backend.md#active-limits) owns that backend limit.

The [Claude adapter reference](../../.agents/skills/harness-adapters/references/harness/claude.md) records the permission-mode observations and the distinct startup dialogs.

## Codex permission mode (config/codex-permission-mode)

The optional local, gitignored `config/codex-permission-mode` selects the permission flags for Codex crewmates, scouts, secondmates, and relaunches started by this home.

| File content | Launch permission flags |
| --- | --- |
| Absent or `bypass` | The [Codex approval mode](#codex-automatic-approval-review) flag, `--dangerously-bypass-approvals-and-sandbox` by default |
| `restricted` | `--sandbox workspace-write --ask-for-approval on-request` |

Create the file containing exactly one of the two tokens, optionally followed by a newline.
An absent file preserves the existing launch command.
Restricted mode changes only the permission flags; model, effort, and hook wiring stay the same.
It replaces whichever flag `config/codex-approval-mode` selects, and the task record reports `restricted`, so managed approval failover never treats the launch as bypass.
It grants no additional writable directories, including the shared Firstmate state directory.
Writes outside the worker's worktree, including status reports and steering-inbox acknowledgements, remain subject to operator approval.
Codex `--sandbox workspace-write` also disables network access and does not permit writes to shared Git metadata by default, so `git commit`, `git push`, `gh`, and no-mistakes pipeline steps from a restricted worker likewise stop at an approval prompt.
Choose restricted mode only when that approval workflow is available.

`bin/fm-spawn.sh` reads and validates the setting before any spawn or relaunch mutation, regardless of the selected harness.
Any other content, an unreadable or non-regular file, or a dangling symlink refuses the launch instead of falling back to bypass.
Changes take effect at the next launch without a restart.
The file is not inherited into secondmate homes; configure it separately in each home that should also restrict its own Codex workers.
`backend=t3code` always runs Codex at T3's `full-access`, so it refuses `restricted` before mutation; [`t3code-backend.md`](../t3code-backend.md#active-limits) owns that backend limit.

## Persistent managed-policy failover

After firstmate observes a Codex command-approval prompt under its bypass flag or a Claude managed-policy refusal of a bypass session, it asks the captain for explicit approval to save a lasting worker permission setting and relaunch the worker.
Only after that approval does firstmate invoke `bin/fm-approval-failover.sh`; the script's header and help own the command and recovery mechanics.
There is no automatic detection, polling, startup window, or approval-prompt answering.
The command saves Codex's `approve-for-me` or Claude's `auto` in the owning home's absent mode file, so later launches use the model-reviewed remedy without retrying bypass.
Existing explicit settings are never overwritten, including invalid or empty files, directories and dangling symlinks; a concurrent setting wins too.
To retain a secondmate's remedy across convergence, select it in the primary home under the [inherited-local-material contract](../../.agents/skills/secondmate-provisioning/SKILL.md).
Recovery uses the existing [lifecycle control plane](../agent-control.md), respecting its leases and supported-runtime limits; incomplete recovery is reported with the saved setting and work preserved.
A `backend=t3code` task refuses before any change, because T3 already runs it at `full-access` and its spawns refuse both fallbacks; approve the pending request in T3 Code itself or choose another backend.
Generic login failures do not establish a defeated bypass, and managed hook review remains a separate operator decision.
Neither fallback is unrestricted execution, and Firstmate does not change vendor or security-agent settings.

## Worker tool exclusions (config/crew-exclude-tools)

The optional local, gitignored `config/crew-exclude-tools` hides named tools from this home's ship and scout workers, for example to keep an MCP server's write tools out of reach while its read tools stay available, or to stop sending the schemas of tools a worker never calls with every model request.
The contract is runtime-neutral: a runtime must support hiding the listed tool names or refuse the launch, and a non-empty list is never silently ignored by the launch (Claude name typos are the exception, see [Validation](#validation)).
With no file, or a file with no entries, every launch on every runtime is unchanged.

Create the file with one tool name per line, such as `mcp__<server>__<tool>` for an MCP tool.
Blank lines and lines beginning with `#` are allowed, and surrounding whitespace on a line is trimmed; a trailing comment on an entry line is not allowed.
The file is read from this home's own configuration directory on every launch, so a change reaches the next worker or relaunch without a restart.
It is not in the inherited configuration set, so no other home, including a secondmate home, receives it; create the file in each home that wants it.
It does not apply to a secondmate's own agent, which neither reads nor refuses on it.

### Runtime support

| Runtime | With a non-empty list |
| --- | --- |
| `claude` | Launches with `--disallowedTools '<names>'`, so each listed tool's schema is absent from every model request, not only denied at call time. An entry may also be an MCP server name such as `mcp__<server>`, which hides all of that server's tools. Applies to every ship and scout spawn and relaunch. |
| `pi`, `pi-signed` | Hides listed tool names, MCP tools included, on every ship and scout spawn and relaunch. |
| Every other runtime, and a raw launch command | The launch refuses with an error naming `config/crew-exclude-tools`, because that runtime has no verified way to hide tools. |

A relaunch validates the list and the replacement runtime's support before stopping the running worker, so an exclusion-list refusal preserves the running agent.

### Trimming Claude tool schemas

Claude Code sends every enabled tool's schema with each model call, and a long-lived worker resends them on every turn.
List a tool the workers do not use to remove its schema from that fixed cost, for example `Workflow` or the artifact tools; the measured examples are in `docs/verification/runtime-backends.md`.
Claude Code can supply a built-in `Artifact` tool when the artifacts MCP server is disallowed, so hide both `mcp__<artifacts-server>` and `Artifact` to remove every artifact schema.
Only a name that matches a tool present in the worker's session has any effect; [Validation](#validation) explains why Claude names go unchecked, so confirm the saving from a worker's first request or `/context`.
The measured effect on a Claude Code 2.1.319 worker launch is recorded in [`docs/verification/runtime-backends.md`](../verification/runtime-backends.md).

### Validation

An entry may use only `A-Z`, `a-z`, `0-9`, `_`, `.`, and `-`.
An entry with any other character, including internal whitespace, a comma, or a `*`, refuses the launch and names the offending entry.
An unreadable or nonregular file, or a path inspection error, also refuses and names the configuration file.
For a new worker, these checks run before its endpoint, local copy, or task record is created; Firstmate never launches with a partial list.
Only exact tool names are accepted, not wildcard patterns.
Firstmate checks syntax and runtime support before launch but never runs `pi mcp list` or otherwise connects to servers to validate names.
Claude workers get no post-launch name check, so a misspelled Claude entry is silently ineffective.
When its first agent run starts, after Pi's startup tool-loading boundary, the worker extension compares the launch's exclusion list with its own loaded-tool registry and appends a timestamped warning note to `state/<task-id>.status` naming the configuration file and every unmatched entry for the supervisor.
The check runs before worker actions so it cannot supersede a terminal status emitted during the turn.
An unmatched entry is reported as **unverified**, not valid: Pi versions that omit excluded tools from the registry cannot distinguish a correct exclusion from a typo, and a server that has not connected cannot verify its tools either.
Names present in the registry produce no report; unknown or unverified names do not refuse the launch.
Each relaunch installs a fresh worker extension with the home's current list, so the replacement performs the same check.

[`bin/fm-exclude-tools-lib.sh`](../../bin/fm-exclude-tools-lib.sh) implements parsing and pre-launch validation for this contract; [`bin/fm-spawn.sh`](../../bin/fm-spawn.sh)'s header owns the launch-flag mechanics.
