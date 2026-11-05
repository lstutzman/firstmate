#!/usr/bin/env bash
# Adopt an open GitHub pull request that has no task record in this home, so
# bin/fm-pr-merge.sh and bin/fm-teardown.sh can run on it here.
#
# A PR opened by a worker this home did not spawn (another home's ship, a task
# whose record was lost) leaves fm-pr-check.sh and fm-pr-merge.sh refusing with
# "task metadata is unavailable". Hand-writing a record into the merge guard's
# input is unsafe, so this writes the smallest record those scripts accept and
# then registers the PR through bin/fm-pr-check.sh exactly as a ready ship does.
#
# What the consumers read from a task record, and so all this writes:
#   fm-pr-merge.sh  a regular, non-symlink state/<task-id>.meta; spawn_gen=
#                   only when present (absent skips the incarnation check);
#                   project= for the merger= and admission= bindings; yolo= and
#                   office= in an office home only; pr= and pr_head= through
#                   its own merge-time run of fm-pr-check.sh
#   fm-pr-check.sh  kind=, mode=, project=, worktree=; it appends pr_at=, pr=
#                   and pr_head=, which must stay the record's last lines
#   fm-teardown.sh  a non-empty worktree= and project=, and no window= or
#                   spawn_gen=, to clean the record as a windowless leftover
# So the record holds only:
#   worktree=<state>/<task-id>.adopted-no-copy
#                      a path this checks does not exist, so no copy is named
#                      and teardown inspects, resets and returns nothing
#   project=<abs dir>  the registered clone of the PR's repository
#   kind=ship
#   mode=no-mistakes   only a no-mistakes PR's forge head is, by contract, its
#                      named head, and an adopted record has no copy to name
#                      any other head from
#   yolo=<on|off>      exactly as the operator stated it
#   adopted=1          lets fm-pr-check.sh read pr_head= from the forge
#   adopted_at=<epoch> when this record was written
# It never writes window=, an endpoint, branch=, spawn_gen= or office=, so it
# names no live worker or branch, and an office home refuses to merge an adopted
# record, because an office merges only what it spawned. Every merge guard -
# green at the live head, required checks, admission classes, the office record,
# captain holds - still runs unchanged in fm-pr-merge.sh.
#
# Refuses, writing nothing, when:
#   - a record for <task-id> already exists;
#   - the URL is not a GitHub pull request, or the PR is not open;
#   - the project is not registered in data/projects.md, or its origin is not
#     the PR's repository;
#   - --mode is not no-mistakes, or --yolo on is asked for a project whose
#     registered posture is not +yolo.
#   - <state>/<task-id>.adopted-no-copy exists.
# When this home's backlog transitions are automatic, a backlog item <task-id>
# is then reused (moved to In flight) or filed In flight with the PR linked, so
# teardown's close works as for any ship. A refusal from fm-pr-check.sh (a
# draft, a ready gate) removes the record again and keeps that item for a rerun.
#
# Usage: fm-pr-adopt.sh <task-id> <pr-url> --mode no-mistakes --yolo <on|off> [--project <dir>]
#   --project defaults to $FM_HOME/projects/<repository name>.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-role-lib.sh
. "$SCRIPT_DIR/fm-role-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  echo "usage: fm-pr-adopt.sh <task-id> <pr-url> --mode no-mistakes --yolo <on|off> [--project <dir>]" >&2
  exit 2
}
refuse() {
  echo "error: adopt refused: $*" >&2
  exit 1
}

[ "$#" -ge 2 ] || usage
ID=$1
RAW_URL=$2
shift 2
MODE=
YOLO=
PROJ=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || usage; MODE=$2; shift 2 ;;
    --yolo) [ "$#" -ge 2 ] || usage; YOLO=$2; shift 2 ;;
    --project) [ "$#" -ge 2 ] || usage; PROJ=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$MODE" ] && [ -n "$YOLO" ] || usage
fm_task_id_creation_valid "$ID" || refuse "invalid task id '$ID'"
fm_pr_url_parse "$RAW_URL" || refuse "'$RAW_URL' is not a canonical pull request URL"
URL=$FM_PR_URL
[ "$FM_PR_PROVIDER" = github ] || refuse "only a GitHub pull request can be adopted, not a $FM_PR_PROVIDER one"
[ "$MODE" = no-mistakes ] \
  || refuse "--mode must be no-mistakes: an adopted record has no worker copy, so only a PR whose forge head is its named head can be recorded"
case "$YOLO" in on|off) ;; *) refuse "--yolo must be on or off" ;; esac

