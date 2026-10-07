#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh --stack: merging a GitHub stacked pull request
# set through the guarded merge path. Every case drives the real entrypoint
# against a stubbed gh that serves a three-layer stack (#1 on main, #2 on #1,
# #3 on #2, each owned by its own task) and records every forge call, so a case
# proves both what the run refused and that no merge request reached the forge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-stack-tests)

REPO_URL=https://github.com/example/repo
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
H3=3333333333333333333333333333333333333333
MERGE_COMMIT=4444444444444444444444444444444444444444
GATED_TREE=5555555555555555555555555555555555555555
OTHER_TREE=6666666666666666666666666666666666666666

# One live pull request view. Args: file head base [rollup-json] [draft]
write_pr_view() {
  local file=$1 head=$2 base=$3
  local rollup=${4:-'[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]'}
  local draft=${5:-false}
  printf '{"state":"OPEN","isDraft":%s,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s","baseRefName":"%s","statusCheckRollup":%s}\n' \
    "$draft" "$head" "$base" "$rollup" > "$file"
}

# The live stack GitHub reports. Each member is number:head_ref[:state[:draft]].
# Args: case_dir member...
write_stack() {
  local case_dir=$1 spec number ref state draft prs=''
  shift
  for spec in "$@"; do
    IFS=: read -r number ref state draft <<EOF
$spec
EOF
    prs="${prs:+$prs,}{\"number\":$number,\"state\":\"${state:-open}\",\"draft\":${draft:-false},\"merged_at\":null,\"head\":{\"ref\":\"$ref\",\"sha\":\"x\"}}"
  done
  printf '[{"id":9,"number":4,"open":true,"base":{"ref":"main"},"pull_requests":[%s]}]\n' "$prs" \
    > "$case_dir/stacks.json"
}

write_outcome() {  # <case_dir> <number> <merged true|false>
  if [ "$3" = true ]; then
    printf '%s\n' state=MERGED merged=true queued=false base=main > "$1/outcome-$2"
  else
    printf '%s\n' state=OPEN merged=false queued=false base=main > "$1/outcome-$2"
  fi
}

# A three-layer stack that satisfies every condition, its three tasks having
# recorded their pull requests and heads. Echoes the case dir.
make_stack_case() {
  local name=$1 case_dir n head
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/home/data" "$case_dir/home/config" "$case_dir/fakebin"
  fm_git_init_commit "$case_dir/wt"
  git -C "$case_dir/wt" update-ref refs/remotes/origin/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  cp "$ROOT/.tasks.toml" "$case_dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$case_dir/home/data/backlog.md"
  for n in 1 2 3; do
    case "$n" in 1) head=$H1 ;; 2) head=$H2 ;; 3) head=$H3 ;; esac
    fm_write_meta "$case_dir/state/task-b$n.meta" \
      "window=fm-task-b$n" \
      "worktree=$case_dir/wt" \
      "project=$case_dir/project" \
      "kind=ship" \
      "mode=no-mistakes" \
      "pr=$REPO_URL/pull/$n" \
      "pr_head=$head"
    write_outcome "$case_dir" "$n" true
  done
  write_pr_view "$case_dir/pr-1.json" "$H1" main
  write_pr_view "$case_dir/pr-2.json" "$H2" feat/a
  write_pr_view "$case_dir/pr-3.json" "$H3" feat/b
  write_stack "$case_dir" 1:feat/a 2:feat/b 3:feat/c
  printf '{"name":"main","protected":false}\n' > "$case_dir/branch.json"
  printf '[]\n' > "$case_dir/rules.json"
  printf '{"status":"ahead","ahead_by":3,"behind_by":0}\n' > "$case_dir/compare.json"
  printf '{"status":"merged","details":{"message":"merged","sha":"%s"}}\n' "$MERGE_COMMIT" > "$case_dir/merge-async.json"
  printf '0\n' > "$case_dir/merge-async.rc"
  printf '{"number":3,"merge_commit_sha":"%s"}\n' "$MERGE_COMMIT" > "$case_dir/pull-3.json"
  printf '{"sha":"%s","commit":{"tree":{"sha":"%s"}}}\n' "$MERGE_COMMIT" "$GATED_TREE" > "$case_dir/commit-$MERGE_COMMIT.json"
  printf '{"sha":"%s","commit":{"tree":{"sha":"%s"}}}\n' "$H3" "$GATED_TREE" > "$case_dir/commit-$H3.json"
  : > "$case_dir/gh.log"
  add_stack_gh_mock "$case_dir"
  printf '%s\n' "$case_dir"
}

