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
    printf '  700 1700000 /usr/local/bin/codex -c features.x=true app-server --listen unix:///run/codex.sock\n'
    printf '  800 104000 codex app-server proxy\n'
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
  make_fake_herdr "$w"
  printf '%s\n' "$w"
}

weight() {  # <world> [args...]
  local w=$1
  shift
  PATH="$w/herdrbin:$PATH" bash "$WEIGHT" --ps "$w/ps.txt" --proc-root "$w/proc" --db "$w/usage.db" --now "$NOW" --homes-root "$w/homes" "$@"
}

# A fake herdr that answers `--session S workspace list`, `pane list` and `pane process-info --pane P`
# from fixture files in <world>/herdr (S.workspaces.json, S.panes.json, S.proc.<pane with : as _>.json)
# and fails when a fixture is absent, so no test ever reaches the real Herdr.
make_fake_herdr() {  # <world>
  mkdir -p "$1/herdrbin" "$1/herdr"
  cat > "$1/herdrbin/herdr" <<'SH'
#!/usr/bin/env bash
d=$(dirname "$0")/../herdr
s=$2
case "$3 $4" in
  "workspace list") f=$d/$s.workspaces.json ;;
  "pane list") f=$d/$s.panes.json ;;
  "pane process-info") p=${6//:/_}; f=$d/$s.proc.$p.json ;;
  *) exit 1 ;;
esac
[ -f "$f" ] && cat "$f"
SH
  chmod +x "$1/herdrbin/herdr"
}

# fake_pane_pids <world> <session> <pane> <pid>: the pane's foreground process is <pid>.
fake_pane_pids() {
  printf '{"result":{"process_info":{"shell_pid":1,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s}]}}}\n' "$4" "$4" \
    > "$1/herdr/$2.proc.${3//:/_}.json"
}

# lock_holder <world> <home> <ps-line-model-flags>: start a real process named claude, record its pid
# as <home>'s session lock, list it in the fake process table with the given age, and set LAST_HOLDER to its pid.
lock_holder() {  # <world> <home> <age-seconds> <model>
  local w=$1 home=$2 age=$3 model=$4 pid
  mkdir -p "$w/homes/$home/state" "$w/bin"
  [ -x "$w/bin/claude" ] || cp "$(command -v bash)" "$w/bin/claude"
  mkfifo "$w/fifo" 2>/dev/null
  # shellcheck disable=SC2016 # the script text is for the child shell
  "$w/bin/claude" -c 'read -r -t 60 _ <> "$1"' _ "$w/fifo" >/dev/null 2>&1 &
  pid=$!
  HOLDER_PIDS="${HOLDER_PIDS:-} $pid"
  printf '%s\n' "$pid" > "$w/homes/$home/state/.lock"
  printf '  %s %s claude --model %s\n' "$pid" "$age" "$model" >> "$w/ps.txt"
  LAST_HOLDER=$pid
}

stop_holders() {
  local p
  for p in ${HOLDER_PIDS:-}; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  HOLDER_PIDS=
}

test_flags_old_and_retired_sessions_only() {
  local w out
  w=$(make_world flags)
  out=$(weight "$w")
  assert_equals 4 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "pids 200, 300, 400 and 600 qualify; 100 is young and on a current model; vim and codex app-server daemons are not sessions"
  assert_not_contains "$out" "pid=100 " "a young session on a current model is not listed"
  assert_not_contains "$out" "pid=500" "a process that merely mentions claude is not a session"
  assert_not_contains "$out" "pid=700" "a codex app-server daemon is not a session"
  assert_not_contains "$out" "pid=800" "a codex app-server proxy daemon is not a session"
  assert_contains "$out" "pid=200 claude home=quartermaster age=27.8h model=claude-opus-5-5 [age>24h]" "an old session names pid, the home in its --add-dir (which wins over its working directory), age and model"
  assert_contains "$out" "pid=600 claude home=unknown" "no add-dir and no readable working directory: home unknown"
  assert_contains "$out" "pid=300 codex cwd=repo/pane age=55.6h model=default [age>24h]" "a codex session with no model flag and a plain working directory"
  assert_contains "$out" "pid=400 claude home=slarti age=1.4h model=claude-opus-4-8 [retired-model]" "a retired model is flagged even when young, the home comes from the working directory and the --model= form is read"
  pass 'only sessions older than 24 hours or on a retired model are listed'
}

