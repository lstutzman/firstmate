#!/usr/bin/env bash
# fm-nm-drive-steer.sh - send a quiet no-mistakes ship worker the one fixed steer
# it needs when nothing is driving its validation, instead of a stale alarm.
#
# Usage: fm-nm-drive-steer.sh <task-id>
#        fm-nm-drive-steer.sh --help
#
# bin/fm-watch.sh calls this on the first sight of a new stale pane hash for an
# ordinary crew, outside away mode, before it decides whether to alarm. Two
# slips leave a no-mistakes ship idle with nothing that will wake it:
#   start     its last event is the pre-pipeline `done:` handoff (a note that
#             does not report a CI-ready or published PR) and no no-mistakes
#             run is attributed to its branch, so validation never started;
#   reattach  a run is attributed to its branch and is executing (pending,
#             running, fixing, ci) or parked at a gate the worker itself owes,
#             yet no drive call is running from its copy, so nothing will wake
#             it at the run's next gate or outcome.
# When the run is pending (queued behind the machine's max_concurrent_runs
# slots), the reattach steer also names the runs in this repo holding slots,
# each as branch and run id from the `no-mistakes axi` overview, and says the
# wait is `paused [cause=external]`, not `blocked`. The overview lists only this
# repo's runs while the cap is machine-wide, so runs in other repos may also
# hold slots; the steer says so rather than presenting a full list.
# Either slip gets one fixed text steer through bin/fm-send.sh, the durable
# steering inbox, at most once per slip per task generation (the meta's
# spawn_gen), recorded in state/.nm-drive-steer-<task-id> before the send so a
# failed send is never retried. After that the watcher's ordinary stale and
# wedge path owns the pane again.
#
# Nothing is sent when any of these holds: the task is not a local no-mistakes
# ship (kind=ship, mode=no-mistakes, no remote_host); its record names no
# branch, worktree, or spawn generation; its last event is blocked,
# needs-decision, failed, or captain-held, or a `paused:` declared with
# [cause=external] or a [dep=...] tag; any needs-decision is still open (an
# older blocker a later event superseded does not count, as on the wedge
# ladder, which reads only the newest event); its
# steering inbox already holds an unhandled steer; a drive call is running from
# its worktree, or that cannot be established (fm_nm_drive_call_live in
# bin/fm-nm-run-lib.sh); bin/fm-crew-state.sh does not name one of the two
# slips, including a gate whose answer a human owes; or the slip was already
# steered this generation.
#
# Exit 0 when a steer was durably sent, 1 when none was sent, 2 for a usage
# error. FM_CREW_STATE_BIN overrides the current-state reader, as for the
# watcher. Prints nothing on stdout.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_CREW_STATE_BIN=${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -eq 1 ] && [ -n "$1" ] || { usage >&2; exit 2; }
id=$1
case "$id" in
  */*|.*|*[!A-Za-z0-9._-]*) echo "error: '$id' is not a task id" >&2; exit 2 ;;
esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

meta="$STATE/$id.meta"
statusf="$STATE/$id.status"
[ -f "$meta" ] && [ -f "$statusf" ] || exit 1
[ "$(fm_meta_get "$meta" kind)" = ship ] || exit 1
[ "$(fm_meta_get "$meta" mode)" = no-mistakes ] || exit 1
[ -z "$(fm_meta_get "$meta" remote_host)" ] || exit 1
branch=$(fm_meta_get "$meta" branch)
wt=$(fm_meta_get "$meta" worktree)
gen=$(fm_meta_get "$meta" spawn_gen)
[ -n "$branch" ] && [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$gen" ] || exit 1
marker="$STATE/.nm-drive-steer-$id"
if grep -Fxq -- "$gen start" "$marker" 2>/dev/null && grep -Fxq -- "$gen reattach" "$marker" 2>/dev/null; then
  exit 1
fi

last=$(last_status_line "$statusf")
verb=$(status_line_verb "$last")
case "$verb" in
  blocked|needs-decision|failed|captain-held) exit 1 ;;
esac
if status_is_paused "$last"; then
  [ "$(status_line_cause "$last")" != external ] || exit 1
  [ -z "$(status_line_dep "$last")" ] || exit 1
fi
! status_has_open_needs_decision "$statusf" || exit 1
! fm_task_inbox_oldest_unhandled "$STATE" "$id" >/dev/null || exit 1

fm_nm_drive_call_live "$wt"
[ "$?" -eq 1 ] || exit 1

line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
case "$line" in "state: "*) ;; *) exit 1 ;; esac
state=${line#state: }
state=${state%% *}
src=${line#*source: }
src=${src%% *}
detail=${line#*source: "$src"}
detail=${detail# · }

slip=
if [ "$src" = run-step ]; then
  case "$state" in
    working) slip=reattach ;;
    parked)
      case " · $detail · " in
        *" · $FM_GATE_HUMAN_DECISION · "*) ;;
        *) slip=reattach ;;
      esac
      ;;
  esac
elif [ "$src" = status-log ] && [ "$verb" = "done" ] \
  && ! fm_dod_should_gate_ship_done ship no-mistakes "$last"; then
  # bin/fm-crew-state.sh leads with this marker when the daemon still reports a
  # live run its run-step route could not attribute: reattach, never restart.
  case "$detail" in
    "pipeline handoff:"*) slip=reattach ;;
    *) slip=start ;;
  esac
fi
[ -n "$slip" ] || exit 1

! grep -Fxq -- "$gen $slip" "$marker" 2>/dev/null || exit 1
printf '%s %s\n' "$gen" "$slip" >> "$marker" || exit 1

case "$slip" in
  start)
    text="Automatic steer: your done: is the pipeline handoff, and no no-mistakes run exists for $branch, so validation has not started. Run /no-mistakes now as your brief's Definition of done says: background the drive call, declare the wait, reattach whenever it returns without a gate or outcome, and report done only with the green, non-draft PR URL."
    ;;
  reattach)
    text="Automatic steer: the no-mistakes run for $branch is still active, but no no-mistakes axi run or respond call is running from your copy, so nothing will wake you at its next gate or outcome. Re-run \`no-mistakes axi run\` with no flags now, backgrounded as your brief's Definition of done says, and reattach the same way every time it returns without a gate or outcome."
    ;;
esac

if [ "$slip" = reattach ]; then
  case "$detail" in
    *"(pending)"*)
      overview=$(fm_nm_run "$wt" 10 axi)
      ids=$(fm_nm_table_column "$overview" runs id)
      branches=$(fm_nm_table_column "$overview" runs branch)
      run_statuses=$(fm_nm_table_column "$overview" runs status)
      holders=$(paste -d '\t' <(printf '%s\n' "$ids") <(printf '%s\n' "$branches") <(printf '%s\n' "$run_statuses") \
        | awk -F '\t' -v own="$branch" '$3 == "running" && $2 != own { printf "%s%s (run %s)", sep, $2, $1; sep = ", " }')
      text="$text Your run is pending because the machine's run slots are full, which is \`paused [cause=external]\`, not \`blocked\`; keep reattaching."
      [ -z "$holders" ] || text="$text Runs in this repo holding the slots (runs in other repos may hold more): $holders."
      ;;
  esac
fi

FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SEND_EXPECTED_SPAWN_GEN="$gen" \
  fm_run_timed 30 "$SCRIPT_DIR/fm-send.sh" "$id" "$text" </dev/null >/dev/null 2>&1 || exit 1
exit 0
