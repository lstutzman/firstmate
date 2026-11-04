#!/usr/bin/env bash
# Behavior tests for bin/fm-officer.sh, the officer agent kind.
#
# Covers the kind's contract through its executable interface: registering
# and retiring an officer's watcher check, the check's report line (exactly one
# per new actionable digest, silence on repeats, empty digests, and an
# unreachable archive host or a late harvester until its attempts run out), the
# scheduled run the check starts outside its own process group, the OFFICER:
# health lines from ensure, the primary-home-only rule, the write lane, and the fleet boundary
# (an officer run calls no fleet-acting script and no forge or Linear tool).
set -u

# shellcheck source=tests/officer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/officer-helpers.sh"

OFFICER="$ROOT/bin/fm-officer.sh"
TMP_ROOT=$(fm_test_tmproot fm-officer)
DATE=2026-10-23
# 2026-10-24 07:00 UTC: past a 06:00 cadence, with yesterday = $DATE.
NOW=1792825200
export TZ=UTC

empty_spec() {
  printf '{"sessions": [{"machine": "alpha", "id": "s1", "first_prompt": "hello", "calls": [["Bash", {"command": "rm -f /tmp/x"}, "", false]]}]}\n' > "$1"
}

clean_spec() {
  printf '{"sessions": [{"machine": "alpha", "id": "s1", "first_prompt": "hello", "calls": []}], "harvested": "2026-10-24T01:00:00+00:00"}\n' > "$1"
}

late_spec() {
  printf '{"sessions": [{"machine": "alpha", "id": "s1", "first_prompt": "hello", "calls": [["Bash", {"command": "rm -f /tmp/x"}, "", false]]}], "harvested": "2026-10-23T10:00:00+00:00"}\n' > "$1"
}

# make_world <name> <spec-writer>: a registered-ready home and its archive.
make_world() {
  local name=$1 writer=$2 home archive
  home="$TMP_ROOT/$name/home"
  archive="$TMP_ROOT/$name/archive"
  officer_home "$home"
  "$writer" "$TMP_ROOT/$name/spec.json"
  officer_archive "$archive" "$DATE" "$TMP_ROOT/$name/spec.json"
  officer_registry "$home" "$archive" alpha
  printf '%s\n' "$home"
}

# nav_office <home> <sources>: a local navigator office of <home> listing <sources>,
# with its wake-source checks registered the way its home would register them.
nav_office() {
  local home=$1 nav="$1/../navigator"
  mkdir -p "$nav/data"
  printf 'navigator\n' > "$nav/.fm-office"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home" > "$nav/.fm-secondmate-parent"
  printf -- '- navigator - nav (home: %s; scope: office; projects: none; added 2026-11-04)\n' "$nav" > "$home/data/secondmates.md"
  printf -- '- navigator - nav (role: navigator; sources: %s; added 2026-11-04)\n' "$2" > "$home/data/offices.md"
  FM_HOME="$nav" "$ROOT/bin/fm-office.sh" register-sources >/dev/null || fail "register-sources must succeed in the navigator home"
}

officer() {  # <home> <args...>
  local home=$1
  shift
  FM_OFFICER_NOW=$NOW FM_HOME="$home" "$OFFICER" "$@"
}

wait_for_run() {  # <home>: until the scheduled run has logged an attempt.
  local i=0
  until grep -q " $DATE " "$1/data/officers/triage/runs.log" 2>/dev/null && [ ! -d "$1/data/officers/triage/.run.lock" ]; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || fail "the scheduled run never finished"
    sleep 0.1
  done
}

test_register_and_retire() {
  local home out
  home=$(make_world register empty_spec)
  out=$(officer "$home" register triage) || fail "register must succeed: $out"
  assert_contains "$out" "registered: officer triage" "register names the officer"
  assert_present "$home/state/officer-triage.check.sh" "register writes the check"
  assert_present "$home/state/officer-triage.check-trust" "register trusts the check"
  assert_contains "$(cat "$home/state/officer-triage.check.sh")" "fm-officer.sh check triage" "the check runs the officer check"
  assert_contains "$(officer "$home" list)" "check=registered" "list shows the registered check"
  officer "$home" run triage --date "$DATE" >/dev/null || fail "run must succeed"
  out=$(officer "$home" retire triage) || fail "retire must succeed: $out"
  assert_absent "$home/state/officer-triage.check.sh" "retire removes the check"
  assert_absent "$home/state/officer-triage.check-trust" "retire removes the trust binding"
  assert_no_grep "- triage - " "$home/data/officers.md" "retire removes the registry line"
  assert_present "$home/data/officers/triage/$DATE.json" "retire keeps the findings"
  pass "fm-officer: register installs a trusted check; retire removes it and keeps findings"
}

