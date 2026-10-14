set -u
. "$(dirname "$0")/lib.sh"
FX="$LAB/fixtures"; FAKES="$LAB/fake-quota:$LAB/fake-ssh:$REAL_PATH"; Q="$FX/quota-unknown.json"
oracle() { python3 -I "$LAB/oracle.py" "$1" | awk '{printf "remaining=%s%%  spendPriority=%s  runway=%s", $1, $2, $3}'; }
UNMEASURED='candidate: claude:sonnet  provider=claude  -> eligible, unranked: provider claude unmeasured (unknown): disclosed uncertainty'
MAL='dispatch-resolve: cpa-usage pool unavailable (malformed cpa-usage-axi read on slartibartfast); claude quota from quota-axi'
NOROWS='dispatch-resolve: cpa-usage pool unavailable (no claude account rows from cpa-usage-axi on slartibartfast); claude quota from quota-axi'
use_rules pool-rules.json; mkresp 1 rule_1 0.94; set_host slartibartfast

# ---------- S5 appendix: what was left behind after the 1s hang? ----------
EV="$EVID/s05-hung-read-bounded.txt"
{ echo; echo "--- leftover-process investigation (the check above found a matching pid 1s after the 1s hang) ---"
  echo "matching processes now: $(ps -axo pid,ppid,pgid,stat,etime,command | grep -F 'fake-ssh/ssh' | grep -v grep | tr '\n' ';')"; } | tee -a "$EV"
for i in 1 2 3; do
  reset_log; run "$EV" "hang #$i with FM_CPA_USAGE_TIMEOUT=1, then sample the process table" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon" FAKE_CPA_HANG=1 FM_CPA_USAGE_TIMEOUT=1 >/dev/null
  for d in 0 0.5 2; do sleep "$d"; printf '  +%ss after return: %s\n' "$d" "$(ps -axo pid,ppid,pgid,stat,etime,command | grep -F 'fake-ssh/ssh' | grep -v grep | tr '\n' ';')"; done | tee -a "$EV"
done

# ---------- S6: malformed reads ----------
EV="$EVID/s06-malformed-read-fallback.txt"
echo "# S6: any non-blank window that is not a plain decimal, a row off the table's columns, or output without an accounts table is a malformed read: whole-pool fallback with one stderr line. Blank windows count as 0 used." > "$EV"
for word in nan NaN infinity -infinity 1e400 n/a 0x10 .5 1. '1 0' +0.5 -0.1 '"0.5"'; do
  write_cpa "$FX/cpa-bad.toon" "bad@example.com,claude,$word,,0.40,2030-01-07T20:00Z,2030-01-01T07:35Z,0,0" 'busy@example.com,claude,0.20,2030-01-01T11:00Z,0.10,2030-01-07T20:00Z,2030-01-01T07:35Z,0,1'
  reset_log; run "$EV" "used_5h='$word' on one of two accounts" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-bad.toon" >/dev/null
  check "$EV" "used_5h='$word': whole pool falls back, the healthy account never ranks alone" contains "$OUT" "$UNMEASURED"
  check "$EV" "used_5h='$word': exactly one malformed-read line" [ "$ERR" = "$MAL" ]
