#!/usr/bin/env bash
# Behavior tests for the automatic no-mistakes drive steer
# (bin/fm-nm-drive-steer.sh, fm_nm_drive_call_live in bin/fm-nm-run-lib.sh, and
# its first-sight stale hook in bin/fm-watch.sh).
#
# Two slips leave a no-mistakes ship idle with nothing that will wake it: a
# pre-pipeline done: whose worker never started validation, and an active run
# whose worker ended its turn with no drive call running. Each must get exactly
# one fixed steer per task generation and no stale wake, after which the
# ordinary stale alarm applies again. A worker with a live drive call or a
# declared external wait gets neither.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

STEER="$ROOT/bin/fm-nm-drive-steer.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-drive-steer-tests)

WORKING_RUN='state: working · source: run-step · run active (pending) · status-log superseded by active run · run: R1'
NO_RUN='state: blocked · source: status-log · named head not reachable outside the task copy'

# One lane: a home with a task record, status log, worktree, fake tmux and
# crew-state from make_case, a fake ps that lists $dir/ps.txt for the
# drive-call probe's listing (and defers to the real ps otherwise), and an
# empty fake /proc at $dir/proc.
drive_case() {  # <name> <status-line> -> dir
  local name=$1 line=$2 dir real_ps
  dir=$(make_case "$name")
  mkdir -p "$dir/wt" "$dir/proc"
  : > "$dir/ps.txt"
  real_ps=$(command -v ps)
  cat > "$dir/fakebin/ps" <<SH
#!/usr/bin/env bash
if [ "\$*" = "-A -o pid= -o args=" ]; then
  [ -z "\${FM_FAKE_PS_FAIL:-}" ] || exit 1
  cat "$dir/ps.txt"
  exit 0
fi
exec "$real_ps" "\$@"
SH
  chmod +x "$dir/fakebin/ps"
  printf 'window=test:fm-%s\nkind=ship\nmode=no-mistakes\nbranch=fm/%s\nworktree=%s\nspawn_gen=s1\n' \
    "$name" "$name" "$dir/wt" > "$dir/state/$name.meta"
  printf '%s\n' "$line" > "$dir/state/$name.status"
  printf '%s\n' "$dir"
}

# Record a running drive call whose working directory is <cwd>.
live_drive_call() {  # <dir> <pid> <cwd> [args]
  local dir=$1 pid=$2 cwd=$3 args=${4:-no-mistakes axi run --wait 60m}
  printf '%s %s\n' "$pid" "$args" >> "$dir/ps.txt"
  mkdir -p "$dir/proc/$pid"
  ln -s "$cwd" "$dir/proc/$pid/cwd"
}

run_steer() {  # <dir> <task> <crew-state-line>
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_PROC_ROOT_OVERRIDE="$dir/proc" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE="$3" \
    FM_FAKE_TMUX_WINDOW="test:fm-$2" "$STEER" "$2"
}