test_check_reports_each_new_actionable_digest_once() {
  local home out
  home=$(make_world report empty_spec)
  officer "$home" register triage >/dev/null || fail "register must succeed"
  officer "$home" run triage --date "$DATE" >/dev/null || fail "run must succeed"
  out=$(officer "$home" check triage) || fail "check must exit 0"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "a new actionable digest prints exactly one line"
  assert_contains "$out" "officer triage: $DATE: " "the line names the officer and date"
  assert_contains "$out" "data/officers/triage/$DATE.md" "the line points at the digest"
  out=$(officer "$home" check triage) || fail "repeat check must exit 0"
  assert_equals "" "$out" "a repeated digest prints nothing"
  pass "fm-officer: check prints one line for a new actionable digest and none on repeat"
}

test_check_is_silent_for_an_empty_digest() {
  local home out
  home=$(make_world quiet clean_spec)
  officer "$home" run triage --date "$DATE" >/dev/null || fail "run must succeed"
  assert_grep "DIGEST $DATE 0 " "$home/data/officers/triage/digest" "nothing actionable gives a zero digest"
  out=$(officer "$home" check triage) || fail "check must exit 0"
  assert_equals "" "$out" "an empty digest prints nothing"
  pass "fm-officer: check is silent for a digest with nothing actionable"
}

test_scheduled_run_starts_from_the_check_and_reports() {
  local home out
  home=$(make_world schedule empty_spec)
  officer "$home" register triage >/dev/null || fail "register must succeed"
  out=$(FM_OFFICER_NOW=$((NOW - 7200)) FM_HOME="$home" "$OFFICER" check triage) || fail "early check must exit 0"
  assert_equals "" "$out" "before the cadence time the check starts nothing"
  assert_absent "$home/data/officers/triage/runs.log" "no run before the cadence time"
  # Run the check the way the watcher does: in its own process group, which
  # is stopped as soon as the check returns.
  (
    set -m
    FM_OFFICER_NOW=$NOW FM_HOME="$home" bash "$home/state/officer-triage.check.sh" >/dev/null &
    pid=$!
    wait "$pid"
    kill -KILL -- "-$pid" 2>/dev/null || true
  )
  wait_for_run "$home"
  assert_grep "$DATE ok" "$home/data/officers/triage/runs.log" "the scheduled run outlives the check's process group"
  out=$(officer "$home" check triage) || fail "check must exit 0"
  assert_contains "$out" "officer triage: $DATE: " "the next check reports the scheduled digest"
  out=$(officer "$home" check triage)
  assert_equals 1 "$(grep -c " $DATE " "$home/data/officers/triage/runs.log")" "a finished date is not rerun"
  pass "fm-officer: the check starts a due run detached, and reports it once finished"
}

test_same_day_manual_run_does_not_block_the_next_scheduled_run() {
  local home
  home=$(make_world manualday empty_spec)
  officer "$home" register triage >/dev/null || fail "register must succeed"
  # A manual run for $DATE at 18:00 that same day, the evening before the check.
  FM_OFFICER_NOW=$((NOW - 46800)) FM_HOME="$home" "$OFFICER" run triage --date "$DATE" >/dev/null || fail "manual run must succeed"
  assert_equals 1 "$(grep -c " $DATE ok" "$home/data/officers/triage/runs.log")" "one manual run is logged"
  officer "$home" check triage >/dev/null || fail "check must exit 0"
  wait_for_attempts "$home" 2
  assert_equals 2 "$(grep -c " $DATE ok" "$home/data/officers/triage/runs.log")" "the next morning's check runs $DATE again despite the manual run"
  mv "$home/data/officers/triage/run-output.log" "$home/data/officers/triage/run-output.first.log"
  FM_OFFICER_RETRY_SECS=0 officer "$home" check triage >/dev/null || fail "check must exit 0"
  assert_absent "$home/data/officers/triage/run-output.log" "a run finished since the cadence time is not repeated"
  pass "fm-officer: a same-day manual run does not block the next day's scheduled run"
}