done
write_cpa "$FX/cpa-bad.toon" 'ok@example.com,claude,0.20,2030-01-01T11:00Z,nan,2030-01-07T20:00Z,2030-01-01T07:35Z,0,1'
reset_log; run "$EV" "used_7d=nan" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-bad.toon" >/dev/null
check "$EV" "used_7d=nan: malformed" [ "$ERR" = "$MAL" ]
write_cpa "$FX/cpa-bad.toon" 'wide@example.com,claude,0.20,2030-01-01T11:00Z,0.10,2030-01-07T20:00Z,2030-01-01T07:35Z,0,1,extra' 'busy@example.com,claude,0.20,2030-01-01T11:00Z,0.10,2030-01-07T20:00Z,2030-01-01T07:35Z,0,1'
reset_log; run "$EV" "a row with one column too many" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-bad.toon" >/dev/null
check "$EV" "extra column: malformed" [ "$ERR" = "$MAL" ]; check "$EV" "extra column: claude entry kept" contains "$OUT" "$UNMEASURED"
write_cpa "$FX/cpa-bad.toon" 'short@example.com,claude,0.20,2030-01-01T11:00Z,0.10,2030-01-07T20:00Z,2030-01-01T07:35Z,0' 'busy@example.com,claude,0.20,2030-01-01T11:00Z,0.10,2030-01-07T20:00Z,2030-01-01T07:35Z,0,1'
reset_log; run "$EV" "a row with one column too few" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-bad.toon" >/dev/null
check "$EV" "missing column: malformed" [ "$ERR" = "$MAL" ]
printf 'error: database is locked\n' > "$FX/cpa-bad.toon"
reset_log; run "$EV" "output is an error line, no accounts table" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-bad.toon" >/dev/null
check "$EV" "no table: malformed" [ "$ERR" = "$MAL" ]; check "$EV" "no table: claude entry kept" contains "$OUT" "$UNMEASURED"
: > "$FX/cpa-bad.toon"
reset_log; run "$EV" "completely empty output (exit 0)" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-bad.toon" >/dev/null
check "$EV" "empty output: malformed" [ "$ERR" = "$MAL" ]
printf 'help[1]:\n  Run cpa-usage-axi ration for windows used this week\n' > "$FX/cpa-bad.toon"
reset_log; run "$EV" "only a help section" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-bad.toon" >/dev/null
check "$EV" "help only: malformed" [ "$ERR" = "$MAL" ]
exp=$(oracle "$FX/cpa-blank.toon"); echo "oracle(cpa-blank.toon, one account with blank used_5h): $exp" | tee -a "$EV"
reset_log; run "$EV" "blank used_5h (no active 5h window) counts as nothing used" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-blank.toon" >/dev/null
check "$EV" "blank window: pool is $exp" contains "$OUT" "scope=all_models  $exp  -> eligible"; check "$EV" "blank window: stderr silent" [ -z "$ERR" ]
reset_log; run "$EV" "table with only a codex row" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-no-claude.toon" >/dev/null
check "$EV" "no claude rows: named fallback" [ "$ERR" = "$NOROWS" ]; check "$EV" "no claude rows: claude entry kept" contains "$OUT" "$UNMEASURED"
reset_log; run "$EV" "accounts[0] header with no rows" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-empty-table.toon" >/dev/null
check "$EV" "empty table: named fallback" [ "$ERR" = "$NOROWS" ]

# ---------- S7: host value guard ----------
EV="$EVID/s07-host-value-guard.txt"
echo "# S7: only a plain host name reaches ssh; anything else is refused before any call, named without echoing the value. Recording fake ssh on PATH." > "$EV"
BADHOST='dispatch-resolve: cpa-usage pool unavailable (config/cpa-usage-host is not a host name); claude quota from quota-axi'
for val in '-oProxyCommand=sh evil' 'host;id' '$(id)' 'slarti bartfast' '-v' 'slarti/bartfast' '`id`' '.hidden' '-'; do
  set_host "$val"; reset_log; run "$EV" "value: $val" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon" >/dev/null
  check "$EV" "[$val] ssh never called" [ ! -e "$FAKE_LOG/ssh.argv" ]
  check "$EV" "[$val] refused in one stderr line" [ "$ERR" = "$BADHOST" ]
  check "$EV" "[$val] value not echoed" not_contains "$ERR$OUT" "$val"
  check "$EV" "[$val] claude entry kept, exit 0" bash -c '[ "$1" = 0 ] && case "$2" in *"$3"*) exit 0;; esac; exit 1' _ "$RC" "$OUT" "$UNMEASURED"
