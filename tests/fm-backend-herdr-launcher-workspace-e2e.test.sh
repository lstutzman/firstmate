#!/usr/bin/env bash
# tests/fm-backend-herdr-launcher-workspace-e2e.test.sh - mandatory ISOLATED
# end-to-end real-Herdr test for worker PLACEMENT with presentation spaces
# disabled.
#
# The guarantee under test: a crewmate or scout runs alone in a fresh Herdr
# workspace of its own (fleet rules section 1: one session per workspace),
# nested under its dispatching home's workspace (labeled "└ <task> · p:<token>"
# and ordered in the block right after it, on every path: spawn, relaunch and
# fallback), never as a tab of the launcher's workspace, never in a workspace
# another session holds, and never in one picked by a workspace label when the
# launcher's pane names its own. A home with no workspace gets one created to
# nest under, and duplicated home workspaces with no launcher identity resolve
# to the lowest-numbered with a warning. Herdr enforces no
# workspace-label uniqueness, so two workspaces can both be labeled "firstmate";
# a claimed launcher identity is still validated first, so a stale one refuses.
#
# This drives the REAL bin/fm-spawn.sh and bin/fm-teardown.sh, because the
# guarantee spans the whole spawn handoff (fm-spawn.sh's herdr arm ->
# fm_backend_herdr_container_ensure -> fm_backend_herdr_workspace_ensure ->
# fm_backend_herdr_launcher_identity) and no adapter primitive holds it alone.
# The headline duplicate-label case additionally runs fm-spawn.sh INSIDE a real
# Herdr pane, so the pane identity comes from Herdr's own injection rather than
# from an environment this test composed.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): every lifecycle
# operation goes through bin/fm-herdr-lab.sh, which appends the named session
# flag and verifies the default fleet session is unchanged after teardown.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# Every spawn below states its own launcher identity, so a pane inherited from
# the terminal this suite was started in must not leak into any of them.
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-launcher-e2e.XXXXXX")
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-launcher-ws) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}
export HERDR_SESSION="$HERDR_LAB_SESSION"

WORKTREES=()
CLEANED=0
# Idempotent: fail() cleans up before exiting and the EXIT trap fires after it,
# so a second teardown would otherwise report the already-consumed fleet-state
# tripwire as if the lab had gone wrong.
cleanup_all() {
  local wt status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do
    [ -n "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1
  done
  WORKTREES=()
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# --- helpers ----------------------------------------------------------------

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

# make_workspace <label> -> "<workspace_id> <tab_id> <root_pane_id>"
make_workspace() {  # <label>
  local out
  out=$(lab workspace create --cwd "$TMP_ROOT" --label "$1" --no-focus 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '
    [.result.workspace.workspace_id, .result.tab.tab_id, .result.root_pane.pane_id] | @tsv
  ' 2>/dev/null | tr '\t' ' '
}

workspace_of_pane() {  # <pane_id>
  lab pane get "$1" 2>/dev/null | jq -r '.result.pane.workspace_id // empty' 2>/dev/null
}

label_of_workspace() {  # <workspace_id>
  lab workspace list 2>/dev/null \
    | jq -r --arg id "$1" '.result.workspaces[]? | select(.workspace_id == $id) | .label' 2>/dev/null
}

# assert_nested <workspace_id> <task-id> <parent_workspace_id> <what>: the
# workspace carries the "└ <task> · p:<token>" child label and sits inside the
# contiguous block of "└ " children right after its parent, because Herdr has
# no parent field and that label plus ordering is how nesting is shown.
assert_nested() {
  local ws=$1 task=$2 parent=$3 what=$4 label order idx pidx i id lbl
  label=$(label_of_workspace "$ws")
  case "$label" in
    "└ $task · p:"*) : ;;
    *) fail "$what: workspace $ws is labeled '$label', not a nested '└ $task · p:<token>' child" ;;
  esac
  order=$(lab workspace list 2>/dev/null | jq -r '.result.workspaces[]? | [.workspace_id, .label] | @tsv')
  idx=-1; pidx=-1; i=0
  while IFS=$'\t' read -r id lbl; do
    [ "$id" != "$ws" ] || idx=$i
    [ "$id" != "$parent" ] || pidx=$i
    i=$((i + 1))
  done <<ORDER
$order
ORDER
  [ "$pidx" -ge 0 ] && [ "$idx" -gt "$pidx" ] || fail "$what: workspace $ws is not after its parent $parent (positions $idx, $pidx)"
  i=0
  while IFS=$'\t' read -r id lbl; do
    if [ "$i" -gt "$pidx" ] && [ "$i" -lt "$idx" ]; then
      case "$lbl" in
        "└ "*) : ;;
        *) fail "$what: '$lbl' sits between parent $parent and nested workspace $ws, so the child is not in its parent's block" ;;
      esac
    fi
    i=$((i + 1))
  done <<ORDER
$order
ORDER
}

active_tab_of_workspace() {  # <workspace_id>
  lab workspace list 2>/dev/null \
    | jq -r --arg id "$1" '.result.workspaces[]? | select(.workspace_id == $id) | .active_tab_id // empty' 2>/dev/null
}

tab_labels_of_workspace() {  # <workspace_id>
  lab tab list --workspace "$1" 2>/dev/null \
    | jq -r '[.result.tabs[]?.label] | sort | join(",")' 2>/dev/null
}

journal_field() {  # <presentation-journal> <key>
  grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-
}

# spawn_from_launcher <launcher-pane|""> <home> <task-id> <project> [extra fm-spawn args...]
# Composes exactly the Herdr identity Herdr itself injects into a pane's
# processes. An empty launcher pane means "this firstmate is not running inside
# Herdr at all".
SPAWN_OUT=; SPAWN_ERR=; SPAWN_RC=
spawn_from_launcher() {
  local pane=$1 home=$2 id=$3 proj=$4
  shift 4
  SPAWN_OUT="$TMP_ROOT/$id.out"; SPAWN_ERR="$TMP_ROOT/$id.err"
  if [ -n "$pane" ]; then
    env HERDR_ENV=1 HERDR_PANE_ID="$pane" HERDR_SESSION="$HERDR_LAB_SESSION" \
      HERDR_SOCKET_PATH="$LAB_SOCKET" \
      FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "sh -c 'echo launcher-ws-ok'" --backend herdr "$@" \
      >"$SPAWN_OUT" 2>"$SPAWN_ERR"
  else
    env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$HERDR_LAB_SESSION" \
      FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "sh -c 'echo launcher-ws-ok'" --backend herdr "$@" \
      >"$SPAWN_OUT" 2>"$SPAWN_ERR"
  fi
  SPAWN_RC=$?
  return 0
}

record_worktree() {  # <meta>
  local wt
  wt=$(grep '^worktree=' "$1" 2>/dev/null | cut -d= -f2-)
  [ -n "$wt" ] && WORKTREES+=("$wt")
  return 0
}

