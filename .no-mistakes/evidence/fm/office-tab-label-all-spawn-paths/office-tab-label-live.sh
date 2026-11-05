#!/usr/bin/env bash
# Live real-Herdr lab scenario: an office's own tab carries its bare role name
# on the presentation-projection spawn path and the destroyed-endpoint
# (restart husk) reclaim path, including migration of a legacy fm-<id> journal;
# an ordinary worker in the same office home keeps fm-<id>.
set -u
ROOT=${ROOT:?}
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-office-tab-live.XXXXXX")
H="$ROOT/bin/fm-herdr-lab.sh"
S=$("$H" name office-tab) || exit 1
export HERDR_SESSION="$S"
WTS=(); CLEANED=0; RC=0
cleanup() {
  [ "$CLEANED" = 0 ] || return 0; CLEANED=1
  for wt in ${WTS[@]+"${WTS[@]}"}; do treehouse return --force "$wt" >/dev/null 2>&1; done
  "$H" teardown "$S" && echo "TEARDOWN: lab $S removed, default session tripwire intact" || echo "TEARDOWN FAILED"
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null; rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; RC=1; }
ok() { echo "PASS: $*"; }
"$H" provision "$S" || { echo "provision failed"; exit 1; }
lab() { "$H" run "$S" "$@"; }
tab_label() { lab tab get "$1" 2>/dev/null | jq -r '.result.tab.label // empty'; }
ws_label() { lab workspace get "$1" 2>/dev/null | jq -r '.result.workspace.label // empty'; }
meta() { grep "^$2=" "$1" | tail -1 | cut -d= -f2-; }
jfield() { grep "^$2=" "$1" | head -1 | cut -d= -f2-; }

PROJ="$TMP_ROOT/proj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q
printf x > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

PARENT="$TMP_ROOT/parent"; mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config"
printf -- '- qmoff - Run the fleet. (role: quartermaster; added 2026-11-05)\n' > "$PARENT/data/offices.md"
OFF="$TMP_ROOT/office"; mkdir -p "$OFF/state" "$OFF/config" "$OFF/data/qmoff" "$OFF/data/wk1"
printf 'qmoff\n' > "$OFF/.fm-secondmate-home"; printf 'qmoff\n' > "$OFF/.fm-office"
printf '# Office authority\nTest office.\n' > "$OFF/data/charter.md"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$OFF/.fm-secondmate-parent"
: > "$OFF/config/herdr-presentation-spaces"
printf '%s\n' fm-office-authority-v1 id=qmoff dispatch=proj merge=proj merge-via=none auto-merge-classes=none wip=5 \
  admission-sha256=proj:0000000000000000000000000000000000000000000000000000000000000000 > "$OFF/config/office-authority"
bash -c '. "$1/bin/fm-config-inherit-lib.sh" && fm_inherit_receipt_commit "$2/.fm-inherit-office-authority.generation" "$2/office-authority"' _ "$ROOT" "$OFF/config" || { echo "receipt failed"; exit 1; }
for id in qmoff wk1; do printf '# Task\n## Captain'"'"'s intent\nlabel check %s\n\n## Firstmate spec\nnothing\n' "$id" > "$OFF/data/$id/brief.md"; done

spawn() {  # <id>
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$S" FM_GATE_REFUSE_BYPASS=1 \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$OFF" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$1" "$PROJ" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr \
    >"$TMP_ROOT/$1.$2.out" 2>"$TMP_ROOT/$1.$2.err"
  local rc=$?; echo "spawn $1 ($2) rc=$rc"; sed 's/^/  stderr: /' "$TMP_ROOT/$1.$2.err" | grep -i 'warn\|error' | head -5
  local wt; wt=$(meta "$OFF/state/$1.meta" worktree 2>/dev/null); [ -n "$wt" ] && WTS+=("$wt")
  return $rc
}
report() {  # <id> <expected> <what>
  local m="$OFF/state/$1.meta" t w l wl jl
  t=$(meta "$m" herdr_tab_id); w=$(meta "$m" herdr_workspace_id); l=$(tab_label "$t"); wl=$(ws_label "$w")
  jl=$(jfield "$OFF/state/$1.herdr-presentation" task_label 2>/dev/null)
  echo "  $1: tab=$t tab_label='$l' workspace='$wl' journal_task_label='$jl'"
  case "$wl" in "└ "*" · p:"*) : ;; *) fail "$3: $1 is not in a projected presentation workspace ('$wl')"; return ;; esac
  [ "$l" = "$2" ] && ok "$3: $1 tab label is '$2'" || fail "$3: $1 tab label '$l' != '$2'"
  [ "$jl" = "$2" ] && ok "$3: $1 journal task_label is '$2'" || fail "$3: $1 journal task_label '$jl' != '$2'"
}
restart_lab() { "$H" stop "$S" >/dev/null && "$H" provision "$S" >/dev/null || { echo "restart failed"; exit 1; }; }

