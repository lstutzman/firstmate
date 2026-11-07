#!/usr/bin/env bash
# Tests for bin/fm-pr-adopt.sh: adopting an open GitHub PR that has no task
# record in this home, so bin/fm-pr-merge.sh merges it under its own unchanged
# guards and bin/fm-teardown.sh cleans the record afterwards with no copy to
# touch. Every refusal must leave no record behind.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-pr-adopt-tests)
URL=https://github.com/example/repo/pull/9
HEAD_SHA=deadbeefcafefeed0000000000000000deadbeef

# A home with a markdown backlog, the registry line given, and a clone of a
# local bare repository whose origin reads as github.com/example/repo. The gh
# mock answers from files in the case directory. Echoes the case directory.
make_case() {  # <name> [registry-line]
  local case_dir=$TMP_ROOT/$1 registry=${2:-'- repo [no-mistakes +yolo] - test project (added 2026-11-05)'}
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" "$case_dir/home/projects" "$case_dir/fakebin"
  fm_test_tasks_toml "$case_dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$case_dir/home/data/backlog.md"
  printf '%s\n' "$registry" > "$case_dir/home/data/projects.md"
  fm_git_init_commit "$case_dir/src"
  git clone --quiet --bare "$case_dir/src" "$case_dir/origin.git"
  git clone --quiet "$case_dir/origin.git" "$case_dir/home/projects/repo"
  git -C "$case_dir/home/projects/repo" remote set-url origin git@github.com:Example/Repo.git
  printf 'OPEN\n' > "$case_dir/pr-state"
  printf 'SUCCESS\n' > "$case_dir/pr-conclusion"
  : > "$case_dir/gh.log"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/gh.log"
case " \$* " in
  *" pr view "*statusCheckRollup*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$HEAD_SHA","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"%s"}]}\n' "\$(cat "$case_dir/pr-conclusion")" ;;
  *" pr view "*"--json state "*) cat "$case_dir/pr-state" ;;
  *" pr view "*isDraft*) printf '{"isDraft":false}\n' ;;
  *" pr view "*headRefOid*) printf '%s\n' "$HEAD_SHA" ;;
  *" pr merge "*) printf 'merged\n' ;;
  *" api graphql "*) printf '%s\n' state=MERGED merged=true queued=false base=main ;;
  *"/contents/.github/required-checks.list"*) printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1 ;;
  *"/rules/branches/"*) printf '[]\n' ;;
  *"/branches/"*) printf '{"name":"main","protected":false,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}\n' ;;
  *) exit 1 ;;
esac
SH
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "$3" ;;
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/fakebin/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/fakebin/treehouse"
  chmod +x "$case_dir/fakebin/"*
  printf '%s\n' "$case_dir"
}

# Runs one firstmate script in the case's home.
run_in() {  # <case_dir> <script> [args...]
  local case_dir=$1 script=$2
  shift 2
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" HOME="$case_dir/user-home" \
  PATH="$case_dir/fakebin:$PATH" bash "$ROOT/bin/$script" "$@"
}

# Teardown with a git rewrite, so its clone refresh reaches the local bare
# repository instead of GitHub.
run_teardown() {  # <case_dir> [args...]
  local case_dir=$1
  shift
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$case_dir/origin.git.insteadOf" \
  GIT_CONFIG_VALUE_0=git@github.com:Example/Repo.git \
  run_in "$case_dir" fm-teardown.sh "$@"
}

# A refusal exits 1, names its reason, and leaves no record and no merge.
expect_refused() {  # <case_dir> <label> <stderr-fragment> [adopt args...]
  local case_dir=$1 label=$2 fragment=$3 rc=0
  shift 3
  run_in "$case_dir" fm-pr-adopt.sh "$@" > "$case_dir/out" 2> "$case_dir/err" || rc=$?
  expect_code 1 "$rc" "$label"
  assert_grep "$fragment" "$case_dir/err" "$label: refusal does not say '$fragment': $(cat "$case_dir/err")"
  assert_absent "$case_dir/home/state/adopt-9.meta" "$label: a record was left behind"
  assert_no_grep 'pr merge' "$case_dir/gh.log" "$label: a merge was attempted"
}