done
for val in 'user@slartibartfast' 'slartibartfast.tail299042.ts.net' 'SLARTIBARTFAST' 'host_1:2222'; do
  set_host "$val"; reset_log; run "$EV" "valid form: $val" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon" >/dev/null
  check "$EV" "[$val] reaches ssh as one argument after --" [ "$(cat "$FAKE_LOG/ssh.argv")" = $'-o\nBatchMode=yes\n-o\nConnectTimeout=5\n--\n'"$val"$'\ncpa-usage-axi\naccounts' ]
  check "$EV" "[$val] clear" contains "$OUT" '  status: clear'
done
set_host '# only a comment' ''; reset_log; run "$EV" "file with only a comment line" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon" >/dev/null
check "$EV" "comment-only file: no read" [ ! -e "$FAKE_LOG/ssh.argv" ]; check "$EV" "comment-only file: stderr silent" [ -z "$ERR" ]

# ---------- S8: local and own host name run cpa-usage-axi here ----------
EV="$EVID/s08-local-and-own-host.txt"
echo "# S8: 'local' or this machine's own short host name (real hostname -s: $(hostname -s)) runs cpa-usage-axi here with no ssh; any other value goes over ssh. Recording fakes for ssh and cpa-usage-axi." > "$EV"
LOCALS="$LAB/fake-quota:$LAB/fake-ssh:$LAB/fake-cpa:$REAL_PATH"
for val in local "$(hostname -s | tr '[:lower:]' '[:upper:]')" "$(hostname -s | tr '[:upper:]' '[:lower:]')" "$(hostname -s)"; do
  set_host "$val"; reset_log; run "$EV" "value: $val" PATH="$LOCALS" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon" >/dev/null
  check "$EV" "[$val] cpa-usage-axi accounts ran here" [ "$(cat "$FAKE_LOG/cpa-usage-axi.argv" 2>/dev/null)" = accounts ]
  check "$EV" "[$val] ssh never called" [ ! -e "$FAKE_LOG/ssh.argv" ]
  check "$EV" "[$val] clear, silent" bash -c '[ -z "$2" ] && case "$1" in *"  status: clear"*) exit 0;; esac; exit 1' _ "$OUT" "$ERR"
done
for val in slartibartfast "$(hostname -s | tr '[:upper:]' '[:lower:]').local" "$(hostname -s)x"; do
  set_host "$val"; reset_log; run "$EV" "value: $val" PATH="$LOCALS" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon" >/dev/null
  check "$EV" "[$val] went over ssh" grep -qxF -- "$val" "$FAKE_LOG/ssh.argv"
  check "$EV" "[$val] cpa-usage-axi not run here" [ ! -e "$FAKE_LOG/cpa-usage-axi.argv" ]
done

# ---------- S9: schema 6 snapshot ----------
EV="$EVID/s09-schema6-snapshot.txt"
echo "# S9: a schema 6 quota-axi snapshot with two claude account rows (default, work) takes one pooled claude row bound as the default account; validation passes, stderr silent" > "$EV"
set_host slartibartfast; use_rules pool-rules.json; mkresp 1 rule_1 0.94
reset_log; run "$EV" "schema 6, one-claude rule" PATH="$FAKES" QUOTA_AXI_FIXTURE="$FX/quota-s6.json" CPA_FIXTURE="$FX/cpa-pool.toon"
check "$EV" "clear with the pooled row" contains "$OUT" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=42.75%  spendPriority=0.4275  runway=through_reset  -> eligible'
check "$EV" "stderr silent" [ -z "$ERR" ]
use_rules base-rules.json; mkresp 4 rule_4 0.9
reset_log; run "$EV" "schema 6, mixed rule" PATH="$FAKES" QUOTA_AXI_FIXTURE="$FX/quota-s6.json" CPA_FIXTURE="$FX/cpa-pool.toon"
check "$EV" "cursor default account row wins over the 42.75% pool" contains "$OUT" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'"
check "$EV" "kimi unknown row stays unranked" contains "$OUT" 'candidate: kimi:kimi-code/k3  provider=kimi  -> eligible, unranked'

