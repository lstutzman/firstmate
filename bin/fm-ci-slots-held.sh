#!/usr/bin/env bash
# fm-ci-slots-held.sh - which of a project's ready open PRs wait for the
# captain's merge word, so the CI slots gate and the drain leave them out of their slot counts (the
# open-PR cap counts them again).
#
# Usage: fm-ci-slots-held.sh <project-dir> < <newline-separated ready open PR URLs>
#
# Prints the held PR URLs, one per line. bin/fm-project-capacity-lib.sh's fm_ci_slots_held owns
# the signal (a task record in a local home whose yolo is not on, or whose backlog
# row is held for the captain); bin/fm-pr-drain.py gate and state are the callers. A PR no
# local record shows to be waiting is not counted as held here; a PR another home
# holds carries the GitHub label HELD_LABEL, which bin/fm-pr-drain.py reads itself. Exits 1 with a message
# on stderr when the task records cannot be read, which the caller reads as no
# held PR.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

PROJECT=${1:?usage: fm-ci-slots-held.sh <project-dir> < <ready open PR URLs>}
URLS=$(cat)

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"

PROJECT_ABS=$(cd "$PROJECT" 2>/dev/null && pwd -P) || {
  echo "error: project directory $PROJECT cannot be read" >&2
  exit 1
}
LOCK=$(fm_treehouse_project_lock_path "$PROJECT_ABS" 2>/dev/null) || {
  echo "error: the project identity of $PROJECT_ABS cannot be resolved" >&2
  exit 1
}
fm_ci_slots_held "$LOCK" "$PROJECT_ABS" "$STATE" "$CONFIG" "$DATA" "$URLS" || {
  echo "error: $FM_PROJECT_CAPACITY_ERROR" >&2
  exit 1
}
printf '%s' "$FM_CI_SLOTS_HELD_URLS"
