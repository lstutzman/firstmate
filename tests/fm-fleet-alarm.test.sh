#!/usr/bin/env bash
# Offline executable fixtures: quota, stale reads, secondmate work, independent
# timer delivery, reset-window dedupe, configuration and scheduler generation.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
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
[ -f "$FM_HOME/remote-summary" ] || exit 1
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
quota 0.2
mate 0 0 9000
out=$(run_alarm check)
[ -z "$out" ] || fail "idle mates and healthy quota must be silent: $out"
pass 'idle secondmate never alarms, regardless of silence'

quota 0.9
out=$(run_alarm check)
[ -z "$out" ] || fail "exactly 90% carrying use and exactly 10% remaining are not past either threshold: $out"
quota 0.2
run_alarm check >/dev/null
pass 'quota alarm thresholds are strict at the configured boundaries'

mkdir -p "$HOME_FIX/data" "$TMP_ROOT/mate/state"
printf -- '- mate - test domain (home: %s; scope: test; projects: alpha; added 2026-10-26)\n' "$TMP_ROOT/mate" > "$HOME_FIX/data/secondmates.md"
python3 - "$HOME_FIX" "$TMP_ROOT/mate" <<'PY_STATUS'
from pathlib import Path
import json,sys,time
home, mate = map(Path, sys.argv[1:])
now=int(time.time())
summary=dict(schema='fm-secondmate-home-summary.v1',hold_classifier_schema='fm-captain-hold-buckets.v1',home=str(mate),generated_epoch=now,valid=True,counts=dict(in_flight=1,active_children=0,decisions_open=0,holds=0))
(mate/'state/home-summary.json').write_text(json.dumps(summary))
with (home/'state/mate.status').open('w') as file:
    for i in range(10000):
        file.write(f'note [at={now-4000}]: ' + 'x'*512 + '\n')
    file.write(f'working [at={now-3601}]: ' + 'z'*200000 + '\n')
PY_STATUS
SECONDS=0
out=$(run_alarm check)
[ "$SECONDS" -lt 24 ] || fail 'alarm exceeded its 24-second budget with large status history'
assert_contains "$out" 'holding work silent' 'cached work inventory and actual agent events bypass fleet snapshot'
assert_not_contains "$out" 'inventory unavailable' 'large status history is readable without a full decision fold'
# Reset the alarm input for subsequent cases.
mate 0 0 0
pass 'cached summary reader completes inside budget with oversized status history'

run_alarm check >/dev/null
mate 1 0 3601
bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-classify-lib.sh"; f="$2/state/mate.status"; before=$(_fm_status_file_size "$f"); printf "note [at=%s]: parent answer\n" "$(date +%s)" >> "$f"; status_home_appends_record "$f" "$before" "$(_fm_status_file_size "$f")"' fleet-alarm-test "$ROOT" "$HOME_FIX"
printf 'blocked [key=pending-reply-test] [at=%s]: parent escalation\n' "$(date +%s)" >> "$HOME_FIX/state/mate.status"
assert_contains "$(run_alarm check)" 'holding work silent' 'parent answer and continuity escalation cannot count as agent speech'
mate 0 0 0
run_alarm check >/dev/null
mate 1 0 3601
python3 - "$HOME_FIX" "$TMP_ROOT/mate" <<'PY_CACHE'
from pathlib import Path
import hashlib,json,sys
home,mate=map(Path,sys.argv[1:])
name,host,remote='mate','unreachable.invalid','/remote/mate'
(home/'data/secondmates.md').write_text(f'- {name} - test domain (host: {host}; root: /remote/code; home: {remote}; scope: test; projects: alpha; added 2026-10-26)\n')
summary=json.loads((mate/'state/home-summary.json').read_text())
summary['home']=remote
cache=home/'state/secondmate-summary-cache'
cache.mkdir(exist_ok=True)
key=hashlib.sha256(f'{name}\n{host}\n{remote}\n'.encode()).hexdigest()
(cache/(key+'.json')).write_text(json.dumps(summary))
PY_CACHE
assert_contains "$(run_alarm check)" 'holding work silent' 'remote mate uses route-keyed cache without contacting the host'
python3 - "$HOME_FIX" <<'PY_SKEW'
from pathlib import Path
import json,sys,time
for path in (Path(sys.argv[1])/'state/secondmate-summary-cache').glob('*.json'):
    value=json.loads(path.read_text())
    value['generated_epoch']=int(time.time())+5
    path.write_text(json.dumps(value))