test_app_server_word_in_a_brief_is_still_a_session() {
  local w out
  w=$(make_world brief)
  {
    printf '  900 108000 codex --model gpt-5.5 --yolo [fm-launch-brief] fix the codex app-server lifecycle in fm-busy-lib\n'
    printf ' 1000 108000 claude --model claude-opus-5-5 app-server notes\n'
    printf ' 1100 108000 codex -c features.code_mode_host=true app-server --listen unix://\n'
  } > "$w/ps.txt"
  out=$(weight "$w")
  assert_contains "$out" "pid=900 codex home=unknown age=30.0h model=gpt-5.5 [age>24h]" "a codex worker whose launch brief mentions app-server is still a session"
  assert_contains "$out" "pid=1000 claude home=unknown age=30.0h model=claude-opus-5-5 [age>24h]" "a claude session is never skipped as an app-server"
  assert_not_contains "$out" "pid=1100" "the app-server subcommand after a -c pair is a daemon"
  pass 'only the codex app-server subcommand is skipped, not the word in a brief'
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

test_lock_holders_are_not_flagged_for_age() {
  local w out holder
  w=$(make_world holders)
  lock_holder "$w" navigator 200000 claude-opus-5-5; holder=$LAST_HOLDER
  out=$(weight "$w")
  stop_holders
  assert_not_contains "$out" "pid=$holder " "a home's lock-holding session over 24h is not flagged for age"
  assert_contains "$out" "pid=200 claude home=quartermaster" "a non-holder over 24h is still flagged"
  assert_equals 4 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "only the holder is dropped from the list"
  pass 'a session holding a home lock is not flagged for age alone'
}

test_lock_holder_on_retired_model_is_still_flagged() {
  local w out holder
  w=$(make_world holderret)
  lock_holder "$w" slarti 200000 claude-opus-4-8; holder=$LAST_HOLDER
  out=$(weight "$w")
  stop_holders
  assert_contains "$out" "pid=$holder claude home=unknown age=55.6h model=claude-opus-4-8 [retired-model]" "a lock holder on a retired model is flagged for the model only"
  pass 'a lock holder on a retired model is still flagged'
}

test_parent_home_lock_holder_is_not_flagged() {
  local w out holder
  w=$(make_world parent)
  mkdir -p "$w/homes/navigator" "$w/main/state"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$w/main" > "$w/homes/navigator/.fm-secondmate-parent"
  lock_holder "$w" navigator 200000 claude-opus-5-5; holder=$LAST_HOLDER
  rm -f "$w/homes/navigator/state/.lock"
  printf '%s\n' "$holder" > "$w/main/state/.lock"
  out=$(weight "$w")
  stop_holders
  assert_not_contains "$out" "pid=$holder " "the main home's lock holder, named by a mate's parent binding, is not flagged for age"
  pass 'the main home lock holder is skipped through the parent binding'
}

test_recorded_task_session_is_not_flagged_for_age() {
  local w out
  w=$(make_world task)
  printf '  450 200000 claude --model claude-opus-4-8\n' >> "$w/ps.txt"
  mkdir -p "$w/homes/slarti/state"
  printf 'window=fm-remote:w9:p2\nbackend=herdr\n' > "$w/homes/slarti/state/a-task.meta"
  printf 'window=w8:p1\n' > "$w/homes/slarti/state/local-task.meta"
  fake_pane_pids "$w" fm-remote w9:p2 200
  fake_pane_pids "$w" default w8:p1 450
  out=$(weight "$w")
  assert_not_contains "$out" "pid=200 " "a session in a home's recorded task window is not flagged for age"
  assert_contains "$out" "pid=450 claude home=unknown age=55.6h model=claude-opus-4-8 [retired-model]" "a recorded-task session on a retired model is flagged for the model only"
  assert_contains "$out" "pid=300 codex" "a session in no recorded window is still flagged"
  pass 'a recorded task session is not flagged for age alone'
}

test_named_workspace_session_is_not_flagged_for_age() {
  local w out
  w=$(make_world named)
  printf '  450 200000 claude --model claude-opus-4-8\n' >> "$w/ps.txt"
  printf '{"result":{"workspaces":[{"label":"Lee steps","workspace_id":"w10F"},{"label":"Skipper","workspace_id":"w17C"}]}}\n' > "$w/herdr/default.workspaces.json"
  printf '{"result":{"panes":[{"pane_id":"w10F:p1","workspace_id":"w10F"},{"pane_id":"w10F:p2","workspace_id":"w10F"},{"pane_id":"w17C:p1","workspace_id":"w17C"}]}}\n' > "$w/herdr/default.panes.json"
  fake_pane_pids "$w" default w10F:p1 300
  fake_pane_pids "$w" default w10F:p2 450
  fake_pane_pids "$w" default w17C:p1 200
  out=$(weight "$w")
  assert_not_contains "$out" "pid=300 " "a session in the Lee steps workspace is not flagged for age"
  assert_contains "$out" "pid=450 claude home=unknown age=55.6h model=claude-opus-4-8 [retired-model]" "a named-workspace session on a retired model is flagged for the model only"
  assert_contains "$out" "pid=200 claude" "a session in another workspace is still flagged"
  pass 'a named workspace session is not flagged for age alone'
}

test_dead_lock_pid_protects_nothing() {
  local w out
  w=$(make_world deadlock)
  mkdir -p "$w/homes/navigator/state"
  printf '200\n' > "$w/homes/navigator/state/.lock"
  out=$(weight "$w")
  assert_contains "$out" "pid=200 claude" "a lock naming a process that is not a live harness does not exempt a session"
  pass 'a stale lock exempts nothing'
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
  test_app_server_word_in_a_brief_is_still_a_session \
  test_context_is_account_level_and_labelled_inferred \
  test_prints_nothing_private \
  test_retired_pattern_and_age_are_configurable \
  test_missing_database_still_lists_sessions \
  test_quiet_when_nothing_qualifies \
  test_note_and_wake_line_once_per_day \
  test_lock_holders_are_not_flagged_for_age \
  test_lock_holder_on_retired_model_is_still_flagged \
  test_parent_home_lock_holder_is_not_flagged \
  test_recorded_task_session_is_not_flagged_for_age \
  test_named_workspace_session_is_not_flagged_for_age \
  test_dead_lock_pid_protects_nothing \
  test_never_signals_a_process
