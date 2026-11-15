#!/usr/bin/env bash
# tests/fm-external-wait-recheck.test.sh - bin/fm-external-wait-recheck.sh
# re-checks declared external waits read-only: it parses the dependency a paused
# or blocked [cause=external] line names, reports a cleared dependency once, an
# overdue recovery time once, and counts repeat waits per dependency; the
# watcher wakes on each new finding once. Fake ssh, curl and gh on PATH answer
# from per-name files, so a dependency with no "up" file is unreachable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-external-wait-recheck-tests)
RECHECK="$ROOT/bin/fm-external-wait-recheck.sh"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
UP="$TMP_ROOT/up"
mkdir -p "$UP"
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$FAKE_UP/.calls"
host=''
for a in "$@"; do host=$a; done
[ "$host" = true ] && host=${*: -2:1}
[ -f "$FAKE_UP/ssh_$host" ]
SH
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$FAKE_UP/.calls"
url=${*: -1}
[ -f "$FAKE_UP/$(printf '%s' "$url" | tr '/:' '__')" ]
SH
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$FAKE_UP/.calls"
f="$FAKE_UP/$(printf '%s' "$3" | tr '/:' '__')"
[ -f "$f" ] || exit 1
cat "$f"
SH
chmod +x "$FAKEBIN/ssh" "$FAKEBIN/curl" "$FAKEBIN/gh"
export FAKE_UP="$UP"
export PATH="$FAKEBIN:$PATH"

up() { : > "$UP/$1"; }
calls() { cat "$UP/.calls" 2>/dev/null || true; }

PAST=$(date -u -d '@1000000000' +%Y-%m-%dT%H:%MZ)
FUTURE=2099-01-01T00:00Z

# A fresh home with one status file per "<task>" heredoc given as name and lines on stdin.
mkhome() {  # <name>
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state"
  printf '%s' "$h"
}
addlog() {  # <home> <task> -> lines on stdin
  cat > "$1/state/$2.status"
}
recheck() { FM_HOME=$1 bash "$RECHECK" "${@:2}"; }

test_declaration_parse() {
  local line
  line="paused [at=1790000001] [cause=external] [dep=ssh/slartibartfast]: slartibartfast unreachable, expected back soon; until $FUTURE"
  assert_equals external "$(status_line_cause "$line")" "the external cause tag is read"
  assert_equals ssh/slartibartfast "$(status_line_dep "$line")" "an ssh dependency is read from the paused line"
  assert_equals https/api.example.org/health "$(status_line_dep "blocked [at=1790000001] [cause=external] [dep=https/api.example.org/health]: down")" \
    "an https dependency with a path is read from a blocked line"
  assert_equals task/other-task "$(status_line_dep "paused [dep=task/other-task]: waiting")" "a task dependency is read"
  pass "the structured external-wait declaration parses and older lines stay valid"
}

test_cleared_once() {
  local h out
  h=$(mkhome cleared)
  addlog "$h" t <<EOF
working [at=1790000000]: started
paused [at=1790000001] [cause=external] [dep=ssh/hostA]: hostA unreachable, expected back soon; until $FUTURE
EOF
  out=$(recheck "$h" --apply)
  assert_contains "$out" "file=t.status dep=ssh/hostA verdict=waiting new=0" "a dependency that is down stays a wait"
  up ssh_hostA
  out=$(recheck "$h")
  assert_contains "$out" "file=t.status dep=ssh/hostA verdict=cleared new=1" "dry run reports the cleared dependency as new"
  assert_equals "" "$(cat "$h/state/.external-wait-recheck.seen" 2>/dev/null)" "dry run records nothing"
  out=$(recheck "$h" --apply)
  assert_contains "$out" "verdict=cleared new=1" "the first applying run reports it as new"
  out=$(recheck "$h" --apply)
  assert_contains "$out" "verdict=cleared new=0" "the second run does not report it as new again"
  assert_contains "$(calls)" "ssh -o BatchMode=yes -o ConnectTimeout=5 -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o StrictHostKeyChecking=yes -- hostA true" \
    "the re-check is the bounded read-only ssh probe with no forwarding or unknown host keys"
  pass "a cleared dependency is reported new exactly once"
}

