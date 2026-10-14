set -u
. "$(dirname "$0")/lib.sh"
mkdir -p "$EVID/fixtures"
FX="$LAB/fixtures"
write_cpa "$FX/cpa-pool.toon" \
  'reserve@example.com,claude,0.00,,1.00,2030-01-03T15:00Z,2030-01-01T06:52Z,43,0' \
  'one@example.com,claude,0.15,2030-01-01T11:00Z,0.13,2030-01-07T20:00Z,2030-01-01T07:35Z,0,165494245' \
  'two@example.com,claude,0.06,2030-01-01T12:00Z,0.22,2030-01-07T06:00Z,2030-01-01T07:35Z,0,81088936' \
  'three@example.com,claude,0.12,2030-01-01T11:50Z,0.92,2030-01-06T14:00Z,2030-01-01T07:35Z,0,218157013' \
  'codex@example.com,codex,0.99,,0.99,,2030-01-01T07:35Z,0,0'
write_cpa "$FX/cpa-high.toon" \
  'a@example.com,claude,0.02,2030-01-01T11:00Z,0.03,2030-01-07T20:00Z,2030-01-01T07:35Z,0,1' \
  'b@example.com,claude,0.05,2030-01-01T11:00Z,0.01,2030-01-07T20:00Z,2030-01-01T07:35Z,0,1'
write_cpa "$FX/cpa-exhausted.toon" \
  'one@example.com,claude,1.00,2030-01-01T11:00Z,0.40,2030-01-07T20:00Z,2030-01-01T07:35Z,0,1' \
  'two@example.com,claude,0.20,2030-01-01T12:00Z,1.00,2030-01-07T06:00Z,2030-01-01T07:35Z,0,1'
write_cpa "$FX/cpa-blank.toon" \
  'idle5h@example.com,claude,,,0.40,2030-01-07T20:00Z,2030-01-01T07:35Z,0,0' \
  'busy@example.com,claude,0.20,2030-01-01T11:00Z,0.10,2030-01-07T20:00Z,2030-01-01T07:35Z,0,1'
write_cpa "$FX/cpa-over.toon" \
  'over@example.com,claude,1.20,2030-01-01T11:00Z,0.50,2030-01-07T20:00Z,2030-01-01T07:35Z,0,1' \
  'half@example.com,claude,0.50,2030-01-01T11:00Z,0.50,2030-01-07T20:00Z,2030-01-01T07:35Z,0,1'
write_cpa "$FX/cpa-no-claude.toon" 'codex@example.com,codex,0.10,,0.10,,2030-01-01T07:35Z,0,1'
write_cpa "$FX/cpa-empty-table.toon"
cp "$FX"/cpa-*.toon "$EVID/fixtures/"
FAKES="$LAB/fake-quota:$LAB/fake-ssh:$REAL_PATH"
Q="$FX/quota-unknown.json"
oracle() { python3 -I "$LAB/oracle.py" "$1" | awk '{printf "remaining=%s%%  spendPriority=%s  runway=%s", $1, $2, $3}'; }
UNMEASURED='candidate: claude:sonnet  provider=claude  -> eligible, unranked: provider claude unmeasured (unknown): disclosed uncertainty'

# ---------- S2: mixed-provider rule, pooled Claude competes on quota-axi's scale ----------
EV="$EVID/s02-mixed-rule-claude-competes.txt"
{ echo "# S2: in a rule listing claude:sonnet, cursor, kimi the pooled Claude row competes on spendPriority (mean remaining fraction) against cursor's native 0.7597"
  echo "# fake quota-axi: claude unknown, cursor 91% / 0.7597 (fixtures/quota-unknown.json); fake ssh serves fixture tables"; } > "$EV"
use_rules base-rules.json; mkresp 4 rule_4 0.9; set_host slartibartfast
exp=$(oracle "$FX/cpa-pool.toon"); echo "oracle(cpa-pool.toon): $exp" | tee -a "$EV"
reset_log; run "$EV" "pool at 42.75% vs cursor 91%/0.7597" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon"
check "$EV" "status clear" contains "$OUT" '  status: clear'
check "$EV" "pooled claude row shows $exp" contains "$OUT" "candidate: claude:sonnet  provider=claude  scope=all_models  $exp  -> eligible"
check "$EV" "cursor keeps its native scalar" contains "$OUT" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=0.7597  runway=through_reset  -> eligible'
check "$EV" "cursor wins" contains "$OUT" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'"
check "$EV" "stderr silent" [ -z "$ERR" ]
exp=$(oracle "$FX/cpa-high.toon"); echo "oracle(cpa-high.toon): $exp" | tee -a "$EV"
reset_log; run "$EV" "pool at 96% vs cursor 91%/0.7597" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-high.toon"
check "$EV" "pooled claude row shows $exp" contains "$OUT" "candidate: claude:sonnet  provider=claude  scope=all_models  $exp  -> eligible"
check "$EV" "claude wins when the pool outranks cursor" contains "$OUT" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'"

# ---------- S3: exhausted pool ----------
EV="$EVID/s03-exhausted-pool-ineligible.txt"
echo "# S3: every Claude account exhausted on its tighter window -> runway exhausted_now -> Claude candidate not eligible, nothing dispatched" > "$EV"
use_rules pool-rules.json; mkresp 1 rule_1 0.94
reset_log; run "$EV" "all accounts exhausted" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-exhausted.toon"
check "$EV" "exit 0" [ "$RC" = 0 ]
check "$EV" "not clear" not_contains "$OUT" '  status: clear'
check "$EV" "claude ineligible with exhausted_now" contains "$OUT" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=0%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now at all_models'
check "$EV" "no profile printed" not_contains "$OUT" '  profile:'
exp=$(oracle "$FX/cpa-over.toon"); echo "oracle(cpa-over.toon, one account used_5h=1.20): $exp" | tee -a "$EV"
reset_log; run "$EV" "one account over 100% used clamps to 0 remaining, the other keeps the pool alive" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-over.toon"
check "$EV" "over-used account clamps, pool is $exp" contains "$OUT" "scope=all_models  $exp  -> eligible"

