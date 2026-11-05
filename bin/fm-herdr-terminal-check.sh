#!/usr/bin/env bash
# Keep one bare "Terminal" Herdr workspace on this machine and flag agents that
# share a workspace, tab or pane with something else.
#
# Usage: fm-herdr-terminal-check.sh
#
# Runs at locked session start (bin/fm-session-start.sh, BOOTSTRAP section) and
# prints one line per finding; a healthy machine prints nothing. Always exits 0.
#
# Terminal workspace (the captain's own scratch shell, never used by an agent):
#   - none labelled exactly "Terminal": create one, a bare shell at $HOME with
#     one tab and one pane, nothing run in it, focus left where it is;
#   - exactly one: leave it alone, and report it only if it holds an agent or
#     more than one tab or pane;
#   - several: report them and change nothing.
# Only the primary home does this: a home carrying .fm-secondmate-home (every
# secondmate and office) and a home whose backend is not herdr print nothing.
#
# Agent placement: every agent Herdr itself recognizes (`herdr agent list`) must
# sit alone in its own workspace, in its only tab and pane. An agent that shares
# a workspace with another agent, or whose workspace has an extra tab or pane,
# gets one finding line naming its pane and the reason.
#
# This script never closes, moves, kills or renames a workspace, tab, pane or
# process. It works on the session fm_backend_herdr_session names (HERDR_SESSION,
# else Herdr's default) and never starts a Herdr server.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_TERMINAL_LABEL=Terminal

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr

fm_herdr_terminal_note() { printf 'herdr-terminal: %s\n' "$*"; }

fm_herdr_terminal_check() {
  local session workspaces agents terminal_ids count created
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] || return 0
  [ "$(fm_backend_name 2>/dev/null)" = herdr ] || return 0
  command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  session=$(fm_backend_herdr_session)
  workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 0
  printf '%s' "$workspaces" | jq -e '.result.workspaces | type == "array"' >/dev/null 2>&1 || return 0

  terminal_ids=$(printf '%s' "$workspaces" | jq -r --arg label "$FM_TERMINAL_LABEL" \
    '.result.workspaces[] | select(.label == $label) | .workspace_id')
  count=$(printf '%s\n' "$terminal_ids" | awk 'NF { n++ } END { print n+0 }')
  case "$count" in
    0)
      if created=$(fm_backend_herdr_cli "$session" workspace create \
          --cwd "$HOME" --label "$FM_TERMINAL_LABEL" --no-focus 2>/dev/null) \
        && created=$(printf '%s' "$created" | jq -er '.result.workspace.workspace_id' 2>/dev/null); then
        fm_herdr_terminal_note "created the '$FM_TERMINAL_LABEL' workspace $created (bare shell at \$HOME, the captain's)"
      else
        fm_herdr_terminal_note "no '$FM_TERMINAL_LABEL' workspace and creating one failed"
      fi
      ;;
    1)
      printf '%s' "$workspaces" | jq -r --arg label "$FM_TERMINAL_LABEL" '
        .result.workspaces[] | select(.label == $label and (.tab_count != 1 or .pane_count != 1))
        | "herdr-terminal: the \($label) workspace \(.workspace_id) has \(.tab_count) tabs and \(.pane_count) panes; it should be one bare pane, nothing was changed"'
      ;;
    *)
      fm_herdr_terminal_note "$count workspaces are labelled '$FM_TERMINAL_LABEL' ($(printf '%s' "$terminal_ids" | paste -sd, -)); changed nothing, the captain keeps one"
      ;;
  esac

  agents=$(fm_backend_herdr_cli "$session" agent list 2>/dev/null) || return 0
  printf '%s' "$agents" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1 || return 0
  jq -rn --argjson ws "$workspaces" --argjson ag "$agents" --arg terminal "$FM_TERMINAL_LABEL" '
    ($ws.result.workspaces | map({key: .workspace_id, value: .}) | from_entries) as $w
    | ($ag.result.agents | group_by(.workspace_id) | map({key: .[0].workspace_id, value: length}) | from_entries) as $n
    | $ag.result.agents[]
    | . as $a
    | ($w[$a.workspace_id] // {}) as $space
    | [ (if ($n[$a.workspace_id] // 1) > 1 then "shares workspace with \(($n[$a.workspace_id]) - 1) other agent(s)" else empty end),
        (if ($space.tab_count // 1) > 1 then "its workspace has \($space.tab_count) tabs" else empty end),
        (if ($space.pane_count // 1) > 1 then "its workspace has \($space.pane_count) panes" else empty end),
        (if $space.label == $terminal then "it sits in the \($terminal) workspace" else empty end) ]
    | select(length > 0)
    | "herdr-terminal: agent \($a.agent // "unknown") in pane \($a.pane_id) (workspace \($space.label // $a.workspace_id)): \(join("; ")); every agent runs alone in its own workspace, nothing was moved"
  ' 2>/dev/null
  return 0
}

if [ "${FM_HERDR_TERMINAL_CHECK_SOURCE_ONLY:-0}" != 1 ]; then
  fm_herdr_terminal_check
  exit 0
fi
