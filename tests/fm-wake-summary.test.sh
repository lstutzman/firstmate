#!/usr/bin/env bash
# tests/fm-wake-summary.test.sh - behavior tests for bin/fm-wake-summary.sh (the
# per-wake verdict classifier) and for bin/fm-wake-drain.sh --summary with its
# opt-in auto-acknowledge (config/wake-auto-ack). The real scripts run over crafted
# queue rows and status logs; bin/fm-crew-state.sh and bin/fm-office.sh are replaced
# through the classifier's two documented seams so the cases stay hermetic.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
SUMMARY="$ROOT/bin/fm-wake-summary.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-summary-tests)

# The drain's BRANCH OUTCOMES section stays out of these homes (same posture as the
# other drain presentation suites).
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

# A crew-state stub: prints the line named by <state>/.fake-crew-state.<task>, or
# "state: unknown" when none.
STUB_DIR="$TMP_ROOT/stubs"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/crew-state" <<'SH'
#!/usr/bin/env bash
f="${FM_STATE_OVERRIDE:?}/.fake-crew-state.$1"
if [ -f "$f" ]; then cat "$f"; else echo "state: unknown · source: none · no metadata for $1"; fi
SH
cat > "$STUB_DIR/office" <<'SH'
#!/usr/bin/env bash
# office stub: `starts-handled <officer>` succeeds when <state>/.fake-starts-handled.<officer> exists.
[ "${1:-}" = starts-handled ] && [ -f "${FM_STATE_OVERRIDE:?}/.fake-starts-handled.${2:-}" ]
SH
chmod +x "$STUB_DIR/crew-state" "$STUB_DIR/office"
export FM_WAKE_SUMMARY_CREW_STATE="$STUB_DIR/crew-state"
export FM_WAKE_SUMMARY_OFFICE="$STUB_DIR/office"

crew_state() { # <state> <task> <line>
  printf '%s\n' "$3" > "$1/.fake-crew-state.$2"
}

