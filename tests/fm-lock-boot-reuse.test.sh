#!/usr/bin/env bash
# tests/fm-lock-boot-reuse.test.sh - bin/fm-lock.sh when the recorded lock pid
# was recorded before a reboot and the number now belongs to another process.
#
# Each case runs the real fm-lock.sh inside a fixture home as a child of a fake
# harness (a bash symlink named "claude"), orphaned before it runs so the
# ancestry walk ends inside the fixture. A second fake harness outside that
# ancestry stands for the unrelated live process that took over the recorded
# pid. The boot identity is pinned through FM_BOOT_ID_OVERRIDE, the seam
# bin/fm-session-lock-lib.sh exposes for tests.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-boot-reuse)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

# A ps that gives no answer about FM_TEST_UNREADABLE_PID and defers to the real
# ps for every other pid, so that one live pid gets the unreadable verdict.
REAL_PS=$(command -v ps) || { echo "FAIL: no ps on PATH" >&2; exit 1; }
PSBIN="$TMP_ROOT/psbin"
mkdir -p "$PSBIN"
cat > "$PSBIN/ps" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  [ "\$a" = "\${FM_TEST_UNREADABLE_PID:-}" ] && exit 2
done
exec "$REAL_PS" "\$@"
SH
chmod +x "$PSBIN/ps"

HOLDER_PIDS=
reap_holders() {
  local pid
  for pid in $HOLDER_PIDS; do
    kill "$pid" 2>/dev/null || true
  done
}
trap 'reap_holders; fm_test_cleanup' EXIT

BOOT_OLD="boot-before-reboot"
BOOT_NEW="boot-after-reboot"

make_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp -R "$ROOT/bin" "$dir/bin"
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
CLAUDE_PID=$$ "$FM_HOME/bin/fm-lock.sh" status > "$FM_HOME/state/status.out" 2>&1
CLAUDE_PID=$$ "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/lock.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/lock.rc"
exit 0
SH
  cat > "$dir/holder.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/holder-pid"
while [ ! -e "$FM_HOME/state/stop-holder" ]; do sleep 0.1; done
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/holder.sh"
}