test_manual_run_after_the_cadence_time_is_not_repeated() {
  local home
  home=$(make_world manuallate empty_spec)
  officer "$home" register triage >/dev/null || fail "register must succeed"
  # 06:30 on the check's day, after the 06:00 cadence time.
  FM_OFFICER_NOW=$((NOW - 1800)) FM_HOME="$home" "$OFFICER" run triage --date "$DATE" >/dev/null || fail "manual run must succeed"
  FM_OFFICER_RETRY_SECS=0 officer "$home" check triage >/dev/null || fail "check must exit 0"
  assert_absent "$home/data/officers/triage/run-output.log" "a manual run since the cadence time satisfies the schedule"
  pass "fm-officer: a manual run since the cadence time is not repeated"
}

test_unreachable_host_is_silent_until_attempts_run_out() {
  local home fakebin out i
  home=$(make_world unreachable empty_spec)
  fakebin=$(fm_fakebin "$TMP_ROOT/unreachable")
  printf '#!/usr/bin/env bash\nexit 255\n' > "$fakebin/ssh"
  chmod +x "$fakebin/ssh"
  officer_registry "$home" "deadhost:/nowhere" alpha
  out=$(PATH="$fakebin:$PATH" FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=2 officer "$home" check triage) || fail "check must exit 0"
  wait_for_run "$home"
  out=$(PATH="$fakebin:$PATH" FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=2 officer "$home" check triage) || fail "check must exit 0"
  assert_equals "" "$out" "a first unreachable attempt is silent"
  i=0
  until [ "$(grep -c "$DATE failed" "$home/data/officers/triage/runs.log")" -ge 2 ] && [ ! -d "$home/data/officers/triage/.run.lock" ]; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || fail "the retry never ran"
    sleep 0.1
  done
  out=$(PATH="$fakebin:$PATH" FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=2 officer "$home" check triage) || fail "check must exit 0"
  assert_contains "$out" "run failed 2 time(s)" "the last failed attempt is reported once"
  out=$(PATH="$fakebin:$PATH" FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=2 officer "$home" check triage)
  assert_equals "" "$out" "the failure is not repeated"
  pass "fm-officer: an unreachable archive host stays silent until its attempts run out"
}

wait_for_attempts() {  # <home> <n>: until <n> attempts for $DATE are logged and no run holds the lock.
  local i=0
  until [ "$(cat "$1/data/officers/triage/runs.log" 2>/dev/null | awk -v d="$DATE" '$2 == d {n++} END {print n + 0}')" -ge "$2" ] \
    && [ ! -d "$1/data/officers/triage/.run.lock" ]; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || fail "attempt $2 never finished"
    sleep 0.1
  done
}

test_late_harvester_is_retried_then_reported() {
  local home out
  home=$(make_world late late_spec)
  out=$(FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=3 officer "$home" check triage) || fail "check must exit 0"
  wait_for_attempts "$home" 1
  assert_grep "$DATE failed fm-officer-triage: archive harvester has not run since $DATE ended" "$home/data/officers/triage/runs.log" \
    "a day the harvester has not finished is a failed attempt"
  printf '%s\n' '{"started": "2026-10-24T01:00:00+00:00"}' > "$TMP_ROOT/late/archive/runs.jsonl"
  out=$(FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=3 officer "$home" check triage) || fail "check must exit 0"
  assert_equals "" "$out" "a failed attempt with attempts left is silent"
  wait_for_attempts "$home" 2
  assert_grep "$DATE ok" "$home/data/officers/triage/runs.log" "the retry analyses the day once the harvester catches up"
  out=$(FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=3 officer "$home" check triage) || fail "check must exit 0"
  assert_contains "$out" "officer triage: $DATE: 1 actionable finding(s)" "the caught-up day is reported as a digest"

  home=$(make_world latefail late_spec)
  out=$(FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=2 officer "$home" check triage) || fail "check must exit 0"
  wait_for_attempts "$home" 1
  out=$(FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=2 officer "$home" check triage) || fail "check must exit 0"
  wait_for_attempts "$home" 2
  out=$(FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=2 officer "$home" check triage) || fail "check must exit 0"
  assert_contains "$out" "officer triage: $DATE: run failed 2 time(s): " "a harvester still late after the last attempt is a failed run"
  assert_contains "$out" "archive harvester has not run since $DATE ended" "the failed run names the late harvester"
  assert_absent "$home/data/officers/triage/$DATE.json" "no digest is written for the unfinished day"
  pass "fm-officer: a late harvester is retried, then reported as a failed run once attempts run out"
}

