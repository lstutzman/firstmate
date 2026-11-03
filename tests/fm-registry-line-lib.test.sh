#!/usr/bin/env bash
# Behavior tests for bin/fm-registry-line-lib.sh: the registry line grammar
# (id, sentence, key: value fields, added date), field reading, the cadence
# period and the interval slot that holds a given moment.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-registry-line-lib.sh
. "$ROOT/bin/fm-registry-line-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-registry-line-lib)
export TZ=UTC

LINE='- friction - Watch friction (role: friction; cadence: every 4h; captains-log: https://x.test/api/captains-log; added 2026-10-23)'

test_line_field_reads_each_field() {
  assert_equals friction "$(line_field "$LINE" role)" "role field"
  assert_equals "every 4h" "$(line_field "$LINE" cadence)" "cadence field"
  assert_equals "https://x.test/api/captains-log" "$(line_field "$LINE" captains-log)" "value keeps its colons"
  pass 'line_field reads each key: value field'
}

test_line_field_refuses_missing_key_and_bad_line() {
  line_field "$LINE" model >/dev/null && fail "a missing key returned success"
  line_field '- not a registry line' role >/dev/null && fail "a malformed line returned success"
  line_field "$LINE" friction >/dev/null && fail "the id was read as a field"
  pass 'line_field fails for a missing key and for a malformed line'
}

test_line_regex_splits_id_and_added_date() {
  [[ "$LINE" =~ $REGISTRY_LINE_RE ]] || fail "a valid line did not match"
  assert_equals friction "${BASH_REMATCH[1]}" "id group"
  assert_equals 2026-10-23 "${BASH_REMATCH[4]}" "added group"
  [[ '- Bad_ID - x (a: b; added 2026-10-23)' =~ $REGISTRY_LINE_RE ]] && fail "an invalid id matched"
  [[ '- ok - x (a: b)' =~ $REGISTRY_LINE_RE ]] && fail "a line with no added date matched"
  pass 'the line regex splits the id and added date and rejects bad lines'
}

test_registry_lines_lists_only_entries() {
  local file="$TMP_ROOT/reg.md"
  printf '# Officers\n\n%s\nnote\n- second - y (a: b; added 2026-10-24)\n' "$LINE" > "$file"
  assert_equals 2 "$(registry_lines "$file" | wc -l | tr -d ' ')" "entry count"
  REGISTRY="$file"
  assert_equals 2 "$(registry_lines | wc -l | tr -d ' ')" "default registry"
  assert_equals "" "$(registry_lines "$TMP_ROOT/absent.md")" "absent file"
  pass 'registry_lines prints the "- " entries of the file or of $REGISTRY'
}

test_cadence_grammar_and_period() {
  local c
  for c in "daily 06:00" "daily 23:59" "every 1h" "every 24h"; do
    [[ "$c" =~ $CADENCE_RE ]] || fail "valid cadence refused: $c"
  done
  for c in "daily 24:00" "every 0h" "every 25h" "hourly" "daily 6:00"; do
    [[ "$c" =~ $CADENCE_RE ]] && fail "invalid cadence accepted: $c"
  done
  assert_equals 86400 "$(cadence_period 'daily 06:00')" "daily period"
  assert_equals 14400 "$(cadence_period 'every 4h')" "interval period"
  [[ 2026-10-23 =~ $RUN_KEY_RE && 2026-10-23T08 =~ $RUN_KEY_RE ]] || fail "run key refused"
  pass 'the cadence grammar and period match the documented values'
}

test_slot_of_finds_the_interval_slot() {
  local now=1792825200 # 2026-10-24 07:00:00 UTC
  slot_of 'every 4h' "$now"
  assert_equals 2026-10-24T04 "$SLOT_KEY" "slot key at 07:00"
  assert_equals "$(( now - 3 * 3600 ))" "$SLOT_SINCE" "slot start at 07:00"
  slot_of 'every 4h' "$(( now + 3600 ))"
  assert_equals 2026-10-24T08 "$SLOT_KEY" "slot key at 08:00"
  pass 'slot_of returns the slot holding the moment'
}

test_line_field_reads_each_field
test_line_field_refuses_missing_key_and_bad_line
test_line_regex_splits_id_and_added_date
test_registry_lines_lists_only_entries
test_cadence_grammar_and_period
test_slot_of_finds_the_interval_slot
