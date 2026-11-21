#!/usr/bin/env bash
# fm-spawn refuses a project path that is not a clone root before leasing a
# worktree: a missing path, or a folder inside another repository (such as
# the firstmate home's own checkout), stops with nothing created, while a real
# clone root still spawns.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-project-root)
home="$TMP_ROOT/home"
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
fm_test_spawn_home "$home" claude
# The home sits inside a repository, as a real home inside the firstmate checkout does.
fm_git_init_commit "$TMP_ROOT"
real="$home/projects/real"
wt="$TMP_ROOT/wt"
fm_git_worktree "$real" "$wt" project-root-test

# refuse <id> <project-arg> <expected-text>: runs from the home, as an
# operator does, and leaves the output in $TMP_ROOT/<id>.out.
refuse() {
  local id=$1 rc=0
  fm_test_spawn_brief "$home" "$id"
  (cd "$home" && fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$2" --mode no-mistakes --yolo off) > "$TMP_ROOT/$id.out" || rc=$?
  [ "$rc" -ne 0 ] || fail "$id: spawn succeeded: $(cat "$TMP_ROOT/$id.out")"
  assert_grep "$3" "$TMP_ROOT/$id.out" "$id: expected refusal text"
  [ ! -e "$home/state/$id.meta" ] || fail "$id: meta was written"
}

refuse missing-path skills 'not a clone root'
! grep -q 'projects/real' "$TMP_ROOT/missing-path.out" || fail 'suggested a project that was not asked for'
pass 'missing path is refused with nothing created'

mkdir -p "$real/sub"
refuse subdir-path "$real/sub" 'not a clone root'
pass 'a subdirectory of a repository is refused'

mkdir -p "$home/skills" "$home/projects/skills"
refuse home-subdir skills 'did you mean projects/skills'
pass 'a home folder that is not a clone is refused and suggests projects/<name>'

fm_test_spawn_brief "$home" root-ok
fm_test_run_spawn "$home" "$wt" "$fakebin" root-ok "$real" --mode no-mistakes --yolo off > "$TMP_ROOT/ok.out" ||
  fail "clone root refused: $(cat "$TMP_ROOT/ok.out")"
[ -e "$home/state/root-ok.meta" ] || fail 'clone root spawn wrote no meta'
pass 'a real clone root still spawns'