PY_SKEW
assert_not_contains "$(run_alarm check)" 'inventory unavailable' 'a cached summary from a remote clock a few seconds ahead is fresh'
python3 - "$HOME_FIX" <<'PY_CACHE'
from pathlib import Path
import json,sys
for path in (Path(sys.argv[1])/'state/secondmate-summary-cache').glob('*.json'):
    value=json.loads(path.read_text())
    value['generated_epoch']-=121*60
    path.write_text(json.dumps(value))
PY_CACHE
assert_contains "$(run_alarm check)" 'cached home summary is stale' 'stale inventory cannot appear healthy'
python3 - "$HOME_FIX" <<'PY_REMOTE'
from pathlib import Path
import json,sys,time
home=Path(sys.argv[1])
value=json.loads(next((home/'state/secondmate-summary-cache').glob('*.json')).read_text())
value['generated_epoch']=int(time.time())+5
(home/'remote-summary').write_text(json.dumps(value))
PY_REMOTE
mv "$HOME_FIX/state/secondmate-summary-cache" "$HOME_FIX/parent-cache-disabled"
# Clearing the prior read failure must not rearm the existing silence alarm.
assert_not_contains "$(run_alarm check)" 'inventory unavailable' 'published remote summary is read even without a fresh parent copy'
mv "$HOME_FIX/remote-summary" "$HOME_FIX/remote-summary-cleared"
mate 0 0 0
run_alarm check >/dev/null
pass 'cached remote inventory and parent-channel silence preserve source and freshness boundaries'

# One slow remote must leave enough budget to evaluate another mate locally.
mate 1 0 3601
printf -- '- slow - test domain (host: unreachable.invalid; root: /remote/code; home: /remote/slow; scope: test; projects: alpha; added 2026-10-26)\n' > "$HOME_FIX/slow-registry"
cat "$HOME_FIX/data/secondmates.md" >> "$HOME_FIX/slow-registry"
mv "$HOME_FIX/slow-registry" "$HOME_FIX/data/secondmates.md"
: > "$HOME_FIX/remote-slow"
printf '%s\n' '{"budget_seconds":3}' > "$HOME_FIX/config/fleet-alarm.json"
SECONDS=0
out=$(run_alarm check)
[ "$SECONDS" -lt 3 ] || fail 'slow remote starved the alarm budget'
assert_contains "$out" 'holding work silent' 'local mate is checked despite a slow remote'
assert_contains "$out" 'inventory unavailable: slow' 'unavailable remote remains visible'
mv "$HOME_FIX/remote-slow" "$HOME_FIX/remote-slow-cleared"
mv "$HOME_FIX/config/fleet-alarm.json" "$HOME_FIX/small-budget-cleared"
mate 0 0 0
run_alarm check >/dev/null
pass 'slow remote summary reads do not starve the silent-mate check'

cat > "$HOME_FIX/accounts" <<'ROWS'
accounts[2]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:
  exhausted@example.invalid,claude,0.1,,1.0,window1,,1,0
  member@example.invalid,claude,0.1,,0.2,window1,,1,0
ROWS
out=$(run_alarm check)
[ -z "$out" ] || fail "exhausted idle account with pool headroom must not alarm: $out"
mate 1 0 3601
out=$(run_alarm check)
assert_contains "$out" 'exhausted@example.invalid 7d 100%' 'account pressure remains informational in card text'
assert_contains "$out" 'Carrying Claude accounts: member@example.invalid' 'successful recent traffic identifies carrying account'
mate 0 0 0
quota 0.2
run_alarm check >/dev/null
pass 'idle exhausted account does not alarm while the pool has headroom'

# Several carrying accounts: failed-only requests and other providers do not qualify.
cat > "$HOME_FIX/accounts" <<'ROWS'
accounts[3]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:
  first@example.invalid,claude,0.1,,0.91,window1,,1,0
  second@example.invalid,claude,0.1,,0.92,window1,,1,0
  failed@example.invalid,claude,0.1,,1.0,window1,,1,0
ROWS
cat > "$HOME_FIX/models" <<'ROWS'
models[4]{account,model,requests,failed}:
  first@example.invalid,claude-opus-5-5,5,0
  second@example.invalid,claude-sonnet-5-5,5,4
  failed@example.invalid,claude-opus-5-5,2,2
  foreign@example.invalid,gpt-6.1-sol,5,0
