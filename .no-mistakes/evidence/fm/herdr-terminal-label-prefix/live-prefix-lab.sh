#!/usr/bin/env bash
# Live real-Herdr lab: a "[5] Terminal" labelled workspace is recognised by the
# changed check (no duplicate) and duplicated by the base-commit check.
set -u
ROOT=$1; BASE_ROOT=$2
HELPER=$ROOT/bin/fm-herdr-lab.sh
REAL_HERDR=$(command -v herdr); ORIG=$PATH
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-term-prefix.XXXXXX")
mkdir -p "$T/fakebin" "$T/home/state" "$T/home/config"; echo herdr > "$T/home/config/backend"
S=$("$HELPER" name term-prefix)
export HERDR_LAB_HELPER=$HELPER HERDR_LAB_SESSION=$S REAL_HERDR HERDR_ORIGINAL_PATH=$ORIG
trap 'env PATH="$ORIG" "$HELPER" teardown "$S"; echo "teardown exit=$?"; /usr/bin/trash "$T"' EXIT
"$HELPER" provision "$S" || exit 1
# Reuse the e2e test's lab-only herdr shim (routes every call through `helper run`).
sed -n '/^cat > "\$FAKEBIN\/herdr" <<.SH.$/,/^SH$/p' "$ROOT/tests/fm-herdr-terminal-check-e2e.test.sh" | sed '1d;$d' > "$T/fakebin/herdr"
chmod +x "$T/fakebin/herdr"
lab() { env PATH="$ORIG" "$HELPER" run "$S" "$@"; }
check() { FM_HOME="$T/home" FM_BACKEND=herdr HERDR_SESSION="$S" FM_HERDR_TERMINAL_LOCK="$T/lock" PATH="$T/fakebin:$ORIG" "$1/bin/fm-herdr-terminal-check.sh"; }
show() { lab workspace list | jq -c '[.result.workspaces[] | {workspace_id,label,tab_count,pane_count}]'; }
lab workspace create --cwd "$T/home" --label anchor --no-focus >/dev/null
read -r WS PANE <<<"$(lab workspace create --cwd "$T/home" --label '[5] Terminal' --no-focus | jq -r '"\(.result.workspace.workspace_id) \(.result.root_pane.pane_id)"')"
echo "== lab $S workspaces before (real herdr $(herdr --version)):"; show
echo "== scenario A: changed check, run twice, with a '[5] Terminal' present"
O1=$(check "$ROOT"); O2=$(check "$ROOT"); echo "out1=[$O1] out2=[$O2]"; show
echo "== scenario B: agent in the '[5] Terminal' is flagged by the changed check"
lab pane report-agent "$PANE" --source fm-term-prefix --agent claude --state idle >/dev/null
O3=$(check "$ROOT"); echo "out=[$O3]"; show
echo "== scenario C (baseline): base-commit check against the same lab"
O4=$(check "$BASE_ROOT"); echo "out=[$O4]"; show
