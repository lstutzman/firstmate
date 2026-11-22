# Dispatch

Part of the [configuration reference](../configuration.md).

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that firstmate reads before dispatching a crewmate or scout.
Firstmate chooses the best matching rule with judgment; shell scripts do not match the natural-language rules.
Firstmate resolves the rule's profile object or array under `AGENTS.md` section 4 and `quota-array-dispatch`, then passes only concrete `--harness`, `--model`, and `--effort` flags to `fm-spawn.sh`.

**Spawn requirements**

- When the file exists, `fm-spawn.sh` enforces that contract by refusing crewmate and scout spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
- Batch spawns satisfy the same requirement with a shared `--harness`.
- Secondmate spawns are exempt and resolve through `config/secondmate-harness` using the registered mate's id; see [Choose the secondmate harness](harnesses.md#choose-the-secondmate-harness) for pin precedence and legacy parsing.

**Contract owners**

This section is the single owner of the canonical schema and its per-field semantics.
`AGENTS.md` section 4 owns the always-loaded dispatch intake boundary, and `quota-array-dispatch` owns the completion-aware profile-array selection procedure.

```json
{
  "preferred_provider": "<optional quota-axi provider family to spend first>",
  "shared_quota": false,
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "approval": "captain",
      "min_confidence": 0.85,
      "floor": { "scope": "<quota-axi scope>", "min_percent": 20, "provider": "<quota-axi provider>" },
      "use": [
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max|ultra, optional>", "provider": "<optional quota-axi provider>", "quota_scope": "<optional quota-axi scope>", "floor": { "scope": "<quota-axi scope>", "min_percent": 50 } }
      ],
      "why": "<optional rationale that helps firstmate choose>"
    }
  ],
  "default": [
    { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" }
  ]
}
```

**Required and optional fields**

| Field | Requirement |
| --- | --- |
| `rules` | May be absent or empty for a default-only configuration. |
| Rule `when` and `use` | Required for each rule. |
| `use` and optional top-level `default` | Accept one profile object or a non-empty array of profile objects; the single-object form remains fully backward-compatible. |
| Profile `harness` | Required in every profile. |
| Profile `model` and `effort`; rule `why` | Optional. |
| Top-level `preferred_provider` | Optional provider-family preference, applied after eligibility checks under `quota-array-dispatch`. |
| Top-level `shared_quota` | Optional; see "Shared-quota opt-out" below. |

**Preferred provider**

