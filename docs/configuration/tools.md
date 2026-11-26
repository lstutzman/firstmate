# Tools

Part of the [configuration reference](../configuration.md).

## Lavish server address (config/lavish-axi-host)

The optional local, gitignored `config/lavish-axi-host` contains one non-empty address without whitespace for the per-machine Lavish server.
`fm-spawn.sh` exports that address into every new worker and relaunch for opening boards, and the file is inherited into secondmate homes through the primary-authoritative configuration contract.

Once a board exists, the process-event adapter derives the polling address from that board's own saved Lavish session instead; its header owns the lookup contract.
When the file is absent, worker launches do not add a board address and retain the existing ambient-environment behavior.

Malformed or unreadable values refuse the launch before the worker starts.
The address selects the existing shared server; it does not authorize starting or stopping the server, and the Lavish startup crash remains a vendor-tool concern.

## Lavish URL domain map (config/lavish-url-domains)

The optional local, gitignored `config/lavish-url-domains` maps captured website hosts to registered projects for `/lavish-url` feedback routing.
Each non-comment line is one `<domain>[:<port>] <project>` pair, and the named project must already be registered in `data/projects.md`.
The map is home-local and is not inherited by secondmate homes.
When the file is absent, routing falls back to registry entries that name the site, and treats a site only a project's own docs mention as unconfirmed evidence.
A malformed line or an unregistered project is an error rather than a guess, and two projects sharing the deciding entry are reported as ambiguous.
Snapshots and their metadata live under `<home>/.lavish/snapshots/`; `bin/fm-lavish-url.sh` owns the matching order, the snapshot record, and the routing output.

## Toolchain

On session start the first mate detects what its required toolchain is missing or too old and lists each problem with its exact install or upgrade command, or with manual instructions.
It installs missing automatically supported tools only after you say go; for an installed but outdated tool, run the printed upgrade command after consent, while manual-only tools remain for you to install from the printed instructions.

Required tools come in two parts: a universal toolchain every home needs regardless of backend, and a per-backend delta that follows the runtime backend actually resolved for this home.

**Universal requirements**

Every home requires:

- node and git.
- gh, with GitHub authentication through `gh auth login`.
- no-mistakes v1.46.0 or newer.
- Compatible gh-axi.
- chrome-devtools-axi.
- Compatible tasks-axi, as specified in "Backlog backend" above.
- Compatible quota-axi.

[`bin/fm-bootstrap.sh`](../../bin/fm-bootstrap.sh) owns the axi-family floor policy and the gh-axi and lavish-axi floors, while [`bin/fm-tasks-axi-lib.sh`](../../bin/fm-tasks-axi-lib.sh) and [`bin/fm-quota-axi-lib.sh`](../../bin/fm-quota-axi-lib.sh) hold their own tools' floor constants.
This section is the single owner of that universal toolchain list; backend guides' prerequisites point here and add only their backend-specific tools.

In that list, no-mistakes runs the validation pipeline, gh-axi and chrome-devtools-axi cover GitHub and browser operations, and tasks-axi plus quota-axi back backlog mutations and quota-aware array dispatch.
Lavish is a presentation-only dependency for visual decisions and reports; nonvisual work can proceed with plain text when it is unavailable.

**Backend requirements**

The per-backend delta is required only for the backend resolved from `FM_BACKEND`, then `config/backend`, then runtime auto-detection, then default `tmux`, so a home is never told to install a tool an inactive backend or feature would need.
`fm_backend_required_tools` in `bin/fm-backend.sh` owns the backend additions:

| Resolved backend | Additional tools |
| --- | --- |
| `tmux` | `tmux`, `jq`, `treehouse` |
| `herdr` | `herdr`, `jq`, `treehouse` |
| `zellij` | `zellij`, `jq`, `treehouse` |
| `orca` | `orca` |
| `cmux` | `cmux`, `jq`, `treehouse` |
| `paseo` | `paseo`, `jq`, `treehouse` |
| `rex` | `rex`, `jq`, `treehouse` |
| `t3code` | `node`, `treehouse` |
| `tern` | `tern`, `jq`, `treehouse` |

