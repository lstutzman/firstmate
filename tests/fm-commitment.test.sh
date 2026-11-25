#!/usr/bin/env bash
# Behavior tests for bin/fm-commitment.sh: the register it writes, what it refuses, and retire.
# The officer's evaluation of these rows is covered in tests/fm-officer-page-check.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMMIT="$ROOT/bin/fm-commitment.sh"
TMP_ROOT=$(fm_test_tmproot fm-commitment)
HOME_DIR="$TMP_ROOT/quartermaster"
REG="$HOME_DIR/data/standing-commitments.json"
mkdir -p "$HOME_DIR/data"
HOOK="$TMP_ROOT/landing-hook.sh"
printf '#!/bin/sh\nexec gate-ledger.py "$@"\n' > "$HOOK"

commit() {  # <args...>: runs the recorder in the fixture home
  FM_HOME="$HOME_DIR" bash "$COMMIT" "$@"
}

add() {  # <id> <enforcement> <verify> [extra args]: records one row with fixed words
  local id=$1 enf=$2 ver=$3
  shift 3
  commit add --id "$id" --commitment "Landing runs the ledger on every red pile" \
    --lee-words 'Lee, main chat, 2026-11-25: "from now on"' --enforcement "$enf" --verify "$ver" "$@"
}

test_add_records_one_row_with_every_field() {
  add landing-ledger "file:$HOOK#contains=gate-ledger.py" 'log:/var/log/landing/*.log;regex=^==> dotnet build(?!.*skipped);max-count=1;max-age=48h' \
    >/dev/null 2>&1 || fail "a well-formed row was refused"
  python3 -I - "$REG" "$HOOK" <<'PY' || fail "the stored row is wrong"
import json, re, sys
doc = json.load(open(sys.argv[1]))
assert doc["version"] == 1 and len(doc["rows"]) == 1, doc
r = doc["rows"][0]
assert r["id"] == "landing-ledger" and r["owner"] == "quartermaster", r
assert r["commitment"] == "Landing runs the ledger on every red pile", r
assert r["lee_words"] == 'Lee, main chat, 2026-11-25: "from now on"', r
assert r["enforcement"] == "file:%s#contains=gate-ledger.py" % sys.argv[2], r
assert r["verify"].endswith(";max-count=1;max-age=48h") and r["retired"] is None, r
assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", r["recorded_at"]), r
PY
  pass "add stores the commitment, Lee's words, owner (this home by default), both specs and recorded_at"
}

test_a_row_may_be_recorded_for_another_home() {
  add navigator-hook none none --owner navigator >/dev/null 2>&1 || fail "an owner-relayed row was refused"
  assert_equals "navigator" "$(jq -r '.rows[] | select(.id == "navigator-hook") | .owner' "$REG")" "the owner is the named home"
  pass "add records a row on another home's behalf"
}

test_memory_and_none_are_accepted() {
  add slarti-memory memory none --owner slarti >/dev/null 2>&1 || fail "memory enforcement must be accepted"
  add no-proof none none >/dev/null 2>&1 || fail "none enforcement and none verification must be accepted"
  pass "memory and none specs are accepted (and always red when the officer evaluates them)"
}

