#!/usr/bin/env bash
# fm_atomic_mkdir must give exactly one winner per directory however the system
# mkdir behaves (uutils coreutils 0.10.0 lets several racers win).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-atomic-mkdir)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
# shellcheck source=bin/fm-atomic-lib.sh
. "$ROOT/bin/fm-atomic-lib.sh"

# A mkdir that reports success even when the directory exists: the worst case of
# a non-atomic system mkdir, put first on PATH.
mkdir -p "$TMP_ROOT/stub"
# shellcheck disable=SC2016 # the stub script body must keep $a/$last literal
printf '#!/bin/sh\nfor a; do last=$a; done\n/bin/mkdir -p -- "$last"\nexit 0\n' > "$TMP_ROOT/stub/mkdir"
chmod +x "$TMP_ROOT/stub/mkdir"
PATH="$TMP_ROOT/stub:$PATH"

N=20
ROUNDS=5
race() { # <round-dir> <claim-fn>: print the number of winners
  local dir=$1 fn=$2 i
  mkdir -p "$dir/out"
  for i in $(seq 1 "$N"); do
    ( if $fn "$dir/claim"; then : > "$dir/out/win.$i"; fi ) &
  done
  wait
  find "$dir/out" -name 'win.*' | wc -l | tr -d ' '
}
stub_claim() { mkdir "$1" 2>/dev/null; }

for r in $(seq 1 "$ROUNDS"); do
  winners=$(race "$TMP_ROOT/atomic.$r" fm_atomic_mkdir)
  [ "$winners" = 1 ] || fail "round $r: fm_atomic_mkdir gave $winners winners, want exactly 1"
done
# The stub must make the plain-mkdir claim lose exclusivity, or the test proves nothing.
winners=$(race "$TMP_ROOT/plain" stub_claim)
[ "$winners" -gt 1 ] || fail "stub mkdir produced only $winners winners; the race test would be vacuous"

# The remote job sequence claim, under the same stub: 20 concurrent allocators
# must get the 20 distinct sequence numbers 1..20.
mkdir -p "$TMP_ROOT/account"
mkdir -p "$TMP_ROOT/seq-out"
export FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-job"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
fm_remote_job_prepare_state "$TMP_ROOT/account" || fail "$FM_REMOTE_JOB_ERROR"
pids=()
for i in $(seq 1 "$N"); do
  fm_remote_job_next_seq > "$TMP_ROOT/seq-out/$i" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || fail "a concurrent sequence allocator failed"; done
[ "$(cat "$TMP_ROOT"/seq-out/* | sort -n)" = "$(seq 1 "$N")" ] \
  || fail "concurrent sequence claims were not distinct: $(cat "$TMP_ROOT"/seq-out/* | sort -n | tr '\n' ' ')"

# The officer lane lock and the remote worker's job claim and worker lock, run
# from their own scripts (which dispatch on load, so each function is loaded alone).
load_fn() { eval "$(sed -n "/^$2() *{/,/^}/p" "$ROOT/bin/$1")"; }
load_fn fm-officer.sh lock_acquire
load_fn fm-officer.sh lock_is_stale
for fn in worker_claim worker_acquire_lock worker_publish_lock_owner worker_publish_identity worker_lock_recent worker_dir_recent worker_lock_holds_only_owner_files worker_lock_is_stale; do
  load_fn fm-remote-job-worker.sh "$fn"
done
for fn in lock_acquire lock_is_stale worker_claim worker_acquire_lock; do
  declare -F "$fn" >/dev/null || fail "could not load $fn"
done
job_claim() { mkdir -p "$1"; worker_claim "$1"; }
for r in $(seq 1 "$ROUNDS"); do
  winners=$(race "$TMP_ROOT/officer.$r" lock_acquire)
  [ "$winners" = 1 ] || fail "round $r: officer lock_acquire gave $winners winners, want exactly 1"
  winners=$(race "$TMP_ROOT/job.$r" job_claim)
  [ "$winners" = 1 ] || fail "round $r: worker_claim gave $winners winners, want exactly 1"