# return_worktrees <meta>: hand every worktree a finished case recorded back
# early, so the later cases still find a free one in the pool.
return_worktrees() {  # <meta>
  local wt
  while IFS= read -r wt; do
    [ -n "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1
  done <<EOF
$(grep '^worktree=' "$1" 2>/dev/null | cut -d= -f2-)
EOF
  return 0
}

LAB_SOCKET=$(lab session list --json 2>/dev/null \
  | jq -r --arg s "$HERDR_LAB_SESSION" '.sessions[]? | select(.name == $s) | .socket_path' 2>/dev/null)
[ -n "$LAB_SOCKET" ] || fail "could not read the isolated lab session's socket path"

# --- scratch world ----------------------------------------------------------

# Presentation spaces are on by default, so every home that asserts the FLAT
# layout below opts out explicitly rather than depending on that default.
PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/config"
printf 'off\n' > "$PRIMARY_HOME/config/herdr-presentation-spaces"
SM_ID="lwsm1"
SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin" "$SM_HOME/data"
printf 'off\n' > "$SM_HOME/config/herdr-presentation-spaces"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf '%s\n' "$SM_ID" > "$SM_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM_HOME/data/charter.md"

SM2_ID="lwsm2"
SM2_HOME="$TMP_ROOT/secondmate-home-2"
mkdir -p "$SM2_HOME/state" "$SM2_HOME/config" "$SM2_HOME/projects" "$SM2_HOME/bin" "$SM2_HOME/data"
printf 'off\n' > "$SM2_HOME/config/herdr-presentation-spaces"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM2_HOME/AGENTS.md"
printf '%s\n' "$SM2_ID" > "$SM2_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM2_HOME/data/charter.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$SM2_HOME/.gitignore"
git -C "$SM2_HOME" init -q -b main

# A third primary-shaped home that keeps presentation spaces ON through the
# historical empty opt-in file, so the default-on migration is exercised against
# real Herdr while the opted-out homes above assert the flat layout in isolation.
PRES_HOME="$TMP_ROOT/presentation-home"
mkdir -p "$PRES_HOME/state" "$PRES_HOME/config"
: > "$PRES_HOME/config/herdr-presentation-spaces"

write_ship_brief() {  # <file> <id>
  cat > "$1" <<EOF
# Task
## Captain's intent
Exercise Herdr launcher placement for $2.

## Firstmate spec
Verify the worker is placed in the correct workspace.
EOF
}

for id in uniqA uniqB dupC dupD staleF smE presU presD presF presG presH presI presJ huskK huskL huskM huskN; do
  mkdir -p "$PRIMARY_HOME/data/$id" "$SM_HOME/data/$id" "$PRES_HOME/data/$id"
  write_ship_brief "$PRIMARY_HOME/data/$id/brief.md" "$id"
  write_ship_brief "$SM_HOME/data/$id/brief.md" "$id"
  write_ship_brief "$PRES_HOME/data/$id/brief.md" "$id"
done
mkdir -p "$PRIMARY_HOME/data/$SM2_ID"
printf 'trivial secondmate charter brief: nothing to do.\n' > "$PRIMARY_HOME/data/$SM2_ID/brief.md"

PROJ="$TMP_ROOT/scratch-project"; make_scratch_project "$PROJ"

# One unrelated workspace, kept FOCUSED throughout, so every placement result
# below is also evidence that the globally focused workspace is never the target.
read -r WS_OTHER WS_OTHER_TAB _ <<EOF
$(make_workspace captain-other)
EOF
[ -n "$WS_OTHER" ] || fail "could not create the unrelated captain workspace"
lab tab focus "$WS_OTHER_TAB" >/dev/null 2>&1 || fail "could not focus the unrelated captain workspace"

focused_workspace() {
  lab workspace list 2>/dev/null | jq -r '[.result.workspaces[]? | select(.focused == true) | .workspace_id][0] // empty' 2>/dev/null
}
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "the unrelated captain workspace did not take focus"

# Destroy a session's endpoint as setup for the step under test. Each session
# is alone in its workspace, and Herdr 0.7.x refuses to close a workspace's
# last tab, so this closes the workspace. Herdr 0.7.x also moves focus when a
# non-focused workspace is closed, so focus goes back to the captain's
# workspace here and the later focus check measures only the step under test.
destroy_endpoint_workspace() {
  lab workspace close "$1" >/dev/null 2>&1 || return 1
  lab tab focus "$WS_OTHER_TAB" >/dev/null 2>&1 || return 1
  [ "$(focused_workspace)" = "$WS_OTHER" ]
}

# --- 1. presentation off, no herdr ancestry: with no home workspace to nest
#        under, the spawn creates the home's own 'firstmate' workspace at the
#        home and nests the worker's own fresh workspace right after it -------

[ -z "$(lab workspace list 2>/dev/null | jq -r '.result.workspaces[]? | select(.label == "firstmate") | .workspace_id')" ] \
  || fail "the lab session already holds a 'firstmate' workspace before the missing-home case"
spawn_from_launcher "" "$PRIMARY_HOME" uniqA "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a spawn with no home workspace must create one and nest under it"$'\n'"$(cat "$SPAWN_ERR")"
WS_PRIMARY=$(lab workspace list 2>/dev/null | jq -r '[.result.workspaces[]? | select(.label == "firstmate") | .workspace_id] | if length == 1 then .[0] else empty end')
[ -n "$WS_PRIMARY" ] || fail "a spawn with no home workspace did not create exactly one 'firstmate' workspace"
LAUNCH_PRIMARY_PANE=$(lab pane list --workspace "$WS_PRIMARY" 2>/dev/null | jq -r '.result.panes[0].pane_id // empty')
[ -n "$LAUNCH_PRIMARY_PANE" ] || fail "could not read the created 'firstmate' workspace's pane"
UNIQA_META="$PRIMARY_HOME/state/uniqA.meta"
record_worktree "$UNIQA_META"
UNIQA_PANE=$(grep '^herdr_pane_id=' "$UNIQA_META" | cut -d= -f2-)
[ -n "$UNIQA_PANE" ] || fail "uniqA meta is missing herdr_pane_id"
UNIQA_WS=$(workspace_of_pane "$UNIQA_PANE")
[ -n "$UNIQA_WS" ] || fail "could not read uniqA's workspace"
assert_nested "$UNIQA_WS" uniqA "$WS_PRIMARY" "uniqA"
[ "$(tab_labels_of_workspace "$UNIQA_WS")" = "fm-uniqA" ] \
  || fail "uniqA's workspace holds more than its own session: '$(tab_labels_of_workspace "$UNIQA_WS")'"
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "the spawn stole focus from the captain's workspace"
pass "real herdr E2E: a presentation-off spawn with no home workspace creates it and gets its own fresh workspace nested under it without stealing focus"

# --- 2. presentation off, WITH a launcher pane in a 'firstmate' workspace: the
#        worker still gets its own workspace, and the launcher's is untouched --

WS_PRIMARY_TABS_BEFORE_UNIQB=$(tab_labels_of_workspace "$WS_PRIMARY")

spawn_from_launcher "$LAUNCH_PRIMARY_PANE" "$PRIMARY_HOME" uniqB "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a primary spawn from a launcher pane failed"$'\n'"$(cat "$SPAWN_ERR")"
UNIQB_META="$PRIMARY_HOME/state/uniqB.meta"
record_worktree "$UNIQB_META"
UNIQB_PANE=$(grep '^herdr_pane_id=' "$UNIQB_META" | cut -d= -f2-)
UNIQB_WS=$(workspace_of_pane "$UNIQB_PANE")
[ -n "$UNIQB_WS" ] && [ "$UNIQB_WS" != "$WS_PRIMARY" ] && [ "$UNIQB_WS" != "$UNIQA_WS" ] \
  || fail "a crewmate launched from the 'firstmate' workspace must not share it or another session's workspace (got '$UNIQB_WS')"
assert_nested "$UNIQB_WS" uniqB "$WS_PRIMARY" "uniqB"
[ "$(tab_labels_of_workspace "$UNIQB_WS")" = "fm-uniqB" ] \
  || fail "uniqB's workspace holds more than its own session"
[ "$(tab_labels_of_workspace "$WS_PRIMARY")" = "$WS_PRIMARY_TABS_BEFORE_UNIQB" ] \
  || fail "a spawn from the launcher pane changed the launcher workspace's tabs"
pass "real herdr E2E: a presentation-off spawn from a launcher pane gets its own workspace and leaves the launcher's untouched"

# --- 2b. presentation spaces ON: the projected child is created and bound
#         UNDER the launcher's exact workspace, not collapsed into it ---------

spawn_from_launcher "$LAUNCH_PRIMARY_PANE" "$PRES_HOME" presU "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a presentation-enabled spawn from a launcher pane failed"$'\n'"$(cat "$SPAWN_ERR")"
PRESU_META="$PRES_HOME/state/presU.meta"
record_worktree "$PRESU_META"
PRESU_PANE=$(grep '^herdr_pane_id=' "$PRESU_META" | cut -d= -f2-)
PRESU_WS=$(workspace_of_pane "$PRESU_PANE")
[ -n "$PRESU_WS" ] || fail "could not read presU's workspace"
[ "$PRESU_WS" != "$WS_PRIMARY" ] \
  || fail "a projected worker must get its own disposable workspace, not be collapsed into its parent"
case "$(label_of_workspace "$PRESU_WS")" in
  "└ "*" · p:"*) : ;;
  *) fail "presU's workspace is not a presentation projection: '$(label_of_workspace "$PRESU_WS")'" ;;
