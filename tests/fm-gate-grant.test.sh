#!/usr/bin/env bash
# tests/fm-gate-grant.test.sh - bin/fm-gate-grant.sh: a recorded, scoped grant
# of the project's gate-edit permission reaches a worker through the launch
# path, survives a relaunch, and is never set for a task without one.
#
# Like tests/fm-spawn-compact-adviser-disable.test.sh, the assertions drive the
# real spawn and the real fm-control relaunch against a fake pane, then EXECUTE
# the launch command the pane received with the harness replaced by a probe that
# prints the environment it started with. The cleanup and PR-registration
# revokes are covered in tests/fm-teardown.test.sh and
# tests/fm-pr-check-security.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

GRANT="$ROOT/bin/fm-gate-grant.sh"
CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-gate-grant)

# make_home <name> <id>: a home with one ship task record. Echoes the home dir.
make_home() {
  local name=$1 id=$2 home="$TMP_ROOT/$1/home"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  {
    echo "kind=ship"
    echo "mode=no-mistakes"
  } > "$home/state/$id.meta"
  printf '%s\n' "$home"
}

grant_cmd() { # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$GRANT" "$@"
}

write_decision() { printf '%s\n' "$2" > "$1/decision"; }

# The probe prints both variables as the launched agent saw them.
install_probe() { # <fakebin> <harness>
  cat > "$1/$2" <<'SH'
#!/bin/sh
printf '%s|%s\n' "${ALLOW_GATE_EDIT-unset}" "${ALLOW_GATE_EDIT_FILES-unset}"
SH
  chmod +x "$1/$2"
}

# Run a launch command in a synthetic pane. With "stale" the pane shell still
# holds an earlier launch's grant: a launch that no longer holds the grant must
# drop it, not inherit it.
run_launch() { # <fakebin> <launch-text> [stale]
  if [ "${3:-}" = stale ]; then
    env -i HOME="$TMP_ROOT/pane-home" PATH="$1:$PATH" TERM=xterm TMUX=synthetic-pane \
      ALLOW_GATE_EDIT=1 ALLOW_GATE_EDIT_FILES=stale.sh /bin/sh -c "$2"
  else
    env -i HOME="$TMP_ROOT/pane-home" PATH="$1:$PATH" TERM=xterm TMUX=synthetic-pane /bin/sh -c "$2"
  fi
}

