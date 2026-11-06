#!/usr/bin/env bash
# Behavior tests for bin/fm-tree-park.sh: a finished ship whose pushed PR head
# waits on another home's merger returns its copy to the pool and keeps its
# record; a steer brings back a fresh copy at that head; every unsafe copy keeps
# today's behaviour; and cleanup after the merge still works on a parked record.
#
# Each case is a lab home with a scratch bare remote, a project clone, and a
# scratch pool, so no real forge, pool, or endpoint is touched. treehouse, gh,
# no-mistakes, and herdr are fakes on PATH, and the control plane is a stub in a
# copied code root: the control plane's own suites own exit and relaunch.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tree-park)
fm_git_identity fmtest fmtest@example.invalid
BRANCH=fm/lab-task
URL=https://github.com/o/r/pull/42
ID=task-a

# make_lab <name>: print the case directory. Layout:
#   remote.git        scratch bare remote; project/ is its clone
#   pool/1/project    the task's leased slot, on $BRANCH at the pushed head
#   home/             the lab FM_HOME; root/bin is a copy of bin/ with a
#                     control-plane stub; fakebin/ holds the fake CLIs
make_lab() {
  local name=$1 dir head
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/pool" "$dir/fakebin" "$dir/root"
  git init -q --bare "$dir/remote.git"
  git clone -q "$dir/remote.git" "$dir/project" 2>/dev/null
  git -C "$dir/project" commit -q --allow-empty -m init
  git -C "$dir/project" push -q origin HEAD:refs/heads/main
  git -C "$dir/project" checkout -q -b "$BRANCH"
  printf 'change\n' > "$dir/project/change.txt"
  git -C "$dir/project" add change.txt
  git -C "$dir/project" commit -q -m change
  git -C "$dir/project" push -q origin "$BRANCH"
  git -C "$dir/project" checkout -q --detach
  printf '{}\n' > "$dir/pool/treehouse-state.json"
  mkdir -p "$dir/pool/1"
  git -C "$dir/project" worktree add -q "$dir/pool/1/project" "$BRANCH"
  git -C "$dir/pool/1/project" branch -q --set-upstream-to="origin/$BRANCH"
  head=$(git -C "$dir/pool/1/project" rev-parse HEAD)
  printf '%s\n' "$head" > "$dir/gh-head"
  printf '%s\n' '- project [no-mistakes merger=slarti] - fixture (added 2026-01-01)' > "$dir/home/data/projects.md"

  cp -R "$ROOT/bin" "$dir/root/bin"
  cat > "$dir/root/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
# Control-plane stub: records each verb; relaunch records the copy it was
# given so a case can check the replacement starts on the right head.
printf '%s\n' "$*" >> "$FM_TEST_LAB/control.log"
case "${2:-}" in
  exit) exit "${FM_TEST_CONTROL_EXIT_RC:-0}" ;;
  relaunch)
    wt=$(grep '^worktree=' "$FM_TEST_LAB/home/state/$1.meta" | tail -1 | cut -d= -f2-)
    printf 'relaunch worktree=%s head=%s branch=%s\n' "$wt" "$(git -C "$wt" rev-parse HEAD)" \
      "$(git -C "$wt" symbolic-ref --quiet --short HEAD)" >> "$FM_TEST_LAB/control.log"
    [ "${3:-}" != --note-file ] || cp "$4" "$FM_TEST_LAB/relaunch-note"
    exit "${FM_TEST_CONTROL_RELAUNCH_RC:-0}"
    ;;
esac
exit 2
SH
  chmod +x "$dir/root/bin/fm-control.sh"

  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# Scratch pool: get --lease adds the next slot, return resets and frees it.
printf '%s\n' "$*" >> "$FM_TEST_LAB/treehouse.log"
pool=$FM_TEST_LAB/pool
case "${1:-}" in
  get)
    n=1
    while [ -e "$pool/$n" ]; do n=$((n + 1)); done
    mkdir -p "$pool/$n"
    git -C "$PWD" worktree add -q --detach "$pool/$n/project" >/dev/null 2>&1 || exit 1
    printf '%s\n' "$pool/$n/project"
    ;;
  return)
    [ "${FM_TEST_TH_RETURN_RC:-0}" = 0 ] || { echo "return refused" >&2; exit "$FM_TEST_TH_RETURN_RC"; }
    wt=${3:-}
    git -C "$wt" checkout -q --detach && git -C "$wt" reset -q --hard && git -C "$wt" clean -fdq
    ;;
  *) exit 2 ;;
