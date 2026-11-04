#!/usr/bin/env bash
# Behavior tests for bin/fm-office-authority-lib.sh: whether a home is an
# office, and the authority record an office may act on. bin/fm-spawn.sh and
# bin/fm-pr-merge.sh enforce what these functions return; their own suites
# cover that enforcement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-office-authority)
LIB="$ROOT/bin/fm-office-authority-lib.sh"

# shellcheck disable=SC2054 # Commas are inside record values, not separators.
GOOD=(id=quartermaster dispatch=firstmate,skills merge=firstmate merge-via=skills=slarti
  auto-merge-classes=none wip=2
  admission-sha256=firstmate:0000000000000000000000000000000000000000000000000000000000000000)

# resolve <home>: prints "<rc> <office-id> <error>" from fm_office_resolve.
resolve() {
  bash -c '. "$1"; rc=0; fm_office_resolve "$2" "$2/data" "$2/config" || rc=$?; printf "%s|%s|%s\n" "$rc" "$FM_OFFICE_ID" "$FM_OFFICE_ERROR"' _ "$LIB" "$1"
}

expect_not_office() {  # <home> <label>
  assert_equals "0||" "$(resolve "$1")" "$2: a home that is not an office"
}

expect_refused() {  # <home> <label> <error-fragment>
  local out
  out=$(resolve "$1")
  case "$out" in 1\|\|*) ;; *) fail "$2: expected a refusal, got '$out'" ;; esac
  assert_contains "$out" "$3" "$2: refusal reason"
  assert_contains "$out" "bin/fm-office.sh ensure" "$2: refusal names the repair"
}

test_homes_that_are_not_offices() {
  local h="$TMP_ROOT/main"
  mkdir -p "$h/data" "$h/config"
  expect_not_office "$h" "main home"
  h="$TMP_ROOT/plain-mate"
  mkdir -p "$h/data" "$h/config"
  printf 'slarti\n' > "$h/.fm-secondmate-home"
  printf '# Charter\n\nIdle by default.\n' > "$h/data/charter.md"
  expect_not_office "$h" "plain second mate"
  printf '%s\n' fm-office-authority-v1 "${GOOD[@]}" > "$h/config/office-authority"
  expect_not_office "$h" "plain second mate with a stray authority record"
  pass "a main home and a plain second mate are not offices, even with a stray record"
}

test_inconsistent_signals_refuse() {
  local h
  h="$TMP_ROOT/no-sm"
  fm_write_office_home "$h" quartermaster
  mv "$h/.fm-secondmate-home" "$h/.gone"
  expect_refused "$h" "marker without .fm-secondmate-home" "not a seeded second mate"
  h="$TMP_ROOT/no-heading"
  fm_write_office_home "$h" quartermaster
  printf '# Charter\n' > "$h/data/charter.md"
  expect_refused "$h" "marker without heading" "lacks the"
  h="$TMP_ROOT/no-marker"
  fm_write_office_home "$h" quartermaster
  mv "$h/.fm-office" "$h/.gone"
  expect_refused "$h" "heading without marker" "no .fm-office marker"
  h="$TMP_ROOT/id-mismatch"
  fm_write_office_home "$h" quartermaster
  printf 'navigator\n' > "$h/.fm-office"
  expect_refused "$h" "id mismatch" "names office 'navigator'"
  h="$TMP_ROOT/symlink-marker"
  fm_write_office_home "$h" quartermaster
  mv "$h/.fm-office" "$h/office-id"
  ln -s office-id "$h/.fm-office"
  expect_refused "$h" "symlinked marker" "not a readable regular file"
  pass "every inconsistent combination of office signals refuses"
}

test_unpublished_or_unproven_record_refuses() {
  local h
  h="$TMP_ROOT/unpublished"
  fm_write_office_home "$h" quartermaster
  expect_refused "$h" "no record" "no published authority record"
  printf '%s\n' fm-office-authority-v1 "${GOOD[@]}" > "$h/config/office-authority"
  expect_refused "$h" "record without receipt" "no published authority record"
  h="$TMP_ROOT/stale"
  fm_write_office_home "$h" quartermaster "${GOOD[@]}"
  sed -i.bak 's/^wip=2$/wip=9/' "$h/config/office-authority"
  expect_refused "$h" "edited after publish" "diverges from the receipt"
  h="$TMP_ROOT/absent"
  fm_write_office_home "$h" quartermaster "${GOOD[@]}"
  mv "$h/config/office-authority" "$h/config/.gone"
  (. "$ROOT/bin/fm-config-inherit-lib.sh"; fm_inherit_receipt_commit "$h/config/.fm-inherit-office-authority.generation" "$h/config/office-authority")
  expect_refused "$h" "published absence" "published no authority"
  pass "a missing, unproven, or absent authority record refuses"
}