inbox_count() {  # <dir> <task>
  local n=0 f
  for f in "$1/state/$2.inbox"/*.msg "$1/state/$2.inbox/handled"/*.msg; do
    [ -e "$f" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

inbox_body() {  # <dir> <task>
  cat "$1/state/$2.inbox"/*.msg 2>/dev/null
}

# Move every queued steer into handled/, as the worker's acknowledgement does.
ack_inbox() {  # <dir> <task>
  local f
  for f in "$1/state/$2.inbox"/*.msg; do
    [ -e "$f" ] && mv "$f" "$1/state/$2.inbox/handled/"
  done
}

test_prepipeline_done_without_a_run_gets_one_start_steer() {
  local dir
  dir=$(drive_case start 'done [at=1]: implemented and committed on fm/start')
  run_steer "$dir" start "$NO_RUN" || fail "a pre-pipeline done with no run was not steered"
  [ "$(inbox_count "$dir" start)" = 1 ] || fail "the start steer was not one durable inbox record"
  inbox_body "$dir" start | grep -F "/no-mistakes" >/dev/null || fail "the start steer does not tell the worker to run /no-mistakes"
  inbox_body "$dir" start | grep -F "fm/start" >/dev/null || fail "the start steer does not name the branch"
  ack_inbox "$dir" start
  if run_steer "$dir" start "$NO_RUN"; then fail "the start slip was steered twice in one generation"; fi
  [ "$(inbox_count "$dir" start)" = 1 ] || fail "a second start steer was recorded"
  pass "a pre-pipeline done with no run gets exactly one start steer per generation"
}

test_active_run_without_a_drive_call_gets_one_reattach_steer() {
  local dir
  dir=$(drive_case reattach 'paused [at=1]: no-mistakes run queued; background reattach will wake me')
  run_steer "$dir" reattach "$WORKING_RUN" || fail "an active run with no drive call was not steered"
  [ "$(inbox_count "$dir" reattach)" = 1 ] || fail "the reattach steer was not one durable inbox record"
  inbox_body "$dir" reattach | grep -F "no-mistakes axi run" >/dev/null || fail "the reattach steer does not name the reattach command"
  ack_inbox "$dir" reattach
  if run_steer "$dir" reattach "$WORKING_RUN"; then fail "the reattach slip was steered twice in one generation"; fi
  # A relaunch is a new generation and gets its own steer.
  sed -i.bak 's/^spawn_gen=s1$/spawn_gen=s2/' "$dir/state/reattach.meta"
  run_steer "$dir" reattach "$WORKING_RUN" || fail "a new task generation did not get its own steer"
  [ "$(inbox_count "$dir" reattach)" = 2 ] || fail "the new generation's steer was not recorded"
  pass "an active run with no drive call gets exactly one reattach steer per generation"
}

test_pending_run_steer_names_the_runs_holding_the_slots() {
  local dir body
  dir=$(drive_case queued 'paused [at=1]: no-mistakes run queued')
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "$1" = axi ] || exit 1
cat <<'OUT'
runs[4]{id,branch,status,head,pr}:
  "RUNPEND","fm/queued",pending,aaaaaaa1,""
  "RUNONE","fm/other-one",running,bbbbbbb2,""
  "RUNTWO","fm/other-two",running,ccccccc3,"https://example.test/pull/1"
  "RUNOLD","fm/old",handed_off,ddddddd4,""
OUT
SH
  chmod +x "$dir/fakebin/no-mistakes"
  run_steer "$dir" queued 'state: working · source: run-step · run active (pending) · run: RUNPEND' \
    || fail "a pending run with no drive call was not steered"
  body=$(inbox_body "$dir" queued)
  printf '%s' "$body" | grep -F 'paused [cause=external]' >/dev/null || fail "the pending steer does not say the wait is paused, not blocked"
  printf '%s' "$body" | grep -F 'fm/other-one (run RUNONE), fm/other-two (run RUNTWO)' >/dev/null \
    || fail "the pending steer does not name the runs holding the slots"
  printf '%s' "$body" | grep -F 'fm/old' >/dev/null && fail "a finished run was named as holding a slot"
  printf '%s' "$body" | grep -F 'fm/queued (run' >/dev/null && fail "the worker's own run was named as holding a slot"
  # A non-pending active run gets the plain steer.
  dir=$(drive_case plain 'paused [at=1]: no-mistakes run queued')
  run_steer "$dir" plain 'state: working · source: run-step · run active (running) · run: R1' || fail "the plain reattach was not steered"
  inbox_body "$dir" plain | grep -F 'run slots' >/dev/null && fail "a run that is not pending got the slot text"
  pass "a pending run's reattach steer says paused and names the runs holding the slots"
}

test_parked_gate_the_worker_owes_is_a_reattach_but_a_human_gate_is_not() {
  local dir
  dir=$(drive_case parked 'working [at=1]: answered the review gate')
  if run_steer "$dir" parked 'state: parked · source: run-step · awaiting_approval · ask-user: authority decision · run: R2'; then
    fail "a gate a human owes was steered"
  fi
  [ "$(inbox_count "$dir" parked)" = 0 ] || fail "a human gate recorded a steer"
  run_steer "$dir" parked 'state: parked · source: run-step · fix_review · run: R2' \
    || fail "a gate the worker owes, with no drive call, was not steered"
  pass "a parked gate the worker owes is steered to reattach, a gate a human owes is not"
}

test_live_drive_call_gets_no_steer() {
  local dir
  dir=$(drive_case live 'paused [at=1]: no-mistakes pipeline driving in background')
  live_drive_call "$dir" 4242 "$dir/wt/sub"
  mkdir -p "$dir/wt/sub"
  if run_steer "$dir" live "$WORKING_RUN"; then fail "a worker with a live drive call was steered"; fi
  dir=$(drive_case live-respond 'done [at=1]: committed on fm/live-respond')
  live_drive_call "$dir" 4343 "$dir/wt" "/opt/bin/no-mistakes axi respond --run R3 --action approve"
  if run_steer "$dir" live-respond "$NO_RUN"; then fail "a worker inside a respond call was steered"; fi
  [ "$(inbox_count "$dir" live-respond)" = 0 ] || fail "a live drive call recorded a steer"
  pass "a worker with a live run or respond drive call gets no steer"
}

test_unrelated_processes_are_not_drive_calls() {
  local dir
  dir=$(drive_case unrelated 'paused [at=1]: no-mistakes run queued')
  # A shell whose script mentions the command, a status read from the same
  # copy, and a drive call in a different copy are none of them this worker's.
  live_drive_call "$dir" 5001 "$dir/wt" "/bin/bash -c no-mistakes axi run > out"
  live_drive_call "$dir" 5002 "$dir/wt" "no-mistakes axi status"
  mkdir -p "$dir/other"
  live_drive_call "$dir" 5003 "$dir/other" "no-mistakes axi run"
  run_steer "$dir" unrelated "$WORKING_RUN" || fail "unrelated processes were taken for this worker's drive call"
  pass "only a no-mistakes axi run or respond process in the worker's own copy counts as a drive call"
}

# Where /proc does not exist (macOS), the probe reads each candidate's working
# directory from `lsof -a -p <pid> -d cwd -Fn`, whose field output is one
# `p<pid>`, `f<fd>` and `n<name>` record per line (lsof(8) OUTPUT FOR OTHER
# PROGRAMS). The fake lsof prints those records from $dir/lsof/<pid>, and the
# fake `ps -p <pid>` reports a pid alive while $dir/alive/<pid> exists.
probe_without_proc() {  # <dir>
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$dir/no-proc" \
    bash -c '. "$1/bin/fm-nm-run-lib.sh"; fm_nm_drive_call_live "$2"' _ "$ROOT" "$dir/wt"
}

test_lsof_probe_reads_the_drive_call_cwd_without_proc() {
  local dir rc
  dir="$TMP_ROOT/lsof"
  mkdir -p "$dir/fakebin" "$dir/wt/sub" "$dir/other" "$dir/lsof" "$dir/alive"
  dir=$(cd "$dir" && pwd -P)
  cat > "$dir/fakebin/ps" <<SH
#!/usr/bin/env bash
if [ "\$*" = "-A -o pid= -o args=" ]; then cat "$dir/ps.txt"; exit 0; fi
if [ "\$1" = "-p" ]; then [ -e "$dir/alive/\$2" ]; exit; fi
exit 1
SH
  cat > "$dir/fakebin/lsof" <<SH
#!/usr/bin/env bash
[ "\$*" = "-a -p \$3 -d cwd -Fn" ] || exit 1
cat "$dir/lsof/\$3" 2>/dev/null
SH
  chmod +x "$dir/fakebin/ps" "$dir/fakebin/lsof"

  printf '6001 no-mistakes axi run --wait 60m\n' > "$dir/ps.txt"
  printf 'p6001\nfcwd\nn%s\n' "$dir/wt/sub" > "$dir/lsof/6001"
  rc=0; probe_without_proc "$dir" || rc=$?
  [ "$rc" = 0 ] || fail "a drive call whose lsof cwd is inside the copy answered $rc, not 0"

  printf 'p6001\nfcwd\nn%s\n' "$dir/other" > "$dir/lsof/6001"
  rc=0; probe_without_proc "$dir" || rc=$?
  [ "$rc" = 1 ] || fail "a drive call whose lsof cwd is another copy answered $rc, not 1"

  : > "$dir/lsof/6001"
  : > "$dir/alive/6001"
  rc=0; probe_without_proc "$dir" || rc=$?
  [ "$rc" = 2 ] || fail "a live drive call with no readable lsof cwd answered $rc, not 2"

  rm -f "$dir/alive/6001"
  rc=0; probe_without_proc "$dir" || rc=$?
  [ "$rc" = 1 ] || fail "a drive call that exited since the listing answered $rc, not 1"
  pass "without /proc the probe reads the drive call's cwd from lsof field output"
}

test_declared_external_wait_gets_no_steer() {
  local dir line
  for line in \
    'paused [at=1] [cause=external]: no-mistakes run queued behind other lanes' \
    'blocked [at=1] [cause=external]: no-mistakes run pending for 24 min' \
    'needs-decision [at=1] [cause=decision] [key=nm-r1-review]: ask-user findings=f1 file=/tmp/f.txt' \
    'paused [at=1] [dep=pr/o/r/7]: waiting on the base PR'; do
    dir=$(drive_case "wait-$RANDOM" "$line")
    if run_steer "$dir" "${dir##*/}" "$WORKING_RUN"; then fail "a declared wait was steered: $line"; fi
  done
  pass "a declared external wait, blocker, or open decision gets no steer"
}