test_failure_after_a_reported_digest_is_reported_once() {
  local home out
  home=$(make_world twokinds empty_spec)
  officer_archive "$TMP_ROOT/twokinds/archive" 2026-10-22 "$TMP_ROOT/twokinds/spec.json"
  officer "$home" run triage --date 2026-10-22 >/dev/null || fail "run for the earlier day must succeed"
  out=$(FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=1 officer "$home" check triage) || fail "check must exit 0"
  assert_contains "$out" "officer triage: 2026-10-22: 1 actionable finding(s)" "the earlier digest is reported"
  wait_for_attempts "$home" 1
  out=$(FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=1 officer "$home" check triage) || fail "check must exit 0"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "only the new failure is reported"
  assert_contains "$out" "officer triage: $DATE: run failed 1 time(s)" "the failed day is reported"
  out=$(FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=1 officer "$home" check triage) || fail "check must exit 0"
  assert_equals "" "$out" "neither the digest nor the failure is repeated"
  out=$(FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=1 officer "$home" check triage) || fail "check must exit 0"
  assert_equals "" "$out" "later checks stay silent"
  pass "fm-officer: a failure after a reported digest is reported once and neither line repeats"
}

test_timed_out_run_counts_as_an_attempt() {
  local home fakebin out i
  home=$(make_world timeout empty_spec)
  fakebin=$(fm_fakebin "$TMP_ROOT/timeout")
  printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$fakebin/ssh"
  chmod +x "$fakebin/ssh"
  officer_registry "$home" "slowhost:/archive" alpha
  out=$(PATH="$fakebin:$PATH" FM_OFFICER_RUN_TIMEOUT=1 FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=1 \
    officer "$home" check triage) || fail "check must exit 0"
  i=0
  until grep -q " $DATE " "$home/data/officers/triage/runs.log" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 150 ] || fail "the timed-out run was never logged"
    sleep 0.1
  done
  assert_grep "$DATE failed timed out" "$home/data/officers/triage/runs.log" "a run the timeout ends is logged as a failed attempt"
  out=$(PATH="$fakebin:$PATH" FM_OFFICER_RUN_TIMEOUT=1 FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=1 \
    officer "$home" check triage) || fail "check must exit 0"
  assert_contains "$out" "officer triage: $DATE: run failed 1 time(s): timed out" "a spent timed-out attempt is reported"
  assert_equals 1 "$(grep -c " $DATE " "$home/data/officers/triage/runs.log")" "no further run starts once attempts are spent"
  pass "fm-officer: a scheduled run that times out counts as a failed attempt"
}

test_ensure_reports_gaps_and_is_silent_when_healthy() {
  local home out
  home=$(make_world ensure clean_spec)
  out=$(officer "$home" ensure)
  assert_contains "$out" "OFFICER: officer triage: its watcher check is not registered" "an unregistered check is reported"
  officer "$home" register triage >/dev/null || fail "register must succeed"
  out=$(officer "$home" ensure)
  assert_equals "" "$out" "a freshly registered officer is healthy"
  out=$(FM_OFFICER_NOW=$((NOW + 3 * 86400)) FM_HOME="$home" "$OFFICER" ensure)
  assert_contains "$out" "no finished run since it was registered" "an officer that never ran within two cadences is reported"
  officer "$home" run triage --date "$DATE" >/dev/null || fail "run must succeed"
  out=$(officer "$home" ensure)
  assert_equals "" "$out" "a recent finished run is healthy"
  out=$(FM_OFFICER_NOW=$((NOW + 3 * 86400)) FM_HOME="$home" "$OFFICER" ensure)
  assert_contains "$out" "no finished run since" "a digest older than two cadences is reported"
  printf -- '- broken - no fields here\n' >> "$home/data/officers.md"
  assert_contains "$(officer "$home" ensure)" "OFFICER: malformed registry line" "a malformed line is reported"
  officer_registry "$home" "$TMP_ROOT/ensure/archive" alpha
  sed -i.bak 's/model: none/model: sonnet/' "$home/data/officers.md"
  assert_contains "$(officer "$home" ensure)" "is not available yet" "a model other than none is reported"
  pass "fm-officer: ensure prints OFFICER: lines for each gap and nothing when healthy"
}

wait_for_key() {  # <home> <key>: until the scheduled run has logged an attempt for the slot.
  local i=0
  until grep -q " $2 " "$1/data/officers/page-check/runs.log" 2>/dev/null && [ ! -d "$1/data/officers/page-check/.run.lock" ]; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || fail "the scheduled run for $2 never finished"
    sleep 0.1
  done
}