esac
SH
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "pr view" ] || exit 2
cat "$FM_TEST_LAB/gh-head"
SH
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "axi status" ] || exit 2
printf 'run:\n  id: r1\n  status: %s\n' "${FM_TEST_NM_STATUS:-handed_off}"
[ "${FM_TEST_NM_STATUS:-handed_off}" != handed_off ] || printf '  outcome: handed-off\n'
SH
  # A reachable session whose recorded pane is structurally gone, as it is once
  # treehouse return has stopped everything in the returned slot.
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_LAB/herdr.log"
case "${1:-} ${2:-}" in
  "session list") printf '{"sessions":[{"name":"lab","running":true,"socket_path":"%s/herdr.sock"}]}\n' "$FM_TEST_LAB" ;;
  "status --json") printf '%s\n' '{"server":{"running":true}}' ;;
  "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/treehouse" "$dir/fakebin/gh" "$dir/fakebin/no-mistakes" "$dir/fakebin/herdr"

  fm_write_meta "$dir/home/state/$ID.meta" \
    "window=lab:p1" \
    "endpoint_task_id=$ID" \
    "backend=herdr" \
    "herdr_session=lab" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t1" \
    "herdr_pane_id=p1" \
    "harness=claude" \
    "spawn_gen=fm.lab123456" \
    "worktree=$dir/pool/1/project" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr_at=1700000050" \
    "pr=$URL" \
    "pr_head=$head"
  chmod 0600 "$dir/home/state/$ID.meta"
  printf 'done [at=1700000100]: PR %s checks green\n' "$URL" > "$dir/home/state/$ID.status"
  printf '%s %s\n' "$URL" "$head" > "$dir/home/state/$ID.merge-handoff"
  cp "$dir/home/state/$ID.merge-handoff" "$dir/home/state/$ID.nm-released"
  FM_HOME="$dir/home" fm_treehouse_slot_owner_claim "$dir/pool/1/project" "$ID" "$dir/home" \
    || fail "$name: could not claim the lab slot"
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$ID") || fail "$name: could not arm busy state"
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/home/state" "$ID" idle --gen "$gen" --source claude-hook --event stop \
    || fail "$name: could not record an idle agent"
  : > "$dir/control.log"
  : > "$dir/treehouse.log"
  printf '%s\n' "$dir"
}

lab_env() {  # <dir> <command...>
  local dir=$1
  shift
  FM_TEST_LAB="$dir" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/root" FM_CONFIG_OVERRIDE="$dir/home/config" \
    PATH="$dir/fakebin:$PATH" "$@"
}

park() {  # <dir>
  lab_env "$1" "$1/root/bin/fm-tree-park.sh" park "$ID"
}

meta_value() {  # <dir> <key>
  grep "^$2=" "$1/home/state/$ID.meta" | tail -1 | cut -d= -f2- || true
}

assert_not_parked() {  # <dir> <label>
  local dir=$1 label=$2
  [ "$(meta_value "$dir" parked)" != 1 ] || fail "$label: an unsafe copy was parked"
  [ "$(meta_value "$dir" worktree)" = "$dir/pool/1/project" ] || fail "$label: the record stopped naming its copy"
  ! grep -q '^return' "$dir/treehouse.log" || fail "$label: an unsafe copy was returned to the pool"
  [ -d "$dir/pool/1/project" ] || fail "$label: the copy is gone"
}

