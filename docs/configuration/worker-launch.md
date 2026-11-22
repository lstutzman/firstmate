# Worker launch

Part of the [configuration reference](../configuration.md).

## Worker dependency setup (`config/spawn-setup/<project>/`)

To install dependencies before a new worker starts, add shell scripts to the effective home's `config/spawn-setup/<project>/` directory, where `<project>` is the project directory's basename.
`FM_CONFIG_OVERRIDE` selects a different config root when set.
This configuration is private and opt-in; without it, spawn behavior is unchanged.

| File | Effect |
| --- | --- |
| `<step>.sh` | Run this step with Bash, in filename order, starting in the isolated task copy. |
| `<step>.off` | Skip this step when this file exists. |
| `off` | Skip every step for this project when this file exists. |

Use trusted dependency-install commands only, keep their project writes inside the task copy, and never use `sudo`.
Setup uses the spawning process's environment and does not require executable script permissions.
Keep credentials out of the scripts and their output, because output is saved to the task's logs.
Fresh ship and scout launches run setup after the isolated copy is validated, its base is prepared, and the task record is published, before the worker starts, on every supported worker tool and runtime backend.
Setup runs after the home-wide task-set lock and the shared Treehouse project lock are released, so other spawns and slot returns are not held up by a long install; the task's own record lock stays held until launch.
Relaunches and persistent secondmates do not run setup.
Each enabled step runs independently with its own fixed 600-second deadline; a failed step does not skip later steps or prevent the worker from launching.
Output and the result go to `state/<task-id>.setup/<step>.log`.
A failure or timeout adds the step name and log path to the worker's private launch instructions, telling it to rerun the install inside its copy before testing.
[`bin/fm-spawn-setup.sh`](../../bin/fm-spawn-setup.sh) owns execution and reporting; [`tests/fm-spawn-setup.test.sh`](../../tests/fm-spawn-setup.test.sh) exercises the spawn integration.

For PropertyCompass2, create `config/spawn-setup/PropertyCompass2/10-npm.sh` locally with:

```bash
set -e
cd src/PropertyCompass.Web/client
npm ci
```

Create `config/spawn-setup/PropertyCompass2/20-dotnet.sh` locally with:

```bash
set -e
source scripts/dev-env.sh
export DOTNET_ROOT
dotnet restore PropertyCompass.sln
```

Use `20-dotnet.off` to disable only restore, or `off` to disable all PropertyCompass2 setup.
These examples describe local configuration; no private project setup is included in the repository.

## Spawn base from the primary checkout (config/spawn-base-primary-checkout)

The optional local, gitignored `config/spawn-base-primary-checkout` presence flag opts this home into a default-off base for fresh task worktrees on projects that land work locally.
Without it, every fresh ship or scout worktree on a project with an origin remote resets to `origin/<default>`, or to `origin/<base>` for a named base branch.

### Which tasks it changes

With it present, a fresh local-only ship, or a scout spawned without `--base-branch`, starts from the primary checkout's `<default>` when that branch strictly contains origin's tip.
A local-only project lands work there through `bin/fm-merge-local.sh` and never pushes, so `origin/<default>` stays at the last push, and a fresh task would otherwise start behind work already landed and load the project's instruction files from that stale tree.
A no-mistakes or direct-PR ship and any task with a named base branch still start from origin's tip, because that work is delivered against origin.
When the primary checkout's `<default>` and origin's have diverged, the spawn prints a note and starts from origin's tip.
A project without an origin remote is unaffected, and a relaunch never changes the base a task already has.

`bin/fm-review-diff.sh` reads the same flag, so a local-only ship or a scout is reviewed against the branch it delivers to and its diff shows only its own work, while a no-mistakes or direct-PR ship stays anchored on `origin/<default>`.
`bin/fm-promote.sh` reads it too, telling a scout promoted to no-mistakes or direct-PR on a project with an origin remote to return to origin's default branch rather than the primary checkout's.