ROWS
out=$(run_alarm check)
assert_contains "$out" 'Carrying Claude account first@example.invalid 7d 91%' 'first carrying account alarms'
assert_contains "$out" 'Carrying Claude account second@example.invalid 7d 92%' 'second carrying account alarms'
assert_contains "$out" 'Carrying Claude accounts: first@example.invalid, second@example.invalid' 'all carrying accounts named'
assert_not_contains "$out" 'Carrying Claude account failed@example.invalid' 'failed-only traffic does not carry'
assert_not_contains "$out" 'foreign@example.invalid' 'other provider traffic does not carry'
# Clear previous conditions before testing no carrying traffic.
quota 0.2
run_alarm check >/dev/null
cat > "$HOME_FIX/models" <<'ROWS'
models[1]{account,model,requests,failed}:
  member@example.invalid,claude-opus-5-5,3,3
ROWS
quota 0.91
out=$(run_alarm check)
assert_contains "$out" 'pool near empty' 'pool alarms without a carrying account'
assert_contains "$out" 'Carrying Claude accounts: none (no successful Claude traffic in last 60 minutes)' 'no carrying account explained'
assert_not_contains "$out" 'Carrying Claude account member@example.invalid' 'failed-only traffic skips carrying condition'
quota 0.2
run_alarm check >/dev/null
mate 1 0 3601
out=$(run_alarm check)
assert_contains "$out" 'holding work silent' 'silent-mate alarm survives no recent successful traffic'
assert_contains "$out" 'Carrying Claude accounts: none' 'idle traffic status included in mate card'
mate 0 0 0
cat > "$HOME_FIX/models" <<'ROWS'
models[1]{account,model,requests,failed}:
  member@example.invalid,claude-opus-5-5,5,0
ROWS
quota 0.2
run_alarm check >/dev/null
pass 'one, several, and no carrying accounts use successful Claude traffic only'

cat > "$HOME_FIX/accounts" <<'ROWS'
accounts[2]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:
  low@example.invalid,claude,0.1,,0.95,window1,,1,0
  stale@example.invalid,claude,0.1,,0.0,window1,,121,0
ROWS
out=$(run_alarm check)
assert_contains "$out" 'pool near empty' 'stale headroom cannot inflate live pool mean'
assert_contains "$out" 'reading stale: stale@example.invalid' 'stale alarm retained'
quota 0.2
run_alarm check >/dev/null
pass 'pool mean excludes stale readings'

printf '  # Quota reader host\n\n \t \n \tlocal \t\r\nignored-host\n' > "$HOME_FIX/config/cpa-usage-host"
quota 0.91
out=$(run_alarm check)
assert_contains "$out" '7d 91%' 'commented host config reaches the quota reader'
assert_not_contains "$out" 'configuration invalid' 'comments and whitespace are accepted'
mv "$HOME_FIX/config/cpa-usage-host" "$HOME_FIX/host-config-cleared"
quota 0.2
run_alarm check >/dev/null
pass 'host config uses the first non-comment non-blank line with surrounding whitespace trimmed'

printf '%s\n' 'invalid host contents' > "$HOME_FIX/config/cpa-usage-host"
out=$(run_alarm check)
assert_contains "$out" 'Fleet alarm configuration invalid: invalid cpa-usage-host' 'collection error reason reaches output'
assert_not_contains "$out" 'invalid host contents' 'invalid config contents are not exposed'
mv "$HOME_FIX/config/cpa-usage-host" "$HOME_FIX/invalid-host-config-cleared"
run_alarm check >/dev/null
pass 'collection errors report the actual reason without echoing config contents'

quota 0.91
out=$(run_alarm check)
assert_contains "$out" '7d 91%' 'account threshold'
assert_contains "$(cat "$HOME_FIX/quota-calls")" 'models --hours 1 --limit 1000' 'carrying uses a bounded traffic window'
[ -z "$(run_alarm check)" ] || fail 'threshold alert must deduplicate'
quota 0.92
[ -z "$(run_alarm check)" ] || fail 'changed pressure text must not re-fire an active condition'
quota 0.91 1 window2
assert_contains "$(run_alarm check)" 'window2' 'new reset window rearms'
quota 0.2
run_alarm check >/dev/null
quota 0.91
assert_contains "$(run_alarm check)" '7d 91%' 'clear rearms threshold'
pass 'carrying threshold deduplicates per reset window'

