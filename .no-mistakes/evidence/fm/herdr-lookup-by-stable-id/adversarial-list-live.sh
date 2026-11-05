#!/usr/bin/env bash
# Adversarial live check: list_live must find an office by its record, not by
# an fm-<id> title, and must reject a record whose pane no longer sits in its
# recorded tab.
set -u
ROOT=$1
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
fail() { printf 'not ok - %s\n' "$1"; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-adv.XXXXXX")
SESSION="fm-lab-herdr-adv-$$"; export HERDR_SESSION="$SESSION"
cleanup_all() { herdr_safe_stop_and_delete "$SESSION"; find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null; rm -rf "$TMP_ROOT"; fm_test_cleanup; }
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "lab prepare"
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr || fail source
PRIMARY_HOME="$TMP_ROOT/primary-home"; OFFICE_HOME="$TMP_ROOT/office-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data" "$PRIMARY_HOME/config"
printf 'off\n' > "$PRIMARY_HOME/config/herdr-presentation-spaces"
mkdir -p "$OFFICE_HOME/state" "$OFFICE_HOME/data" "$OFFICE_HOME/config" "$OFFICE_HOME/projects" "$OFFICE_HOME/bin"
printf 'off\n' > "$OFFICE_HOME/config/herdr-presentation-spaces"
printf '# placeholder\n' > "$OFFICE_HOME/AGENTS.md"
printf 'advqm\n' > "$OFFICE_HOME/.fm-secondmate-home"; printf 'advqm\n' > "$OFFICE_HOME/.fm-office"
printf '# Office authority\nnothing.\n' > "$OFFICE_HOME/data/charter.md"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PRIMARY_HOME" > "$OFFICE_HOME/.fm-secondmate-parent"
printf -- '- advqm - Run the fleet. (role: navigator; added 2026-11-05)\n' > "$PRIMARY_HOME/data/offices.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$OFFICE_HOME/.gitignore"
git -C "$OFFICE_HOME" init -q -b main
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" advqm "$OFFICE_HOME" "sh -c 'echo office-ok'" --secondmate --backend herdr >"$TMP_ROOT/o" 2>&1 \
  || fail "office spawn: $(cat "$TMP_ROOT/o")"
META="$PRIMARY_HOME/state/advqm.meta"
QM_PANE=$(sed -n 's/^herdr_pane_id=//p' "$META"); QM_TAB=$(sed -n 's/^herdr_tab_id=//p' "$META"); QM_WS=$(sed -n 's/^herdr_workspace_id=//p' "$META")
LABEL=$(herdr tab get "$QM_TAB" --session "$SESSION" | jq -r .result.tab.label)
echo "office advqm: pane=$QM_PANE tab=$QM_TAB label=$LABEL"
[ "$LABEL" = Navigator ] || fail "office tab label is '$LABEL', expected Navigator"
pass "office tab shows bare role name Navigator"
# Decoy: a tab in the primary's workspace titled fm-advqm that no record names.
PWS=$(FM_HOME="$PRIMARY_HOME" fm_backend_herdr_workspace_find "$SESSION")
[ -n "$PWS" ] || PWS=$QM_WS
DECOY=$(herdr tab create --workspace "$PWS" --cwd "$TMP_ROOT" --label fm-advqm --no-focus --session "$SESSION")
DECOY_TAB=$(printf '%s' "$DECOY" | jq -r '.result.tab.tab_id // .result.tab_id // empty')
DECOY_PANE=$(printf '%s' "$DECOY" | jq -r '.result.root_pane.pane_id // .result.pane.pane_id // .result.pane_id // empty')
echo "decoy tab=$DECOY_TAB pane=$DECOY_PANE (workspace $PWS)"
[ -n "$DECOY_TAB" ] || fail "decoy create: $DECOY"
LIVE=$(FM_HOME="$PRIMARY_HOME" fm_backend_herdr_list_live "$SESSION"); echo "list_live with decoy:"; printf '%s\n' "$LIVE"
[ "$(printf '%s\n' "$LIVE" | grep -c $'\tfm-advqm$')" = 1 ] || fail "expected exactly one fm-advqm line"
printf '%s\n' "$LIVE" | grep -qx "$SESSION:$QM_PANE"$'\t'"fm-advqm" || fail "office not found by its recorded pane"
pass "list_live finds the office by its recorded pane and ignores a decoy tab titled fm-advqm"
# Stale record: a record whose pane is the office pane but whose tab is the decoy's.
sed "s/^herdr_tab_id=.*/herdr_tab_id=$DECOY_TAB/" "$META" > "$PRIMARY_HOME/state/ghost.meta"
LIVE=$(FM_HOME="$PRIMARY_HOME" fm_backend_herdr_list_live "$SESSION"); echo "list_live with mismatched ghost record:"; printf '%s\n' "$LIVE"
printf '%s\n' "$LIVE" | grep -q $'\tfm-ghost$' && fail "a record whose pane is not in its recorded tab was listed"
pass "list_live rejects a record whose recorded pane is no longer in its recorded tab"
rm -f "$PRIMARY_HOME/state/ghost.meta"
# Record for another session must not be listed in this one.
sed "s/^herdr_session=.*/herdr_session=fm-lab-other/" "$META" > "$PRIMARY_HOME/state/other.meta"
LIVE=$(FM_HOME="$PRIMARY_HOME" fm_backend_herdr_list_live "$SESSION")
printf '%s\n' "$LIVE" | grep -q $'\tfm-other$' && fail "a record naming another session was listed"
pass "list_live ignores a record naming another Herdr session"
# Empty session is refused, never falls through to default.
out=$(FM_HOME="$PRIMARY_HOME" fm_backend_herdr_list_live "" 2>&1); rc=$?
echo "list_live '' -> rc=$rc: $out"
[ "$rc" -ne 0 ] || fail "empty session accepted"
pass "list_live refuses an empty session name"