test_flapping_dependency_wakes_once() {
  local h out
  h=$(mkhome flap)
  addlog "$h" t <<EOF
paused [at=1790000001] [cause=external] [dep=ssh/hostF]: hostF unreachable; until $FUTURE
EOF
  up ssh_hostF
  out=$(recheck "$h" --apply)
  assert_contains "$out" "dep=ssh/hostF verdict=cleared new=1" "the first clear is new"
  rm -f "$UP/ssh_hostF"
  out=$(recheck "$h" --apply)
  assert_contains "$out" "dep=ssh/hostF verdict=waiting new=0" "a brief failure turns the verdict back to waiting"
  up ssh_hostF
  out=$(recheck "$h" --apply)
  assert_contains "$out" "dep=ssh/hostF verdict=cleared new=0" "clearing again on the same wait line is not new"
  printf 'paused [at=1790000009] [cause=external] [dep=ssh/hostF]: hostF unreachable again; until %s\n' "$FUTURE" >> "$h/state/t.status"
  out=$(recheck "$h" --apply)
  assert_contains "$out" "dep=ssh/hostF verdict=cleared new=1" "a new wait line on the same dependency is new"
  assert_equals 1 "$(wc -l < "$h/state/.external-wait-recheck.seen" | tr -d ' ')" "the marker of the replaced wait line is pruned"
  pass "a flapping dependency is reported once per wait line"
}

test_pass_cap_and_cache() {
  local h out i
  h=$(mkhome cap)
  for i in 01 02 03 04 05 06 07 08 09 10 11 12 13; do
    addlog "$h" "t$i" <<EOF
paused [at=1790000001] [cause=external] [dep=ssh/cap$i]: cap$i unreachable
EOF
  done
  addlog "$h" t00 <<EOF
paused [at=1790000001] [cause=external] [dep=ssh/cap01]: cap01 unreachable too
EOF
  : > "$UP/.calls"
  out=$(recheck "$h")
  assert_equals 12 "$(grep -c '^ssh ' "$UP/.calls")" "a pass runs at most twelve probes, and two waits on one host share a probe"
  assert_contains "$out" "file=t13.status dep=ssh/cap13 verdict=unchecked new=0 detail=pass cap reached" "the dependency past the cap is unchecked"
  assert_contains "$out" "waits=14 cleared=0 overdue=0 waiting=13 unchecked=1" "the totals count the capped wait"
  pass "a pass is capped and probes each dependency once"
}

test_overdue_once() {
  local h out
  h=$(mkhome overdue)
  addlog "$h" a <<EOF
paused [at=1790000001] [cause=external] [dep=ssh/hostB]: hostB unreachable; until $PAST
EOF
  addlog "$h" b <<EOF
paused [at=1790000001] [cause=external]: vendor portal down, no re-check; until $PAST
EOF
  addlog "$h" c <<EOF
paused [at=1790000001] [cause=external]: vendor portal down, no re-check; until $FUTURE
EOF
  addlog "$h" d <<EOF
paused [at=1790000001] [cause=external] [dep=billing/acct]: unknown kind, no time
EOF
  out=$(recheck "$h" --apply)
  assert_contains "$out" "file=a.status dep=ssh/hostB verdict=overdue new=1" "a down dependency past its time is overdue"
  assert_contains "$out" "file=b.status dep=none verdict=overdue new=1" "a wait with no re-check is overdue once its time passes"
  assert_contains "$out" "file=c.status dep=none verdict=waiting new=0" "a wait before its time is still waiting"
  assert_contains "$out" "file=d.status dep=billing/acct verdict=waiting new=0" "an unknown dependency kind with no time is never re-checked or overdue"
  out=$(recheck "$h" --apply)
  assert_contains "$out" "file=a.status dep=ssh/hostB verdict=overdue new=0" "an overdue wait is reported once"
  assert_contains "$out" "file=b.status dep=none verdict=overdue new=0" "an undated-check overdue wait is reported once"
  up ssh_hostB
  out=$(recheck "$h" --apply)
  assert_contains "$out" "file=a.status dep=ssh/hostB verdict=cleared new=1" "a dependency that clears after its time is a new cleared finding"
  pass "an overdue wait is reported once, with or without a re-check"
}

