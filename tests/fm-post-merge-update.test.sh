#!/usr/bin/env bash
# Tests for bin/fm-post-merge-update.sh. Spec: docs/configuration.md
# "Post-merge update".
#   - a firstmate merge recorded in the primary home starts exactly one detached
#     fm-update.sh, and a merge recorded a second time starts none;
#   - a firstmate merge recorded in a secondmate home (real local parent
#     binding) starts nothing there; the primary's scan of the line it wrote
#     starts one update after a gh read shows the PR merged;
#   - the same PR through both paths, in either order, starts one update;
#   - another repository's PR (no gh read), an unmerged PR, merged lines that
#     predate the first scan, and an opted-out home start none;
#   - a skipped home, a failed update, or an unreadable child PR raises one
#     check: wake, and success is silent. fm-update.sh is a recording stub here;
#     its own guards and lock are tested in fm-update.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-post-merge-update-tests)
FM_URL=https://github.com/example/firstmate/pull
OTHER_URL=https://github.com/example/other/pull

# new_world <name> [update-mode]: a fixture firstmate code root (a copy of bin/
# whose fm-update.sh records each call, origin set to example/firstmate), a
# clone of it as the firstmate "project", an unrelated repo, a primary home, a
# secondmate home bound to it as sm1, and gh/gh-axi stubs answering per
# $w/gh-mode (merged|open|fail) and logging every call.
new_world() {
  local name=$1 mode=${2:-ok} w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config" "$w/home/data" "$w/root" "$w/fakebin"
  mkdir -p "$w/sm/state" "$w/sm/config" "$w/sm/data"
  cp -R "$ROOT/bin" "$w/root/bin"
  git -C "$w/root" init -q -b main
  git -C "$w/root" add bin
  git -C "$w/root" -c user.name=t -c user.email=t@e.invalid commit -qm initial
  git -C "$w/root" remote add origin git@github.com:Example/firstmate.git
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
  cat > "$w/fakebin/gh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$w/gh-calls"
case "\$(cat "$w/gh-mode")" in
  merged) printf 'state=MERGED\nmerged=true\n' ;;
  open) printf 'state=OPEN\nmerged=false\n' ;;
  *) exit 1 ;;
esac
SH
  printf '#!/usr/bin/env bash\nexit 1\n' > "$w/fakebin/gh-axi"
  chmod +x "$w/fakebin/gh" "$w/fakebin/gh-axi"
  echo merged > "$w/gh-mode"
  printf 'sm1\n' > "$w/sm/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$w/home" > "$w/sm/.fm-secondmate-parent"
  : > "$w/calls"
  : > "$w/gh-calls"
  printf '%s\n' "$w"
}

# report <world> <home> <project-dir> <pr-url>: record a merge in <home>
# through the real fm_merge_outcome_report.
report() {
  local w=$1 home=$2 proj=$3 url=$4 id=task-$RANDOM
  fm_write_meta "$home/state/$id.meta" "project=$proj"
  (
    # shellcheck source=bin/fm-merge-outcome-lib.sh
    . "$w/root/bin/fm-merge-outcome-lib.sh"
    PATH="$w/fakebin:$PATH" fm_merge_outcome_report "$home" "$home/state" "$id" "$url" self
  )
}

scan() {  # <world> [home]
  PATH="$1/fakebin:$PATH" "$1/root/bin/fm-post-merge-update.sh" scan "${2:-$1/home}" "${2:-$1/home}/state"
}

count() { grep -c . "$1" 2>/dev/null || true; }
calls() { count "$1/calls"; }
gh_calls() { count "$1/gh-calls"; }
wait_calls() {  # <world> <count>
  local i
  for i in $(seq 1 100); do [ "$(calls "$1")" -ge "$2" ] && return 0; sleep 0.1; done
  return 1
}
settle() { sleep 1; }