esac
PRESU_JOURNAL="$PRES_HOME/state/presU.herdr-presentation"
[ -f "$PRESU_JOURNAL" ] || fail "a projected spawn did not leave its presentation journal"
[ "$(journal_field "$PRESU_JOURNAL" version)" = 2 ] \
  || fail "the projection did not publish an exact restart binding"$'\n'"$(cat "$PRESU_JOURNAL")"
[ "$(journal_field "$PRESU_JOURNAL" parent_workspace_id)" = "$WS_PRIMARY" ] \
  || fail "the projection bound a parent other than the launcher's own workspace ($WS_PRIMARY)"
[ "$(journal_field "$PRESU_JOURNAL" workspace_id)" = "$PRESU_WS" ] \
  || fail "the projection journal does not name its own workspace"
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "a projected spawn stole focus from the captain's workspace"
pass "real herdr E2E: presentation spaces still create the isolated child workspace and bind it under the launcher's exact parent, without stealing focus"

# --- 2c. presentation spaces ON but the projection falls back flat: each
#         worker gets its own fresh workspace (never the launcher's own, and
#         never one another session already holds), and nothing in the
#         launcher's workspace changes ----------------------------------------

PRES_LOCK_PATH=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path "$1"' \
  "$ROOT" "$HERDR_LAB_SESSION") || fail "could not resolve the lab session's presentation lock"
# hold_presentation_lock <tag>: hold the shared session lock for 8 seconds,
# which outlasts the 5 second bounded projection attempt, so the spawn that
# follows falls back from the journaled projection and then waits for the lock
# to free before it creates and orders its nested workspace.
hold_presentation_lock() {  # <tag>
  PRES_LOCK_READY="$TMP_ROOT/pres-lock-ready-$1"
  ROOT="$ROOT" READY="$PRES_LOCK_READY" LOCK="$PRES_LOCK_PATH" bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    sleep 8
    fm_lock_release "$LOCK"
  ' &
  PRES_LOCK_PID=$!
  while [ ! -e "$PRES_LOCK_READY" ] && kill -0 "$PRES_LOCK_PID" 2>/dev/null; do sleep 0.01; done
  [ -e "$PRES_LOCK_READY" ] || fail "could not hold the lab session's presentation lock ($1)"
}
release_presentation_lock() {
  wait "$PRES_LOCK_PID" || fail "the presentation lock holder failed"
}
hold_presentation_lock presF
WS_PRIMARY_TABS_BEFORE_FLAT=$(tab_labels_of_workspace "$WS_PRIMARY")
WS_PRIMARY_ACTIVE_BEFORE_FLAT=$(active_tab_of_workspace "$WS_PRIMARY")
spawn_from_launcher "$LAUNCH_PRIMARY_PANE" "$PRES_HOME" presF "$PROJ" --mode no-mistakes --yolo off
PRESF_RC=$SPAWN_RC; PRESF_ERR=$SPAWN_ERR
release_presentation_lock
hold_presentation_lock presG
spawn_from_launcher "$LAUNCH_PRIMARY_PANE" "$PRES_HOME" presG "$PROJ" --mode no-mistakes --yolo off
PRESG_RC=$SPAWN_RC; PRESG_ERR=$SPAWN_ERR
release_presentation_lock
[ "$PRESF_RC" -eq 0 ] || fail "a presentation-enabled spawn that falls back flat failed"$'\n'"$(cat "$PRESF_ERR")"
[ "$PRESG_RC" -eq 0 ] || fail "a second presentation-enabled flat fallback failed"$'\n'"$(cat "$PRESG_ERR")"
grep -F "presentation focus lock unavailable" "$PRESF_ERR" >/dev/null 2>&1 \
  || fail "the presF fixture did not reach the flat fallback"$'\n'"$(cat "$PRESF_ERR")"
PRESF_META="$PRES_HOME/state/presF.meta"
record_worktree "$PRESF_META"
PRESF_PANE=$(grep '^herdr_pane_id=' "$PRESF_META" | cut -d= -f2-)
PRESF_WS=$(workspace_of_pane "$PRESF_PANE")
[ -n "$PRESF_WS" ] || fail "could not read presF's workspace"
[ "$PRESF_WS" != "$WS_PRIMARY" ] \
  || fail "a flat-fallback worker from a presentation-enabled home landed in the launcher's own workspace"
assert_nested "$PRESF_WS" presF "$WS_PRIMARY" "a journal-free fallback worker"
[ ! -e "$PRES_HOME/state/presF.herdr-presentation" ] || fail "a flat fallback published a presentation journal"
PRESG_META="$PRES_HOME/state/presG.meta"
record_worktree "$PRESG_META"
PRESG_WS=$(workspace_of_pane "$(grep '^herdr_pane_id=' "$PRESG_META" | cut -d= -f2-)")
[ -n "$PRESG_WS" ] && [ "$PRESG_WS" != "$PRESF_WS" ] && [ "$PRESG_WS" != "$WS_PRIMARY" ] \
  || fail "a second flat fallback shared a workspace with another session (presF $PRESF_WS, presG '$PRESG_WS')"
[ "$(tab_labels_of_workspace "$PRESF_WS")" = "fm-presF" ] \
  || fail "a flat fallback's workspace holds more than its own session: '$(tab_labels_of_workspace "$PRESF_WS")'"
[ "$(tab_labels_of_workspace "$WS_PRIMARY")" = "$WS_PRIMARY_TABS_BEFORE_FLAT" ] \
  || fail "a flat fallback changed the launcher workspace's tabs"
[ "$(active_tab_of_workspace "$WS_PRIMARY")" = "$WS_PRIMARY_ACTIVE_BEFORE_FLAT" ] \
  || fail "a flat fallback changed the launcher workspace's active tab"
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "a flat fallback stole focus from the captain's workspace"
assert_nested "$PRESG_WS" presG "$WS_PRIMARY" "a second journal-free fallback worker"
pass "real herdr E2E: each presentation-enabled fallback gets its own nested workspace and leaves the launcher's workspace untouched"

# --- 2d. '<home> workers' workspaces that already exist (from before this
#         rule, or made by hand): a flat fallback never adopts one, it creates
#         its own ------------------------------------------------------------

read -r WS_WORKERS_DUP _ _ <<EOF
$(make_workspace "firstmate workers")
EOF
[ -n "$WS_WORKERS_DUP" ] || fail "could not create a second 'firstmate workers' workspace"
WS_WORKERS_FIRST=$(lab workspace list 2>/dev/null \
  | jq -r '[.result.workspaces[]? | select(.label == "firstmate workers") | .workspace_id][0] // empty')