test_parks_a_clean_handed_off_task() {
  local dir head out
  dir=$(make_lab park-clean)
  head=$(cat "$dir/gh-head")
  # Harness wiring in the copy is not work, so it does not stop a park.
  mkdir -p "$dir/pool/1/project/.claude"
  printf '{}\n' > "$dir/pool/1/project/.claude/settings.local.json"
  out=$(park "$dir" 2>"$dir/err") || fail "park-clean: a clean handed-off task did not park: $(cat "$dir/err")"
  case "$out" in "parked: $ID"*) ;; *) fail "park-clean: park did not report the release: $out" ;; esac
  [ "$(meta_value "$dir" parked)" = 1 ] || fail "park-clean: the record is not marked parked"
  [ -z "$(meta_value "$dir" worktree)" ] || fail "park-clean: the record still names the returned slot"
  [ "$(meta_value "$dir" parked_head)" = "$head" ] || fail "park-clean: the parked head is not the PR head"
  [ "$(meta_value "$dir" parked_branch)" = "$BRANCH" ] || fail "park-clean: the parked branch is wrong"
  [ "$(meta_value "$dir" parked_worktree)" = "$dir/pool/1/project" ] || fail "park-clean: the returned slot is not recorded"
  fm_pr_metadata_identity_parse "$dir/home/state/$ID.meta" && [ "$FM_PR_META_URL" = "$URL" ] \
    || fail "park-clean: the parked record no longer parses as a PR record"
  grep -qx "$ID exit --stop-background" "$dir/control.log" || fail "park-clean: the agent was not stopped through the control plane"
  grep -qx "return --force $dir/pool/1/project" "$dir/treehouse.log" || fail "park-clean: the slot was not returned"
  [ ! -e "$dir/pool/1/.fm-slot-owner" ] || fail "park-clean: the slot claim was left behind"
  [ ! -e "$dir/pool/1/project/.claude/settings.local.json" ] || fail "park-clean: the harness wiring stayed in the returned slot"
  [ -f "$dir/home/state/$ID.status" ] && [ -f "$dir/home/state/$ID.merge-handoff" ] \
    || fail "park-clean: the task's status or handoff record was removed"
  [ "$(wc -l < "$dir/home/state/$ID.status" | tr -d ' ')" = 1 ] || fail "park-clean: park wrote to the task's status"
  bash -c '. "$1/bin/fm-classify-lib.sh"; . "$1/bin/fm-office-authority-lib.sh"; fm_office_task_landing "$2" "$3" main' \
    _ "$ROOT" "$dir/home/state" "$ID" \
    || fail "park-clean: the parked task no longer reads as landing, so the watcher would alarm on its stopped worker"
  out=$(lab_env "$dir" "$dir/root/bin/fm-crew-state.sh" "$ID" 2>/dev/null) || true
  case "$out" in "state: done"*parked*) ;; *) fail "park-clean: crew state does not read the parked task as done: $out" ;; esac
  pass "a clean handed-off ship whose head is the pushed PR head returns its copy and keeps its record"
}

test_sweep_parks_once_per_handoff() {
  local dir out i
  dir=$(make_lab sweep)
  out=$(lab_env "$dir" "$dir/root/bin/fm-tree-park.sh" sweep 2>&1) || fail "sweep: the sweep failed: $out"
  [ -z "$out" ] || fail "sweep: a successful launch printed output: $out"
  i=0
  until [ "$(meta_value "$dir" parked)" = 1 ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ "$(meta_value "$dir" parked)" = 1 ] || fail "sweep: the detached park never finished: $(cat "$dir/home/state/$ID.park-log" 2>/dev/null)"
  lab_env "$dir" "$dir/root/bin/fm-tree-park.sh" sweep >/dev/null 2>&1 || fail "sweep: a second sweep failed"
  [ "$(grep -c '^return' "$dir/treehouse.log")" = 1 ] || fail "sweep: the copy was returned more than once"
  pass "the watcher sweep parks a candidate once per handoff, outside its own check bound"
}

test_sweep_reports_a_failure_after_the_agent_stopped_once() {
  local dir out
  dir=$(make_lab sweep-report)
  FM_TEST_TH_RETURN_RC=1 park "$dir" >/dev/null 2>&1 && fail "sweep-report: a failed return reported success"
  out=$(lab_env "$dir" "$dir/root/bin/fm-tree-park.sh" sweep 2>&1) || true
  case "$out" in *"$ID"*"treehouse return failed"*) ;; *) fail "sweep-report: the sweep did not report the failed return: $out" ;; esac
  out=$(lab_env "$dir" "$dir/root/bin/fm-tree-park.sh" sweep 2>&1) || true
  case "$out" in *"treehouse return failed"*) fail "sweep-report: the failure was reported twice: $out" ;; esac
  [ "$(meta_value "$dir" worktree)" = "$dir/pool/1/project" ] || fail "sweep-report: a failed return dropped the copy from the record"
  pass "a park that fails after it stopped the agent is reported once and keeps the record naming its copy"
}