test_interval_cadence_runs_once_per_slot() {
  local home fakebin out c slot_a=2026-10-24T06 slot_b=2026-10-24T08
  home="$TMP_ROOT/interval/home"
  officer_home "$home"
  fakebin=$(fm_fakebin "$TMP_ROOT/interval")
  printf '#!/usr/bin/env bash\nprintf "\\n404"\n' > "$fakebin/curl"
  chmod +x "$fakebin/curl"
  officer_pagecheck_line() { printf -- '- page-check - Checks pages (role: pagecheck; cadence: %s; app: https://app.test; rules: %s/none; model: none; added 2026-10-24)\n' "$1" "$TMP_ROOT" > "$home/data/officers.md"; }
  for c in "every 0h" "every 25h" "every 2 hours"; do
    officer_pagecheck_line "$c"
    FM_HOME="$home" "$OFFICER" run page-check --date "$slot_a" >/dev/null 2>&1 && fail "cadence '$c' must be refused"
  done
  officer_pagecheck_line "every 2h"
  PATH="$fakebin:$PATH" FM_OFFICER_NOW=$NOW FM_HOME="$home" "$OFFICER" register page-check >/dev/null || fail "register must succeed"
  # NOW is 07:00 UTC, inside the slot that began at 06:00.
  PATH="$fakebin:$PATH" FM_OFFICER_NOW=$NOW FM_HOME="$home" "$OFFICER" check page-check >/dev/null || fail "check must exit 0"
  wait_for_key "$home" "$slot_a"
  assert_grep "$slot_a ok" "$home/data/officers/page-check/runs.log" "the first check in a slot starts that slot's run, keyed by the slot"
  out=$(PATH="$fakebin:$PATH" FM_OFFICER_NOW=$NOW FM_HOME="$home" "$OFFICER" check page-check)
  assert_contains "$out" "officer page-check: $slot_a: " "the next check reports the slot's digest"
  out=$(PATH="$fakebin:$PATH" FM_OFFICER_NOW=$((NOW + 1800)) FM_HOME="$home" "$OFFICER" check page-check)
  assert_equals "" "$out" "a repeat within the slot is silent"
  assert_equals 1 "$(grep -c " $slot_a " "$home/data/officers/page-check/runs.log")" "a finished slot is not run again"
  PATH="$fakebin:$PATH" FM_OFFICER_NOW=$((NOW + 3600)) FM_HOME="$home" "$OFFICER" check page-check >/dev/null || fail "check must exit 0"
  wait_for_key "$home" "$slot_b"
  assert_grep "$slot_b ok" "$home/data/officers/page-check/runs.log" "the next slot starts its own run two hours after the last slot began"
  assert_equals "" "$(FM_OFFICER_NOW=$((NOW + 3600)) FM_HOME="$home" "$OFFICER" ensure)" "an interval officer with a run in the last two periods is healthy"
  assert_contains "$(FM_OFFICER_NOW=$((NOW + 3600 + 5 * 3600)) FM_HOME="$home" "$OFFICER" ensure)" "(cadence every 2h)" \
    "ensure judges an interval officer against two of its own periods"
  pass "fm-officer: an interval cadence runs once per slot and ensure uses the interval"
}

wait_for_failures() {  # <home> <key> <count>: until the lane has logged that many failed attempts for the slot.
  local i=0
  until [ "$(grep -c " $2 failed" "$1/data/officers/page-check/runs.log" 2>/dev/null || true)" -ge "$3" ] 2>/dev/null \
    && [ ! -d "$1/data/officers/page-check/.run.lock" ]; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || fail "failed attempt $3 for $2 was never logged"
    sleep 0.1
  done
}

