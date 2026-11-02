#!/usr/bin/env bash
# fm-worktree-assert.sh - refuse unless the current directory is the worktree
# a task's record names.
#
# Usage: fm-worktree-assert.sh <task-id>
#
# A worker session restored after a restart (a harness --resume, a restored
# pane) can start in whatever directory the restore chose, away from the copy
# holding its work. bin/fm-spawn.sh already enters and verifies the recorded
# worktree on every launch and relaunch; this is the same check for a session
# firstmate did not launch. It reads `worktree=` from state/<id>.meta, resolves
# both paths with `pwd -P`, and exits 0 when the current directory is that
# worktree or inside it. Otherwise it exits 1 naming the exact directory the
# worker must `cd` into, and exits 2 for a missing task record or a record with
# no worktree. A secondmate's worktree= is its home, so the same check applies.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

[ "$#" -eq 1 ] && [ -n "$1" ] || { echo "usage: fm-worktree-assert.sh <task-id>" >&2; exit 2; }
id=$1
case "$id" in
  */*|.*|*[!A-Za-z0-9._-]*) echo "error: '$id' is not a task id" >&2; exit 2 ;;
esac
meta="$STATE/$id.meta"
[ -f "$meta" ] || { echo "error: no task record $meta" >&2; exit 2; }
wt=$(fm_meta_get "$meta" worktree)
[ -n "$wt" ] || { echo "error: task $id's record names no worktree" >&2; exit 2; }
want=$(cd "$wt" 2>/dev/null && pwd -P) || { echo "error: task $id's recorded worktree '$wt' is missing" >&2; exit 2; }
here=$(pwd -P)
case "$here/" in
  "$want"/*) exit 0 ;;
esac
echo "error: this session is in '$here', not task $id's worktree; refusing to continue outside the copy holding its work. cd -- '$want'" >&2
exit 1