test_refuses_each_unsafe_copy() {
  local dir
  dir=$(make_lab unsafe-dirty)
  printf 'edit\n' >> "$dir/pool/1/project/change.txt"
  park "$dir" >/dev/null 2>&1 && fail "unsafe-dirty: a tracked edit was parked"
  assert_not_parked "$dir" unsafe-dirty
  [ ! -s "$dir/control.log" ] || fail "unsafe-dirty: the agent was stopped for an unsafe copy"

  dir=$(make_lab unsafe-untracked)
  printf 'new\n' > "$dir/pool/1/project/new.txt"
  park "$dir" >/dev/null 2>&1 && fail "unsafe-untracked: an untracked file was parked"
  assert_not_parked "$dir" unsafe-untracked

  dir=$(make_lab unsafe-unpushed)
  git -C "$dir/pool/1/project" commit -q --allow-empty -m unpushed
  git -C "$dir/pool/1/project" rev-parse HEAD > "$dir/gh-head"
  park "$dir" >/dev/null 2>&1 && fail "unsafe-unpushed: an unpushed commit was parked"
  assert_not_parked "$dir" unsafe-unpushed

  dir=$(make_lab unsafe-mismatch)
  printf '%s\n' 1111111111111111111111111111111111111111 > "$dir/gh-head"
  park "$dir" >/dev/null 2>&1 && fail "unsafe-mismatch: a copy that is not the PR head was parked"
  assert_not_parked "$dir" unsafe-mismatch

  dir=$(make_lab unsafe-live-run)
  FM_TEST_NM_STATUS=running park "$dir" >/dev/null 2>&1 && fail "unsafe-live-run: a copy under a live run was parked"
  assert_not_parked "$dir" unsafe-live-run

  dir=$(make_lab unsafe-unreleased)
  rm -f "$dir/home/state/$ID.nm-released"
  park "$dir" >/dev/null 2>&1 && fail "unsafe-unreleased: a copy whose run was not released was parked"
  assert_not_parked "$dir" unsafe-unreleased

  dir=$(make_lab unsafe-steered)
  mkdir -p "$dir/home/state/$ID.inbox"
  printf 'restack\n' > "$dir/home/state/$ID.inbox/0001.msg"
  park "$dir" >/dev/null 2>&1 && fail "unsafe-steered: a task with a waiting steer was parked"
  assert_not_parked "$dir" unsafe-steered

  dir=$(make_lab unsafe-tmux)
  sed -i.bak 's/^backend=herdr$/backend=tmux/' "$dir/home/state/$ID.meta"
  park "$dir" >/dev/null 2>&1 && fail "unsafe-tmux: a task whose backend cannot relaunch it was parked"
  assert_not_parked "$dir" unsafe-tmux

  dir=$(make_lab unsafe-busy)
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/home/state" "$ID" busy --current-gen --source claude-hook --event prompt \
    || fail "unsafe-busy: could not record a busy agent"
  park "$dir" >/dev/null 2>&1 && fail "unsafe-busy: a busy agent's copy was parked"
  assert_not_parked "$dir" unsafe-busy

  dir=$(make_lab unsafe-unstopped)
  FM_TEST_CONTROL_EXIT_RC=1 park "$dir" >/dev/null 2>&1 && fail "unsafe-unstopped: a copy was parked without a proven stop"
  assert_not_parked "$dir" unsafe-unstopped
  pass "dirty, untracked, unpushed, mismatched, live-run, unreleased, steered, tmux, busy, and unstopped copies are never parked"
}

test_steer_unparks_on_the_recorded_head() {
  local dir head out new
  dir=$(make_lab unpark)
  head=$(cat "$dir/gh-head")
  park "$dir" >/dev/null 2>"$dir/err" || fail "unpark: setup park failed: $(cat "$dir/err")"
  # The returned slot is handed to other work meanwhile.
  git -C "$dir/pool/1/project" checkout -q --detach origin/main
  out=$(lab_env "$dir" "$dir/root/bin/fm-send.sh" "$ID" "restack onto main" 2>&1) \
    || fail "unpark: the steer to a parked task failed: $out"
  new=$(meta_value "$dir" worktree)
  [ -n "$new" ] && [ "$new" != "$dir/pool/1/project" ] || fail "unpark: the task was not given a fresh copy: $new"
  [ -z "$(meta_value "$dir" parked)" ] && [ -z "$(meta_value "$dir" parked_head)" ] \
    || fail "unpark: the parked fields stayed on the record"
  [ "$(git -C "$new" rev-parse HEAD)" = "$head" ] || fail "unpark: the fresh copy is not at the recorded head"
  [ "$(git -C "$new" symbolic-ref --quiet --short HEAD)" = "$BRANCH" ] || fail "unpark: the fresh copy is not on the PR branch"
  grep -qx "relaunch worktree=$new head=$head branch=$BRANCH" "$dir/control.log" \
    || fail "unpark: the worker was not relaunched in the fresh copy at the head: $(cat "$dir/control.log")"
  assert_grep "$head" "$dir/relaunch-note" "unpark: the relaunch note does not name the head"
  FM_HOME="$dir/home" fm_treehouse_slot_owner_state "$new" "$ID"
  [ "$FM_TREEHOUSE_SLOT_OWNER" = mine ] || fail "unpark: the fresh slot was not claimed for the task"
  grep -q "get --lease --lease-holder $ID" "$dir/treehouse.log" || fail "unpark: the fresh slot was not leased to the task"
  ls "$dir/home/state/$ID.inbox/"*.msg >/dev/null 2>&1 || fail "unpark: the steer was not recorded after the relaunch"
  grep -rqF 'restack onto main' "$dir/home/state/$ID.inbox" || fail "unpark: the recorded steer lost its text"
  pass "a steer to a parked task leases a fresh copy at the recorded PR head, relaunches the worker there, then records the steer"
}