test_adopt_merge_teardown_round_trip() {
  local case_dir meta rc=0 clone_head
  case_dir=$(make_case round-trip)
  meta=$case_dir/home/state/adopt-9.meta
  clone_head=$(git -C "$case_dir/home/projects/repo" rev-parse HEAD)

  run_in "$case_dir" fm-pr-adopt.sh adopt-9 "$URL" --mode no-mistakes --yolo on > "$case_dir/out" 2> "$case_dir/err" || rc=$?
  expect_code 0 "$rc" "round-trip: adopt: $(cat "$case_dir/err")"
  assert_equals "worktree=$case_dir/home/state/adopt-9.adopted-no-copy
project=$case_dir/home/projects/repo
kind=ship
mode=no-mistakes
yolo=on
adopted=1" "$(sed -n 1,6p "$meta")" "round-trip: the record holds more or other fields than the minimum"
  assert_grep "pr=$URL" "$meta" "round-trip: pr= was not recorded"
  assert_grep "pr_head=$HEAD_SHA" "$meta" "round-trip: pr_head= was not read from the forge"
  assert_no_grep 'window=' "$meta" "round-trip: the record names a window"
  assert_no_grep 'spawn_gen=' "$meta" "round-trip: the record names an incarnation"
  assert_no_grep 'office=' "$meta" "round-trip: the record grants an office"
  assert_no_grep 'branch=' "$meta" "round-trip: the record names a branch"
  assert_absent "$case_dir/home/state/adopt-9.adopted-no-copy" "round-trip: the no-copy path exists"
  assert_present "$case_dir/home/state/adopt-9.check.sh" "round-trip: no merge poll was armed"
  assert_grep '- [ ] adopt-9 - Adopt' "$case_dir/home/data/backlog.md" "round-trip: no In flight backlog item"

  rc=0
  run_in "$case_dir" fm-pr-merge.sh adopt-9 "$URL" > "$case_dir/out" 2> "$case_dir/err" || rc=$?
  expect_code 0 "$rc" "round-trip: merge: $(cat "$case_dir/err")"
  assert_grep "pr merge 9 --repo example/repo --match-head-commit $HEAD_SHA --squash" "$case_dir/gh.log" \
    "round-trip: the merge was not bound to the live head"

  rc=0
  run_teardown "$case_dir" adopt-9 > "$case_dir/out" 2> "$case_dir/err" || rc=$?
  expect_code 0 "$rc" "round-trip: teardown: $(cat "$case_dir/err")"
  assert_absent "$meta" "round-trip: teardown left the record"
  assert_grep '- [x] adopt-9 - Adopt' "$case_dir/home/data/backlog.md" "round-trip: the backlog item was not closed"
  assert_equals "$clone_head" "$(git -C "$case_dir/home/projects/repo" rev-parse HEAD)" "round-trip: teardown moved the project clone"
  assert_equals main "$(git -C "$case_dir/home/projects/repo" branch --show-current)" "round-trip: teardown switched the project clone's branch"
  pass "an adopted PR merges under fm-pr-merge.sh's guards and its record tears down with no copy touched"
}

test_red_check_still_refuses_the_merge() {
  local case_dir rc=0
  case_dir=$(make_case red-check)
  run_in "$case_dir" fm-pr-adopt.sh adopt-9 "$URL" --mode no-mistakes --yolo on > /dev/null 2>&1 \
    || fail "red-check: adopt failed"
  printf 'FAILURE\n' > "$case_dir/pr-conclusion"
  run_in "$case_dir" fm-pr-merge.sh adopt-9 "$URL" > "$case_dir/out" 2> "$case_dir/err" || rc=$?
  expect_code 1 "$rc" "red-check: a red adopted PR merged"
  assert_no_grep 'pr merge' "$case_dir/gh.log" "red-check: the forge merge was called"
  # The merge-time re-record still found a head, so a retry after green works.
  rc=0
  printf 'SUCCESS\n' > "$case_dir/pr-conclusion"
  run_in "$case_dir" fm-pr-merge.sh adopt-9 "$URL" > "$case_dir/out" 2> "$case_dir/err" || rc=$?
  expect_code 0 "$rc" "red-check: retry after green: $(cat "$case_dir/err")"
  pass "fm-pr-merge.sh still refuses a red adopted PR, and merges it once green"
}

