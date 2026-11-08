#!/usr/bin/env bash
# Behavior tests for bin/fm-session-weight.sh against a fake process table, a fake working-directory
# tree and a fake usage database: which sessions are flagged, what a line names, the stated limit,
# the once-per-day note, and that nothing is ever signalled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WEIGHT="$ROOT/bin/fm-session-weight.sh"
TMP_ROOT=$(fm_test_tmproot fm-session-weight)
NOW=1794009600

# make_world <name>: a fake process table, proc root and usage database.
make_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/proc/200" "$w/proc/300" "$w/proc/400"
  ln -s /home/lee/fm-homes/navigator "$w/proc/200/cwd"
  ln -s /srv/work/repo/pane "$w/proc/300/cwd"
  ln -s /home/lee/fm-homes/slarti "$w/proc/400/cwd"
  {
    printf '  100   3600 claude --dangerously-skip-permissions --model claude-opus-5-5\n'
    printf '  200 100000 claude --add-dir /home/lee/fm-homes/quartermaster/state/operational-inbox --model claude-opus-5-5\n'
    printf '  300 200000 codex --yolo\n'
    printf '  400   5000 claude --model=claude-opus-4-8 --secret-flag hunter2\n'
    printf '  500 900000 vim claude-notes.txt\n'
    printf '  600 900000 /usr/local/bin/claude --model claude-sonnet-5-5\n'
  } > "$w/ps.txt"
  python3 -I - "$w/usage.db" "$NOW" <<'PY'
import sqlite3, sys
db, now = sys.argv[1], int(sys.argv[2])
con = sqlite3.connect(db)
con.execute("create table usage(id text primary key, ts real, account text, model text, input int, output int, reasoning int, cache_read int, cache_write int, total int, failed int)")
rows = []
for i, size in enumerate([100000, 200000, 300000, 400000, 500000]):
    rows.append(("a%d" % i, now - 600 - i, "x@example.com", "claude-opus-5-5", 0, 1, 0, size, 0, size, 0))
rows.append(("old", now - 30 * 3600, "x@example.com", "claude-opus-5-5", 0, 1, 0, 900000, 0, 900000, 0))
rows.append(("bad", now - 60, "x@example.com", "claude-opus-5-5", 0, 1, 0, 900000, 0, 900000, 1))
rows.append(("r0", now - 60, "x@example.com", "claude-opus-4-8", 10000, 1, 0, 50000, 20000, 80000, 0))
con.executemany("insert into usage values (?,?,?,?,?,?,?,?,?,?,?)", rows)
con.commit()
PY
  printf '%s\n' "$w"
}

weight() {  # <world> [args...]
  local w=$1
  shift
  bash "$WEIGHT" --ps "$w/ps.txt" --proc-root "$w/proc" --db "$w/usage.db" --now "$NOW" "$@"
}

test_flags_old_and_retired_sessions_only() {
  local w out
  w=$(make_world flags)
  out=$(weight "$w")
  assert_equals 4 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "pids 200, 300, 400 and 600 qualify; 100 is young and on a current model; vim is not a session"
  assert_not_contains "$out" "pid=100 " "a young session on a current model is not listed"
  assert_not_contains "$out" "pid=500" "a process that merely mentions claude is not a session"
  assert_contains "$out" "pid=200 claude home=quartermaster age=27.8h model=claude-opus-5-5 [age>24h]" "an old session names pid, the home in its --add-dir (which wins over its working directory), age and model"
  assert_contains "$out" "pid=600 claude home=unknown" "no add-dir and no readable working directory: home unknown"
  assert_contains "$out" "pid=300 codex cwd=repo/pane age=55.6h model=default [age>24h]" "a codex session with no model flag and a plain working directory"
  assert_contains "$out" "pid=400 claude home=slarti age=1.4h model=claude-opus-4-8 [retired-model]" "a retired model is flagged even when young, the home comes from the working directory and the --model= form is read"
  pass 'only sessions older than 24 hours or on a retired model are listed'
}

