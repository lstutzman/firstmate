#!/usr/bin/env bash
# Behavior tests for the office authority check on the relaunch path:
# `bin/fm-spawn.sh <id> --relaunch` in an office home (bin/fm-office-authority-
# lib.sh owns detection and the authority record). A relaunch keeps its place,
# so it is never deferred by wip=, but it must still refuse whatever the
# published record does not cover, and a home that is not an office must
# relaunch exactly as before.
#
# Every case drives the real spawn against a real isolated git worktree and a
# fake tmux that models the pane (a dead agent leaves a bare shell), then judges
# a refusal by the fake pane receiving no launch command and the task record
# staying byte-identical.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-office-relaunch)
ID=office-relaunch-a1

# make_case <name> [record-line...]: an office home "mate-x" that dispatches to
# and merges the fixture project, holding a ship task that was spawned by it
# with yolo on and whose agent has exited. Record lines replace the default line
# with their key. Echoes the case dir.
make_case() {
  local name=$1 case_dir kv key old
  shift
  case_dir="$TMP_ROOT/$name"
  local -a rec=(id=mate-x dispatch=proj merge=proj merge-via=none auto-merge-classes=none wip=1
    admission-sha256=proj:0000000000000000000000000000000000000000000000000000000000000000)
  for kv in "$@"; do
    key=${kv%%=*}
    local -a kept=()
    for old in "${rec[@]}"; do [ "${old%%=*}" = "$key" ] || kept+=("$old"); done
    rec=("${kept[@]}" "$kv")
  done
  fm_test_spawn_home "$case_dir/home" codex
  fm_test_fake_tmux_relaunch "$case_dir/fakebin"
  fm_fake_exit0 "$case_dir/fakebin" treehouse
  fm_git_worktree "$case_dir/proj" "$case_dir/wt" "wt-$name"
  fm_test_spawn_brief "$case_dir/home" "$ID"
  mkdir -p "$case_dir/fake"
  : > "$case_dir/fake/literal"
  : > "$case_dir/fake/keys"
  printf 'zsh' > "$case_dir/fake/command"
  printf '%s\n' "fm-$ID" > "$case_dir/fake/windows"
  printf '%s' "$case_dir/wt" > "$case_dir/fake/cwd"
  {
    echo "window=fmses:fm-$ID"
    echo "endpoint_task_id=$ID"
    echo "worktree=$case_dir/wt"
    echo "project=$case_dir/proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=on"
    echo "tasktmp=$case_dir/tasktmp"
    echo "model=default"
    echo "effort=default"
    echo "office=mate-x"
  } > "$case_dir/home/state/$ID.meta"
  fm_write_office_home "$case_dir/home" mate-x "${rec[@]}"
  printf '%s\n' "$case_dir"
}