test_refused_unpark_stays_parked_and_sends_nothing() {
  local dir out
  dir=$(make_lab unpark-moved)
  park "$dir" >/dev/null 2>"$dir/err" || fail "unpark-moved: setup park failed: $(cat "$dir/err")"
  printf '%s\n' 2222222222222222222222222222222222222222 > "$dir/gh-head"
  out=$(lab_env "$dir" "$dir/root/bin/fm-send.sh" "$ID" "fix the finding" 2>&1) \
    && fail "unpark-moved: a steer was sent although the PR head moved: $out"
  [ "$(meta_value "$dir" parked)" = 1 ] && [ -z "$(meta_value "$dir" worktree)" ] \
    || fail "unpark-moved: a refused unpark did not leave the task parked"
  ! ls "$dir/home/state/$ID.inbox/"*.msg >/dev/null 2>&1 || fail "unpark-moved: a refused unpark still recorded the steer"
  ! grep -q relaunch "$dir/control.log" || fail "unpark-moved: a refused unpark relaunched the worker"
  [ "$(grep -c '^return' "$dir/treehouse.log")" = 2 ] || fail "unpark-moved: the fresh slot was not returned: $(cat "$dir/treehouse.log")"

  dir=$(make_lab unpark-relaunch-fails)
  park "$dir" >/dev/null 2>"$dir/err" || fail "unpark-relaunch-fails: setup park failed: $(cat "$dir/err")"
  out=$(FM_TEST_CONTROL_RELAUNCH_RC=1 lab_env "$dir" "$dir/root/bin/fm-send.sh" "$ID" "fix the finding" 2>&1) \
    && fail "unpark-relaunch-fails: a steer was sent with no relaunched worker: $out"
  [ "$(meta_value "$dir" parked)" = 1 ] && [ -z "$(meta_value "$dir" worktree)" ] \
    || fail "unpark-relaunch-fails: a failed relaunch did not leave the task parked"
  ! ls "$dir/home/state/$ID.inbox/"*.msg >/dev/null 2>&1 || fail "unpark-relaunch-fails: the steer was recorded with no worker"

  out=$(lab_env "$dir" "$dir/root/bin/fm-send.sh" "$ID" --key Enter 2>&1) \
    && fail "unpark-relaunch-fails: a key was sent to a parked task: $out"
  case "$out" in *parked*) ;; *) fail "unpark-relaunch-fails: the key refusal does not say the task is parked: $out" ;; esac
  pass "an unpark that cannot match the head or relaunch the worker leaves the task parked and records no steer"
}

test_teardown_after_merge_on_a_parked_task() {
  local dir out
  dir=$(make_lab teardown)
  park "$dir" >/dev/null 2>"$dir/err" || fail "teardown: setup park failed: $(cat "$dir/err")"
  : > "$dir/treehouse.log"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$dir/home/data/backlog.md"
  printf 'manual\n' > "$dir/home/config/backlog-backend"
  out=$(lab_env "$dir" "$dir/root/bin/fm-teardown.sh" "$ID" 2>&1) || fail "teardown: cleanup of a parked task failed: $out"
  [ ! -e "$dir/home/state/$ID.meta" ] || fail "teardown: the parked record was not removed"
  ! grep -q '^return' "$dir/treehouse.log" || fail "teardown: cleanup returned a slot the parked task no longer holds"
  [ ! -e "$dir/home/state/$ID.park-attempt" ] && [ ! -e "$dir/home/state/$ID.merge-handoff" ] \
    || fail "teardown: the park records were left behind"
  pass "cleanup of a parked task after its merge removes the record without touching the pool"
}

fm_test_run \
  test_parks_a_clean_handed_off_task \
  test_sweep_parks_once_per_handoff \
  test_sweep_reports_a_failure_after_the_agent_stopped_once \
  test_refuses_each_unsafe_copy \
  test_steer_unparks_on_the_recorded_head \
  test_refused_unpark_stays_parked_and_sends_nothing \
  test_teardown_after_merge_on_a_parked_task
