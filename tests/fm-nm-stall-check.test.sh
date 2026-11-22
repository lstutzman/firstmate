#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-stall-check.sh, over a fake `no-mistakes` whose run
# state is stubbed per task copy. Covers the pending-with-no-steps condition (and
# its run-slot exemption), the gate condition and its owner routing, the once-only
# rule, the clear when a run moves, unreadable reads, and the watcher sweep that
# turns the line into one `check: nm-stall:` wake.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-stall-check)
CHECK="$ROOT/bin/fm-nm-stall-check.sh"

# A world: <root>/state with metas, <root>/wt/<task> copies, a fake no-mistakes
# serving <root>/fake/<task>.status for `axi status` (exit 1 when <task>.fail
# exists), and <root>/nmhome as the no-mistakes home whose state.sqlite holds the
# machine's runs (see set_runs).
make_world() {  # <name> <max_concurrent_runs|none> -> prints root
  local root="$TMP_ROOT/$1"
  mkdir -p "$root/state" "$root/wt" "$root/fake" "$root/bin" "$root/nmhome"
  cat > "$root/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
name=$(basename "$PWD")
[ "${1:-}" = axi ] || exit 0
if [ "${2:-}" = status ]; then
  [ ! -e "$FAKE_DIR/$name.fail" ] || exit 1
  cat "$FAKE_DIR/$name.status" 2>/dev/null
fi
exit 0
SH
  chmod +x "$root/bin/no-mistakes"
  [ "$2" = none ] || printf 'max_concurrent_runs: %s\n' "$2" > "$root/nmhome/config.yaml"
  printf '%s' "$root"
}

add_task() {  # <root> <task> [extra meta line]
  mkdir -p "$1/wt/$2"
  printf 'kind=ship\nmode=no-mistakes\nbranch=fm/%s\nworktree=%s\n%s\n' "$2" "$1/wt/$2" "${3:-}" \
    > "$1/state/$2.meta"
}

set_status() {  # <root> <task> <toon>
  printf '%s\n' "$3" > "$1/fake/$2.status"
}

pending_toon() {  # <task> <run> [step status ...]
  local task=$1 run=$2 rows=""
  shift 2
  for s in "$@"; do rows="$rows    step,$s,0,0"$'\n'; done
  printf 'run:\n  id: "%s"\n  branch: fm/%s\n  status: pending\n  head: "abc1234"\n  pr: ""\n  findings: none\n  steps[%s]{step,status,findings,duration_ms}:\n%s' \
    "$run" "$task" "$#" "$rows"
}

gate_toon() {  # <task> <run> <gate> <action> [parked]
  printf 'run:\n  id: "%s"\n  branch: fm/%s\n  status: awaiting_approval\n  awaiting_agent: parked %s\n  head: "abc1234"\n  pr: ""\n  findings[1]{id,severity,file,line,action,description}:\n    r1,error,b.go,,%s,something\ngate: %s\n' \
    "$2" "$1" "${5:-1m}" "$4" "$3"
}

# Replace the machine's run rows in <root>/nmhome/state.sqlite, laid out as
# no-mistakes keeps them (runs.status). Each spec is <repo>:<status>:<count>.
set_runs() {  # <root> <spec...>
  local root=$1
  shift
  python3 -I - "$root/nmhome/state.sqlite" "$@" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE IF NOT EXISTS repos (id TEXT PRIMARY KEY, working_path TEXT)")
db.execute("CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL, "
           "head_sha TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', created_at INTEGER NOT NULL)")
db.execute("DELETE FROM runs")
n = 0
for spec in sys.argv[2:]:
    repo, status, count = spec.split(":")
    db.execute("INSERT OR IGNORE INTO repos VALUES (?, ?)", (repo, "/repos/" + repo))
    for _ in range(int(count)):
        n += 1
        db.execute("INSERT INTO runs VALUES (?, ?, ?, 'abc1234', ?, ?)", ("R%d" % n, repo, "fm/r%d" % n, status, n))
db.commit()
PY
}

sweep() {  # <root> <now>
  FAKE_DIR="$1/fake" PATH="$1/bin:$PATH" NM_HOME="$1/nmhome" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    FM_NM_STALL_NOW="$2" bash "$CHECK" sweep 2>&1
}

