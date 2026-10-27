#!/usr/bin/env bash
# Live: main's (parent lab home's) real watcher, re-armed after each wake the way
# firstmate re-arms it, wakes on a machine-service notice relayed by the child home.
set -u
REPO=$1; cd "$REPO"
unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
CHILD=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); PARENT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$CHILD" >/dev/null; bin/fm-lab-home.sh create "$PARENT" >/dev/null
mkdir -p "$CHILD/tmux" "$PARENT/tmux"
trap 'kill $loop 2>/dev/null; TMUX_TMPDIR="$CHILD/tmux" tmux kill-server 2>/dev/null; TMUX_TMPDIR="$PARENT/tmux" tmux kill-server 2>/dev/null; /usr/bin/trash "$CHILD" "$PARENT"' EXIT
printf 'deepthought-lab\n' > "$CHILD/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$CHILD/.fm-secondmate-parent"
rec() { printf '{"kind":"%s","source":"nightly-scan","item_id":"PC-3385","severity":"high","evidence_path":"/var/lib/secscan/f.json","request_id":"%s"%s}' "$1" "$2" "${3:-}"; }
armloop() {  # <home> <log>: re-arm the real watcher after every wake, like firstmate
  while :; do FM_POLL=2 FM_HOME="$1" TMUX_TMPDIR="$1/tmux" bash bin/fm-watch.sh >> "$2" 2>>"$2.err"; echo "--- (re-armed)" >> "$2"; done
}
armloop "$PARENT" "$PARENT/wakes.log" & loop=$!
sleep 8
echo "== parent wakes before any relay:"; cat "$PARENT/wakes.log"; : > "$PARENT/wakes.log"
echo "== child: scan submits a notice; child watcher relays it"
rec notice live-notice ',"summary":"secret finding: gitleaks generic-api-key in api/settings.py"' | FM_HOME="$CHILD" TMUX_TMPDIR="$CHILD/tmux" bin/fm-inbox.sh service; echo
armloop "$CHILD" "$CHILD/wakes.log" & cloop=$!
sleep 6; kill $cloop 2>/dev/null
echo "-- child wakes (first 3):"; head -3 "$CHILD/wakes.log"
echo "-- child wake queue:"; cut -f2- "$CHILD/state/.wake-queue"
echo "-- parent channel:"; cat "$PARENT/state/deepthought-lab.status"
sleep 40; echo "== parent wakes after relay:"; cat "$PARENT/wakes.log"
echo "-- parent wake queue:"; cut -f2- "$PARENT/state/.wake-queue" 2>/dev/null
true
. bin/fm-classify-lib.sh; l=$(cat "$PARENT/state/deepthought-lab.status"); status_is_captain_relevant "$l" && echo "classifier: captain-relevant verb=$(status_line_verb "$l")"
kill $loop; pkill -P $loop 2>/dev/null; true