# ---------- S4: failed reads ----------
EV="$EVID/s04-failed-read-fallback.txt"
echo "# S4: a failed pool read keeps quota-axi's own claude entry (unknown here) and prints exactly one stderr line; ssh's own stderr never leaks" > "$EV"
set_host no-such-host-cpa.invalid
reset_log; run "$EV" "REAL ssh to a host that does not resolve" PATH="$LAB/fake-quota:$REAL_PATH" QUOTA_AXI_FIXTURE="$Q"
check "$EV" "exit 0" [ "$RC" = 0 ]
check "$EV" "quota-axi claude entry kept (unmeasured)" contains "$OUT" "$UNMEASURED"
check "$EV" "escalates: no rankable candidate" contains "$OUT" '  reason: no rankable eligible candidate'
check "$EV" "one stderr line naming the exit status" [ "$ERR" = 'dispatch-resolve: cpa-usage pool unavailable (cpa-usage-axi on no-such-host-cpa.invalid failed with exit 255); claude quota from quota-axi' ]
set_host slartibartfast
reset_log; run "$EV" "fake ssh: exit 255 with known-hosts and connection-refused noise on its stderr" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon" FAKE_CPA_FAIL=1 FAKE_CPA_NOISE=1
check "$EV" "stderr is exactly the one resolver line" [ "$ERR" = 'dispatch-resolve: cpa-usage pool unavailable (cpa-usage-axi on slartibartfast failed with exit 255); claude quota from quota-axi' ]
check "$EV" "claude entry kept" contains "$OUT" "$UNMEASURED"
reset_log; run "$EV" "fake ssh: success with the same stderr noise" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon" FAKE_CPA_NOISE=1
check "$EV" "noise does not spoil a good read" contains "$OUT" '  status: clear'
check "$EV" "stderr empty on success" [ -z "$ERR" ]

# ---------- S5: bounded reads ----------
EV="$EVID/s05-hung-read-bounded.txt"
echo "# S5: a hung read is bounded by FM_CPA_USAGE_TIMEOUT (default 10; blank/non-numeric/zero resets to 10); a KILL-escalated status 137 reads as a timeout. Timeout mechanism on this host: $(bash -c ". $WT/bin/fm-timeout-lib.sh; fm_timeout_mechanism")" > "$EV"
reset_log; run "$EV" "fake ssh ignores TERM and loops; FM_CPA_USAGE_TIMEOUT=1" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon" FAKE_CPA_HANG=1 FM_CPA_USAGE_TIMEOUT=1
check "$EV" "exit 0" [ "$RC" = 0 ]
check "$EV" "named as a 1s timeout" [ "$ERR" = 'dispatch-resolve: cpa-usage pool unavailable (cpa-usage-axi on slartibartfast timed out after 1s); claude quota from quota-axi' ]
check "$EV" "returned within 5s (took ${MS} ms)" [ "$MS" -lt 5000 ]
check "$EV" "claude entry kept" contains "$OUT" "$UNMEASURED"
sleep 1; left=$(pgrep -f "fake-ssh/ssh" || true); check "$EV" "no hung fake ssh left behind (pids: ${left:-none})" [ -z "$left" ]
reset_log; run "$EV" "fake ssh ignores TERM and loops; FM_CPA_USAGE_TIMEOUT=2" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon" FAKE_CPA_HANG=1 FM_CPA_USAGE_TIMEOUT=2
check "$EV" "named as a 2s timeout" [ "$ERR" = 'dispatch-resolve: cpa-usage pool unavailable (cpa-usage-axi on slartibartfast timed out after 2s); claude quota from quota-axi' ]
check "$EV" "took at least 2s and under 6s (${MS} ms)" bash -c "[ $MS -ge 1900 ] && [ $MS -lt 6000 ]"
reset_log; run "$EV" "fake ssh kills itself with SIGKILL (status 137)" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon" FAKE_CPA_KILLED=1
check "$EV" "137 is reported as the bound" [ "$ERR" = 'dispatch-resolve: cpa-usage pool unavailable (cpa-usage-axi on slartibartfast timed out after 10s); claude quota from quota-axi' ]
check "$EV" "claude entry kept" contains "$OUT" "$UNMEASURED"
for bad in 00 0 abc ''; do
  reset_log; run "$EV" "hang with FM_CPA_USAGE_TIMEOUT='$bad' falls back to the 10s default" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon" FAKE_CPA_HANG=1 FM_CPA_USAGE_TIMEOUT="$bad"
  check "$EV" "'$bad': named as a 10s timeout" [ "$ERR" = 'dispatch-resolve: cpa-usage pool unavailable (cpa-usage-axi on slartibartfast timed out after 10s); claude quota from quota-axi' ]
  check "$EV" "'$bad': bound fired near 10s, not unbounded (${MS} ms)" bash -c "[ $MS -ge 9500 ] && [ $MS -lt 20000 ]"
  check "$EV" "'$bad': claude entry kept" contains "$OUT" "$UNMEASURED"
done
reset_log; run "$EV" "quick read with FM_CPA_USAGE_TIMEOUT=abc still works" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon" FM_CPA_USAGE_TIMEOUT=abc
check "$EV" "clear" contains "$OUT" '  status: clear'