add_stack_gh_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
C=$FM_TEST_CASE
printf '%s\n' "$*" >> "$C/gh.log"
number_of() { printf '%s' "${1##*/}"; }
case "${1:-} ${2:-}" in
  "pr view")
    n=$(number_of "$3")
    case " $* " in
      *statusCheckRollup*) cat "$C/pr-$n.json" ;;
      *headRefOid*) jq -r .headRefOid "$C/pr-$n.json" ;;
      *) cat "$C/pr-$n.json" ;;
    esac
    exit 0
    ;;
  "api graphql")
    for arg in "$@"; do
      case "$arg" in number=*) n=${arg#number=} ;; esac
    done
    cat "$C/outcome-$n"
    exit 0
    ;;
esac
[ "${1:-}" = api ] || exit 0
case " $* " in
  *" --method PUT "*merge-async*)
    for meta in "$FM_STATE_OVERRIDE"/task-b*.meta; do
      cp "$meta" "$C/at-merge-${meta##*/}"
    done
    cat "$C/merge-async.json"
    exit "$(cat "$C/merge-async.rc")"
    ;;
  *"/merge-async/"*)
    n=$(( $(cat "$C/poll-calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$n" > "$C/poll-calls"
    line=$(sed -n "${n}p" "$C/poll-sequence")
    [ -n "$line" ] || line=$(tail -n1 "$C/poll-sequence")
    printf '%s\n' "$line"
    exit 0
    ;;
  *"/stacks?pull_request="*) cat "$C/stacks.json"; exit 0 ;;
  *"/compare/"*) cat "$C/compare.json"; exit 0 ;;
  *"/rules/branches/"*) cat "$C/rules.json"; exit 0 ;;
  *"/branches/"*) cat "$C/branch.json"; exit 0 ;;
  *"/pulls/3 "*) cat "$C/pull-3.json"; exit 0 ;;
  *"/commits/"*)
    for arg in "$@"; do
      case "$arg" in repos/*/commits/*) sha=${arg##*/} ;; esac
    done
    [ -f "$C/commit-$sha.json" ] || exit 1
    cat "$C/commit-$sha.json"
    exit 0
    ;;
esac
exit 1
SH
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$case_dir/fakebin/gh" "$case_dir/fakebin/gh-axi"
}

run_stack_merge() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_CASE="$case_dir" \
  FM_PR_STACK_POLL_DELAY=0 \
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 \
  HOME="$case_dir/user-home" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

# The canonical stack merge request: #3 on top, gated at H3.
run_default_stack() {
  local case_dir=$1
  shift
  run_stack_merge "$case_dir" --stack "$H3" task-b3 "$REPO_URL/pull/3" \
    --member task-b1 "$REPO_URL/pull/1" --member task-b2 "$REPO_URL/pull/2" "$@" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
}

assert_no_merge_request() {
  local case_dir=$1 label=$2
  assert_no_grep 'merge-async' "$case_dir/gh.log" "$label: a stack merge request reached the forge"
}