The flag is per home and is not inherited by secondmate homes, which keep their own project clones and opt in separately.
Only its presence is read, at each fresh spawn, review, and promotion.
The [`fm-spawn.sh` header](../../bin/fm-spawn.sh) owns the exact base rule, and the [`fm-review-diff.sh` header](../../bin/fm-review-diff.sh) owns the review anchor.

## Worker account pin (config/claude-account, config/pi-account)

A home that mixes accounts for one runner, such as a work login and a personal one, can pin the account its own Claude and Pi workers launch on.
The pin is opt-in: without a home-wide or per-secondmate pin, pane-backed Claude launches keep receiving firstmate's own `CLAUDE_CONFIG_DIR` when it is set.
Unpinned Pi launches use the destination pane's ambient account.

Both files are local and gitignored.

| Runner | File | Variable the launch receives | `ordinary` means |
| --- | --- | --- | --- |
| `claude` | `config/claude-account` | `CLAUDE_CONFIG_DIR` | the variable unset, so Claude uses its default login |
| `pi`, `pi-signed` | `config/pi-account` | `PI_CODING_AGENT_DIR` | `~/.pi/agent` |

### File format and provider selection

`config/claude-account` holds one line: `ordinary`, or the absolute path of an existing Claude config directory.
`config/pi-account` holds that same root on line 1 and, on line 2, the providers this home may spend, separated by spaces, for example `openai-codex anthropic`.