spawn_case() { # <name> <id>: spawn the task, leaving the launch text in $dir/launch.log
  local name=$1 id=$2 home dir fakebin wt proj out status
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  fm_git_worktree "$proj" "$wt" "wt-$name"
  : > "$dir/launch.log"
  : > "$dir/pane.log"
  out=$(FM_FAKE_LAUNCH_LOG="$dir/launch.log" FM_FAKE_PANE_LOG="$dir/pane.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "spawn of $id should succeed: $out"
  install_probe "$fakebin" codex
  printf '%s\n' "$fakebin" > "$dir/fakebin.path"
}

test_task_without_a_grant_gets_no_variable() {
  local home dir seen
  home=$(make_home nogrant gg-none)
  dir="$TMP_ROOT/nogrant"
  spawn_case nogrant gg-none
  seen=$(run_launch "$(cat "$dir/fakebin.path")" "$(cat "$dir/launch.log")") || fail "launch failed to run"
  assert_equals 'unset|unset' "$seen" "a task with no grant must start with neither variable"
  assert_not_contains "$(cat "$dir/launch.log")" ALLOW_GATE_EDIT "a task that never held a grant must launch exactly as before"
  [ ! -e "$home/data/gg-none/gate-grant.log" ] || fail "a launch with no grant wrote a grant log"
  pass "a task without a grant starts with no gate-edit variable"
}

test_spawn_carries_a_live_grant() {
  local home dir seen
  home=$(make_home carry gg-carry)
  dir="$TMP_ROOT/carry"
  write_decision "$dir" "firstmate grants gate.sh and hooks/pre-commit.sh for the PR; the edit only adds a check"
  grant_cmd "$home" grant gg-carry --files gate.sh,hooks/pre-commit.sh --pr none --kind tighten \
    --decision-file "$dir/decision" >/dev/null || fail "grant refused"
  spawn_case carry gg-carry
  seen=$(run_launch "$(cat "$dir/fakebin.path")" "$(cat "$dir/launch.log")") || fail "launch failed to run"
  assert_equals '1|gate.sh,hooks/pre-commit.sh' "$seen" "the worker must start with the grant scoped to the named files"
  grep -q ' carry kind=tighten files=gate.sh,hooks/pre-commit.sh' "$home/data/gg-carry/gate-grant.log" \
    || fail "the carry was not logged"
  # Nothing is written into the worker's gate-protected settings files.
  if [ -e "$dir/wt/.claude/settings.local.json" ]; then
    grep -q 'ALLOW_GATE_EDIT' "$dir/wt/.claude/settings.local.json" \
      && fail "the grant was written into the worker's settings.local.json"
  fi
  pass "spawn carries a live grant into the worker's environment, scoped to the named files"
}

# The strictest launch-env-allowlist posture clears the agent's environment to
# Firstmate's own floor; the grant must still arrive, and a task with no grant
# must still start with neither variable.
test_grant_survives_the_launch_env_allowlist() {
  local home dir seen
  home=$(make_home allow gg-allow)
  dir="$TMP_ROOT/allow"
  : > "$home/config/launch-env-allowlist"
  write_decision "$dir" 'firstmate grants gate.sh for the PR; the edit only tightens a check'
  grant_cmd "$home" grant gg-allow --files gate.sh --pr none --kind tighten --decision-file "$dir/decision" >/dev/null \
    || fail "grant refused"
  spawn_case allow gg-allow
  assert_contains "$(cat "$dir/launch.log")" '/usr/bin/env -i' "the allowlist should launch under a cleared environment"
  seen=$(run_launch "$(cat "$dir/fakebin.path")" "$(cat "$dir/launch.log")") || fail "launch failed to run"
  assert_equals '1|gate.sh' "$seen" "the grant must survive the cleared allowlisted environment"
  home=$(make_home allow-none gg-allow-none)
  dir="$TMP_ROOT/allow-none"
  : > "$home/config/launch-env-allowlist"
  spawn_case allow-none gg-allow-none
  seen=$(run_launch "$(cat "$dir/fakebin.path")" "$(cat "$dir/launch.log")") || fail "launch failed to run"
  assert_equals 'unset|unset' "$seen" "a task with no grant must start with neither variable under the allowlist either"
  pass "the grant survives the launch-env allowlist, and a task without one still gets neither variable there"
}

test_relaunch_keeps_a_live_grant_and_drops_a_revoked_one() {
  local home dir id=gg-relaunch out status seen launch
  home=$(make_home relaunch "$id")
  dir="$TMP_ROOT/relaunch"
  mkdir -p "$dir/fake" "$dir/user-home"
  fm_test_fake_tmux_relaunch "$dir/fakebin"
  fm_git_worktree "$dir/proj" "$dir/wt" wt-relaunch
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/wt"
    echo "project=$dir/proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$dir/tasktmp"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  write_decision "$dir" 'Lee, main chat, 2026-11-13: "yes, loosen gate.sh for this PR"'
  grant_cmd "$home" grant "$id" --files gate.sh --pr none --kind signoff --decision-file "$dir/decision" >/dev/null \
    || fail "grant refused"
  install_probe "$dir/fakebin" codex
  relaunch() {
    : > "$dir/fake/literal"; : > "$dir/fake/keys"
    printf 'codex' > "$dir/fake/command"
    printf '%s\n' "fm-$id" > "$dir/fake/windows"
    printf '%s' "$dir/wt" > "$dir/fake/cwd"
    rm -f "$dir/fake/launch"
    out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
      HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
      "$CONTROL" "$id" relaunch --note 'replacement continues the same task' 2>&1)
    status=$?
    expect_code 0 "$status" "relaunch should succeed: $out"
    launch=$(cat "$dir/fake/launch" 2>/dev/null)
    [ -n "$launch" ] || fail "relaunch sent no replacement launch command"
    run_launch "$dir/fakebin" "$launch" stale || fail "the replacement launch failed to run"
  }
  seen=$(relaunch)
  assert_equals '1|gate.sh' "$seen" "a relaunch must keep a live grant"
  seen=$(relaunch)
  assert_equals '1|gate.sh' "$seen" "a second relaunch must still keep it"
  [ "$(grep -c ' carry ' "$home/data/$id/gate-grant.log")" -ge 2 ] || fail "each relaunch carry must be logged"
  grant_cmd "$home" revoke "$id" --reason test >/dev/null || fail "revoke failed"
  seen=$(relaunch)
  assert_equals 'unset|unset' "$seen" "a relaunch after a revoke must carry nothing, and must drop the variable a pane shell kept"
  pass "relaunch keeps a live grant and drops a revoked one"
}

