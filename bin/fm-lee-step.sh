#!/usr/bin/env bash
# fm-lee-step.sh - render a command the captain must run by hand, host-aware
# and with the reason an agent cannot run it.
#
# Usage: fm-lee-step.sh --cause <sudo|credential|policy|tool|physical> <host> <script> [arg...]
#
# Prints two lines: a label line naming the cause and the host, then the
# command to paste. The command is `bash <script> [arg...]` only when
# config/lee-step-host is set and names <host>, because ssh to the machine one
# is already on has no key and the step stalls; otherwise it is
# `ssh -t <host> 'bash <script> [arg...]'`, which works from any machine.
#
# config/lee-step-host's first non-blank line names the machine the captain
# reads Lee steps on (main's session), never the machine this script runs on.
# A <host> of the form user@name is compared by its name, case-insensitively.
#
# Every step must state --cause, the reason no agent can do it: sudo (needs
# root), credential (a login, token or secret the agent lacks), policy (a rule
# or approval reserved to the captain), tool (a tool is missing or broken) or
# physical (a person at a machine or device). bin/fm-classify-lib.sh
# status_line_cause owns that vocabulary, and a status line asking for the step
# carries the same value as its [cause=...] tag.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

usage() {
  echo "usage: fm-lee-step.sh --cause <sudo|credential|policy|tool|physical> <host> <script> [arg...]" >&2
  exit 2
}

[ "${1:-}" = --cause ] && [ "$#" -ge 4 ] || usage
cause=$2
host=$3
shift 3
case "$cause" in
  sudo|credential|policy|tool|physical) ;;
  *) echo "error: --cause must be one of sudo, credential, policy, tool, physical (got '$cause'): say why no agent can run this step" >&2; exit 2 ;;
esac
case "$host" in
  ''|-*|*[!A-Za-z0-9@._-]*) echo "error: '$host' is not a host name" >&2; exit 2 ;;
esac

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

own=$(fm_config_line "$CONFIG" lee-step-host)
target=$(lower "${host#*@}")

cmd='bash'
for word in "$@"; do
  cmd+=" $(printf '%q' "$word")"
done

if [ -n "$own" ] && [ "$(lower "${own%%.*}")" = "${target%%.*}" ]; then
  printf 'Lee step [cause=%s], run on %s (your session is already there):\n%s\n' "$cause" "$host" "$cmd"
else
  printf 'Lee step [cause=%s], run from any machine:\nssh -t %s %s\n' "$cause" "$host" "'${cmd//\'/\'\\\'\'}'"
fi