# row <seq> <kind> <key> <payload>: one queue row as the drain hands it to the classifier.
row() { printf '1794000000\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

# classify <state> <rows> [<annotations>]: the classifier's output and exit status.
classify() {
  local state=$1 rows=$2 ann=${3:-}
  if [ -n "$ann" ]; then
    printf '%s\n' "$rows" | FM_STATE_OVERRIDE="$state" "$SUMMARY" --annotations <(printf '%s\n' "$ann")
  else
    printf '%s\n' "$rows" | FM_STATE_OVERRIDE="$state" "$SUMMARY"
  fi
}

annotation() { # <status-key> <line>
  printf 'wake annotation: latest wake-EVENT observed at drain, not current state: %s: %s' "$1" "$2"
}

# --- signal ---------------------------------------------------------------

test_signal_on_a_presented_declared_pause_is_no_action() {
  local d state out rc=0
  d=$(make_case sig-paused); state="$d/state"
  printf 'paused [cause=external]: waiting on CI\n' > "$state/w1.status"
  crew_state "$state" w1 'state: paused · source: status-log · waiting on CI'
  out=$(classify "$state" "$(row 7 signal w1.status 'signal: w1.status')" "$(annotation other.status 'note: x')") || rc=$?
  assert_equals 0 "$rc" "all rows no-action exits 0"
  assert_contains "$out" "#7 signal w1.status: no-action" "verdict line"
  assert_contains "$out" "state: paused" "the crew state that decides it is on the line"
  printf 'paused: waiting on a release; until 2099-01-01T00:00Z\n' > "$state/w1.status"
  rc=0; out=$(classify "$state" "$(row 7 signal w1.status 's')") || rc=$?
  assert_equals 0 "$rc" "a presented pause whose clearing time is still ahead is no-action"
  pass "a signal whose status file has no unread line and ends in a declared pause on a paused crew is no-action"
}

test_signal_on_an_unread_pause_needs_action() {
  local d state out rc=0
  d=$(make_case sig-unread-pause); state="$d/state"
  printf 'paused [cause=external]: waiting on CI\n' > "$state/w1.status"
  crew_state "$state" w1 'state: paused · source: status-log · waiting on CI'
  out=$(classify "$state" "$(row 7 signal w1.status 'signal: w1.status')" "$(annotation w1.status 'paused [cause=external]: waiting on CI')") || rc=$?
  assert_equals 1 "$rc" "an unread pause is not no-action"
  assert_contains "$out" "#7 signal w1.status: ACTION - unread paused line: paused [cause=external]: waiting on CI" "the unread pause is named"
  pass "a pause still in the drain's unread annotations needs the supervisor to read it"
}

test_signal_without_annotation_reads_the_newest_status_line() {
  local d state out rc=0
  d=$(make_case sig-noann); state="$d/state"
  printf 'paused: waiting on a release\n' > "$state/w2.status"
  crew_state "$state" w2 'state: paused · source: status-log · waiting on a release'
  out=$(classify "$state" "$(row 3 signal w2.status 'signal: w2.status')") || rc=$?
  assert_equals 0 "$rc" "exit"
  assert_contains "$out" "no-action" "verdict"
  pass "with no annotation the newest status line is judged"
}

test_signal_refusals() {
  local d state out rc
  d=$(make_case sig-refuse); state="$d/state"
  crew_state "$state" w3 'state: paused · source: status-log · x'

  printf 'needs-decision [key=k]: pick one\n' > "$state/w3.status"
  rc=0; out=$(classify "$state" "$(row 1 signal w3.status 's')" "$(annotation w3.status 'needs-decision [key=k]: pick one')") || rc=$?
  assert_equals 1 "$rc" "an unread needs-decision needs action"
  assert_contains "$out" "ACTION - unread needs-decision" "needs-decision verdict"

  rc=0; out=$(classify "$state" "$(row 1 signal w3.status 's')" "$(annotation w3.status 'blocked [cause=tool]: stuck')") || rc=$?
  assert_contains "$out" "ACTION - unread blocked" "blocked verdict"

  rc=0; out=$(classify "$state" "$(row 1 signal w3.status 's')" "$(annotation w3.status 'done: finished')") || rc=$?
  assert_contains "$out" "ACTION - unread done" "done verdict"

  rc=0; out=$(classify "$state" "$(row 1 signal w3.status 's')" "$(annotation w3.status 'paused: waiting')
$(annotation w3.status 'done: finished')") || rc=$?
  assert_contains "$out" "ACTION - unread done" "a done line behind a pause still needs action"

  printf 'paused [cause=policy]: needs approval\n' > "$state/w3.status"
  rc=0; out=$(classify "$state" "$(row 1 signal w3.status 's')") || rc=$?
  assert_contains "$out" "ACTION - the pause names cause=policy" "a non-external cause needs action"

  rc=0; out=$(classify "$state" "$(row 1 signal w3.status 'needs-decision:w3.status')" "") || rc=$?
  assert_contains "$out" "ACTION - decision-owned signal" "a decision-owned payload needs action"

  rc=0; out=$(classify "$state" "$(row 1 signal w3.turn-ended 'signal: w3.turn-ended')") || rc=$?
  assert_contains "$out" "ACTION - turn-ended row" "a turn-end row needs action"

  printf 'paused: waiting\n' > "$state/w3.status"
  crew_state "$state" w3 'state: working · source: pane · busy'
  rc=0; out=$(classify "$state" "$(row 1 signal w3.status 's')") || rc=$?
  assert_contains "$out" "ACTION - state: working" "a pause on a crew that is not paused needs action"

  rm -f "$state/.fake-crew-state.w3"
  rc=0; out=$(classify "$state" "$(row 1 signal w3.status 's')") || rc=$?
  assert_contains "$out" "ACTION - state: unknown" "an unreadable crew state needs action"

  printf 'paused: waiting; until 2020-01-01T00:00Z\n' > "$state/w3.status"
  crew_state "$state" w3 'state: paused · source: status-log · x'
  rc=0; out=$(classify "$state" "$(row 1 signal w3.status 's')") || rc=$?
  assert_contains "$out" "ACTION - the pause names a clearing time that has passed" "a passed clearing time needs action"
  pass "an unread decision, blocker or done line, a non-external cause, a passed clearing time and a non-paused crew all need action"
}

# --- stale ----------------------------------------------------------------

test_stale_on_a_declared_pause() {
  local d state out rc=0
  d=$(make_case stale); state="$d/state"
  printf 'window=fm:fm-st1\n' > "$state/st1.meta"
  printf 'paused [cause=external]: waiting on upstream\n' > "$state/st1.status"
  crew_state "$state" st1 'state: paused · source: status-log · waiting on upstream'
  out=$(classify "$state" "$(row 4 stale fm:fm-st1 'stale: fm:fm-st1 (paused 3600s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)')") || rc=$?
  assert_equals 0 "$rc" "exit"
  assert_contains "$out" "#4 stale fm:fm-st1: no-action" "verdict"

  rc=0; out=$(classify "$state" "$(row 4 stale fm:fm-st1 'stale: fm:fm-st1 (paused 9000s, awaiting external - the declared clearing time has passed, rechecked on a long cadence not a wedge; confirm the wait cleared)')") || rc=$?
  assert_equals 1 "$rc" "exit"
  assert_contains "$out" "ACTION - the declared pause time has passed" "a due recheck needs action"

  crew_state "$state" st1 'state: working · source: pane · busy'
  rc=0; out=$(classify "$state" "$(row 4 stale fm:fm-st1 'stale: fm:fm-st1 (idle)')") || rc=$?
  assert_contains "$out" "ACTION - state: working" "a stale window on a crew that is not paused needs action"

  rc=0; out=$(classify "$state" "$(row 4 stale fm:fm-nobody 'stale: fm:fm-nobody (idle)')") || rc=$?
  assert_contains "$out" "ACTION - no task record" "a stale window with no task record needs action"
  pass "a stale on a declared pause is no-action; a due recheck, a working crew and an unknown window are not"
}

# --- check: merge landed --------------------------------------------------

test_merge_landed() {
  local d state out rc=0
  d=$(make_case merge); state="$d/state"
  out=$(classify "$state" "$(row 9 check merged-gone-x 'check: merge landed: gone https://github.com/o/r/pull/5')") || rc=$?
  assert_equals 0 "$rc" "exit"
  assert_contains "$out" "no-action - task gone is already torn down" "a torn-down task is no-action"

  printf 'window=fm:fm-live\n' > "$state/live.meta"
  crew_state "$state" live 'state: done · source: status-log · shipped'
  rc=0; out=$(classify "$state" "$(row 9 check merged-live-x 'check: merge landed: live https://github.com/o/r/pull/6 away')") || rc=$?
  assert_equals 1 "$rc" "exit"
  assert_contains "$out" "ACTION - task live is still recorded" "a recorded task needs its teardown"
  assert_contains "$out" "state: done" "the crew state is on the line"


  crew_state "$state" live 'state: done · source: run-step · PR merged · pr=https://github.com/o/r/pull/6'
  rc=0; out=$(classify "$state" "$(row 9 check merged-live-x 'check: merge landed: live https://github.com/o/r/pull/6')") || rc=$?
  assert_equals 1 "$rc" "exit"
  assert_contains "$out" "ACTION - task live is still recorded" "a merged task that is not yet torn down still wakes the model"
  pass "a merge landed for a torn-down task is no-action; any task still recorded, merged or not, wakes the model"
}

# --- check: office lane delivery ------------------------------------------

test_office_lane_delivery() {
  local d state out rc=0 line plain findings
  d=$(make_case lane); state="$d/state"
  plain="check: /h/state/office-lane-friction.check.sh: office quartermaster: friction digest 2026-11-08T21; 2 start request(s) delivered to this office's inbox"
  findings="check: /h/state/office-lane-friction.check.sh: office quartermaster: friction digest 2026-11-08T21: 5 finding(s) in /h/data/officers/friction/x.md; 2 start request(s) delivered to this office's inbox"
  : > "$state/.fake-starts-handled.friction"
  rc=0; out=$(classify "$state" "$(row 11 check office-lane-friction "$plain")") || rc=$?
  assert_equals 0 "$rc" "exit"
  assert_contains "$out" "no-action - every friction start request" "all handled is no-action"
  for line in "$findings" "${findings/5 finding/2 high-severity finding}"; do
    rc=0; out=$(classify "$state" "$(row 11 check office-lane-friction "$line")") || rc=$?
    assert_equals 1 "$rc" "a findings clause needs action"
    assert_contains "$out" "check office-lane-friction: ACTION" "the office must read new findings"
  done
  rm -f "$state/.fake-starts-handled.friction"
  rc=0; out=$(classify "$state" "$(row 11 check office-lane-friction "$plain")") || rc=$?
  assert_equals 1 "$rc" "exit"
  assert_contains "$out" "ACTION - the friction start request(s) are not all acknowledged" "unhandled requests need action"

  : > "$state/.fake-starts-handled.friction"
  rc=0; out=$(classify "$state" "$(row 11 check office-lane-friction "check: /h/state/office-lane-friction.check.sh: office quartermaster: friction digest 2026-11-08T21: 5 finding(s) in /h/x.md")") || rc=$?
  assert_contains "$out" "ACTION" "a digest line with no delivery clause is not classified"
  pass "an office lane delivery is no-action only without a findings clause and when every request is already acknowledged"
}

test_other_rows_need_action() {
  local d state out rc=0
  d=$(make_case other); state="$d/state"
  out=$(classify "$state" "$(row 1 heartbeat heartbeat heartbeat)") || rc=$?
  assert_equals 1 "$rc" "exit"
  assert_contains "$out" "heartbeat fleet: ACTION" "a heartbeat needs a fleet review"
  rc=0; out=$(classify "$state" "$(row 2 check pr-register 'check: pr-register: t #1 draft')") || rc=$?
  assert_contains "$out" "ACTION - check: pr-register" "an unclassified check needs action"
  pass "a heartbeat and any unclassified check need action"
}

test_mixed_batch_exits_nonzero() {
  local d state out rc=0
  d=$(make_case mixed); state="$d/state"
  out=$(classify "$state" "$(row 1 check merged-gone-x 'check: merge landed: gone https://github.com/o/r/pull/5')
$(row 2 check pr-register 'check: pr-register: t #1 draft')") || rc=$?
  assert_equals 1 "$rc" "exit"
  assert_contains "$out" "#1 check merged-gone-x: no-action" "the quiet row is still labelled"
  assert_contains "$out" "#2 check pr-register: ACTION" "the other row needs action"
  pass "a mixed batch reports each verdict and exits non-zero"
}

# --- drain --summary and auto-ack ------------------------------------------

# drain_summary <state>: run the drain in summary mode, stdout and stderr merged.
drain_summary() { FM_STATE_OVERRIDE="$1" "$DRAIN" --summary 2>&1; }

queue_rows() { grep -c . "$1/.wake-queue" 2>/dev/null || true; }

opt_in() { : > "$TMP_ROOT/config/wake-auto-ack"; }
opt_out() { rm -f "$TMP_ROOT/config/wake-auto-ack"; }

test_summary_prints_one_line_per_wake_and_the_ack_command() {
  local d state out
  d=$(make_case drain-summary); state="$d/state"
  opt_out
  append_wake "$state" check merged-gone-x 'check: merge landed: gone https://github.com/o/r/pull/5'
  out=$(drain_summary "$state")
  assert_contains "$out" "WAKE SUMMARY (1 wake(s), 0 need action):" "header"
  assert_contains "$out" "check merged-gone-x: no-action" "the verdict line"
  assert_contains "$out" "WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation" "the exact ack command is printed"
  assert_not_contains "$out" "AUTO-ACKED" "no opt-in, no auto-ack"
  [ "$(queue_rows "$state")" = 1 ] || fail "the row must stay queued without the opt-in"
  pass "--summary prints one verdict line per wake and the exact ack command, acknowledging nothing without the opt-in"
}

test_all_no_action_batch_is_auto_acked() {
  local d state out
  d=$(make_case drain-auto); state="$d/state"
  opt_in
  append_wake "$state" check merged-gone-x 'check: merge landed: gone https://github.com/o/r/pull/5'
  append_wake "$state" check office-lane-friction "check: /h/state/office-lane-friction.check.sh: office quartermaster: friction digest 2026-11-08T21; 1 start request(s) delivered to this office's inbox"
  : > "$state/.fake-starts-handled.friction"
  out=$(drain_summary "$state")
  assert_contains "$out" "WAKE AUTO-ACKED: 2 wake(s) classified no-action and acknowledged through 2" "auto-ack line"
  assert_not_contains "$out" "WAKE_ACK_REQUIRED" "no ack command is left to run"
  [ "$(queue_rows "$state")" = 0 ] || fail "the batch must be acknowledged: $(cat "$state/.wake-queue")"
  opt_out
  pass "an all no-action batch is acknowledged by the drain when the home opts in"
}

test_mixed_batch_acknowledges_nothing() {
  local d state out
  d=$(make_case drain-mixed); state="$d/state"
  opt_in
  append_wake "$state" check merged-gone-x 'check: merge landed: gone https://github.com/o/r/pull/5'
  append_wake "$state" check pr-register 'check: pr-register: t #1 draft'
  out=$(drain_summary "$state")
  assert_contains "$out" "WAKE SUMMARY (2 wake(s), 1 need action):" "header counts the action wake"
  assert_contains "$out" "WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 2" "the ack command is printed"
  assert_not_contains "$out" "AUTO-ACKED" "mixed batch is not auto-acked"
  [ "$(queue_rows "$state")" = 2 ] || fail "nothing may be acknowledged in a mixed batch"
  opt_out
  pass "one action wake in a batch means nothing is auto-acknowledged"
}

test_sections_block_the_auto_ack() {
  local d state out
  opt_in
  # OPEN DECISIONS from an unrelated task.
  d=$(make_case drain-open); state="$d/state"
  printf 'needs-decision [key=api]: pick REST or RPC\n' > "$state/other.status"
  append_wake "$state" check merged-gone-x 'check: merge landed: gone https://github.com/o/r/pull/5'
  out=$(drain_summary "$state")
  assert_contains "$out" "OPEN DECISIONS" "open decisions are still printed"
  assert_not_contains "$out" "AUTO-ACKED" "OPEN DECISIONS block the auto-ack"
  [ "$(queue_rows "$state")" = 1 ] || fail "an open decision must keep the batch queued"

  # UNREAD STATUS: a note line nobody has read.
  d=$(make_case drain-unread); state="$d/state"
  printf 'note: bootstrap\n' > "$state/n1.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1
  printf 'note: the captain said use REST\n' >> "$state/n1.status"
  append_wake "$state" check merged-gone-x 'check: merge landed: gone https://github.com/o/r/pull/5'
  out=$(drain_summary "$state")
  assert_contains "$out" "UNREAD STATUS" "unread status is still printed"
  assert_contains "$out" "the captain said use REST" "the unread line is shown"
  assert_not_contains "$out" "AUTO-ACKED" "UNREAD STATUS blocks the auto-ack"
  [ "$(queue_rows "$state")" = 1 ] || fail "unread status must keep the batch queued"

  # RECORD DIVERGENCE: a fake captain-hold reporting one diverged call.
  d=$(make_case drain-diverge); state="$d/state"
  mkdir -p "$d/bin"
  cp -R "$ROOT/bin/." "$d/bin/"
  cat > "$d/bin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = diverged ] && printf 'tk\torigin\tkey-1\tthe title\n'
exit 0
SH
  chmod +x "$d/bin/fm-captain-hold.sh"
  printf 'working: x\n' > "$state/tk.status"
  append_wake "$state" check merged-gone-x 'check: merge landed: gone https://github.com/o/r/pull/5'
  out=$(FM_STATE_OVERRIDE="$state" "$d/bin/fm-wake-drain.sh" --summary 2>&1)
  assert_contains "$out" "RECORD DIVERGENCE" "record divergence is still printed"
  assert_not_contains "$out" "AUTO-ACKED" "RECORD DIVERGENCE blocks the auto-ack"
  [ "$(queue_rows "$state")" = 1 ] || fail "a record divergence must keep the batch queued"
  opt_out
  pass "OPEN DECISIONS, UNREAD STATUS and RECORD DIVERGENCE each block the auto-ack and still print"
}

test_signal_pause_batch_is_auto_acked_and_a_new_decision_is_not() {
  local d state out
  d=$(make_case drain-signal); state="$d/state"
  opt_in
  printf 'note: bootstrap\n' > "$state/s1.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1
  printf 'paused [cause=external]: waiting on CI\n' >> "$state/s1.status"
  crew_state "$state" s1 'state: paused · source: status-log · waiting on CI'
  append_wake "$state" signal s1.status 'signal: s1.status'
  out=$(drain_summary "$state")
  assert_contains "$out" "signal s1.status: ACTION - unread paused line" "a fresh pause is an action wake"
  assert_contains "$out" "wake annotation:" "the annotation it was judged on is printed"
  assert_contains "$out" "waiting on CI" "so the supervisor reads the pause text"
  assert_not_contains "$out" "AUTO-ACKED" "an unread pause is never auto-acked"
  [ "$(queue_rows "$state")" = 1 ] || fail "the fresh pause wake must stay queued"
  out=$(drain_summary "$state")
  assert_contains "$out" "signal s1.status: no-action - declared pause already presented" "once presented, the pause is no-action"
  assert_contains "$out" "AUTO-ACKED" "and acknowledged"

  printf 'needs-decision [key=pick]: which one\n' >> "$state/s1.status"
  append_wake "$state" signal s1.status 'needs-decision:s1.status'
  out=$(drain_summary "$state")
  assert_contains "$out" "ACTION" "a new needs-decision is an action wake"
  assert_not_contains "$out" "AUTO-ACKED" "never auto-acked"
  [ "$(queue_rows "$state")" = 1 ] || fail "the decision wake must stay queued"
  opt_out
  pass "a fresh pause wakes the supervisor, a presented one is auto-acked, and a following needs-decision wake is not"
}

test_recovery_only_drain_is_auto_acked() {
  local d state out
  d=$(make_case drain-recovery); state="$d/state"
  # A recovery episode with an empty queue: the rearm-resurface shape, where the
  # watcher restarted and published a downtime marker but queued no row.
  opt_out
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_publish "$STATE/.watcher-down" downtime' _ "$ROOT/bin/fm-wake-lib.sh" \
    || fail "could not publish the downtime marker"
  opt_in
  out=$(drain_summary "$state")
  assert_contains "$out" "WAKE SUMMARY (recovery only, no queued wake rows)" "a summary is printed on the empty-queue path"
  assert_contains "$out" "WAKE AUTO-ACKED: 0 wake(s) classified no-action and acknowledged through 0" "the episode is retired"
  out=$(drain_summary "$state")
  assert_not_contains "$out" "WAKE_ACK_REQUIRED" "the recovery episode no longer asks for an acknowledgement"
  opt_out
  pass "a recovery episode with no queued rows is retired by the auto-ack when the home opts in"
}

test_a_broken_classifier_shows_the_raw_rows_and_acknowledges_nothing() {
  local d state out
  d=$(make_case drain-broken); state="$d/state"
  opt_in
  mkdir -p "$d/bin"
  cp -R "$ROOT/bin/." "$d/bin/"
  chmod -x "$d/bin/fm-wake-summary.sh"
  append_wake "$state" check merged-gone-x 'check: merge landed: gone https://github.com/o/r/pull/5'
  out=$(FM_STATE_OVERRIDE="$state" "$d/bin/fm-wake-drain.sh" --summary 2>&1)
  assert_contains "$out" "WAKE SUMMARY UNAVAILABLE (classified 0 of 1 wake rows)" "the failure is stated"
  assert_contains "$out" "check: merge landed: gone" "the raw row is shown, never hidden"
  assert_contains "$out" "WAKE_ACK_REQUIRED" "the ack command is printed"
  assert_not_contains "$out" "AUTO-ACKED" "nothing is auto-acknowledged"
  [ "$(queue_rows "$state")" = 1 ] || fail "the row must stay queued"
  opt_out
  pass "a classifier that cannot run shows the raw wake rows and acknowledges nothing"
}

# --- --quiet-ack (the Stop hook's no-wake path) ----------------------------

quiet_ack() { # <state>: exit status of the quiet drain, its output in $QUIET_OUT
  local rc=0
  QUIET_OUT=$(FM_STATE_OVERRIDE="$1" "$DRAIN" --quiet-ack 2>&1) || rc=$?
  return "$rc"
}

merge_row() { append_wake "$1" check "merged-$2-x" "check: merge landed: $2 https://github.com/o/r/pull/5"; }

test_quiet_ack_without_the_flag_does_nothing() {
  local d state rc=0
  d=$(make_case quiet-off); state="$d/state"
  opt_out
  merge_row "$state" gone
  quiet_ack "$state" || rc=$?
  assert_equals 11 "$rc" "the mode does not apply without the opt-in"
  assert_equals "" "$QUIET_OUT" "and prints nothing"
  [ "$(queue_rows "$state")" = 1 ] || fail "the row must stay queued"
  pass "--quiet-ack without config/wake-auto-ack exits 11 and touches nothing"
}

test_quiet_ack_acknowledges_a_quiet_batch_and_leaves_one_record() {
  local d state rc=0 out
  d=$(make_case quiet-on); state="$d/state"
  opt_in
  merge_row "$state" gone
  merge_row "$state" gone2
  quiet_ack "$state" || rc=$?
  assert_equals 0 "$rc" "a quiet batch is acknowledged"
  assert_equals "" "$QUIET_OUT" "silently"
  [ "$(queue_rows "$state")" = 0 ] || fail "the batch must be acknowledged: $(cat "$state/.wake-queue")"
  [ "$(wc -l < "$state/.wake-auto-acked" | tr -d ' ')" = 1 ] || fail "one record line expected"
  out=$(drain_summary "$state")
  assert_contains "$out" "WAKE AUTO-ACKED WHILE NO MODEL WAS WOKEN: 2 wake(s) in 1 batch(es)" "the next drain reports it"
  assert_contains "$out" "check=2" "with the kinds"
  out=$(drain_summary "$state")
  assert_not_contains "$out" "WHILE NO MODEL WAS WOKEN" "and only once"
  opt_out
  pass "--quiet-ack acknowledges a quiet batch silently and the next --summary drain reports it once"
}

test_quiet_ack_mixed_batch_wakes_and_consumes_nothing() {
  local d state rc=0 out
  d=$(make_case quiet-mixed); state="$d/state"
  opt_in
  printf 'note: bootstrap\n' > "$state/n1.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1
  printf 'note: the captain said use REST\n' >> "$state/n1.status"
  merge_row "$state" gone
  append_wake "$state" check pr-register 'check: pr-register: t #1 draft'
  quiet_ack "$state" || rc=$?
  assert_equals 10 "$rc" "one action wake means a model is needed"
  [ "$(queue_rows "$state")" = 2 ] || fail "nothing may be acknowledged"
  out=$(drain_summary "$state")
  assert_contains "$out" "the captain said use REST" "the unread status was not consumed by the quiet pass"
  assert_contains "$out" "WAKE SUMMARY (2 wake(s), 1 need action)" "and the supervisor's own drain shows both rows"
  opt_out
  pass "a mixed batch (and an unread note) leaves everything for the supervisor's own drain"
}

test_quiet_ack_fresh_pause_wakes_and_consumes_nothing() {
  local d state rc=0 out
  d=$(make_case quiet-pause); state="$d/state"
  opt_in
  printf 'note: bootstrap\n' > "$state/p1.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1
  printf 'paused [cause=external]: waiting on the vendor\n' >> "$state/p1.status"
  crew_state "$state" p1 'state: paused · source: status-log · waiting on the vendor'
  append_wake "$state" signal p1.status 'signal: p1.status'
  quiet_ack "$state" || rc=$?
  assert_equals 10 "$rc" "an unread pause needs a model"
  [ "$(queue_rows "$state")" = 1 ] || fail "nothing may be acknowledged"
  out=$(drain_summary "$state")
  assert_contains "$out" "wake annotation:" "the supervisor's drain still has the unread annotation"
  assert_contains "$out" "waiting on the vendor" "with the pause text, not consumed by the quiet pass"
  opt_out
  pass "--quiet-ack exits 10 on a fresh pause and leaves its status line unread"
}

test_quiet_ack_lock_timeout_does_not_report_success() {
  local d state rc=0 holder i
  d=$(make_case quiet-lock); state="$d/state"
  opt_in
  merge_row "$state" gone
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    printf "ready\n" > "$3"
    exec sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.wake-queue.lock" "$d/queue.ready" &
  holder=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$d/queue.ready" ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$d/queue.ready" ] || { kill "$holder" 2>/dev/null || true; fail "queue holder never acquired its lock"; }
  QUIET_OUT=$(FM_STATE_OVERRIDE="$state" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 "$DRAIN" --quiet-ack 2>&1) || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  assert_equals 10 "$rc" "a quiet drain that could not take the queue lock acknowledged nothing"
  [ "$(queue_rows "$state")" = 1 ] || fail "the row must stay queued"
  [ ! -e "$state/.wake-auto-acked" ] || fail "no auto-ack record may be left"
  opt_out
  pass "--quiet-ack exits 10, not 0, when the queue lock stays held past the presentation timeout"
}

test_quiet_ack_error_exit_after_handling_restores_downtime() {
  local d c state rc=0 token
  d=$(make_case quiet-error); state="$d/state"
  c=$(make_case quiet-error-control)
  opt_in
  merge_row "$state" gone
  merge_row "$c/state" gone
  mkdir -p "$d/bin"
  cp -R "$ROOT/bin/." "$d/bin/"
  QUIET_OUT=$(FM_STATE_OVERRIDE="$c/state" "$d/bin/fm-wake-drain.sh" --quiet-ack 2>&1) || rc=$?
  case "$rc" in 0|10) ;; *) fail "the copied drain must reach classification without the injection (rc $rc): $QUIET_OUT" ;; esac
  printf '\nfm_wake_print_deduped() { return 1; }\n' >> "$d/bin/fm-wake-lib.sh"
  rc=0
  QUIET_OUT=$(FM_STATE_OVERRIDE="$state" "$d/bin/fm-wake-drain.sh" --quiet-ack 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a quiet drain that failed after beginning handling must not report success"
  [ "$rc" -ne 10 ] || fail "the injected failure must take an error exit, not the classified one: $QUIET_OUT"
  assert_not_contains "$QUIET_OUT" "wake drain:" "no earlier drain error preceded the injected dedupe failure"
  [ "$(queue_rows "$state")" = 1 ] || fail "the row must stay queued"
  token=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_snapshot "$STATE/.watcher-down"; printf "%s" "$FM_RECOVERY_MARKER_TOKEN"' _ "$ROOT/bin/fm-wake-lib.sh")
  case "$token" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "the recovery marker must be back in downtime so the Stop hook can rewake, got: $token" ;;
  esac
  opt_out
  pass "--quiet-ack that fails after beginning handling exits non-zero and leaves the recovery marker in downtime"
}

test_open_decisions_unchanged_since_last_presented() {
  local d state rc=0 out
  d=$(make_case quiet-od); state="$d/state"
  opt_in
  printf 'needs-decision [key=k1]: pick one\nneeds-decision [key=k2]: pick two\n' > "$state/other.status"
  merge_row "$state" gone
  # Nothing presented yet: the section is new to the model, so a model is needed.
  quiet_ack "$state" || rc=$?
  assert_equals 10 "$rc" "an OPEN DECISIONS section no model has seen wakes"
  out=$(drain_summary "$state")
  assert_contains "$out" "OPEN DECISIONS" "the real wake prints it"
  assert_not_contains "$out" "AUTO-ACKED" "and does not auto-ack a new section"
  # Identical set: quiet.
  rc=0; quiet_ack "$state" || rc=$?
  assert_equals 0 "$rc" "a byte-identical set is quiet"
  [ "$(queue_rows "$state")" = 0 ] || fail "the batch must be acknowledged"
  # The unchanged section still prints on the next real wake.
  merge_row "$state" gone2
  append_wake "$state" check pr-register 'check: pr-register: t #1 draft'
  out=$(drain_summary "$state")
  assert_contains "$out" "[key=k1] needs-decision: pick one" "the unchanged section still prints"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through 2 --recovery-generation "$(sed -n 's/.*--recovery-generation //p' <<<"$out" | head -1)" >/dev/null 2>&1 || true
  : > "$state/.wake-queue"
  # One changed line wakes.
  merge_row "$state" gone3
  printf 'needs-decision [key=k1]: pick one, reworded\n' >> "$state/other.status"
  rc=0; quiet_ack "$state" || rc=$?
  assert_equals 10 "$rc" "a changed decision line wakes the model"
  drain_summary "$state" >/dev/null
  : > "$state/.wake-queue"
  # A new key wakes.
  merge_row "$state" gone4
  printf 'needs-decision [key=k3]: a third\n' >> "$state/other.status"
  rc=0; quiet_ack "$state" || rc=$?
  assert_equals 10 "$rc" "a new decision key wakes the model"
  drain_summary "$state" >/dev/null
  : > "$state/.wake-queue"
  # A removed key wakes.
  merge_row "$state" gone5
  printf 'resolved [key=k3]: done\n' >> "$state/other.status"
  rc=0; quiet_ack "$state" || rc=$?
  assert_equals 10 "$rc" "a removed decision key wakes the model"
  opt_out
  pass "an OPEN DECISIONS section byte-identical to the last presented one is quiet; a new, changed or removed decision wakes the model"
}

test_open_decisions_unchanged_does_not_hide_unread_status() {
  local d state rc=0
  d=$(make_case quiet-od-unread); state="$d/state"
  opt_in
  printf 'needs-decision [key=k1]: pick one\n' > "$state/other.status"
  printf 'note: bootstrap\n' > "$state/n1.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1
  merge_row "$state" gone
  drain_summary "$state" >/dev/null
  printf 'note: new information\n' >> "$state/n1.status"
  quiet_ack "$state" || rc=$?
  assert_equals 10 "$rc" "UNREAD STATUS wakes even with an unchanged OPEN DECISIONS section"
  opt_out
  pass "an unread status line wakes the model even when OPEN DECISIONS is unchanged"
}

test_every_classified_wake_is_counted_once() {
  local d state out
  d=$(make_case counters); state="$d/state"
  opt_in
  merge_row "$state" gone
  append_wake "$state" check pr-register 'check: pr-register: t #1 draft'
  drain_summary "$state" >/dev/null
  drain_summary "$state" >/dev/null
  out=$(cat "$state/.wake-classified.jsonl")
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ] || fail "each wake is counted once, not per drain: $out"
  assert_contains "$out" '"kind":"check","verdict":"no-action","auto_acked":false' "the quiet wake, not acknowledged because its batch was mixed"
  assert_contains "$out" '"verdict":"action","auto_acked":false' "the action wake"
  : > "$state/.wake-queue"; rm -f "$state/.wake-classified.jsonl"
  merge_row "$state" gone9
  quiet_ack "$state" || fail "the quiet batch must be acknowledged"
  assert_contains "$(cat "$state/.wake-classified.jsonl")" '"verdict":"no-action","auto_acked":true' "an acknowledged wake is marked auto_acked"
  opt_out
  pass "state/.wake-classified.jsonl records ts, kind, verdict and auto_acked once per wake"
}

