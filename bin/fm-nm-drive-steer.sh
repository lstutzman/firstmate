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
# Two guards keep that automatic start from spending review tokens on a head
# that is about to change (the cancelled-run measurement behind them is in the
# change that added them):
#   settle    a start steer, and the supersede below, wait until the branch
#             head has not moved for FM_NM_START_SETTLE_SECS (default 120): the
#             later of the worker's done: stamp and the head commit's committer
#             time must be at least that old. Two minutes covers the worker's
#             last amend or rebase after its done line and stays under the
#             stale escalation (FM_STALE_ESCALATE_SECS, 240), so the watcher
#             holds the pane quietly instead of alarming. Exit 4 means "wait,
#             nothing sent, nothing recorded"; 0 disables the window.
#   supersede a run that is pending, or still at its intent or rebase step,
#             while the worker's committed head is no longer covered by the
#             run's head (fm_nm_head_matches_worktree: the run head is neither
#             that head nor a descendant of it) is cancelled through
#             `no-mistakes axi abort --run <id>` before its review step spends
#             anything, and the worker gets the start steer for the new head.
#             Once per task generation, only when no drive call is live, and
#             never for a run at review or later. Unreadable or unverifiable
#             run facts leave the run alone.
#
# Exit 0 when a steer was durably sent, 1 when none was sent, 2 for a usage
# error, 4 when a start or supersede is waiting for the head to settle.
# FM_CREW_STATE_BIN overrides the current-state reader, as for the watcher.
# Prints nothing on stdout.
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

# Seconds since the branch head last moved: the later of the worker's done:
# stamp (a start only) and the head commit's committer time. Unknown times
# count as long ago, and a stamp in the future (clock skew) is ignored, so no
# unreadable input can hold a steer back for good.
settle_window=${FM_NM_START_SETTLE_SECS:-120}
case "$settle_window" in ''|*[!0-9]*) settle_window=120 ;; esac
head_quiet_secs() {  # -> seconds since the head last moved
  local now since=0 ct at
  now=$(date +%s) || { printf '%s' "$settle_window"; return; }
  ct=$(git -C "$wt" log -1 --format=%ct HEAD 2>/dev/null) || ct=
  case "$ct" in ''|*[!0-9]*) ;; *) since=$ct ;; esac
  if [ "$slip" = start ] && at=$(status_line_at_epoch "$last") && [ "$at" -gt "$since" ]; then
    since=$at
  fi
  [ "$since" -le "$now" ] || since=0
  printf '%s' "$(( now - since ))"
}

# Run id named by crew-state's `run: <id>` detail; empty when it names none.
run_id=$(printf '%s' "$line" | sed -n 's/.*[ ·]run: \([A-Za-z0-9]*\).*/\1/p')

# 0 when run $1 has not reached its review step and its head no longer covers
# the worker's committed head, so cancelling it forfeits no review work.
run_is_superseded_pre_review() {  # <run-id>
  local out rstatus rhead step
  [ -n "$1" ] || return 1
  out=$(fm_nm_run_checked "$wt" 10 axi status --run "$1") || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")" = "$1" ] || return 1
  rstatus=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
  rhead=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head_sha)")
  [ -n "$(fm_nm_resolve_commit "$wt" "$rhead")" ] || return 1
  ! fm_nm_head_matches_worktree "$wt" "$rhead" || return 1
  step=$(fm_nm_run_progress "$out" 2>/dev/null | cut -f4) || step=
  case "$rstatus:$step" in
    pending:|pending:intent|pending:rebase|running:intent|running:rebase) return 0 ;;
  esac
  return 1
}

if [ "$slip" = reattach ] && run_is_superseded_pre_review "$run_id"; then
  slip=supersede
fi

case "$slip" in
  start|supersede)
    [ "$(head_quiet_secs)" -ge "$settle_window" ] || exit 4
    ;;
esac

! grep -Fxq -- "$gen $slip" "$marker" 2>/dev/null || exit 1
printf '%s %s\n' "$gen" "$slip" >> "$marker" || exit 1

if [ "$slip" = supersede ]; then
  fm_nm_run_checked "$wt" 30 axi abort --run "$run_id" >/dev/null 2>&1 || true
  out=$(fm_nm_run_checked "$wt" 10 axi status --run "$run_id") || exit 1
  case "$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)") $(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")" in
    *cancelled*) ;;
    *) exit 1 ;;
  esac
fi

case "$slip" in
  start)
    text="Automatic steer: your done: is the pipeline handoff, and no no-mistakes run exists for $branch, so validation has not started. Run /no-mistakes now as your brief's Definition of done says: background the drive call, declare the wait, reattach whenever it returns without a gate or outcome, and report done only with the green, non-draft PR URL."
    ;;
  supersede)
    text="Automatic steer: firstmate cancelled the no-mistakes run for $branch before its review step because the branch head moved after that run started, so it would have reviewed a stale head. Run /no-mistakes now for the current head as your brief's Definition of done says: check branch_sync.next_action in \`no-mistakes axi status\` first, background the drive call, declare the wait, reattach whenever it returns without a gate or outcome, and report done only with the green, non-draft PR URL."
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
