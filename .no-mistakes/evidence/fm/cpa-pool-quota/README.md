# Live validation: pooled CLIProxyAPI Claude quota in bin/fm-dispatch-resolve.sh (branch fm/cpa-pool-quota, 5cfd4499)

Every scenario drove the real `bin/fm-dispatch-resolve.sh` from the run worktree against a disposable `FM_HOME` under `$TMPDIR`
(torn down afterwards). The typesafe endpoint was a local keyless Jev stand-in (`driver/server.py`, reached by the real `curl`
through `config/typesafe-base-url`). Host: macOS, bash 3.2, jq 1.7.1, no GNU `timeout` (the bound ran through the perl mechanism).

| # | Scenario | External boundary used | Result | Evidence |
|---|----------|------------------------|--------|----------|
| S1 | Pooled read ranks the Claude candidate; `local` and own host name read the same pool here | REAL `quota-axi` 0.1.60 (reports claude unknown on this host), REAL `ssh slartibartfast cpa-usage-axi accounts`, independent Python oracle from a raw table read taken just before the run | pass | `s01-live-pool-ranks-claude.txt` |
| S2 | Mixed rule: pooled Claude competes on quota-axi's spendPriority scale (cursor wins at 42.75%, Claude wins at 96%) | fixture tables via a recording fake ssh; fake quota-axi (claude unknown, cursor 91%/0.7597) | pass | `s02-mixed-rule-claude-competes.txt` |
| S3 | Every account exhausted -> `exhausted_now`, candidate ineligible; an over-100%-used account clamps to 0 | fixtures | pass | `s03-exhausted-pool-ineligible.txt` |
| S4 | Failed read keeps quota-axi's claude entry with one stderr line; ssh stderr noise never leaks | REAL ssh to a non-resolving host (exit 255); fake ssh with noise | pass | `s04-failed-read-fallback.txt` |
| S5 | Hung read bounded by FM_CPA_USAGE_TIMEOUT (1s, 2s); 137 reads as a timeout; `00`, `0`, `abc`, blank fall back to 10s (wall clock ~10.6s) | fake ssh that ignores TERM / kills itself | pass (one transient leftover-pid observation did not reproduce in 3 re-runs; see file) | `s05-hung-read-bounded.txt` |
| S6 | nan, NaN, infinity, -infinity, 1e400, n/a, 0x10, .5, 1., "1 0", +0.5, -0.1, quoted, wrong column counts, no accounts table, empty output, help-only: all malformed with whole-pool fallback; blank window = 0 used; no claude rows named | fixtures | pass | `s06-malformed-read-fallback.txt` |
| S7 | Only a plain host name reaches ssh: `-oProxyCommand=sh evil`, `host;id`, `$(id)`, backticks, spaces, `-v`, `/`, `.hidden`, `-` refused before any call and never echoed; `user@host`, FQDN, `host_1:2222` pass through as one argv after `--`; comment-only and padded lines handled | recording fake ssh | pass (one check artifact for the value `-`; see file) | `s07-host-value-guard.txt` |
| S8 | `local` and the real `hostname -s` in any case run `cpa-usage-axi accounts` here with no ssh; `.local` suffix or any other host goes over ssh | recording fakes for ssh and cpa-usage-axi, real `hostname` | pass | `s08-local-and-own-host.txt` |
| S9 | Schema 6 snapshot with two claude account rows takes one pooled default row; silent; cursor default row still wins a mixed rule | fake quota-axi schema 6 | pass | `s09-schema6-snapshot.txt` |
| S10 | Absent or empty `config/cpa-usage-host`: no read, silent, unchanged resolution | recording fake ssh | pass | `s10-absent-file-unchanged.txt` |
| S11 | Documented: model-scoped Claude rule floor is unverifiable under the pool and escalates | fixtures | pass | `s11-model-scoped-floor-unverifiable.txt` |
| S12 | Documented: two Claude candidates in one rule tie on the pooled row and escalate | fixtures | pass | `s12-two-claude-candidates-tie.txt` |
| S13 | `config/cpa-usage-host` inherited into a seeded secondmate home by the REAL `fm-config-push.sh` (pushed / unchanged / changed / absence mirrored) exactly like `typesafe-base-url`; the secondmate's own resolver then reads the pool over ssh to the inherited host | real config-push against a minted lab primary; recording fake ssh for the secondmate's read | pass (two harness-side FAIL lines, each explained and re-run clean in the file) | `s13-secondmate-inherits-cpa-usage-host.txt` |
| S14 | After the `fm_config_line` refactor, `config/typesafe-model` and `config/typesafe-base-url` still steer the request seen by the stand-in | real curl to the stand-in | pass | `s14-typesafe-config-alias.txt` |

Baseline suites run from the worktree: `bash tests/fm-dispatch-resolve.test.sh`, `bash tests/fm-quota-choose.test.sh`,
`bash tests/fm-secondmate-harness.test.sh` (260 s) - all passed.

Notes
- Account e-mail addresses in the real cpa-usage-axi table were redacted in `s01` before writing evidence; the resolver's own output never prints them.
- In S13 `fm-config-push.sh` exits 1 after propagating because its follow-up reread nudge goes through `fm-send.sh`, which refuses fleet lifecycle inside a no-mistakes gate worktree when the push passes `FM_*_OVERRIDE` relocations. That path is unchanged by this branch; the propagation report and the secondmate's files are the observables.
- `driver/` holds the lab helpers (`lib.sh`, scenario scripts, the oracle, the stand-in server, the fakes); `fixtures/` holds every table, snapshot, rule file and brief used.