test_non_summary_drain_is_unchanged() {
  local d state out
  d=$(make_case drain-plain); state="$d/state"
  opt_in
  append_wake "$state" check merged-gone-x 'check: merge landed: gone https://github.com/o/r/pull/5'
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN" 2>&1)
  assert_contains "$out" "check: merge landed: gone" "the raw row is printed"
  assert_contains "$out" "WAKE_ACK_REQUIRED" "the ack command is printed"
  assert_not_contains "$out" "AUTO-ACKED" "the plain drain never auto-acks"
  [ "$(queue_rows "$state")" = 1 ] || fail "the plain drain must not acknowledge"
  opt_out
  pass "without --summary the drain output and behavior are unchanged even with the opt-in"
}

test_summary_flag_is_exclusive() {
  local d state rc=0
  d=$(make_case drain-usage); state="$d/state"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --summary --ack-through 1 --recovery-generation x >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "--summary with an acknowledgement is a usage error"
  pass "--summary cannot be combined with --ack-through"
}

test_quiet_ack_without_the_flag_does_nothing
test_quiet_ack_acknowledges_a_quiet_batch_and_leaves_one_record
test_quiet_ack_mixed_batch_wakes_and_consumes_nothing
test_quiet_ack_fresh_pause_wakes_and_consumes_nothing
test_quiet_ack_lock_timeout_does_not_report_success
test_quiet_ack_error_exit_after_handling_restores_downtime
test_open_decisions_unchanged_since_last_presented
test_open_decisions_unchanged_does_not_hide_unread_status
test_every_classified_wake_is_counted_once
test_signal_pause_batch_is_auto_acked_and_a_new_decision_is_not
test_signal_without_annotation_reads_the_newest_status_line
test_signal_on_a_presented_declared_pause_is_no_action
test_signal_on_an_unread_pause_needs_action
test_signal_refusals
test_stale_on_a_declared_pause
test_merge_landed
test_office_lane_delivery
test_other_rows_need_action
test_mixed_batch_exits_nonzero
test_summary_prints_one_line_per_wake_and_the_ack_command
test_all_no_action_batch_is_auto_acked
test_mixed_batch_acknowledges_nothing
test_sections_block_the_auto_ack
test_recovery_only_drain_is_auto_acked
test_a_broken_classifier_shows_the_raw_rows_and_acknowledges_nothing
test_non_summary_drain_is_unchanged
test_summary_flag_is_exclusive
