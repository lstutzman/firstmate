#!/usr/bin/env bash
# fm-gate-grant.sh - a scoped, recorded grant of the project gate-edit
# permission (ALLOW_GATE_EDIT for named protected files) to one task's worker.
#
# A worker cannot set the permission itself: the guard refuses the edit, the
# worker's .claude/settings.local.json is gate-protected, a relaunch rewrites
# that file, and a pane environment does not survive a relaunch. The grant lives
# in firstmate's own task state instead, and the launch path (bin/fm-spawn.sh,
# which bin/fm-control.sh relaunch also runs) carries it into the worker's
# environment, so a human never types the variable into the worker's pane.
#
# Usage:
#   fm-gate-grant.sh grant <task> --files <f1,f2,...> --pr <url|none> \
#       --kind tighten|signoff --decision-file <path|->
#   fm-gate-grant.sh revoke <task> [--reason <why>]
#   fm-gate-grant.sh show <task>
#   fm-gate-grant.sh env <task>      (the launch path's one call; see below)
#
# `grant` records the grant for a ship or scout task that has a task record. The
# files are comma-separated repo-relative paths, the exact form the project
# hook's ALLOW_GATE_EDIT_FILES reads; each must be a plain relative path with no
# `..`, glob, space, quote or other shell syntax. --pr names the pull request
# the edit belongs to, or `none` before one exists. --kind says who decided:
# `tighten` is firstmate's own grant for an edit that only adds or tightens a
# check, and its decision file is firstmate's statement naming the files and the
# PR; `signoff` is the captain's sign-off for an edit that loosens, skips or
# deletes a check, and its decision file is his quoted words with where and when
# (the fleet rules, sections 3 and 9, own who may grant; this script enforces
# only that a decision was recorded). An empty or missing decision refuses the
# grant. A task that already holds a grant refuses a second one: revoke it
# first, so a grant is never widened silently.
#
# The grant is the record state/<task>.gate-grant (key=value lines) beside
# state/<task>.gate-grant.decision (the decision text). Every grant, carry,
# refused carry and revoke is appended to data/<task>/gate-grant.log, which
# keeps the decision text and outlives the task record.
#
# `env` prints the shell prefix the launch command starts with: for a live grant
# `export ALLOW_GATE_EDIT=1; export ALLOW_GATE_EDIT_FILES='<files>'; ` (logged as
# a carry, and marked in state/<task>.gate-grant.carried). For a task that never
# held a grant it prints nothing, so its launch is unchanged. For a task whose
# grant was carried and has since been revoked it prints `unset ALLOW_GATE_EDIT
# ALLOW_GATE_EDIT_FILES; `, so a pane shell that kept the earlier export cannot
# hand it to a launch that no longer holds the grant. A record that cannot be
# validated prints the unset prefix, logs the refusal and exits 1: the variable
# is never set from a record that is not whole.
#
# Every edit under the grant is logged at its end: revoke lists the commits that
# touched the granted files since the default branch (committed edits only, and
# best effort when the task's worktree is already gone) as `edits` lines.
#
# The grant ends in two places. bin/fm-pr-check.sh revokes it when the task's PR
# is registered, and bin/fm-teardown.sh revokes it at cleanup; `revoke` is
# idempotent and logs only when it removes something; `--forget-carry` (the
# cleanup path) also removes the carried marker. A revoke stops every later
# launch from carrying the grant; it cannot reach into an agent that is already
# running, which keeps the environment it was launched with until its next
# relaunch or its cleanup; revoke says so on stderr, except at cleanup.
#
# Delivery to a running worker is a relaunch: grant, then
# `bin/fm-control.sh <task> relaunch`, which rebuilds the launch through
# bin/fm-spawn.sh and so picks the grant up.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

UNSET_PREFIX='unset ALLOW_GATE_EDIT ALLOW_GATE_EDIT_FILES; '
MAX_DECISION_BYTES=8192

die() { echo "fm-gate-grant: $*" >&2; exit 1; }
usage() {
  echo "usage: fm-gate-grant.sh grant <task> --files <f1,f2,...> --pr <url|none> --kind tighten|signoff --decision-file <path|->" >&2
  echo "       fm-gate-grant.sh revoke <task> [--reason <why>] | show <task> | env <task>" >&2
  exit 2
}

paths_for() { # <task>: set RECORD, DECISION and LOG
  RECORD="$STATE/$1.gate-grant"
  CARRIED="$STATE/$1.gate-grant.carried"
  DECISION="$STATE/$1.gate-grant.decision"
  LOG="$DATA/$1/gate-grant.log"
}

log_line() { # <event> <detail...>: one timestamped line in the task's log
  local event=$1
  shift
  mkdir -p "$(dirname "$LOG")" || return 1
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$*" >> "$LOG"
}