The JSON-emitting adapters (`herdr`, `zellij`, `cmux`, `paseo`, `rex`, `tern`) need `jq` because their spawn and liveness paths parse backend JSON, and `tmux` needs it because spawn reads `treehouse status --json` to lease the pool slots this home's task records still name.
Every session-provider-only backend (`tmux`, `herdr`, `zellij`, `cmux`, `paseo`, `rex`, `t3code`, `tern`) uses `treehouse` for worktrees.

Backend tool availability uses the adapter's own executable resolver, so bootstrap and spawn agree on supported non-`PATH` locations such as cmux's bundled CLI and the Rex server bundle's `rex`.
An unknown resolved backend emits `BACKEND_INVALID` and blocks dispatch instead of silently dropping its dependency delta or falling back to tmux.

Orca provides both the task worktree and terminal endpoint (see "Runtime backend" above), so `backend=orca` requires only `orca` on top of the universal toolchain and skips both `treehouse` and every other backend's session CLI.
A herdr, zellij, cmux, paseo, rex, t3code, or tern home is therefore never told `tmux` is missing, and the `treehouse` durable-lease and pool-root upgrade check runs only for the backends that actually use treehouse.

**Feature-specific requirements**

- When `config/crew-dispatch.json` exists, bootstrap also requires `jq` for dispatch profile validation.
- When Relay is opted in, bootstrap also requires `curl` and `jq` before arming the relay poll shim.
- When `config/record-export-root` exists, record sync and teardown archival require `python3` for descriptor-relative filesystem transactions and strict manifest parsing.

**Missing and outdated tool diagnostics**

`tasks-axi` and `quota-axi` are essential bootstrap tools in every profile.
An absent required tool with an automated install path reports `MISSING:` with its install command, while a present required tool below its floor or missing a required capability reports `OUTDATED:` with its installed version (or `unparseable`), requirement, and upgrade command; manual-only and presentation-only dependencies retain their dedicated diagnostics, and [`bin/fm-bootstrap.sh`](../../bin/fm-bootstrap.sh)'s header owns these exact line formats.

- An absent `treehouse` reports `MISSING:` with its install command, while an installed build without `treehouse get --lease` and `--root` support or the `treehouse lease` command reports `OUTDATED:` with the `treehouse update` upgrade.
- An absent `no-mistakes` reports `MISSING:` with its install command, while a version below 1.46.0 or an unparseable version reports `OUTDATED:` with the `no-mistakes update` upgrade.
- An absent `tasks-axi` reports `MISSING: tasks-axi (install: npm install -g --ignore-scripts tasks-axi@0.2.6)` and a below-floor or feature-incompatible one reports `OUTDATED:` with its required version and any missing feature-probe capability, while retaining that same pinned install command as its upgrade; when `config/backlog-backend` is not `manual`, a home with a configured non-markdown adapter or a markdown backlog refuses lifecycle mutation until compatible `tasks-axi` is on `PATH`, while a manual-backend home keeps its backlog hand-edited.
- An absent `gh-axi` reports `MISSING: gh-axi (install: npm install -g --ignore-scripts gh-axi@0.1.38 && gh-axi setup hooks)` and an outdated one reports `OUTDATED:` with its `gh-axi update` upgrade.
- An absent or board-incompatible `lavish-axi` reports `PRESENTATION_UNAVAILABLE` with the 0.1.77 compatibility floor, install command, and explicit text fallback; compatible versions below 0.1.80 retain legacy board replies and report an upgrade recommendation for synchronous acceptance, while [`bootstrap-diagnostics`](../../.agents/skills/bootstrap-diagnostics/SKILL.md) owns diagnostic handling.
- An absent `quota-axi` reports `MISSING: quota-axi (install: npm install -g --ignore-scripts quota-axi@0.1.60)` and an incompatible one reports `OUTDATED:` with its `quota-axi update` upgrade; firstmate cannot resolve a profile array without a compatible binary.

**Checkout diagnostics**

Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
In a read-only session that did not get the fleet lock, the same line is advisory and omits the checkout command.