done
mkdir -p "$TMP_ROOT/officer-nopid"
lock_acquire "$TMP_ROOT/officer-nopid" && fail "officer lock_acquire took over a fresh lock whose owner has not written its pid"
touch -t 200001010000 "$TMP_ROOT/officer-nopid"
lock_acquire "$TMP_ROOT/officer-nopid" || fail "officer lock_acquire did not take over an old lock with no pid"
mkdir -p "$TMP_ROOT/officer-dead"
( exit 0 ) & dead=$!; wait "$dead"
printf '%s\n' "$dead" > "$TMP_ROOT/officer-dead/pid"
lock_acquire "$TMP_ROOT/officer-dead" || fail "officer lock_acquire did not take over a lock whose pid is gone"
# shellcheck disable=SC2034
WORKER_LOCK=$(fm_remote_job_worker_lock_path)
mkdir -p "$TMP_ROOT/worker-out"
for i in $(seq 1 "$N"); do
  ( if worker_acquire_lock "$TMP_ROOT/account" "identity-$i"; then : > "$TMP_ROOT/worker-out/win.$i"; sleep 3; fi ) &
done
wait
[ "$(find "$TMP_ROOT/worker-out" -name 'win.*' | wc -l | tr -d ' ')" = 1 ] \
  || fail "worker_acquire_lock gave $(find "$TMP_ROOT/worker-out" -name 'win.*' | wc -l | tr -d ' ') winners, want exactly 1"