record_get() { # <key>
  grep "^$1=" "$RECORD" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Whole means: regular files that are not links, every field well formed, a
# non-empty decision, and a file list that is still a list of plain paths.
files_valid() { # <comma list>
  local list=$1 f rest
  [ -n "$list" ] || return 1
  case "$list" in ,* | *, | *,,*) return 1 ;; esac
  rest=$list
  while [ -n "$rest" ]; do
    f=${rest%%,*}
    case "$rest" in *,*) rest=${rest#*,} ;; *) rest= ;; esac
    case "$f" in
      '' | /* | ./* | ../* | */../* | */.. | .. | */./* | */. | *//* | */) return 1 ;;
    esac
    case "$f" in *[!A-Za-z0-9._/@+-]*) return 1 ;; esac
  done
}

record_valid() { # sets G_KIND G_FILES G_PR on success
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] && [ -f "$DECISION" ] && [ ! -L "$DECISION" ] || return 1
  [ "$(record_get version)" = 1 ] || return 1
  G_KIND=$(record_get kind)
  G_FILES=$(record_get files)
  G_PR=$(record_get pr)
  case "$G_KIND" in tighten | signoff) ;; *) return 1 ;; esac
  files_valid "$G_FILES" || return 1
  case "$G_PR" in none | https://*[!\ ]*) ;; *) return 1 ;; esac
  [ -n "$(tr -d '[:space:]' < "$DECISION")" ] || return 1
  [ "$(record_get decision_sha256)" = "$(sha256_of "$DECISION")" ] || return 1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

cmd_grant() {
  local id=$1 files='' pr='' kind='' dfile='' tmp_dec tmp_rec meta task_kind
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --files) [ "$#" -ge 2 ] || usage; files=$2; shift 2 ;;
      --pr) [ "$#" -ge 2 ] || usage; pr=$2; shift 2 ;;
      --kind) [ "$#" -ge 2 ] || usage; kind=$2; shift 2 ;;
      --decision-file) [ "$#" -ge 2 ] || usage; dfile=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  paths_for "$id"
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || die "task $id has no task record; a grant needs a live task"
  task_kind=$(grep '^kind=' "$meta" | tail -1 | cut -d= -f2- || true)
  case "${task_kind:-ship}" in ship | scout) ;; *) die "task $id is a ${task_kind}, not a ship or scout worker" ;; esac
  case "$kind" in tighten | signoff) ;; *) die "--kind must be tighten or signoff" ;; esac
  files_valid "$files" || die "--files must be comma-separated plain repo-relative paths (letters, digits and ._/@+- only; no .., glob or space)"
  case "$pr" in none | https://*[!\ ]*) ;; *) die "--pr must be a full https:// pull request URL, or none" ;; esac
  [ -n "$dfile" ] || die "--decision-file is required: the grant records the decision it rests on"
  [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ] || die "task $id already holds a gate grant; revoke it first"
  mkdir -p "$STATE" || die "cannot create $STATE"
  tmp_dec=$(mktemp "$STATE/.gate-grant-decision.XXXXXX") || die "cannot create a temporary file in $STATE"
  tmp_rec=$(mktemp "$STATE/.gate-grant.XXXXXX") || { rm -f -- "$tmp_dec"; die "cannot create a temporary file in $STATE"; }
  # A failure below must leave neither half of a grant behind.
  trap 'rm -f -- "$tmp_dec" "$tmp_rec"' EXIT
  if [ "$dfile" = - ]; then
    head -c $((MAX_DECISION_BYTES + 1)) > "$tmp_dec" || die "cannot read the decision from stdin"
  else
    [ -f "$dfile" ] || die "decision file $dfile does not exist"
    head -c $((MAX_DECISION_BYTES + 1)) "$dfile" > "$tmp_dec" || die "cannot read decision file $dfile"
  fi
  [ "$(wc -c < "$tmp_dec" | tr -d ' ')" -le "$MAX_DECISION_BYTES" ] || die "the decision is longer than $MAX_DECISION_BYTES bytes; record the words that matter"
  [ -n "$(tr -d '[:space:]' < "$tmp_dec")" ] || die "the decision is empty; a grant records who decided and why"
  chmod 0600 "$tmp_dec" "$tmp_rec"
  {
    echo "version=1"
    echo "kind=$kind"
    echo "files=$files"
    echo "pr=$pr"
    echo "granted_at=$(date +%s)"
    echo "decision_sha256=$(sha256_of "$tmp_dec")"
  } > "$tmp_rec"
  mv -f -- "$tmp_dec" "$DECISION"
  mv -f -- "$tmp_rec" "$RECORD"
  trap - EXIT
  mkdir -p "$(dirname "$LOG")" || die "grant recorded but the log directory for $id could not be created"
  {
    printf '%s grant kind=%s files=%s pr=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$files" "$pr"
    sed 's/^/    decision| /' "$DECISION"
  } >> "$LOG" || die "grant recorded but its log $LOG could not be written"
  echo "gate grant recorded for $id: $kind, files $files, pr $pr; it reaches the worker on its next launch (fm-control.sh $id relaunch)"
}

