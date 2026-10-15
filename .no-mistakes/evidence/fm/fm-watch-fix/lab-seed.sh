#!/usr/bin/env bash
# seed.sh <lab-home> <repo-root>
set -u
LAB=$1; ROOT=$2; ST=$LAB/state
. "$ROOT/bin/fm-pending-reply-lib.sh"
: > "$LAB/config/wait-no-turns"
NOW=$(date +%s)
# big log for hibit with open decision at the end
perl -e 'for $i (1..40000){ if($i%50==0){print "done [at=$i]: step $i\n"} else {print "working [at=$i]: tick $i of the long-lived mate log\n"}} print "needs-decision [key=ask]: narrow or wide?\n"' > "$ST/hibit.status"
mk() { # task completed-epoch
  local corr
  export FM_PENDING_REPLY_NOW=$(( $2 - 60 ))
  corr=$(fm_pending_reply_create "$LAB" "$ST" "$1" "relayed ask for $1")
  fm_pending_reply_mark_delivered "$ST" "$corr"
  fm_pending_reply_observe_busy "$ST" "$corr" busy
  export FM_PENDING_REPLY_NOW=$2
  fm_pending_reply_observe_busy "$ST" "$corr" idle
  printf '%s %s\n' "$1" "$corr"
}
for i in $(seq 1 60); do mk hibit $((NOW - 3600)); done
printf 'working: started\nneeds-decision [key=captain-ask]: merge or wait?\n' > "$ST/oldmate.status"
for i in 1 2 3; do mk oldmate $((NOW - 90000)); done
# procevent inbox
IN=$ST/procevent-inbox; mkdir -p "$IN"; chmod 700 "$IN"
seq_() { local b="$IN/$1.$2"; head -c 200000 /dev/urandom | base64 > "$b.result"; printf 'quota\n' > "$b.adapter"; printf 'hibit\n' > "$b.owner-task"; chmod 600 "$b".*;
  if [ "$3" != unhandled ]; then : > "$b.handled"; touch -d "@$(( NOW - $3*86400 ))" "$b.handled"; fi; }
seq_ src 1 5; seq_ src 2 4; seq_ src 3 1; seq_ src 4 unhandled; seq_ other 1 10