test_interval_failure_is_reported_once_across_slots() {
  local home fakebin base out n key=2026-10-24T06 next=2026-10-24T08
  home="$TMP_ROOT/intfail/home"
  officer_home "$home"
  fakebin=$(fm_fakebin "$TMP_ROOT/intfail")
  printf '#!/usr/bin/env bash\nprintf "\\n404"\n' > "$fakebin/curl"
  chmod +x "$fakebin/curl"
  printf -- '- page-check - Checks pages (role: pagecheck; cadence: every 2h; app: https://app.test; model: none; added 2026-10-24)\n' > "$home/data/officers.md"
  PATH="$fakebin:$PATH" FM_OFFICER_NOW=$NOW FM_HOME="$home" "$OFFICER" register page-check >/dev/null || fail "register must succeed"
  # A directory where the lane keeps state.json makes every run fail.
  mkdir -p "$home/data/officers/page-check/state.json"
  base=$((NOW - 3600))   # 06:00, the start of the slot
  for n in 1 2 3; do
    out=$(PATH="$fakebin:$PATH" FM_OFFICER_RETRY_SECS=1800 FM_OFFICER_NOW=$((base + (n - 1) * 1800)) FM_HOME="$home" "$OFFICER" check page-check)
    assert_equals "" "$out" "attempt $n is silent"
    wait_for_failures "$home" "$key" "$n"
  done
  out=$(PATH="$fakebin:$PATH" FM_OFFICER_RETRY_SECS=1800 FM_OFFICER_NOW=$((base + 5400)) FM_HOME="$home" "$OFFICER" check page-check)
  assert_contains "$out" "officer page-check: $key: run failed 3 time(s)" "an interval officer reports its failure after the last attempt in the slot"
  for n in 1 2 3; do
    PATH="$fakebin:$PATH" FM_OFFICER_RETRY_SECS=1800 FM_OFFICER_NOW=$((base + 7200 + (n - 1) * 1800)) FM_HOME="$home" "$OFFICER" check page-check >/dev/null
    wait_for_failures "$home" "$next" "$n"
  done
  out=$(PATH="$fakebin:$PATH" FM_OFFICER_RETRY_SECS=1800 FM_OFFICER_NOW=$((base + 7200 + 5400)) FM_HOME="$home" "$OFFICER" check page-check)
  assert_equals "" "$out" "the same failure in the next slot is not reported again"
  pass "fm-officer: a failing interval officer reports once, even though attempts reset each slot"
}

test_secondmate_home_runs_no_officers() {
  local home out rc
  home=$(make_world secondmate empty_spec)
  printf 'mate\n' > "$home/.fm-secondmate-home"
  rc=0
  out=$(officer "$home" register triage 2>&1) || rc=$?
  expect_code 3 "$rc" "register refuses in a second mate home"
  assert_contains "$out" "primary home" "the refusal names the primary-home rule"
  rc=0
  out=$(officer "$home" run triage --date "$DATE" 2>&1) || rc=$?
  expect_code 3 "$rc" "run refuses in a second mate home"
  assert_absent "$home/data/officers/triage/$DATE.json" "no findings are written"
  out=$(officer "$home" check triage) || fail "check must exit 0"
  assert_equals "" "$out" "check is silent in a second mate home"
  assert_contains "$(officer "$home" ensure)" "OFFICER: data/officers.md lists officers in a second mate home" \
    "ensure reports officers registered in a second mate home"
  pass "fm-officer: a second mate home refuses to register or run officers"
}

# tree_digest <home>: every path and content hash outside the officer's lane.
tree_digest() {
  (cd "$1" && find . -path ./data/officers/triage -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$f" "$(cksum < "$f")"
  done)
}

test_run_writes_only_its_lane_and_acts_on_no_fleet() {
  local home bin fakebin before tool
  home=$(make_world lane empty_spec)
  officer "$home" register triage >/dev/null || fail "register must succeed"
  printf 'working [at=1]: busy\n' > "$home/state/other-task.status"
  printf '1\tcheck\tsomething\n' > "$home/state/.wake-queue"
  # A firstmate copy whose fleet-acting scripts only record that they ran.
  bin="$TMP_ROOT/lane/code/bin"
  mkdir -p "$bin"
  cp -R "$ROOT/bin/." "$bin/"
  for tool in fm-spawn.sh fm-send.sh fm-pr-merge.sh fm-merge-local.sh fm-teardown.sh fm-control.sh \
    fm-inbox.sh fm-captain-hold.sh fm-tasks-axi.sh fm-wake-drain.sh fm-backlog-handoff.sh; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/fleet.calls"\n' "$tool" "$TMP_ROOT/lane" > "$bin/$tool"
    chmod +x "$bin/$tool"
  done
  fakebin=$(fm_fakebin "$TMP_ROOT/lane")
  for tool in gh gh-axi linear-axi ssh tmux herdr git; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/fleet.calls"\n' "$tool" "$TMP_ROOT/lane" > "$fakebin/$tool"
    chmod +x "$fakebin/$tool"
  done
  before=$(tree_digest "$home")
  PATH="$fakebin:$PATH" FM_OFFICER_NOW=$NOW FM_HOME="$home" "$bin/fm-officer.sh" run triage --date "$DATE" >/dev/null \
    || fail "run must succeed"
  PATH="$fakebin:$PATH" FM_OFFICER_NOW=$NOW FM_HOME="$home" "$bin/fm-officer.sh" check triage >/dev/null \
    || fail "check must succeed"
  assert_equals "$before" "$(tree_digest "$home")" "an officer run changes nothing outside data/officers/triage/"
  assert_absent "$TMP_ROOT/lane/fleet.calls" "an officer run calls no fleet-acting script, forge, Linear, or pane tool"
  pass "fm-officer: a run writes only its findings lane and acts on nothing in the fleet"
}