With the opt-in [Treehouse pool report](home-and-state.md#treehouse-pool-report-configtreehouse-pool-report), bootstrap also prints `TREEHOUSE_POOL_REPORT:` findings.

**Project refresh at startup**

The locked session-start deferred network stage runs bootstrap's best-effort project clone refresh through `fm-fleet-sync.sh`; [`fm-bootstrap.sh`'s header](../../bin/fm-bootstrap.sh) owns the exact clone-refresh overlap, liveness-before-convergence, per-mate concurrency, ordered diagnostic replay, and sequential-fallback contract.

- It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms.
- Normal completed runs keep local-only and no-origin skips silent.
- If bootstrap kills a timed-out refresh, it replays any completed `fm-fleet-sync.sh` output before the aggregate timeout skip so no finished result is lost.

**Stale Git lock recovery**

A killed refresh (or a teardown process kill) can leave an orphaned `.git/packed-refs.lock` in a clone, which makes the next refresh's fetch fail with Git's `Unable to create '...packed-refs.lock': File exists`.
On that signature only, `fm-fleet-sync.sh` retries the fetch with a bounded wait for the lock to self-clear, then removes the lock and retries once more only when it can prove the lock stale, exactly like the `fm-teardown.sh` `index.lock` recovery.

It never removes a live lock, leaves any other failure shape untouched, and prints every wait, retry, and removal to stderr plus a one-line `recovered:` summary to stdout on success so that this session-start relay still surfaces the recovery.

**Secondmate sync at startup**

The same deferred network stage performs guarded tracked-file sync and propagates declared inherited local material into each validated live home under that sequencing contract.
Local routes use direct guarded filesystem operations, while remote routes delegate sync and allowlisted transfer through their configured SSH host without probing any unconfigured fleet.

- It emits `SECONDMATE_SYNC:` only when a home was skipped for an actionable sync reason, inheritance failed, or a divergent shared captain-preference copy was quarantined.
- When a running home advances and its loaded instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed, bootstrap sends the re-read nudge itself through the stable `fm-<id>` selector and reports the exact completed send as `BOOTSTRAP_INFO:`.
- If that send fails, bootstrap keeps an idempotent retry marker and emits `NUDGE_SECONDMATES:` with the failure reason.
- The same bootstrap run emits `SECONDMATE_LIVENESS:` only when a registered secondmate is skipped or its relaunch fails; already-live and successfully relaunched secondmates are handled silently.

**Push inherited configuration during a session**

For a mid-session inherited local-material edit where tracked-file sync is not needed, run `bin/fm-config-push.sh`.
It uses the same live secondmate discovery and propagation helper as bootstrap; its [help](../../bin/fm-config-push.sh) owns reporting and exit semantics, and [`fm_config_inherit_items`](../../bin/fm-config-inherit-lib.sh) declares the inherited items.

