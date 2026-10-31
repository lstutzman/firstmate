#!/usr/bin/env bash
# Offline executable fixtures: quota, stale reads, secondmate work, independent
# timer delivery, reset-window dedupe, configuration and scheduler generation.
set -eu
# shellcheck source=tests/lib.sh
. "/home/lee/.no-mistakes/worktrees/4e1bb7649f99/01M69A6TN02DCNX9R491BB58P1/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-alarm)
HOME_FIX="$TMP_ROOT/home"
BIN_FIX="$TMP_ROOT/bin"
mkdir -p "$HOME_FIX/state" "$HOME_FIX/config" "$HOME_FIX/data" "$TMP_ROOT/mate/state" "$BIN_FIX"
cp "$ROOT/bin/fm-fleet-alarm.py" "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-env-lib.sh" "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-secondmate-registry-lib.sh" "$BIN_FIX/"
cat > "$BIN_FIX/cpa-usage-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/quota-calls"
[ ! -f "$FM_HOME/quota-fail" ] || exit 1
if [ "$1" = models ]; then
  cat "$FM_HOME/models"
else
  cat "$FM_HOME/accounts"
fi
SH
# A full fleet snapshot is deliberately unavailable: the alarm must not call it.
cat > "$BIN_FIX/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
exit 99
SH
cat > "$BIN_FIX/fm-on.sh" <<'SH'
#!/usr/bin/env bash
[ ! -f "$FM_HOME/remote-slow" ] || sleep 10
[ ! -f "$FM_HOME/remote-refused" ] || exit 1
[ -f "$FM_HOME/remote-summary" ] || exit 255
cat "$FM_HOME/remote-summary"
SH
# Exercise the real ledger publisher against the fixture home, without a watcher.
cat > "$BIN_FIX/fm-fleet-ledger.sh" <<'SH'
#!/usr/bin/env bash
exec "$ROOT/bin/fm-fleet-ledger.sh" "$@"
SH
chmod +x "$BIN_FIX/"*.sh "$BIN_FIX/cpa-usage-axi"

quota() {
  local used=$1 age=${2:-1} reset=${3:-window1}
  printf '%s\n' 'accounts[1]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:' \
    "  member@example.invalid,claude,0.2,,$used,$reset,,$age,0" > "$HOME_FIX/accounts"

}
# The watcher summary and main's own last line are always fresh here; only the
# mate's own event age and its spawn time may prove it awake.
mate() {
  local active=$1 decisions=$2 agent=$3 spawn=${4:-}
  printf -- '- mate - test domain (home: %s; scope: test; projects: alpha; added 2026-10-26)\n' "$TMP_ROOT/mate" > "$HOME_FIX/data/secondmates.md"
  python3 - "$HOME_FIX" "$TMP_ROOT/mate" "$active" "$decisions" "$agent" "$spawn" <<'PY_MATE'
from pathlib import Path
import json,sys,time
home,mate=map(Path,sys.argv[1:3])
active,decisions=map(int,sys.argv[3:5])
age=json.loads(sys.argv[5])
now=int(time.time())
summary=dict(schema='fm-secondmate-home-summary.v1',hold_classifier_schema='fm-captain-hold-buckets.v1',home=str(mate),generated_epoch=now,valid=True,counts=dict(in_flight=0,active_children=active,decisions_open=decisions,holds=0))
(mate/'state/home-summary.json').write_text(json.dumps(summary))
(home/'state/mate.status').write_text('working: no timestamp\n' if age is None else f'working [at={now-age}]: agent event\n')
(home/'state/mate.meta').write_text('spawn_gen='+sys.argv[6]+'\n')
PY_MATE
}

run_alarm() {
  ROOT="$ROOT" FM_HOME="$HOME_FIX" PATH="$BIN_FIX:$PATH" TMPDIR="$TMP_ROOT" \
    python3 "$BIN_FIX/fm-fleet-alarm.py" "$@"
}
cat > "$HOME_FIX/models" <<'ROWS'
models[1]{account,model,requests,failed}:
  member@example.invalid,claude-opus-5-5,5,0
ROWS
rm -f "$HOME_FIX/config/fleet-alarm.json"
: > "$HOME_FIX/config/fleet-ledger"
quota 0.2; mate 0 0 0
echo "## baseline timer"; run_alarm timer; run_alarm check
echo "## race: one bad poll on timer, recovery"
printf '%s\n' '{}' > "$TMP_ROOT/mate/state/home-summary.json"
run_alarm timer; echo "status lines after 1 bad timer poll: $(wc -l < "$HOME_FIX/state/fleet-alarm.status" 2>/dev/null || echo 0)"
mate 0 0 0; run_alarm timer
echo "status lines after recovery: $(wc -l < "$HOME_FIX/state/fleet-alarm.status" 2>/dev/null || echo 0)"
echo "## persistent: timer twice"
printf '%s\n' '{}' > "$TMP_ROOT/mate/state/home-summary.json"
run_alarm timer; run_alarm timer
echo "--- status file:"; cat "$HOME_FIX/state/fleet-alarm.status"
echo "## mirror: check poll held back (count1), then timer again"
out=$(run_alarm check); echo "check out: [$out]"
run_alarm timer
n=$(grep -c '^needs-decision' "$HOME_FIX/state/fleet-alarm.status"); echo "needs-decision lines: $n"
echo "--- ledger records:"; jq -c '{event,state,key,cause}' "$HOME_FIX/state/fleet-ledger.jsonl"
echo "## quota pressure with persist default"
mate 0 0 0; run_alarm timer; quota 0.95; run_alarm timer
tail -n1 "$HOME_FIX/state/fleet-alarm.status"
