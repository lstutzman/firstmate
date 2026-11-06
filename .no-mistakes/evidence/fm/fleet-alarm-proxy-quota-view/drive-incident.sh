#!/usr/bin/env bash
# Drives the real bin/fm-fleet-alarm.py against a disposable FM_HOME with a stub
# cpa-usage-axi that replays the reported incident (synthetic proxy readings).
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-alarm-lab.XXXXXX")
mkdir -p "$LAB/home/state" "$LAB/home/config" "$LAB/home/data" "$LAB/bin"
cp "$ROOT/bin/fm-fleet-alarm.py" "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-env-lib.sh" "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-secondmate-registry-lib.sh" "$LAB/bin/"
cat > "$LAB/bin/cpa-usage-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/quota-calls"
if [ "$1" = models ]; then
  if [ "$3" = 0.25 ]; then cat "$FM_HOME/models-15m"; else cat "$FM_HOME/models-60m"; fi
else cat "$FM_HOME/accounts"; fi
SH
printf '#!/usr/bin/env bash\nexit 99\n' > "$LAB/bin/fm-fleet-snapshot.sh"
printf '#!/usr/bin/env bash\nexit 255\n' > "$LAB/bin/fm-on.sh"
printf '#!/usr/bin/env bash\nexec "$ROOT/bin/fm-fleet-ledger.sh" "$@"\n' > "$LAB/bin/fm-fleet-ledger.sh"
chmod +x "$LAB/bin/"*
H=$LAB/home
echo '{"persist_polls":1}' > "$H/config/fleet-alarm.json"
run() { ROOT="$ROOT" FM_HOME="$H" PATH="$LAB/bin:$PATH" TMPDIR="$LAB" python3 "$LAB/bin/fm-fleet-alarm.py" "$@"; }
accounts() { # marley lstutzman misterrobot (7d used)
  printf '%s\n' 'accounts[3]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:' \
   "  marleycrittendom@example.invalid,claude,0.0,,$1,2026-11-09T10:00:00Z,,2,0" \
   "  lstutzman@example.invalid,claude,0.4,,$2,2026-11-12T10:00:00Z,,2,633000000" \
   "  misterrobot@example.invalid,claude,0.0,,$3,2026-11-11T10:00:00Z,,2,0" > "$H/accounts"; }
echo "=== S1 incident: marley 7d 100% carried earlier in the hour, proxy rotated to lstutzman (13%) ==="
accounts 1.0 0.13 0.05
printf '%s\n' 'models[2]{account,model,requests,failed}:' '  marleycrittendom@example.invalid,claude-opus-5-5,40,0' '  lstutzman@example.invalid,claude-opus-5-5,900,0' > "$H/models-60m"
printf '%s\n' 'models[1]{account,model,requests,failed}:' '  lstutzman@example.invalid,claude-opus-5-5,300,0' > "$H/models-15m"
run check; echo "exit=$?"
echo "--- ledger needs-decision rows after S1:"; grep -c needs-decision "$H/state/fleet-ledger.jsonl" 2>/dev/null || echo 0
echo "--- timer RUN-RESULT after S1:"; run timer; echo "exit=$?"
echo
echo "=== S2 adversarial: every serving account exhausted (marley 100%, lstutzman 95% both serving) ==="
accounts 1.0 0.95 0.05
printf '%s\n' 'models[2]{account,model,requests,failed}:' '  marleycrittendom@example.invalid,claude-opus-5-5,40,0' '  lstutzman@example.invalid,claude-opus-5-5,900,0' > "$H/models-60m"
cp "$H/models-60m" "$H/models-15m"
run check; echo "exit=$?"
echo "--- ledger needs-decision rows after S2:"; grep needs-decision "$H/state/fleet-ledger.jsonl" | tail -3
echo
echo "=== S3 adversarial: only failed requests on the headroom account (not really serving) ==="
accounts 1.0 0.13 0.05
printf '%s\n' 'models[1]{account,model,requests,failed}:' '  marleycrittendom@example.invalid,claude-opus-5-5,40,0' > "$H/models-60m"
printf '%s\n' 'models[2]{account,model,requests,failed}:' '  marleycrittendom@example.invalid,claude-opus-5-5,10,0' '  lstutzman@example.invalid,claude-opus-5-5,5,5' > "$H/models-15m"
rm -f "$H/state/.fleet-alarm.json"
run check; echo "exit=$?"
echo
echo "--- cpa-usage-axi calls made:"; sort "$H/quota-calls" | uniq -c
rm -rf "$LAB"