# --- the remaining claim sites, their stale-lock takeover, and the session lock ---
# Each site runs in its own subshell: the scripts that own these locks dispatch
# on load, so each function is loaded alone, and two of them are both called
# lock_acquire. A failure inside a subshell must stop the whole test.
stub_claim_always() { mkdir -p -- "$1"; } # the non-atomic claim of a stub mkdir: every racer wins
RACE_PIDS=()
start_racers() { # <dir> <fn>: N background racers on <dir>/claim; a success leaves <dir>/out/win.<i>
  local dir=$1 fn=$2 i
  mkdir -p "$dir/out"
  RACE_PIDS=()
  for i in $(seq 1 "$N"); do
    ( if $fn "$dir/claim" 2>/dev/null; then : > "$dir/out/win.$i"; fi ) &
    RACE_PIDS+=("$!")
  done
}
stop_racers() { # <dir> <settle-seconds>: let the race settle, stop losers that keep polling (by pid), print winners
  local dir=$1 p
  sleep "$2"
  for p in "${RACE_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  for p in "${RACE_PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
  find "$dir/out" -name 'win.*' | wc -l | tr -d ' '
}
dead_pid() { ( exit 0 ) & local d=$!; wait "$d"; printf '%s\n' "$d"; }
expect_one() { [ "$2" = 1 ] || fail "$1 gave $2 winners, want exactly 1"; }
expect_many() { [ "$2" -gt 1 ] || fail "$1: a non-atomic claim produced only $2 winners; the race test would be vacuous"; }
# jitter_after <fn>: wrap a stale check so that, when fm_atomic_takeover runs it
# and it says "stale", each racer then sleeps a different 0-0.5s before the
# removal, widening the check-then-remove window. A takeover that does not
# serialize its stale check with its removal lets a late racer delete the claim
# an early racer has just made.
jitter_after() {
  eval "real_$(declare -f "$1")"
  eval "$1() { real_$1 \"\$@\" || return; [ \"\${FUNCNAME[1]:-}\" != fm_atomic_takeover ] || sleep \"0.\$(( BASHPID % 6 ))\"; return 0; }"
}
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# Optional mode argument and the takeover primitive itself.
( umask 022; fm_atomic_mkdir "$TMP_ROOT/mode777" 0777 ) || fail "claim with an explicit mode failed"
[ "$(stat -c %a "$TMP_ROOT/mode777" 2>/dev/null || stat -f %Lp "$TMP_ROOT/mode777")" = 755 ] \
  || fail "claim with mode 0777 did not follow the umask like mkdir"
fm_atomic_mkdir "$TMP_ROOT/modebad" notoctal 2>/dev/null && fail "claim with a bad mode succeeded"
always_stale() { return 0; }
never_stale() { return 1; }
fm_atomic_takeover "$TMP_ROOT/absent" always_stale && fail "takeover of a missing lock succeeded"
mkdir -p "$TMP_ROOT/take-yes"
fm_atomic_takeover "$TMP_ROOT/take-yes" always_stale || fail "takeover of a stale lock failed"
[ ! -e "$TMP_ROOT/take-yes" ] || fail "takeover did not remove the stale lock"
mkdir -p "$TMP_ROOT/take-no"; echo live > "$TMP_ROOT/take-no/pid"
fm_atomic_takeover "$TMP_ROOT/take-no" never_stale && fail "takeover removed a lock the verifier called live"
[ "$(cat "$TMP_ROOT/take-no/pid")" = live ] || fail "a refused takeover disturbed the live lock"
for r in $(seq 1 "$ROUNDS"); do
  d=$TMP_ROOT/take-race.$r; mkdir -p "$d/out"; mkdir -p "$d/claim"
  for i in $(seq 1 "$N"); do
    ( if fm_atomic_takeover "$d/claim" always_stale; then : > "$d/out/win.$i"; fi ) &
  done
  wait
  expect_one "round $r: fm_atomic_takeover" "$(find "$d/out" -name 'win.*' | wc -l | tr -d ' ')"
done

# Officer lane lock, and the run-host slot lock (the same function), taken over
# from a dead owner: exactly one racer wins; a live owner is never taken over.
jitter_after lock_is_stale
for r in $(seq 1 "$ROUNDS"); do
  d=$TMP_ROOT/officer-stale.$r; mkdir -p "$d/claim"; dead_pid > "$d/claim/pid"
  expect_one "round $r: officer lock_acquire taking over a dead owner" "$(race "$d" lock_acquire)"
done
mkdir -p "$TMP_ROOT/officer-live"; printf '%s\n' "$$" > "$TMP_ROOT/officer-live/pid"
lock_acquire "$TMP_ROOT/officer-live" && fail "officer lock_acquire took over a lock held by a live pid"
[ "$(cat "$TMP_ROOT/officer-live/pid")" = "$$" ] || fail "officer lock_acquire disturbed a live lock"

# Pollers (busy-event, launcher) spawn a process per retry, so they run fewer rounds.
POLL_ROUNDS=3
# Busy-state writer lock (fm-busy-event.sh).
(
  load_fn fm-busy-event.sh lock_acquire
  load_fn fm-busy-event.sh lock_is_stale
  jitter_after lock_is_stale
  lock_mtime() { mtime_of "$1"; }
  ID=race
  export FM_BUSY_LOCK_STALE_SECS=60
  busy_claim() { LOCK=$1; lock_acquire; }
  for r in $(seq 1 "$POLL_ROUNDS"); do
    d=$TMP_ROOT/busy.$r; start_racers "$d" busy_claim
    expect_one "round $r: busy-event lock_acquire" "$(stop_racers "$d" 1)"
  done
  fm_atomic_mkdir() { stub_claim_always "$1"; }
  d=$TMP_ROOT/busy.control; start_racers "$d" busy_claim
  expect_many "busy-event lock_acquire" "$(stop_racers "$d" 1)"
  # shellcheck source=bin/fm-atomic-lib.sh
  . "$ROOT/bin/fm-atomic-lib.sh"
  for r in $(seq 1 "$POLL_ROUNDS"); do
    d=$TMP_ROOT/busy-stale.$r; mkdir -p "$d/claim"; touch -t 200001010000 "$d/claim"
    start_racers "$d" busy_claim
    expect_one "round $r: busy-event lock_acquire taking over a stale lock" "$(stop_racers "$d" 1)"
  done
) || exit 1

# Away-mode launcher lock (fm-afk-launch.sh).
(
  FM_STATE_OVERRIDE=$TMP_ROOT/afk-state; FM_ROOT_OVERRIDE=$ROOT
  mkdir -p "$FM_STATE_OVERRIDE"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  for fn in fm_afk_launch_log fm_afk_launch_lock_owned fm_afk_launch_lock_unowned fm_afk_launch_lock_acquire; do
    load_fn fm-afk-launch.sh "$fn"
  done
  FM_AFK_LAUNCH_STATE=$TMP_ROOT/afk-state
  # A claim still being written (pid but no pid-identity yet) is never taken
  # over; the same lock left that way for over a second is; and a lock that
  # changed since the caller looked is not.
  d=$TMP_ROOT/afk-partial; mkdir -p "$d"; p=$(dead_pid); printf '%s' "$p" > "$d/pid"
  fm_atomic_takeover "$d" fm_afk_launch_lock_unowned "$p" "" && fail "afk takeover removed a claim still being written"
  [ "$(cat "$d/pid" 2>/dev/null)" = "$p" ] || fail "a refused afk takeover disturbed the claim being written"
  touch -t 200001010000 "$d"
  fm_atomic_takeover "$d" fm_afk_launch_lock_unowned "$p" "" || fail "afk takeover did not remove an old incomplete lock"
  d=$TMP_ROOT/afk-changed; mkdir -p "$d"; p=$(dead_pid); printf '%s' "$p" > "$d/pid"; printf 'no-such-identity' > "$d/pid-identity"
  fm_atomic_takeover "$d" fm_afk_launch_lock_unowned "$(dead_pid)" "other-identity" && fail "afk takeover removed a lock that changed since it was seen"
  fm_atomic_takeover "$d" fm_afk_launch_lock_unowned "$p" "no-such-identity" || fail "afk takeover did not remove a dead owner's lock"
  jitter_after fm_afk_launch_lock_unowned
  afk_claim() { FM_AFK_LAUNCH_LOCK=$1; fm_afk_launch_lock_acquire; }
  for r in $(seq 1 "$POLL_ROUNDS"); do
    d=$TMP_ROOT/afk.$r; start_racers "$d" afk_claim
    expect_one "round $r: fm_afk_launch_lock_acquire" "$(stop_racers "$d" 1)"
  done
  fm_atomic_mkdir() { stub_claim_always "$1"; }
  d=$TMP_ROOT/afk.control; start_racers "$d" afk_claim
  expect_many "fm_afk_launch_lock_acquire" "$(stop_racers "$d" 1)"
  # shellcheck source=bin/fm-atomic-lib.sh
  . "$ROOT/bin/fm-atomic-lib.sh"
  for r in $(seq 1 "$POLL_ROUNDS"); do
    d=$TMP_ROOT/afk-stale.$r; mkdir -p "$d/claim"
    dead_pid > "$d/claim/pid"; printf 'no-such-identity' > "$d/claim/pid-identity"
    start_racers "$d" afk_claim
    expect_one "round $r: fm_afk_launch_lock_acquire taking over a dead owner" "$(stop_racers "$d" 1)"
  done
) || exit 1

# Per-task temp root claim in fm-spawn.sh.
(
  load_fn fm-spawn.sh spawn_claim_task_tmp
  HARNESS=polytoken
  spawn_claim() { TASK_TMP=$1; SPAWN_TASK_TMP_CREATED=0; spawn_claim_task_tmp && [ "$SPAWN_TASK_TMP_CREATED" = 1 ]; }
  for r in $(seq 1 "$ROUNDS"); do
    expect_one "round $r: spawn_claim_task_tmp" "$(race "$TMP_ROOT/spawn.$r" spawn_claim)"
  done
  [ "$(stat -c %a "$TMP_ROOT/spawn.1/claim" 2>/dev/null || stat -f %Lp "$TMP_ROOT/spawn.1/claim")" = 700 ] \
    || fail "spawn task temp root is not mode 0700"
  fm_atomic_mkdir() { stub_claim_always "$1"; }
  expect_many "spawn_claim_task_tmp" "$(race "$TMP_ROOT/spawn.control" spawn_claim)"
) || exit 1

# Remote job worker lock taken over from a dead owner (fm-remote-job-worker.sh).
jitter_after worker_lock_is_stale
for r in $(seq 1 3); do
  rm -rf "$WORKER_LOCK"
  mkdir -p "$WORKER_LOCK"
  dead_pid > "$WORKER_LOCK/pid"; echo start > "$WORKER_LOCK/start"; echo command > "$WORKER_LOCK/command"
  touch -t 200001010000 "$WORKER_LOCK"
  rm -f -- "$(fm_remote_job_worker_ready_path)"
  d=$TMP_ROOT/worker-stale.$r; mkdir -p "$d/out"
  for i in $(seq 1 "$N"); do
    ( if worker_acquire_lock "$TMP_ROOT/account" "identity-$i"; then : > "$d/out/win.$i"; sleep 2; fi ) &
  done
  wait
  expect_one "round $r: worker_acquire_lock taking over a dead owner" "$(find "$d/out" -name 'win.*' | wc -l | tr -d ' ')"
done

# The session lock and the startup-network lock both take fm-wake-lib.sh's
# fm_lock_try_acquire (a symlink claim with a steal mutex, no mkdir): exactly one
# racer owns a fresh lock and exactly one takes over a dead owner's.
(
  FM_STATE_OVERRIDE=$TMP_ROOT/session-state; FM_ROOT_OVERRIDE=$ROOT
  mkdir -p "$FM_STATE_OVERRIDE"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  # The winner records itself and keeps the lock until it is stopped.
  session_claim() { fm_lock_try_acquire "$1" || return 1; : > "${1%/claim}/out/win.${BASHPID:-$$}"; sleep 30; return 1; }
  for r in $(seq 1 "$POLL_ROUNDS"); do
    d=$TMP_ROOT/session.$r; start_racers "$d" session_claim
    expect_one "round $r: session claim lock" "$(stop_racers "$d" 1)"
  done
  for r in $(seq 1 "$POLL_ROUNDS"); do
    d=$TMP_ROOT/session-stale.$r; mkdir -p "$d"
    # A process that takes the lock and exits without releasing it leaves a dead owner.
    bash -c '. "$1"; fm_lock_try_acquire "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$d/claim" || fail "could not leave a dead session claim owner"
    [ -L "$d/claim" ] || [ -d "$d/claim" ] || fail "the dead session claim owner left no lock"
    start_racers "$d" session_claim
    expect_one "round $r: session claim lock taking over a dead owner" "$(stop_racers "$d" 1.5)"
  done
) || exit 1

# Contract: mode 0700, existing dir loses, bad parent fails, bad usage fails.
( umask 022; fm_atomic_mkdir "$TMP_ROOT/mode" ) || fail "fresh claim failed"
[ "$(stat -c %a "$TMP_ROOT/mode" 2>/dev/null || stat -f %Lp "$TMP_ROOT/mode")" = 700 ] || fail "claim is not mode 0700"
fm_atomic_mkdir "$TMP_ROOT/mode" 2>/dev/null && fail "claim of an existing directory succeeded"
fm_atomic_mkdir "$TMP_ROOT/no/such/parent" 2>/dev/null && fail "claim under a missing parent succeeded"
fm_atomic_mkdir 2>/dev/null && fail "claim with no argument succeeded"
echo "PASS: fm-atomic-mkdir"