test_valid_record_loads() {
  local h="$TMP_ROOT/valid" out
  fm_write_office_home "$h" quartermaster "${GOOD[@]}"
  assert_equals "0|quartermaster|" "$(resolve "$h")" "valid record"
  out=$(bash -c '. "$1"; fm_office_resolve "$2" "$2/data" "$2/config"; printf "%s;%s;%s;%s;%s\n" "$FM_OFFICE_DISPATCH" "$FM_OFFICE_MERGE" "$FM_OFFICE_MERGE_VIA" "$FM_OFFICE_WIP" "$FM_OFFICE_AUTO_MERGE_CLASSES"' _ "$LIB" "$h")
  assert_equals "firstmate,skills;firstmate;skills=slarti;2;" "$out" "loaded authority"
  pass "a published, proven record loads the office's authority"
}

test_malformed_record_refuses() {
  local name line h
  while IFS='|' read -r name line; do
    h="$TMP_ROOT/bad-$name"
    local -a rec=()
    local kv
    for kv in "${GOOD[@]}"; do
      [ "${kv%%=*}" = "${line%%=*}" ] || rec+=("$kv")
    done
    [ "$line" = "-" ] || rec+=("$line")
    fm_write_office_home "$h" quartermaster "${rec[@]}"
    case "$(resolve "$h")" in 1\|\|*) ;; *) fail "malformed record $name was accepted" ;; esac
  done <<'EOF'
auto-class|auto-merge-classes=authority
other-id|id=navigator
wip-zero|wip=0
merge-outside|merge=nuggets
via-overlap|merge-via=firstmate=slarti
no-sha|admission-sha256=
sha-other|admission-sha256=skills:0000000000000000000000000000000000000000000000000000000000000000
no-dispatch|dispatch=
unknown|colour=blue
EOF
  h="$TMP_ROOT/bad-missing-key"
  fm_write_office_home "$h" quartermaster "${GOOD[@]:0:5}"
  expect_refused "$h" "missing key" "has no wip= line"
  pass "a malformed record refuses, including any auto-merge class"
}

test_admission_digest() {
  local c="$TMP_ROOT/digest" a b
  mkdir -p "$c/admission"
  digest() { bash -c '. "$1"; fm_office_admission_digest "$2" "$3"' _ "$LIB" "$c" "$1"; }
  digest fm >/dev/null && fail "a missing admission config produced a digest"
  printf 'command=x\nclasses=authority\n' > "$c/admission/fm"
  a=$(digest fm)
  [[ "$a" =~ ^[0-9a-f]{64}$ ]] || fail "digest is not a sha256: $a"
  assert_equals "$a" "$(digest fm)" "digest is stable"
  printf 'bin/** authority\n' > "$c/admission/fm.rules"
  b=$(digest fm)
  assert_not_equals "$a" "$b" "adding the rules file changes the digest"
  printf 'AGENTS.md authority\n' > "$c/admission/fm.rules"
  assert_not_equals "$b" "$(digest fm)" "editing the rules file changes the digest"
  pass "the admission digest covers the config and its rules file"
}

test_live_tasks() {
  local s="$TMP_ROOT/live-state" out
  mkdir -p "$s"
  fm_write_meta "$s/a.meta" kind=ship
  fm_write_meta "$s/b.meta" kind=scout
  fm_write_meta "$s/c.meta" kind=secondmate
  fm_write_meta "$s/self.meta" kind=ship
  out=$(bash -c '. "$1"; fm_office_live_tasks "$2" self; printf "%s %s\n" "$FM_OFFICE_LIVE" "$FM_OFFICE_LIVE_IDS"' _ "$LIB" "$s")
  assert_equals "2 a, b" "$out" "live task count"
  pass "live tasks count every ship and scout but this one and any second mate"
}

test_homes_that_are_not_offices
test_inconsistent_signals_refuse
test_unpublished_or_unproven_record_refuses
test_valid_record_loads
test_malformed_record_refuses
test_admission_digest
test_live_tasks
