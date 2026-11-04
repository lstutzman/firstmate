#!/usr/bin/env bash
# tests/fm-decision-sweep.test.sh - bin/fm-decision-sweep.sh closes open
# merge-handoff-<n> decisions whose PR <n> merged, lists other all-merged
# decisions for review, closes those only when named with --key, and touches
# nothing else. A fake gh on PATH answers `gh pr view <url> --json ...` from
# per-URL JSON files; a URL with no file makes the fake fail like an unreachable forge.
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
pr 12 MERGED 2026-10-25T08:00:00Z

test_verdicts_and_skips() {
  local h out
  h=$(mkhome verdicts <<EOF
needs-decision [at=1790000001] [key=merge-handoff-12]: [handoff=slarti] $(U 12) is ready to merge
needs-decision [at=1790000002] [key=merge-handoff-4]: [handoff=slarti] $(U 12) is ready to merge
needs-decision [at=1790000003] [key=merge-handoff-1]: $(U 1) and $(U 4) are ready to merge
needs-decision [at=1790000004] [key=fm-sdlc-landing-truth]: PR 1 ($(U 1)) is merged. For PR 5 I need the landing-truth job first. Options: (a) wait (b) skip
needs-decision [at=1790000005] [key=release-1720-go]: $(U 1) merged to main; go for production deploy?
needs-decision [at=1790000006] [key=merge-handoff-2]: $(U 2) is ready to merge
needs-decision [at=1790000007] [key=merge-handoff-3]: $(U 3) is ready to merge
needs-decision [at=1790000008] [key=pc-mixed-merge]: merge $(U 1) and $(U 3)?
needs-decision [at=1790000009] [key=merge-handoff-99]: $(U 99) is ready to merge
needs-decision [at=1790000010] [key=captain-hold-x]: hold on $(U 1)
needs-decision [at=1790000011] [key=pending-reply-x]: pending-reply-missed: $(U 1)
needs-decision [at=1790000012] [key=no-url]: pick a color, see PR 1 and #1
blocked [at=1790000013] [key=blocker]: waiting on $(U 1)
EOF
  )
  out=$(sweep "$h")
  assert_contains "$out" "key=merge-handoff-12 verdict=settled" "merge handoff for its own merged PR settles"
  assert_contains "$out" "key=merge-handoff-4 verdict=review" "merge handoff naming another PR is only reviewed"
  assert_contains "$out" "key=merge-handoff-1 verdict=review" "merge handoff naming two PRs is only reviewed"
  assert_contains "$out" "key=fm-sdlc-landing-truth verdict=review prs=$(U 1)=MERGED note=PR 1 (" "an options call naming a merged PR is listed with its note"
  assert_contains "$out" "key=release-1720-go verdict=review" "a go ask naming a merged PR is only reviewed"
  assert_contains "$out" "key=merge-handoff-2 verdict=manual prs=$(U 2)=CLOSED" "closed-unmerged PR settles nothing"
  assert_contains "$out" "key=merge-handoff-3 verdict=open" "open PR stays open"
  assert_contains "$out" "key=pc-mixed-merge verdict=open" "one open PR keeps the decision open"
  assert_contains "$out" "key=merge-handoff-99 verdict=unreadable" "unreadable PR is reported"
  assert_contains "$out" "review: every named PR merged" "review items have their own heading"
  assert_not_contains "$out" "captain-hold-x" "captain-hold keys are never candidates"
  assert_not_contains "$out" "pending-reply-x" "pending-reply keys are never candidates"
  assert_not_contains "$out" "key=no-url" "decisions without a PR URL are never candidates"
  assert_not_contains "$out" "key=blocker" "blocked entries are never candidates"
  assert_contains "$out" "candidates=9 settled=1 closed-by-key=0 review=4 still-open=2 manual=1 unreadable=1 truncated=0 skipped-reserved-key=2 skipped-no-pr-url=1 refused-key=0 failed-to-close=0" "totals"
  pass "dry run reports settled, review, open, manual, unreadable and skipped decisions"
}

test_dry_run_changes_nothing() {
  local h before
  h=$(mkhome dryrun <<EOF
needs-decision [at=1790000001] [key=merge-handoff-1]: $(U 1) is ready to merge
EOF
  )
  before=$(cksum < "$h/state/t.status")
  sweep "$h" > /dev/null
  assert_equals "$before" "$(cksum < "$h/state/t.status")" "dry run left the status file alone"
  pass "dry run changes nothing"
}