- The [`secondmate-provisioning` skill](../../.agents/skills/secondmate-provisioning/SKILL.md#charter-and-seed) owns the local and remote re-read behavior shared with locked bootstrap inheritance, including unchanged retries and interrupted transfers.
- That live discovery starts from `state/*.meta` records with `kind=secondmate`; `data/secondmates.md` only backfills `home=` for older or incomplete meta records.
- Skipped items, such as a destination checkout that does not yet gitignore the item, are visible warnings but not hard failures.

## Watched tool updates (config/watched-tools.json)

`config/watched-tools.json` is an optional local, gitignored list of the tools this home depends on.
When it is present and the check is armed, [`bin/fm-tool-update-check.sh`](../../bin/fm-tool-update-check.sh) reports two conditions, and keeps them deliberately distinct:

- `<tool> update available` means a newer version exists at the tool's update source.
- `<tool> update not in effect` means a newer copy is already installed on this host, but `PATH` still resolves an older one.

The second condition is the reason the check exists.
An update can install correctly and stay inert because an earlier `PATH` entry still holds an older copy, and a check that only asks whether a newer version is published reports that host as up to date.

The script therefore runs every copy of a watched command found on `PATH` and asks it for its own version, rather than trusting one lookup or reading a version out of a directory name.
It only reports; it never installs or updates tools, fetches into a watched git repository, or changes `PATH` or a version manager.

This section is the single owner of the canonical schema.
`bin/fm-tool-update-check.sh` owns probe mechanics, cadence, and the report record.

```json
{
  "tools": [
    {
      "name": "<label used in the report>",
      "command": "<optional bare executable name to find on PATH>",
      "version_args": ["<optional args that make it print its version, default --version>"],
      "announce_pattern": "<optional extended regex matching the tool's own update announcement>",
      "announce_args": ["<optional args for the command that carries that announcement, default version_args>"],
      "published": {
        "source": "npm",
        "package": "<npm package name, including an optional @scope/>"
      },
      "version_url": "<optional https URL whose body carries the newest published version>",
      "git": {
        "repo": "<optional absolute path to a local clone>",
        "remote": "<optional remote name, default origin>",
        "branch": "<optional branch, default the remote's own default branch>"
      }
    }
  ]
}
```

**Entry fields and probe behavior**

- Each entry needs a unique non-empty `name` and at least one of `command` or `git`; an entry may carry both.
- A `published` probe also requires `command` to supply the installed version; it can accompany `git` and an announcement on the same entry, but not `version_url`, so an entry has at most one published-version source.
- A `command` entry gives the `PATH` comparison above, and adding `announce_pattern` also reads the tool's own update announcement, which is how a tool that already reports its own updates is read rather than reimplemented.
- The announcement counts as `update available` only when the version it names is newer than the newest installed copy found; a version already installed is reported only as `update not in effect`, so one completed install does not report both in the same sweep. An announcement naming no readable version is reported as an available update as before.
- A tool does not always announce a new release on the command that prints its version: `no-mistakes --version` prints only the version, while its other commands carry the announcement.
- `announce_args` names the command to search for the announcement in that case, and it is asked only of the copy `PATH` resolves; without it the version probe's own output is searched.
- A tool whose CLI never announces its own updates (Claude Code is one) can add `version_url` to its `command` entry: one HTTPS URL without whitespace or control characters whose response body carries the newest published version.
- It is fetched read-only with curl inside the same probe bound; the first dotted numeric version in the body is compared with the newest installed copy found.
- `update available` is reported only when the published version is newer than every installed copy found; a failed request, a body without a readable version, or a missing curl is reported as that tool's own check failure.
- An `announce_pattern` that is not a usable extended regular expression stops `arm`, and during a sweep it is reported as that one tool's own check failure so one broken pattern never stops the other watched tools from being checked.
- A `git` entry reports how many commits the local clone is behind its remote branch, and stays silent when the clone is current or ahead.
- An omitted `branch` uses the remote's default branch, taken from the clone's own record of it and otherwise asked of the remote directly, so a `--single-branch` clone still resolves.

**Published release sources**

A `published` object selects one public release source:

- `{"source":"npm","package":"tasks-axi"}` reads the public npm registry version selected by the package's `latest` dist-tag; scoped names such as `@scope/tool` are supported.
- `{"source":"github","repo":"herdrdev/herdr"}` reads the `tag_name` of GitHub's latest published release for that public repository; draft releases, prereleases, and tags without a release are not selected.

`published` accepts only the fields shown for its source, and requires a package name or `owner/repo`, without a URL, query, or credentials.
It compares that source with the newest installed copy found, and reports an update only when the published version is numerically newer; a published version already installed is reported only as `update not in effect`.
For this comparison, the installed version is the first dotted number in the output of a version command that exits successfully, so `0.1.49`, `v0.8.2`, and `herdr 0.8.2` work; a version command that fails is reported as a check failure.
The published version must be a dotted numeric version with an optional leading `v`; other formats, including prerelease suffixes, produce a check failure.
Components are compared numerically, with leading zeroes and missing trailing zero components ignored.
These queries use `curl` and the existing `jq` parser, without an npm installation or a GitHub login; `curl` is required only for a `published` or `version_url` probe.
The `published` HTTP reads ignore curl configuration and send no credentials, follow no redirects, and fail within the probe bound on an unavailable source, HTTP error, or unreadable version.

All probe kinds are read-only and bounded, and a probe that cannot answer is reported as a check failure rather than assumed current.
Malformed configuration stops `arm` with a diagnostic.
During a sweep, malformed configuration is reported as a registry failure and no tools are checked.
See [`docs/examples/watched-tools.json`](../examples/watched-tools.json) for a starting point to copy into local `config/watched-tools.json`.

**Arm, edit, and disarm**

Arm the check once per home with `bin/fm-tool-update-check.sh arm`.

- That writes `state/tool-updates.check.sh` and binds its bytes with `bin/fm-check-register.sh`, so the existing watcher polls it on its normal cadence and turns its one line into a `check:` wake; no separate schedule is involved.
- Registering the check is itself a reason to watch, so the home keeps a watcher for it after the last task is torn down, and `disarm` is what ends that need.
- `bin/fm-tool-update-check.sh disarm` removes the shim, its trust binding, and the report record.

**Repeat reporting and inheritance**

- The check prints nothing when everything is current, and `state/.tool-updates` records the findings the last report was made from so the same pending update is reported once instead of on every poll.
- A changed or returning condition is reported again.
- Adding, removing, or changing a watched tool is an edit to this file and needs no code change or re-arming.
- This file is not inherited by secondmate homes, so each home watches the tools it actually depends on.

**Probe timing and limits**

| Setting | Default | Purpose |
| --- | --- | --- |
| `FM_TOOL_UPDATE_INTERVAL` | 900 seconds | Time between probes; `0` probes on every run. |
| `FM_TOOL_UPDATE_PROBE_SECS` | 5 | Bounds one probe. |
| `FM_TOOL_UPDATE_BUDGET_SECS` | 20 | Bounds a whole sweep. |

- If the budget runs out before the next tool, the sweep records its partial findings and says which check it did not reach rather than reporting the remaining tools as current.
- It waits until the next configured interval before probing again, while a final probe that finishes after the deadline still completes the sweep.
- The sweep must finish inside `FM_CHECK_TIMEOUT` (default 30), because a run the watcher kills records nothing and would then surface as a `timed out` check wake on every poll.
- So a budget larger than that timeout allows is cut down to what fits instead of being refused, and the cut is reported in the report line.
- A budget that is not a whole number from 1 to 120 is still refused outright.

## Local Claude usage warner (config/usage-warner)

`config/usage-warner` is an optional local, gitignored set of Claude usage-window thresholds.
It is opt-in and load-bearing: an unconfigured home sees no behaviour change, and [`bin/fm-usage-warner.sh`](../../bin/fm-usage-warner.sh) refuses to arm without at least one valid threshold.
This is a threshold warner, not a usage viewer - it runs the existing `quota-axi` read (`--no-credential-refresh`, never a credential-refreshing flag) and speaks only once when a configured window crosses a configured percentage, batching several crossings from the same read into one notification and re-arming once a window reads back below its threshold.
Warnings post through macOS Notification Center, the same OS-level path the away-mode wedge alarm resolves to on this platform, without sourcing or coupling to that daemon's away-mode-specific config or rate limiting.

This section is the single owner of the canonical schema.
`bin/fm-usage-warner.sh` owns read, notification, and de-dupe mechanics.

```
<window-id>:<percent>
```

One directive per non-empty, non-comment line, split on the last colon so a per-model window id such as `model:fable` still parses.
`<window-id>` is exactly the `id` field `quota-axi`'s own `--json` output already uses.
`<percent>` is how much of that window has been CONSUMED, a whole number from 1 to 100, compared against the window's own `percentUsed`: `seven_day:90` warns once the weekly window is 90% used, with 10% of it left.
See [`usage-warner.md`](../usage-warner.md) for the full behaviour reference and [`docs/examples/usage-warner`](../examples/usage-warner) for a starting point to copy into local `config/usage-warner`.

Arm the check once per home with `bin/fm-usage-warner.sh arm`.
That writes `state/usage-warner.check.sh` and binds its bytes with `bin/fm-check-register.sh`, so the existing watcher polls it on its normal cadence and turns a crossing into a `check:` wake; no separate schedule is involved.
`arm` refuses on any platform other than macOS.
`bin/fm-usage-warner.sh disarm` removes the shim, its trust binding, and the de-dupe record (`state/.usage-warner`).
