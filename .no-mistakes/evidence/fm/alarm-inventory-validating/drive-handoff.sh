#!/usr/bin/env bash
# Live driver: real fm-crew-state.sh and fm-fleet-snapshot.sh against a disposable
# marked lab home, a real git worktree and a real private tmux server. Only the
# no-mistakes daemon is replaced by a scripted `no-mistakes axi` responder (the
# gate phase may not start real no-mistakes runs).
set -u
WT_ROOT=$1
cd "$WT_ROOT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
TMUXDIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
SOCK="$TMUXDIR/tmux-$(id -u)/default"
cleanup() {
  [ -S "$SOCK" ] && tmux -S "$SOCK" kill-server 2>/dev/null
  bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1
  rm -rf "$LAB"
}
trap cleanup EXIT
export FM_HOME="$LAB" TMUX_TMPDIR="$TMUXDIR"
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX

# Real crew worktree on its branch; the run was taken at an older head.
wt=$LAB/projects/handoff
mkdir -p "$wt"
git -C "$wt" init -q
git -C "$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$wt" checkout -q -b fm/handoff
git -C "$wt" update-ref refs/remotes/origin/main "$(git -C "$wt" rev-parse HEAD)"
RUN_HEAD=$(git -C "$wt" rev-parse HEAD)
[ -n "${ATTRIBUTED:-}" ] || git -C "$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'worker commit after the run head'

# Real tmux crew window on the lab socket.
TMUX_TMPDIR="$TMUXDIR" tmux new-session -d -s firstmate -n fm-handoff-ship -c "$wt" 'sleep 600'

cat > "$LAB/data/backlog.md" <<'EOF'
## In flight
- [ ] handoff-ship - Handed off to validation (repo: alpha) (kind: ship) (since 2026-11-06)

## Queued

## Done
EOF

cat > "$LAB/state/handoff-ship.meta" <<EOF
window=firstmate:fm-handoff-ship
worktree=$wt
project=$wt
harness=claude
kind=ship
mode=${MODE:-no-mistakes}
EOF
gen=$(bin/fm-busy-event.sh arm "$LAB/state" handoff-ship)
bin/fm-busy-event.sh apply "$LAB/state" handoff-ship idle --gen "$gen" --source claude-hook --event stop

FB=$LAB/fakebin; mkdir -p "$FB"
write_daemon() {  # <status|none>
  if [ "$1" = none ]; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/no-mistakes"
  else
    cat > "$FB/no-mistakes" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = axi ] || exit 0
cat <<'TOON'
run:
  id: "01RUN"
  branch: fm/handoff
  status: $1
  awaiting_agent: parked 2m10s
  head: "$RUN_HEAD"
  pr: ""
  findings: none
gate: review
TOON
SH
  fi
  chmod +x "$FB/no-mistakes"
}

scenario() {  # <label> <daemon-status|none> <status-line>
  write_daemon "$2"
  printf '%s\n' "$3" > "$LAB/state/handoff-ship.status"
  echo "=== $1"
  echo "daemon run status: $2"
  echo "status file: $(cut -c1-120 "$LAB/state/handoff-ship.status")$( [ "${#3}" -gt 120 ] && echo "... (${#3} chars)")"
  echo "--- fm-crew-state.sh handoff-ship"
  PATH="$FB:$PATH" bin/fm-crew-state.sh handoff-ship 2>&1 | grep -E '^state:' | cut -c1-200
  echo "--- fm-fleet-snapshot.sh --secondmate-home-summary"
  PATH="$FB:$PATH" bin/fm-fleet-snapshot.sh --secondmate-home-summary 2>&1 | jq -c '{valid, invalidity, reason: (.reason // null | if . then .[0:160] else . end)}'
  echo
}

scenario "1 handoff: done while the branch's run is parked at a gate" awaiting_approval 'done: implementation complete'
scenario "2 handoff: done while the branch's run is running" running 'done: implementation complete'
scenario "3 no run ever started: done reads terminal (alarm stays)" none 'done: no change needed'
scenario "4 run cancelled/aborted, no failed line: done reads terminal" cancelled 'done: implementation complete'
scenario "5 adversarial: worker note names a handoff, no live run" none 'done: pipeline handoff: validation run not finished'
scenario "5b adversarial: worker note mentions a pipeline handoff loosely, no live run" none 'done: pipeline handoff complete'
scenario "5c adversarial: worker note mentions handoff, cancelled run" cancelled 'done: handed off; pipeline handoff done'
scenario "6 adversarial: 5000-char note with live run (truncation)" awaiting_approval "done: $(printf 'x%.0s' $(seq 1 5000))"
if [ -z "${MODE:-}" ]; then
  sed -i '' 's/^mode=.*/mode=direct-PR/' "$LAB/state/handoff-ship.meta"
  scenario "7 non-no-mistakes mode (direct) with a live run: no marker" awaiting_approval 'done: implementation complete'
fi
