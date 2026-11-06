#!/usr/bin/env bash
# Keep one bare "Terminal" Herdr workspace on this machine and flag agents that
# share a workspace, tab or pane with something else.
#
# Usage: fm-herdr-terminal-check.sh
#
# Runs at locked session start (bin/fm-session-start.sh, BOOTSTRAP section) in
# every herdr home, primary or secondmate, and prints one line per finding; a
# healthy machine prints nothing. Always exits 0.
#
# Terminal workspace (the captain's own scratch shell, never used by an agent):
#   - none labelled exactly "Terminal": create one, a bare shell at $HOME with
#     one tab and one pane, nothing run in it, focus left where it is;
#   - exactly one: leave it alone, and report it only if it holds an agent or
#     more than one tab or pane;
#   - several: report them and change nothing.
# One machine-wide lock per host and Herdr session (FM_HERDR_TERMINAL_LOCK,
# default under XDG_RUNTIME_DIR or TMPDIR, outside every home) guards this part,
# so exactly one home creates the workspace; a home that finds the lock held
# skips it. A home whose backend is not herdr prints nothing.
#
# Agent placement: every agent Herdr itself recognizes (`herdr agent list`) must
# sit alone in its own workspace. Agents that share a workspace with another
# agent, or sit in the Terminal workspace, are reported on one summary line with
# their count and the first few; extra non-agent tabs or panes are not flagged.
#
# This script never closes, moves, kills or renames a workspace, tab, pane or
# process. It works on the session fm_backend_herdr_session names (HERDR_SESSION,
# else Herdr's default) and never starts a Herdr server.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_TERMINAL_LABEL=Terminal
# Some Herdr versions prefix workspace labels with "[n] "; compare without it.
FM_JQ_NORM='def norm: strings | sub("^\\[[0-9]+\\] "; "");'

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_herdr_terminal_note() { printf 'herdr-terminal: %s\n' "$*"; }

fm_herdr_terminal_lock_path() {  # <session>
  local host
  host=$(uname -n 2>/dev/null | tr -c 'A-Za-z0-9._-' _)
  printf '%s/fm-herdr-terminal.%s.%s.lock' "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}" \
    "${host:-host}" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' _)"
}

fm_herdr_terminal_workspace() {  # <session>
  local session=$1 workspaces terminal_ids count created
  workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 0
  printf '%s' "$workspaces" | jq -e '.result.workspaces | type == "array"' >/dev/null 2>&1 || return 0
  terminal_ids=$(printf '%s' "$workspaces" | jq -r --arg label "$FM_TERMINAL_LABEL" \
    "$FM_JQ_NORM"'.result.workspaces[] | select((.label | norm) == $label) | .workspace_id')
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
      printf '%s' "$workspaces" | jq -r --arg label "$FM_TERMINAL_LABEL" "$FM_JQ_NORM"'
        .result.workspaces[] | select((.label | norm) == $label and (.tab_count != 1 or .pane_count != 1))
        | "herdr-terminal: the \($label) workspace \(.workspace_id) has \(.tab_count) tabs and \(.pane_count) panes; it should be one bare pane, nothing was changed"'
      ;;
    *)
      fm_herdr_terminal_note "$count workspaces are labelled '$FM_TERMINAL_LABEL' ($(printf '%s' "$terminal_ids" | paste -sd, -)); changed nothing, the captain keeps one"
      ;;
  esac
}

fm_herdr_terminal_check() {
  local session lock workspaces agents
  [ "$(fm_backend_name 2>/dev/null)" = herdr ] || return 0
  command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  session=$(fm_backend_herdr_session)
  lock=${FM_HERDR_TERMINAL_LOCK:-$(fm_herdr_terminal_lock_path "$session")}
  if fm_lock_try_acquire "$lock"; then
    fm_herdr_terminal_workspace "$session"
    fm_lock_release "$lock" || true
  fi

  workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 0
  printf '%s' "$workspaces" | jq -e '.result.workspaces | type == "array"' >/dev/null 2>&1 || return 0
  agents=$(fm_backend_herdr_cli "$session" agent list 2>/dev/null) || return 0
  printf '%s' "$agents" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1 || return 0
  jq -rn --argjson ws "$workspaces" --argjson ag "$agents" --arg terminal "$FM_TERMINAL_LABEL" "$FM_JQ_NORM"'
    ($ws.result.workspaces | map({key: .workspace_id, value: (.label | norm)}) | from_entries) as $label
    | ($ag.result.agents | group_by(.workspace_id) | map({key: .[0].workspace_id, value: length}) | from_entries) as $n
    | [ $ag.result.agents[]
        | select($n[.workspace_id] > 1 or $label[.workspace_id] == $terminal)
        | "\(.agent // "unknown") in pane \(.pane_id) (workspace \($label[.workspace_id] // .workspace_id))" ] as $flagged
    | select($flagged | length > 0)
    | "herdr-terminal: \($flagged | length) agent(s) share a workspace with another session: \($flagged[:3] | join(", "))\(if ($flagged | length) > 3 then ", and \(($flagged | length) - 3) more" else "" end); every agent runs alone in its own workspace, nothing was moved"
  ' 2>/dev/null
  return 0
}

if [ "${FM_HERDR_TERMINAL_CHECK_SOURCE_ONLY:-0}" != 1 ]; then
  fm_herdr_terminal_check
  exit 0
fi
