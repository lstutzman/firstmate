#!/usr/bin/env bash
# fm-ready-branch.sh - record that a ship finished as a pushed, verified ready
# branch with no PR, so it frees its project-capacity place like a recorded PR.
#
# Usage: FM_HOME=<home> fm-ready-branch.sh <task-id> <branch>
#        FM_HOME=<home> fm-ready-branch.sh list
#
# A worker whose CI slots check (bin/fm-pr-drain.py gate) held its PR opening
# reports `done: branch <branch> pushed, no PR (CI slots)`; firstmate then runs
# this to append ready_branch=<branch> to state/<task-id>.meta, which
# bin/fm-project-capacity-lib.sh counts the way it counts pr=. It changes nothing
# when the record already has a ready_branch= line, and exits 1 when the task has
# no record. The branch's PR opens later through /no-mistakes, which validates it
# (.agents/skills/ship-landing).
#
# list prints `<task-id> <branch> <project>` for each task record in this home's
# state that has a ready_branch= line and no pr= line: the parked branches still
# waiting for a CI slot.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ID=${1:?usage: fm-ready-branch.sh <task-id> <branch> | list}
if [ "$ID" = list ] && [ "$#" -eq 1 ]; then
  for META in "$STATE"/*.meta; do
    [ -f "$META" ] && [ ! -L "$META" ] || continue
    BRANCH=$(sed -n 's/^ready_branch=//p' "$META" | head -n 1)
    [ -n "$BRANCH" ] || continue
    if grep -q '^pr=.' "$META"; then continue; fi
    printf '%s %s %s\n' "$(basename "$META" .meta)" "$BRANCH" "$(sed -n 's/^project=//p' "$META" | head -n 1)"
  done
  exit 0
fi
BRANCH=${2:?usage: fm-ready-branch.sh <task-id> <branch>}
case "$ID" in */* | '' | .*) echo "error: bad task id '$ID'" >&2; exit 1 ;; esac
case "$BRANCH" in *[[:space:]]* | '') echo "error: bad branch '$BRANCH'" >&2; exit 1 ;; esac
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: task $ID has no record at $META" >&2; exit 1; }
if grep -q '^ready_branch=' "$META"; then
  echo "task $ID already records its ready branch"
  exit 0
fi
printf 'ready_branch=%s\n' "$BRANCH" >> "$META"
echo "recorded ready branch $BRANCH for task $ID"