test_only_an_open_decision_outlives_a_later_event() {
  local dir
  dir=$(drive_case superseded-blocker 'blocked [at=1] [cause=external]: run pending for 25 min')
  printf '%s\n' 'paused [at=2]: no-mistakes run queued; background reattach will wake me' \
    >> "$dir/state/superseded-blocker.status"
  run_steer "$dir" superseded-blocker "$WORKING_RUN" \
    || fail "an older blocker superseded by a later pause suppressed the steer"
  dir=$(drive_case open-decision 'needs-decision [at=1] [cause=decision] [key=scope]: pick a scope')
  printf '%s\n' 'paused [at=2]: no-mistakes run queued' >> "$dir/state/open-decision.status"
  if run_steer "$dir" open-decision "$WORKING_RUN"; then fail "a worker with an open decision was steered"; fi
  pass "an older blocker a later event superseded allows the steer, an open decision does not"
}

test_unknown_probe_or_ci_ready_done_gets_no_steer() {
  local dir
  dir=$(drive_case ps-fails 'paused [at=1]: no-mistakes run queued')
  if FM_FAKE_PS_FAIL=1 run_steer "$dir" ps-fails "$WORKING_RUN"; then fail "an unreadable process table was read as no drive call"; fi
  dir=$(drive_case ci-ready 'done [at=1]: PR https://github.com/o/r/pull/9 checks green')
  if run_steer "$dir" ci-ready "$NO_RUN"; then fail "a CI-ready done was steered to start validation"; fi
  dir=$(drive_case pending-steer 'done [at=1]: committed on fm/pending-steer')
  mkdir -p "$dir/state/pending-steer.inbox/handled"
  printf 'schema=fm-task-inbox.v1\nat=2026-11-06T00:00:00Z\nbody-terminator=1\n--\nRun /no-mistakes now.\n' \
    > "$dir/state/pending-steer.inbox/001.msg"
  if run_steer "$dir" pending-steer "$NO_RUN"; then fail "a steer was stacked on an unhandled one"; fi
  pass "an unknown probe, a CI-ready done, or an unhandled steer gets no automatic steer"
}

