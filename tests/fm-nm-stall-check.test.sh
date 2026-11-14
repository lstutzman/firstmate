#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-stall-check.sh, over a fake `no-mistakes` whose run
# state is stubbed per task copy. Covers the pending-with-no-steps condition (and
# its run-slot exemption), the gate condition and its owner routing, the once-only
# rule, the clear when a run moves, and unreadable reads.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-stall-check)
CHECK="$ROOT/bin/fm-nm-stall-check.sh"

# A world: <root>/state with metas, <root>/wt/<task> copies, a fake no-mistakes
# serving <root>/fake/<task>.status for `axi status` (exit 1 when <task>.fail
# exists) and <root>/fake/overview for the bare `axi` overview.
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
elif [ "$#" -eq 1 ]; then
  cat "$FAKE_DIR/overview" 2>/dev/null
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

overview_toon() {  # <running count> <branch-prefix>
  local n=$1 i rows=""
  for ((i = 0; i < n; i++)); do rows="$rows  \"01R$i\",fm/other$i,running,abc1234,\"\""$'\n'; done
  printf 'count: %s of %s total\nruns[%s]{id,branch,status,head,pr}:\n%s' "$n" "$n" "$n" "$rows"
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
  printf '%s\n' "$(overview_toon 1)" > "$root/fake/overview"
  out=$(sweep "$root" 1000)
  [ -z "$out" ] || fail "first sight must stay silent: $out"
  out=$(sweep "$root" 1299)
  [ -z "$out" ] || fail "under five minutes must stay silent: $out"
  out=$(sweep "$root" 1300)
  assert_contains "$out" "t1 run RUN1 pending with no step started" "five minutes pending wakes"
  assert_contains "$out" "1 of 4 run slots in use" "wake names the slot state"
  out=$(sweep "$root" 1900)
  [ -z "$out" ] || fail "the same run and state must not wake twice: $out"
  pass "pending with no steps wakes once at five minutes"
}

test_pending_run_that_started_a_step_clears_and_a_new_stall_wakes_again() {
  local root out
  root=$(make_world clear 4)
  add_task "$root" t1
  set_status "$root" t1 "$(pending_toon t1 RUN1)"
  printf '%s\n' "$(overview_toon 0)" > "$root/fake/overview"
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
  printf '%s\n' "$(overview_toon 2)" > "$root/fake/overview"
  sweep "$root" 1000 >/dev/null
  out=$(sweep "$root" 5000)
  [ -z "$out" ] || fail "queued behind full slots must stay silent: $out"
  assert_absent "$root/state/.nm-stall-check" "no clock may start while the slots are full"
  # A slot frees; the clock starts then, not before.
  printf '%s\n' "$(overview_toon 1)" > "$root/fake/overview"
  out=$(sweep "$root" 5100)
  [ -z "$out" ] || fail "clock starts when the slot frees: $out"
  out=$(sweep "$root" 5400)
  assert_contains "$out" "pending with no step started" "wakes five minutes after the slot freed"
  pass "full run slots keep a pending run silent"
}

test_unknown_slot_state_still_wakes_and_says_so() {
  local root out
  root=$(make_world unknown none)
  add_task "$root" t1
  set_status "$root" t1 "$(pending_toon t1 RUN1)"
  sweep "$root" 1000 >/dev/null
  out=$(sweep "$root" 1300)
  assert_contains "$out" "run slot state unknown" "unreadable cap is disclosed, not hidden"
  pass "unreadable slot state wakes with a caveat"
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
  assert_absent "$root/fake/forbidden.log" "the sweep may only read status and the overview"
  pass "the sweep only reads"
}

fm_test_run \
  test_pending_with_no_steps_wakes_once_after_five_minutes \
  test_pending_run_that_started_a_step_clears_and_a_new_stall_wakes_again \
  test_pending_behind_full_slots_is_silent_and_starts_no_clock \
  test_unknown_slot_state_still_wakes_and_says_so \
  test_gate_wakes_after_thirty_minutes_routed_to_the_captain_for_ask_user \
  test_gate_owed_by_the_worker_routes_to_the_worker \
  test_run_reported_parked_age_counts_on_first_sight \
  test_new_gate_or_answered_gate_resets \
  test_unreadable_read_keeps_the_clock_and_never_wakes \
  test_other_tasks_and_other_branches_are_ignored \
  test_two_tasks_wake_in_one_line_and_a_torn_down_task_drops_its_row \
  test_sweep_never_drives_a_run