test_dependency_kinds() {
  local h out
  h=$(mkhome kinds)
  addlog "$h" web <<EOF
paused [at=1790000001] [cause=external] [dep=https/api.example.org/health]: api down
EOF
  addlog "$h" pr <<EOF
paused [at=1790000001] [cause=external] [dep=pr/o/r/5]: waiting for the other owner
EOF
  addlog "$h" prblock <<EOF
blocked [at=1790000001] [cause=external] [key=wait-6] [dep=pr/o/r/6]: waiting for the other owner
EOF
  addlog "$h" waiter <<EOF
paused [at=1790000001] [cause=external] [dep=task/finisher]: waiting for the other task
EOF
  addlog "$h" finisher <<EOF
working [at=1790000001]: busy
EOF
  : > "$UP/.calls"
  out=$(recheck "$h")
  assert_contains "$out" "file=web.status dep=https/api.example.org/health verdict=waiting" "an http dependency that does not answer waits"
  assert_contains "$out" "file=pr.status dep=pr/o/r/5 verdict=waiting" "an open pull request waits"
  assert_contains "$out" "file=waiter.status dep=task/finisher verdict=waiting" "a task that is not done waits"
  assert_contains "$out" "file=prblock.status dep=pr/o/r/6 verdict=waiting new=0 detail=pull request wait on a decision" "a blocked pull request wait is left to the decision sweep"
  assert_not_contains "$(calls)" "pr/o/r/6" "no forge read for a blocked pull request wait"
  up https___api.example.org_health
  printf 'MERGED' > "$UP/https___github.com_o_r_pull_5"
  printf 'done [at=1790000009]: finished\n' >> "$h/state/finisher.status"
  out=$(recheck "$h")
  assert_contains "$out" "file=web.status dep=https/api.example.org/health verdict=cleared" "an http dependency that answers clears"
  assert_contains "$out" "file=pr.status dep=pr/o/r/5 verdict=cleared" "a merged pull request clears the pause"
  assert_contains "$out" "file=waiter.status dep=task/finisher verdict=cleared" "a task that is done clears"
  assert_contains "$(calls)" "curl -fsS --max-time 15 --max-redirs 0 -o /dev/null -- https://api.example.org/health" "the http re-check is a bounded GET"
  pass "ssh, https, pull request and task dependencies are re-checked read-only"
}

test_https_refuses_internal_hosts() {
  local h out host n
  h=$(mkhome internal)
  n=0
  for host in 169.254.169.254 127.0.0.1 localhost metadata api.localhost 10.0.0.1 0x7f.0.0.1 example.org.; do
    n=$((n + 1))
    addlog "$h" "h$n" <<EOF
paused [at=1790000001] [cause=external] [dep=https/$host/latest]: down
EOF
  done
  : > "$UP/.calls"
  out=$(recheck "$h")
  assert_equals "" "$(calls)" "no request is made to an IP, localhost or single-label host"
  assert_equals "$n" "$(grep -c 'detail=not a public DNS name' <<<"$out")" "each internal host is refused"
  pass "an https dependency must be a dotted public DNS name"
}

test_hostile_names_are_never_run() {
  local h out
  h=$(mkhome hostile)
  addlog "$h" t <<EOF
paused [at=1790000001] [cause=external] [dep=ssh/-oProxyCommand=x]: down
EOF
  : > "$UP/.calls"
  out=$(recheck "$h")
  assert_contains "$out" "verdict=waiting" "a dependency beginning with a dash is a plain wait"
  assert_equals "" "$(calls)" "nothing was run for a malformed dependency"
  pass "a malformed dependency name is never run"
}

test_resolved_wait_is_not_rechecked() {
  local h out
  h=$(mkhome resolved)
  addlog "$h" t <<EOF
paused [at=1790000001] [cause=external] [dep=ssh/hostC]: hostC unreachable; until $PAST
resolved [at=1790000002]: hostC is back
EOF
  out=$(recheck "$h" --apply)
  assert_contains "$out" "waits=0" "a resolved wait is no longer a wait"
  pass "a resolved wait is left alone"
}

