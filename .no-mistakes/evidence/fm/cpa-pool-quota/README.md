# Test evidence: pooled CLIProxyAPI Claude quota in bin/fm-dispatch-resolve.sh (branch fm/cpa-pool-quota, 27ceceab)

All `live-*.txt` transcripts are the real resolver run from the gate worktree on Lees-Mac-mini against a disposable FM_HOME
(`lab-config/`), the real local Jev on slartibartfast (config/typesafe-base-url + token file), the real `quota-axi --json`
(which reports claude unknown on this host), and the real `cpa-usage-axi accounts` on slartibartfast over real ssh. A PATH shim
in front of ssh only records argv so each transcript shows which path the resolver took. Account e-mails are masked.

- `live-0-no-pool.txt` - no config/cpa-usage-host: claude unranked (unknown), no ssh, "no rankable eligible candidate".
- `live-1-pool-ssh-slartibartfast.txt` - host `slartibartfast`: one bounded ssh read, claude row remaining=31% spendPriority=0.31, status clear, profile claude:sonnet.
- `live-1-expected-vs-actual.txt` - the real table captured before and after scenario 1 (`cpa-accounts-*.toon`) and an independent awk recomputation of the documented formula: 31% / 0.31 matches the resolver.
- `live-2-pool-local.txt` - literal `local`: the resolver runs the local cpa-usage-axi wrapper (its own ssh argv differs from the resolver's), no direct resolver ssh.
- `live-3-pool-own-hostname-uppercase.txt` - host `LEES-MAC-MINI` on Lees-Mac-mini: treated as local (case-insensitive short host name), no direct resolver ssh.
- `live-4-pool-unreachable-host.txt` - host `fm-lab-nohost.invalid`: real ssh exit 255, one stderr line, quota-axi claude entry kept.
- `live-5-pool-timeout-blackhole.txt` - host `192.0.2.1` with FM_CPA_USAGE_TIMEOUT=1: bounded, "timed out after 1s", fallback.
- `live-6-pool-malformed-host.txt` - value `-oProxyCommand=sh evil`: refused before ssh, stderr names the file not the value.
- `blank-window-before-fix.txt` / `blank-window-after-fix.txt` - NOT live at the cpa boundary: a stub cpa-usage-axi prints a table with a blank used_5h; the pre-fix resolver (4271d3e9) drops that account (80%), the target resolver counts it as nothing used (70%, spendPriority 0.7). Jev and quota-axi are real.
- `non-numeric-window-before-fix.txt` / `non-numeric-window-after-fix.txt` - same setup with an `n/a` window and an all-blank account: target gives 90% (n/a dropped, all-blank counts as unused); pre-fix gives a different number.
- `dispatch-resolve-test.log` - `bash tests/fm-dispatch-resolve.test.sh` (includes the new "a non-numeric window drops only its own account" case).
- `secondmate-harness-inheritance-test.log` - `bash tests/fm-secondmate-harness.test.sh` (config/cpa-usage-host propagation into secondmate homes).