lab workspace create --cwd "$TMP_ROOT" --label Quartermaster --no-focus >/dev/null || { echo "parent ws create failed"; exit 1; }
echo "== S1 projection path: fresh spawns in an office home with presentation on"
spawn qmoff first || fail "office spawn failed: $(cat "$TMP_ROOT/qmoff.first.err")"
spawn wk1 first || fail "worker spawn failed: $(cat "$TMP_ROOT/wk1.first.err")"
report qmoff Quartermaster "projection"
report wk1 fm-wk1 "projection"
[ "$RC" = 0 ] || { echo "S1 failed; stopping"; exit 1; }

echo "== S2 reclaim path: restart session (husk panes), respawn same ids"
OLD_Q_PANE=$(meta "$OFF/state/qmoff.meta" herdr_pane_id); OLD_Q_WS=$(meta "$OFF/state/qmoff.meta" herdr_workspace_id)
restart_lab
spawn qmoff reclaim1 || fail "office reclaim failed: $(cat "$TMP_ROOT/qmoff.reclaim1.err")"
spawn wk1 reclaim1 || fail "worker reclaim failed: $(cat "$TMP_ROOT/wk1.reclaim1.err")"
NEW_Q_PANE=$(meta "$OFF/state/qmoff.meta" herdr_pane_id); NEW_Q_WS=$(meta "$OFF/state/qmoff.meta" herdr_workspace_id)
[ "$NEW_Q_WS" = "$OLD_Q_WS" ] && [ "$NEW_Q_PANE" != "$OLD_Q_PANE" ] && ok "reclaim: office reused its projected workspace $NEW_Q_WS with a new pane (real reclaim, not flat)" || fail "reclaim: office did not reclaim (ws $OLD_Q_WS->$NEW_Q_WS pane $OLD_Q_PANE->$NEW_Q_PANE)"
report qmoff Quartermaster "reclaim"
report wk1 fm-wk1 "reclaim"

echo "== S3 legacy journal: office tab and journal carry fm-qmoff from before the change; reclaim migrates"
J="$OFF/state/qmoff.herdr-presentation"; T=$(meta "$OFF/state/qmoff.meta" herdr_tab_id)
lab tab rename "$T" fm-qmoff >/dev/null || fail "could not rename tab to legacy label"
sed -i 's/^task_label=.*/task_label=fm-qmoff/' "$J"
echo "  seeded legacy: tab_label='$(tab_label "$T")' journal_task_label='$(jfield "$J" task_label)'"
OLD_Q_WS=$(meta "$OFF/state/qmoff.meta" herdr_workspace_id)
restart_lab
spawn qmoff legacy || fail "legacy reclaim failed: $(cat "$TMP_ROOT/qmoff.legacy.err")"
[ "$(meta "$OFF/state/qmoff.meta" herdr_workspace_id)" = "$OLD_Q_WS" ] && ok "legacy: reclaimed the same projected workspace" || fail "legacy: did not reclaim same workspace"
report qmoff Quartermaster "legacy-migrate"

echo "== S4 adversarial: a worker journal forged with the office role label must not be honoured"
J2="$OFF/state/wk1.herdr-presentation"; T2=$(meta "$OFF/state/wk1.meta" herdr_tab_id); W2=$(meta "$OFF/state/wk1.meta" herdr_workspace_id)
sed -i 's/^task_label=.*/task_label=Quartermaster/' "$J2"
TABS_BEFORE=$(lab tab list --workspace "$W2" | jq -c '[.result.tabs[]?|{tab_id,label}]')
restart_lab
spawn wk1 forged; FRC=$?
TABS_AFTER=$(lab tab list --workspace "$W2" | jq -c '[.result.tabs[]?|{tab_id,label}]')
ALL_LABELS=$(lab workspace list | jq -r '.result.workspaces[].workspace_id' | while read -r w; do lab tab list --workspace "$w" | jq -r '.result.tabs[]?.label'; done | sort | tr '\n' ',')
echo "  rc=$FRC tabs before=$TABS_BEFORE after=$TABS_AFTER all_tab_labels=$ALL_LABELS"
if [ "$FRC" -ne 0 ] && grep -q 'malformed herdr presentation journal for wk1' "$TMP_ROOT/wk1.forged.err" && [ "$TABS_BEFORE" = "$TABS_AFTER" ] \
   && [ "$(printf '%s' "$ALL_LABELS" | grep -o 'Quartermaster,' | wc -l)" -le 1 ]; then
  ok "adversarial: forged worker journal refused as malformed; no tab was created or relabelled with the role name"
else fail "adversarial: forged journal was not refused cleanly"; fi
echo "RESULT rc=$RC"
exit $RC
