#!/usr/bin/env bash
# tests/fm-backend-herdr-workspace-per-home-e2e.test.sh - mandatory ISOLATED
# end-to-end real-herdr test for the P3 "workspace-per-home" pass (AGENTS.md
# task herdr-sm-spaces-k4). Drives the REAL bin/fm-spawn.sh and
# bin/fm-teardown.sh (not just adapter primitives), because the requirement
# under test - a --secondmate spawn's tab landing in the secondmate's OWN
# herdr workspace, and a crewmate spawned FROM a secondmate home landing there
# too - only exists at fm-spawn.sh's own home-shadowing logic (the herdr case
# arm) and at fm_backend_herdr_workspace_label's FM_HOME read; neither is
# exercised by the adapter-primitive smoke test.
#
# Mirrors tests/fm-backend-autodetect-smoke.test.sh's isolated-session
# convention: a private throwaway HERDR_SESSION (never the captain's
# default), scratch FM_HOME(s), and scratch local-only projects.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): cleanup uses
# ONLY herdr_safe_stop_and_delete, never a bare/inline-prefixed `herdr server
# stop`.
#
# Covers, at minimum (per the task brief):
#   - a primary-shaped home (no .fm-secondmate-home marker) spawning a
#     crewmate into the "firstmate" workspace
#   - a secondmate-shaped home (with .fm-secondmate-home) getting its own
#     labeled workspace when the PRIMARY spawns it (fm-spawn.sh's FM_HOME
#     shadow for --secondmate)
#   - a crewmate spawned FROM that secondmate-shaped home (the secondmate
#     running its OWN fm-spawn.sh) landing in the secondmate's own workspace -
#     this exact path has never run before this test
#   - an office spawned by the primary showing its bare role name on its tab
#   - steer, interrupt, exit and relaunch each finding the recorded pane, for
#     both the office and an ordinary crewmate, and a relaunch giving an
#     office tab still labeled fm-<id> its role name back
#   - teardown closing the right tab (and no other)
#   - list-live recovery finding exactly the tasks each home recorded
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}
assert_not_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

