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
  officer "$home" check triage >/dev/null || fail "check must exit 0"
  assert_equals 2 "$(grep -c " $DATE " "$home/data/officers/triage/runs.log")" "a run finished since the cadence time is not repeated"
  pass "fm-officer: a same-day manual run does not block the next day's scheduled run"
}

test_manual_run_after_the_cadence_time_is_not_repeated() {
  local home
  home=$(make_world manuallate empty_spec)
  officer "$home" register triage >/dev/null || fail "register must succeed"
  # 06:30 on the check's day, after the 06:00 cadence time.
  FM_OFFICER_NOW=$((NOW - 1800)) FM_HOME="$home" "$OFFICER" run triage --date "$DATE" >/dev/null || fail "manual run must succeed"
  officer "$home" check triage >/dev/null || fail "check must exit 0"
  sleep 1
  assert_equals 1 "$(grep -c " $DATE " "$home/data/officers/triage/runs.log")" "a manual run since the cadence time satisfies the schedule"
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
test_secondmate_home_runs_no_officers
test_run_writes_only_its_lane_and_acts_on_no_fleet