test_consumer_decides_whether_main_is_woken() {
  local home out
  # No consumer: field keeps today's behaviour: main is woken (test_check_reports_each_new_actionable_digest_once too).
  home=$(make_world consumer-none empty_spec)
  officer "$home" run triage --date "$DATE" >/dev/null || fail "run must succeed"
  out=$(officer "$home" check triage) || fail "check must exit 0"
  assert_contains "$out" "officer triage: $DATE: " "no consumer: still wakes main"

  home=$(make_world consumer-main empty_spec)
  nav_office "$home" tick,lane:triage
  sed -i.bak 's/model: none;/model: none; consumer: main,navigator;/' "$home/data/officers.md" && rm -f "$home/data/officers.md.bak"
  officer "$home" register triage >/dev/null || fail "register must accept a main,navigator consumer"
  assert_equals "" "$(officer "$home" ensure)" "consumer: main,navigator is a valid line"
  officer "$home" run triage --date "$DATE" >/dev/null || fail "run must succeed"
  out=$(officer "$home" check triage) || fail "check must exit 0"
  assert_contains "$out" "officer triage: $DATE: " "consumer naming main still wakes main"

  home=$(make_world consumer-office empty_spec)
  nav_office "$home" tick,lane:triage
  sed -i.bak 's/model: none;/model: none; consumer: navigator;/' "$home/data/officers.md" && rm -f "$home/data/officers.md.bak"
  officer "$home" register triage >/dev/null || fail "register must accept a navigator consumer"
  assert_equals "" "$(officer "$home" ensure)" "consumer: navigator is a valid line"
  officer "$home" run triage --date "$DATE" >/dev/null || fail "run must succeed"
  out=$(officer "$home" check triage) || fail "check must exit 0"
  assert_equals "" "$out" "a consumer list without main leaves main asleep for the digest"
  assert_grep "DIGEST $DATE " "$home/data/officers/triage/digest" "the digest itself is still written"
  pass "fm-officer: consumer: decides whether main is woken; absent keeps today's behaviour"
}

test_unknown_consumer_is_a_registry_problem() {
  local home out
  home=$(make_world consumer-bad empty_spec)
  sed -i.bak 's/model: none;/model: none; consumer: ghost;/' "$home/data/officers.md" && rm -f "$home/data/officers.md.bak"
  out=$(officer "$home" ensure)
  assert_contains "$out" 'consumer "ghost" is not main or an office' "an unknown consumer is reported"
  out=$(officer "$home" register triage 2>&1) && fail "register must refuse an unknown consumer"
  assert_contains "$out" 'consumer "ghost"' "register names the bad consumer"
  pass "fm-officer: an unknown consumer is a line problem"
}

test_consumer_office_must_read_the_digest() {
  local home out
  home=$(make_world consumer-nolane empty_spec)
  nav_office "$home" tick,lane:progress
  sed -i.bak 's/model: none;/model: none; consumer: navigator;/' "$home/data/officers.md" && rm -f "$home/data/officers.md.bak"
  out=$(officer "$home" ensure)
  assert_contains "$out" 'consumer office navigator does not list sources: lane:triage (or lane:triage:high)' "an office without the lane source is reported"
  out=$(officer "$home" register triage 2>&1) && fail "register must refuse a consumer office that never reads the digest"

  nav_office "$home" lane:triage:high
  out=$(officer "$home" ensure)
  case "$out" in *navigator*) fail "a lane:triage:high source with its registered check must be accepted: $out" ;; esac
  rm -f "$home/../navigator/state/office-lane-triage-high.check.sh"
  out=$(officer "$home" ensure)
  assert_contains "$out" 'consumer office navigator has no registered office-lane-triage-high check' "a :high source whose check is not registered is reported"

  nav_office "$home" lane:triage
  rm -f "$home/../navigator/state/office-lane-triage.check.sh"
  out=$(officer "$home" ensure)
  assert_contains "$out" 'consumer office navigator has no registered office-lane-triage check' "a lane source whose check is not registered is reported"

  printf -- '- navigator - nav (host: deepthought; root: /r; home: /r/navigator; scope: office; projects: PropertyCompass2; added 2026-11-04)\n' > "$home/data/secondmates.md"
  out=$(officer "$home" ensure)
  assert_contains "$out" 'consumer office navigator is remote' "a remote consumer office is reported"

  : > "$home/data/secondmates.md"
  sed -i.bak 's/consumer: navigator;/consumer: .*;/' "$home/data/officers.md" && rm -f "$home/data/officers.md.bak"
  out=$(officer "$home" ensure)
  assert_contains "$out" 'consumer ".*" is not main or an office' "a pattern consumer matches no office"
  pass "fm-officer: a consumer office must read the digest through its own lane source"
}