test_repeat_count() {
  local h out
  h=$(mkhome repeat)
  addlog "$h" one <<EOF
paused [at=1790000001] [cause=external] [dep=ssh/flaky]: flaky unreachable
paused [at=1790000001] [cause=external] [dep=ssh/flaky]: flaky unreachable
resolved [at=1790000002]: back
EOF
  addlog "$h" two <<EOF
blocked [at=1790000003] [cause=external] [dep=ssh/flaky]: flaky unreachable again
EOF
  out=$(recheck "$h" --apply)
  assert_not_contains "$out" "repeat dep=" "two declarations are below the threshold (identical lines count once)"
  addlog "$h" three <<EOF
paused [at=1790000004] [cause=external] [dep=ssh/flaky]: flaky unreachable a third time
paused [at=1790000005] [cause=external] [dep=ssh/steady]: steady unreachable once
EOF
  out=$(recheck "$h" --apply)
  assert_contains "$out" "repeat dep=ssh/flaky count=3 tasks=one,three,two new=1" "the third declaration names the dependency once, with its tasks"
  assert_not_contains "$out" "repeat dep=ssh/steady" "a dependency named once is not a repeat"
  out=$(recheck "$h" --apply)
  assert_contains "$out" "repeat dep=ssh/flaky count=3 tasks=one,three,two new=0" "the same count is not reported again"
  addlog "$h" four <<EOF
paused [at=1790000006] [cause=external] [dep=ssh/flaky]: flaky unreachable a fourth time
EOF
  out=$(recheck "$h" --apply)
  assert_contains "$out" "repeat dep=ssh/flaky count=4 tasks=four,one,three,two new=1" "a grown count is reported again"
  assert_contains "$out" "repeats=1" "totals count the repeat dependency"
  pass "repeat waits are counted per dependency and reported when the count grows"
}

test_fan_in_is_not_a_repeat() {
  local h out t
  h=$(mkhome fanin)
  for t in a b c; do
    addlog "$h" "$t" <<EOF
paused [at=1790000001] [cause=external] [dep=task/build-x]: waiting on build-x
blocked [at=1790000002] [cause=external] [dep=pr/o/r/5]: waiting on the other owner's merge
EOF
  done
  out=$(recheck "$h")
  assert_not_contains "$out" "repeat dep=" "several tasks waiting on one task or pull request are not a repeat outage"
  assert_contains "$out" "repeats=0" "no repeat is counted for fan-in waits"
  pass "fan-in waits on a task or pull request are never repeats"
}

test_custom_paused_verb_counts_repeats() {
  local h out t
  h=$(mkhome verb)
  for t in a b c; do
    addlog "$h" "$t" <<EOF
waiting-on [at=1790000001] [cause=external] [dep=ssh/hostV]: hostV unreachable ($t)
EOF
  done
  out=$(FM_CLASSIFY_PAUSED_VERB=waiting-on recheck "$h")
  assert_contains "$out" "repeat dep=ssh/hostV count=3 tasks=a,b,c" "a home's own paused verb counts toward repeats"
  pass "the repeat count honours FM_CLASSIFY_PAUSED_VERB"
}

test_status_logs_are_never_written() {
  local h before
  h=$(mkhome readonly)
  addlog "$h" t <<EOF
paused [at=1790000001] [cause=external] [dep=ssh/hostD]: hostD unreachable; until $PAST
EOF
  up ssh_hostD
  before=$(cksum < "$h/state/t.status")
  recheck "$h" --apply > /dev/null
  assert_equals "$before" "$(cksum < "$h/state/t.status")" "the re-check never appends to a task's status log"
  pass "the sweep is read-only toward status logs"
}

start_watcher() {  # <home> [env-assignment...]
  fm_test_track_watcher_state "$1/state"
  env FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_DECISION_SWEEP_INTERVAL_SECS=0 "${@:2}" "$ROOT/bin/fm-watch.sh" >>"$1/wake.out" 2>/dev/null &
  printf '%s\n' "$!" > "$1/watch.pid"
}
rearm_watcher() {  # <home> [env-assignment...]
  ! kill -0 "$(cat "$1/watch.pid")" 2>/dev/null || return 0
  start_watcher "$@"
}
stop_watcher() {  # <home>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
}

