#!/usr/bin/env bash
# Behavior tests for config/brief-include.md inheritance: the primary's text is
# every secondmate home's base, and the home's own lines below that base are
# kept across every later push, on both the local and the remote route.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-brief-include)

new_home_pair() {
  local base="$TMP_ROOT/$1"
  mkdir -p "$base/primary/config" "$base/second/config"
  printf '%s\n' "$base/primary|$base/second"
}

push_local() {  # <primary> <second> <report>
  FM_INHERITABLE_CONFIG=brief-include.md FM_CONFIG_INHERIT_REPORT="$3" \
    propagate_inheritable_config "$1/config" "$2/config" "$1"
}

report_status() {  # <report>
  awk -F '\t' '$1 == "brief-include.md" { s = $2 } END { print s }' "$1"
}

expect_bytes() {  # <file> <expected-bytes> <message>
  [ "$(cat "$1"; printf x)" = "$2"x ] || fail "$3"$'\n'"got:"$'\n'"$(cat "$1")"
}

test_local_push_keeps_child_lines() {
  local rec primary second report before
  rec=$(new_home_pair local)
  primary=${rec%%|*}
  second=${rec#*|}
  report="$TMP_ROOT/local.report"

  printf '%s\n' "base rule one" > "$primary/config/brief-include.md"
  printf '%s\n' "child rule A" > "$second/config/brief-include.md"
  : > "$report"
  push_local "$primary" "$second" "$report" || fail "first local push failed"
  [ "$(report_status "$report")" = pushed ] || fail "first local push did not report pushed"
  expect_bytes "$second/config/brief-include.md" $'base rule one\nchild rule A\n' \
    "first push did not put the base above the child's existing lines"

  printf '%s\n' "child rule B" >> "$second/config/brief-include.md"
  before="$TMP_ROOT/local.before"
  cp "$second/config/brief-include.md" "$before"
  : > "$report"
  push_local "$primary" "$second" "$report" || fail "unchanged-base local push failed"
  [ "$(report_status "$report")" = unchanged ] || fail "an unchanged base re-push did not report unchanged"
  cmp -s "$before" "$second/config/brief-include.md" \
    || fail "an unchanged base re-push changed the child's file"

  printf '%s\n' "base rule one, revised" "base rule two" > "$primary/config/brief-include.md"
  : > "$report"
  push_local "$primary" "$second" "$report" || fail "changed-base local push failed"
  [ "$(report_status "$report")" = pushed ] || fail "a changed base did not report pushed"
  expect_bytes "$second/config/brief-include.md" \
    $'base rule one, revised\nbase rule two\nchild rule A\nchild rule B\n' \
    "a changed base did not replace the old base while keeping the child's lines"

  rm -f "$primary/config/brief-include.md"
  : > "$report"
  push_local "$primary" "$second" "$report" || fail "absent-base local push failed"
  expect_bytes "$second/config/brief-include.md" $'child rule A\nchild rule B\n' \
    "a removed primary file did not leave exactly the child's own lines"
  pass "local push puts the primary's text above the child's lines and keeps them on every re-push"
}

test_local_first_push_does_not_duplicate_a_verbatim_copy() {
  local rec primary second report
  rec=$(new_home_pair verbatim)
  primary=${rec%%|*}
  second=${rec#*|}
  report="$TMP_ROOT/verbatim.report"
  printf '%s\n' "base rule one" > "$primary/config/brief-include.md"
  printf '%s\n' "base rule one" "child rule A" > "$second/config/brief-include.md"
  : > "$report"
  push_local "$primary" "$second" "$report" || fail "verbatim first push failed"
  expect_bytes "$second/config/brief-include.md" $'base rule one\nchild rule A\n' \
    "a child that already began with the base got the base twice"
  pass "a first push into a home that already copied the base verbatim adds no duplicate"
}

test_base_without_trailing_newline_is_stable() {
  local rec primary second report before
  rec=$(new_home_pair no-newline)
  primary=${rec%%|*}
  second=${rec#*|}
  report="$TMP_ROOT/no-newline.report"
  printf '%s' "base rule one" > "$primary/config/brief-include.md"
  printf '%s\n' "child rule A" > "$second/config/brief-include.md"
  : > "$report"
  push_local "$primary" "$second" "$report" || fail "no-newline first push failed"
  expect_bytes "$second/config/brief-include.md" $'base rule one\nchild rule A\n' \
    "a base without a trailing newline was joined onto the child's first line"
  before="$TMP_ROOT/no-newline.before"
  cp "$second/config/brief-include.md" "$before"
  push_local "$primary" "$second" "$report" || fail "no-newline re-push failed"
  cmp -s "$before" "$second/config/brief-include.md" \
    || fail "a base without a trailing newline drifted on re-push"
  pass "a base without a trailing newline composes and re-pushes byte-stably"
}

remote_push() {  # <home> <payload-or-empty> <generation>
  local home=$1 payload=$2 generation=$3 empty bytes hash
  if [ -n "$payload" ]; then
    bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
    hash=$(fm_inherit_sha256 "$payload") || fail "cannot hash remote payload"
    PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" \
      put config/brief-include.md "$bytes" "$hash" "$generation" < "$payload" 2>&1
  else
    empty="$TMP_ROOT/remote-empty"
    : > "$empty"
    hash=$(fm_inherit_sha256 "$empty") || fail "cannot hash empty payload"
    PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" \
      absent config/brief-include.md 0 "$hash" "$generation" < /dev/null 2>&1
  fi
}

test_remote_push_keeps_child_lines() {
  local home source out before
  home="$TMP_ROOT/remote/home"
  source="$TMP_ROOT/remote/source.md"
  mkdir -p "$home/config"
  printf '%s\n' "base rule one" > "$source"
  printf '%s\n' "child rule A" > "$home/config/brief-include.md"
  out=$(remote_push "$home" "$source" 1) || fail "remote first push failed: $out"
  assert_contains "$out" "pushed: config/brief-include.md" "remote first push did not publish"
  expect_bytes "$home/config/brief-include.md" $'base rule one\nchild rule A\n' \
    "remote first push did not put the base above the child's lines"

  printf '%s\n' "child rule B" >> "$home/config/brief-include.md"
  before="$TMP_ROOT/remote/before"
  cp "$home/config/brief-include.md" "$before"
  out=$(remote_push "$home" "$source" 2) || fail "remote unchanged-base push failed: $out"
  assert_contains "$out" "unchanged: config/brief-include.md" "remote unchanged base did not report unchanged"
  cmp -s "$before" "$home/config/brief-include.md" || fail "remote unchanged base changed the child's file"

  printf '%s\n' "base rule two" > "$source"
  out=$(remote_push "$home" "$source" 3) || fail "remote changed-base push failed: $out"
  expect_bytes "$home/config/brief-include.md" $'base rule two\nchild rule A\nchild rule B\n' \
    "remote changed base did not replace the old base while keeping the child's lines"

  out=$(remote_push "$home" "" 4) || fail "remote absent push failed: $out"
  expect_bytes "$home/config/brief-include.md" $'child rule A\nchild rule B\n' \
    "remote absent base did not leave exactly the child's own lines"
  pass "remote push puts the primary's text above the child's lines and keeps them on every re-push"
}

test_local_push_keeps_child_lines
test_local_first_push_does_not_duplicate_a_verbatim_copy
test_base_without_trailing_newline_is_stable
test_remote_push_keeps_child_lines

echo "# all fm-brief-include-inheritance tests passed"