test_stack_merges_and_records_every_member() {
  local case_dir rc=0 n
  case_dir=$(make_stack_case happy)
  run_default_stack "$case_dir" || rc=$?
  expect_code 0 "$rc" "happy: the stack merge should succeed ($(cat "$case_dir/stderr"))"
  assert_grep "--method PUT repos/example/repo/pulls/3/merge-async -f sha=$H3 -f merge_method=squash -f merge_action=direct_merge" \
    "$case_dir/gh.log" "happy: the merge request did not bind the gated head on the top pull request"
  for n in 1 2 3; do
    assert_grep "pr=$REPO_URL/pull/$n" "$case_dir/at-merge-task-b$n.meta" \
      "happy: task-b$n's pull request was not recorded before the merge request"
    assert_grep "verified: $REPO_URL/pull/$n is merged" "$case_dir/stdout" \
      "happy: #$n was not proven merged"
    assert_grep "$REPO_URL/pull/$n" "$case_dir/state/.wake-queue" \
      "happy: #$n's merge outcome was not recorded"
  done
  assert_grep "verified: main at merge commit $MERGE_COMMIT has the gated tree of $H3" "$case_dir/stdout" \
    "happy: the merged tree was not proven equal to the gated tree"
  assert_no_grep 'branches/feat' "$case_dir/gh.log" \
    "happy: a member's required checks were read from its own base instead of the trunk"
  pass "a green stack merges through one head-bound request and records every member"
}

test_stack_merge_method_flag_is_forwarded() {
  local case_dir rc=0
  case_dir=$(make_stack_case method)
  run_default_stack "$case_dir" -- --rebase || rc=$?
  expect_code 0 "$rc" "method: the stack merge should succeed"
  assert_grep "-f merge_method=rebase" "$case_dir/gh.log" "method: --rebase was not forwarded"
  pass "a stack merge forwards the caller's merge method"
}

test_top_head_must_equal_gated_head() {
  local case_dir rc=0
  case_dir=$(make_stack_case gated-mismatch)
  run_stack_merge "$case_dir" --stack 9999999999999999999999999999999999999999 task-b3 "$REPO_URL/pull/3" \
    --member task-b1 "$REPO_URL/pull/1" --member task-b2 "$REPO_URL/pull/2" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "gated-mismatch: a top head other than the gated head must refuse"
  assert_grep "not the gated head 9999999999999999999999999999999999999999" "$case_dir/stderr" \
    "gated-mismatch: the refusal did not name the gated head"
  assert_no_merge_request "$case_dir" gated-mismatch
  pass "the top pull request's live head must be the gated head"
}

test_member_without_recorded_head_refuses() {
  local case_dir rc=0
  case_dir=$(make_stack_case no-recorded-head)
  sed -i.bak '/^pr_head=/d' "$case_dir/state/task-b1.meta"
  run_default_stack "$case_dir" || rc=$?
  expect_code 1 "$rc" "no-recorded-head: a member with no recorded head must refuse"
  assert_grep "task task-b1 has no recorded head" "$case_dir/stderr" \
    "no-recorded-head: the refusal did not name the member"
  assert_no_merge_request "$case_dir" no-recorded-head
  pass "every stack member must have recorded its head before the merge"
}

test_member_that_moved_since_recorded_refuses_and_keeps_the_record() {
  local case_dir rc=0
  case_dir=$(make_stack_case moved)
  write_pr_view "$case_dir/pr-2.json" 7777777777777777777777777777777777777777 feat/a
  run_default_stack "$case_dir" || rc=$?
  expect_code 1 "$rc" "moved: a member that changed since it was recorded must refuse"
  assert_grep "$REPO_URL/pull/2 moved to 7777777777777777777777777777777777777777" "$case_dir/stderr" \
    "moved: the refusal did not name the moved member"
  assert_grep "pr_head=$H2" "$case_dir/state/task-b2.meta" \
    "moved: the refused run overwrote the recorded head, so a retry would pass vacuously"
  assert_no_merge_request "$case_dir" moved
  pass "a stack member that changed since it was recorded refuses without re-recording it"
}

