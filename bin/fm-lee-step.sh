#!/usr/bin/env bash
# fm-lee-step.sh - render a command the captain must run by hand, host-aware
# and with the reason an agent cannot run it.
#
# Usage: fm-lee-step.sh --cause <sudo|credential|policy|tool|physical> [--no-recipe <why>] <host> <script> [arg...]
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
#
# A step with --cause sudo is refused unless --no-recipe <why> states that no
# fleet-admin recipe covers it: root work goes through `sudo -n fleet-admin
# <recipe>`, which the agent runs itself (fleet rules section 9), and a new root
# ability ships as a recipe in agent-config/fleet-admin/ of the skills repo, so
# the captain is never handed a sudo step a recipe could run. Name the recipe
# gap in <why> (for example "no recipe installs the pam module"); the reason is
# printed on the step so it can be removed later.
#
# With config/lee-step-host unset the reader's machine is unknown, so the step is
# an ssh line even for the host the session runs on, which stalls for a captain
# already there; a note on stderr says so and names the file that fixes it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

usage() {
  echo "usage: fm-lee-step.sh --cause <sudo|credential|policy|tool|physical> [--no-recipe <why>] <host> <script> [arg...]" >&2
  exit 2
}

[ "${1:-}" = --cause ] && [ "$#" -ge 4 ] || usage
cause=$2
shift 2
no_recipe=''
if [ "${1:-}" = --no-recipe ]; then
  [ "$#" -ge 4 ] || usage
  no_recipe=$2
  shift 2
  [ -n "${no_recipe//[[:space:]]/}" ] || { echo "error: --no-recipe needs the reason no fleet-admin recipe covers this step" >&2; exit 2; }
fi
[ "$#" -ge 2 ] || usage
host=$1
shift
case "$cause" in
  sudo|credential|policy|tool|physical) ;;
  *) echo "error: --cause must be one of sudo, credential, policy, tool, physical (got '$cause'): say why no agent can run this step" >&2; exit 2 ;;
esac
if [ "$cause" = sudo ] && [ -z "$no_recipe" ]; then
  echo "error: a sudo step is refused: run the root work yourself with 'sudo -n fleet-admin <recipe>' (fleet rules section 9); if no recipe covers it, propose one (agent-config/fleet-admin/ in the skills repo) or rerun with --no-recipe '<why no recipe covers it>'" >&2
  exit 2
fi
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

why_line=''
[ -z "$no_recipe" ] || why_line=$(printf '\nNo fleet-admin recipe: %s' "$no_recipe")
[ -n "$own" ] || echo "note: config/lee-step-host is unset, so this step is an ssh line even if your session is on $host; set it to the machine the captain reads Lee steps on (docs/configuration.md)" >&2

if [ -n "$own" ] && [ "$(lower "${own%%.*}")" = "${target%%.*}" ]; then
  printf 'Lee step [cause=%s], run on %s (your session is already there):\n%s%s\n' "$cause" "$host" "$cmd" "$why_line"
else
  printf 'Lee step [cause=%s], run from any machine:\nssh -t %s %s%s\n' "$cause" "$host" "'${cmd//\'/\'\\\'\'}'" "$why_line"
fi
