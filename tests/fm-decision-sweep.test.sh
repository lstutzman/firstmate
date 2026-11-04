#!/usr/bin/env bash
# tests/fm-decision-sweep.test.sh - bin/fm-decision-sweep.sh closes open
# needs-decision lines whose key names a PR-subject ask and whose named PRs
# have all merged, and nothing else. A fake gh on PATH answers `gh pr view <url> --json ...` from per-URL
# JSON files; a URL with no file makes the fake fail like an unreachable forge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-decision-sweep-tests)
SWEEP="$ROOT/bin/fm-decision-sweep.sh"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
PRS="$TMP_ROOT/prs"
mkdir -p "$PRS"
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "pr view" ] || exit 2
f="$FAKE_GH_PRS/$(printf '%s' "$3" | tr '/:' '__')"
[ -f "$f" ] || { echo "gh: could not resolve to a PullRequest" >&2; exit 1; }
cat "$f"
SH
chmod +x "$FAKEBIN/gh"
export FAKE_GH_PRS="$PRS"
export PATH="$FAKEBIN:$PATH"

pr() {  # <n> <state> [mergedAt] [closedAt] - defines https://github.com/o/r/pull/<n>
  local json
  json=$(printf '{"state":"%s","mergedAt":%s,"closedAt":%s}' "$2" \
    "$([ -n "${3:-}" ] && printf '"%s"' "$3" || printf null)" \
    "$([ -n "${4:-}" ] && printf '"%s"' "$4" || printf null)")
  printf '%s' "$json" > "$PRS/https___github.com_o_r_pull_$1"
}
U() { printf 'https://github.com/o/r/pull/%s' "$1"; }

# A fresh home whose single status file holds the lines on stdin.
mkhome() {  # <name>
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state"
  cat > "$h/state/t.status"
  printf '%s' "$h"
}
sweep() { FM_HOME=$1 bash "$SWEEP" "${@:2}"; }
open_keys() { status_open_decisions "$1/state/t.status" | cut -f1 | tr '\n' ' '; }

pr 1 MERGED 2026-10-22T10:00:00Z
pr 2 CLOSED "" 2026-10-23T11:00:00Z
pr 3 OPEN
pr 4 MERGED 2026-10-24T12:00:00Z

test_verdicts_and_skips() {
  local h out
  h=$(mkhome verdicts <<EOF
needs-decision [at=1790000001] [key=pc2701-merge]: merge $(U 1)?
needs-decision [at=1790000002] [key=merge-closed]: merge $(U 2)?
needs-decision [at=1790000003] [key=merge-open]: merge $(U 3)?
needs-decision [at=1790000004] [key=merge-mixed]: merge $(U 1) and $(U 3)?
needs-decision [at=1790000005] [key=merge-unreadable]: merge $(U 99)?
needs-decision [at=1790000006] [key=review-both]: review $(U 1) and $(U 4)
needs-decision [at=1790000007] [key=release-1720-go]: $(U 1) merged to main; go for production deploy?
needs-decision [at=1790000008] [key=merge-handoff-12]: $(U 4) is ready to merge
needs-decision [at=1790000009] [key=emerged-x]: $(U 1)
needs-decision [at=1790000010] [key=captain-hold-x]: hold on $(U 1)
needs-decision [at=1790000011] [key=pending-reply-x]: pending-reply-missed: $(U 1)
needs-decision [at=1790000012] [key=no-url]: pick a color, see PR 1 and #1
blocked [at=1790000013] [key=blocker]: waiting on $(U 1)
EOF
  )
  out=$(sweep "$h")
  assert_contains "$out" "key=pc2701-merge verdict=settled" "merge key with its PR merged settles"
  assert_contains "$out" "key=merge-closed verdict=manual prs=$(U 2)=CLOSED" "closed-unmerged PR does not settle a merge ask"
  assert_contains "$out" "key=merge-open verdict=open" "open PR stays open"
  assert_contains "$out" "key=merge-mixed verdict=open" "one open PR keeps the decision open"
  assert_contains "$out" "key=merge-unreadable verdict=unreadable" "unreadable PR is reported"
  assert_contains "$out" "key=review-both verdict=settled" "every named PR merged"
  assert_contains "$out" "key=release-1720-go verdict=manual prs=$(U 1)=MERGED" "a go ask that only mentions a merged PR is manual"
  assert_contains "$out" "key=merge-handoff-12 verdict=settled" "merge handoff settles"
  assert_contains "$out" "key=emerged-x verdict=manual" "a key part must match whole"
  assert_not_contains "$out" "captain-hold-x" "captain-hold keys are never candidates"
  assert_not_contains "$out" "pending-reply-x" "pending-reply keys are never candidates"
  assert_not_contains "$out" "key=no-url" "decisions without a PR URL are never candidates"
  assert_not_contains "$out" "key=blocker" "blocked entries are never candidates"
  assert_contains "$out" "candidates=9 settled=3 still-open=2 manual=3 unreadable=1 truncated=0 skipped-reserved-key=2 skipped-no-pr-url=1 failed-to-close=0" "totals"
  pass "dry run reports settled, open, manual, unreadable and skipped decisions"
}

test_dry_run_changes_nothing() {
  local h before after
  h=$(mkhome dryrun <<EOF
needs-decision [at=1790000001] [key=k]: merge $(U 1)?
EOF
  )
  before=$(cksum < "$h/state/t.status")
  sweep "$h" > /dev/null
  after=$(cksum < "$h/state/t.status")
  assert_equals "$before" "$after" "dry run left the status file alone"
  pass "dry run changes nothing"
}