test_live_stack_with_an_unnamed_member_refuses() {
  local case_dir rc=0
  case_dir=$(make_stack_case extra-member)
  write_stack "$case_dir" 1:feat/a 2:feat/b 3:feat/c 8:feat/d
  run_default_stack "$case_dir" || rc=$?
  expect_code 1 "$rc" "extra-member: a live stack holding an unnamed pull request must refuse"
  assert_grep "the live stack holds pull requests [1,2,3,8], but this merge names [1,2,3]" "$case_dir/stderr" \
    "extra-member: the refusal did not compare the live and named members"
  assert_no_merge_request "$case_dir" extra-member
  pass "the live stack must hold exactly the named pull requests"
}

test_named_top_that_is_not_the_top_refuses() {
  local case_dir rc=0
  case_dir=$(make_stack_case not-top)
  run_stack_merge "$case_dir" --stack "$H2" task-b2 "$REPO_URL/pull/2" \
    --member task-b1 "$REPO_URL/pull/1" --member task-b3 "$REPO_URL/pull/3" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "not-top: a mid-stack pull request named as the top must refuse"
  assert_grep "$REPO_URL/pull/2 is not the top of its stack; #3 is" "$case_dir/stderr" \
    "not-top: the refusal did not name the real top"
  assert_no_merge_request "$case_dir" not-top
  pass "the named top must be the top of the live stack"
}

test_draft_member_refuses() {
  local case_dir rc=0
  case_dir=$(make_stack_case draft)
  write_stack "$case_dir" 1:feat/a 2:feat/b:open:true 3:feat/c
  run_default_stack "$case_dir" || rc=$?
  expect_code 1 "$rc" "draft: a draft member must refuse"
  assert_grep "stack pull request #2 is a draft" "$case_dir/stderr" "draft: the refusal did not name the draft"
  assert_no_merge_request "$case_dir" draft
  pass "every stack member must be open and not a draft"
}

test_red_check_on_a_lower_member_refuses() {
  local case_dir rc=0
  case_dir=$(make_stack_case red-lower)
  write_pr_view "$case_dir/pr-1.json" "$H1" main \
    '[{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"}]'
  run_default_stack "$case_dir" || rc=$?
  expect_code 1 "$rc" "red-lower: a red check on a lower member must refuse"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" "red-lower: the red check was not named"
  assert_no_merge_request "$case_dir" red-lower
  pass "a red check on any stack member refuses the stack"
}

test_trunk_required_check_applies_to_every_member() {
  local case_dir rc=0
  case_dir=$(make_stack_case trunk-required)
  printf '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}}]\n' \
    > "$case_dir/rules.json"
  write_pr_view "$case_dir/pr-1.json" "$H1" main \
    '[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]'
  write_pr_view "$case_dir/pr-3.json" "$H3" feat/b \
    '[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]'
  run_default_stack "$case_dir" || rc=$?
  expect_code 1 "$rc" "trunk-required: a mid member missing a trunk-required check must refuse"
  assert_grep "required check 'build' has not reported at head $H2" "$case_dir/stderr" \
    "trunk-required: the mid member's missing trunk check was not named"
  assert_no_merge_request "$case_dir" trunk-required
  pass "the trunk's required checks apply to every stack member"
}

test_trunk_that_is_not_an_ancestor_refuses() {
  local case_dir rc=0
  case_dir=$(make_stack_case diverged)
  printf '{"status":"diverged","ahead_by":3,"behind_by":1}\n' > "$case_dir/compare.json"
  run_default_stack "$case_dir" || rc=$?
  expect_code 1 "$rc" "diverged: a trunk that moved past the stack base must refuse"
  assert_grep "is diverged relative to main" "$case_dir/stderr" "diverged: the refusal did not name the divergence"
  assert_no_merge_request "$case_dir" diverged
  pass "the trunk head must be an ancestor of the gated head"
}