[ -n "$WS_WORKERS_FIRST" ] || fail "could not read the first 'firstmate workers' workspace"
hold_presentation_lock presH
spawn_from_launcher "$LAUNCH_PRIMARY_PANE" "$PRES_HOME" presH "$PROJ" --mode no-mistakes --yolo off
PRESH_RC=$SPAWN_RC; PRESH_ERR=$SPAWN_ERR
release_presentation_lock
[ "$PRESH_RC" -eq 0 ] \
  || fail "a flat fallback refused when two 'firstmate workers' workspaces exist"$'\n'"$(cat "$PRESH_ERR")"
PRESH_META="$PRES_HOME/state/presH.meta"
record_worktree "$PRESH_META"
PRESH_WS=$(workspace_of_pane "$(grep '^herdr_pane_id=' "$PRESH_META" | cut -d= -f2-)")
[ -n "$PRESH_WS" ] && [ "$PRESH_WS" != "$WS_WORKERS_FIRST" ] && [ "$PRESH_WS" != "$WS_WORKERS_DUP" ] \
  && [ "$PRESH_WS" != "$PRESF_WS" ] && [ "$PRESH_WS" != "$PRESG_WS" ] \
  || fail "a flat fallback adopted an existing workspace instead of creating its own ($PRESH_WS)"
assert_nested "$PRESH_WS" presH "$WS_PRIMARY" "a fallback beside existing workers workspaces"
pass "real herdr E2E: existing '<home> workers' workspaces are never adopted; a fallback creates its own nested workspace"

# --- 2e. reclaim of a destroyed endpoint from a presentation-enabled home
#         (the relaunch an unpark runs): the replacement gets a fresh
#         workspace of its own, never the launcher's and never one that
#         another session already holds -----------------------------------------

destroy_endpoint_workspace "$PRESF_WS" || fail "could not destroy presF's endpoint"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/codex"
chmod +x "$FAKEBIN/codex"
WS_PRIMARY_TABS_BEFORE_REBIND=$(tab_labels_of_workspace "$WS_PRIMARY")
env PATH="$FAKEBIN:$PATH" HERDR_ENV=1 HERDR_PANE_ID="$LAUNCH_PRIMARY_PANE" HERDR_SESSION="$HERDR_LAB_SESSION" \
  HERDR_SOCKET_PATH="$LAB_SOCKET" FM_SPAWN_NO_GUARD=1 FM_HOME="$PRES_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" presF --relaunch --harness codex >"$TMP_ROOT/presF-rebind.out" 2>"$TMP_ROOT/presF-rebind.err" \
  || fail "reclaiming presF's destroyed endpoint failed"$'\n'"$(cat "$TMP_ROOT/presF-rebind.err")"
PRESF_REBOUND_PANE=$(grep '^herdr_pane_id=' "$PRESF_META" | tail -1 | cut -d= -f2-)
PRESF_REBOUND_WS=$(workspace_of_pane "$PRESF_REBOUND_PANE")
[ -n "$PRESF_REBOUND_WS" ] || fail "could not read presF's rebound workspace"
[ "$PRESF_REBOUND_WS" != "$WS_PRIMARY" ] \
  || fail "a reclaimed worker from a presentation-enabled home landed in the launcher's own workspace"
[ "$PRESF_REBOUND_WS" != "$PRESG_WS" ] && [ "$PRESF_REBOUND_WS" != "$PRESH_WS" ] \
  || fail "a reclaimed worker joined a workspace another session holds ($PRESF_REBOUND_WS)"
assert_nested "$PRESF_REBOUND_WS" presF "$WS_PRIMARY" "a reclaimed worker"
[ "$(tab_labels_of_workspace "$PRESF_REBOUND_WS")" = "fm-presF" ] \
  || fail "a reclaimed worker's workspace holds more than its own session: '$(tab_labels_of_workspace "$PRESF_REBOUND_WS")'"
[ "$(tab_labels_of_workspace "$WS_PRIMARY")" = "$WS_PRIMARY_TABS_BEFORE_REBIND" ] \
  || fail "the reclaim changed the launcher workspace's tabs"
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "the reclaim stole focus from the captain's workspace"
PRESF_REBOUND_TAB=$(grep '^herdr_tab_id=' "$PRESF_META" | tail -1 | cut -d= -f2-)
[ "$(lab tab get "$PRESF_REBOUND_TAB" | jq -r '.result.tab.label')" = fm-presF ] \
  || fail "a reclaimed ordinary worker's tab should keep fm-<id>"
pass "real herdr E2E: reclaiming a presentation-enabled home's destroyed endpoint gets its own workspace, not the launcher's or another session's"

# --- 2f. park, unpark, then a new spawn: three different workspaces ---------
# bin/fm-tree-park.sh unpark ends in fm-control.sh relaunch, which stops the
# worker and runs the same fm-spawn.sh --relaunch the reclaim above runs, so
# this drives that call after stopping the endpoint exactly as a park does.
# presI is parked and unparked while presJ is spawned as a fresh task, each
# from the same lock-contended presentation-enabled home as 2c.

hold_presentation_lock presI
spawn_from_launcher "$LAUNCH_PRIMARY_PANE" "$PRES_HOME" presI "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "presI's spawn failed"$'\n'"$(cat "$SPAWN_ERR")"
release_presentation_lock
PRESI_META="$PRES_HOME/state/presI.meta"
record_worktree "$PRESI_META"
PRESI_WS=$(workspace_of_pane "$(grep '^herdr_pane_id=' "$PRESI_META" | cut -d= -f2-)")
destroy_endpoint_workspace "$PRESI_WS" || fail "could not stop presI the way a park does"
env PATH="$FAKEBIN:$PATH" HERDR_ENV=1 HERDR_PANE_ID="$LAUNCH_PRIMARY_PANE" HERDR_SESSION="$HERDR_LAB_SESSION" \
  HERDR_SOCKET_PATH="$LAB_SOCKET" FM_SPAWN_NO_GUARD=1 FM_HOME="$PRES_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" presI --relaunch --harness codex >"$TMP_ROOT/presI-unpark.out" 2>"$TMP_ROOT/presI-unpark.err" \
  || fail "relaunching presI after its park failed"$'\n'"$(cat "$TMP_ROOT/presI-unpark.err")"
PRESI_UNPARKED_WS=$(workspace_of_pane "$(grep '^herdr_pane_id=' "$PRESI_META" | tail -1 | cut -d= -f2-)")
hold_presentation_lock presJ
spawn_from_launcher "$LAUNCH_PRIMARY_PANE" "$PRES_HOME" presJ "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "presJ's spawn failed"$'\n'"$(cat "$SPAWN_ERR")"
release_presentation_lock
PRESJ_META="$PRES_HOME/state/presJ.meta"
record_worktree "$PRESJ_META"
PRESJ_WS=$(workspace_of_pane "$(grep '^herdr_pane_id=' "$PRESJ_META" | cut -d= -f2-)")
[ -n "$PRESI_WS" ] && [ -n "$PRESI_UNPARKED_WS" ] && [ -n "$PRESJ_WS" ] || fail "could not read all three workspaces"
[ "$PRESI_WS" != "$PRESI_UNPARKED_WS" ] && [ "$PRESI_WS" != "$PRESJ_WS" ] && [ "$PRESI_UNPARKED_WS" != "$PRESJ_WS" ] \
  || fail "park, unpark and a new spawn shared a workspace (first $PRESI_WS, unparked $PRESI_UNPARKED_WS, new $PRESJ_WS)"
[ "$(tab_labels_of_workspace "$PRESI_UNPARKED_WS")" = "fm-presI" ] && [ "$(tab_labels_of_workspace "$PRESJ_WS")" = "fm-presJ" ] \
  || fail "an unparked or new session's workspace holds more than that one session"