# TMP_ROOT is physically resolved (mktemp -d "$(pwd -P)"-relative) for the same
# low-noise scratch fixture shape used by
# tests/fm-backend-autodetect-smoke.test.sh.
# fm-spawn no longer needs this as a symlink workaround: fm-spawn-symlink-guard-s8
# canonicalized project and backend cwd comparisons in the worktree-discovery
# poll.
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-e2e.XXXXXX")
SESSION="fm-lab-herdr-e2e-$$"
export HERDR_SESSION="$SESSION"
WT1=; WT2=
cleanup_all() {
  [ -n "$WT1" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT1" >/dev/null 2>&1
  [ -n "$WT2" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT2" >/dev/null 2>&1
  herdr_safe_stop_and_delete "$SESSION"
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
  fm_test_cleanup
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- scratch world: a primary-shaped home, a secondmate-shaped home, two projects ---

# This test asserts the per-home FLAT workspace shape, so both homes opt out of
# the default-on presentation projection rather than depending on that default.
PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data/cm1" "$PRIMARY_HOME/config"
printf 'off\n' > "$PRIMARY_HOME/config/herdr-presentation-spaces"
cat > "$PRIMARY_HOME/data/cm1/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise primary-home Herdr placement.

## Firstmate spec
Verify the crewmate uses its primary home's workspace.
EOF

SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/data/cm2" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin"
printf 'off\n' > "$SM_HOME/config/herdr-presentation-spaces"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf 'e2esm1\n' > "$SM_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM_HOME/data/charter.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$SM_HOME/.gitignore"
git -C "$SM_HOME" init -q -b main
cat > "$SM_HOME/data/cm2/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise secondmate-owned Herdr placement.

## Firstmate spec
Verify the crewmate uses its secondmate home's workspace.
EOF

make_scratch_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

PROJ1="$TMP_ROOT/scratch-project-1"; make_scratch_project "$PROJ1"
PROJ2="$TMP_ROOT/scratch-project-2"; make_scratch_project "$PROJ2"

# --- 1. primary-shaped home: a crewmate spawns into the "firstmate" space ---

CM1_OUT="$TMP_ROOT/cm1.out"; CM1_ERR="$TMP_ROOT/cm1.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm1 "$PROJ1" "sh -c 'echo primary-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM1_OUT" 2>"$CM1_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "primary-shaped crewmate spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM1_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM1_ERR")"

CM1_META="$PRIMARY_HOME/state/cm1.meta"
[ -f "$CM1_META" ] || fail "no meta written for cm1"
assert_contains_local "$(cat "$CM1_META")" "backend=herdr" "cm1 meta missing backend=herdr"
WT1=$(grep '^worktree=' "$CM1_META" | cut -d= -f2-)
CM1_PANE=$(grep '^herdr_pane_id=' "$CM1_META" | cut -d= -f2-)
[ -n "$CM1_PANE" ] || fail "cm1 meta missing herdr_pane_id"
pass "real herdr E2E: a primary-shaped home spawns a crewmate on the herdr backend"

sleep 1
CM1_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM1_PANE" 30) || fail "capture failed on cm1's pane"
assert_contains_local "$CM1_CAPTURE" "primary-crew-ok" "cm1's raw launch command did not run in its herdr pane"

CM1_WSID=$(herdr pane get "$CM1_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM1_WSID" ] || fail "could not read cm1's pane workspace_id"
CM1_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$CM1_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$CM1_WS_LABEL" = "firstmate" ] || fail "a primary-shaped home's crewmate should land in the 'firstmate' workspace, got '$CM1_WS_LABEL'"
pass "real herdr E2E: the primary-shaped home's crewmate landed in the 'firstmate' workspace"

# --- 2. the PRIMARY spawns a secondmate: its tab lands in the SECONDMATE's own space ---
# (fm-spawn.sh's herdr case arm shadows FM_HOME to the secondmate's home for
# exactly this call - AGENTS.md task herdr-sm-spaces-k4, requirement 3.)

SM_OUT="$TMP_ROOT/sm.out"; SM_ERR="$TMP_ROOT/sm.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" e2esm1 "$SM_HOME" "sh -c 'echo secondmate-launch-ok'" --secondmate --backend herdr \
  >"$SM_OUT" 2>"$SM_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "the primary's --secondmate spawn of e2esm1 failed"$'\n'"--- stdout ---"$'\n'"$(cat "$SM_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$SM_ERR")"

SM_META="$PRIMARY_HOME/state/e2esm1.meta"
[ -f "$SM_META" ] || fail "no meta written for e2esm1 (recorded in the PRIMARY's own state dir, since the primary did the spawning)"
assert_contains_local "$(cat "$SM_META")" "kind=secondmate" "e2esm1 meta missing kind=secondmate"
assert_contains_local "$(cat "$SM_META")" "backend=herdr" "e2esm1 meta missing backend=herdr"
assert_contains_local "$(cat "$SM_META")" "home=$SM_HOME" "e2esm1 meta does not record its own home"
SM_PANE=$(grep '^herdr_pane_id=' "$SM_META" | cut -d= -f2-)
[ -n "$SM_PANE" ] || fail "e2esm1 meta missing herdr_pane_id"
pass "real herdr E2E: the primary spawns a --secondmate task on the herdr backend"

SM_WSID=$(herdr pane get "$SM_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$SM_WSID" ] || fail "could not read e2esm1's pane workspace_id"
[ "$SM_WSID" != "$CM1_WSID" ] || fail "the secondmate's tab must NOT land in the primary's workspace, but it shares $CM1_WSID"
SM_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$SM_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$SM_WS_LABEL" = "2ndmate-e2esm1" ] || fail "a --secondmate spawn should land in '2ndmate-<id>', got '$SM_WS_LABEL'"
pass "real herdr E2E: a --secondmate spawn by the PRIMARY lands in the SECONDMATE's own labeled workspace, distinct from the primary's"

# --- 3. a crewmate spawned FROM the secondmate-shaped home lands in the SAME
# secondmate workspace (this exact path has never run before this test) -----

CM2_OUT="$TMP_ROOT/cm2.out"; CM2_ERR="$TMP_ROOT/cm2.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$SM_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm2 "$PROJ2" "sh -c 'echo sm-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM2_OUT" 2>"$CM2_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "a crewmate spawned FROM the secondmate-shaped home failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM2_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM2_ERR")"

CM2_META="$SM_HOME/state/cm2.meta"
[ -f "$CM2_META" ] || fail "no meta written for cm2 (recorded in the SECONDMATE's own state dir - it did its own spawning)"
assert_contains_local "$(cat "$CM2_META")" "backend=herdr" "cm2 meta missing backend=herdr"
WT2=$(grep '^worktree=' "$CM2_META" | cut -d= -f2-)
CM2_PANE=$(grep '^herdr_pane_id=' "$CM2_META" | cut -d= -f2-)
[ -n "$CM2_PANE" ] || fail "cm2 meta missing herdr_pane_id"
pass "real herdr E2E: a crewmate spawns successfully FROM a secondmate-shaped home's own fm-spawn.sh process"

sleep 1
CM2_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM2_PANE" 30) || fail "capture failed on cm2's pane"
assert_contains_local "$CM2_CAPTURE" "sm-crew-ok" "cm2's raw launch command did not run in its herdr pane"

CM2_WSID=$(herdr pane get "$CM2_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ "$CM2_WSID" = "$SM_WSID" ] || fail "a crewmate spawned FROM the secondmate home should land in the SAME workspace as the secondmate's own task ($SM_WSID), got '$CM2_WSID'"
[ "$CM2_WSID" != "$CM1_WSID" ] || fail "a crewmate spawned FROM the secondmate home must NOT land in the primary's workspace"
pass "real herdr E2E: a crewmate spawned FROM the secondmate-shaped home lands in the secondmate's OWN workspace - falls out of per-home resolution, no glue needed"

# --- 3b. the PRIMARY spawns an OFFICE: its tab shows the bare role name -----

OFFICE_HOME="$TMP_ROOT/office-home"
mkdir -p "$OFFICE_HOME/state" "$OFFICE_HOME/data" "$OFFICE_HOME/config" "$OFFICE_HOME/projects" "$OFFICE_HOME/bin"
printf 'off\n' > "$OFFICE_HOME/config/herdr-presentation-spaces"
printf '# scratch office home AGENTS.md placeholder\n' > "$OFFICE_HOME/AGENTS.md"
printf 'e2eqm\n' > "$OFFICE_HOME/.fm-secondmate-home"
printf 'e2eqm\n' > "$OFFICE_HOME/.fm-office"
printf '# Office authority\nTrivial e2e office: nothing to do.\n' > "$OFFICE_HOME/data/charter.md"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PRIMARY_HOME" > "$OFFICE_HOME/.fm-secondmate-parent"
printf -- '- e2eqm - Run the fleet. (role: quartermaster; added 2026-11-05)\n' > "$PRIMARY_HOME/data/offices.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$OFFICE_HOME/.gitignore"
git -C "$OFFICE_HOME" init -q -b main

QM_OUT="$TMP_ROOT/qm.out"; QM_ERR="$TMP_ROOT/qm.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" e2eqm "$OFFICE_HOME" "sh -c 'echo office-launch-ok'" --secondmate --backend herdr \
  >"$QM_OUT" 2>"$QM_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "the primary's --secondmate spawn of office e2eqm failed"$'\n'"--- stdout ---"$'\n'"$(cat "$QM_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$QM_ERR")"
QM_META="$PRIMARY_HOME/state/e2eqm.meta"
QM_PANE=$(grep '^herdr_pane_id=' "$QM_META" | cut -d= -f2-)
QM_TAB=$(grep '^herdr_tab_id=' "$QM_META" | cut -d= -f2-)
[ -n "$QM_PANE" ] && [ -n "$QM_TAB" ] || fail "office e2eqm's record lacks its herdr ids"
QM_TAB_LABEL=$(herdr tab get "$QM_TAB" --session "$SESSION" 2>/dev/null | jq -r '.result.tab.label // empty')
[ "$QM_TAB_LABEL" = Quartermaster ] || fail "an office's own tab should carry its bare role name, got '$QM_TAB_LABEL'"
QM_WSID=$(herdr pane get "$QM_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
QM_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$QM_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$QM_WS_LABEL" = Quartermaster ] || fail "an office's workspace should carry its bare role name, got '$QM_WS_LABEL'"
pass "real herdr E2E: an office spawned by the primary shows its bare role name on both its workspace and its tab"

# --- 3c. steer, interrupt, exit and relaunch find the recorded pane --------
#
# Each control path resolves the task through its record in the spawning home,
# never through the tab title, so the role-named office tab and the fm-<id>
# crewmate tab must behave the same. The agent is a stand-in process named like
# a harness and registered with Herdr, as in tests/fm-control-herdr-smoke.test.sh.

STANDIN_BIN=$(fm_agent_standin "$TMP_ROOT/standin") || STANDIN_BIN=
if [ -z "$STANDIN_BIN" ]; then
  echo "skip: no long-running stand-in binary survives a rename; lifecycle control checks not run"
else
  mkdir -p "$TMP_ROOT/agentbin"
  ln -s "$STANDIN_BIN" "$TMP_ROOT/agentbin/claude"
  printf -v CLAUDE_Q '%q' "$TMP_ROOT/agentbin/claude"

  run_control() {  # <home> <id> <verb> [args...]
    local home=$1; shift
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 FM_CONTROL_LAUNCH_WAIT=20 \
      "$ROOT/bin/fm-control.sh" "$@" 2>&1
  }

  wait_process_state() {  # <pane> <expected>
    local i=0
    while [ "$i" -lt 50 ]; do
      [ "$(fm_backend_herdr_pane_process_state "$SESSION" "$1")" != "$2" ] || return 0
      sleep 0.1
      i=$((i + 1))
    done
    return 1
  }

  stop_agent() {  # <pane>
    local pid
    pid=$(herdr pane process-info --pane "$1" --session "$SESSION" 2>/dev/null \
      | jq -r '.result.process_info.foreground_processes[0].pid // empty')
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    herdr pane release-agent "$1" --source fm-e2e --agent fm-e2e-agent --session "$SESSION" >/dev/null 2>&1
    wait_process_state "$1" shell || fail "the stand-in agent in pane $1 did not stop"
  }

  lifecycle_check() {  # <home> <id> <pane>
    local home=$1 id=$2 pane=$3 meta="$1/state/$2.meta" out fakebin fakebin_q
    out=$(env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" HERDR_SESSION="$SESSION" \
      "$ROOT/bin/fm-send.sh" "$id" "e2e steer for $id" 2>&1) \
      || fail "fm-send could not steer $id through its record: $out"
    compgen -G "$home/state/$id.inbox/*.msg" >/dev/null \
      || fail "fm-send to $id left no durable record in $home/state/$id.inbox/"
    grep -q "e2e steer for $id" "$home/state/$id.inbox/"*.msg \
      || fail "$id's steering inbox does not hold the steer that was sent"
    pass "real herdr E2E: fm-send steers $id into its own durable inbox through its record"

    # The stand-in codex the relaunch starts goes on the pane's PATH in the same
    # line that starts the first stand-in, while the shell is at its prompt.
    # A line typed just after the stand-in is killed can reach the pane before
    # bash reads input again and arrive mangled.
    fakebin="$TMP_ROOT/fakebin-$id"
    mkdir -p "$fakebin/agent"
    ln -s "$STANDIN_BIN" "$fakebin/agent/codex"
    cat > "$fakebin/codex" <<EOF
#!/usr/bin/env bash
herdr pane report-agent '$pane' --source fm-e2e --agent fm-e2e-agent --state idle --session '$SESSION' >/dev/null 2>&1
exec '$fakebin/agent/codex' 900
EOF
    chmod +x "$fakebin/codex"
    printf -v fakebin_q '%q' "$fakebin"

    awk -F= '$1 == "harness" {$0="harness=claude"} {print}' "$meta" > "$meta.tmp" && mv "$meta.tmp" "$meta"
    fm_backend_herdr_send_text_line "$SESSION:$pane" "export PATH=$fakebin_q:\$PATH; $CLAUDE_Q 900" \
      || fail "could not start the stand-in agent in $id's pane"
    wait_process_state "$pane" agent || fail "the stand-in agent in $id's pane is not seen as an agent"
    herdr pane report-agent "$pane" --source fm-e2e --agent fm-e2e-agent --state idle \
      --session "$SESSION" >/dev/null 2>&1 || fail "could not register the stand-in agent on $id's pane"
    out=$(run_control "$home" "$id" interrupt) || fail "interrupt of $id failed: $out"
    assert_contains_local "$out" "interrupt-delivered $id harness=claude backend=herdr verified=agent-alive" \
      "interrupt of $id did not prove the agent on its recorded pane survived"
    pass "real herdr E2E: interrupt reaches $id's recorded pane"

    stop_agent "$pane"
    out=$(run_control "$home" "$id" exit) || fail "exit of $id failed: $out"
    assert_contains_local "$out" "already-stopped $id" "exit of $id did not read its recorded pane as stopped"
    assert_contains_local "$out" "endpoint=$SESSION:$pane" "exit of $id read an endpoint other than its recorded pane"
    pass "real herdr E2E: exit finds $id's recorded pane stopped"

    out=$(run_control "$home" "$id" relaunch --harness codex --note "e2e relaunch of $id") \
      || fail "relaunch of $id failed: $out"
    assert_contains_local "$out" "relaunched $id harness=codex" "relaunch of $id did not report the codex replacement"
    assert_contains_local "$out" "endpoint=$SESSION:$pane" "relaunch of $id did not confirm its replacement on the recorded pane"
    [ "$(sed -n 's/^window=//p' "$meta" | tail -1)" = "$SESSION:$pane" ] \
      || fail "relaunch of $id replaced its endpoint instead of reusing its pane"
    [ "$(sed -n 's/^herdr_pane_id=//p' "$meta" | tail -1)" = "$pane" ] \
      || fail "relaunch of $id rebound its record to another pane"
    pass "real herdr E2E: relaunch of $id reuses its recorded pane"

    stop_agent "$pane"
  }

  lifecycle_check "$PRIMARY_HOME" cm1 "$CM1_PANE"
  [ "$(herdr tab get "$(grep '^herdr_tab_id=' "$CM1_META" | cut -d= -f2-)" --session "$SESSION" 2>/dev/null \
    | jq -r '.result.tab.label // empty')" = fm-cm1 ] \
    || fail "an ordinary crewmate's tab must keep its fm-<id> label through a relaunch"

  herdr tab rename "$QM_TAB" fm-e2eqm --session "$SESSION" >/dev/null 2>&1 \
    || fail "could not give the office tab its earlier fm-<id> label"
  [ "$(herdr tab get "$QM_TAB" --session "$SESSION" 2>/dev/null | jq -r '.result.tab.label // empty')" = fm-e2eqm ] \
    || fail "the office tab did not take the earlier fm-<id> label"
  lifecycle_check "$PRIMARY_HOME" e2eqm "$QM_PANE"
  [ "$(sed -n 's/^herdr_tab_id=//p' "$QM_META" | tail -1)" = "$QM_TAB" ] \
    || fail "relaunch of the office rebound its record to another tab"
  QM_TAB_LABEL=$(herdr tab get "$QM_TAB" --session "$SESSION" 2>/dev/null | jq -r '.result.tab.label // empty')
  [ "$QM_TAB_LABEL" = Quartermaster ] \
    || fail "relaunching an office whose tab still says fm-e2eqm should rename that same tab to its role name, got '$QM_TAB_LABEL'"
  pass "real herdr E2E: relaunching an office renames its earlier fm-<id> tab to its role name in place"
fi

# --- 4. list-live recovery: each home sees only its own tabs ---------------

# list_live finds a home's direct reports by the herdr ids in that home's own
# records, so the primary sees the secondmate it spawned (its record is in the
# primary's state) wherever that secondmate's tab lives, and never the
# secondmate's own crewmate, whose record lives in the secondmate's home.
PRIMARY_LIVE=$(FM_HOME="$PRIMARY_HOME" fm_backend_herdr_list_live "$SESSION")
assert_contains_local "$PRIMARY_LIVE" "fm-cm1" "the primary home's list_live did not see its own task"
assert_contains_local "$PRIMARY_LIVE" "$SESSION:$SM_PANE"$'\t'"fm-e2esm1" "the primary home's list_live did not find the secondmate it recorded by its recorded pane"
assert_contains_local "$PRIMARY_LIVE" "$SESSION:$QM_PANE"$'\t'"fm-e2eqm" "the primary home's list_live did not find the office by its record despite its role-name tab"
assert_not_contains_local "$PRIMARY_LIVE" "fm-cm2" "the primary home's list_live must not see the secondmate-owned crewmate's task"
pass "real herdr E2E: list_live from the primary's own context sees exactly the tasks the primary recorded"

SM_LIVE=$(FM_HOME="$SM_HOME" fm_backend_herdr_list_live "$SESSION")
assert_contains_local "$SM_LIVE" "fm-e2esm1" "the secondmate home's list_live did not see its own task"
assert_contains_local "$SM_LIVE" "fm-cm2" "the secondmate home's list_live did not see the crewmate spawned from it"
assert_not_contains_local "$SM_LIVE" "fm-cm1" "the secondmate home's list_live must not see the primary's task"
pass "real herdr E2E: list_live from the secondmate's own context sees only tasks in the secondmate's own workspace (both its own tab and its crewmate's)"

# --- 5. teardown closes the RIGHT tab, and no other ------------------------

TD1_OUT="$TMP_ROOT/td1.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" FM_DATA_OVERRIDE="$PRIMARY_HOME/data" \
  FM_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" cm1 >"$TD1_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for the primary-shaped crewmate cm1"$'\n'"$(cat "$TD1_OUT")"
[ -f "$CM1_META" ] && fail "fm-teardown.sh did not remove cm1's meta"
if herdr pane get "$CM1_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close cm1's pane"
fi
if ! herdr pane get "$SM_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm1 must not have closed the secondmate's OWN pane (wrong tab closed)"
fi
if ! herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm1 must not have closed cm2's pane (wrong tab closed)"
fi
WT1=
pass "real herdr E2E: tearing down cm1 closes only its own tab - the secondmate's and cm2's tabs survive untouched"

TD2_OUT="$TMP_ROOT/td2.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$SM_HOME/state" FM_DATA_OVERRIDE="$SM_HOME/data" \
  FM_CONFIG_OVERRIDE="$SM_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" cm2 >"$TD2_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for the secondmate-owned crewmate cm2"$'\n'"$(cat "$TD2_OUT")"
[ -f "$CM2_META" ] && fail "fm-teardown.sh did not remove cm2's meta"
if herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close cm2's pane"
fi
if ! herdr pane get "$SM_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm2 must not have closed the secondmate's OWN pane (wrong tab closed)"
fi
WT2=
pass "real herdr E2E: tearing down cm2 closes only its own tab - the secondmate's own tab (same workspace) survives untouched"

fm_backend_herdr_kill "$SESSION:$SM_PANE"
fm_backend_herdr_kill "$SESSION:$QM_PANE"

cleanup_all
trap - EXIT
