#!/usr/bin/env bash
# Real-Herdr E2E for bin/fm-herdr-terminal-check.sh. Every Herdr call goes
# through one guarded named non-default lab; teardown verifies the default
# fleet session is unchanged. Agents are registered with `pane report-agent`
# (Herdr's own agent API), so no model is ever launched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-terminal-check-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config"
printf '%s\n' herdr > "$HOME_DIR/config/backend"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name herdr-terminal-chk)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# The lab helper is the only CLI transport: strip the adapter's trailing
# --session pair and delegate to `helper run`, refusing any other session flag.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
check() {
  FM_HOME="${CHECK_HOME:-$HOME_DIR}" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
    PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$ROOT/bin/fm-herdr-terminal-check.sh"
}
terminals() { lab workspace list | jq '[.result.workspaces[] | select(.label == "Terminal")] | length'; }
snapshot() { lab workspace list | jq -S -c '[.result.workspaces[] | {workspace_id, label, tab_count, pane_count}]'; }
new_workspace() { # <label> -> prints "<workspace> <pane>"
  lab workspace create --cwd "$HOME_DIR" --label "$1" --no-focus \
    | jq -r '"\(.result.workspace.workspace_id) \(.result.root_pane.pane_id)"'
}
register_agent() { # <pane> <name>
  lab pane report-agent "$1" --source fm-terminal-check-test --agent claude --state idle >/dev/null \
    || fail "could not register a fixture agent in $1"
  lab pane rename "$1" "$2" >/dev/null 2>&1 || true
}

ANCHOR=$(new_workspace captain-anchor)

# 1. Missing Terminal is created: one workspace, one tab, one pane, no agent.
[ "$(terminals)" = 0 ] || fail 'fixture lab unexpectedly starts with a Terminal workspace'
OUT=$(check) || fail 'check failed with no Terminal'
[ "$(terminals)" = 1 ] || fail 'missing Terminal workspace was not created exactly once'
case "$OUT" in *"created the 'Terminal' workspace"*) ;; *) fail "creation was not reported: $OUT" ;; esac
lab workspace list | jq -e '.result.workspaces[] | select(.label == "Terminal") | .tab_count == 1 and .pane_count == 1' >/dev/null \
  || fail 'created Terminal is not one tab and one pane'
[ "$(lab agent list | jq '.result.agents | length')" = 0 ] || fail 'Terminal workspace holds an agent'
pass 'missing Terminal workspace is created as one bare tab and pane'

# 2. An existing Terminal is left alone; the run is silent and idempotent.
BEFORE=$(snapshot)
OUT=$(check) || fail 'check failed with a Terminal present'
[ -z "$OUT" ] || fail "healthy machine was not silent: $OUT"
[ "$(snapshot)" = "$BEFORE" ] || fail 'existing Terminal run changed the workspaces'
pass 'existing Terminal workspace is left alone and the check is silent'

# 3. A secondmate or office home never creates or reports anything.
lab workspace list | jq -r '.result.workspaces[] | select(.label == "Terminal") | .workspace_id' \
  | while read -r id; do lab workspace rename "$id" Renamed >/dev/null; done
mkdir -p "$TMP_ROOT/mate/state" "$TMP_ROOT/mate/config"
printf '%s\n' herdr > "$TMP_ROOT/mate/config/backend"
printf '%s\n' mate > "$TMP_ROOT/mate/.fm-secondmate-home"
OUT=$(CHECK_HOME="$TMP_ROOT/mate" check) || fail 'secondmate check failed'
[ -z "$OUT" ] && [ "$(terminals)" = 0 ] || fail 'secondmate home created or reported a Terminal'
pass 'a secondmate home does not touch the Terminal workspace'
lab workspace list | jq -r '.result.workspaces[] | select(.label == "Renamed") | .workspace_id' \
  | while read -r id; do lab workspace rename "$id" Terminal >/dev/null; done

# 4. Two Terminals are reported, nothing is changed.
read -r EXTRA _ <<< "$(new_workspace Terminal)"
BEFORE=$(snapshot)
OUT=$(check) || fail 'check failed with two Terminals'
case "$OUT" in *"2 workspaces are labelled 'Terminal'"*"changed nothing"*) ;; *) fail "duplicate Terminals not reported: $OUT" ;; esac
[ "$(snapshot)" = "$BEFORE" ] || fail 'duplicate Terminals were changed'
lab workspace close "$EXTRA" >/dev/null || fail 'could not remove the fixture extra Terminal'
pass 'two Terminal workspaces are reported and left untouched'

# 5. A lone agent in its own workspace is fine; two in one workspace, or an
# agent beside an extra tab or pane, are flagged and nothing is closed.
read -r WS_A PANE_A <<< "$(new_workspace solo)"
register_agent "$PANE_A" solo
OUT=$(check) || fail 'check failed with a lone agent'
[ -z "$OUT" ] || fail "a lone agent was flagged: $OUT"
lab pane split "$PANE_A" --direction down --cwd "$HOME_DIR" --no-focus >/dev/null || fail 'could not split fixture pane'
BEFORE=$(snapshot)
OUT=$(check) || fail 'check failed with an agent beside an extra pane'
case "$OUT" in *"pane $PANE_A"*"2 panes"*) ;; *) fail "agent beside an extra pane not flagged: $OUT" ;; esac
lab tab create --workspace "$WS_A" --cwd "$HOME_DIR" --no-focus >/dev/null || fail 'could not create fixture tab'
OUT=$(check) || fail 'check failed with an agent beside an extra tab'
case "$OUT" in *"pane $PANE_A"*"2 tabs"*) ;; *) fail "agent beside an extra tab not flagged: $OUT" ;; esac
OTHER=$(lab pane list --workspace "$WS_A" | jq -r --arg a "$PANE_A" '[.result.panes[] | select(.pane_id != $a)][0].pane_id')
register_agent "$OTHER" second
OUT=$(check) || fail 'check failed with two agents in one workspace'
case "$OUT" in *"pane $PANE_A"*"shares workspace"*) ;; *) fail "shared workspace not flagged for first agent: $OUT" ;; esac
case "$OUT" in *"pane $OTHER"*"shares workspace"*) ;; *) fail "shared workspace not flagged for second agent: $OUT" ;; esac
[ "$(printf '%s\n' "$OUT" | grep -c 'herdr-terminal: agent')" = 2 ] || fail "expected one line per agent: $OUT"
pass 'agents sharing a workspace, tab or pane are flagged one line each'

# 6. Nothing was ever closed or renamed by the check itself.
AFTER=$(lab workspace list | jq '[.result.workspaces[]] | length')
[ "$AFTER" -ge 3 ] || fail 'a workspace disappeared'
for pane in "$PANE_A" "$OTHER"; do lab pane get "$pane" >/dev/null || fail 'a flagged pane was closed'; done
lab workspace get "$(printf '%s' "$ANCHOR" | cut -d' ' -f1)" >/dev/null || fail 'the anchor workspace was touched'
pass 'the check never closed, moved or renamed anything'