META="$STATE/$ID.meta"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || refuse "state directory $STATE is unavailable"
{ [ ! -e "$META" ] && [ ! -L "$META" ]; } || refuse "task $ID already has a record at $META"
NO_COPY="$STATE/$ID.adopted-no-copy"
{ [ ! -e "$NO_COPY" ] && [ ! -L "$NO_COPY" ]; } || refuse "$NO_COPY exists, so the record could name a copy"

[ -n "$PROJ" ] || PROJ="$FM_HOME/projects/$FM_PR_REPO"
PROJ=$(cd "$PROJ" 2>/dev/null && pwd -P) || refuse "project directory ${PROJ} does not exist"
PROJ_NAME=${PROJ##*/}
POSTURE_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-pr-adopt.XXXXXX")
POSTURE=$("$SCRIPT_DIR/fm-project-mode.sh" "$PROJ_NAME" 2>"$POSTURE_ERR") || POSTURE=
if [ -z "$POSTURE" ] || grep -q 'not in registry\|no registry at' "$POSTURE_ERR"; then
  rm -f -- "$POSTURE_ERR"
  refuse "project $PROJ_NAME is not registered in $DATA/projects.md"
fi
rm -f -- "$POSTURE_ERR"
[ "$YOLO" = off ] || [ "${POSTURE#* }" = on ] \
  || refuse "--yolo on asked for $PROJ_NAME, whose registered posture is '$POSTURE', not +yolo"

ORIGIN=$(git -C "$PROJ" remote get-url origin 2>/dev/null) || refuse "project $PROJ has no origin remote"
ORIGIN_ID=$(fm_role_remote_identity "$ORIGIN" "$PROJ" nolocal)
PR_ID=$(printf '%s/%s' "$FM_PR_HOST" "$FM_PR_PATH" | tr '[:upper:]' '[:lower:]')
[ "$ORIGIN_ID" = "$PR_ID" ] || refuse "$URL is in $PR_ID, but project $PROJ_NAME's origin is ${ORIGIN_ID:-$ORIGIN}"

command -v gh >/dev/null 2>&1 || refuse "reading the PR needs gh on PATH"
PR_STATE=$(gh pr view "$URL" --json state -q .state 2>/dev/null) || refuse "could not read $URL from GitHub"
[ "$PR_STATE" = OPEN ] || refuse "$URL is ${PR_STATE:-unreadable}, not open"

# The backlog item first, so a later refusal leaves only a reusable item.
if fm_backlog_transition_applies "$CONFIG" "$DATA" ship; then
  fm_backlog_row_probe "$DATA" "$ID" || true
  case "$FM_BACKLOG_ROW_RESULT:$FM_BACKLOG_ROW_STATE" in
    not_found:)
      fm_backlog_mutate "$DATA" add "$ID" "Adopt $URL" --kind ship --repo "$PROJ_NAME" --start --pr "$URL" \
        || refuse "could not file backlog item $ID: $FM_BACKLOG_TRANSITION_ERROR" ;;
    found:in_flight\ no\ no) ;;
    found:queued\ no\ no)
      fm_backlog_start "$DATA" "$ID" || refuse "could not start backlog item $ID: $FM_BACKLOG_TRANSITION_ERROR" ;;
    found:*) refuse "backlog item $ID is $FM_BACKLOG_ROW_STATE (state held blocked), not queued or in flight" ;;
    *) refuse "backlog item $ID cannot be read: ${FM_BACKLOG_ROW_ERROR:-unknown error}" ;;
  esac
else
  [ "$?" -ne 2 ] || refuse "backlog data directory $DATA is inaccessible: $FM_BACKLOG_TRANSITION_ERROR"
  echo "note: backlog transitions do not apply here (${FM_BACKLOG_TRANSITION_SKIP:-}); file the item by hand" >&2
fi

TMP=$(mktemp "$STATE/.fm-pr-adopt.XXXXXX")
printf '%s\n' "worktree=$NO_COPY" "project=$PROJ" kind=ship "mode=$MODE" "yolo=$YOLO" adopted=1 "adopted_at=$(date +%s)" > "$TMP"
# ln refuses an existing name, so a record created since the check above is never replaced.
if ! ln -- "$TMP" "$META" 2>/dev/null; then
  rm -f -- "$TMP"
  refuse "task $ID already has a record at $META"
fi
rm -f -- "$TMP"

if ! FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"; then
  rm -f -- "$META"
  refuse "bin/fm-pr-check.sh did not register $URL (its error is above); the record was removed"
fi
grep -q '^pr_head=' "$META" || echo "warn: GitHub did not report a head for $URL; fm-pr-merge.sh reads it live" >&2
echo "adopted: $ID $URL project=$PROJ_NAME mode=$MODE yolo=$YOLO"