# --- the watcher hook -------------------------------------------------------

# Run one watcher round for a lane whose pane is already stably idle at <text>:
# the poll sees the hash for the second time, which is first sight of a stale.
drive_watch_round() {  # <dir> <task> <crew-state-line> <pane-text> <exit|absorb> [escalate-secs]
  local dir=$1 task=$2 verdict=$3 text=$4 mode=$5 esc=${6:-999} state key pid
  state="$dir/state"
  printf '%s' "$text" > "$dir/pane.txt"
  key=$(printf '%s' "test:fm-$task" | tr ':/.' '___')
  printf '%s' "$(hash_text "$text")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$(seen_sig "$state/$task.status")" > "$state/.seen-${task}_status"
  : > "$dir/watch.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_PROC_ROOT_OVERRIDE="$dir/proc" FM_FAKE_TMUX_WINDOW="test:fm-$task" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    FM_FAKE_CREW_STATE="$verdict" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS="$esc" \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" &
  pid=$!
  if [ "$mode" = exit ]; then
    wait_for_exit "$pid" 100 || { reap "$pid"; return 1; }
    return 0
  fi
  wait_poll_cycle "$state" "$pid" || return 1
  wait_poll_cycle "$state" "$pid" || return 1
  reap "$pid"
  # Stopping a watcher by hand leaves a recovery record the next round would
  # otherwise surface first; acknowledge it as the stopped cycle it is.
  ack_stopped_cycle "$state"
}

stale_wakes() {  # <state>
  local n
  n=$(grep -c "$(printf '\tstale\t')" "$1/.wake-queue" 2>/dev/null) || n=0
  printf '%s' "${n:-0}"
}