test_context_is_account_level_and_labelled_inferred() {
  local w out
  w=$(make_world ctx)
  out=$(weight "$w")
  assert_contains "$out" "account recent claude-opus-5-5 requests (last 6h, n=5): median 300K, p90 500K" "failed and out-of-window requests are left out"
  assert_contains "$out" "account recent claude-opus-4-8 requests (last 6h, n=1): median 80K, p90 80K" "the retired model's own recent requests"
  assert_contains "$out" "account recent context: no data for model claude-sonnet-5-5" "a model with no recent requests says so"
  assert_equals 4 "$(printf '%s\n' "$out" | grep -c 'inferred from account-level requests, not measured')" "every line states the limit"
  pass 'context comes from account-level request sizes and every line says it is inferred'
}

test_prints_nothing_private() {
  local w out
  w=$(make_world priv)
  out=$(weight "$w")
  assert_not_contains "$out" "hunter2" "the rest of a command line is never printed"
  assert_not_contains "$out" "--dangerously-skip-permissions" "flags other than the model are never printed"
  pass 'only pid, home, age, model and account context are printed'
}

test_retired_pattern_and_age_are_configurable() {
  local w out
  w=$(make_world conf)
  out=$(weight "$w" --min-age-hours 1000 --retired 'sonnet-5')
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "only the pattern match remains"
  assert_contains "$out" "pid=600 claude" "the sonnet session matches the supplied retired pattern"
  out=$(FM_SESSION_WEIGHT_RETIRED='opus-4' weight "$w" --min-age-hours 1000)
  assert_contains "$out" "pid=400" "the environment variable sets the retired pattern"
  pass 'the age threshold and retired pattern can be set'
}

test_missing_database_still_lists_sessions() {
  local w out
  w=$(make_world nodb)
  out=$(weight "$w" --db "$w/missing.db")
  assert_equals 4 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "the sessions are still listed"
  assert_contains "$out" "account recent context: no data for model claude-opus-5-5" "without a database there is no context figure"
  pass 'a missing usage database degrades to no context figure'
}

test_quiet_when_nothing_qualifies() {
  local w
  w=$(make_world quiet)
  printf '  100 3600 claude --model claude-opus-5-5\n' > "$w/ps.txt"
  assert_equals "" "$(weight "$w")" "no flagged session: no output"
  assert_equals "" "$(weight "$w" --note-dir "$w/notes" --summary)" "no flagged session: no note and no wake line"
  assert_absent "$w/notes" "no note directory is created"
  pass 'nothing is printed or written when no session qualifies'
}

test_note_and_wake_line_once_per_day() {
  local w out
  w=$(make_world note)
  out=$(weight "$w" --note-dir "$w/notes" --summary)
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "one wake line"
  assert_contains "$out" "session-weight 2026-11-07 [key=session-weight-2026-11-07]: 4 session(s) older than 24h or on a retired model (pids 200,300,400,600)" "the line carries the day key and the pids"
  assert_contains "$out" "inferred from account-level requests, not measured" "the wake line states the limit"
  assert_present "$w/notes/2026-11-07.txt" "the note is written"
  assert_equals 4 "$(wc -l < "$w/notes/2026-11-07.txt" | tr -d ' ')" "the note holds one line per session"
  assert_equals "" "$(weight "$w" --note-dir "$w/notes" --summary)" "the same day again: silent"
  assert_contains "$(weight "$w" --note-dir "$w/notes" --summary --now $((NOW + 86400)))" "session-weight 2026-11-08" "the next day writes a new note"
  pass 'one note and one wake line per UTC day'
}

test_never_signals_a_process() {
  local w sleeper
  w=$(make_world nosignal)
  sleep 30 &
  sleeper=$!
  printf '  %s 999999 claude --model claude-opus-4-8\n' "$sleeper" > "$w/ps.txt"
  weight "$w" >/dev/null
  kill -0 "$sleeper" 2>/dev/null || fail "the flagged process must still be running"
  kill "$sleeper" 2>/dev/null
  wait "$sleeper" 2>/dev/null
  pass 'a flagged process is left running'
}

fm_test_run \
  test_flags_old_and_retired_sessions_only \
  test_context_is_account_level_and_labelled_inferred \
  test_prints_nothing_private \
  test_retired_pattern_and_age_are_configurable \
  test_missing_database_still_lists_sessions \
  test_quiet_when_nothing_qualifies \
  test_note_and_wake_line_once_per_day \
  test_never_signals_a_process
