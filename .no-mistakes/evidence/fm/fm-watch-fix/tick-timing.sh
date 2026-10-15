#!/usr/bin/env bash
set -u
export FM_HOME=$2 PATH="/tmp/fm-test-scripts-01M50/fakebin:$PATH"
. "$1/bin/fm-pending-reply-lib.sh"
for n in 1 2 3; do
  s=$(date +%s%N); fm_pending_reply_tick "$2/state"; e=$(date +%s%N)
  echo "tick $n: $(( (e-s)/1000000 )) ms"
done
