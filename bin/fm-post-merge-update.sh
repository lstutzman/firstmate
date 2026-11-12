#!/usr/bin/env bash
# Fast-forward every firstmate home after a firstmate merge is recorded.
#
# bin/fm-merge-outcome-lib.sh calls `launch` once per newly recorded merge
# (its notified marker already deduplicates a merge seen by both bin/fm-pr-merge.sh
# and the merge poll). `launch` returns at once; it only starts `run` detached.
#
#   fm-post-merge-update.sh launch <home> <state> <task-id>
#   fm-post-merge-update.sh run <home> <state> <label>
#
# launch is a silent no-op unless ALL hold:
#   - <home> is the primary home: no .fm-secondmate-home or .fm-office marker;
#   - the task's recorded project= (state/<id>.meta) shares firstmate's own
#     repository lineage (fm_role_self_repo), so a merge in any other project
#     does nothing;
#   - the home has not opted out with an empty config/no-post-merge-update file
#     (docs/configuration.md "Post-merge update").
# run executes bin/fm-update.sh, the one fast-forward-only implementation, under
# a per-home lock so back-to-back merges serialize. fm-update.sh moves homes and
# code roots together under its own guards (clean tree, ancestry, branch,
# self-update-source) and never forces, stashes, or restarts anything; this
# wrapper discards its restart/nudge/reread summary, which stays with
# /updatefirstmate. Success is silent. A non-zero exit or any skipped home is
# reported as ONE `check:` wake in the primary home, keyed by <label>.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() { echo "usage: fm-post-merge-update.sh launch|run <home> <state> <task-id|label>" >&2; }

cmd=${1:-}
[ $# -eq 4 ] || { usage; exit 2; }
home=$2
state=$3
arg=$4

case "$cmd" in
  launch)
    # shellcheck source=bin/fm-role-lib.sh
    . "$SCRIPT_DIR/fm-role-lib.sh"
    [ ! -e "$home/.fm-secondmate-home" ] && [ ! -e "$home/.fm-office" ] || exit 0
    [ ! -e "${FM_CONFIG_OVERRIDE:-$home/config}/no-post-merge-update" ] || exit 0
    meta="$state/$arg.meta"
    [ -f "$meta" ] || exit 0
    proj=$(sed -n 's/^project=//p' "$meta" | tail -1)
    [ -n "$proj" ] && [ -d "$proj" ] || exit 0
    fm_role_self_repo "$proj" "$FM_ROOT" || exit 0
    label="post-merge-update-$arg-$(date +%s)"
    ( nohup "$SCRIPT_DIR/fm-post-merge-update.sh" run "$home" "$state" "$label" \
        >/dev/null 2>&1 </dev/null & )
    exit 0
    ;;
  run)
    label=$arg
    out=$(mktemp "${TMPDIR:-/tmp}/fm-post-merge-update.XXXXXX") || exit 1
    # shellcheck disable=SC2034 # Sourced wake helpers consume STATE.
    STATE=$state
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    lock="$state/.post-merge-update.lock"
    fm_lock_acquire_wait "$lock" || { /usr/bin/trash "$out" 2>/dev/null; exit 1; }
    rc=0
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$SCRIPT_DIR/fm-update.sh" >"$out" 2>&1 </dev/null || rc=$?
    fm_lock_release "$lock"
    problems=$(grep -E 'skipped|^error:' "$out" | head -3 | tr '\n' ';' | cut -c1-400)
    if [ "$rc" -ne 0 ] || [ -n "$problems" ]; then
      [ -n "$problems" ] || problems="fm-update.sh exited $rc"
      fm_wake_append check "$label" \
        "check: post-merge update needs a look (nothing forced): $problems" || true
    fi
    /usr/bin/trash "$out" 2>/dev/null || true
    exit 0
    ;;
  *) usage; exit 2 ;;
esac