test_pending_with_no_steps_wakes_once_after_five_minutes() {
  local root out
  root=$(make_world pending 4)
  add_task "$root" t1
  set_status "$root" t1 "$(pending_toon t1 RUN1 pending pending)"
  set_runs "$root" here:running:1 here:pending:1 here:completed:5
  out=$(sweep "$root" 1000)
  [ -z "$out" ] || fail "first sight must stay silent: $out"
  out=$(sweep "$root" 1299)
  [ -z "$out" ] || fail "under five minutes must stay silent: $out"
  out=$(sweep "$root" 1300)
  assert_contains "$out" "t1 run RUN1 pending with no step started" "five minutes pending wakes"
  assert_contains "$out" "while a run slot is free (1 of 4 run slots in use machine-wide)" "wake names the slot state"
  out=$(sweep "$root" 1900)
  [ -z "$out" ] || fail "the same run and state must not wake twice: $out"
  pass "pending with no steps wakes once at five minutes"
}

test_pending_run_that_started_a_step_clears_and_a_new_stall_wakes_again() {
  local root out
  root=$(make_world clear 4)
  add_task "$root" t1
  set_status "$root" t1 "$(pending_toon t1 RUN1)"
  set_runs "$root" here:pending:1
  sweep "$root" 1000 >/dev/null
  out=$(sweep "$root" 1400)
  assert_contains "$out" "t1 run RUN1 pending" "empty steps table also counts as no step started"
  # The run moves: a step starts. The record row goes away.
  set_status "$root" t1 "$(pending_toon t1 RUN1 running pending)"
  out=$(sweep "$root" 1500)
  [ -z "$out" ] || fail "a started step is not a stall: $out"
  assert_no_grep "RUN1" "$root/state/.nm-stall-check" "cleared state must drop its record row"
  # The same run id stalls pending again later: a fresh clock, a fresh wake.
  set_status "$root" t1 "$(pending_toon t1 RUN1 pending)"
  out=$(sweep "$root" 1600)
  [ -z "$out" ] || fail "clock must restart after a clear: $out"
  out=$(sweep "$root" 1900)
  assert_contains "$out" "t1 run RUN1 pending" "second stall wakes again"
  pass "a moved run clears and a later stall wakes again"
}

test_pending_behind_full_slots_is_silent_and_starts_no_clock() {
  local root out
  root=$(make_world full 2)
  add_task "$root" t1
  set_status "$root" t1 "$(pending_toon t1 RUN1 pending)"
  set_runs "$root" here:running:2 here:pending:1
  sweep "$root" 1000 >/dev/null
  out=$(sweep "$root" 5000)
  [ -z "$out" ] || fail "queued behind full slots must stay silent: $out"
  assert_absent "$root/state/.nm-stall-check" "no clock may start while the slots are full"
  # A slot frees; the clock starts then, not before.
  set_runs "$root" here:running:1 here:completed:1 here:pending:1
  out=$(sweep "$root" 5100)
  [ -z "$out" ] || fail "clock starts when the slot frees: $out"
  out=$(sweep "$root" 5400)
  assert_contains "$out" "pending with no step started" "wakes five minutes after the slot freed"
  pass "full run slots keep a pending run silent"
}

assert_unknown_slot_state() {  # <out> <what>
  assert_contains "$1" "t1 run RUN1 pending with no step started for 5m while the run slot state is unknown" "$2 is disclosed"
  case "$1" in *"slot is free"*) fail "$2 must never claim a free slot: $1" ;; esac
}

test_unknown_slot_state_still_wakes_and_says_so() {
  local root out
  root=$(make_world unknown none)
  add_task "$root" t1
  set_status "$root" t1 "$(pending_toon t1 RUN1)"
  set_runs "$root" here:pending:1
  sweep "$root" 1000 >/dev/null
  out=$(sweep "$root" 1300)
  assert_unknown_slot_state "$out" "an unreadable cap"
  pass "unreadable slot state wakes with a caveat"
}

# Machine-wide cap: one pending run here (task "t1"), and <n> running runs in a
# repo this home has no task in.
machine_world() {  # <name> <running elsewhere> <cap>
  local root
  root=$(make_world "$1" "$3")
  add_task "$root" t1
  set_status "$root" t1 "$(pending_toon t1 RUN1)"
  set_runs "$root" here:pending:1 elsewhere:running:"$2" elsewhere:pending:2 elsewhere:failed:3
  printf '%s' "$root"
}