# relaunch <case-dir>: relaunches the case's task; sets OUT and RC.
relaunch() {
  local case_dir=$1 home=$1/home
  mkdir -p "$case_dir/user-home"
  RC=0
  OUT=$(env PATH="$case_dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$case_dir/fake" \
    HOME="$case_dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 TMUX=fake,1,0 \
    FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch 2>&1) || RC=$?
}

launched() {  # <case-dir>: succeeds when the fake pane was sent a launch
  grep -q 'encode launch-brief' "$1/fake/literal"
}

expect_refused() {  # <case-dir> <label> <fragment>
  local case_dir=$1 before=$1/meta.before
  [ "$RC" -ne 0 ] || fail "$2: the office relaunched: $OUT"
  assert_contains "$OUT" "$3" "$2: the refusal did not give the office reason"
  assert_contains "$OUT" "spawn refused" "$2: the refusal was not the spawn's own"
  ! launched "$case_dir" || fail "$2: a refused office relaunch still launched an agent"
  cmp -s "$before" "$case_dir/home/state/$ID.meta" || fail "$2: a refused office relaunch changed the task record"
}

# refuse_case <name> <label> <fragment> [record-line...]: builds the case,
# applies $BREAK to its home when set, and expects the relaunch refused.
refuse_case() {
  local name=$1 label=$2 fragment=$3 case_dir
  shift 3
  case_dir=$(make_case "$name" "$@")
  [ -z "${BREAK:-}" ] || "$BREAK" "$case_dir/home"
  cp "$case_dir/home/state/$ID.meta" "$case_dir/meta.before"
  relaunch "$case_dir"
  expect_refused "$case_dir" "$label" "$fragment"
}

break_unpublish() { /usr/bin/trash "$1/config/office-authority" "$1/config/.fm-inherit-office-authority.generation"; }
break_heading() { printf '# Charter\n' > "$1/data/charter.md"; }
break_secondmate_kind() { sed -i.bak 's/^kind=ship$/kind=secondmate/' "$1/state/$ID.meta"; }

test_office_relaunches_inside_its_record() {
  local case_dir
  case_dir=$(make_case inside)
  relaunch "$case_dir"
  expect_code 0 "$RC" "an office relaunch inside its record was refused: $OUT"
  launched "$case_dir" || fail "an office relaunch inside its record launched no agent: $OUT"
  [ "$(grep -c '^office=' "$case_dir/home/state/$ID.meta")" = 1 ] \
    || fail "an office relaunch did not keep exactly one office= line in the task record"
  grep -qx 'office=mate-x' "$case_dir/home/state/$ID.meta" \
    || fail "an office relaunch lost office=mate-x from the task record"
  pass "an office relaunches a task inside its authority record and keeps its office= line"
}

test_office_relaunch_is_not_deferred_by_wip() {
  local case_dir
  # wip=1 and a second live task: a fresh spawn would be deferred, but a
  # relaunch keeps the place it already holds.
  case_dir=$(make_case wip)
  fm_write_meta "$case_dir/home/state/other-live.meta" kind=ship project="$case_dir/proj"
  relaunch "$case_dir"
  expect_code 0 "$RC" "an office relaunch was deferred or refused past its wip: $OUT"
  assert_not_contains "$OUT" "deferred:" "an office relaunch was deferred by wip="
  launched "$case_dir" || fail "an office relaunch past its wip launched no agent: $OUT"
  pass "an office relaunch keeps its place and is never deferred by wip="
}

test_non_office_relaunches_as_before() {
  local case_dir
  # A plain second mate holding a stray record that would refuse this task.
  case_dir=$(make_case stray dispatch=none merge=none admission-sha256=)
  /usr/bin/trash "$case_dir/home/.fm-office"
  printf '# Charter\n' > "$case_dir/home/data/charter.md"
  sed -i.bak '/^office=/d' "$case_dir/home/state/$ID.meta"
  relaunch "$case_dir"
  expect_code 0 "$RC" "a plain second mate with a stray authority record could not relaunch: $OUT"
  assert_not_contains "$OUT" "authority record" "a plain second mate's relaunch mentioned an office authority record"
  launched "$case_dir" || fail "a plain second mate's relaunch launched no agent: $OUT"
  ! grep -q '^office=' "$case_dir/home/state/$ID.meta" || fail "a plain second mate's relaunch gained an office= line"
  pass "a home that is not an office relaunches exactly as before, even with a stray record"
}

test_office_relaunch_refuses_outside_its_record() {
  BREAK=break_unpublish refuse_case unpublished "unpublished record" "no published authority record"
  BREAK=break_heading refuse_case no-heading "marker without heading" 'lacks the "# Office authority" heading'
  BREAK='' refuse_case dispatch "project removed from dispatch" "dispatches only to other" \
    dispatch=other merge=none admission-sha256=
  BREAK='' refuse_case merge-gone "yolo on, project in neither merge= nor merge-via=" \
    "is in neither its merge= nor its merge-via=" merge=none admission-sha256=
  BREAK=break_secondmate_kind refuse_case secondmate "second mate task" "never creates or relaunches a second mate"
  pass "an office relaunch refuses whatever its authority record does not cover, and launches nothing"
}

test_office_relaunches_inside_its_record
test_office_relaunch_is_not_deferred_by_wip
test_non_office_relaunches_as_before
test_office_relaunch_refuses_outside_its_record
echo "# all fm-office-relaunch tests passed"
