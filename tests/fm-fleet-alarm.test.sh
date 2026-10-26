#!/usr/bin/env bash
# Offline executable fixtures: quota, stale reads, secondmate work, independent
# timer delivery, reset-window dedupe, configuration and scheduler generation.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-alarm)
HOME_FIX="$TMP_ROOT/home"
BIN_FIX="$TMP_ROOT/bin"
mkdir -p "$HOME_FIX/state" "$HOME_FIX/config" "$BIN_FIX"
cp "$ROOT/bin/fm-fleet-alarm.py" "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-env-lib.sh" "$BIN_FIX/"
cat > "$BIN_FIX/cpa-usage-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/quota-calls"
[ ! -f "$FM_HOME/quota-fail" ] || exit 1
if [ "$1" = check ]; then
  cat "$FM_HOME/threshold"
else
  cat "$FM_HOME/accounts"
fi
SH
cat > "$BIN_FIX/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
[ ! -f "$FM_HOME/mate-fail" ] || exit 1
cat "$FM_HOME/snapshot"
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
  if [ "$used" = 0.2 ]; then
    : > "$HOME_FIX/threshold"
  else
    printf '%s\n' "alert: member@example.invalid 7d ${used#0.}% (resets $reset)" > "$HOME_FIX/threshold"
  fi
}
# The watcher summary and main's own last line are always fresh here; only the
# mate's own event age and its spawn time may prove it awake.
mate() {
  local active=$1 decisions=$2 agent=$3 spawn=${4:-}
  jq -n --argjson active "$active" --argjson decisions "$decisions" \
    --argjson agent "$agent" --arg spawn "$spawn" \
    '{secondmate_current:{registry:{complete:true},records:[{id:"mate",registered:true,
      spawn_gen:(if $spawn == "" then null else $spawn end),
      current:{state:"active_child_work"},
      counts:{active_children:$active,decisions_open:$decisions,holds:0},
      freshness:{age_seconds:0},parent_event:{age_seconds:0,agent_age_seconds:$agent}}],truncated:0}}' > "$HOME_FIX/snapshot"
}
run_alarm() {
  ROOT="$ROOT" FM_HOME="$HOME_FIX" PATH="$BIN_FIX:$PATH" TMPDIR="$TMP_ROOT" \
    python3 "$BIN_FIX/fm-fleet-alarm.py" "$@"
}
quota 0.2
mate 0 0 9000
out=$(run_alarm check)
[ -z "$out" ] || fail "idle mates and healthy quota must be silent: $out"
pass 'idle secondmate never alarms, regardless of silence'

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
assert_contains "$(cat "$HOME_FIX/quota-calls")" 'check --five-hour off --seven-day 0.9' 'tool owns threshold check'
[ -z "$(run_alarm check)" ] || fail 'threshold alert must deduplicate'
quota 0.91 1 window2
assert_contains "$(run_alarm check)" 'window2' 'new reset window rearms'
quota 0.2
run_alarm check >/dev/null
quota 0.91
assert_contains "$(run_alarm check)" '7d 91%' 'clear rearms threshold'
pass 'weekly threshold uses tool check and deduplicates per reset window'

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
jq '.secondmate_current.records[0].counts.in_flight=1' "$HOME_FIX/snapshot" > "$HOME_FIX/next-snapshot"
mv "$HOME_FIX/next-snapshot" "$HOME_FIX/snapshot"
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
: > "$HOME_FIX/threshold"
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
printf '%s\n' 'alert: busy@example.invalid 7d 95% (resets window1); codex@example.invalid/codex 7d 99%' > "$HOME_FIX/threshold"
out=$(run_alarm check)
assert_contains "$out" 'busy@example.invalid' 'every Claude account is checked'
assert_not_contains "$out" 'codex@example.invalid' 'Codex account is outside Claude pool'
assert_not_contains "$out" 'pool near empty' 'healthy reserve prevents pool alarm'
pass 'account alerts preserve healthy pool reserves and exclude other providers'
quota 0.2
run_alarm check >/dev/null

cat > "$HOME_FIX/accounts" <<'ROWS'
accounts[2]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:
  busy@example.invalid,claude,0.1,,0.95,window1,,1,0
  new@example.invalid,claude,,,,,,,0
ROWS
printf '%s\n' 'alert: busy@example.invalid 7d 95% (resets window1)' > "$HOME_FIX/threshold"
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
: > "$HOME_FIX/threshold"
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
assert_contains "$(cat "$HOME_FIX/quota-calls")" '--seven-day 0.8' 'configured weekly threshold'
pass 'operator thresholds control quota, staleness and silence'

mate 0 0 0
jq '.secondmate_current.registry.complete=false' "$HOME_FIX/snapshot" > "$HOME_FIX/next-snapshot"
mv "$HOME_FIX/next-snapshot" "$HOME_FIX/snapshot"
assert_contains "$(run_alarm check)" 'inventory incomplete' 'incomplete registry alerts'
pass 'registry read failures cannot appear healthy'

mate 0 0 0
run_alarm check >/dev/null
printf '%s\n' '{}' > "$HOME_FIX/snapshot"
assert_contains "$(run_alarm check)" "Secondmate work inventory unavailable: KeyError: 'secondmate_current'" 'inventory failure names its cause'
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