`preferred_provider` accepts a provider ID matching `^[a-z0-9]+(-[a-z0-9]+)*\z`, using the same vocabulary as profile `provider`.
For example, `"preferred_provider": "codex"` prefers the OpenAI subscription family across its eligible accounts, not one account or harness.
Both bootstrap and the enabled resolver reject malformed values, including null, empty strings, uppercase letters, and whitespace.
Bootstrap validates this field even without a resolver key because the agent-owned intake also honors it.
An absent field preserves the existing routing behavior.
The [profile-array procedure](../../.agents/skills/quota-array-dispatch/SKILL.md#rank-by-spendpriority) owns family preference, uncertainty, and fallback after the existing gates.

**Shared-quota opt-out**

An optional top-level `"shared_quota": true` declares this home draws every provider's usage from one single shared budget, such as one workplace AI spend line, so per-provider quota rows do not describe what is left.
With it set, typed dispatch resolution makes no `quota-axi` call, applies no quota floor or runway gate, ranks nothing by `spendPriority`, and resolves the matched rule's `use` profiles in declared order; every candidate line still prints, stating quota ranking is off by home declaration.
`preferred_provider` is a separate home preference, not a quota signal, so it still applies: `preferred_provider` still narrows the pool; declared order then picks within it.
Firstmate's own `quota-array-dispatch` intake honors the same declaration.
Without the setting, or with `"shared_quota": false`, behavior is unchanged.
The declared value must be a boolean; anything else is an actionable configuration error reported like any other malformed rule.

**Fields applied only by typed resolution**

Rule `approval`, `min_confidence`, and `floor`, and profile `provider`, `quota_scope`, and `floor` are optional declarations that only [typed dispatch resolution](#typed-dispatch-resolution-env-fm_dispatch_provider-fm_dispatch_model) applies in code; without that opt-in they are inert, and firstmate's own intake reads them as ordinary hints.
The resolver supplies the fixed neutral Choice option `No listed rule applies to this task.` for work that matches no listed rule.

- `approval` accepts only `"captain"` and means a task the rule matches is never dispatched from the tool's answer alone.

`min_confidence` is a number from 0 through 1.
The rule's own probability in the answer must reach it, replacing the resolver's global 0.6 floor on the answer's confidence.
Set it high when a wrong pick is costly and low when the rule is a safe runner-up.

**Rule quota floors**

- A rule `floor` names the quota-axi `provider` and `scope` whose `effectivePercentRemaining` must be at least `min_percent` for the rule's profiles to apply.
- A provider-only rule floor on an expanded provider binds to its `default` account row.
- An absent or unknown row or unmeasured provider makes the floor unverifiable and escalates without authorizing default routing.
- A known percentage below the floor makes the tool resolve among `default` profiles instead.

**Provider identifiers and mappings**

A profile `provider` optionally names the quota-axi provider family whose rows apply to that profile; when present, profile and rule-floor provider IDs must match the strict whole-string pattern `^[a-z0-9]+(-[a-z0-9]+)*\z`.
Bootstrap's resolver-only validation gate is described under "Validation and diagnostics" below.

Typed resolution additively recognizes `gemini` because AGENTS.md section 4 verifies it for crewmate and scout dispatch.

| Harness | Provider declaration on the opted-in resolver path |
| --- | --- |
| `claude`, `codex`, `grok`, `kimi`, `cursor`, `agy`, `muse` | The resolver has an authoritative single-provider mapping. |
| Every other verified harness | Must declare `provider` explicitly; this includes multi-provider `pi`, `pi-signed`, `omp`, and `opencode`, and unmapped `gemini`, `rovo`, `devin`, `commandcode`, `cortex`, and `kiro`; omission is an actionable configuration error before any request. |

This single-provider table is separate from the frozen legacy mapping used by `fm-quota-choose.sh`, so additions cannot alter no-key routing.

**Profile quota scope**

- A profile `quota_scope` is a non-empty string naming one quota-axi row of that profile's provider and matched account, such as an Antigravity tier scope (`gemini` or `claude_gpt`) that no model-name rule can bind.
- The named row joins the candidate's applicable rows by exact scope match, so a known zero or `exhausted_now` row makes the candidate ineligible and a healthy row ranks it.
- A named row absent from the snapshot leaves the candidate eligible but unranked and is reported as disclosed uncertainty, never as a block.
- Firstmate never derives the scope from a model name and never falls back to a profile or rule `floor` scope; a profile without `quota_scope` resolves exactly as before.

**Profile quota floors**

- A profile `floor` contains only `scope` and `min_percent`, always uses that profile's provider and matched account, and makes that one candidate ineligible below `min_percent` on the named scope.
- An absent or unknown named row also makes the candidate unrankable and is reported as an unverifiable floor, not as a known shortfall.

**Model, effort, and fallback behavior**

- `ultra` is native-only: the model-aware validation contract and launch mapping are owned by `bin/fm-harness.sh validate-native-effort` and `bin/fm-spawn.sh` respectively.
- Codex `max` is valid when the profile selects `gpt-5.6-luna`, whose installed catalog entry supports that reasoning level.
- On pane backends, an omitted model or effort means the selected harness uses its own default for that axis; [T3 selection](../t3code-backend.md#provider-instances-and-models) owns server-backed defaults.
- OpenCode receives the effort as its default `build` agent's `variant`, keyed to the resolved model, inside the `OPENCODE_CONFIG_CONTENT` JSON its launch already writes (the per-model reasoning-effort field of the config schema, verified on opencode 1.18.32); with no model resolved, the effort is recorded in task metadata but omitted from the launch.
- Every profile array is an implicit quota-aware choice resolved through `quota-array-dispatch`.
- If no dispatch rule fits, firstmate resolves `default` through the same object-or-array path before falling back to `config/crew-harness`.
- On pane backends, except for `ultra` under the native-effort contract above, an effort value the chosen harness does not accept is recorded as `effort=` in task meta for traceability but omitted from the launch flags.
  For T3 Code, follow the [catalog validation contract](../t3code-backend.md#provider-instances-and-models).
- Bootstrap reports unsupported harness/model/effort combinations as a `CREW_DISPATCH` diagnostic when they are visible in the file.

See [`docs/examples/crew-dispatch.json`](../examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`; its Pi default declares the `claude` provider required for typed resolution of that Anthropic model.

**Validation and diagnostics**

- When the file exists, bootstrap validates it with `jq`.
- Valid files stay silent by default; with `FM_BOOTSTRAP_VERBOSE_FACTS=1`, bootstrap emits `BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json`, one `BOOTSTRAP_INFO:` fact per rule, and one fact for the optional default profile set.
- Malformed JSON, malformed rules, an empty or malformed profile array, a malformed `preferred_provider`, an unverified harness, or an effort value unsupported by that harness is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`.
- Bootstrap enables resolver-only checks for `approval`, `min_confidence`, `floor`, and present `provider` declarations when `TYPESAFE_API_KEY` is non-empty in the environment or the home's `.env`, when the home's valid `config/dispatch-credential-sources.json` names a `typesafe` source, or when a non-default typesafe base URL or a `config/typesafe-token-file` is configured, regardless of `FM_DISPATCH_PROVIDER`.
  Bootstrap only checks that declaration; it never reads the key or runs the source's tool.
  An OpenRouter key or OpenRouter declaration alone does not enable these bootstrap checks; the resolver validates those declarations itself before any request.
  Without a typesafe key, declared typesafe source, custom base URL, or token file, bootstrap retains its pre-existing verified-harness baseline.
- Missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
- While the file remains present, no crewmate or scout spawn may proceed without an explicit resolved harness; malformed configuration must be reported and corrected rather than selected around.

**Inheritance**

Secondmate homes inherit this file from the primary, so a secondmate's own crewmates apply the same dispatch profile behavior.

## Typed dispatch resolution (.env FM_DISPATCH_PROVIDER, FM_DISPATCH_MODEL)

`bin/fm-dispatch-resolve.sh` resolves one concrete crewmate or scout profile from a written brief through typesafe.ai, OpenRouter, any System One-compatible host, or OpenAI, so the rule match that firstmate otherwise reasons out in its own context becomes one short tool turn.
`FM_DISPATCH_PROVIDER` selects `typesafe`, `openrouter`, `systemone`, or `openai`, and `FM_DISPATCH_MODEL` selects the model.
Each setting comes from the calling environment or the home's gitignored `.env` through `bin/fm-env-lib.sh`; a non-empty environment value wins.
OpenRouter, `systemone`, and OpenAI each require their explicit `FM_DISPATCH_PROVIDER` value and a non-empty `FM_DISPATCH_MODEL`; an omitted model is an actionable configuration error, and the presence of a provider's key never selects that provider by itself.
`systemone` also requires `FM_DISPATCH_BASE_URL`, an `http://` or `https://` base such as a local llama.cpp server or a hosted System One-compatible service, and posts to `<base>/v1/systemone`; a missing or scheme-less base URL is an actionable configuration error.
With no provider setting, the original typesafe.ai behavior is unchanged: `jev-latest` is used when `TYPESAFE_API_KEY` is available, `FM_DISPATCH_MODEL` is ignored, and the resolver is off when no key is available and no `typesafe` credential source is declared.
Explicit `FM_DISPATCH_PROVIDER=typesafe` also uses `jev-latest` when no model is set.
The selected provider needs a non-empty key from the environment, else `.env`, else, for `typesafe` and `openrouter` only, the credential source the home declares for that provider; `systemone` is the exception, where an absent `FM_DISPATCH_API_KEY` means the request carries no `Authorization` header.

A configured non-default base URL or a configured `config/typesafe-token-file` (next sections) is also an on switch, so a local System One needs no key.

Off means one `dispatch-resolve: off` line on stderr, nothing on stdout, exit 0, and no network call, so firstmate dispatches exactly as it does without the tool.
A declared credential source that cannot supply its key is not off; see "Credential source declaration" below.
This section is the single owner of the tool's operator contract; the script header owns its exact flags and output lines, and "Crew dispatch profiles" above owns the declared top-level, rule, and profile fields it applies.

Rules come only from the effective home's `config/crew-dispatch.json`; `FM_CONFIG_OVERRIDE` selects the config directory for tests and specialized setup like the other scripts.

```sh
bin/fm-dispatch-resolve.sh data/<id>/brief.md --project <name>        # TOON block on stdout
```

**Base URL (config/typesafe-base-url)**

The resolver posts to `<base URL>/v1/systemone`, with the base URL defaulting to `https://api.typesafe.ai`.
To use a self-hosted System One, such as a local Jev, put one URL in the optional local, gitignored `config/typesafe-base-url`, or set `TYPESAFE_BASE_URL` in the calling environment, which wins over the file.
The file's first non-blank line not beginning with `#` is the URL; like `config/crew-dispatch.json` it is inherited into secondmate homes.

```text
# local Jev
http://jev.local:8800
```

Only `http://` and `https://` URLs without whitespace are accepted, and trailing slashes are trimmed; anything else is an exit 2 configuration error before any call, and bootstrap reports it as `CREW_DISPATCH: invalid typesafe base URL - ...` when `config/crew-dispatch.json` exists.
With a non-default base URL configured the resolver is on even without `TYPESAFE_API_KEY`; the key is sent only to the default `https://api.typesafe.ai`, never to a custom URL, so without a token file (below) the request sends no `Authorization` header.
An unset URL changes nothing: the default endpoint, and off without a key.

**Model and token file (config/typesafe-model, config/typesafe-token-file)**

A local System One can need its own model name and bearer token.
The optional local, gitignored `config/typesafe-model` holds the model name on its first non-blank line not beginning with `#`; unset keeps `jev-latest`.
The optional `config/typesafe-token-file` holds, on its first such line, the path of a file whose contents are the bearer token (a leading `~/` expands to `HOME`).
The token is read at call time, sent only on the fd-fed `Authorization` header, and never printed or logged.
A configured token file wins over `TYPESAFE_API_KEY` from the environment or `.env`, at the default or a custom base URL; the key is sent only to the default base URL.
A configured token file makes the resolver and the bootstrap rule check active, like a custom URL; one that is unreadable or empty is an exit 2 configuration error naming the path.
A custom URL with no key and no token file stays keyless.
Both files are inherited into secondmate homes like `config/typesafe-base-url`.

**When firstmate invokes the resolver**

Firstmate invokes the resolve path directly after writing the brief, without a preflight; the absent-key off line is handled exactly like every other non-clear outcome.

**What the model receives**

When on and at least one rule exists, the tool sends the project name and the brief's task-specific text as state and asks one Choice question whose options are every rule's `when` plus the fixed neutral option for no matching rule; the model never sees quota, catalogs, `why`, `use`, approvals, or confidence floors.
OpenRouter's Decisions API and a `systemone` host accept the same Choice request shape and return the same typed answer, including confidence and a probability per option.
For OpenAI's Decisions API the resolver rewrites that request into OpenAI's shape - the state as JSON text `input` and one `choice` question named `rule` whose `choices` are the same options - and maps the answer's per-option probability array back; a refusal, a missing or duplicated rule answer, or duplicated option values is rejected as malformed.
Every provider then uses the same response validation and post-model gates.
The task-specific text is the brief's `## Captain's intent` and `## Firstmate spec` sections under `# Task` that `bin/fm-brief.sh` scaffolds, read by the same parser that feeds `fm-spawn.sh` validation and the no-mistakes `--intent` contract; a brief with neither section is sent whole.

When the sections are sent from a scout brief, the line `Brief kind: scout (report only)` comes first, taken from the scaffold's scout contract line; ship briefs and briefs sent whole get no kind line.
A ship brief's delivery mode is deliberately not sent, because in live runs naming it pushed a routine ship brief toward the hardest tier (see [the verification record](../verification/dispatch-resolve.md)).

The scaffold's standard setup, rules, and definition-of-done text is the same in every brief, so leaving it out keeps its safety language from reading as a signal about the task.

**Never-send list (config/dispatch-never-send)**

The optional local, gitignored `config/dispatch-never-send` keeps values you name from ever leaving the machine in a resolver request.
It has no default entries, and an absent file changes nothing.
Like `config/crew-dispatch.json`, it is inherited into secondmate homes, so a secondmate's resolver withholds the same values.

Each non-blank line not beginning with `#` is one literal value, matched case-insensitively.
Every entry is trimmed of surrounding whitespace, and any run of whitespace, in the entry or in the checked text, counts as one space, so a value the brief wraps across lines still matches.

```text
# Client names
Example Client Ltd
```

Before the request is sent, the endpoint URL and every string in the final provider-specific request body are checked, including strings inside JSON text such as OpenAI's `input`: the selected model, the project name, the task text, each rule's `when`, and the fixed question text.
A match stops the request: the resolver behaves exactly as when it is off, printing one `dispatch-resolve: off (...; nothing sent)` line on stderr and nothing on stdout, making no network or quota call, and exiting 0, so firstmate dispatches through its existing intake.
A list that is present but not a readable regular file also stops the request the same way rather than sending unchecked text.
That one diagnostic names the list line number at most and never prints the listed value or the matching text.

**Missing or invalid rules**

An absent rules file, a default-only file, or `rules: []` returns the non-clear reason `no rules to match` without a model or quota request, leaving firstmate's existing routing in control; an existing but unreadable or malformed rules file, including a broken symlink, remains an actionable exit 2 configuration error.

**Checks performed after the answer**

After the answer, code applies all remaining checks and ranking:

- The confidence floor and the matched rule's `approval` and `floor`.
- Each candidate's `provider`, `quota_scope`, and `floor`.
- Every applicable account-wide and model/product row from one `quota-axi --json` snapshot.
- The optional `preferred_provider` restriction under the [profile-array procedure](../../.agents/skills/quota-array-dispatch/SKILL.md#rank-by-spendpriority).
- The numeric `spendPriority` argmax within that candidate pool, using each candidate's limiting row.
- With the home's `shared_quota: true` declaration ("Crew dispatch profiles"), the quota snapshot, floors, runway gates, and `spendPriority` argmax are skipped entirely; resolution is the matched rule's declared profile order (`preferred_provider` still narrows the pool; declared order then picks within it).

The resolver prints its preferred-family decision while retaining evidence for every candidate.
If preferred candidates remain eligible but none is rankable, it escalates instead of selecting another family.
It never introduces candidates outside the matched rule or its existing default fallback.

The [shared quota library](../../bin/fm-quota-axi-lib.sh) accepts schema 5 and schema 6 and implements the [account-matching contract](../../.agents/skills/quota-array-dispatch/SKILL.md#1-eligibility).

- An expanded provider with no matching account row leaves the candidate eligible but unranked.
- Known applicable rows from a provider with partial quota semantics remain rankable; rows whose own status is not known remain unrankable.

**Pooled Claude quota (config/cpa-usage-host)**

When Claude traffic is pooled through CLIProxyAPI, `quota-axi` on a host without the Claude keychain reports the `claude` provider as unknown, which leaves every Claude candidate unranked.
The optional local, gitignored `config/cpa-usage-host` names, on its first non-blank line not beginning with `#`, the ssh host that runs the read-only `cpa-usage-axi`, or `local` to run it on this host.
A value equal to this machine's own short host name, compared case-insensitively, also runs it here without ssh, so a secondmate home that inherits the file on the usage host itself still reads the pool.

```text
# CLIProxyAPI usage host
slartibartfast
```

With the file present, one `cpa-usage-axi accounts` read, bounded to `FM_CPA_USAGE_TIMEOUT` seconds overall (default 10; a blank, non-numeric, or zero value resets to 10), replaces the snapshot's `claude` entry with one known `all_models` row whose remaining percent is the mean, over every Claude account, of each account's remaining share of its tighter 5-hour or 7-day window.
The row's `spendPriority` is that same mean as a fraction between 0 and 1, on the magnitude of `quota-axi`'s own scalar, so a Claude candidate ranks against other providers rather than above them.
A blank window, which `cpa-usage-axi` prints when none is active, counts as nothing used.
Any other window that is not a plain decimal number (including `nan` and `infinity`), a row that does not match the table's columns, or output with no `accounts` table makes the whole read malformed.
The row's runway is `exhausted_now` only when every account is exhausted, which makes Claude candidates ineligible.
A failed, timed-out (including a bound that had to KILL the read), or malformed read, a read with no Claude account rows, or a value that is not a plain host name, keeps `quota-axi`'s own `claude` entry and prints one `dispatch-resolve: cpa-usage pool unavailable` line on stderr.
An absent file changes nothing and makes no read.
Every Claude candidate binds to the same pooled row, so two Claude candidates in one rule tie and escalate unless their profile floors or other rows separate them.
While the pool is in effect that row is the only Claude evidence, so a rule or profile floor on a `model:` scope for Claude is unverifiable: the rule escalates and the profile stays eligible but unranked.
The file is inherited into secondmate homes like `config/typesafe-base-url`.

**Confidence and fallback rules**

- A rule that declares `min_confidence` is checked against that rule's own probability, whether it is the picked option or a runner-up, so a runner-up never needs weaker support than it would as the pick.
- A picked rule without `min_confidence`, and the neutral option, keep the global 0.6 floor on the answer's confidence exactly as before, so a file with no declared floors behaves as it did.

When the picked rule declares its own floor but its probability falls below it, the tool checks the other options:

1. Find the most probable other option that clears its own floor: the rule's `min_confidence`, or 0.6 otherwise.
2. Print a `fallback:` line naming both floors and resolve that rule as though it had been picked.

No qualifying option, or two equally probable qualifying options, produces `ambiguous`.

**Candidate eligibility and evidence**

- Any applicable `exhausted_now` row or known zero bound makes that candidate ineligible, and a known profile-floor shortfall does the same before unrelated quota uncertainty is considered.
- Missing or nonnumeric `spendPriority` evidence is never ranked, and every candidate is printed beside its evidence or the reason it was not rankable, including on ambiguous and approval-gated outcomes that emit no profile.
- On the opted-in path, duplicate concrete profiles with the same harness, model, and effort inside one rule or the default array are configuration errors rather than ties.

**Outcomes and exit status**

| Result | Meaning |
| --- | --- |
| `clear` | A `profile:` line ready for `fm-spawn.sh`. |
| `ambiguous` | Confidence below the floor with no runner-up taken. |
| `escalate` | An approval-gated rule, unverifiable rule floor, nothing rankable, or a genuine tie. |
| `error` | API, network, malformed response metadata, rendering, quota-axi failure, or a declared credential source that cannot supply its key. |

Every result above exits 0.

- Response probabilities must contain exactly every offered choice, use numeric values from 0 through 1, and sum to approximately 1 within 0.01.
- Only a usage or configuration error exits 2: an unreadable brief, an existing but unreadable or malformed canonical rules file, an unreadable or invalid credential source declaration, a missing `jq`, an unknown provider, a non-typesafe provider without a model, or `systemone` without a valid base URL, each reported and never selected around.
- Missing `curl` is a normal structured `error` outcome with exit 0 so firstmate uses today's routing.

**Firstmate retains the dispatch decision**

The tool never replaces firstmate's judgment, `quota-array-dispatch`, the captain-approval gate, or `fm-spawn.sh` validation; `AGENTS.md` section 4 owns what firstmate does with each outcome.
By accepted design, a `clear` result does not enforce catalog/authentication, reasoning-class, or completion-runway gates.
Firstmate still applies those gates before dispatch, including when `preferred_provider` is present.
Explicit captain overrides retain precedence over the resolver's suggestion.

Firstmate passes its profile line unless it states a reason to override, such as the brief's reasoning class or an eligible-unranked-candidate note; every non-clear result returns to the full existing intake.

**Task record (data/<id>/dispatch-resolution.json)**

For a brief at `data/<id>/brief.md`, or `<FM_DATA_OVERRIDE>/<id>/brief.md` when that override is set, each run first removes that task's `dispatch-resolution.json`, so a decision never outlives a later run.
Every outcome that exits 0, including off, then writes one JSON object there: `task` (the `<id>`), `status` (`clear`, `ambiguous`, `escalate`, `error`, or `off`), and `profile`.
On `clear`, `profile` holds `harness`, `model`, and `effort`, each `null` when the chosen profile leaves it unset; otherwise `profile` is `null`.
A usage or configuration error (exit 2) writes no record.
`fm-spawn.sh` reads this record as the task's decision, as "Per-launch overrides and inherited defaults" describes.
A run that sent its request also names its local-jev call receipt there (`receipt_id`, `pick`, `pick_source`), which `fm-spawn.sh` and `fm-teardown.sh` follow with decision and outcome receipts; [local-jev receipts](../local-jev-receipts.md) owns those fields.

**Credential source declaration (config/dispatch-credential-sources.json)**

The optional local, gitignored `config/dispatch-credential-sources.json` tells the resolver where a provider's key lives when neither the environment nor `.env` supplies one.
It names a source and never holds a key.
It is read from the effective config directory, which is `FM_CONFIG_OVERRIDE` when set and `$FM_HOME/config` otherwise, so each home reads only its own file.
It is not among the settings `bin/fm-config-inherit-lib.sh` propagates, so a secondmate home that wants a declared source keeps its own file.
A home without the file behaves exactly as it did before the file existed.
It covers the `typesafe` and `openrouter` keys only; the `systemone` and OpenAI keys still come from the environment or `.env`.

The file is one JSON object keyed by provider, `typesafe` or `openrouter`, and each value says where that provider's key is:

```json
{
  "typesafe": { "source": "macos-keychain", "service": "typesafe-api-key", "account": "me" }
}
```

`source` is required and names the adapter, and `macos-keychain` is the first.
It requires `service`, accepts an optional `account`, and reads that generic-password item with `security find-generic-password -s <service> [-a <account>] -w`.
Store the item with `security add-generic-password -s <service> [-a <account>] -w`, which prompts for the key and lets `security` read it back without an access dialog.
Only the service and account reach `security`'s argument list, and the key comes back on a pipe.
No other field is accepted, so the file has nowhere to put a key.
`bin/fm-credential-source-lib.sh` owns the schema and the adapters, so a further source adds an adapter there rather than a special case in the resolver.

The resolver reads the file only after the environment and `.env` have supplied no key for the selected provider, and it uses only that provider's entry.
A declaration for one provider never feeds another provider and never selects a provider.
Three outcomes stay distinct:

- **Off.** No entry for the selected provider and no key keeps today's behavior: the `dispatch-resolve: off` line, nothing on stdout, and exit 0.
- **Configuration error.** An unreadable file, malformed JSON, an unknown provider, an unknown or missing field, or a value that is not a plain non-empty string exits 2 with one line that names the problem.
  The check covers the whole file, so an invalid entry for a provider that is not selected also exits 2.
  The line names providers and fields and never prints a declared value.
- **Unavailable source.** An entry whose source this host cannot run, or that yields no key, ends as the `error` outcome with exit 0 and a reason ending `nothing sent`, and makes no network or quota call.
  The reason says whether the host cannot run the source, the source holds no readable key, or it did not answer in time, and it never relays the tool's own output.
  A source that does not answer within 5 seconds ends the same way, so an unanswered Keychain access prompt cannot hold an intake.

A configuration installer can check a source before it writes anything:

```sh
bin/fm-dispatch-resolve.sh --supports-credential-source macos-keychain
```

The probe prints `supported` and exits 0, or prints `unsupported` and exits 1, for a source name on the host it runs on.
`unsupported` covers an unknown name, a host the adapter does not run on, and a missing tool.
The probe reads no declaration and no credential and runs no credential tool.
An installer should treat any status other than 0 as a refusal, because a resolver that predates the probe rejects the flag with exit 2.

**Key handling and provider settings**

- The resolver copies every environment-provided key into a non-exported private variable and unsets `TYPESAFE_API_KEY`, `OPENROUTER_API_KEY`, `OPENAI_API_KEY`, and `FM_DISPATCH_API_KEY` before launching child processes; bootstrap also protects the typesafe key.
- A key read from a declared source is captured into the same private variable, so it is never exported either.
- The resolver sends only the selected key to `curl` as a header read from a file descriptor, never on argv, and never prints, logs, or writes any key.
- The typesafe.ai endpoint defaults to `https://api.typesafe.ai/v1/systemone` and its model to `jev-latest`, both overridable as described above (`TYPESAFE_BASE_URL`, `config/typesafe-base-url`, `config/typesafe-model`, `config/typesafe-token-file`), the OpenRouter endpoint is `https://openrouter.ai/api/alpha/decisions`, the OpenAI endpoint is `https://api.openai.com/v1/decisions`, and the `systemone` endpoint is `<FM_DISPATCH_BASE_URL>/v1/systemone`.
- The pooled Claude quota read that `config/cpa-usage-host` enables is bounded by `FM_CPA_USAGE_TIMEOUT` seconds (default 10).
- The default confidence floor remains 0.6; request timeouts are 5 seconds for typesafe.ai and 10 seconds for OpenRouter, `systemone`, and OpenAI.
- A CPU-only local `systemone` host may not answer within its 10-second timeout; that is an ordinary `error` outcome, and firstmate keeps its existing intake.

The recommended OpenRouter model is `typesafe/jev-1.13` because it is built for fast typed choices and supplies native per-option probabilities without generated text.
The dated model catalog observation is recorded in [dispatch verification](../verification/dispatch-resolve.md#the-api-the-tool-depends-on).
The resolver never chooses this model automatically; use these settings in the calling environment or the home's `.env`:

```dotenv
FM_DISPATCH_PROVIDER=openrouter
FM_DISPATCH_MODEL=typesafe/jev-1.13
```

A `systemone` or OpenAI setup names its model the same way; the resolver never picks one for them:

```dotenv
FM_DISPATCH_PROVIDER=systemone
FM_DISPATCH_MODEL=<model the host serves>
FM_DISPATCH_BASE_URL=http://127.0.0.1:8080
```

The live rule-match evidence is recorded in [`verification/dispatch-resolve.md`](../verification/dispatch-resolve.md).
