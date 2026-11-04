#!/usr/bin/env bash
# Live scenario driver: spawn a real Herdr ship (real fm-spawn, real herdr in a
# named fm-lab-* session, real treehouse) from a product root, then restart the
# lab Herdr session the way a host reboot does and record where the restored
# pane resumes. Usage: herdr-restore-cwd-live.sh <product-root> <label> <presentation:on|off>
set -u
ROOT=$1 LABEL=$2 PRES=$3
GATE_ROOT={run-worktree}
. "$GATE_ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-restore-cwd.XXXXXX")
SESSION=$(fm_herdr_lab_name "rc$LABEL" 2>/dev/null || echo "fm-lab-rc$LABEL-$$")
export HERDR_SESSION="$SESSION"
WT=
cleanup() {
  [ -n "$WT" ] && (cd "$PROJ" 2>/dev/null && treehouse return --force "$WT") >/dev/null 2>&1
  herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  /usr/bin/trash "$TMP_ROOT"
}
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || { echo "FAIL prepare"; exit 1; }
. "$GATE_ROOT/bin/fm-backend.sh"; fm_backend_source herdr

H="$TMP_ROOT/home"; mkdir -p "$H/state" "$H/data/rc1" "$H/config" "$H/projects"
[ "$PRES" = off ] && printf 'off\n' > "$H/config/herdr-presentation-spaces"
printf '@AGENTS.md\n' > "$H/CLAUDE.md"; printf '# lab home\n' > "$H/AGENTS.md"
printf '# Task\n## Captain'"'"'s intent\nlab\n\n## Firstmate spec\nlab\n' > "$H/data/rc1/brief.md"
PROJ="$H/projects/scratch"; mkdir -p "$PROJ"; git -C "$PROJ" init -q
printf '# s\n' > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm i
git clone -q --bare "$PROJ" "$TMP_ROOT/origin.git"; git -C "$PROJ" remote add origin "file://$TMP_ROOT/origin.git"

echo "== product root: $ROOT  session: $SESSION  presentation: $PRES"
FM_SPAWN_NO_GUARD=1 FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" rc1 "$PROJ" \
  "sh -c 'echo crew-ok; exec sleep 900'" --mode no-mistakes --yolo off --backend herdr >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
rc=$?
echo "spawn exit=$rc"; [ "$rc" -eq 0 ] || { tail -20 "$TMP_ROOT/err"; exit 1; }
WT=$(grep '^worktree=' "$H/state/rc1.meta" | cut -d= -f2-)
PANE=$(grep '^herdr_pane_id=' "$H/state/rc1.meta" | cut -d= -f2-)
echo "project clone      : $PROJ"
echo "recorded worktree  : $WT"
echo "treehouse slot     : $(jq -c ".worktrees[] | select(.path==\"$WT\") | del(.seed_inventory_digest)" $(dirname $(dirname "$WT"))/treehouse-state.json)"
echo "pane creation cwd  : $(herdr pane get "$PANE" --session "$SESSION" | jq -r '.result.pane.cwd')"
echo "-- restarting the lab Herdr session (host-reboot stand-in)"
fm_herdr_lab_stop "$SESSION" >/dev/null 2>&1 || { echo "FAIL stop"; exit 1; }
fm_backend_herdr_server_ensure "$SESSION" || { echo "FAIL restart"; exit 1; }
sleep 2
J=$(herdr pane get "$PANE" --session "$SESSION")
echo "restored pane cwd  : $(printf '%s' "$J" | jq -r '.result.pane.cwd')"
echo "restored fg cwd    : $(printf '%s' "$J" | jq -r '.result.pane.foreground_cwd')"
R=$(printf '%s' "$J" | jq -r '.result.pane.foreground_cwd')
if [ "$R" = "$WT" ]; then echo "RESULT: restored pane resumes in the task worktree"
elif [ "$R" = "$PROJ" ]; then echo "RESULT: restored pane resumes in the project clone (under the home's CLAUDE.md)"
else echo "RESULT: restored pane resumes in $R"; fi
echo "-- teardown"
FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" rc1 >"$TMP_ROOT/td" 2>&1; echo "teardown exit=$?"; tail -3 "$TMP_ROOT/td"
echo "slot after teardown: $(jq -c ".worktrees[] | select(.path==\"$WT\") | del(.seed_inventory_digest)" $(dirname $(dirname "$WT"))/treehouse-state.json)"