test_key_needs_apply() {
  local h rc=0
  h=$(mkhome keyusage <<EOF
needs-decision [at=1790000001] [key=release-1720-go]: $(U 1) merged; go?
EOF
  )
  sweep "$h" --key release-1720-go > /dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "--key without --apply is a usage error"
  pass "--key needs --apply"
}

test_apply_closes_only_settled_and_is_idempotent() {
  local h out second
  h=$(mkhome apply <<EOF
needs-decision [at=1790000001] [key=merge-handoff-1]: $(U 1) is ready to merge
needs-decision [at=1790000002] [key=merge-handoff-2]: $(U 2) is ready to merge
needs-decision [at=1790000003] [key=release-1720-go]: $(U 1) merged to main; go for production deploy?
needs-decision [at=1790000004] [key=fm-sdlc-landing-truth]: PR 1 ($(U 1)) is merged. Options: (a) wait (b) skip
needs-decision [at=1790000005] [key=captain-hold-x]: hold on $(U 1)
needs-decision [at=1790000006] [key=no-url]: pick a color
EOF
  )
  out=$(sweep "$h" --apply) || fail "apply exited nonzero: $out"
  assert_equals "merge-handoff-2 release-1720-go fm-sdlc-landing-truth captain-hold-x no-url " "$(open_keys "$h")" "only the settled handoff left the fold"
  assert_grep "resolved [key=merge-handoff-1] [at=" "$h/state/t.status" "resolved line carries the exact key and a stamp"
  assert_grep "decision-sweep: $(U 1) merged 2026-10-22T10:00:00Z" "$h/state/t.status" "merged evidence"
  second=$(cksum < "$h/state/t.status")
  out=$(sweep "$h" --apply) || fail "re-apply exited nonzero"
  assert_equals "$second" "$(cksum < "$h/state/t.status")" "re-apply appended nothing"
  assert_contains "$out" "settled=0" "re-apply finds nothing settled"
  pass "apply closes only settled decisions and re-apply is a no-op"
}

test_key_closes_reviewed_decisions() {
  local h out
  h=$(mkhome keyed <<EOF
needs-decision [at=1790000001] [key=pc2701-merge]: merge $(U 1) and $(U 4) (legal)
needs-decision [at=1790000002] [key=fm-sdlc-landing-truth]: PR 1 ($(U 1)) is merged. Options: (a) wait (b) skip
needs-decision [at=1790000003] [key=release-1720-go]: $(U 1) merged to main; go?
EOF
  )
  out=$(sweep "$h" --apply --key pc2701-merge,fm-sdlc-landing-truth) || fail "keyed apply exited nonzero: $out"
  assert_contains "$out" "key=pc2701-merge verdict=closed-by-key" "listed review key is closed"
  assert_equals "release-1720-go " "$(open_keys "$h")" "only the listed keys left the fold"
  assert_grep "resolved [key=pc2701-merge] [at=" "$h/state/t.status" "keyed close is stamped"
  assert_grep "decision-sweep: $(U 1) merged 2026-10-22T10:00:00Z; $(U 4) merged 2026-10-24T12:00:00Z" "$h/state/t.status" "every PR is cited"
  pass "--apply --key closes exactly the listed review decisions"
}

test_key_refuses_unsettled() {
  local h out rc=0
  h=$(mkhome refuse <<EOF
needs-decision [at=1790000001] [key=pc-open-merge]: merge $(U 1) and $(U 3)?
needs-decision [at=1790000002] [key=pc-closed-merge]: merge $(U 2)?
needs-decision [at=1790000003] [key=captain-hold-x]: hold on $(U 1)
needs-decision [at=1790000004] [key=pc-cut-merge]: merge $(U 1) and https://github.com/o/r/pu [truncated]
EOF
  )
  out=$(sweep "$h" --apply --key pc-open-merge --key pc-closed-merge --key captain-hold-x --key pc-cut-merge --key gone 2>&1) || rc=$?
  assert_equals 1 "$rc" "a refused key fails the run"
  assert_contains "$out" "--key 'pc-open-merge' refused: verdict is open" "open PR refuses"
  assert_contains "$out" "--key 'pc-closed-merge' refused: verdict is manual" "closed-unmerged PR refuses"
  assert_contains "$out" "--key 'captain-hold-x' refused: reserved key" "reserved key refuses"
  assert_contains "$out" "--key 'pc-cut-merge' refused: note is truncated" "truncated note refuses"
  assert_contains "$out" "--key 'gone' refused: not an open needs-decision" "unknown key refuses"
  assert_equals "pc-open-merge pc-closed-merge captain-hold-x pc-cut-merge " "$(open_keys "$h")" "nothing was closed"
  pass "--key refuses decisions that are not review"
}