quota 0.2
run_alarm check >/dev/null
quota 1 1 2026-10-30T15:00Z
assert_contains "$(run_alarm check)" 'member@example.invalid 7d 100%' 'first exhausted account reading alerts'
quota 1 1 2026-10-30T14:59Z
[ -z "$(run_alarm check)" ] || fail 'one-minute backwards reset drift must not re-alert'
quota 1 1 2026-11-06T14:59Z
assert_contains "$(run_alarm check)" 'member@example.invalid 7d 100%' 'a different weekly reset window rearms'
quota 0.2
run_alarm check >/dev/null
quota 1 1 2026-10-27T05:59Z
assert_contains "$(run_alarm check)" 'member@example.invalid 7d 100%' 'first reading before the hour alerts'
quota 1 1 2026-10-27T06:00Z
[ -z "$(run_alarm check)" ] || fail 'one-minute forwards reset drift must not re-alert'
pass 'minute-level reset drift deduplicates within the hour while new weekly windows rearm'

quota 0.2
run_alarm check >/dev/null
quota 0.99
assert_contains "$(run_alarm check)" 'pool near empty' 'pool threshold'
quota 0.2 121
assert_contains "$(run_alarm check)" 'reading stale' 'stale account snapshot'
[ -z "$(run_alarm check)" ] || fail 'stale reading must deduplicate'
quota 0.2
run_alarm check >/dev/null
printf '%s\n' bad > "$HOME_FIX/accounts"
assert_contains "$(run_alarm check)" 'Claude quota unavailable; reading may be stale: ValueError: no accounts header in quota reading' 'malformed data is unknown, not healthy, and names its cause'
quota 0.2
run_alarm check >/dev/null
pass 'pool exhaustion, stale readings and malformed data alert'

mate 1 0 3599
[ -z "$(run_alarm check)" ] || fail 'a mate heard from 59 minutes ago is awake'
mate 1 0 3601
assert_contains "$(run_alarm check)" 'holding work silent' 'silent in-flight work'
[ -z "$(run_alarm check)" ] || fail 'silent mate must deduplicate'
mate 1 0 1
[ -z "$(run_alarm check)" ] || fail 'recent agent event proves communication'
mate 1 0 3660
assert_contains "$(run_alarm check)" 'holding work silent' 'fresh summary and parent answer are not agent communication'
mate 0 0 0
run_alarm check >/dev/null
mate 0 1 3601
assert_contains "$(run_alarm check)" 'holding work silent' 'open decisions count as work'
mate 0 0 3601
[ -z "$(run_alarm check)" ] || fail 'idle must clear silent condition'
pass 'in-flight and decision work alarm after 60 minutes of agent silence; agent communication clears'
mate 0 0 3601
jq '.counts.in_flight=1' "$TMP_ROOT/mate/state/home-summary.json" > "$HOME_FIX/next-snapshot"
mv "$HOME_FIX/next-snapshot" "$TMP_ROOT/mate/state/home-summary.json"
assert_contains "$(run_alarm check)" 'holding work silent' 'program in flight also counts as work'
mate 0 0 0
run_alarm check >/dev/null
pass 'in-flight programs count even without an active worker'
now=$(date +%s)
mate 1 0 null "s$((now - 300)).1.1"
[ -z "$(run_alarm check)" ] || fail 'a mate spawned five minutes ago without an event is not silent'
mate 1 0 9000 "s$((now - 300)).1.1"
[ -z "$(run_alarm check)" ] || fail 'a relaunched mate gets a fresh silence window'
mate 1 0 null "s$((now - 3700)).1.1"
assert_contains "$(run_alarm check)" 'holding work silent' 'silence counts from spawn when the mate never reported'
mate 0 0 0
run_alarm check >/dev/null
pass 'silence without an agent event is measured from spawn'
now=$(date +%s)
mate 0 0 3601
printf '%s\n' "needs-decision [at=$((now - 4000))] [key=raised-to-main]: which way?" \
  "working [at=$((now - 3601))]: agent event" > "$HOME_FIX/state/mate.status"
assert_contains "$(run_alarm check)" 'holding work silent' "a decision raised in main's channel counts as work"
printf '%s\n' "resolved [at=$((now - 3700))] [key=raised-to-main]: answered" >> "$HOME_FIX/state/mate.status"
[ -z "$(run_alarm check)" ] || fail "a resolved decision in main's channel is not work"
mate 0 0 0
run_alarm check >/dev/null
mate 0 0 3601
python3 - "$HOME_FIX/state/mate.status" "$now" <<'PY_OLD'
import sys
path, now = sys.argv[1], int(sys.argv[2])
with open(path, 'w') as status:
    status.write(f'blocked [at={now - 9000}] [key=ancient]: outside the window\n')
    status.write(''.join(f'note [at={now - 8000}]: {"x" * 200} {i}\n' for i in range(400)))
    status.write(f'working [at={now - 3601}]: agent event\n')
