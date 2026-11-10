#!/usr/bin/env bash
# Behavior tests for bin/fm-linear-usage.py: one JSONL usage line per Linear call, best effort.
# Covers: the record fields from rate-limit headers, null for missing values, the key NAME only,
# LINEAR_JOB overriding the job, file modes 0700/0600, and a logging failure never raising.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-linear-usage)
MOD="$ROOT/bin/fm-linear-usage.py"

run_record() {  # <state-dir> <env...> -- calls record with headers
  local dir=$1; shift
  env FM_LINEAR_USAGE_NO_POST=1 "$@" python3 -I - "$MOD" "$dir" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("u", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
row = m.record("officer:progress", "firstmate/bin/x.py", "OfficerLabels", 429,
               {"X-RateLimit-Requests-Remaining": "17", "X-RateLimit-Complexity-Remaining": "900",
                "X-Complexity": "12", "Retry-After": "30"}, "pc-token", state_dir=sys.argv[2])
print("row" if row else "none")
PY
}

test_usage_line_fields_and_modes() {
  local dir="$TMP_ROOT/state/linear-usage" out line
  out=$(run_record "$dir" LINEAR_JOB=)
  assert_equals row "$out" "record returns the row"
  line=$(cat "$dir/usage.jsonl")
  assert_contains "$line" '"job":"officer:progress"' "job recorded"
  assert_contains "$line" '"requests_remaining":17' "requests remaining from header"
  assert_contains "$line" '"complexity_remaining":900' "complexity remaining from header"
  assert_contains "$line" '"requests_limit":null' "missing header is null"
  assert_contains "$line" '"retry_after":30' "retry-after recorded"
  assert_contains "$line" '"key":"pc-token"' "key name recorded"
  assert_contains "$line" '"status":429' "status recorded"
  assert_equals 600 "$(stat -c %a "$dir/usage.jsonl")" "file mode 0600"
  assert_equals 700 "$(stat -c %a "$dir")" "dir mode 0700"
  pass "usage line fields and modes"
}

test_linear_job_overrides_and_appends() {
  local dir="$TMP_ROOT/state/job"
  run_record "$dir" LINEAR_JOB=cl-keeper >/dev/null
  run_record "$dir" LINEAR_JOB=cl-keeper >/dev/null
  assert_equals 2 "$(wc -l < "$dir/usage.jsonl")" "each call appends a line"
  assert_contains "$(tail -1 "$dir/usage.jsonl")" '"job":"cl-keeper"' "LINEAR_JOB overrides the job"
  pass "LINEAR_JOB overrides the job and lines append"
}

test_unwritable_sink_never_raises() {
  local blocked="$TMP_ROOT/blocked" out
  : > "$blocked"
  out=$(run_record "$blocked/under-a-file" LINEAR_JOB=)
  assert_equals none "$out" "an unwritable sink returns None and does not raise"
  pass "unwritable sink never raises"
}

fm_test_run test_usage_line_fields_and_modes test_linear_job_overrides_and_appends test_unwritable_sink_never_raises