test_malformed_specs_are_refused() {
  local out
  out=$(add bad-1 'script:/x' none 2>&1) && fail "an unknown enforcement type must be refused"
  assert_contains "$out" "enforcement must be" "the refusal names the enforcement grammar"
  out=$(add bad-2 'file:relative/path' none 2>&1) && fail "a relative enforcement path must be refused"
  assert_contains "$out" "must be absolute" "the refusal names the path rule"
  out=$(add bad-3 "file:$HOOK#contains=" none 2>&1) && fail "an empty contains literal must be refused"
  out=$(add bad-4 "file:$TMP_ROOT/no-such-hook.sh" none 2>&1) && fail "an enforcement file that does not exist must be refused"
  assert_contains "$out" "does not exist" "the refusal says the file is missing"
  out=$(add bad-5 "file:$HOOK#contains=never-in-it" none 2>&1) && fail "an enforcement file lacking the literal must be refused"
  assert_contains "$out" "lacks the required text" "the refusal says the check is not wired in"
  out=$(add bad-6 none 'sql:select 1' 2>&1) && fail "an unknown verify type must be refused"
  out=$(add bad-7 none 'file:relative/*.log' 2>&1) && fail "a relative verify path must be refused"
  out=$(add bad-8 none 'file:/x/*.log;max-age=0h' 2>&1) && fail "max-age of 0 must be refused"
  out=$(add bad-9 none 'file:/x/*.log;max-age=6' 2>&1) && fail "max-age without h must be refused"
  out=$(add bad-10 none 'log:/x/a.log' 2>&1) && fail "a log spec with no regex must be refused"
  out=$(add bad-11 none 'log:/x/a.log;regex=(unclosed' 2>&1) && fail "a regex that does not compile must be refused"
  assert_contains "$out" "does not compile" "the refusal names the regex"
  out=$(add bad-12 none 'log:/x/a.log;regex=x;max-count=many' 2>&1) && fail "a non-numeric max-count must be refused"
  out=$(add bad-13 none 'status:;regex=x' 2>&1) && fail "a status spec with no home must be refused"
  out=$(add bad-14 none 'status:navigator;regex=x;max-count=1' 2>&1) && fail "max-count on a status spec must be refused"
  out=$(add 'Bad Id' none none 2>&1) && fail "an id that is not a slug must be refused"
  out=$(commit add --id missing-fields --enforcement none 2>&1) && fail "a row with missing fields must be refused"
  assert_contains "$out" "--commitment" "the refusal names the missing flag"
  out=$(commit add --id multi --commitment $'two\nlines' --lee-words w --enforcement none --verify none 2>&1) && fail "a multi-line commitment must be refused"
  assert_equals "0" "$(jq '[.rows[] | select(.id | startswith("bad-") or . == "multi" or . == "missing-fields")] | length' "$REG")" "no refused row is recorded"
  pass "malformed or unfulfilled specs and fields are refused and record nothing"
}

test_a_regex_may_hold_a_semicolon_and_options_follow_it() {
  add semi none 'log:/x/*.log;regex=a;b;max-count=2;max-age=6h' >/dev/null 2>&1 || fail "a regex with a semicolon must be accepted"
  add status-ok none 'status:navigator;regex=^done;max-age=12h' >/dev/null 2>&1 || fail "a status spec must be accepted"
  add file-ok none 'file:/x/receipts/*.json;max-age=26h' >/dev/null 2>&1 || fail "a file spec with max-age must be accepted"
  pass "log, status and file verify specs parse, including a regex with ; before the options"
}

test_a_duplicate_id_is_refused_and_retire_keeps_the_row() {
  local out
  out=$(add landing-ledger none none 2>&1) && fail "a duplicate id must be refused"
  assert_contains "$out" "exists already" "the refusal names the duplicate"
  commit retire --id landing-ledger --reason 'replaced by a hook' >/dev/null 2>&1 || fail "retire was refused"
  assert_equals "replaced by a hook" "$(jq -r '.rows[] | select(.id == "landing-ledger") | .retired.reason' "$REG")" "retire records the reason"
  assert_contains "$(jq -r '.rows[] | select(.id == "landing-ledger") | .retired.at' "$REG")" "T" "retire records when"
  out=$(add landing-ledger none none 2>&1) && fail "a retired row's id stays taken"
  out=$(commit retire --id landing-ledger --reason again 2>&1) && fail "retiring twice must be refused"
  out=$(commit retire --id no-such-row --reason x 2>&1) && fail "retiring an unknown row must be refused"
  out=$(commit retire --id navigator-hook 2>&1) && fail "retire without a reason must be refused"
  pass "a duplicate or retired id is refused; retire marks the row and never deletes it"
}

test_list_shows_active_rows_and_all_on_request() {
  local out
  out=$(commit list)
  assert_not_contains "$out" "landing-ledger" "a retired row is not listed by default"
  assert_contains "$out" "navigator-hook" "an active row is listed"
  assert_contains "$(commit list --all)" "landing-ledger	quartermaster	retired" "--all lists the retired row with its state"
  assert_equals "true" "$(commit list --all --json | jq 'map(.id) | index("landing-ledger") != null')" "--json lists rows as JSON"
  pass "list shows active rows, and retired ones with --all"
}

test_an_unreadable_register_is_not_overwritten() {
  local out
  printf 'not json' > "$REG"
  out=$(add after-corruption none none 2>&1) && fail "add must not overwrite an unreadable register"
  assert_equals "not json" "$(cat "$REG")" "the unreadable register is left as it was"
  pass "an unreadable register stops add and is left untouched"
}

fm_test_run test_add_records_one_row_with_every_field test_a_row_may_be_recorded_for_another_home \
  test_memory_and_none_are_accepted test_malformed_specs_are_refused \
  test_a_regex_may_hold_a_semicolon_and_options_follow_it test_a_duplicate_id_is_refused_and_retire_keeps_the_row \
  test_list_shows_active_rows_and_all_on_request test_an_unreadable_register_is_not_overwritten