assert_nested "$PRESI_UNPARKED_WS" presI "$WS_PRIMARY" "an unparked relaunch"
assert_nested "$PRESJ_WS" presJ "$WS_PRIMARY" "a new spawn beside an unparked relaunch"
pass "real herdr E2E: a session, its unparked relaunch and a new spawn each get their own nested workspace"

# The guard: placing a session into a workspace that already holds another
# tab refuses, names the workspace, and creates nothing.
GUARD_TABS_BEFORE=$(tab_labels_of_workspace "$PRESJ_WS")
GUARD_ERR="$TMP_ROOT/guard.err"
FM_HOME="$PRES_HOME" HERDR_SESSION="$HERDR_LAB_SESSION" bash -c '
  . "$0/bin/backends/herdr.sh"
  fm_backend_herdr_create_task "$1:$2" fm-guard "$3" "" "" exclusive' "$ROOT" "$HERDR_LAB_SESSION" "$PRESJ_WS" "$TMP_ROOT" >/dev/null 2>"$GUARD_ERR" \
  && fail "the guard let a second session into a workspace that already holds one"
assert_contains_local "$(cat "$GUARD_ERR")" "$PRESJ_WS" "the guard refusal did not name the workspace"
assert_contains_local "$(cat "$GUARD_ERR")" "one session only" "the guard refusal did not state the rule"
[ "$(tab_labels_of_workspace "$PRESJ_WS")" = "$GUARD_TABS_BEFORE" ] || fail "a refused placement still changed the workspace's tabs"
pass "real herdr E2E: the guard refuses a second session in a workspace that already holds one"

# --- 2g. a presentation-off home's relaunch also gets its own workspace ------

destroy_endpoint_workspace "$UNIQB_WS" || fail "could not stop uniqB's endpoint"
WS_PRIMARY_TABS_BEFORE_UNPARK=$(tab_labels_of_workspace "$WS_PRIMARY")
env PATH="$FAKEBIN:$PATH" HERDR_ENV=1 HERDR_PANE_ID="$LAUNCH_PRIMARY_PANE" HERDR_SESSION="$HERDR_LAB_SESSION" \
  HERDR_SOCKET_PATH="$LAB_SOCKET" FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" uniqB --relaunch --harness codex >"$TMP_ROOT/uniqB-relaunch.out" 2>"$TMP_ROOT/uniqB-relaunch.err" \
  || fail "relaunching a presentation-off home's uniqB failed"$'\n'"$(cat "$TMP_ROOT/uniqB-relaunch.err")"
UNIQB_PANE=$(grep '^herdr_pane_id=' "$UNIQB_META" | tail -1 | cut -d= -f2-)
UNIQB_RELAUNCH_WS=$(workspace_of_pane "$UNIQB_PANE")
[ -n "$UNIQB_RELAUNCH_WS" ] && [ "$UNIQB_RELAUNCH_WS" != "$WS_PRIMARY" ] && [ "$UNIQB_RELAUNCH_WS" != "$UNIQA_WS" ] \
  || fail "a presentation-off relaunch joined another session's workspace ('$UNIQB_RELAUNCH_WS')"
assert_nested "$UNIQB_RELAUNCH_WS" uniqB "$WS_PRIMARY" "a presentation-off relaunch"
[ "$(tab_labels_of_workspace "$UNIQB_RELAUNCH_WS")" = "fm-uniqB" ] \
  || fail "the relaunched session's workspace holds more than that session"
[ "$(tab_labels_of_workspace "$WS_PRIMARY")" = "$WS_PRIMARY_TABS_BEFORE_UNPARK" ] \
  || fail "the relaunch changed the launcher workspace's tabs"
pass "real herdr E2E: relaunching a presentation-off home's session gets its own workspace, not the launcher's"

# --- 2h. a workspace create that returns no seeded tab id is closed, not left behind

REAL_HERDR=$(command -v herdr)
SHIMBIN="$TMP_ROOT/shimbin"
mkdir -p "$SHIMBIN"
cat > "$SHIMBIN/herdr" <<SHIM
#!/usr/bin/env bash
out=\$("$REAL_HERDR" "\$@") || exit \$?
if [ "\${1:-}" = workspace ] && [ "\${2:-}" = create ]; then
  printf '%s\n' "\$out" | jq -c 'del(.result.tab)'
else
  printf '%s\n' "\$out"
fi
SHIM
chmod +x "$SHIMBIN/herdr"
WS_COUNT_BEFORE_SHIM=$(lab workspace list 2>/dev/null | jq -r '.result.workspaces | length')
SHIM_ERR="$TMP_ROOT/shim.err"
# shellcheck disable=SC2016 # $0 and the adapter path expand inside the child shell
env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH PATH="$SHIMBIN:$PATH" HERDR_SESSION="$HERDR_LAB_SESSION" \
  FM_HOME="$PRIMARY_HOME" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp nested-workers "$1" shimT' "$ROOT" "$HERDR_LAB_SESSION" \
  >/dev/null 2>"$SHIM_ERR" && fail "a workspace create with no seeded tab id was accepted"
assert_contains_local "$(cat "$SHIM_ERR")" "no seeded tab id" "the refusal did not say why"
i=0
while [ "$(lab workspace list 2>/dev/null | jq -r '.result.workspaces | length')" != "$WS_COUNT_BEFORE_SHIM" ] && [ "$i" -lt 50 ]; do
  sleep 0.2; i=$((i + 1))
done
[ "$(lab workspace list 2>/dev/null | jq -r '.result.workspaces | length')" = "$WS_COUNT_BEFORE_SHIM" ] \
  || fail "the workspace created before the refusal was left behind"
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "closing the unusable workspace stole focus"
pass "real herdr E2E: a workspace whose create response has no seeded tab id is closed again and focus is preserved"

# --- 2i. an unconfigured home whose client meets the presentation floor but
#         whose running server reads below it at the session re-check: the
#         worker still gets a fresh workspace of its own, never the launcher's