test_runs_in_another_repo_fill_the_machine_slots() {
  local root out
  root=$(machine_world other4 4 4)
  sweep "$root" 1000 >/dev/null
  out=$(sweep "$root" 5000)
  [ -z "$out" ] || fail "four running elsewhere must keep the pending run silent: $out"
  assert_absent "$root/state/.nm-stall-check" "no clock while machine slots are full"
  pass "machine-wide count: full slots held by a repo with no task here stay silent"
}

test_free_machine_slot_with_runs_elsewhere_still_alarms() {
  local root out
  root=$(machine_world other3 3 4)
  sweep "$root" 1000 >/dev/null
  out=$(sweep "$root" 1300)
  assert_contains "$out" "t1 run RUN1 pending with no step started for 5m while a run slot is free (3 of 4 run slots in use machine-wide)" "three of four slots wakes"
  pass "machine-wide count: a free slot still alarms"
}

test_unreadable_machine_count_never_claims_a_free_slot() {
  local root out kind
  for kind in missing corrupt; do
    root=$(make_world "unread-$kind" 4)
    add_task "$root" t1
    set_status "$root" t1 "$(pending_toon t1 RUN1)"
    [ "$kind" = missing ] || printf 'not a database' > "$root/nmhome/state.sqlite"
    sweep "$root" 1000 >/dev/null
    out=$(sweep "$root" 1300)
    assert_unknown_slot_state "$out" "a $kind state database"
  done
  assert_absent "$TMP_ROOT/unread-missing/nmhome/state.sqlite" "the read-only count must never create the database"
  pass "machine-wide count: an unreadable count is unknown, not free"
}

test_slot_count_is_read_once_per_sweep() {
  local root out
  root=$(make_world once 2)
  add_task "$root" t1
  add_task "$root" t2
  set_status "$root" t1 "$(pending_toon t1 RUN1)"
  set_status "$root" t2 "$(pending_toon t2 RUN2)"
  set_runs "$root" here:running:1 here:pending:2
  # shellcheck disable=SC2016 # the stub script must keep "$@" and ${1:-} literal
  printf '#!/usr/bin/env bash\n[ "${1:-}" != -I ] || printf x >> "%s"\nexec "%s" "$@"\n' \
    "$root/fake/python.calls" "$(command -v python3)" > "$root/bin/python3"
  chmod +x "$root/bin/python3"
  sweep "$root" 1000 >/dev/null
  out=$(sweep "$root" 1300)
  assert_contains "$out" "t1 run RUN1 pending" "first pending task wakes"
  assert_contains "$out" "t2 run RUN2 pending" "second pending task wakes"
  [ "$(cat "$root/fake/python.calls")" = xx ] || fail "one count per sweep expected, saw: $(cat "$root/fake/python.calls")"
  pass "the machine-wide count is read once per sweep"
}

test_gate_wakes_after_thirty_minutes_routed_to_the_captain_for_ask_user() {
  local root out
  root=$(make_world gate 4)
  add_task "$root" t1
  set_status "$root" t1 "$(gate_toon t1 RUN1 review ask-user 1m)"
  out=$(sweep "$root" 1000)
  [ -z "$out" ] || fail "first sight of a gate must stay silent: $out"
  out=$(sweep "$root" 2799)
  [ -z "$out" ] || fail "under thirty minutes must stay silent: $out"
  out=$(sweep "$root" 2800)
  assert_contains "$out" "t1 run RUN1 parked at review" "gate wake names the task, run and gate"
  assert_contains "$out" "owed by the captain through firstmate (ask-user findings r1)" "ask-user routes to the captain"
  out=$(sweep "$root" 9000)
  [ -z "$out" ] || fail "the same gate must not wake twice: $out"
  pass "a gate parked thirty minutes wakes once, routed by owner"
}

test_gate_owed_by_the_worker_routes_to_the_worker() {
  local root out
  root=$(make_world workergate 4)
  add_task "$root" t1
  set_status "$root" t1 "$(gate_toon t1 RUN1 review auto-fix 1m)"
  sweep "$root" 1000 >/dev/null
  out=$(sweep "$root" 2900)
  assert_contains "$out" "owed by the task's own worker (t1)" "auto-fix gate routes to the worker"
  pass "a worker-owed gate routes to its worker"
}

test_run_reported_parked_age_counts_on_first_sight() {
  local root out
  root=$(make_world parkedage 4)
  add_task "$root" t1
  set_status "$root" t1 "$(gate_toon t1 RUN1 review ask-user 1h2m3s)"
  out=$(sweep "$root" 1000)
  assert_contains "$out" "parked at review for 63m" "the run's own parked duration is used when longer than first sight"
  pass "the run's reported parked age counts at first sight"
}