# ---------- S10: absent file ----------
EV="$EVID/s10-absent-file-unchanged.txt"
echo "# S10: no config/cpa-usage-host: no read, stderr quiet, resolution is quota-axi's own outcome (claude unknown here -> escalate)" > "$EV"
use_rules pool-rules.json; mkresp 1 rule_1 0.94; drop_host
reset_log; run "$EV" "absent file" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon"
check "$EV" "no ssh call" [ ! -e "$FAKE_LOG/ssh.argv" ]; check "$EV" "stderr silent" [ -z "$ERR" ]
check "$EV" "escalates on quota-axi's unknown claude" contains "$OUT" '  reason: no rankable eligible candidate'
: > "$HOSTFILE"; reset_log; run "$EV" "empty file" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon" >/dev/null
check "$EV" "empty file: no ssh call" [ ! -e "$FAKE_LOG/ssh.argv" ]; check "$EV" "empty file: stderr silent" [ -z "$ERR" ]

# ---------- S11: model-scoped Claude floor under the pool ----------
EV="$EVID/s11-model-scoped-floor-unverifiable.txt"
echo "# S11 (documented): while the pool is in effect the pooled all_models row is the only Claude evidence, so a rule floor on model:fable is unverifiable and escalates" > "$EV"
set_host slartibartfast; use_rules base-rules.json; mkresp 4 rule_1 0.95
reset_log; run "$EV" "rule_1 (floor claude/model:fable >= 20%) with the pool at 42.75%" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon"
check "$EV" "escalates" contains "$OUT" '  status: escalate'
check "$EV" "names the unverifiable floor" contains "$OUT" '  reason: rule rule_1 floor claude/model:fable is unverifiable'

# ---------- S12: two Claude candidates tie ----------
EV="$EVID/s12-two-claude-candidates-tie.txt"
echo "# S12 (documented): two Claude candidates in one rule bind to the same pooled row, tie, and escalate" > "$EV"
use_rules tie-rules.json; mkresp 1 rule_1 0.94
reset_log; run "$EV" "claude:sonnet and claude:opus in one rule" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon"
check "$EV" "tie escalation" contains "$OUT" '  reason: genuine spendPriority tie'
check "$EV" "both carry the pooled row" bash -c '[ "$(printf "%s\n" "$1" | grep -c "spendPriority=0.4275  runway=through_reset  -> eligible")" = 2 ]' _ "$OUT"

# ---------- S14: fm_typesafe_config_line alias still serves the typesafe files ----------
EV="$EVID/s14-typesafe-config-alias.txt"
echo "# S14: after the fm_config_line refactor, config/typesafe-model and config/typesafe-base-url still steer the request (seen by the local Jev stand-in)" > "$EV"
use_rules pool-rules.json; mkresp 1 rule_1 0.94
printf '# pinned model\njev-custom-model\n' > "$LAB/home/config/typesafe-model"
before=$(grep -c '"model": "jev-custom-model"' "$LAB/jev/requests.log" || true)
reset_log; run "$EV" "config/typesafe-model=jev-custom-model" PATH="$FAKES" QUOTA_AXI_FIXTURE="$Q" CPA_FIXTURE="$FX/cpa-pool.toon"
after=$(grep -c '"model": "jev-custom-model"' "$LAB/jev/requests.log" || true)
echo "requests carrying model jev-custom-model: before=$before after=$after; base URL in use: $(sed -n '$p' "$LAB/home/config/typesafe-base-url"); total requests received by the stand-in: $(grep -c '^/v1/systemone ' "$LAB/jev/requests.log")" | tee -a "$EV"
check "$EV" "the request carried the configured model" [ "$after" = $((before + 1)) ]
check "$EV" "clear" contains "$OUT" '  status: clear'
mv "$LAB/home/config/typesafe-model" "$LAB/out/typesafe-model.removed"
echo; echo "=== failures ==="; cat "$LAB/out/failures" 2>/dev/null || echo none