test_watcher_wakes_once_on_clear() {
  local on off i count
  on=$(mkhome watch-on)
  off=$(mkhome watch-off)
  addlog "$on" t <<EOF
paused [at=1790000001] [cause=external] [dep=ssh/hostW]: hostW unreachable; until $FUTURE
EOF
  addlog "$off" t <<EOF
paused [at=1790000001] [cause=external] [dep=ssh/hostW]: hostW unreachable; until $FUTURE
EOF
  mkdir -p "$on/config" "$off/config"
  up ssh_hostW
  start_watcher "$on" FM_EXTERNAL_WAIT_RECHECK_INTERVAL_SECS=1
  start_watcher "$off" FM_EXTERNAL_WAIT_RECHECK_INTERVAL_SECS=0
  i=0
  while [ "$i" -lt 200 ] && ! grep -qs 'check: external-wait' "$on/wake.out"; do
    rearm_watcher "$on" FM_EXTERNAL_WAIT_RECHECK_INTERVAL_SECS=1
    rearm_watcher "$off" FM_EXTERNAL_WAIT_RECHECK_INTERVAL_SECS=0
    sleep 0.1
    i=$((i + 1))
  done
  # Keep the watcher cycling past more sweeps: the finding must not wake again.
  i=0
  while [ "$i" -lt 40 ]; do
    rearm_watcher "$on" FM_EXTERNAL_WAIT_RECHECK_INTERVAL_SECS=1
    sleep 0.1
    i=$((i + 1))
  done
  stop_watcher "$on"
  stop_watcher "$off"
  count=$(grep -c 'check: external-wait: cleared: file=t.status dep=ssh/hostW' "$on/wake.out" || true)
  assert_equals 1 "$count" "the watcher woke firstmate exactly once when the dependency cleared"
  assert_no_grep 'check: external-wait' "$off/wake.out" "a zero cadence wakes nothing"
  pass "the watcher wakes once when a declared dependency clears"
}

test_watcher_wakes_once_on_overdue_and_repeat() {
  local h i t
  h=$(mkhome watch-overdue)
  for t in a b c; do
    addlog "$h" "$t" <<EOF
paused [at=1790000001] [cause=external] [dep=ssh/hostO]: hostO unreachable; until $PAST
EOF
  done
  mkdir -p "$h/config"
  start_watcher "$h" FM_EXTERNAL_WAIT_RECHECK_INTERVAL_SECS=1
  i=0
  while [ "$i" -lt 200 ] && ! grep -qs 'check: external-wait' "$h/wake.out"; do
    rearm_watcher "$h" FM_EXTERNAL_WAIT_RECHECK_INTERVAL_SECS=1
    sleep 0.1
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt 40 ]; do
    rearm_watcher "$h" FM_EXTERNAL_WAIT_RECHECK_INTERVAL_SECS=1
    sleep 0.1
    i=$((i + 1))
  done
  stop_watcher "$h"
  for t in a b c; do
    assert_equals 1 "$(grep -o "overdue: file=$t.status dep=ssh/hostO" "$h/wake.out" | wc -l | tr -d ' ')" "the watcher woke once on task $t's passed recovery time"
  done
  assert_equals 1 "$(grep -o 'repeat: dep=ssh/hostO count=3 tasks=a,b,c' "$h/wake.out" | wc -l | tr -d ' ')" "the watcher woke once on the repeat dependency"
  pass "the watcher wakes once on an overdue wait and once on a repeat dependency"
}

test_declaration_parse
test_cleared_once
test_flapping_dependency_wakes_once
test_pass_cap_and_cache
test_overdue_once
test_dependency_kinds
test_https_refuses_internal_hosts
test_hostile_names_are_never_run
test_resolved_wait_is_not_rechecked
test_repeat_count
test_fan_in_is_not_a_repeat
test_custom_paused_verb_counts_repeats
test_status_logs_are_never_written
test_watcher_wakes_once_on_clear
test_watcher_wakes_once_on_overdue_and_repeat
