set -u
. "$(dirname "$0")/lib.sh"
mkresp 1 rule_1 0.94
probe=$(curl -sS -X POST "http://127.0.0.1:$(cat "$LAB/jev/port")/v1/systemone" -d '{}' -o /dev/null -w '%{http_code}')
echo "probe http=$probe"; [ "$probe" = 200 ] || exit 1
use_rules pool-rules.json
set_host '# CLIProxyAPI usage host' slartibartfast
EV="$EVID/s01-live-pool-ranks-claude.txt"
{ echo "# S1: live pooled Claude quota from cpa-usage-axi on slartibartfast ranks the Claude candidate"
  echo "# Real quota-axi $(quota-axi --version 2>/dev/null | head -1) on this host (Claude keychain absent), real ssh to slartibartfast, real curl to a local keyless Jev stand-in (config/typesafe-base-url -> 127.0.0.1)."
  echo "# Real quota-axi snapshot on this host (no account identifiers in it):"
  quota-axi --json 2>/dev/null | jq -c '{schemaVersion, claude: (.providers[] | select(.provider == "claude") | {status: .quotaSemantics.status, rows: (.quotaSemantics.effectiveAvailability | length)})}' | sed 's/^/#   /'
} > "$EV"
ssh -o BatchMode=yes -o ConnectTimeout=5 -- slartibartfast cpa-usage-axi accounts > "$LAB/out/pool-before.toon"
reset_log
run "$EV" "ssh host: real read over ssh" PATH="$REAL_PATH"
OUT1=$OUT; ERR1=$ERR; RC1=$RC
ssh -o BatchMode=yes -o ConnectTimeout=5 -- slartibartfast cpa-usage-axi accounts > "$LAB/out/pool-after.toon"
cat > "$LAB/oracle.py" <<'PY'
# Independent oracle: docs/configuration.md "Pooled Claude quota" rule, computed from a raw cpa-usage-axi table.
import math, sys
lines = open(sys.argv[1]).read().split('\n')
head = next(i for i, l in enumerate(lines) if l.startswith('accounts[') and l.endswith('}:'))
fields = lines[head][lines[head].index('{') + 1:lines[head].index('}')].split(',')
rows = []
for l in lines[head + 1:]:
    if not l.startswith('  '): break
    rows.append(dict(zip(fields, l[2:].split(','))))
rem = []
for r in rows:
    if r['provider'] != 'claude': continue
    u5 = float(r['used_5h']) if r['used_5h'] != '' else 0.0
    u7 = float(r['used_7d']) if r['used_7d'] != '' else 0.0
    rem.append(min(max(1 - max(u5, u7), 0.0), 1.0))
bp = math.floor(sum(rem) / len(rem) * 10000 + 0.5)
fmt = lambda x: repr(x)[:-2] if repr(x).endswith('.0') else repr(x)
print(fmt(bp / 100), fmt(bp / 10000), 'exhausted_now' if all(x == 0 for x in rem) else 'through_reset', len(rem), ' '.join(fmt(round(x, 4)) for x in rem))
PY
read -r PCT FRAC RUNWAY NACC PERACC < <(python3 -I "$LAB/oracle.py" "$LAB/out/pool-before.toon")
{ echo; echo "--- oracle (python, from a raw table read taken immediately before the run; accounts redacted) ---"
  awk '/^  [^,]*@/ { n++; sub(/^  [^,]*,/, "  account-" n "@redacted,") } { print }' "$LAB/out/pool-before.toon"
  echo "per-account remaining share of the tighter window: $PERACC  (claude accounts: $NACC)"
  echo "expected: remaining=${PCT}%  spendPriority=${FRAC}  runway=${RUNWAY}"
  if cmp -s "$LAB/out/pool-before.toon" "$LAB/out/pool-after.toon"; then echo "table read after the run is identical to the one before (pool did not move during the run)"; else echo "WARNING: table moved during the run"; diff "$LAB/out/pool-before.toon" "$LAB/out/pool-after.toon" | sed -E 's/[^,]*@[^,]*/<account>/'; fi
} | tee -a "$EV"
check "$EV" "exit 0" [ "$RC1" = 0 ]
check "$EV" "status clear" contains "$OUT1" '  status: clear'
check "$EV" "pooled row equals the oracle" contains "$OUT1" "candidate: claude:sonnet  provider=claude  scope=all_models  remaining=${PCT}%  spendPriority=${FRAC}  runway=${RUNWAY}  -> eligible"
check "$EV" "claude profile dispatched" contains "$OUT1" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'"
check "$EV" "stderr silent" [ -z "$ERR1" ]
set_host local
reset_log; run "$EV" "local: real local cpa-usage-axi wrapper (which itself sshes to slartibartfast)" PATH="$REAL_PATH"
check "$EV" "local value yields the same pooled row" contains "$OUT" "remaining=${PCT}%  spendPriority=${FRAC}  runway=${RUNWAY}  -> eligible"
check "$EV" "local value: stderr silent" [ -z "$ERR" ]
own=$(hostname -s | tr '[:upper:]' '[:lower:]'); set_host "$own"
reset_log; run "$EV" "own host name ($own; real hostname -s is $(hostname -s)): runs cpa-usage-axi here" PATH="$REAL_PATH"
check "$EV" "own host name yields the same pooled row" contains "$OUT" "remaining=${PCT}%  spendPriority=${FRAC}  runway=${RUNWAY}  -> eligible"
check "$EV" "own host name: stderr silent" [ -z "$ERR" ]
echo; echo "jev requests so far: $(wc -l < "$LAB/jev/requests.log")"; tail -1 "$LAB/jev/requests.log" | cut -c1-160