test_a_grant_without_a_decision_is_refused() {
  local home dir out status
  home=$(make_home refuse gg-refuse)
  dir="$TMP_ROOT/refuse"
  : > "$dir/empty"
  printf '  \n\t\n' > "$dir/blank"
  for f in "$dir/empty" "$dir/blank" "$dir/missing"; do
    out=$(grant_cmd "$home" grant gg-refuse --files gate.sh --pr none --kind signoff --decision-file "$f" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "a grant with decision file ${f##*/} was accepted: $out"
    [ ! -e "$home/state/gg-refuse.gate-grant" ] || fail "a refused grant left a record (${f##*/})"
  done
  out=$(grant_cmd "$home" grant gg-refuse --files gate.sh --pr none --kind signoff 2>&1) \
    && fail "a grant with no --decision-file was accepted: $out"
  out=$(printf '' | grant_cmd "$home" grant gg-refuse --files gate.sh --pr none --kind signoff --decision-file - 2>&1) \
    && fail "a grant with an empty stdin decision was accepted: $out"
  [ ! -e "$home/state/gg-refuse.gate-grant" ] || fail "a refused grant left a record"
  pass "a grant with an empty or missing decision is refused and leaves no record"
}

test_grant_validation() {
  local home dir bad
  home=$(make_home valid gg-valid)
  dir="$TMP_ROOT/valid"
  write_decision "$dir" 'firstmate grants gate.sh'
  for bad in '' '/etc/passwd' '../gate.sh' 'a/../b.sh' 'a b.sh' 'a;b.sh' "a'b.sh" '*.sh' 'a,,b.sh' 'a.sh,' './a.sh' 'a//b.sh'; do
    grant_cmd "$home" grant gg-valid --files "$bad" --pr none --kind tighten --decision-file "$dir/decision" >/dev/null 2>&1 \
      && fail "the file list '$bad' was accepted"
  done
  grant_cmd "$home" grant gg-valid --files gate.sh --pr 12 --kind tighten --decision-file "$dir/decision" >/dev/null 2>&1 \
    && fail "a bare PR number was accepted"
  grant_cmd "$home" grant gg-valid --files gate.sh --pr none --kind loosen --decision-file "$dir/decision" >/dev/null 2>&1 \
    && fail "an unknown kind was accepted"
  grant_cmd "$home" grant gg-nosuch --files gate.sh --pr none --kind tighten --decision-file "$dir/decision" >/dev/null 2>&1 \
    && fail "a grant for a task with no record was accepted"
  grant_cmd "$home" grant gg-valid --files gate.sh --pr https://github.com/o/r/pull/9 --kind tighten \
    --decision-file "$dir/decision" >/dev/null || fail "a valid grant was refused"
  grant_cmd "$home" grant gg-valid --files other.sh --pr none --kind tighten --decision-file "$dir/decision" >/dev/null 2>&1 \
    && fail "a second grant silently replaced the first"
  grant_cmd "$home" show gg-valid | grep -q 'files=gate.sh pr=https://github.com/o/r/pull/9' || fail "show did not report the grant"
  grant_cmd "$home" revoke gg-valid >/dev/null || fail "revoke failed"
  grant_cmd "$home" revoke gg-valid | grep -q 'no gate grant' || fail "a second revoke was not an idempotent no-op"
  pass "grant validates files, PR, kind and task, refuses a second grant, and revoke is idempotent"
}

test_a_damaged_record_carries_nothing() {
  local home dir out status
  home=$(make_home damaged gg-damaged)
  dir="$TMP_ROOT/damaged"
  write_decision "$dir" 'firstmate grants gate.sh'
  grant_cmd "$home" grant gg-damaged --files gate.sh --pr none --kind tighten --decision-file "$dir/decision" >/dev/null \
    || fail "grant refused"
  printf 'rewritten after the grant\n' > "$home/state/gg-damaged.gate-grant.decision"
  out=$(grant_cmd "$home" env gg-damaged 2>/dev/null)
  status=$?
  [ "$status" -ne 0 ] || fail "a record whose decision changed was carried"
  case "$out" in *'export ALLOW_GATE_EDIT=1'*) fail "a damaged record set the variable: $out" ;; esac
  grep -q ' carry-refused ' "$home/data/gg-damaged/gate-grant.log" || fail "the refused carry was not logged"
  pass "a record that is not whole is never carried"
}

test_env_prefix_follows_the_grant_lifecycle() {
  local home dir
  home=$(make_home prefix gg-prefix)
  dir="$TMP_ROOT/prefix"
  write_decision "$dir" 'firstmate grants gate.sh'
  [ -z "$(grant_cmd "$home" env gg-prefix)" ] || fail "a task that never held a grant got a prefix"
  grant_cmd "$home" grant gg-prefix --files gate.sh --pr none --kind tighten --decision-file "$dir/decision" >/dev/null \
    || fail "grant refused"
  assert_contains "$(grant_cmd "$home" env gg-prefix)" "export ALLOW_GATE_EDIT_FILES='gate.sh'" "a live grant must be exported"
  grant_cmd "$home" revoke gg-prefix >/dev/null || fail "revoke failed"
  assert_equals 'unset ALLOW_GATE_EDIT ALLOW_GATE_EDIT_FILES; ' "$(grant_cmd "$home" env gg-prefix)" \
    "a carried then revoked grant must drop the variable a pane shell kept"
  grant_cmd "$home" revoke gg-prefix --reason 'task cleanup' --forget-carry >/dev/null || fail "cleanup revoke failed"
  [ -z "$(grant_cmd "$home" env gg-prefix)" ] || fail "cleanup left the carried marker behind"
  pass "the launch prefix follows the grant: nothing, export, unset, then nothing after cleanup"
}

test_task_without_a_grant_gets_no_variable
test_env_prefix_follows_the_grant_lifecycle
test_spawn_carries_a_live_grant
test_grant_survives_the_launch_env_allowlist
test_relaunch_keeps_a_live_grant_and_drops_a_revoked_one
test_a_grant_without_a_decision_is_refused
test_grant_validation
test_a_damaged_record_carries_nothing