PY_OLD
[ -z "$(run_alarm check)" ] || fail "only a bounded tail of main's channel is folded"
mate 0 0 0
run_alarm check >/dev/null
pass "open needs-decision and blocked lines in main's bounded channel tail count as work"


mate 0 0 0
quota 0.99
run_alarm check >/dev/null
: > "$HOME_FIX/config/fleet-ledger"
[ -z "$(run_alarm timer)" ] || fail 'timer publishes through ledger without stdout'
assert_contains "$(cat "$HOME_FIX/state/fleet-ledger.jsonl")" 'needs-decision' 'timer publishes without a watcher'
before=$(wc -l < "$HOME_FIX/state/fleet-ledger.jsonl")
run_alarm timer
[ "$(wc -l < "$HOME_FIX/state/fleet-ledger.jsonl")" = "$before" ] || fail 'timer must deduplicate'
pass 'independent timer delivery survives prior check receipt and deduplicates'
: > "$HOME_FIX/quota-fail"
assert_contains "$(run_alarm check)" 'quota unavailable' 'read failure alerts separately'
# A failed read must preserve known active conditions, not rearm them.
mv "$HOME_FIX/quota-fail" "$HOME_FIX/quota-fail-cleared"
[ -z "$(run_alarm check)" ] || fail 'unknown read must not rearm an uncleared threshold'
quota 0.2
run_alarm check >/dev/null
run_alarm timer
assert_contains "$(cat "$HOME_FIX/state/fleet-ledger.jsonl")" 'resolved' 'cleared timer alert closes its log decision'
quota 0.99
run_alarm timer
cat > "$HOME_FIX/accounts" <<'ROWS'
accounts[2]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:
  live@example.invalid,claude,0.1,,0.2,window1,,1,0
  retired@example.invalid,claude,0.1,,0.1,window1,,20000,0
ROWS
run_alarm timer
[ "$(tail -n 1 "$HOME_FIX/state/fleet-ledger.jsonl" | grep -c resolved)" = 1 ] || fail 'ignored accounts must not keep the card open'
before=$(wc -l < "$HOME_FIX/state/fleet-ledger.jsonl")
run_alarm timer
[ "$(wc -l < "$HOME_FIX/state/fleet-ledger.jsonl")" = "$before" ] || fail 'ignored accounts alone must not reopen the card'
pass 'read failures retain dedupe history and healthy timer reads close alerts'


run_alarm timer-files linux "$TMP_ROOT/units"
assert_contains "$(cat "$TMP_ROOT/units/firstmate-fleet-alarm.service")" 'timer' 'systemd runs timer action'
assert_contains "$(cat "$TMP_ROOT/units/firstmate-fleet-alarm.timer")" 'OnUnitActiveSec=5min' 'systemd cadence'
run_alarm timer-files darwin "$TMP_ROOT/plists"
python3 - "$TMP_ROOT/plists/com.firstmate.fleet-alarm.plist" "$HOME_FIX" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as file:
    value = plistlib.load(file)
assert value['ProgramArguments'][-1] == 'timer'
assert value['EnvironmentVariables']['FM_HOME'] == sys.argv[2]
assert value['StartInterval'] == 300
PY
pass 'launchd and systemd timer files target the primary home'

quota 0.2
run_alarm check >/dev/null
cat > "$HOME_FIX/accounts" <<'ROWS'
accounts[3]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:
  busy@example.invalid,claude,0.1,,0.95,window1,,1,0
  reserve@example.invalid,claude,0.1,,0.2,window1,,1,0
  codex@example.invalid,codex,0.1,,0.99,window1,,1,0
ROWS
cat > "$HOME_FIX/models" <<'ROWS'
models[2]{account,model,requests,failed}:
  busy@example.invalid,claude-opus-5-5,5,0
  codex@example.invalid,gpt-6.1-sol,5,0
ROWS
out=$(run_alarm check)
assert_contains "$out" 'busy@example.invalid' 'every Claude account is checked'
assert_not_contains "$out" 'codex@example.invalid' 'Codex account is outside Claude pool'
assert_not_contains "$out" 'pool near empty' 'healthy reserve prevents pool alarm'
pass 'carrying account alerts preserve healthy pool reserves and exclude other providers'
cat > "$HOME_FIX/models" <<'ROWS'
models[1]{account,model,requests,failed}:
  member@example.invalid,claude-opus-5-5,5,0