test_watcher_steers_a_prepipeline_done_instead_of_alarming() {
  local dir
  dir=$(drive_case wstart 'done [at=1]: implemented and committed on fm/wstart')
  drive_watch_round "$dir" wstart "$NO_RUN" 'idle prompt after done' absorb \
    || fail "the watcher alarmed instead of steering a pre-pipeline done: $(cat "$dir/watch.out")"
  [ "$(stale_wakes "$dir/state")" -eq 0 ] || fail "a steered pre-pipeline done still queued a stale wake"
  [ "$(inbox_count "$dir" wstart)" = 1 ] || fail "the watcher did not record exactly one start steer"
  # The worker acted and went quiet again on a new pane: the slip is spent, so
  # the ordinary alarm is back.
  ack_inbox "$dir" wstart
  drive_watch_round "$dir" wstart "$NO_RUN" 'idle prompt after done, again' exit \
    || fail "a repeated slip in the same generation did not fall back to the stale alarm"
  grep -F "stale: test:fm-wstart" "$dir/watch.out" >/dev/null || fail "the fallback was not the ordinary stale wake: $(cat "$dir/watch.out")"
  [ "$(inbox_count "$dir" wstart)" = 1 ] || fail "the fallback sent a second steer"
  pass "the watcher steers a pre-pipeline done once instead of a stale wake, then alarms as before"
}

test_watcher_steers_an_undriven_run_then_alarms_when_still_quiet() {
  local dir
  dir=$(drive_case wreattach 'paused [at=1]: no-mistakes run queued; background reattach will wake me')
  drive_watch_round "$dir" wreattach "$WORKING_RUN" 'idle prompt, nothing running' absorb \
    || fail "the watcher alarmed instead of steering an undriven run: $(cat "$dir/watch.out")"
  [ "$(stale_wakes "$dir/state")" -eq 0 ] || fail "a steered undriven run still queued a stale wake"
  [ "$(inbox_count "$dir" wreattach)" = 1 ] || fail "the watcher did not record exactly one reattach steer"
  # Still quiet on the very same pane once the hold elapses: the ordinary
  # first-sight decision runs, exactly as if no steer had been sent.
  ack_inbox "$dir" wreattach
  drive_watch_round "$dir" wreattach 'state: parked · source: run-step · fix_review · run: R1' \
    'idle prompt, nothing running' exit 0 \
    || fail "a worker still quiet after its steer was not alarmed"
  grep -F "stale: test:fm-wreattach" "$dir/watch.out" >/dev/null || fail "the fallback was not the ordinary stale wake"
  [ "$(inbox_count "$dir" wreattach)" = 1 ] || fail "the fallback sent a second steer"
  pass "the watcher steers an undriven run once, then alarms when the worker stays quiet"
}

test_watcher_leaves_a_live_drive_call_alone() {
  local dir
  dir=$(drive_case wlive 'paused [at=1]: no-mistakes pipeline driving in background')
  live_drive_call "$dir" 6001 "$dir/wt"
  drive_watch_round "$dir" wlive "$WORKING_RUN" 'idle, drive call in background' absorb \
    || fail "a worker with a live drive call was alarmed: $(cat "$dir/watch.out")"
  [ "$(inbox_count "$dir" wlive)" = 0 ] || fail "a worker with a live drive call was steered"
  [ "$(stale_wakes "$dir/state")" -eq 0 ] || fail "a worker with a live drive call queued a stale wake"
  pass "the watcher neither steers nor alarms a worker whose drive call is live"
}

fm_test_run \
  test_prepipeline_done_without_a_run_gets_one_start_steer \
  test_active_run_without_a_drive_call_gets_one_reattach_steer \
  test_pending_run_steer_names_the_runs_holding_the_slots \
  test_parked_gate_the_worker_owes_is_a_reattach_but_a_human_gate_is_not \
  test_live_drive_call_gets_no_steer \
  test_unrelated_processes_are_not_drive_calls \
  test_lsof_probe_reads_the_drive_call_cwd_without_proc \
  test_declared_external_wait_gets_no_steer \
  test_only_an_open_decision_outlives_a_later_event \
  test_unknown_probe_or_ci_ready_done_gets_no_steer \
  test_watcher_steers_a_prepipeline_done_instead_of_alarming \
  test_watcher_steers_an_undriven_run_then_alarms_when_still_quiet \
  test_watcher_leaves_a_live_drive_call_alone
