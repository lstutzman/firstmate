#!/usr/bin/env bash
# Behavior tests for the local-jev receipt writer: bin/fm-jev-receipts.py and
# its bash side, bin/fm-jev-receipt-lib.sh (docs/local-jev-receipts.md owns the
# schema). Covers the shared fields, append-only one-JSON-object-per-line
# output under concurrent writers, the canonical input hash, file modes, and a
# write that fails without changing the caller's exit code.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRITER="$ROOT/bin/fm-jev-receipts.py"
TMP_ROOT=$(fm_test_tmproot fm-jev-receipts-test)
DIR="$TMP_ROOT/receipts"

append() {  # <kind> <fields-json>: prints the receipt id; stderr goes to $TMP_ROOT/err
  FM_JEV_RECEIPTS_DIR=$DIR FM_HOME=/homes/fixture python3 -I "$WRITER" append "$1" <<<"$2" 2> "$TMP_ROOT/err"
}
lines() { cat "$DIR"/*.jsonl; }

id=$(append call '{"caller":"fixture","subject":"t1","request":{"state":{"b":2,"a":1},"question":"q?","criteria":{"true":"yes","false":"no"}},"pick":"true"}')
code=$?
expect_code 0 "$code" "a call append exits 0"
assert_equals 1 "$(lines | wc -l | tr -d ' ')" "one append writes one line"
assert_equals "$id" "$(lines | jq -r .receipt_id)" "the printed receipt id is the record's"
assert_equals 'local-jev-receipt.v1 call /homes/fixture fixture t1 true true true' \
  "$(lines | jq -r '[.schema, .kind, .home, .caller, .subject, (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")),
      (.host | type == "string"), (.receipt_id | startswith("jr-"))] | map(tostring) | join(" ")')" \
  "the writer adds schema, kind, ts, host, home, and a minted receipt id"
expected_hash=$(printf '%s' '{"criteria":{"false":"no","true":"yes"},"question":"q?","state":{"a":1,"b":2}}' | sha256sum | cut -d' ' -f1)
assert_equals "$expected_hash" "$(lines | jq -r .input_hash)" "input_hash is the sha256 of the compact, key-sorted request"
assert_equals "$(basename "$(ls "$DIR"/*.jsonl)")" "$(date -u +%Y-%m).jsonl" "records go to this UTC month's file"
first=$(head -1 "$DIR"/*.jsonl)
pass "writer: one call append is one line with the shared fields and the canonical input hash"

append decision "{\"receipt_id\":\"$id\",\"decision\":\"true\",\"source\":\"model\",\"overridden\":false,\"override_by\":null,\"corrected_decision\":null}" >/dev/null
append outcome "{\"receipt_id\":\"$id\",\"misroute\":true,\"corrected_decision\":\"false\",\"note\":\"reversed later\"}" >/dev/null
assert_equals 3 "$(lines | wc -l | tr -d ' ')" "a decision and an outcome add one line each"
assert_equals "$first" "$(head -1 "$DIR"/*.jsonl)" "an append never rewrites an earlier line"
assert_equals "$id $id $id" "$(lines | jq -r .receipt_id | paste -sd' ' -)" "a decision and an outcome keep their call's receipt id"
pass "writer: decision and outcome records append after the call and link to it"

for i in $(seq 1 24); do
  append call "{\"caller\":\"fixture\",\"subject\":\"par-$i\",\"request\":{\"state\":\"$(printf 'x%.0s' $(seq 1 400))\",\"question\":\"q\",\"criteria\":{}}}" >/dev/null &
done
wait
assert_equals 27 "$(lines | wc -l | tr -d ' ')" "24 concurrent appends add 24 lines"
assert_equals 27 "$(lines | jq -c . 2>/dev/null | wc -l | tr -d ' ')" "every line is one valid JSON object"
assert_equals 24 "$(lines | jq -r 'select((.subject // "") | startswith("par-")) | .subject' | sort -u | wc -l | tr -d ' ')" "no concurrent record is lost or merged"
assert_equals '700 600' "$(stat -c '%a' "$DIR" 2>/dev/null || stat -f '%Lp' "$DIR") $(stat -c '%a' "$DIR"/*.jsonl 2>/dev/null || stat -f '%Lp' "$DIR"/*.jsonl)" \
  "the stream directory is private to the user and each file is 0600"
pass "writer: concurrent appends never interleave and the stream is private"

out=$(append decision '{"decision":"true","source":"guess"}')
code=$?
expect_code 0 "$code" "an invalid decision still exits 0"
assert_equals '' "$out" "an invalid decision prints no receipt id"
assert_contains "$(cat "$TMP_ROOT/err")" 'local-jev receipt: not written (decision source must be one of' "an invalid source is named"
assert_equals 27 "$(lines | wc -l | tr -d ' ')" "an invalid decision writes nothing"
: > "$TMP_ROOT/blocker"
out=$(FM_JEV_RECEIPTS_DIR="$TMP_ROOT/blocker/sub" python3 -I "$WRITER" append call <<<'{"caller":"fixture"}' 2> "$TMP_ROOT/err")
code=$?
expect_code 0 "$code" "an unwritable stream still exits 0"
assert_equals '' "$out" "an unwritten record prints no receipt id"
assert_equals 1 "$(grep -c '^local-jev receipt: not written' "$TMP_ROOT/err")" "an unwritable stream prints exactly one warning"
pass "writer: a record that cannot be written prints one warning and exits 0"

# shellcheck disable=SC2016 # the library path is the inner shell's $1
lib_out=$(FM_JEV_RECEIPTS_DIR=$DIR bash -c '. "$1"; fm_jev_receipt call "{\"caller\":\"bash-fixture\"}"; echo "rc=$?"' _ "$ROOT/bin/fm-jev-receipt-lib.sh" 2> "$TMP_ROOT/err")
assert_contains "$lib_out" 'rc=0' "the bash writer returns 0"
assert_equals "$(lines | jq -r 'select(.caller == "bash-fixture") | .receipt_id')" "$(head -1 <<<"$lib_out")" "the bash writer prints the receipt id it appended"
# shellcheck disable=SC2016 # the library path is the inner shell's $1
lib_out=$(FM_JEV_RECEIPTS_DIR="$TMP_ROOT/blocker/sub" bash -c '. "$1"; fm_jev_receipt call "{}"; echo "rc=$?"' _ "$ROOT/bin/fm-jev-receipt-lib.sh" 2> "$TMP_ROOT/err")
assert_equals 'rc=0' "$lib_out" "the bash writer returns 0 and prints no id when the write fails"
assert_equals 1 "$(grep -c '^local-jev receipt: not written' "$TMP_ROOT/err")" "the bash writer passes on exactly one warning"
bash_bin=$(command -v bash)
# shellcheck disable=SC2016 # the library path is the inner shell's $1
lib_out=$(PATH=/nonexistent "$bash_bin" -c '. "$1"; fm_jev_receipt call "{}"; echo "rc=$?"' _ "$ROOT/bin/fm-jev-receipt-lib.sh" 2> "$TMP_ROOT/err")
assert_equals 'rc=0' "$lib_out" "a missing python3 never changes the caller's exit code"
assert_equals 'local-jev receipt: not written (python3 not found)' "$(cat "$TMP_ROOT/err")" "a missing python3 prints one warning"
pass "bash writer: appends through the python writer and never fails its caller"

echo "# all fm-jev-receipts tests passed"