test_new_gate_or_answered_gate_resets() {
  local root out
  root=$(make_world newgate 4)
  add_task "$root" t1
  set_status "$root" t1 "$(gate_toon t1 RUN1 review ask-user 1m)"
  sweep "$root" 1000 >/dev/null
  out=$(sweep "$root" 2900)
  assert_contains "$out" "parked at review" "first gate wakes"
  set_status "$root" t1 "$(gate_toon t1 RUN1 test ask-user 1m)"
  out=$(sweep "$root" 3000)
  [ -z "$out" ] || fail "a different gate starts a new clock: $out"
  out=$(sweep "$root" 4900)
  assert_contains "$out" "parked at test" "the new gate wakes on its own clock"
  pass "a different gate is a new state"
}

test_unreadable_read_keeps_the_clock_and_never_wakes() {
  local root out
  root=$(make_world unreadable 4)
  add_task "$root" t1
  set_status "$root" t1 "$(gate_toon t1 RUN1 review ask-user 1m)"
  sweep "$root" 1000 >/dev/null
  : > "$root/fake/t1.fail"
  out=$(sweep "$root" 2900)
  [ -z "$out" ] || fail "an unreadable read must not wake: $out"
  assert_grep "RUN1" "$root/state/.nm-stall-check" "an unreadable read must keep the row"
  rm -f "$root/fake/t1.fail"
  out=$(sweep "$root" 3000)
  assert_contains "$out" "parked at review" "the retained clock still counts once readable"
  pass "an unreadable read neither wakes nor resets"
}

test_other_tasks_and_other_branches_are_ignored() {
  local root out
  root=$(make_world ignored 4)
  add_task "$root" t1 "remote_host=far"
  add_task "$root" t2
  printf 'kind=scout\nmode=no-mistakes\nbranch=fm/t3\nworktree=%s\n' "$root/wt/t2" > "$root/state/t3.meta"
  add_task "$root" t4
  set_status "$root" t1 "$(gate_toon t1 RUN1 review ask-user 1m)"
  set_status "$root" t2 "$(gate_toon t2 RUN2 review ask-user 1m)"
  # t4's copy answers with another branch's run.
  set_status "$root" t4 "$(gate_toon other RUN4 review ask-user 1m)"
  # t2 is a finished run: terminal outcome.
  set_status "$root" t2 "$(printf 'run:\n  id: "RUN2"\n  branch: fm/t2\n  status: completed\n  outcome: passed\n')"
  sweep "$root" 1000 >/dev/null
  out=$(sweep "$root" 9000)
  [ -z "$out" ] || fail "remote, scout, terminal and foreign-branch runs must stay silent: $out"
  pass "remote, scout, terminal and foreign-branch runs are ignored"
}

test_two_tasks_wake_in_one_line_and_a_torn_down_task_drops_its_row() {
  local root out
  root=$(make_world two 4)
  add_task "$root" t1
  add_task "$root" t2
  set_status "$root" t1 "$(gate_toon t1 RUN1 review ask-user 1m)"
  set_status "$root" t2 "$(gate_toon t2 RUN2 review auto-fix 1m)"
  sweep "$root" 1000 >/dev/null
  out=$(sweep "$root" 2900)
  assert_contains "$out" "t1 run RUN1" "first task named"
  assert_contains "$out" "t2 run RUN2" "second task named"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] || fail "wakes must share one line: $out"
  rm -f "$root/state/t1.meta"
  sweep "$root" 3000 >/dev/null
  assert_no_grep "RUN1" "$root/state/.nm-stall-check" "a gone task keeps no row"
  assert_grep "RUN2" "$root/state/.nm-stall-check" "a live task keeps its row"
  pass "one line for several tasks, and a gone task is dropped"
}

test_sweep_never_drives_a_run() {
  local root
  root=$(make_world readonly 4)
  add_task "$root" t1
  set_status "$root" t1 "$(gate_toon t1 RUN1 review ask-user 1m)"
  cat > "$root/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "axi status") cat "$FAKE_DIR/$(basename "$PWD").status" ;;
  "axi ") : ;;
  *) printf '%s\n' "$*" >> "$FAKE_DIR/forbidden.log" ;;