FLOOR_HOME="$TMP_ROOT/floor-home"
mkdir -p "$FLOOR_HOME/state" "$FLOOR_HOME/config" "$FLOOR_HOME/data/floorA"
write_ship_brief "$FLOOR_HOME/data/floorA/brief.md" floorA
FLOORBIN="$TMP_ROOT/floorbin"
mkdir -p "$FLOORBIN"
# The third status read of a spawn is the session-scoped re-check that follows
# the client gate and the server ensure; only that read reports an old server.
# Every other read names the 0.8.0 floor release (protocols untouched), so the
# client is above the floor whatever Herdr the lab really runs (CI pins 0.7.4).
cat > "$FLOORBIN/herdr" <<SHIM
#!/usr/bin/env bash
out=\$("$REAL_HERDR" "\$@") || exit \$?
if [ "\${1:-}" = status ]; then
  n=\$(( \$(cat "$FLOORBIN/count" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "\$n" > "$FLOORBIN/count"
  out=\$(printf '%s\n' "\$out" | jq -c '.client.version = "0.8.0" | if .server.version then .server.version = "0.8.0" else . end')
  if [ "\$n" = 3 ]; then
    printf '%s\n' "\$out" | jq -c '.server.version = "0.7.5" | .server.protocol = 14'
    exit 0
  fi
fi
printf '%s\n' "\$out"
SHIM
chmod +x "$FLOORBIN/herdr"
WS_PRIMARY_TABS_BEFORE_FLOOR=$(tab_labels_of_workspace "$WS_PRIMARY")
env PATH="$FLOORBIN:$PATH" HERDR_ENV=1 HERDR_PANE_ID="$LAUNCH_PRIMARY_PANE" HERDR_SESSION="$HERDR_LAB_SESSION" \
  HERDR_SOCKET_PATH="$LAB_SOCKET" FM_SPAWN_NO_GUARD=1 FM_HOME="$FLOOR_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" floorA "$PROJ" "sh -c 'echo launcher-ws-ok'" --backend herdr --mode no-mistakes --yolo off \
  >"$TMP_ROOT/floorA.out" 2>"$TMP_ROOT/floorA.err" \
  || fail "a spawn whose server reads below the presentation floor failed"$'\n'"$(cat "$TMP_ROOT/floorA.err")"
assert_contains_local "$(cat "$TMP_ROOT/floorA.err")" "server version 0.7.5" "the fixture did not reach the below-floor server read"
FLOORA_META="$FLOOR_HOME/state/floorA.meta"
record_worktree "$FLOORA_META"
FLOORA_WS=$(workspace_of_pane "$(grep '^herdr_pane_id=' "$FLOORA_META" | cut -d= -f2-)")
[ -n "$FLOORA_WS" ] && [ "$FLOORA_WS" != "$WS_PRIMARY" ] \
  || fail "a spawn whose server reads below the floor joined the launcher's workspace ('$FLOORA_WS')"
assert_nested "$FLOORA_WS" floorA "$WS_PRIMARY" "a spawn whose server reads below the floor"
[ "$(tab_labels_of_workspace "$FLOORA_WS")" = "fm-floorA" ] \
  || fail "the below-floor spawn's workspace holds more than its own session"
[ "$(tab_labels_of_workspace "$WS_PRIMARY")" = "$WS_PRIMARY_TABS_BEFORE_FLOOR" ] \
  || fail "the below-floor spawn changed the launcher workspace's tabs"
return_worktrees "$FLOORA_META"
pass "real herdr E2E: a client above the presentation floor with a server below it still gives the worker its own workspace"

# --- 2j. a respawn over the task's own earlier agent-free husk closes that
#         exact husk, and its workspace only when nothing else is left in it;
#         a husk pane that now holds a live agent is left alone ----------------

# spawn_husk_task <id> -> sets HUSK_PANE and HUSK_WS for the first spawn of <id>
spawn_husk_task() {
  spawn_from_launcher "" "$PRIMARY_HOME" "$1" "$PROJ" --mode no-mistakes --yolo off
  [ "$SPAWN_RC" -eq 0 ] || fail "the first spawn of $1 failed"$'\n'"$(cat "$SPAWN_ERR")"
  record_worktree "$PRIMARY_HOME/state/$1.meta"
  HUSK_PANE=$(grep '^herdr_pane_id=' "$PRIMARY_HOME/state/$1.meta" | cut -d= -f2-)
  HUSK_WS=$(workspace_of_pane "$HUSK_PANE")
  [ -n "$HUSK_PANE" ] && [ -n "$HUSK_WS" ] || fail "could not read $1's first endpoint"
  HUSK_WT=$(grep '^worktree=' "$PRIMARY_HOME/state/$1.meta" | cut -d= -f2-)
}
# respawn_husk_task <id> -> sets NEW_PANE and NEW_WS for the respawn of <id>
respawn_husk_task() {
  spawn_from_launcher "" "$PRIMARY_HOME" "$1" "$PROJ" --mode no-mistakes --yolo off
  [ "$SPAWN_RC" -eq 0 ] || fail "the respawn of $1 failed"$'\n'"$(cat "$SPAWN_ERR")"
  record_worktree "$PRIMARY_HOME/state/$1.meta"
  NEW_PANE=$(grep '^herdr_pane_id=' "$PRIMARY_HOME/state/$1.meta" | tail -1 | cut -d= -f2-)
  NEW_WS=$(workspace_of_pane "$NEW_PANE")
  [ -n "$NEW_PANE" ] && [ "$NEW_PANE" != "$HUSK_PANE" ] && [ -n "$NEW_WS" ] && [ "$NEW_WS" != "$HUSK_WS" ] \
    || fail "the respawn of $1 did not get its own fresh workspace (old $HUSK_WS, new '$NEW_WS')"
  [ "$(tab_labels_of_workspace "$NEW_WS")" = "fm-$1" ] \
    || fail "the respawn of $1's workspace holds more than its own session"
}
# return_husk_worktrees <id>: once a case's checks are done, hand back both the
# first spawn's and the respawn's worktrees.
return_husk_worktrees() {  # <id>
  [ -z "$HUSK_WT" ] || treehouse return --force "$HUSK_WT" >/dev/null 2>&1
  return_worktrees "$PRIMARY_HOME/state/$1.meta"
}
workspace_exists() {  # <workspace_id>
  [ -n "$(label_of_workspace "$1")" ]
}
wait_workspace_gone() {  # <workspace_id>
  local i=0
  while workspace_exists "$1" && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
  ! workspace_exists "$1"
}

spawn_husk_task huskK
respawn_husk_task huskK
lab pane get "$HUSK_PANE" >/dev/null 2>&1 && fail "the respawn left huskK's earlier agent-free husk pane behind"
wait_workspace_gone "$HUSK_WS" || fail "the respawn left huskK's emptied husk workspace behind"
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "retiring huskK's husk stole focus"
return_husk_worktrees huskK
pass "real herdr E2E: a respawn closes the task's earlier agent-free husk and its emptied workspace"

spawn_husk_task huskL
lab tab create --workspace "$HUSK_WS" --cwd "$TMP_ROOT" --label other-session --no-focus >/dev/null 2>&1 \
  || fail "could not add another tab to huskL's workspace"
respawn_husk_task huskL
lab pane get "$HUSK_PANE" >/dev/null 2>&1 && fail "the respawn left huskL's earlier agent-free husk pane behind"
workspace_exists "$HUSK_WS" || fail "the respawn closed huskL's husk workspace although it still held another tab"
[ "$(tab_labels_of_workspace "$HUSK_WS")" = "other-session" ] \
  || fail "huskL's husk workspace lost its other tab: '$(tab_labels_of_workspace "$HUSK_WS")'"
return_husk_worktrees huskL
pass "real herdr E2E: a respawn closes the husk but keeps its workspace when that still holds another tab"

spawn_husk_task huskM
lab pane send-text "$HUSK_PANE" "sleep 600" >/dev/null 2>&1 || fail "could not type a command into huskM's pane"
lab pane send-keys "$HUSK_PANE" enter >/dev/null 2>&1 || fail "could not start a process in huskM's pane"
lab pane report-agent "$HUSK_PANE" --source fm-launcher-e2e --agent test-agent --state idle >/dev/null 2>&1 \
  || fail "could not register a live agent in huskM's pane"
respawn_husk_task huskM
lab pane get "$HUSK_PANE" >/dev/null 2>&1 || fail "the respawn closed huskM's earlier pane although it holds a live agent"
assert_contains_local "$(cat "$SPAWN_ERR")" "left this task's earlier herdr endpoint" "the respawn did not note the pane it left in place"
return_husk_worktrees huskM
pass "real herdr E2E: a respawn leaves the task's earlier pane alone when it holds a live agent"

# A record whose pane id Herdr now reports in another workspace and tab (the
# shape of a pane id reused elsewhere, such as a bare shell in the captain's own
# workspace) is never treated as this task's husk.
spawn_husk_task huskN
HUSKN_META="$PRIMARY_HOME/state/huskN.meta"
read -r FOREIGN_WS FOREIGN_TAB _ <<EOF
$(make_workspace foreign-shell)
EOF
[ -n "$FOREIGN_WS" ] && [ -n "$FOREIGN_TAB" ] || fail "could not create the foreign workspace"
sed -i -e "s|^herdr_workspace_id=.*|herdr_workspace_id=$FOREIGN_WS|" -e "s|^herdr_tab_id=.*|herdr_tab_id=$FOREIGN_TAB|" "$HUSKN_META" \
  || fail "could not point huskN's record at another workspace and tab"
respawn_husk_task huskN
lab pane get "$HUSK_PANE" >/dev/null 2>&1 || fail "the respawn closed a pane Herdr reports outside the task's recorded workspace and tab"
workspace_exists "$HUSK_WS" || fail "the respawn closed the workspace of a pane outside the task's recorded workspace and tab"
assert_contains_local "$(cat "$SPAWN_ERR")" "not in its recorded workspace and tab" "the respawn did not note why it left the pane in place"
return_husk_worktrees huskN
pass "real herdr E2E: a respawn never closes a recorded pane id that Herdr reports in another workspace and tab"

# --- 3. duplicate label, launcher in the NON-first match, driven from a real
#        Herdr pane so the identity comes from Herdr's own injection ----------

read -r WS_PRIMARY_DUP _ LAUNCH_DUP_PANE <<EOF
$(make_workspace firstmate)
EOF
[ -n "$WS_PRIMARY_DUP" ] || fail "could not create the second 'firstmate' workspace"
[ "$WS_PRIMARY_DUP" != "$WS_PRIMARY" ] || fail "the two 'firstmate' workspaces must be distinct"
DUP_COUNT=$(lab workspace list 2>/dev/null | jq -r '[.result.workspaces[]? | select(.label == "firstmate")] | length')
[ "$DUP_COUNT" = 2 ] || fail "expected exactly two 'firstmate' workspaces, got $DUP_COUNT"
WS_PRIMARY_TABS_BEFORE=$(tab_labels_of_workspace "$WS_PRIMARY")
WS_PRIMARY_DUP_TABS_BEFORE=$(tab_labels_of_workspace "$WS_PRIMARY_DUP")

cat > "$TMP_ROOT/spawn-in-pane.sh" <<SPAWN
#!/usr/bin/env bash
set -u
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \\
  "$ROOT/bin/fm-spawn.sh" dupC "$PROJ" "sh -c 'echo launcher-ws-ok'" --mode no-mistakes --yolo off --backend herdr \\
  > "$TMP_ROOT/dupC.out" 2> "$TMP_ROOT/dupC.err"
echo \$? > "$TMP_ROOT/dupC.rc"
SPAWN
chmod +x "$TMP_ROOT/spawn-in-pane.sh"
lab pane run "$LAUNCH_DUP_PANE" "$TMP_ROOT/spawn-in-pane.sh" >/dev/null 2>&1 \
  || fail "could not run fm-spawn.sh inside the launcher's herdr pane"
i=0
while [ ! -f "$TMP_ROOT/dupC.rc" ] && [ "$i" -lt 120 ]; do sleep 2; i=$((i + 1)); done
[ -f "$TMP_ROOT/dupC.rc" ] || fail "fm-spawn.sh never finished inside the launcher's herdr pane"
[ "$(cat "$TMP_ROOT/dupC.rc")" = 0 ] \
  || fail "the in-pane spawn failed"$'\n'"$(cat "$TMP_ROOT/dupC.err" 2>/dev/null)"

DUPC_META="$PRIMARY_HOME/state/dupC.meta"
record_worktree "$DUPC_META"
DUPC_PANE=$(grep '^herdr_pane_id=' "$DUPC_META" | cut -d= -f2-)
DUPC_WS=$(workspace_of_pane "$DUPC_PANE")
[ -n "$DUPC_WS" ] && [ "$DUPC_WS" != "$WS_PRIMARY_DUP" ] && [ "$DUPC_WS" != "$WS_PRIMARY" ] && [ "$DUPC_WS" != "$WS_OTHER" ] \
  || fail "a worker launched from the second 'firstmate' workspace must get its own workspace, got '$DUPC_WS'"
[ "$(tab_labels_of_workspace "$DUPC_WS")" = "fm-dupC" ] || fail "dupC's workspace holds more than its own session"
assert_nested "$DUPC_WS" dupC "$WS_PRIMARY_DUP" "a worker launched from the second 'firstmate' workspace"
[ "$(grep '^herdr_workspace_id=' "$DUPC_META" | cut -d= -f2-)" = "$DUPC_WS" ] \
  || fail "the recorded endpoint workspace does not match the worker's workspace"
[ "$(tab_labels_of_workspace "$WS_PRIMARY_DUP")" = "$WS_PRIMARY_DUP_TABS_BEFORE" ] \
  || fail "the launcher's own workspace gained or lost a tab"
pass "real herdr E2E: with two 'firstmate' workspaces, a worker spawned from inside the second one gets its own workspace"

[ "$(tab_labels_of_workspace "$WS_PRIMARY")" = "$WS_PRIMARY_TABS_BEFORE" ] \
  || fail "the other same-labeled workspace's tabs changed; it must never be adopted or mutated"
[ "$(label_of_workspace "$WS_PRIMARY")" = firstmate ] \
  || fail "the other same-labeled workspace was renamed"
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "the in-pane spawn stole focus from the captain's workspace"
pass "real herdr E2E: the duplicate-labeled sibling workspace is left entirely untouched and focus is preserved"

# --- 3b. presentation spaces ON with a duplicated parent label: the projection
#         still hangs off the launcher's exact workspace ---------------------

spawn_from_launcher "$LAUNCH_DUP_PANE" "$PRES_HOME" presD "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a projected spawn under a duplicated parent label failed"$'\n'"$(cat "$SPAWN_ERR")"
PRESD_META="$PRES_HOME/state/presD.meta"
record_worktree "$PRESD_META"
PRESD_PANE=$(grep '^herdr_pane_id=' "$PRESD_META" | cut -d= -f2-)
PRESD_WS=$(workspace_of_pane "$PRESD_PANE")
[ -n "$PRESD_WS" ] || fail "could not read presD's workspace"
PRESD_JOURNAL="$PRES_HOME/state/presD.herdr-presentation"
[ "$(journal_field "$PRESD_JOURNAL" version)" = 2 ] \
  || fail "the duplicate-label projection did not publish a version 2 binding"$'\n'"$(cat "$PRESD_JOURNAL" 2>/dev/null)"
[ "$(journal_field "$PRESD_JOURNAL" parent_workspace_id)" = "$WS_PRIMARY_DUP" ] \
  || fail "the duplicate-label projection journal did not bind the launcher's exact parent workspace"
[ "$PRESD_WS" != "$WS_PRIMARY" ] && [ "$PRESD_WS" != "$WS_PRIMARY_DUP" ] \
  || fail "a projected worker must not be collapsed into either same-labeled parent workspace"
assert_nested "$PRESD_WS" presD "$WS_PRIMARY_DUP" "a projected worker under a duplicated parent label"
[ "$(tab_labels_of_workspace "$WS_PRIMARY")" = "$WS_PRIMARY_TABS_BEFORE" ] \
  || fail "the other same-labeled workspace was mutated by a projected spawn"
[ "$(focused_workspace)" = "$WS_OTHER" ] || fail "a projected spawn stole focus from the captain's workspace"
pass "real herdr E2E: with a duplicated home label, a projected worker still hangs off the launcher's exact workspace and the sibling stays untouched"

# --- 4. duplicate label with NO launcher identity: the label is the only way
#        to find the home workspace and it names two, so the worker nests under
#        the lowest-numbered one with one warning naming both ---------------

DUP_LOWEST=$(lab workspace list 2>/dev/null | jq -r '.result.workspaces[]? | select(.label == "firstmate") | .workspace_id' | sort -V | head -1)
[ "$(lab workspace list 2>/dev/null | jq -r '[.result.workspaces[]? | select(.label == "firstmate")] | length')" = 2 ] \
  || fail "the duplicate-label case needs exactly two 'firstmate' workspaces"
spawn_from_launcher "" "$PRIMARY_HOME" dupD "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a spawn whose home label names two workspaces must still nest the worker"$'\n'"$(cat "$SPAWN_ERR")"
[ "$(grep -c "herdr workspaces in session '$HERDR_LAB_SESSION' are labeled 'firstmate'" "$SPAWN_ERR")" = 1 ] \
  || fail "the duplicate-parent spawn did not print exactly one warning naming the duplicated home"$'\n'"$(cat "$SPAWN_ERR")"
assert_contains_local "$(cat "$SPAWN_ERR")" "lowest-numbered, $DUP_LOWEST" "the warning did not name the chosen workspace"
DUPD_META="$PRIMARY_HOME/state/dupD.meta"
record_worktree "$DUPD_META"
DUPD_WS=$(workspace_of_pane "$(grep '^herdr_pane_id=' "$DUPD_META" | cut -d= -f2-)")
assert_nested "$DUPD_WS" dupD "$DUP_LOWEST" "a worker under duplicated home workspaces"
return_worktrees "$DUPD_META"
[ "$(lab workspace list 2>/dev/null | jq -r '[.result.workspaces[]? | select(.label == "firstmate")] | length')" = 2 ] \
  || fail "a duplicated home must not gain a third 'firstmate' workspace"
pass "real herdr E2E: duplicate home-labeled workspaces with no launcher identity nest the worker under the lowest-numbered with one warning"

# --- 5. a STALE launcher pane refuses, even though the home label is
#        unambiguous from the launcher's own (now closed) workspace -----------
# A firstmate whose own pane was closed under it has an identity that no longer
# resolves. Guessing a workspace from the label is exactly what must not happen.

read -r _ _ STALE_PANE <<EOF
$(make_workspace stale-parent)
EOF
[ -n "$STALE_PANE" ] || fail "could not create the workspace whose pane goes stale"
lab pane close "$STALE_PANE" >/dev/null 2>&1
if lab pane get "$STALE_PANE" >/dev/null 2>&1; then
  fail "the launcher pane did not actually go away"
fi

spawn_from_launcher "$STALE_PANE" "$PRIMARY_HOME" staleF "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -ne 0 ] || fail "a launcher pane that no longer exists must refuse, not fall back to a label search"
assert_contains_local "$(cat "$SPAWN_ERR")" "$STALE_PANE" \
  "the stale-identity refusal did not name the launcher pane it could not resolve"
[ ! -e "$PRIMARY_HOME/state/staleF.meta" ] || fail "a refused spawn must not publish task metadata"
STALE_TABS=0
for w in $(lab workspace list 2>/dev/null | jq -r '.result.workspaces[]?.workspace_id'); do
  STALE_TABS=$((STALE_TABS + $(lab tab list --workspace "$w" 2>/dev/null | jq -r '[.result.tabs[]? | select(.label == "fm-staleF")] | length')))
done
[ "$STALE_TABS" = 0 ] || fail "a refused spawn created a worker endpoint anyway"
pass "real herdr E2E: a launcher pane that no longer exists refuses before any worker endpoint exists"

# --- 6. a secondmate launching its own worker gets the same guarantee -------

read -r WS_SM_DECOY _ _ <<EOF
$(make_workspace "2ndmate-$SM_ID")
EOF
read -r WS_SM_LAUNCH _ LAUNCH_SM_PANE <<EOF
$(make_workspace "2ndmate-$SM_ID")
EOF
[ -n "$WS_SM_DECOY" ] && [ -n "$WS_SM_LAUNCH" ] || fail "could not create the two secondmate-labeled workspaces"
WS_SM_DECOY_TABS_BEFORE=$(tab_labels_of_workspace "$WS_SM_DECOY")

spawn_from_launcher "$LAUNCH_SM_PANE" "$SM_HOME" smE "$PROJ" --mode no-mistakes --yolo off
[ "$SPAWN_RC" -eq 0 ] || fail "a secondmate-owned crewmate spawn failed"$'\n'"$(cat "$SPAWN_ERR")"
SME_META="$SM_HOME/state/smE.meta"
record_worktree "$SME_META"
SME_PANE=$(grep '^herdr_pane_id=' "$SME_META" | cut -d= -f2-)
SME_WS=$(workspace_of_pane "$SME_PANE")
[ -n "$SME_WS" ] && [ "$SME_WS" != "$WS_SM_LAUNCH" ] && [ "$SME_WS" != "$WS_SM_DECOY" ] \
  || fail "a secondmate's own worker must get its own workspace, got '$SME_WS'"
assert_nested "$SME_WS" smE "$WS_SM_LAUNCH" "the secondmate's worker"
[ "$(tab_labels_of_workspace "$WS_SM_DECOY")" = "$WS_SM_DECOY_TABS_BEFORE" ] \
  || fail "the duplicate secondmate-labeled workspace was mutated"
pass "real herdr E2E: a secondmate launching its own worker gets its own workspace too, and its same-labeled sibling is untouched"

# --- 7. a --secondmate launch is NOT collapsed into the launcher's workspace -

spawn_from_launcher "$LAUNCH_DUP_PANE" "$PRIMARY_HOME" "$SM2_ID" "$SM2_HOME" --secondmate
[ "$SPAWN_RC" -eq 0 ] || fail "the primary's --secondmate launch failed"$'\n'"$(cat "$SPAWN_ERR")"
SM2_META="$PRIMARY_HOME/state/$SM2_ID.meta"
SM2_PANE=$(grep '^herdr_pane_id=' "$SM2_META" | cut -d= -f2-)
SM2_WS=$(workspace_of_pane "$SM2_PANE")
[ "$SM2_WS" != "$WS_PRIMARY_DUP" ] \
  || fail "a --secondmate launch must stand up the secondmate's own workspace, not join the launcher's"
[ "$(label_of_workspace "$SM2_WS")" = "2ndmate-$SM2_ID" ] \
  || fail "a --secondmate launch should land in '2ndmate-$SM2_ID', got '$(label_of_workspace "$SM2_WS")'"
pass "real herdr E2E: a --secondmate launch still stands up that secondmate's own workspace instead of inheriting the launcher's"

# --- 8. teardown closes only the worker's own pane --------------------------

FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" FM_DATA_OVERRIDE="$PRIMARY_HOME/data" \
  FM_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" dupC >"$TMP_ROOT/teardown.out" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "fm-teardown.sh failed for dupC"$'\n'"$(cat "$TMP_ROOT/teardown.out")"
[ ! -f "$DUPC_META" ] || fail "fm-teardown.sh did not remove dupC's meta"
if lab pane get "$DUPC_PANE" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close dupC's own pane"
fi
lab pane get "$LAUNCH_DUP_PANE" >/dev/null 2>&1 || fail "teardown closed the launcher's own pane"
lab pane get "$UNIQB_PANE" >/dev/null 2>&1 || fail "teardown closed an unrelated worker's pane in another workspace"
[ "$(label_of_workspace "$WS_PRIMARY_DUP")" = firstmate ] || fail "teardown removed or renamed the launcher's workspace"
pass "real herdr E2E: teardown closes only the worker's own pane and leaves the launcher, its workspace, and the same-labeled sibling intact"

if ! cleanup_all; then
  trap - EXIT
  printf 'not ok - isolated Herdr lab teardown failed or the default fleet session changed\n' >&2
  exit 1
fi
trap - EXIT
pass "real herdr E2E: isolated lab session removed and default fleet session unchanged"