test_firstmate_merge_starts_one_update() {
  local w; w=$(new_world a)
  report "$w" "$w/home" "$w/fmproject" "$FM_URL/1" || fail "report failed"
  wait_calls "$w" 1 || fail "no update started"
  settle
  [ "$(calls "$w")" = 1 ] || fail "expected one update, got $(calls "$w")"
  grep -qx "$w/home" "$w/calls" || fail "update not scoped to the primary home"
  report "$w" "$w/home" "$w/fmproject" "$FM_URL/1" || fail "second report failed"
  settle
  [ "$(calls "$w")" = 1 ] || fail "a second record of the same PR started another update"
  ! grep -rq 'post-merge update' "$w/home/state" || fail "success was not silent"
  pass "firstmate merge in primary starts exactly one detached update"
}

test_child_reported_merge_starts_one_update() {
  local w; w=$(new_world b)
  scan "$w"
  report "$w" "$w/sm" "$w/fmproject" "$FM_URL/7" || fail "secondmate report failed"
  grep -q "^done \[key=merged-task-[0-9]*\].*: merged task-[0-9]* $FM_URL/7\$" "$w/home/state/sm1.status" \
    || fail "secondmate merge line did not reach the parent channel"
  settle
  [ "$(calls "$w")" = 0 ] || fail "the secondmate home itself started an update"
  scan "$w" "$w/sm"
  settle
  [ "$(calls "$w")" = 0 ] || fail "a scan in the secondmate home started an update"
  scan "$w"
  wait_calls "$w" 1 || fail "the primary's scan of the child line started no update"
  scan "$w"
  settle
  [ "$(calls "$w")" = 1 ] || fail "a rescan started another update"
  [ "$(gh_calls "$w")" = 1 ] || fail "expected one gh read, got $(gh_calls "$w")"
  grep -qx "$w/home" "$w/calls" || fail "update not scoped to the primary home"
  ! grep -rq 'post-merge update' "$w/home/state" || fail "success was not silent"
  pass "a child-reported firstmate merge starts one update from the primary only"
}

test_same_pr_via_both_paths_starts_one() {
  local w; w=$(new_world c)
  scan "$w"
  report "$w" "$w/sm" "$w/fmproject" "$FM_URL/8" || fail "secondmate report failed"
  scan "$w"
  wait_calls "$w" 1 || fail "child path started no update"
  report "$w" "$w/home" "$w/fmproject" "$FM_URL/8" || fail "primary report failed"
  report "$w" "$w/home" "$w/fmproject" "$FM_URL/9" || fail "primary report failed"
  wait_calls "$w" 2 || fail "primary path started no update for a new PR"
  report "$w" "$w/sm" "$w/fmproject" "$FM_URL/9" || fail "secondmate report failed"
  scan "$w"
  settle
  [ "$(calls "$w")" = 2 ] || fail "expected two updates for two PRs, got $(calls "$w")"
  [ "$(gh_calls "$w")" = 1 ] || fail "a PR the primary already claimed was read again"
  pass "the same PR through both paths, in either order, starts one update"
}

test_other_repo_unmerged_and_old_lines_start_none() {
  local w; w=$(new_world d)
  report "$w" "$w/sm" "$w/fmproject" "$FM_URL/3" || fail "secondmate report failed"
  scan "$w"
  settle
  [ "$(calls "$w")" = 0 ] || fail "a merge reported before the first scan started an update"
  report "$w" "$w/sm" "$w/other" "$OTHER_URL/4" || fail "secondmate report failed"
  scan "$w"
  settle
  [ "$(calls "$w")" = 0 ] || fail "another repository's PR started an update"
  [ "$(gh_calls "$w")" = 0 ] || fail "another repository's PR was read with gh"
  echo open > "$w/gh-mode"
  report "$w" "$w/sm" "$w/fmproject" "$FM_URL/5" || fail "secondmate report failed"
  scan "$w"
  settle
  [ "$(calls "$w")" = 0 ] || fail "an unmerged PR started an update"
  [ "$(gh_calls "$w")" = 1 ] || fail "the unmerged PR was not checked with gh"
  pass "another repository, an unmerged PR, or a line before the first scan starts none"
}

