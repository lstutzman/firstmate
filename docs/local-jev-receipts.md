# Local-jev decision receipts

Every local-jev call in this repository leaves a receipt: what was asked, what local-jev answered, what the caller did with the answer, and, when it is later known, how that turned out.
The receipts let Deep Thought's replay gate rescore a new model against real decisions before each weekly training.
This document owns the `local-jev-receipt.v1` schema and what each caller records.
`bin/fm-jev-receipts.py`'s header owns the writer's mechanics, and `bin/fm-jev-receipt-lib.sh` is its bash side.

## Stream

Each machine keeps one append-only stream that every home on it shares: `${XDG_STATE_HOME:-$HOME/.local/state}/local-jev/receipts/YYYY-MM.jsonl`, one file per UTC month.
`FM_JEV_RECEIPTS_DIR` replaces the directory, and the test suite points it at a fixture directory.
Each line is one JSON object, and a line is never rewritten.
The directory is created 0700 and each file 0600, because receipts carry brief and issue text.
Receipts stay on the machine that wrote them: they are never committed, and never leave the fleet machines.

A receipt write never changes its caller's result or exit code.
A write that fails prints one `local-jev receipt: not written (<why>)` line on stderr, and the caller carries on.

## Shared fields

Every line carries these fields; the writer fills them, and a `decision` or `outcome` passes its call's `receipt_id`:

| Field | Meaning |
|---|---|
| `schema` | Always `local-jev-receipt.v1` |
| `kind` | `call`, `decision` or `outcome` |
| `receipt_id` | Minted when the call is made; a `decision` or `outcome` for that call repeats it |
| `ts` | When the line was written, ISO 8601 UTC with milliseconds |
| `host` | The writing machine's short host name |
| `home` | The writing Firstmate home (`FM_HOME`), or `null` |

The reader ignores fields it does not know, so a caller may add context such as `project` or `officer`.

## kind=call

One `call` line is written for each question sent to local-jev, whether it answers or fails.

| Field | Meaning |
|---|---|
| `caller` | The stable caller name, from the table below |
| `subject` | What the question was about: a task id, or a finding's fingerprint |
| `route` | How the question was sent and its question type, for example `typesafe:systemone/choice` or `jev.py:noul` |
| `model` | The model the caller asked for, or `null` when the caller lets local-jev choose |
| `served_adapter` | The model or adapter local-jev reports serving the answer, or `null` when it reports none; `jev.py` callers always record `null`, because `jev.py` reports none |
| `request` | `{state, question, criteria}` exactly as sent: `criteria` maps each option key to its description |
| `input_hash` | The sha256 of `request` serialised as compact, key-sorted UTF-8 JSON |
| `pick` | The option key the caller's floor accepts, or `abstain` when no option clears it; `null` when the call failed |
| `confidence` | The confidence of the answer, or `null` |
| `probabilities` | Each option key's probability, or `null` |
| `floor` | The confidence floor the caller applied |
| `latency_ms` | How long the call took |
| `error` | Why the call failed or timed out, else `null` |

A yes/no (`noul`) question has the option keys `true` and `false`.
Its `criteria` values are the descriptions sent with `--true` and `--false`, or `null` when none were sent.
Its `probabilities` are the answer's probability for `true` and one minus it for `false`, and its `confidence` is the larger of the two.

## kind=decision

One `decision` line records what the caller did with a call, under the call's `receipt_id`.
A caller that skipped local-jev it would otherwise have asked, such as after its call cap, writes a `decision` line with a fresh `receipt_id` and no `call`.