# Commits on the task's branch that touched the granted files: the edits made
# under the grant, as far as git can tell. Best effort; never fails a revoke.
log_edits() { # <task> <comma list>
  local id=$1 files=$2 wt base b out
  local -a paths
  wt=$(grep '^worktree=' "$STATE/$id.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  if [ -z "$wt" ] || ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    log_line edits "worktree unavailable; edits under the grant are not listed" || true
    return 0
  fi
  base=
  for b in refs/remotes/origin/HEAD refs/remotes/origin/main refs/remotes/origin/master refs/heads/main refs/heads/master; do
    if git -C "$wt" rev-parse --verify -q "$b" >/dev/null 2>&1; then base=$b; break; fi
  done
  [ -n "$base" ] || { log_line edits "no default branch found; edits under the grant are not listed" || true; return 0; }
  IFS=, read -r -a paths <<< "$files"
  out=$(git -C "$wt" log --format='commit %h %s' --name-only "$base..HEAD" -- "${paths[@]}" 2>/dev/null) || out=
  if [ -z "$out" ]; then
    log_line edits "no commit touched the granted files" || true
  else
    log_line edits "commits that touched the granted files:" || true
    printf '%s\n' "$out" | sed 's/^/    edit| /' >> "$LOG" || true
  fi
}

cmd_revoke() {
  local id=$1 reason=revoked forget=0
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || usage; reason=$2; shift 2 ;;
      --forget-carry) forget=1; shift ;;
      *) usage ;;
    esac
  done
  paths_for "$id"
  [ "$forget" = 0 ] || rm -f -- "$CARRIED" || die "cannot remove the carried marker for $id"
  if [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ] && [ ! -e "$DECISION" ] && [ ! -L "$DECISION" ]; then
    echo "no gate grant for $id"
    return 0
  fi
  local detail
  [ ! -f "$RECORD" ] || ! record_valid || log_edits "$id" "$G_FILES"
  if [ "$forget" = 0 ] && [ -e "$CARRIED" ]; then
    echo "actionable: the worker of $id was launched with the gate-edit grant and keeps it until it is relaunched or cleaned up" >&2
  fi
  detail="kind=$(record_get kind) files=$(record_get files) pr=$(record_get pr) reason=$(printf '%s' "$reason" | tr '\n' ' ')"
  rm -f -- "$RECORD" "$DECISION" || die "cannot remove the gate grant for $id"
  log_line revoke "$detail" || echo "fm-gate-grant: the grant for $id is removed but its log $LOG could not be written" >&2
  echo "gate grant revoked for $id"
}

cmd_show() {
  local id=$1
  paths_for "$id"
  if [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]; then
    echo "no gate grant for $id"
    return 0
  fi
  if ! record_valid; then
    echo "gate grant for $id is present but not whole (it will not be carried)"
    return 1
  fi
  echo "gate grant for $id: kind=$G_KIND files=$G_FILES pr=$G_PR granted_at=$(record_get granted_at)"
  sed 's/^/  decision| /' "$DECISION"
}

cmd_env() {
  local id=$1
  paths_for "$id"
  if [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]; then
    # Only a task that carried a grant has anything to drop from its pane shell.
    [ ! -e "$CARRIED" ] || printf '%s' "$UNSET_PREFIX"
    return 0
  fi
  if ! record_valid; then
    printf '%s' "$UNSET_PREFIX"
    log_line carry-refused "the grant record is not whole; no gate-edit variable was set" 2>/dev/null || true
    echo "fm-gate-grant: the gate grant for $id is not whole; the launch carries no gate-edit variable" >&2
    return 1
  fi
  # Quoting: the validated file list holds only characters safe inside quotes.
  : > "$CARRIED" || { echo "fm-gate-grant: cannot mark the carry for $id; the launch carries no gate-edit variable" >&2; return 1; }
  printf "export ALLOW_GATE_EDIT=1; export ALLOW_GATE_EDIT_FILES='%s'; " "$G_FILES"
  log_line carry "kind=$G_KIND files=$G_FILES pr=$G_PR" 2>/dev/null \
    || echo "fm-gate-grant: could not append the carry to $LOG" >&2
}

[ "$#" -ge 2 ] || usage
CMD=$1
TASK=$2
shift 2
fm_task_id_path_safe "$TASK" || die "invalid task id"
case "$CMD" in
  grant) cmd_grant "$TASK" "$@" ;;
  revoke) cmd_revoke "$TASK" "$@" ;;
  show) [ "$#" -eq 0 ] || usage; cmd_show "$TASK" ;;
  env) [ "$#" -eq 0 ] || usage; cmd_env "$TASK" ;;
  *) usage ;;
esac
