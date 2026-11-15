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
state= limit=30 search=
while [ $# -gt 0 ]; do
  case $1 in --state) state=$2 ;; --limit) limit=$2 ;; --search) search=1 ;; esac
  shift
done
# GitHub's search API returns at most 1000 results, whatever --limit asks for.
[ -z "$search" ] || [ "$limit" -le 1000 ] || limit=1000
python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))[:int(sys.argv[2])]))' "$FAKE_GH_DATA/$state.json" "$limit"
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

test_closed_list_at_the_search_cap_is_unknown() {
  local args=(5 --) i
  for ((i = 0; i < 1200; i++)); do args+=(48:24); done
  timeline "${args[@]}"
  assert_contains "$("$DRAIN" state "$PROJECT")" "unknown o/r 1000 or more PRs closed in 14 days" \
    "a closed list cut at GitHub's 1000-result search cap was walked as if complete"
  pass "a closed list that reaches GitHub's 1000-result search cap reads as unknown"
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

brief() {  # <id> <mode> <args...>
  local id=$1 mode=$2
  shift 2
  FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-brief.sh" "$id" r --mode "$mode" --project "$PROJECT" "$@" >"$TMP_ROOT/brief.out" 2>&1
}

# The PR drain check line a brief hands its worker, or nothing.
drain_check() {  # <id>
  # shellcheck disable=SC2016 # literal backticks, not an expansion
  sed -n 's/^PR drain check: .*run `\([^`]*\)` from your worktree\.$/\1/p' "$TMP_ROOT/home/data/$1/brief.md"
}

test_brief_tells_workers_to_check_drain_before_a_pr() {
  local home="$TMP_ROOT/home" id check
  mkdir -p "$home/data"
  peak_then 0
  for id in calm-nm:no-mistakes calm-direct:direct-PR; do
    brief "${id%%:*}" "${id#*:}" || fail "the ${id#*:} brief did not scaffold: $(cat "$TMP_ROOT/brief.out")"
    check=$(drain_check "${id%%:*}")
    [ -n "$check" ] || fail "a ${id#*:} brief written outside drain has no PR drain check"
    assert_no_regex "^# PR drain$" "$home/data/${id%%:*}/brief.md" "a brief written outside drain has a PR drain section"
  done
  # The command the brief hands the worker reads the live state from the worktree.
  peak_then 7
  assert_equals "on o/r 7" "$(cd "$PROJECT" && eval "$check")" "the brief's drain check did not read the live drain"
  peak_then 0
  assert_equals "off o/r 0" "$(cd "$PROJECT" && eval "$check")" "the brief's drain check did not see the drain end"
  brief local local-only || fail "the local-only brief did not scaffold"
  assert_no_grep "PR drain" "$home/data/local/brief.md" "a local-only brief mentions the PR drain"
  peak_then 7
  brief drained no-mistakes || fail "the drained brief did not scaffold"
  grep -qx "# PR drain" "$home/data/drained/brief.md" || fail "a brief written in drain has no PR drain section"
  [ -n "$(drain_check drained)" ] || fail "a brief written in drain has no PR drain check"
  for id in cve restack red-gate-fix returned-pr-fix review; do
    brief "x-$id" no-mistakes --pr-drain "$id" || fail "the $id brief did not scaffold"
    assert_no_grep "PR drain check" "$home/data/x-$id/brief.md" "a $id brief was told to check the drain"
    assert_no_regex "^# PR drain$" "$home/data/x-$id/brief.md" "a $id brief in drain was told not to open a PR"
    assert_grep "PR drain: $id" "$home/data/x-$id/brief.md" "--pr-drain did not record $id"
  done
  brief x-wolverine no-mistakes --pr-drain wolverine || fail "the wolverine brief did not scaffold"
  grep -qx "# PR drain" "$home/data/x-wolverine/brief.md" || fail "a wolverine brief in drain has no PR drain section"
  [ -n "$(drain_check x-wolverine)" ] || fail "a wolverine brief in drain does not carry the drain check"
  brief bad no-mistakes --pr-drain feature && fail "an unknown --pr-drain class was accepted"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" scouted r --scout --pr-drain cve >/dev/null 2>&1 &&
    fail "--pr-drain was accepted on a scout"
  pass "PR-opening briefs carry a live drain check, landing jobs and cve skip it, and --pr-drain is validated"
}

fm_test_run \
  test_twenty_open_turns_drain_on \
  test_drain_holds_from_nineteen_down_to_one \
  test_zero_open_turns_drain_off \
  test_a_zero_since_the_peak_keeps_drain_off \
  test_unreadable_or_undecided_history_is_unknown \
  test_closed_list_at_the_search_cap_is_unknown \
  test_non_github_origin_is_not_applicable \
  test_classes_are_validated \
  test_brief_tells_workers_to_check_drain_before_a_pr