esac
SH
  sweep "$root" 1000 >/dev/null
  sweep "$root" 9000 >/dev/null
  assert_absent "$root/fake/forbidden.log" "the sweep may only read status"
  pass "the sweep only reads"
}

ack_wakes() {  # <root>: drain and acknowledge the queue as firstmate does
  local root=$1 seq gen
  FM_STATE_OVERRIDE="$root/state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$root/drain.err" || return 1
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$root/drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$root/drain.err")
  [ -n "$seq" ] && [ -n "$gen" ] || return 1
  FM_STATE_OVERRIDE="$root/state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null
}

watch_once() {  # <root> <now> <alarm secs>
  local root=$1
  mkdir -p "$root/config"
  FAKE_DIR="$root/fake" PATH="$root/bin:$PATH" NM_HOME="$root/nmhome" FM_HOME="$root" \
    FM_STATE_OVERRIDE="$root/state" FM_CONFIG_OVERRIDE="$root/config" FM_NM_STALL_NOW="$2" \
    FM_CHECK_INTERVAL=0 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    perl -e 'alarm shift; exec @ARGV' "$3" "$ROOT/bin/fm-watch.sh" 2>"$root/watch.err"
}

test_watcher_sweep_wakes_once_on_a_stalled_run() {
  local root out
  root=$(make_world watch 4)
  for cli in herdr gh treehouse; do printf '#!/usr/bin/env bash\nexit 1\n' > "$root/bin/$cli"; chmod +x "$root/bin/$cli"; done
  add_task "$root" t1
  set_status "$root" t1 "$(gate_toon t1 RUN1 review ask-user 1m)"
  sweep "$root" 1000 >/dev/null
  out=$(watch_once "$root" 2900 60) || fail "watch: the watcher failed: $(cat "$root/watch.err")"
  [ "$(printf '%s\n' "$out" | grep -c 'check: nm-stall: ')" = 1 ] \
    || fail "watch: the stalled run did not wake the home exactly once: $out"
  assert_contains "$out" "check: nm-stall: t1 run RUN1 parked at review" "the wake carries the stall line"
  [ "$(grep -c 'check: nm-stall: ' "$root/state/.wake-queue" 2>/dev/null)" = 1 ] \
    || fail "watch: the stall was not queued as exactly one wake: $(cat "$root/state/.wake-queue" 2>/dev/null)"
  # Firstmate read the queue. A second task stalls, so the next sweep has a wake
  # of its own; the first task's stall must not ride along with it.
  ack_wakes "$root" || fail "watch: the first wake could not be acknowledged: $(cat "$root/drain.err")"
  add_task "$root" t2
  set_status "$root" t2 "$(gate_toon t2 RUN2 review auto-fix 1m)"
  sweep "$root" 2900 >/dev/null
  out=$(watch_once "$root" 9000 60) || fail "watch: the second watcher failed: $(cat "$root/watch.err")"
  assert_contains "$out" "check: nm-stall: t2 run RUN2 parked at review" "the second sweep wakes on the new stall"
  case "$out" in *"RUN1"*) fail "watch: the second sweep woke again on the first stall: $out" ;; esac
  ! grep -q 'RUN1' "$root/state/.wake-queue" 2>/dev/null || fail "watch: the second sweep queued the first stall again"
  pass "the watcher's check sweep wakes once on a stalled run"
}

fm_test_run \
  test_pending_with_no_steps_wakes_once_after_five_minutes \
  test_pending_run_that_started_a_step_clears_and_a_new_stall_wakes_again \
  test_pending_behind_full_slots_is_silent_and_starts_no_clock \
  test_unknown_slot_state_still_wakes_and_says_so \
  test_runs_in_another_repo_fill_the_machine_slots \
  test_free_machine_slot_with_runs_elsewhere_still_alarms \
  test_unreadable_machine_count_never_claims_a_free_slot \
  test_slot_count_is_read_once_per_sweep \
  test_gate_wakes_after_thirty_minutes_routed_to_the_captain_for_ask_user \
  test_gate_owed_by_the_worker_routes_to_the_worker \
  test_run_reported_parked_age_counts_on_first_sight \
  test_new_gate_or_answered_gate_resets \
  test_unreadable_read_keeps_the_clock_and_never_wakes \
  test_other_tasks_and_other_branches_are_ignored \
  test_two_tasks_wake_in_one_line_and_a_torn_down_task_drops_its_row \
  test_sweep_never_drives_a_run \
  test_watcher_sweep_wakes_once_on_a_stalled_run