test_broken_consumer_falls_back_to_waking_main() {
  local home out
  home=$(make_world consumer-broken empty_spec)
  nav_office "$home" tick,lane:triage
  sed -i.bak 's/model: none;/model: none; consumer: navigator;/' "$home/data/officers.md" && rm -f "$home/data/officers.md.bak"
  officer "$home" register triage >/dev/null || fail "register must accept a navigator consumer"
  nav_office "$home" tick
  officer "$home" run triage --date "$DATE" >/dev/null || fail "a broken consumer must not stop the officer running"
  out=$(officer "$home" check triage) || fail "check must exit 0"
  assert_contains "$out" "officer triage: $DATE: " "a consumer office that no longer reads the digest leaves main as the reader"
  out=$(officer "$home" ensure)
  assert_contains "$out" 'consumer office navigator does not list sources: lane:triage' "ensure still reports the broken consumer"
  pass "fm-officer: a consumer that cannot read the digest falls back to waking main"
}

test_failure_line_reaches_main_whatever_the_consumer() {
  local home out
  home=$(make_world consumer-fail late_spec)
  nav_office "$home" tick,lane:triage
  sed -i.bak 's/model: none;/model: none; consumer: navigator;/' "$home/data/officers.md" && rm -f "$home/data/officers.md.bak"
  out=$(FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=1 officer "$home" check triage) || fail "check must exit 0"
  wait_for_attempts "$home" 1
  out=$(FM_OFFICER_RETRY_SECS=0 FM_OFFICER_ATTEMPTS=1 officer "$home" check triage) || fail "check must exit 0"
  assert_contains "$out" "officer triage: $DATE: run failed 1 time(s): " "the failure line reaches main"
  pass "fm-officer: the failure line is printed even when main is not a consumer"
}

test_start_home_office_must_read_the_progress_digest() {
  local home out
  home=$(make_world start-home empty_spec)
  printf -- '- progress - starts work (role: progress; cadence: daily 07:00; repos: ex/repo; start-home: ghost; model: none; added 2026-11-04)\n' > "$home/data/officers.md"
  out=$(officer "$home" ensure)
  assert_contains "$out" 'start-home "ghost" is not main or an office' "an unknown start-home office is reported"
  nav_office "$home" tick
  sed -i.bak 's/start-home: ghost/start-home: navigator/' "$home/data/officers.md" && rm -f "$home/data/officers.md.bak"
  out=$(officer "$home" ensure)
  assert_contains "$out" 'start-home office navigator does not list sources: lane:progress' "an office that never reads the progress digest cannot run its requests"
  out=$(officer "$home" register progress 2>&1) && fail "register must refuse a start-home office that never reads the digest"
  nav_office "$home" tick,lane:progress
  officer "$home" register progress >/dev/null || fail "register must accept a start-home office that reads the digest"
  assert_equals "" "$(officer "$home" ensure)" "a start-home office with the lane source is a valid line"
  pass "fm-officer: a start-home office must read the progress digest through its own lane source"
}


test_register_and_retire
test_check_reports_each_new_actionable_digest_once
test_check_is_silent_for_an_empty_digest
test_scheduled_run_starts_from_the_check_and_reports
test_same_day_manual_run_does_not_block_the_next_scheduled_run
test_manual_run_after_the_cadence_time_is_not_repeated
test_unreachable_host_is_silent_until_attempts_run_out
test_late_harvester_is_retried_then_reported
test_failure_after_a_reported_digest_is_reported_once
test_timed_out_run_counts_as_an_attempt
test_ensure_reports_gaps_and_is_silent_when_healthy
test_interval_cadence_runs_once_per_slot
test_interval_failure_is_reported_once_across_slots
test_secondmate_home_runs_no_officers
test_run_writes_only_its_lane_and_acts_on_no_fleet
test_consumer_decides_whether_main_is_woken
test_unknown_consumer_is_a_registry_problem
test_consumer_office_must_read_the_digest
test_broken_consumer_falls_back_to_waking_main
test_failure_line_reaches_main_whatever_the_consumer
test_start_home_office_must_read_the_progress_digest
