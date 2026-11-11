# Secret scan

This repository is public, so no secret may ever reach it.
Three layers run the same scan, [`bin/fm-secret-scan.sh`](../bin/fm-secret-scan.sh), with the reviewed allowlist in [`.gitleaks.toml`](../.gitleaks.toml).
The script header owns modes, exit codes, and the redaction rule; this page owns the policy.

## Layers

- CI runs the scan in the `Repo invariants` job on every pull request and main push, over only the commits the event adds.
  A finding fails that job, which fails `Full suite`, and `Repo invariants` is in [`.github/required-checks.list`](../.github/required-checks.list), so the merge gate refuses it.
- The no-mistakes lint step runs `bin/fm-secret-scan.sh --branch` first, over the commits origin does not have yet.
  The pipeline order is intent, rebase, review, test, document, lint, push, pr, ci, so a secret in the branch stops at lint before the push step.
  A commit the ci step adds later, while it repairs a failed check, is pushed after lint and is covered only by CI and the task hook below.
- `bin/fm-spawn.sh` installs a pre-push hook in every task worktree of this repository (through `bin/fm-git-strip-ai-trailers.sh install --secret-scan`) that refuses a push when any pushed commit adds a finding.
  The hook runs beside the forge=external push guard, then chains to the repository's own pre-push hook.
- The `Evidence secret scan` workflow reads the orphan `no-mistakes/evidence` branch daily through [`bin/fm-evidence-branch-scan.sh`](../bin/fm-evidence-branch-scan.sh), because no workflow can run on that branch.
  It is a backstop (see [Evidence](#evidence)) and can only report: it turns red after a secret has already been published.

Every layer needs gitleaks at the version pinned in the script; `bin/fm-install-gitleaks.sh <destination-directory>` installs the checksum-verified build.
A missing or older gitleaks refuses the push or fails the job instead of passing.
A home that spawns a task for this repository without gitleaks on PATH has its pushes refused until it installs one.
Secondmate homes are clones of this repository, so they get the pre-push hook as well.
Install gitleaks on every machine that runs a firstmate gate or spawns firstmate or secondmate work before this lands: the lint step exits 2 without it, which starts fix rounds in the lane.

## What a finding means

Treat every finding as a real secret until proven otherwise.
Rotate the credential through its owner, and remove it from the branch before pushing again.
A secret that is already pushed is not fixed by a later commit that deletes it; history is public.
Never add an allowlist entry to make a new finding pass.
The two permitted allowlist shapes are a decision key (`key=<lowercase-slug>`) and a named canary pinned to its value and its test file.

## Reviewed baseline

The 2026-11-11 scan of all 3,355 commits found 68 `generic-api-key` matches.
Of those, 67 are false positives and each is covered by a narrow entry in `.gitleaks.toml`.
A rescan of all 3,355 commits with this file reports no leaks, and dropping any one entry brings back exactly the findings in its row.

| Entry | Findings it covers | Why it is not a secret |
|---|---|---|
| Decision keys, `key=<lowercase-slug>` or `"key": "<slug>"` | 60 | Firstmate decision and blocker keys such as `merge-handoff-9`; a real key carries uppercase letters or no hyphen |
| `PC-<n>-<12 hex>` and `bytes=<n>` key-context values | 2 | A Linear item id with a suffix and a byte count, each in key position |
| `FIXTURESECRET...` in `tests/fm-officer-progress.test.sh` | 2 | A fake token in a test's error text |
| `...-never-on-argv` values in `tests/fm-dispatch-resolve.test.sh` | 2 | Canaries a test plants to prove a value never reaches argv |
| `fm-inherited-secret-7f3a` in `tests/fm-backend-t3code.test.sh` | 1 | A canary for an inherited-environment test |

One finding is not a false positive and is allowlisted by commit and path only.
Commit `4d572468c20199c54eba9236591d09603183306e` (2026-09-20, on the evidence branch) holds a Lavish board URL with an `artifact_load_token` query parameter, a token for a board session.
History is not rewritten, so the entry exists only to keep CI from failing on old history; the same file at any other commit still fails.
Whether that token still opens a board has not been checked.
That is the captain's call: if it can, revoke the board.

## Evidence

[`.no-mistakes.yaml`](../.no-mistakes.yaml) sets `test.evidence.store_in_repo` to false, so no-mistakes keeps each run's test evidence on local disk under its own home and no longer publishes it to the public orphan `no-mistakes/evidence` branch.
That is the route taken because browser captures holding URLs with tokens reached that branch (the Lavish entry above), and no-mistakes offers no way to stop it short of not publishing.
The publish is done by the no-mistakes binary, which this repository does not control.
Its evidence settings (`store_in_repo`, `attach_media`, `dir`, `branch`, `commit_message`, `local_root`, `retention`, `max_runs`) have no exclude or redact option, and it passes no evidence directory to configured commands, so nothing here could refuse a publish.
The cost is that pull request bodies no longer link the evidence.
Nothing under `.no-mistakes/` is tracked on a code branch either: it is gitignored, and CI rejects a tracked entry.
History is not rewritten and nothing already on the evidence branch is deleted.

The remaining controls:

- The test-step instructions in `.no-mistakes.yaml` tell the gate to run `bin/fm-evidence-secrets.sh redact` then `check` on its evidence directory before finishing, as local hygiene for evidence that may be shared.
  That is an instruction to an agent, not an enforcement point.
- `bin/fm-evidence-secrets.sh check` fails on any URL in a text file whose query string has a parameter named like token, key, secret, auth, sig, password or credential with a value other than `REDACTED`.
  It never prints a value, and it skips binary files, so a URL drawn in a screenshot is out of its reach.
- The daily `Evidence secret scan` workflow stays as a backstop for the existing branch and for any later re-enable of `store_in_repo`.
  `bin/fm-evidence-branch-scan.sh` runs both scans over the last two days of that branch, and passes with a notice where the branch does not exist.

Turning `store_in_repo` back on publishes evidence again, with only that daily detection behind it.