A final newline is optional; any other line, a relative path, or a control character such as a CR refuses.
For Claude, `ordinary` unsets `CLAUDE_CONFIG_DIR` rather than pointing it at `~/.claude`, because Claude reads `$CLAUDE_CONFIG_DIR/.claude.json` and keys its macOS Keychain entry to any directory that is set ([authentication, "Credential management"](https://code.claude.com/docs/en/authentication#credential-management)).

A Pi root can hold several provider logins at once, so the root alone does not say which account a launch spends.
A pinned Pi launch therefore needs `--model <provider>/<id>` naming a declared provider, and Firstmate also passes `--provider <that provider>` so Pi cannot resolve the model under another signed-in provider.

An unqualified model, an undeclared provider, or a raw Pi launch command, which cannot receive that flag, refuses; Firstmate never guesses a provider.

### Launch scope and sign-in checks

When a file is present, supported command-line launches of that runner from this home use it: ships, scouts, local secondmate agents, raw Claude launch commands, and relaunches.
A local secondmate can override this default with its own [per-secondmate account pin](#per-secondmate-account-pins).
T3 Code selects the account through its provider instance instead, so `backend=t3code` refuses a worker account pin before mutation; [`t3code-backend.md`](../t3code-backend.md#active-limits) owns that backend limit.
A raw Claude launch command refuses if its leading assignments set `CLAUDE_CONFIG_DIR` or a credential that a pinned launch unsets, such as `ANTHROPIC_API_KEY`.
The assignment would override the pin.
The refusal names the variable; remove that assignment from the raw command, or change or remove `config/claude-account`.

Before any worker endpoint, local copy, or task record exists, and before a relaunch stops the running worker, Firstmate asks the runner itself whether the pinned account is signed in: `claude auth status` for Claude, and `pi auth check --provider <provider> --json --no-refresh` for Pi, falling back to `pi --list-models <provider>` for a provider an extension registers.
The check runs with only `HOME`, `PATH`, `TMPDIR`, `USER`, `LOGNAME`, and the pinned root in its environment, so a credential variable in firstmate's own environment cannot answer for an empty root.

A pinned Claude launch also unsets the environment credentials Claude ranks above a stored login, such as `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, and the Bedrock and Vertex switches ([authentication precedence](https://code.claude.com/docs/en/authentication#authentication-precedence)).
Pi ranks a root's stored logins above environment variables, so a pinned Pi launch unsets nothing.

A home that authenticates Claude through environment credentials on purpose should leave the pin absent.

### Failures, reporting, and inheritance

A malformed file, a root that is not a readable directory, or a signed-out account refuses the launch and names the file to fix; Firstmate never falls back to the ambient account and never changes a global login or copies a credential.
The spawn prints the pin as `account=` (plus `account_provider=` for Pi) and records the same fields in the task record, so the session-start digest shows which account each worker launched on.

Pins are not inherited into secondmate homes: the secondmate's own workers read that home's `config/claude-account` and `config/pi-account` files independently.
A remote secondmate is launched on its host from its own home's configuration, so create the file in that remote home.

[`bin/fm-worker-account-lib.sh`](../../bin/fm-worker-account-lib.sh) owns parsing, the sign-in check, and the full list of credentials a Claude launch unsets; [runtime backend verification](../verification/runtime-backends.md#worker-account-pin-sign-in-check) records the check against the real runners.

### Several Claude accounts (config/claude-accounts)

A home with more than one Claude subscription can let each ship and scout launch on whichever declared account has quota to spare, instead of pinning every Claude worker to one account.
Create `config/claude-accounts` with one account per line, each `ordinary` or the absolute path of an existing Claude config directory, written exactly as `config/claude-account` would hold it:

```text
ordinary
/home/me/.claude-second
```

A final newline is optional; a blank line, a relative path, a repeated entry, or a control character refuses.
The list is opt-in: without it, every launch, including the single pin above, behaves exactly as before, and `--account` refuses.
A home keeps either the list or `config/claude-account`, never both; with both present, every Claude launch refuses.

While the list is present, every Claude ship or scout spawn must name one declared entry with `--account <entry>`.
Firstmate chooses that entry at dispatch intake under the [`quota-array-dispatch`](../../.agents/skills/quota-array-dispatch/SKILL.md) procedure, and [`bin/fm-claude-account-quota.sh`](../../bin/fm-claude-account-quota.sh) measures each entry for it by running `quota-axi --provider claude --profile-only` under that entry's own config directory (`~/.claude` for `ordinary`).
Firstmate never picks an entry by default, by file order, or from the ambient account, and never discovers, adds, or copies a login.

The named entry passes the same refusals as a pin before anything launches: its directory must exist, a raw Claude command must not override it, and `claude auth status` must say it is signed in, with the stripped environment and credential unsetting described above.
An undeclared, missing, or signed-out entry refuses rather than falling back to another entry or the ambient account.
The spawn line and the task record carry the entry as `account=`.

A relaunch or recovery of that task keeps its recorded account, re-checking that it is still declared and signed in before the running worker stops.
To move a task to another declared account, for example when its own account is exhausted, relaunch it explicitly with `bin/fm-control.sh <id> relaunch --account <entry> --note <text>`; nothing moves a running task automatically.
A task with no recorded account, or one whose account is no longer declared, refuses a plain relaunch and needs that explicit `--account`.

The list covers Claude ships and scouts only.
A local secondmate's own agent never draws from it: under a list it needs its own [per-secondmate account pin](#per-secondmate-account-pins), and `--account` refuses for every secondmate, local or remote.
Other runners ignore the list, and `--account` refuses for them.
Like the single pin, the list is not inherited into secondmate homes.

### Per-secondmate account pins

To choose an account for one local secondmate's own agent, create `config/secondmate-accounts/<id>/claude-account` or `config/secondmate-accounts/<id>/pi-account` in the primary home.
Use the secondmate's registered identifier for `<id>`.
These private files use the same [file format and provider selection](#file-format-and-provider-selection), sign-in checks, and refusal rules as the home-wide worker pins.

The matching per-secondmate file overrides the primary home's matching worker pin for that secondmate alone.
An absent per-secondmate file preserves the existing home-wide pin or unpinned behavior exactly.
Other secondmates and ordinary workers remain unchanged.
A pin for another runner does not apply, and `pi` and `pi-signed` share `pi-account`.
An empty, malformed, unreadable, or unusable per-secondmate pin refuses with its path and reason rather than falling back to the primary's account.

For example, `config/secondmate-accounts/work/claude-account` containing `/home/me/.claude-work` selects that existing Claude login for the local secondmate named `work`.
Removing that file restores the primary home's account selection on the next launch.
Every spawn, control-plane relaunch, and automatic recovery reads the durable setting again, never a previous task record or ambient account choice.
After changing a live mate's pin, use `bin/fm-control.sh <id> relaunch` to apply it.
The relaunch checks the selected pin before stopping the current agent.

Per-secondmate pins stay in the primary home and are not inherited or copied into the secondmate's home.
A matching primary-side per-secondmate pin for a remote route refuses before remote launch, because its account must be configured on that host instead.

### Per-secondmate omp profile

To launch one local omp secondmate under its own isolated omp profile, create `config/secondmate-accounts/<id>/omp-profile` in the primary home.
Use the secondmate's registered identifier for `<id>`.
The file holds one omp profile name on a single line, with an optional final newline.
The name must match omp's own profile rule, `^[a-z0-9][a-z0-9._-]{0,63}$`, must not end in `.`, and must not be a Windows reserved device name (`con`, `prn`, `aux`, `nul`, `com0`-`com9`, `lpt0`-`lpt9`), alone or with an extension such as `nul.x`.

When the file is present, that secondmate's omp agent launches as `omp --profile <name>`, so it uses that profile's own logins, sessions, settings, and caches rather than the primary's default omp profile.
The model catalog check before launch reads the same profile.
When the file is absent, the launch carries no `--profile` flag and is unchanged.
There is no home-wide fallback file.

Only a local secondmate's own omp agent reads this file.
Ships, scouts, other runners, and remote secondmates never read it, and another secondmate's file never applies.
The profile pin is independent of the [per-secondmate account pins](#per-secondmate-account-pins), which select a Claude or Pi login root rather than an omp profile.

For example, `config/secondmate-accounts/speak4/omp-profile` containing `speak4` launches the local secondmate named `speak4` with `omp --profile speak4`.
An empty, malformed, or unreadable file refuses with its path before any worker endpoint, local copy, or task record exists, and never falls back to the default profile.
A raw omp launch command cannot carry the flag, so a pinned secondmate refuses one; launch it with `--harness omp`.
Firstmate does not create, sign in, or copy an omp profile; sign in to it yourself with `omp --profile <name>`.

The spawn prints the pin as `omp_profile=` and records the same field in the task record.
Every spawn, control-plane relaunch, and automatic recovery reads the file again, and a relaunch checks it before stopping the current agent.
After changing a live mate's pin, use `bin/fm-control.sh <id> relaunch` to apply it.
The file stays in the primary home and is not inherited or copied into the secondmate's home, because a secondmate does not launch secondmates.
[`bin/fm-omp-profile-lib.sh`](../../bin/fm-omp-profile-lib.sh) owns parsing and the refusals.

## Home brief include (config/brief-include.md)

The optional local, gitignored `config/brief-include.md` adds standing worker instructions to every ship and scout brief.
This keeps private brief content out of tracked files.
When the file exists, `bin/fm-brief.sh` appends its text verbatim, less any blocks tagged for other projects (below), as the scaffold's last section, `# Home brief additions`, which defers to every other section of the brief, including the ship contract a later scout promotion appends below it.

An absent or blank file changes nothing, while a present path that is not a readable regular file, or text carrying its own `Delivery contract: mode=` line, stops the scaffold before anything is written.
The text is static and never executed or expanded, and secondmate charters never take it.

A block can be limited to some projects: a line that is exactly `<!-- project: PropertyCompass2 -->` (several names are comma-separated) opens a block that only briefs whose repo-name is listed receive.
Every block must be closed with a line that is exactly `<!-- /project -->`: the next tag line may still end the block before it, but the last block must be closed, and a block left open at the end of the file stops the scaffold before anything is written, so own lines added below an inherited base never fall inside a base block.
Tag lines are never emitted, and untagged text always is.
A file with no tag line is emitted unchanged, so tagging only removes text from briefs for other projects and shrinks them.

The primary's file is inherited by every secondmate home as a base: the home's copy is the primary's text followed by the home's own lines.
Each push replaces only that base, so add a home's own rules below it; an edit inside the base is kept, re-appended below the next base rather than lost.
A home whose file predates inheritance keeps its whole file as its own lines, less a leading copy of the primary's text, so text it duplicated differently appears twice once and is pruned by hand.
Removing the primary's file leaves each home exactly its own lines.
`bin/fm-config-inherit-lib.sh` owns the composition on both the local and remote routes.

`bin/fm-brief.sh`'s header owns the placement rule and its safety argument.

## Home branch prompt include (config/branch-prompt-include.md)

The optional local, gitignored `config/branch-prompt-include.md` adds standing home rules to the supervision branch's system prompt, the way `config/brief-include.md` extends worker briefs.
The branch's headless engine loads none of the home's own hooks, `CLAUDE.md`, skills, or plugins, so this file is how a home gives the branch a home-specific rule.
When the file exists, `bin/fm-branch-prompt.sh` appends its text verbatim as the prompt's last section, `# Home prompt additions`, which defers to every other section of the prompt.

An absent or blank file leaves the prompt byte-identical, while a present path that is not a readable regular file stops the generator before it emits anything, so the branch does not start.
The text is static and never executed or expanded, and an edit takes effect when the branch next builds its prompt for a new conversation.

`bin/fm-branch-prompt.sh`'s header owns the placement rule and how it keeps the prompt cache stable.

## Herdr lifecycle spawn guard (config/herdr-lifecycle-spawn-guard)

The optional local, gitignored `config/herdr-lifecycle-spawn-guard` presence flag opts this home into refusing, at spawn, a ship or scout brief that drives Herdr lifecycle without the Herdr isolation contract.
Create it with `touch "$FM_HOME/config/herdr-lifecycle-spawn-guard"`; remove it to launch such briefs again.
It is off by default: without the flag, `bin/fm-spawn.sh` launches the brief as before, and only the unguarded scaffold's own `# Herdr lifecycle declaration - NOT ENABLED` gate text asks the author to regenerate it.
With the flag present, a brief that names `bin/fm-herdr-lab.sh`, or a `herdr session` or `herdr server` command with the verb `start`, `stop`, `delete`, `restart`, `reload-config`, or `live-handoff`, must carry the `# Herdr isolation - HARD SAFETY CONTRACT` section that `bin/fm-brief.sh --herdr-lab` emits.
The refusal names the first matching command, so the author can tell a brief that truly drives Herdr lifecycle from one that only quotes a verb incidentally, and points at `bin/fm-brief.sh --herdr-lab` as the remedy.
A refused spawn writes no task record, so the brief can be regenerated and the spawn repeated.
The flag is read only for ship and scout spawns, secondmate charters never take it, and it is not inherited by secondmate homes.
[`herdr-backend.md`](../herdr-backend.md) owns the lab isolation contract itself; `bin/fm-spawn.sh`'s header owns the exact matching rule.

## Worker launch environment (config/launch-env-allowlist)

The optional local, gitignored `config/launch-env-allowlist` limits the ambient environment passed to newly launched workers, scouts, and secondmates, including relaunches.
T3 Code starts the provider from the server's environment and cannot apply this command boundary, so `backend=t3code` refuses when the file exists; [`t3code-backend.md`](../t3code-backend.md#active-limits) owns that backend limit.
With no file, ambient inheritance remains unfiltered: selected harness markers are cleared, while the provider, long-lived terminal daemon, and shell initialization determine which other variables reach the worker.

Do not assume every worker inherits the invoking Firstmate process's current environment.
The file is inherited into secondmate homes through the [primary-authoritative configuration contract](../../.agents/skills/secondmate-provisioning/SKILL.md).

Changes apply to subsequent launches; existing processes keep their environment.

### Allowlist format

Create the file with one environment variable **name** per line, never credential values, assignments, wildcards, or shell commands.
Blank lines and lines beginning with `#` are allowed.

Invalid names, an unreadable or nonregular file, or a path inspection error (including an inaccessible configuration directory) stop the launch.
An empty file enables filtering with only Firstmate's operational floor.

For example, a provider using `OPENAI_API_KEY` and Git using an SSH agent could use:

```text
# Provider credential already available in the destination pane
OPENAI_API_KEY
# Git over SSH using an existing agent
SSH_AUTH_SOCK
```

### Variables retained and where values come from

Firstmate retains basic home, executable search, terminal, locale, temporary-directory, and backend routing variables, plus its explicit launch assignments, its ship and scout task marker, the compact-adviser kill switch described below, and enabled task trace.
The allowlist floor also retains Tern block markers `TERN_IDENTITY`, `TERN_PANE`, `TERN_PANE_SOCKET`, `TERN_WINDOW_KEY`, and `TERN_WINDOW_SOCKET` so a worker's own Tern/TSP integration survives `env -i`.
It retains `HC_SESSION`, `HC_TERMINAL_ID`, `HC_TERMINAL_SOCKET`, and `HC_SCOPE` the same way, so a worker in an hc terminal still reports its status to herdr-core.
[`fm-spawn.sh --help`](../../bin/fm-spawn.sh) owns the exact retained names and parsing mechanics.

Other ambient names must be listed explicitly, including custom credential-store locations, proxy settings, and certificate overrides when required by the selected tools.
The command shell and worker may still create their own variables.

Unless the Orca environment source below is configured, allowed values come from the destination pane at execution time; they are neither copied from the invoking Firstmate process nor written into the launch command.
Listing a name does not provision it in a daemon's environment or transfer credentials to another machine.

On the Orca backend the destination is an Orca terminal whose environment comes from the Orca app and your shell startup files, not from Firstmate or its tmux session.
Allowlisted names there resolve to whatever that terminal has, often your personal credentials or nothing, so a spawn with a nonempty allowlist prints a warning unless the Orca environment source below is configured.

### Orca environment source (config/launch-env-tmux-session)

An Orca home can opt in to taking allowlisted values from one named tmux session instead of the Orca terminal.
Create the local, gitignored `config/launch-env-tmux-session` containing that session's name, and keep the session running for subsequent Orca spawns.
The source requires `config/launch-env-allowlist` and reads only its names from the session's local environment (`tmux set-environment -t <session>`), so tmux's automatic values such as `SSH_AUTH_SOCK` are never forwarded unless listed.
A listed name missing from the session, an unreadable session, or a malformed selector stops the spawn before Orca creates the worktree or terminal; a name removed with `tmux set-environment -r` stays deliberately unset.
Source mode also sets `GIT_CONFIG_NOSYSTEM=1`, so a system Git credential helper cannot answer with personal credentials.
Values travel only in the owner-only staged launch file, never terminal input, and the pane deletes that file before the worker starts.
If the pane has not run the launch command and deleted the file within 30 seconds, or the spawn is interrupted before then, Firstmate removes the file unless the pane already did, leaves the Orca terminal open, and reports the spawn as failed rather than leaving credentials on disk.
The source applies to fresh Orca spawns; `--relaunch` is refused on Orca because it has no recovery-grade agent-state classifier.
The selector is not inherited into secondmate homes, and other backends ignore it.
[`fm-spawn.sh --help`](../../bin/fm-spawn.sh) owns the snapshot and launch-file mechanics.
Project and harness sandbox settings still own filesystem access to personal credential stores.

### Authentication requirements

Choose the minimum additions for the authentication method actually in use:

| Provider or Git transport | Additional names needed |
| --- | --- |
| Provider login stored under the normal home directory | None for the environment contract; the same user still has access to that provider's stored login. |
| Provider configured through environment variables | The exact credential and endpoint names required by that provider, for example `OPENAI_API_KEY` or `ANTHROPIC_API_KEY`; a multi-provider tool needs each provider it will actually use. |
| Custom provider store | Its configured location variables, such as `CODEX_HOME`, `GROK_HOME`, or `XDG_CONFIG_HOME`; Firstmate's existing explicit Claude and Muse store assignments still apply. |
| Muse environment authentication | `META_API_KEY`, already present in the target tmux session environment; Firstmate's preflight requires the stored-login path on other backends. |
| Git over SSH with an agent | `SSH_AUTH_SOCK`; add `GIT_SSH_COMMAND` only if the chosen transport requires that override. |
| Git over SSH with a key file | No credential variable when normal SSH configuration selects the key; file permissions and any passphrase handling still apply. |
| Git over HTTPS with a credential helper | Whatever the configured helper requires; a GitHub CLI helper using an environment token needs its selected `GH_TOKEN` or `GITHUB_TOKEN`. |

### Validation and security limits

Verify the selected provider login and Git transport after opting in; Firstmate does not infer credentials from model names or install a secret manager.
Raw launch commands run under noninteractive POSIX `sh` with this option and must use compatible syntax.

The filter runs at the worker command boundary, after the terminal daemon and pane shell have started; it does not scrub either of those processes.
This is not a sandbox: it cannot revoke same-user access to credential files, prevent tools or later shells from loading credentials again, or isolate processes from the same user's other processes.

Regression coverage executes emitted launch commands with synthetic nonsecret values in [`tests/fm-spawn-dispatch-profile.test.sh`](../../tests/fm-spawn-dispatch-profile.test.sh), and the Orca environment source in [`tests/fm-spawn-orca-worktree.test.sh`](../../tests/fm-spawn-orca-worktree.test.sh).

### Compact adviser setting

Every crewmate, scout, and secondmate Firstmate launches starts with `COMPACT_ADVISER_DISABLE=1` in its environment, on a fresh spawn and on a relaunch alike, so an unattended session never activates the compact adviser.
This guarantee also covers raw launch commands, remote secondmates, and launches filtered by `config/launch-env-allowlist`; it does not depend on the destination environment already containing the variable.

Firstmate provides no configuration or flag to change this value.
This applies only to agents Firstmate launches; the captain's own primary Firstmate session is never given the variable.

[`fm-spawn.sh --help`](../../bin/fm-spawn.sh) owns the delivery mechanics, with focused regression coverage in [`tests/fm-spawn-compact-adviser-disable.test.sh`](../../tests/fm-spawn-compact-adviser-disable.test.sh) and [`tests/fm-spawn-compact-adviser-disable-remote.test.sh`](../../tests/fm-spawn-compact-adviser-disable-remote.test.sh).

### Gate-edit grant for one task

A project can protect gate files and refuse an edit to them unless `ALLOW_GATE_EDIT=1` (optionally narrowed by `ALLOW_GATE_EDIT_FILES`, a comma-separated list of repo-relative paths) is in the editing session's environment.
A worker cannot set that itself, so a grant lives in the task's own state instead: `bin/fm-gate-grant.sh grant <task> --files <f1,f2> --pr <url|none> --kind tighten|signoff --decision-file <file>` writes `state/<task>.gate-grant`, and every launch of a ship or scout worker, a relaunch included, starts with `ALLOW_GATE_EDIT=1` and `ALLOW_GATE_EDIT_FILES=<files>` exported.
A running worker picks a new grant up on `bin/fm-control.sh <task> relaunch`; nothing is written into the worker's settings files, and a task with no grant starts with neither variable.
The decision file is firstmate's own statement for a `tighten` grant and the captain's quoted words, with where and when, for a `signoff` grant; an empty or missing decision refuses the grant.
The fleet rules own who may grant which kind.

A ship brief states the gate-file scope at dispatch: `bin/fm-brief.sh --gate-files <f1,f2>` names the protected files the task may edit and points at the grant script, and a brief without the flag says gate files are out of scope.
Both forms tell the worker that a gate-integrity or protected-file refusal is not to be retried or worked around: it appends one `blocked [cause=policy]` line naming the file and the edit wanted, so firstmate can grant it or route it, and carries on with the rest of the task.
The brief cannot say whether a grant is in place, because a grant is recorded after the task exists.

`grant` refuses, and logs the refusal, when it is called by a task worker (`FM_TASK_INBOX` names an inbox in this home's state, so a secondmate home's own firstmate still grants, or the working directory is inside a task worktree a `state/*.meta` record names); this stops an accidental or casual self-grant, while a full-access worker that forges local records stays outside this safeguard, as elsewhere in firstmate.

The grant ends when the task's PR is registered (`fm-pr-check.sh`) and at cleanup (`fm-teardown.sh`, before the task's branch and worktree are retired), and every grant, carry, refused carry and revoke is appended to `data/<task>/gate-grant.log`, which keeps the decision text and lists the commits that touched the granted files, and which outlives the task.
The grant record is removed at PR registration, so a relaunch after registration carries nothing; a worker that is already running keeps the environment it started with (the same PR, the same named files) until its next relaunch or cleanup, and a revoke says so.
Each carry also records its file list and the worktree's merge base with the task's base branch in `state/<task>.gate-grant.carried`, so the cleanup revoke lists the commits that touched those files again from that base, covering edits made after the PR registered even once the work has merged; teardown removes the marker only after every refusal point, so a retried teardown lists them again.
The t3code backend starts the agent with its provider instance's environment and never runs the launch command, so it carries no grant.
The script header owns the exact contract, with regression coverage in [`tests/fm-gate-grant.test.sh`](../../tests/fm-gate-grant.test.sh).

### Commit attribution

The optional local, gitignored `config/keep-ai-trailers` presence flag opts this home into keeping AI co-author trailers on its launched workers.
With the flag absent, every Claude command line Firstmate builds carries inline `--settings` JSON with `"attribution":{"commit":"","pr":"","sessionUrl":false}`, every Devin worker config sets `"attribution": false`, and every fleet launch appends a worker-scoped `GIT_CONFIG` `core.hooksPath` entry pointing at `state/<id>.git-hooks`, where git's `commit-msg` hook strips known AI trailers even when a runtime injects them after the typed message.
The entry follows any `GIT_CONFIG_*` entries the worker inherits, so an inherited scoped `credential.helper` still applies to the worker and to the repository's own hooks, such as a git-lfs `pre-push`; an inherited `GIT_CONFIG_COUNT` that is not a decimal number, or that leaves no room for another entry within Git's signed int, stops the launch before the worker runs.
T3 Code owns its provider command and cannot carry Claude's inline setting, but its per-worktree environment overlay selects the same Git hook; [`t3code-backend.md`](../t3code-backend.md#active-limits) owns that backend limit.
When the flag is present, Claude launches omit those attribution-off settings, Devin worker configs keep the user config's `attribution` setting (Devin's default is on), and fleet launches do not install or select the strip hooks, so Git uses the repository's configured hooks directly.
Cortex Code has no attribution switch and its model writes a `Generated with Snowflake CoCo` line and a `Co-authored-by: Snowflake CoCo` trailer itself, so the strip hooks are the only mechanism that removes them from a Cortex worker's commits.
`bin/fm-git-strip-ai-trailers.sh` owns the identities, the install, and chaining the hooks of whichever repository git is running in, including when `git -c core.hooksPath` supplies the pane's hook override, so a project hook such as husky still runs when stripping is enabled.
A repository whose config sets `core.hooksPath` to the empty string runs no project hook, as in plain git; if the wrapper otherwise cannot resolve that repository's hooks directory, the git operation fails rather than silently skipping a project hook such as a pre-push guard.
When stripping is enabled, the hooks directory is read-only, so a hook manager run inside a fleet pane (lefthook's npm postinstall, `pre-commit install`) fails instead of displacing the strip; install a project's hooks from outside the pane, where the wrappers chain them.
The flag is a home-wide attribution choice, so it is inherited into secondmate homes under the [`secondmate-provisioning`](../../.agents/skills/secondmate-provisioning/SKILL.md) inherited-local-material contract and a secondmate's own workers keep AI trailers too.
Per-machine Cursor `cli-config.json` attribution-off is not this contract: it does not travel with Firstmate, defaults back to on when unset, and only feeds the CLI's request to the server, so it suppresses the trailer rather than preventing it.

## Model overlay (`config/model-overlay-dir`)

`config/model-overlay-dir` is an optional file whose first non-blank line not beginning with `#` names a directory, absolute or relative to `config/`.
When that directory holds `<model>-<effort>.md` for a spawn's resolved `--model` and `--effort` (for example `claude-haiku-5-5-medium.md`), the spawn adds that file's text to the worker's launch brief under a `# Model overlay` heading, below every safety, approval and scope rule and outside the `--intent` text.
Without the file, a named model and effort, or a matching overlay, nothing is added; a missing or unreadable directory prints a warning at spawn and never blocks it.
