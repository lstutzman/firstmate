#!/usr/bin/env bash
# Tests for bin/fm-post-merge-update.sh, driven through fm_merge_outcome_report:
#   - a firstmate merge recorded in the primary home starts exactly one detached
#     fm-update.sh, and a merge recorded a second time starts none;
#   - a merge in another project, or in a secondmate home, starts none;
#   - config/no-post-merge-update opts the home out;
#   - a skipped home or a failed update raises one check: wake, success is
#     silent, and no restart is invoked (fm-update.sh is a recording stub here;
#     its own guards are tested in fm-update.test.sh).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-post-merge-update-tests)

# world <name> [update-mode]: a fixture firstmate repo (with a copy of bin/ whose
# fm-update.sh records each call and prints per update-mode), a clone of it as
# the firstmate "project", an unrelated repo, and a primary home.
new_world() {
  local name=$1 mode=${2:-ok} w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config" "$w/home/data" "$w/root"
  cp -R "$ROOT/bin" "$w/root/bin"
  git -C "$w/root" init -q -b main
  git -C "$w/root" add bin
  git -C "$w/root" -c user.name=t -c user.email=t@e.invalid commit -qm initial
  git clone -q "$w/root" "$w/fmproject"
  fm_git_init_commit "$w/other"
  cat > "$w/root/bin/fm-update.sh" <<SH
#!/usr/bin/env bash
echo "\$FM_HOME" >> "$w/calls"
case "$mode" in
  skip) echo "remote secondmate x: skipped on h: dirty" >&2 ;;
  fail) exit 3 ;;
esac
echo "restart-secondmates: none"
SH
  chmod +x "$w/root/bin/fm-update.sh"
  : > "$w/calls"
  printf '%s\n' "$w"
}

# report <world> <project-dir> [home]: record a merge through the real function.
report() {
  local w=$1 proj=$2 home=${3:-$1/home} id=task-$RANDOM
  fm_write_meta "$home/state/$id.meta" "project=$proj"
  LAST_ID=$id
  (
    . "$w/root/bin/fm-merge-outcome-lib.sh"
    fm_merge_outcome_report "$home" "$home/state" "$id" "https://github.com/example/repo/pull/${PRN:-1}" self
  )
}

calls() { grep -c . "$1/calls" 2>/dev/null || true; }
wait_calls() {  # <world> <count>
  local i
  for i in $(seq 1 100); do [ "$(calls "$1")" -ge "$2" ] && return 0; sleep 0.1; done
  return 1
}
settle() { sleep 1; }

test_firstmate_merge_starts_one_update() {
  local w; w=$(new_world a)
  report "$w" "$w/fmproject" || fail "report failed"
  wait_calls "$w" 1 || fail "no update started"
  settle
  [ "$(calls "$w")" = 1 ] || fail "expected one update, got $(calls "$w")"
  grep -qx "$w/home" "$w/calls" || fail "update not scoped to the primary home"
  # same merge recorded again (poll after the merge command): no second run
  local id=$LAST_ID
  (. "$w/root/bin/fm-merge-outcome-lib.sh"
   fm_merge_outcome_report "$w/home" "$w/home/state" "$id" https://github.com/example/repo/pull/1 poll)
  settle
  [ "$(calls "$w")" = 1 ] || fail "repeat record started another update"
  ! grep -q 'post-merge update' "$w"/home/state/* 2>/dev/null || fail "success was not silent"
  pass "firstmate merge in primary starts exactly one detached update"
}

test_other_project_and_secondmate_start_none() {
  local w; w=$(new_world b)
  report "$w" "$w/other" || fail "report failed"
  settle
  [ "$(calls "$w")" = 0 ] || fail "other project started an update"
  mkdir -p "$w/sm/state" "$w/sm/config"
  : > "$w/sm/.fm-secondmate-home"
  report "$w" "$w/fmproject" "$w/sm" || true
  settle
  [ "$(calls "$w")" = 0 ] || fail "secondmate home started an update"
  pass "other project or secondmate home starts no update"
}

test_opt_out_starts_none() {
  local w; w=$(new_world c)
  : > "$w/home/config/no-post-merge-update"
  report "$w" "$w/fmproject" || fail "report failed"
  settle
  [ "$(calls "$w")" = 0 ] || fail "opted-out home started an update"
  pass "config/no-post-merge-update opts out"
}

test_skipped_home_and_failure_are_reported() {
  local w; w=$(new_world d skip)
  report "$w" "$w/fmproject" || fail "report failed"
  wait_calls "$w" 1 || fail "no update started"
  settle
  grep -rq 'post-merge update needs a look' "$w/home/state" || fail "skipped home not reported"
  w=$(new_world e fail)
  report "$w" "$w/fmproject" || fail "report failed"
  wait_calls "$w" 1 || fail "no update started"
  settle
  grep -rq 'exited 3' "$w/home/state" || fail "failed update not reported"
  pass "skipped home or failed update raises a check wake; nothing forced"
}

fm_test_run test_firstmate_merge_starts_one_update \
  test_other_project_and_secondmate_start_none \
  test_opt_out_starts_none \
  test_skipped_home_and_failure_are_reported
