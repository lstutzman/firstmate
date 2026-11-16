#!/usr/bin/env bash
# Behavior tests for bin/fm-complain.sh: the record it appends, what it refuses, and concurrent appends.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMPLAIN="$ROOT/bin/fm-complain.sh"
TMP_ROOT=$(fm_test_tmproot fm-complain)
HOME_DIR="$TMP_ROOT/home"
FILE="$HOME_DIR/data/agent-complaints.jsonl"
mkdir -p "$HOME_DIR/state"
printf 'kind=ship\nproject=/x/projects/widget\n' > "$HOME_DIR/state/t1.meta"

complain() {  # <task-or-empty> args...
  local task=$1
  shift
  if [ -n "$task" ]; then
    FM_HOME="$HOME_DIR" FM_TASK_ID="$task" bash "$COMPLAIN" "$@"
  else
    env -u FM_TASK_ID FM_HOME="$HOME_DIR" bash "$COMPLAIN" "$@"
  fi
}

test_records_one_json_line() {
  complain t1 'the "status" helper needs a flag; it is slow' >/dev/null 2>&1 || fail "complaint was refused"
  [ "$(wc -l < "$FILE")" -eq 1 ] || fail "expected one line"
  python3 -I - "$FILE" "$HOME_DIR" <<'PY' || fail "record fields wrong"
import json, re, sys
r = json.loads(open(sys.argv[1]).read())
assert set(r) == {"at", "task", "home", "project", "sentence"}, r
assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", r["at"]), r
assert (r["task"], r["home"], r["project"]) == ("t1", sys.argv[2], "widget"), r
assert r["sentence"] == 'the "status" helper needs a flag; it is slow', r
PY
  pass "records one JSON line with time, task, home, project and sentence"
}

test_project_unknown_without_meta() {
  complain t2 'no meta here' >/dev/null 2>&1 || fail "complaint was refused"
  tail -n 1 "$FILE" | grep -q '"project":"unknown"' || fail "project not unknown"
  pass "a task with no metadata records project unknown"
}

test_refusals() {
  local before after long
  before=$(wc -l < "$FILE")
  long=$(printf 'x%.0s' $(seq 1 501))
  complain t1 && fail "no argument accepted"
  complain t1 a b && fail "two arguments accepted"
  complain t1 '' && fail "empty sentence accepted"
  complain t1 '   ' && fail "blank sentence accepted"
  complain t1 $'one\ntwo' && fail "multi-line sentence accepted"
  complain t1 "$long" && fail "over-long sentence accepted"
  complain '' 'no task' && fail "missing task id accepted"
  after=$(wc -l < "$FILE")
  [ "$before" -eq "$after" ] || fail "a refused call wrote a record"
  complain t1 "$(printf 'x%.0s' $(seq 1 500))" >/dev/null 2>&1 || fail "500 characters refused"
  pass "refuses none, several, empty, multi-line, over-long and task-less, writing nothing"
}

test_concurrent_appends() {
  local before after i
  before=$(wc -l < "$FILE")
  for i in $(seq 1 40); do
    complain t1 "concurrent complaint $i" >/dev/null 2>&1 &
  done
  wait
  after=$(wc -l < "$FILE")
  [ $((after - before)) -eq 40 ] || fail "expected 40 new lines, got $((after - before))"
  python3 -I - "$FILE" <<'PY' || fail "a line was torn"
import json, sys
for line in open(sys.argv[1]):
    json.loads(line)
PY
  pass "40 concurrent complaints each land as one intact line"
}

fm_test_run test_records_one_json_line test_project_unknown_without_meta test_refusals test_concurrent_appends