ROWS
quota 0.2
run_alarm check >/dev/null

cat > "$HOME_FIX/accounts" <<'ROWS'
accounts[2]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:
  busy@example.invalid,claude,0.1,,0.95,window1,,1,0
  new@example.invalid,claude,,,,,,,0
ROWS
out=$(run_alarm check)
assert_contains "$out" 'busy@example.invalid 7d 95%' 'a blank account cannot hide another account threshold'
assert_contains "$out" 'reading unknown: new@example.invalid' 'blank reading is unknown'
assert_contains "$out" 'pool near empty' 'blank account is excluded from the pool mean'
assert_not_contains "$out" 'quota unavailable' 'one blank row is not a failed read'
pass 'one account without a reading does not blind the others'
quota 0.2
run_alarm check >/dev/null

# 10080 minutes is seven days: the retired account is old enough to ignore.
cat > "$HOME_FIX/accounts" <<'ROWS'
accounts[2]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:
  live@example.invalid,claude,0.1,,0.2,window1,,1,0
  retired@example.invalid,claude,0.1,,0.1,window1,,10080,0
ROWS
out=$(run_alarm check)
assert_contains "$out" '1 ignored stale Claude accounts' 'retired account is counted once'
assert_not_contains "$out" 'retired@example.invalid' 'retired account raises no stale alarm'
[ -z "$(run_alarm check)" ] || fail 'ignored-account note must deduplicate'
cat > "$HOME_FIX/accounts" <<'ROWS'
accounts[2]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:
  live@example.invalid,claude,0.1,,0.95,window1,,1,0
  retired@example.invalid,claude,0.1,,0.1,window1,,10080,0
ROWS
assert_contains "$(run_alarm check)" 'pool near empty' 'retired account is excluded from the pool mean'
pass 'accounts without a reading for seven days are ignored and counted'

printf '%s\n' '{"budget_seconds":999}' > "$HOME_FIX/config/fleet-alarm.json"
assert_contains "$(run_alarm check)" 'configuration invalid' 'invalid timeout budget refused'
pass 'configuration cannot exceed the registered check deadline'

printf '%s\n' '{"budget_seconds":20,"silent_minutes":1,"stale_minutes":2,"seven_day":0.8,"pool_remaining":0.05}' > "$HOME_FIX/config/fleet-alarm.json"
quota 0.91 3
mate 1 0 59
out=$(run_alarm check)
assert_contains "$out" 'reading stale' 'configured stale age'
assert_not_contains "$out" 'holding work silent' 'configured silence age not yet reached'
mate 1 0 61
assert_contains "$(run_alarm check)" 'over 1 minutes' 'configured silence age'
assert_contains "$out" 'Carrying Claude account member@example.invalid' 'configured carrying threshold'
pass 'operator thresholds control quota, staleness and silence'

mate 0 0 0
printf '%s\n' '- malformed registry entry' > "$HOME_FIX/data/secondmates.md"
assert_contains "$(run_alarm check)" 'inventory unavailable' 'malformed registry alerts'
pass 'registry read failures cannot appear healthy'

mate 0 0 0
run_alarm check >/dev/null
printf '%s\n' '{}' > "$TMP_ROOT/mate/state/home-summary.json"
assert_contains "$(run_alarm check)" "Secondmate work inventory unavailable: mate: 'schema'" 'inventory failure names its cause'
mate 0 0 0
run_alarm check >/dev/null
: > "$HOME_FIX/quota-fail"
assert_contains "$(run_alarm check)" 'Claude quota unavailable; reading may be stale: ValueError: reader unavailable or timed out' 'quota failure names its cause'
mv "$HOME_FIX/quota-fail" "$HOME_FIX/quota-fail-cleared"
run_alarm check >/dev/null
pass 'reader failures report the exception type and reason'

cat > "$BIN_FIX/fm-check-register.sh" <<'SH'
#!/usr/bin/env bash
exec "$ROOT/bin/fm-check-register.sh" "$@"
SH
chmod +x "$BIN_FIX/fm-check-register.sh"
assert_contains "$(run_alarm arm)" 'registered: state/fleet-alarm.check.sh' 'check is registered'
[ -x "$HOME_FIX/state/fleet-alarm.check.sh" ] || fail 'shim must be executable'
if run_alarm arm >/dev/null 2>&1; then fail 'arming cannot overwrite an existing check'; fi
pass 'arming uses the existing trust registration and refuses replacement'
