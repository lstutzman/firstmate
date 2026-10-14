# Live validation: pooled Claude quota via config/cpa-usage-host (PR #12 rebase re-validation)

Product driven: the real `bin/fm-dispatch-resolve.sh` at f2daf32d, from a disposable FM_HOME per scenario,
with a local System One stand-in on 127.0.0.1 (the external Jev boundary), the real `quota-axi`
(which reports every provider unknown on this keychain-less host, the motivating case), and the real
`ssh`/`cpa-usage-axi` where the scenario is about the real pool. Fixture-driven scenarios stub only the
external boundaries (`ssh` standing in for the remote host, `quota-axi` for a snapshot with cursor known).
Every expected number comes from an independent awk computation over the raw accounts table
(mean over claude rows of 1 - max(used_5h, used_7d), blank = 0), never from the resolver.

| scenario | transcript | result |
|---|---|---|
| s1 real pool over real ssh to slartibartfast | s1-real-pool-over-ssh-slartibartfast.txt (+ s1-oracle-raw-accounts.toon) | clear, 26.25% / 0.2625 = oracle |
| s2 absent file leaves resolution unchanged, no ssh, quiet stderr | s2-absent-file-unchanged.txt | pass |
| s3 mixed rule: cursor 91%/0.7597 outranks pooled claude 42.75%/0.4275 | s3-mixed-rule-cursor-outranks-pool.txt | cursor profile chosen |
| s3b single Claude rule clears on the pool; exact ssh argv | s3b-single-rule-pool-clear.txt | pass |
| s4 ssh exit 255 falls back with one stderr line | s4-ssh-failure-falls-back.txt | pass |
| s5a hung read bounded by FM_CPA_USAGE_TIMEOUT=1 | s5a-hung-read-bounded-at-1s.txt | wall 1.57s |
| s5b FM_CPA_USAGE_TIMEOUT=00 falls back to the 10s bound, never unbounded | s5b-all-zero-timeout-falls-back-to-10s.txt | wall 10.68s, "timed out after 10s" |
| s6 non-numeric window = malformed read, whole-pool fallback | s6-nonnumeric-window-whole-pool-fallback.txt | pass |
| s7 blank window counts as nothing used (70% / 0.7) | s7-blank-window-counts-as-zero-used.txt | pass |
| s8 exhausted pool makes the Claude candidate ineligible | s8-exhausted-pool-ineligible.txt | pass |
| s9a own short host name (lowercase vs Lees-Mac-mini) runs the real local tool, no resolver ssh | s9a-own-short-hostname-runs-locally.txt (+ s9a-oracle-raw-accounts.toon) | clear, 26% / 0.26 = oracle |
| s9b literal `local` runs the real local tool | s9b-literal-local-runs-locally.txt | pass |
| s9c own host name in UPPERCASE, stub cpa-usage-axi, failing ssh shim | s9c-own-hostname-any-case-no-ssh-direct-cpa-usage-axi.txt | `accounts` run directly, no ssh |
| s10 host value that is an ssh option never reaches ssh | s10-host-option-injection-refused.txt | pass |
| s11 rebase conflict site: inheritable set lists firstmate-role and cpa-usage-host; propagation copies, converges, mirrors absence | s11-rebase-inheritable-set-propagates-cpa-usage-host.txt | pass |
| s12 fm-config-push.sh pushes cpa-usage-host into a live secondmate home with exact bytes and writes the reread instruction | s12-config-push-pushes-cpa-usage-host-to-live-secondmate.txt | pushed; final reread send refused by the no-mistakes gate guard (pre-existing, config-push sets FM_*_OVERRIDE for the send) |

The two `*-attempt1-setup-artifact-*` files record a first attempt at s9a/s9b whose fail-loudly ssh shim broke
the machine's local cpa-usage-axi (itself an ssh wrapper); kept for transparency, superseded by the runs above.

Targeted automated suites: suite-fm-dispatch-resolve.log and suite-fm-secondmate-harness.log (both exit 0).
