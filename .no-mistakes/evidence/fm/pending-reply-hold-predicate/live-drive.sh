#!/usr/bin/env bash
# Live drive of the wait-no-turns pending-reply hold in a disposable marked lab home.
# Real bin/fm-send.sh delivers the request and the repost (no send hook);
# a real tmux pane on the private fm-lab socket stands as the mate's window.
set -u
ROOT=$1; SCEN=$2
cd "$ROOT"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_PENDING_REPLY_SEND_HOOK
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/sm/state"
export TMUX_TMPDIR="$LAB/tmux"
cleanup() { tmux -L fm-lab kill-server 2>/dev/null; /usr/bin/trash "$LAB"; }
trap cleanup EXIT
command -v tmux >/dev/null && tmux -L fm-lab new-session -d -s firstmate -n fm-hibit bash; echo "tmux on PATH: $(command -v tmux || echo no)"
export TMUX="$LAB/tmux/tmux-$(id -u)/fm-lab,0,0"
export FM_HOME="$LAB" FM_SEND_SETTLE=0 FM_PENDING_REPLY_GRACE_SECS=60 FM_PENDING_REPLY_HOLD_ESCALATE_SECS=1000
: > "$LAB/config/wait-no-turns"
. tests/lib.sh >/dev/null 2>&1 || true
fm_write_secondmate_meta "$LAB/state/hibit.meta" "$LAB/sm" "firstmate:fm-hibit"
. bin/fm-pending-reply-lib.sh
S="$LAB/state"
echo "== lab home: $LAB (marked: $(ls -a $LAB | grep -c fm-lab)) ; wait-no-turns present"
FM_PENDING_REPLY_NOW=1000 bin/fm-send.sh hibit "status of phase 7, please report" >/dev/null 2>&1; echo "fm-send request rc=$?"
corr=$(ls "$S/pending-replies" | sed -n 's/\.rec$//p;s/\.env$//p' | head -1)
[ -n "$corr" ] || corr=$(ls "$S/pending-replies" | head -1 | sed 's/\..*//')
rec=$(fm_pending_reply_path "$S" "$corr")
echo "corr=$corr phase=$(fm_pending_reply_get "$rec" phase) delivered=$(fm_pending_reply_get "$rec" delivered_epoch)"
inbox_count() { find "$S/hibit.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }
echo "inbox records after request: $(inbox_count)"
export FM_PENDING_REPLY_NOW=1000
fm_pending_reply_observe_busy "$S" "$corr" busy; fm_pending_reply_observe_busy "$S" "$corr" idle
# mate's status history: two open keyed decisions from earlier
printf 'needs-decision [key=ask-a]: merge or wait?\nneeds-decision [key=ask-b]: which host?\n' >> "$S/hibit.status"
case "$SCEN" in
  working) printf 'working [at=1001]: back on the build\n' >> "$S/hibit.status" ;;
  paused) printf 'paused [at=1001]: waiting on the MacBook\n' >> "$S/hibit.status" ;;
  captain-held) printf 'captain-held [at=1001]: awaiting the captain\n' >> "$S/hibit.status" ;;
  keyed) printf 'working [at=1001]: busy\nneeds-decision [key=later-ask]: merge or wait?\n' >> "$S/hibit.status" ;;
  close) : ;;  # latest event is open keyed needs-decision ask-b
  two) second_corr=1 ;;
esac
if [ "$SCEN" = two ]; then
  FM_PENDING_REPLY_NOW=1000 bin/fm-send.sh hibit "second ask" >/dev/null 2>&1
  c2=$(ls "$S/pending-replies" | sed 's/\..*//' | sort -u | grep -v "^$corr$" | head -1)
  fm_pending_reply_observe_busy "$S" "$c2" busy; fm_pending_reply_observe_busy "$S" "$c2" idle
  echo "second corr=$c2"
fi
echo "-- mate status log:"; sed 's/^/   /' "$S/hibit.status"
before=$(inbox_count)
echo "== tick at t=1200 (past 60s grace, before 1000s hold bound)"
export FM_PENDING_REPLY_NOW=1200; fm_pending_reply_tick "$S"
echo "phase=$(fm_pending_reply_get "$rec" phase) recovery_attempted=$(fm_pending_reply_get "$rec" recovery_attempted_epoch) inbox+$(( $(inbox_count) - before ))"
latest=$(find "$S/hibit.inbox" -maxdepth 1 -name '*.msg' | sort | tail -1)
[ "$(( $(inbox_count) - before ))" -gt 0 ] && { echo "-- repost body delivered to mate inbox:"; bash -c '. "$1"; fm_task_inbox_body "$2"' _ bin/fm-task-inbox-lib.sh "$latest" | head -5 | sed 's/^/   /'; }
echo "== ticks at t=2100 (past hold bound)"
export FM_PENDING_REPLY_NOW=2100; fm_pending_reply_tick "$S"; fm_pending_reply_tick "$S"
echo "phase=$(fm_pending_reply_get "$rec" phase) held_lines=$(grep -c "pending-reply-held: task=hibit pending-reply-id=$corr " "$S/hibit.status") inbox+$(( $(inbox_count) - before ))"
if [ "$SCEN" = two ]; then r2=$(fm_pending_reply_path "$S" "$c2"); echo "second phase=$(fm_pending_reply_get "$r2" phase) held_lines=$(grep -c "pending-reply-held: task=hibit pending-reply-id=$c2 " "$S/hibit.status")"; fi
if [ "$SCEN" = close ]; then
  echo "== late correlated report arrives"
  printf 'working [at=2200]: phase 7 done corr=%s\n' "$corr" >> "$S/hibit.status"
  export FM_PENDING_REPLY_NOW=2200; fm_pending_reply_tick "$S"
  echo "phase=$(fm_pending_reply_get "$rec" phase) open_held_key=$(status_open_decisions "$S/hibit.status" | cut -f1 | grep -c "^pending-reply-$corr$")"
fi
echo "-- final mate status log tail:"; tail -4 "$S/hibit.status" | sed 's/^/   /'