test_refused_merge_request_reports_nothing_merged() {
  local case_dir rc=0
  case_dir=$(make_stack_case conflict)
  printf '{"status":"pending","details":{"message":"another request is pending","uuid":"u-1"}}\n' \
    > "$case_dir/merge-async.json"
  printf '1\n' > "$case_dir/merge-async.rc"
  run_default_stack "$case_dir" || rc=$?
  expect_code 1 "$rc" "conflict: a refused merge request must fail"
  assert_grep "GitHub refused the stack merge request" "$case_dir/stderr" \
    "conflict: the refusal was not reported"
  assert_absent "$case_dir/state/.wake-queue" "conflict: a refused merge request recorded a merge outcome"
  assert_no_grep 'merge-async/u-1' "$case_dir/gh.log" "conflict: the run adopted another request's uuid"
  pass "a merge request the forge refuses reports nothing as merged"
}

test_pending_request_is_polled_to_a_proven_merge() {
  local case_dir rc=0
  case_dir=$(make_stack_case pending)
  printf '{"status":"pending","details":{"message":"queued","uuid":"u-2"}}\n' > "$case_dir/merge-async.json"
  printf '%s\n' '{"status":"pending","details":{"uuid":"u-2"}}' \
    "{\"status\":\"merged\",\"details\":{\"message\":\"merged\",\"sha\":\"$MERGE_COMMIT\"}}" \
    > "$case_dir/poll-sequence"
  run_default_stack "$case_dir" || rc=$?
  expect_code 0 "$rc" "pending: a pending request that merges should succeed ($(cat "$case_dir/stderr"))"
  assert_equals 2 "$(cat "$case_dir/poll-calls")" "pending: the request was not polled until it settled"
  pass "a pending stack merge request is polled until it settles"
}

test_failed_request_with_nothing_merged_refuses() {
  local case_dir rc=0 n
  case_dir=$(make_stack_case failed)
  printf '{"status":"pending","details":{"message":"queued","uuid":"u-3"}}\n' > "$case_dir/merge-async.json"
  printf '%s\n' '{"status":"failed","details":{"message":"required review missing"}}' > "$case_dir/poll-sequence"
  for n in 1 2 3; do write_outcome "$case_dir" "$n" false; done
  run_default_stack "$case_dir" || rc=$?
  expect_code 1 "$rc" "failed: a failed request must refuse"
  assert_grep "ended failed, and these stack pull requests are not proven merged" "$case_dir/stderr" \
    "failed: the refusal did not report the failed request"
  assert_grep "required review missing" "$case_dir/stderr" "failed: the forge's own message was not quoted"
  assert_absent "$case_dir/state/.wake-queue" "failed: an unmerged stack recorded a merge outcome"
  pass "a failed stack merge request is refused, never reported as landed"
}

test_partially_proven_stack_refuses_and_records_only_proven_members() {
  local case_dir rc=0
  case_dir=$(make_stack_case partial)
  write_outcome "$case_dir" 3 false
  run_default_stack "$case_dir" || rc=$?
  expect_code 1 "$rc" "partial: an unproven member must refuse the run"
  assert_grep "not proven merged: $REPO_URL/pull/3" "$case_dir/stderr" "partial: the unproven member was not named"
  assert_grep "$REPO_URL/pull/1" "$case_dir/state/.wake-queue" "partial: a proven member's outcome was lost"
  assert_no_grep "$REPO_URL/pull/3" "$case_dir/state/.wake-queue" "partial: an unproven member was recorded as merged"
  pass "only proven stack members are recorded as merged, and an unproven one refuses"
}