test_opt_out_starts_none() {
  local w; w=$(new_world e)
  : > "$w/home/config/no-post-merge-update"
  report "$w" "$w/home" "$w/fmproject" "$FM_URL/1" || fail "report failed"
  scan "$w"
  report "$w" "$w/sm" "$w/fmproject" "$FM_URL/2" || fail "secondmate report failed"
  scan "$w"
  settle
  [ "$(calls "$w")" = 0 ] || fail "opted-out home started an update"
  pass "config/no-post-merge-update opts out"
}

test_problems_raise_one_check_wake() {
  local w; w=$(new_world f skip)
  report "$w" "$w/home" "$w/fmproject" "$FM_URL/1" || fail "report failed"
  wait_calls "$w" 1 || fail "no update started"
  settle
  grep -rq 'post-merge update needs a look' "$w/home/state" || fail "skipped home not reported"
  w=$(new_world g fail)
  report "$w" "$w/home" "$w/fmproject" "$FM_URL/1" || fail "report failed"
  wait_calls "$w" 1 || fail "no update started"
  settle
  grep -rq 'exited 3' "$w/home/state" || fail "failed update not reported"
  w=$(new_world h)
  echo fail > "$w/gh-mode"
  scan "$w"
  report "$w" "$w/sm" "$w/fmproject" "$FM_URL/6" || fail "secondmate report failed"
  scan "$w"
  settle
  [ "$(calls "$w")" = 0 ] || fail "an unreadable PR started an update"
  grep -rq "could not confirm a child-reported merge of $FM_URL/6" "$w/home/state" \
    || fail "an unreadable child PR was not reported"
  pass "a skipped home, failed update, or unreadable child PR raises a check wake"
}

# The live watcher drives the child path: each cycle scans the primary's status
# logs. The first cycle sets the baseline; a secondmate's merged line written
# after it (the same bytes a remote mate's channel is mirrored with) then starts
# one update without anyone running scan by hand. Each cycle ends at its first
# wake, so the watcher is re-armed while it runs, as firstmate does.
start_watcher() {  # <world>
  fm_test_track_watcher_state "$1/home/state"
  env PATH="$1/fakebin:$PATH" FM_HOME="$1/home" FM_STATE_OVERRIDE="$1/home/state" \
    FM_CONFIG_OVERRIDE="$1/home/config" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$1/root/bin/fm-watch.sh" >/dev/null 2>&1 &
  # shellcheck disable=SC2031
  printf '%s\n' "$!" > "$1/watch.pid"
}
rearm_watcher() {  # <world>
  ! kill -0 "$(cat "$1/watch.pid")" 2>/dev/null || return 0
  start_watcher "$1"
}

test_watcher_cycle_starts_child_update() {
  local w i; w=$(new_world i)
  start_watcher "$w"
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$w/home/state/.post-merge-update/scanned" ]; do
    rearm_watcher "$w"; sleep 0.1; i=$((i + 1))
  done
  [ -e "$w/home/state/.post-merge-update/scanned" ] || fail "the watcher never scanned the primary's status logs"
  report "$w" "$w/sm" "$w/fmproject" "$FM_URL/12" || fail "secondmate report failed"
  i=0
  while [ "$i" -lt 200 ] && [ "$(calls "$w")" -lt 1 ]; do
    rearm_watcher "$w"; sleep 0.1; i=$((i + 1))
  done
  settle
  rearm_watcher "$w"
  settle
  FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" "$w/root/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  [ "$(calls "$w")" = 1 ] || fail "expected one watcher-driven update, got $(calls "$w")"
  grep -qx "$w/home" "$w/calls" || fail "update not scoped to the primary home"
  pass "the live watcher starts one update for a child-reported firstmate merge"
}

fm_test_run test_firstmate_merge_starts_one_update \
  test_child_reported_merge_starts_one_update \
  test_same_pr_via_both_paths_starts_one \
  test_other_repo_unmerged_and_old_lines_start_none \
  test_opt_out_starts_none \
  test_problems_raise_one_check_wake \
  test_watcher_cycle_starts_child_update