test_apply_closes_only_settled_and_is_idempotent() {
  local h out second
  h=$(mkhome apply <<EOF
needs-decision [at=1790000001] [key=merge-one]: merge $(U 1)?
needs-decision [at=1790000002] [key=merge-closed]: merge $(U 2)?
needs-decision [at=1790000003] [key=merge-mixed]: merge $(U 1) and $(U 3)?
needs-decision [at=1790000004] [key=merge-unreadable]: merge $(U 99)?
needs-decision [at=1790000005] [key=release-1720-go]: $(U 1) merged to main; go for production deploy?
needs-decision [at=1790000006] [key=captain-hold-x]: hold on $(U 1)
needs-decision [at=1790000007] [key=no-url]: pick a color
needs-decision [at=1790000008] [key=land-two]: land $(U 1) and $(U 4)
EOF
  )
  out=$(sweep "$h" --apply) || fail "apply exited nonzero: $out"
  assert_equals "merge-closed merge-mixed merge-unreadable release-1720-go captain-hold-x no-url " "$(open_keys "$h")" "only settled keys left the fold"
  assert_grep "resolved [key=merge-one] [at=" "$h/state/t.status" "resolved line carries the exact key and a stamp"
  assert_grep "decision-sweep: $(U 1) merged 2026-10-22T10:00:00Z" "$h/state/t.status" "merged evidence"
  assert_grep "decision-sweep: $(U 1) merged 2026-10-22T10:00:00Z; $(U 4) merged 2026-10-24T12:00:00Z" "$h/state/t.status" "every PR is cited"
  second=$(cksum < "$h/state/t.status")
  out=$(sweep "$h" --apply) || fail "re-apply exited nonzero"
  assert_equals "$second" "$(cksum < "$h/state/t.status")" "re-apply appended nothing"
  assert_contains "$out" "settled=0" "re-apply finds nothing settled"
  pass "apply closes only settled decisions and re-apply is a no-op"
}

test_mixed_prs_close_once_all_land() {
  local h
  h=$(mkhome mixed <<EOF
needs-decision [at=1790000001] [key=merge-mixed]: merge $(U 1) and $(U 5)?
EOF
  )
  pr 5 OPEN
  sweep "$h" --apply > /dev/null
  assert_equals "merge-mixed " "$(open_keys "$h")" "still open while one PR is open"
  pr 5 MERGED 2026-10-25T09:00:00Z
  sweep "$h" --apply > /dev/null
  assert_equals "" "$(open_keys "$h")" "closed once every named PR landed"
  assert_grep "$(U 1) merged 2026-10-22T10:00:00Z; $(U 5) merged 2026-10-25T09:00:00Z" "$h/state/t.status" "both PRs are cited"
  pass "a mixed decision closes only when its last PR lands"
}

test_unkeyed_lines_are_manual() {
  local h out
  h=$(mkhome unkeyed <<EOF
needs-decision [at=1792000001]: merge $(U 1)?
needs-decision [at=1700000000]: older unkeyed $(U 1)
EOF
  )
  out=$(sweep "$h" --apply)
  assert_contains "$out" "key=u-1792000001 verdict=manual" "synthetic key is manual"
  assert_contains "$out" "key=default verdict=manual" "default key is manual"
  assert_equals "u-1792000001 default " "$(open_keys "$h")" "unkeyed decisions stay open"
  pass "unkeyed decisions are left for a manual call"
}

test_truncated_note_is_never_trusted() {
  local h out
  h=$(mkhome truncated <<EOF
needs-decision [at=1790000001] [key=merge-cut]: merge $(U 1)0 [truncated]
needs-decision [at=1790000002] [key=merge-cut-host]: merge $(U 1) and https://github.com/o/r/pu [truncated]
needs-decision [at=1790000003] [key=merge-cut-pull]: merge $(U 1) and https://github.com/o/r/pull/ [truncated]
needs-decision [at=1790000004] [key=merge-cut-text]: merge $(U 1) and the other one th [truncated]
EOF
  )
  out=$(sweep "$h" --apply)
  assert_contains "$out" "key=merge-cut verdict=truncated" "cut URL is not looked up"
  assert_contains "$out" "key=merge-cut-host verdict=truncated" "URL cut mid-host leaves the note truncated"
  assert_contains "$out" "key=merge-cut-pull verdict=truncated" "URL cut after pull/ leaves the note truncated"
  assert_contains "$out" "key=merge-cut-text verdict=truncated" "a cut after a whole merged URL is still truncated"
  assert_equals "merge-cut merge-cut-host merge-cut-pull merge-cut-text " "$(open_keys "$h")" "cut decisions stay open"
  pass "a note cut by the line cap is never settled"
}

test_ledger_hook_runs_when_configured() {
  local h
  h=$(mkhome ledger <<EOF
needs-decision [at=1790000001] [key=merge-k]: merge $(U 1)?
EOF
  )
  mkdir -p "$h/config"
  : > "$h/config/fleet-ledger"
  sweep "$h" --apply > /dev/null
  assert_grep '"state":"resolved","key":"merge-k"' "$h/state/fleet-ledger.jsonl" "fleet ledger recorded the appended line"
  pass "fleet ledger hook runs when config/fleet-ledger exists"
}

test_verdicts_and_skips
test_dry_run_changes_nothing
test_apply_closes_only_settled_and_is_idempotent
test_mixed_prs_close_once_all_land
test_unkeyed_lines_are_manual
test_truncated_note_is_never_trusted
test_ledger_hook_runs_when_configured