test_mixed_prs_close_once_all_land() {
  local h
  h=$(mkhome mixed <<EOF
needs-decision [at=1790000001] [key=merge-handoff-5]: $(U 5) is ready to merge
EOF
  )
  pr 5 OPEN
  sweep "$h" --apply > /dev/null
  assert_equals "merge-handoff-5 " "$(open_keys "$h")" "still open while the PR is open"
  pr 5 MERGED 2026-10-25T09:00:00Z
  sweep "$h" --apply > /dev/null
  assert_equals "" "$(open_keys "$h")" "closed once the PR merged"
  pass "a handoff closes only once its PR lands"
}

test_unkeyed_lines_need_a_key() {
  local h out
  h=$(mkhome unkeyed <<EOF
needs-decision [at=1792000001]: merge $(U 1)?
needs-decision [at=1700000000]: older unkeyed $(U 1)
EOF
  )
  out=$(sweep "$h" --apply)
  assert_contains "$out" "key=u-1792000001 verdict=review" "synthetic key is reviewed"
  assert_contains "$out" "key=default verdict=review" "default key is reviewed"
  assert_equals "u-1792000001 default " "$(open_keys "$h")" "unkeyed decisions stay open"
  sweep "$h" --apply --key u-1792000001,default > /dev/null || fail "keyed close of unkeyed lines failed"
  assert_equals "" "$(open_keys "$h")" "listed synthetic and default keys leave the fold"
  pass "unkeyed decisions close only when listed"
}

test_truncated_note_is_never_trusted() {
  local h out
  h=$(mkhome truncated <<EOF
needs-decision [at=1790000001] [key=merge-handoff-1]: $(U 1)0 [truncated]
needs-decision [at=1790000002] [key=pc-cut-host]: merge $(U 1) and https://github.com/o/r/pu [truncated]
needs-decision [at=1790000003] [key=pc-cut-pull]: merge $(U 1) and https://github.com/o/r/pull/ [truncated]
needs-decision [at=1790000004] [key=pc-cut-text]: merge $(U 1) and the other one th [truncated]
EOF
  )
  out=$(sweep "$h" --apply)
  assert_contains "$out" "key=merge-handoff-1 verdict=truncated" "cut URL is not looked up"
  assert_contains "$out" "key=pc-cut-host verdict=truncated" "URL cut mid-host leaves the note truncated"
  assert_contains "$out" "key=pc-cut-pull verdict=truncated" "URL cut after pull/ leaves the note truncated"
  assert_contains "$out" "key=pc-cut-text verdict=truncated" "a cut after a whole merged URL is still truncated"
  assert_equals "merge-handoff-1 pc-cut-host pc-cut-pull pc-cut-text " "$(open_keys "$h")" "cut decisions stay open"
  pass "a note cut by the line cap is never settled"
}

test_ledger_hook_runs_when_configured() {
  local h
  h=$(mkhome ledger <<EOF
needs-decision [at=1790000001] [key=merge-handoff-1]: $(U 1) is ready to merge
EOF
  )
  mkdir -p "$h/config"
  : > "$h/config/fleet-ledger"
  sweep "$h" --apply > /dev/null
  assert_grep '"state":"resolved","key":"merge-handoff-1"' "$h/state/fleet-ledger.jsonl" "fleet ledger recorded the appended line"
  pass "fleet ledger hook runs when config/fleet-ledger exists"
}

test_verdicts_and_skips
test_dry_run_changes_nothing
test_key_needs_apply
test_apply_closes_only_settled_and_is_idempotent
test_key_closes_reviewed_decisions
test_key_refuses_unsettled
test_mixed_prs_close_once_all_land
test_unkeyed_lines_need_a_key
test_truncated_note_is_never_trusted
test_ledger_hook_runs_when_configured