test_refuses_an_existing_record() {
  local case_dir before
  case_dir=$(make_case existing)
  fm_write_meta "$case_dir/home/state/adopt-9.meta" "window=fm-adopt-9" "worktree=/somewhere" "project=/p"
  before=$(cat "$case_dir/home/state/adopt-9.meta")
  run_in "$case_dir" fm-pr-adopt.sh adopt-9 "$URL" --mode no-mistakes --yolo on > /dev/null 2> "$case_dir/err" \
    && fail "existing: adopt replaced a live record"
  assert_grep 'already has a record' "$case_dir/err" "existing: refusal reason missing"
  assert_equals "$before" "$(cat "$case_dir/home/state/adopt-9.meta")" "existing: the live record changed"
  pass "adopt refuses a task id whose record already exists and leaves it unchanged"
}

test_refuses_a_pr_that_is_not_open() {
  local case_dir
  case_dir=$(make_case not-open)
  printf 'MERGED\n' > "$case_dir/pr-state"
  expect_refused "$case_dir" not-open 'is MERGED, not open' adopt-9 "$URL" --mode no-mistakes --yolo on
  pass "adopt refuses a PR that is not open"
}

test_refuses_another_repository() {
  local case_dir
  case_dir=$(make_case other-repo)
  expect_refused "$case_dir" other-repo "github.com/example/other" \
    adopt-9 https://github.com/example/other/pull/9 --mode no-mistakes --yolo on --project "$case_dir/home/projects/repo"
  pass "adopt refuses a PR whose repository is not the project's origin"
}

test_refuses_an_unregistered_project() {
  local case_dir
  case_dir=$(make_case unregistered '- someone-else [no-mistakes +yolo] - other (added 2026-11-05)')
  expect_refused "$case_dir" unregistered 'not registered' adopt-9 "$URL" --mode no-mistakes --yolo on
  pass "adopt refuses a project that is not registered"
}

test_never_raises_the_registered_posture() {
  local case_dir rc=0
  case_dir=$(make_case no-yolo '- repo [no-mistakes] - test project (added 2026-11-05)')
  expect_refused "$case_dir" no-yolo 'not +yolo' adopt-9 "$URL" --mode no-mistakes --yolo on
  expect_refused "$case_dir" direct-pr '--mode must be no-mistakes' adopt-9 "$URL" --mode direct-PR --yolo off
  run_in "$case_dir" fm-pr-adopt.sh adopt-9 "$URL" --mode no-mistakes > /dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "no-yolo: adopt ran without an explicit --yolo"
  assert_absent "$case_dir/home/state/adopt-9.meta" "no-yolo: a record was written without --yolo"
  rc=0
  run_in "$case_dir" fm-pr-adopt.sh adopt-9 "$URL" --mode no-mistakes --yolo off > /dev/null 2> "$case_dir/err" || rc=$?
  expect_code 0 "$rc" "no-yolo: --yolo off: $(cat "$case_dir/err")"
  assert_grep 'yolo=off' "$case_dir/home/state/adopt-9.meta" "no-yolo: the stated posture was not recorded"
  pass "adopt needs explicit --mode and --yolo and never records yolo on past a project's registered posture"
}

test_adopt_merge_teardown_round_trip
test_red_check_still_refuses_the_merge
test_refuses_an_existing_record
test_refuses_a_pr_that_is_not_open
test_refuses_another_repository
test_refuses_an_unregistered_project
test_never_raises_the_registered_posture
