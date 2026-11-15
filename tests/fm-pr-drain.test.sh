#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-drain.py (the open-PR drain state of a project's GitHub repository) and the
# brief text bin/fm-brief.sh writes from it. A fake gh on PATH answers `gh pr list --state open` from
# open.json and `--state closed` from closed.json, so each case drives a PR timeline with no network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-drain)
DRAIN="$ROOT/bin/fm-pr-drain.py"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
GHDATA="$TMP_ROOT/gh"
mkdir -p "$GHDATA"
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
[ -z "${FAKE_GH_FAIL:-}" ] || { echo "HTTP 502: bad gateway" >&2; exit 1; }
state=
while [ $# -gt 0 ]; do [ "$1" = --state ] && state=$2; shift; done
cat "$FAKE_GH_DATA/$state.json"
SH
chmod +x "$FAKEBIN/gh"
export FAKE_GH_DATA="$GHDATA" PATH="$FAKEBIN:$PATH"

PROJECT="$TMP_ROOT/project"
fm_git_init_commit "$PROJECT"
git -C "$PROJECT" remote add origin git@github.com:o/r.git

# timeline <open-created-hours-ago...> -- <closed created:closed hours-ago...>
timeline() {
  python3 -I - "$GHDATA" "$@" <<'PY'
import json, sys, time
def iso(hours):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() - float(hours) * 3600))
out, args = sys.argv[1], sys.argv[2:]
cut = args.index('--')
json.dump([{'createdAt': iso(h)} for h in args[:cut]], open(out + '/open.json', 'w'))
json.dump([{'createdAt': iso(c), 'closedAt': iso(d)} for c, d in (a.split(':') for a in args[cut + 1:])],
          open(out + '/closed.json', 'w'))
PY
}

# A peak of 20 PRs opened 10 hours ago, of which all but <open> closed an hour ago.
peak_then() {  # <open>
  local args=() i
  for ((i = 0; i < $1; i++)); do args+=(10); done
  args+=(--)
  for ((i = $1; i < 20; i++)); do args+=(10:1); done
  timeline "${args[@]}"
}

test_twenty_open_turns_drain_on() {
  local args=() i
  for ((i = 0; i < 20; i++)); do args+=(3); done
  timeline "${args[@]}" --
  assert_equals "on o/r 20" "$("$DRAIN" state "$PROJECT")" "20 open PRs did not read as drain on"
  pass "20 open PRs turn the drain on"
}

test_drain_holds_from_nineteen_down_to_one() {
  local n
  for n in 19 18 17 16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1; do
    peak_then "$n"
    assert_equals "on o/r $n" "$("$DRAIN" state "$PROJECT")" "$n open PRs after a peak of 20 did not stay in drain"
  done
  pass "after a peak of 20 the drain holds at every count from 19 down to 1"
}

test_zero_open_turns_drain_off() {
  peak_then 0
  assert_equals "off o/r 0" "$("$DRAIN" state "$PROJECT")" "0 open PRs did not end the drain"
  pass "0 open PRs end the drain"
}

test_a_zero_since_the_peak_keeps_drain_off() {
  # 20 opened and closed 30 hours ago, then 0, then 5 new PRs 2 hours ago.
  local args=(2 2 2 2 2 --) i
  for ((i = 0; i < 20; i++)); do args+=(40:30); done
  timeline "${args[@]}"
  assert_equals "off o/r 5" "$("$DRAIN" state "$PROJECT")" "5 open PRs after a return to 0 read as drain on"
  pass "a return to 0 after the peak keeps later PRs out of drain"
}

test_unreadable_or_undecided_history_is_unknown() {
  local out
  timeline 5 5 --
  out=$(FAKE_GH_FAIL=1 "$DRAIN" state "$PROJECT")
  assert_contains "$out" "unknown o/r GitHub unreadable: HTTP 502" "an unreadable GitHub did not read as unknown: $out"
  timeline 900 900 --
  out=$("$DRAIN" state "$PROJECT")
  assert_contains "$out" "unknown o/r open count stayed between 1 and 19" "a window with no 0 or 20 did not read as unknown: $out"
  pass "an unreadable GitHub or a history with no 0 or 20 in the window reads as unknown"
}

test_non_github_origin_is_not_applicable() {
  local other="$TMP_ROOT/other"
  fm_git_init_commit "$other"
  git -C "$other" remote add origin "file://$TMP_ROOT/nowhere.git"
  assert_equals "none" "$(FAKE_GH_FAIL=1 "$DRAIN" state "$other")" "a non-GitHub origin was queried"
  pass "a clone whose origin is not on github.com is outside the rule"
}

test_classes_are_validated() {
  local value
  for value in production-outage cve wolverine lee-research officer scheduled restack red-gate-fix returned-pr-fix review; do
    "$DRAIN" class "$value" || fail "$value was not accepted as a drain class"
  done
  "$DRAIN" class feature && fail "an unknown drain class was accepted"
  pass "every exemption class and landing job is accepted and nothing else"
}

brief() {  # <id> <args...>
  local id=$1
  shift
  FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-brief.sh" "$id" r --mode no-mistakes --project "$PROJECT" "$@" >"$TMP_ROOT/brief.out" 2>&1
}

test_brief_tells_workers_to_push_only_in_drain() {
  local home="$TMP_ROOT/home"
  mkdir -p "$home/data"
  peak_then 7
  brief drained || fail "the drained brief did not scaffold: $(cat "$TMP_ROOT/brief.out")"
  assert_grep "# PR drain" "$home/data/drained/brief.md" "a brief written in drain has no PR drain section"
  assert_grep "do not open a pull request" "$home/data/drained/brief.md" "the drain section does not forbid a new PR"
  brief exempt --pr-drain cve || fail "the cve brief did not scaffold"
  assert_no_regex "^# PR drain$" "$home/data/exempt/brief.md" "a cve brief in drain was told not to open a PR"
  assert_grep "PR drain: cve" "$home/data/exempt/brief.md" "--pr-drain did not record its class"
  brief landing --pr-drain restack || fail "the restack brief did not scaffold"
  assert_grep "# PR drain" "$home/data/landing/brief.md" "a restack brief in drain has no PR drain section"
  peak_then 0
  brief calm || fail "the brief outside drain did not scaffold"
  assert_no_grep "PR drain" "$home/data/calm/brief.md" "a brief written outside drain mentions the drain"
  brief bad --pr-drain feature && fail "an unknown --pr-drain class was accepted"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" scouted r --scout --pr-drain cve >/dev/null 2>&1 &&
    fail "--pr-drain was accepted on a scout"
  pass "the brief carries push-only text only in drain, never for production-outage or cve, and validates --pr-drain"
}

fm_test_run \
  test_twenty_open_turns_drain_on \
  test_drain_holds_from_nineteen_down_to_one \
  test_zero_open_turns_drain_off \
  test_a_zero_since_the_peak_keeps_drain_off \
  test_unreadable_or_undecided_history_is_unknown \
  test_non_github_origin_is_not_applicable \
  test_classes_are_validated \
  test_brief_tells_workers_to_push_only_in_drain
