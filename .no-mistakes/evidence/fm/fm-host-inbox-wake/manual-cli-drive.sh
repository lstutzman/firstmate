#!/usr/bin/env bash
# Manual drive of the host-only check-row rule through the real CLI entry
# (bin/fm-branch-dispatch.mjs offer) in a disposable marked lab home.
set -u
ROOT=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
STATE="$LAB/state"
printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$STATE/demo.meta"
printf 'working [at=%s]: step one\n' "$(date +%s)" > "$STATE/demo.status"

run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; }
offer() { # <posture-flag or ""> <message>
  local flag=$1 msg=$2
  printf '\n$ printf %q | FM_HOME=$LAB node bin/fm-branch-dispatch.mjs offer %s\n' "$msg" "$flag"
  printf '%s\n' "$msg" | FM_HOME="$LAB" node "$ROOT/bin/fm-branch-dispatch.mjs" offer $flag 2>&1
}
pi_offer() { # Pi's own call site: no attendedHost argument
  printf '\n$ node: branchOfferForWake(state, %q, afk=false)  # Pi watcher call, no attendedHost\n' "$1"
  node --input-type=module -e '
    const d = await import(process.argv[1]);
    console.log("pi eligible=" + d.branchOfferForWake(process.argv[2], process.argv[3], false).eligible);
  ' "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$STATE" "$1" 2>&1
}

echo "### 1. baseline: one crewmate signal row the branch could take, no check row"
FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_wake_append signal demo.status "signal: $2/demo.status"' _ "$ROOT/bin/fm-wake-lib.sh" "$STATE"
run cat "$STATE/.wake-queue"
offer "" "signal: $STATE/demo.status"

echo; echo "### 2. the captain queues an inbox note (real bin/fm-inbox.sh note path)"
run env FM_HOME="$LAB" "$ROOT/bin/fm-inbox.sh" note 'captain: ship the hotfix first'
run cat "$STATE/.wake-queue"

echo; echo "### 3. attended host: every close stays main's while the check row waits"
offer "" "signal: $STATE/demo.status"
offer "" "heartbeat"
offer "" "stale: demo"
echo; echo "### 4. attended scope leaves the check row to main (rows= names only the signal row)"
run env FM_HOME="$LAB" node "$ROOT/bin/fm-branch-dispatch.mjs" scope

echo; echo "### 5. away posture unchanged: the branch still takes the close beside the note"
offer "--afk" "signal: $STATE/demo.status"

echo; echo "### 6. Pi's own offer unchanged: no attendedHost argument, so the note does not veto"
pi_offer "signal: $STATE/demo.status"

echo; echo "### 7. main's drain presents the captain's note"
printf '%s\n' "$$" > "$STATE/.lock"
run env FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh"

echo; echo "### 8. main acknowledges what its drain presented (the drain's own printed ack command); the attended close is the branch's again"
ack=$(FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" 2>&1 | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p')
printf '\n$ FM_HOME=$LAB bin/fm-wake-drain.sh %s\n' "$ack"
# shellcheck disable=SC2086
FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" $ack 2>&1 | grep -v '^●' ; echo "ack rc=${PIPESTATUS[0]}"
run cat "$STATE/.wake-queue"
echo "(queue now holds no unread check row)"
FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_wake_append signal demo.status "signal: $2/demo.status"' _ "$ROOT/bin/fm-wake-lib.sh" "$STATE"
run cat "$STATE/.wake-queue"
offer "" "signal: $STATE/demo.status"
echo; echo "### done; lab home removed on exit"