| Field | Meaning |
|---|---|
| `decision` | The option key actually used, or `null` when no option was used (the work stayed with the caller's default) |
| `source` | Where the decision came from: `model`, `fallback:<name>`, `timeout`, `abstain`, `rule` or `heuristic` |
| `overridden` | `true` when firstmate departed from a model pick it was given |
| `override_by` | Who overrode it, or `null` |
| `corrected_decision` | When overridden, the option key that matches what was used instead, or `null` when none matches |

`source` is `model` when the decision is local-jev's own pick, `abstain` when local-jev's answer cleared no floor, `timeout` when the call timed out, `rule` when a host rule decided (a runner-up rule or a hold check), and `fallback:<name>` when another source decided without local-jev.
A fallback is never counted as a local-jev pick.

## kind=outcome

An `outcome` line is written later, when the caller learns how the decision turned out, under the call's `receipt_id`.

| Field | Meaning |
|---|---|
| `misroute` | `true` when the decision is later found to be wrong |
| `corrected_decision` | The option key that would have been right, or `null` |
| `outcome`, `note` | A short result and a free note |

## Replay cases

A replay case is a call whose decision `source` is `model` and that was overridden, or later misrouted, with a `corrected_decision` that is a key of the call's `criteria`.
Fallback, abstain and timeout decisions are counted apart and never replayed.

## Callers

| Caller | Where | Call | Decision | Outcome |
|---|---|---|---|---|
| `dispatch-resolve` | `bin/fm-dispatch-resolve.sh` | One `choice` over the dispatch rules, written once the request was sent | `bin/fm-spawn.sh` at launch | `bin/fm-teardown.sh` at cleanup |
| `officer-duplicate` | `Jev.same` in `bin/fm-officer-linear.py`, for every officer's duplicate and near-match check | One `noul` per candidate item, floor 0.85 | The filer, right after the call | Not written |
| `officer-pattern` | `update_patterns` in `bin/fm-officer-linear.py` | One `noul` per candidate pattern, floor 0.85 | Right after the call | Not written |
| `progress-place` | `LocalJev.place` in `bin/fm-officer-progress.py` | One `choice` over the offices' roles, floor 0.7 | After every check on the ask | Not written |
| `progress-scope`, `progress-hold` | `LocalJev.noul` in `bin/fm-officer-progress.py` | One `noul` per check, at its own floor | Right after the call | Not written |

**Dispatch.**
The resolver's task record (`data/<id>/dispatch-resolution.json`) carries the call's `receipt_id`, the host's `pick` and its `pick_source`, so `fm-spawn.sh` can write the decision; a run that sent nothing (off, or an error before the request) writes no receipt.
The call's `pick` is the rule the confidence floors accept: the model's own choice, a runner-up rule that cleared its own floor (`pick_source` `runner-up`), or `abstain` when no option cleared its floor; `raw_pick` keeps the model's own choice, and `pick_source` `default-floor` says a quota floor then sent the task to the default rule.
At launch, a `clear` selection the launch follows is the decision with `source` `model`, `rule` for a runner-up, or decision `default` with `source` `fallback:default-rule` for a quota floor's default.
A launch that departs from a `clear` selection sets `profile_override` and keeps `override_reason` from `--dispatch-override`.
It is `overridden` by `firstmate` only when the profiles of the rule acted on do not hold the launched profile; a launch that one of that rule's profiles holds keeps that rule as the `decision`, even when another rule or `default` holds the same profile too.
`corrected_decision` of an override is the one rule (or `default`) whose profiles hold the launched profile, or `null` when no rule or several rules hold it.
Another profile of the same rule is not an override, because local-jev chooses only the rule.
Any other status leaves the choice to firstmate: `abstain` for `ambiguous`, `timeout` for a request that timed out, and `fallback:firstmate` for `escalate` or another error.
The task's record keeps the receipt id as `dispatch_receipt=`, and teardown writes the outcome: `landed` when its landed-work gate passed (which does not by itself prove a merge; `pr` names the pull request), `reported` for a scout, or `cancelled` for a forced cleanup.
Teardown cannot tell a misroute, so its `misroute` is always `false`; a cleanup that a later session start finishes writes no outcome.

**Officers.**
Every decision an officer makes is `source` `model`, `abstain`, `rule`, `timeout` or `fallback:<name>`, and an officer never overrides local-jev, so its `overridden` is always `false`.
A duplicate check that cannot ask local-jev uses the fingerprint alone, recorded as decision `false` with `source` `timeout` or `fallback:<why>`.
A home with no local-jev installed records nothing.
The officers do not yet learn whether a duplicate or a placement was later confirmed or reversed, so they write no outcome lines.