wait_for_file() {  # <path> <what>
  local i=0
  while [ "$i" -lt 400 ] && [ ! -s "$1" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$1" ] || fail "fixture never produced $2"
}

# Start the unrelated live harness that now owns the recorded pid; prints its pid.
start_holder() {  # <dir>
  local dir=$1
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$dir" \
    bash -c '"$0" "$1" >/dev/null 2>&1 &' "$FAKE_CLAUDE" "$dir/holder.sh"
  wait_for_file "$dir/state/holder-pid" "the holder pid"
  tr -d '[:space:]' < "$dir/state/holder-pid"
}

# Run status then acquire as <session-id> (empty for none) under boot <boot>,
# with ps unable to read pid <unreadable-pid> when one is given.
run_session() {  # <dir> <session-id> <boot> [unreadable-pid]
  local dir=$1 sid=$2 boot=$3 unreadable=${4:-}
  local -a idenv=()
  [ -z "$sid" ] || idenv+=("CLAUDE_CODE_SESSION_ID=$sid")
  [ -z "$unreadable" ] || idenv+=("PATH=$PSBIN:$PATH" "FM_TEST_UNREADABLE_PID=$unreadable")
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID ${idenv[@]+"${idenv[@]}"} \
    FM_HOME="$dir" FM_BOOT_ID_OVERRIDE="$boot" \
    bash -c '"$0" "$1" &' "$FAKE_CLAUDE" "$dir/session.sh"
  wait_for_file "$dir/state/lock.rc" "the lock exit code"
}

lock_rc() { tr -d '[:space:]' < "$1/state/lock.rc"; }
lock_line1() { head -n 1 "$1/state/.lock" | tr -d '[:space:]'; }

# A home whose lock names a live foreign harness, recorded for session
# <recorded-sid> under boot <recorded-boot> (empty boot writes no boot record).
make_taken_home() {  # <dir> <recorded-sid> <recorded-boot>
  local dir=$1 holder
  make_home "$dir"
  holder=$(start_holder "$dir")
  HOLDER_PIDS="$HOLDER_PIDS $holder"
  printf '%s\n' "$holder" > "$dir/state/.lock"
  [ -z "$2" ] || printf '%s\n' "$2" > "$dir/state/.lock-session"
  [ -z "$3" ] || printf '%s\n' "$3" > "$dir/state/.lock-boot"
}

test_same_session_reclaims_a_pid_reused_after_reboot() {
  local dir=$TMP_ROOT/same-session-reboot holder session
  make_taken_home "$dir" de6f5348 "$BOOT_OLD"
  holder=$(lock_line1 "$dir")
  run_session "$dir" de6f5348 "$BOOT_NEW"
  expect_code 0 "$(lock_rc "$dir")" "the restarted session must reclaim its own lock: $(cat "$dir/state/lock.out")"
  session=$(tr -d '[:space:]' < "$dir/state/session-pid")
  [ "$(lock_line1 "$dir")" = "$session" ] || fail "line 1 is $(lock_line1 "$dir"), expected the restarted session pid $session"
  [ "$(lock_line1 "$dir")" != "$holder" ] || fail "line 1 still names the reused pid"
  [ "$(cat "$dir/state/.lock-boot")" = "$BOOT_NEW" ] || fail "the current boot was not recorded beside the lock"
  kill -0 "$holder" 2>/dev/null || fail "the unrelated live process was disturbed"
  pass "fm-lock: a same-session restart reclaims a lock whose pid was reused after a reboot"
}

test_status_reports_stale_for_a_pid_from_an_earlier_boot() {
  local dir=$TMP_ROOT/status-reboot
  make_taken_home "$dir" de6f5348 "$BOOT_OLD"
  run_session "$dir" de6f5348 "$BOOT_NEW"
  assert_contains "$(cat "$dir/state/status.out")" "lock: stale" "status must call a lock from an earlier boot stale"
  pass "fm-lock: status calls a lock recorded before the current boot stale"
}

test_a_different_session_also_reclaims_after_reboot() {
  local dir=$TMP_ROOT/other-session-reboot
  make_taken_home "$dir" other-session "$BOOT_OLD"
  run_session "$dir" new-session "$BOOT_NEW"
  expect_code 0 "$(lock_rc "$dir")" "a pid from an earlier boot is no owner for any session: $(cat "$dir/state/lock.out")"
  pass "fm-lock: a lock from an earlier boot is reclaimable by any session"
}

test_different_live_session_in_the_same_boot_is_refused() {
  local dir=$TMP_ROOT/other-session-same-boot holder
  make_taken_home "$dir" other-session "$BOOT_NEW"
  holder=$(lock_line1 "$dir")
  run_session "$dir" new-session "$BOOT_NEW"
  expect_code 1 "$(lock_rc "$dir")" "a different live session must still be refused"
  assert_contains "$(cat "$dir/state/lock.out")" "another live firstmate session holds the lock" "refusal message"
  [ "$(lock_line1 "$dir")" = "$holder" ] || fail "a refused acquisition rewrote line 1"
  assert_contains "$(cat "$dir/state/status.out")" "lock: held" "status must agree with the refusal"
  pass "fm-lock: a different live session in the same boot is refused and status says held"
}

test_same_session_same_boot_still_reanchors() {
  local dir=$TMP_ROOT/same-session-same-boot session
  make_taken_home "$dir" de6f5348 "$BOOT_NEW"
  run_session "$dir" de6f5348 "$BOOT_NEW"
  expect_code 0 "$(lock_rc "$dir")" "the trusted-id re-anchor must keep working: $(cat "$dir/state/lock.out")"
  session=$(tr -d '[:space:]' < "$dir/state/session-pid")
  [ "$(lock_line1 "$dir")" = "$session" ] || fail "line 1 is $(lock_line1 "$dir"), expected the re-anchored pid $session"
  pass "fm-lock: the same-session re-anchor still works within one boot"
}

test_legacy_lock_without_a_boot_record_behaves_as_before() {
  local dir
  dir=$TMP_ROOT/legacy-foreign
  make_taken_home "$dir" other-session ""
  run_session "$dir" new-session "$BOOT_NEW"
  expect_code 1 "$(lock_rc "$dir")" "a legacy lock held by a live foreign session must still be refused"
  assert_contains "$(cat "$dir/state/status.out")" "lock: held" "legacy status"

  dir=$TMP_ROOT/legacy-same-session
  make_taken_home "$dir" de6f5348 ""
  run_session "$dir" de6f5348 "$BOOT_NEW"
  expect_code 0 "$(lock_rc "$dir")" "a legacy lock of the same session must still re-anchor: $(cat "$dir/state/lock.out")"
  [ "$(cat "$dir/state/.lock-boot")" = "$BOOT_NEW" ] || fail "the first acquisition after the change must record the boot"

  dir=$TMP_ROOT/legacy-dead
  make_home "$dir"
  printf '999999\n' > "$dir/state/.lock"
  run_session "$dir" new-session "$BOOT_NEW"
  expect_code 0 "$(lock_rc "$dir")" "a legacy dead pid must still be reclaimed: $(cat "$dir/state/lock.out")"
  pass "fm-lock: a lock with no boot record behaves exactly as before"
}

# The reported sequence: line 1 names a pid that a live process outside the
# session's ancestry took over, and that process's identity cannot be read.
# Within one boot (or with no boot record) acquisition must refuse such an
# owner and status must say so rather than call it stale; once the record
# names an earlier boot, the same session reclaims it.
test_unreadable_reused_pid_is_refused_in_one_boot_and_reclaimed_after_reboot() {
  local dir holder session
  dir=$TMP_ROOT/unreadable-same-boot
  make_taken_home "$dir" de6f5348 "$BOOT_NEW"
  holder=$(lock_line1 "$dir")
  run_session "$dir" de6f5348 "$BOOT_NEW" "$holder"
  expect_code 1 "$(lock_rc "$dir")" "a live owner with an unreadable identity must be refused within one boot"
  assert_contains "$(cat "$dir/state/lock.out")" "another live firstmate session holds the lock" "refusal message"
  [ "$(lock_line1 "$dir")" = "$holder" ] || fail "a refused acquisition rewrote line 1"
  assert_contains "$(cat "$dir/state/status.out")" "lock: held by live pid $holder (identity unreadable)" "status must agree with the refusal"

  dir=$TMP_ROOT/unreadable-legacy
  make_taken_home "$dir" de6f5348 ""
  holder=$(lock_line1 "$dir")
  run_session "$dir" de6f5348 "$BOOT_NEW" "$holder"
  expect_code 1 "$(lock_rc "$dir")" "a legacy lock whose live owner is unreadable must still be refused"
  assert_contains "$(cat "$dir/state/status.out")" "lock: held by live pid $holder (identity unreadable)" "legacy status must agree with the refusal"

  dir=$TMP_ROOT/unreadable-after-reboot
  make_taken_home "$dir" de6f5348 "$BOOT_OLD"
  holder=$(lock_line1 "$dir")
  run_session "$dir" de6f5348 "$BOOT_NEW" "$holder"
  expect_code 0 "$(lock_rc "$dir")" "the restarted session must reclaim a pid from an earlier boot even when its identity is unreadable: $(cat "$dir/state/lock.out")"
  session=$(tr -d '[:space:]' < "$dir/state/session-pid")
  [ "$(lock_line1 "$dir")" = "$session" ] || fail "line 1 is $(lock_line1 "$dir"), expected the restarted session pid $session"
  assert_contains "$(cat "$dir/state/status.out")" "lock: stale" "status must call a pid from an earlier boot stale"
  kill -0 "$holder" 2>/dev/null || fail "the unrelated live process was disturbed"
  pass "fm-lock: an unreadable reused pid is refused within one boot and reclaimed after a reboot"
}

test_same_session_reclaims_a_pid_reused_after_reboot
test_unreadable_reused_pid_is_refused_in_one_boot_and_reclaimed_after_reboot
test_status_reports_stale_for_a_pid_from_an_earlier_boot
test_a_different_session_also_reclaims_after_reboot
test_different_live_session_in_the_same_boot_is_refused
test_same_session_same_boot_still_reanchors
test_legacy_lock_without_a_boot_record_behaves_as_before

echo "ALL PASS"