test_merged_tree_mismatch_is_actionable() {
  local case_dir rc=0
  case_dir=$(make_stack_case tree-mismatch)
  printf '{"sha":"%s","commit":{"tree":{"sha":"%s"}}}\n' "$MERGE_COMMIT" "$OTHER_TREE" \
    > "$case_dir/commit-$MERGE_COMMIT.json"
  run_default_stack "$case_dir" || rc=$?
  expect_code 1 "$rc" "tree-mismatch: a merged tree other than the gated tree must exit nonzero"
  assert_grep "landed and is recorded as merged, but main at merge commit $MERGE_COMMIT has tree $OTHER_TREE" \
    "$case_dir/stderr" "tree-mismatch: the mismatch was not reported"
  assert_grep "$REPO_URL/pull/3" "$case_dir/state/.wake-queue" "tree-mismatch: the landed merge was not recorded"
  pass "a landed stack whose trunk tree differs from the gated tree is reported as actionable"
}

test_away_record_refuses_stack_mode() {
  local case_dir rc=0
  case_dir=$(make_stack_case away)
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge whatever is green' >/dev/null
  run_default_stack "$case_dir" || rc=$?
  expect_code 2 "$rc" "away: stack mode must refuse while away"
  assert_grep "--stack is attended-only" "$case_dir/stderr" "away: the refusal did not say why"
  assert_no_merge_request "$case_dir" away
  pass "stack mode is refused while the away-posture record exists"
}

test_invalid_stack_requests_refuse_before_any_read() {
  local case_dir rc
  case_dir=$(make_stack_case invalid)
  for args in \
    "--stack $H3 task-b3 $REPO_URL/pull/3" \
    "--stack $H3 task-b3 $REPO_URL/pull/3 --member task-b1 $REPO_URL/pull/1 --allow-red ci" \
    "--stack $H3 task-b3 $REPO_URL/pull/3 --member task-b1 $REPO_URL/pull/1 --attended-override" \
    "--stack $H3 task-b3 $REPO_URL/pull/3 --member task-b1 $REPO_URL/pull/1 -- --admin" \
    "--stack $H3 task-b3 $REPO_URL/pull/3 --member task-b3 $REPO_URL/pull/1" \
    "--stack $H3 task-b3 $REPO_URL/pull/3 --member task-b1 https://github.com/other/repo/pull/1" \
    "--stack $H3 task-b3 https://gitlab.example/group/project/-/merge_requests/3 --member task-b1 https://gitlab.example/group/project/-/merge_requests/1" \
    "--stack not-a-sha task-b3 $REPO_URL/pull/3 --member task-b1 $REPO_URL/pull/1" \
    "task-b3 $REPO_URL/pull/3 --member task-b1 $REPO_URL/pull/1"; do
    rc=0
    # shellcheck disable=SC2086 # Each case is a whitespace-separated argument list.
    run_stack_merge "$case_dir" $args > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 2 "$rc" "invalid: '$args' should be refused as an invalid request ($(cat "$case_dir/stderr"))"
  done
  [ ! -s "$case_dir/gh.log" ] || fail "invalid: an invalid stack request reached the forge: $(cat "$case_dir/gh.log")"
  pass "invalid stack requests are refused before any forge read"
}

test_stack_merges_and_records_every_member
test_stack_merge_method_flag_is_forwarded
test_top_head_must_equal_gated_head
test_member_without_recorded_head_refuses
test_member_that_moved_since_recorded_refuses_and_keeps_the_record
test_live_stack_with_an_unnamed_member_refuses
test_named_top_that_is_not_the_top_refuses
test_draft_member_refuses
test_red_check_on_a_lower_member_refuses
test_trunk_required_check_applies_to_every_member
test_trunk_that_is_not_an_ancestor_refuses
test_refused_merge_request_reports_nothing_merged
test_pending_request_is_polled_to_a_proven_merge
test_failed_request_with_nothing_merged_refuses
test_partially_proven_stack_refuses_and_records_only_proven_members
test_merged_tree_mismatch_is_actionable
test_away_record_refuses_stack_mode
test_invalid_stack_requests_refuse_before_any_read
