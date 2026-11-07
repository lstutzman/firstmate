#!/usr/bin/env bash
# fm-tree-park.sh - give a finished ship's pool slot back while its PR waits on
# another home's merger, and take a fresh one when it needs code again.
#
# Usage: fm-tree-park.sh sweep
#        fm-tree-park.sh park <task-id>
#        fm-tree-park.sh unpark <task-id>
#
# A ship's Treehouse slot otherwise stays leased from its ready PR until that PR
# merges. When another home merges the project's PRs (merger= in
# data/projects.md) and its landing queue is long, finished ships hold most of
# the pool and new work cannot start. A finished copy whose branch is pushed and
# equals its PR head is preserved on the remote, so this script returns it to
# the pool and keeps the task record; the work is never discarded.
#
# sweep runs on every watcher check sweep (bin/fm-watch.sh) and makes only local
# reads. A task is a park candidate when all of these hold:
#   - kind=ship, not already parked, on a herdr or rex backend: only those can
#     prove the stopped endpoint gone and relaunch a fresh one
#     (docs/agent-control.md), which unpark needs;
#   - its recorded worktree= is a Treehouse pool slot this task still claims;
#   - state/<id>.merge-handoff names its recorded pr= (bin/fm-pr-check.sh wrote
#     it when it handed the PR to its merger home);
#   - fm_office_task_landing holds: the latest event is the worker's done line,
#     the PR was handed off, and no steer arrived since that line;
#   - a no-mistakes task's run was released for that same handoff
#     (state/<id>.nm-released equals the handoff record); an unreleased run is
#     waited for, never parked under.
# Each handoff record (PR URL and head) is attempted once: the sweep writes it to
# state/<id>.park-attempt and starts `park` in its own session, so the watcher's
# check bound cannot cut it off half way. Its log is state/<id>.park-log. A
# park that refused because the copy is not safe to release stays silent, since
# that task keeps today's behaviour; a park that failed after it changed
# something writes state/<id>.park-report, which the next sweep prints once
# (the watcher wakes on it as `check: tree-park:`).
#
# park re-proves everything under the task's locks before it changes anything:
#   - the candidate rules above;
#   - the copy is clean (`git status --porcelain --untracked-files=all`, apart
#     from the harness wiring bin/fm-teardown.sh also exempts), on a branch,
#     with no commit missing from origin/<branch> after a fetch, and its HEAD
#     equals both origin/<branch> and the PR head the forge reports now;
#   - a no-mistakes task has no live run for the copy (`no-mistakes axi status`);
#   - the agent's busy verdict is idle.
# A refusal that can clear by itself (a busy agent, an unreadable fetch, forge
# head, or run, a live run, a stop the control plane could not prove) removes
# state/<id>.park-attempt so a later sweep tries again; one that names unsafe
# work in the copy keeps the attempt spent. The sweep also waits while the
# agent reads busy rather than starting a park that would refuse.
# It then stops the agent with `bin/fm-control.sh <id> exit --stop-background`,
# the control plane's verified stop for a finished agent, and refuses if that
# stop is not proven. Holding the project Treehouse lock, the task's control
# lock, and its record lock (bin/fm-teardown.sh's order), it re-checks the copy,
# removes the harness wiring teardown removes, returns the slot with
# `treehouse return --force`, drops the slot claim, and rewrites the record:
# worktree= is removed (every slot-ownership scan reads that field, so a parked
# record must stop naming the slot) and parked=1, parked_branch=,
# parked_head=, parked_worktree=, and parked_at= are added. The task record,
# its backlog item, its merge poll, and its status are left as they were.
#
# unpark runs from bin/fm-send.sh before a steer to a parked task is recorded.
# Under the project lock it first leases in place every slot this home's
# records still name (fm_treehouse_lease_recorded_slots, as bin/fm-spawn.sh
# does before its own get), then leases a fresh slot (`treehouse get --lease`) and
# claims it, fetches the PR branch, and requires origin/<branch> and the forge's
# PR head to both equal parked_head before it checks the branch out there. It
# then restores worktree= and drops the parked fields, and relaunches the worker
# through `bin/fm-control.sh <id> relaunch --note-file`, whose note tells the
# replacement that its copy is fresh and its steer is in its inbox. Any failure
# returns the fresh slot and restores the parked record, so a refused unpark
# leaves the task exactly as parked and exits nonzero.
#
# bin/fm-teardown.sh treats a parked record as one with no copy to return.
# Exit codes: 0 done (or nothing to do), 1 refused or failed, 2 usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-office-authority-lib.sh
. "$SCRIPT_DIR/fm-office-authority-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
refuse() { printf 'not parked: %s\n' "$*" >&2; exit 1; }
# A refusal that may clear by itself (a busy agent, an unreadable forge or run,
# a stop the control plane could not prove) frees the handoff's one attempt so
# the next sweep tries again; one that names unsafe work keeps it spent.
retry_later() {
  rm -f "$STATE/$ID.park-attempt"
  refuse "$* (retried on a later sweep)"
}

park_meta_value() {  # <key>
  fm_meta_get "$META" "$1"
}

park_home_id() {
  local rc=0 id
  id=$(fm_parent_channel_home_id "$FM_HOME") || rc=$?
  case "$rc" in
    0) printf '%s\n' "$id" ;;
    1) printf 'main\n' ;;
    *) return 1 ;;
  esac
}

park_record_line() {  # <file>: the one line of a single-line record, or fail
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  cat "$1" 2>/dev/null
}

# The local candidate rules from the header. Sets PARK_WT, PARK_PROJ, PARK_URL,
# PARK_HANDOFF, PARK_MODE, PARK_BACKEND; returns 1 with PARK_WHY set otherwise.
park_candidate() {
  local kind self
  PARK_WHY=
  [ -f "$META" ] && [ ! -L "$META" ] || { PARK_WHY="no task record"; return 1; }
  kind=$(park_meta_value kind)
  [ "${kind:-ship}" = ship ] || { PARK_WHY="not a ship"; return 1; }
  [ "$(park_meta_value parked)" != 1 ] || { PARK_WHY="already parked"; return 1; }
  PARK_BACKEND=$(fm_backend_of_meta "$META")
  case "$PARK_BACKEND" in
    herdr|rex) ;;
    *) PARK_WHY="backend $PARK_BACKEND cannot relaunch a worker whose endpoint is gone"; return 1 ;;
  esac
  PARK_WT=$(park_meta_value worktree)
  PARK_PROJ=$(park_meta_value project)
  [ -n "$PARK_WT" ] && [ -d "$PARK_WT" ] || { PARK_WHY="no recorded copy"; return 1; }
  fm_treehouse_pool_slot "$PARK_PROJ" "$PARK_WT" || { PARK_WHY="copy is not a Treehouse pool slot"; return 1; }
  fm_treehouse_slot_owner_state "$PARK_WT" "$ID"
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    mine|absent) ;;
    *) PARK_WHY="pool slot claim is $FM_TREEHOUSE_SLOT_OWNER"; return 1 ;;
  esac
  PARK_URL=$(park_meta_value pr)
  [ -n "$PARK_URL" ] || { PARK_WHY="no recorded PR"; return 1; }
  PARK_HANDOFF=$(park_record_line "$STATE/$ID.merge-handoff") || { PARK_WHY="PR not handed to another home's merger"; return 1; }
  [ "${PARK_HANDOFF%% *}" = "$PARK_URL" ] || { PARK_WHY="handoff record names another PR"; return 1; }
  self=$(park_home_id) || { PARK_WHY="this home's identity marker is unusable"; return 1; }
  fm_office_task_landing "$STATE" "$ID" "$self" || { PARK_WHY="task is not waiting on its merger"; return 1; }
  PARK_MODE=$(park_meta_value mode)
  [ -n "$PARK_MODE" ] || PARK_MODE=no-mistakes
  if [ "$PARK_MODE" = no-mistakes ]; then
    [ "$(park_record_line "$STATE/$ID.nm-released" || true)" = "$PARK_HANDOFF" ] \
      || { PARK_WHY="its no-mistakes run has not been released for this handoff"; return 1; }
  fi
}

# Tracked changes and untracked paths, apart from the harness wiring
# bin/fm-teardown.sh's ship safety check also exempts.
park_copy_dirt() {  # <worktree>
  local raw
  raw=$(git -C "$1" status --porcelain --untracked-files=all 2>/dev/null) || { printf 'unreadable\n'; return 0; }
  printf '%s\n' "$raw" | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' | grep -v '^$' || true
}

# The copy is clean, on a branch, and its HEAD equals origin/<branch> after a
# fetch and the forge's PR head. Sets PARK_BRANCH and PARK_HEAD.
park_copy_preserved() {
  local dirt remote forge
  PARK_TRANSIENT=0
  dirt=$(park_copy_dirt "$PARK_WT")
  [ -z "$dirt" ] || { PARK_WHY="copy has uncommitted changes"; return 1; }
  PARK_BRANCH=$(git -C "$PARK_WT" symbolic-ref --quiet --short HEAD 2>/dev/null) || { PARK_WHY="copy is not on a branch"; return 1; }
  PARK_HEAD=$(git -C "$PARK_WT" rev-parse HEAD 2>/dev/null) || { PARK_WHY="copy head cannot be read"; return 1; }
  fm_run_timed 60 git -C "$PARK_WT" fetch --quiet origin "+refs/heads/$PARK_BRANCH:refs/remotes/origin/$PARK_BRANCH" >/dev/null 2>&1 \
    || { PARK_WHY="origin/$PARK_BRANCH cannot be fetched"; PARK_TRANSIENT=1; return 1; }
  remote=$(git -C "$PARK_WT" rev-parse --verify --quiet "refs/remotes/origin/$PARK_BRANCH^{commit}" 2>/dev/null) \
    || { PARK_WHY="origin/$PARK_BRANCH does not exist"; return 1; }
  [ -z "$(git -C "$PARK_WT" rev-list "$remote..HEAD" 2>/dev/null)" ] || { PARK_WHY="copy has commits not on origin/$PARK_BRANCH"; return 1; }
  [ "$remote" = "$PARK_HEAD" ] || { PARK_WHY="copy head $PARK_HEAD is not origin/$PARK_BRANCH $remote"; return 1; }
  forge=$(park_forge_head "$PARK_WT") || { PARK_WHY="the forge's PR head cannot be read"; PARK_TRANSIENT=1; return 1; }
  [ "$forge" = "$PARK_HEAD" ] || { PARK_WHY="copy head $PARK_HEAD is not the PR head $forge"; return 1; }
}

park_forge_head() {  # <dir>
  local head
  fm_pr_url_parse "$PARK_URL" && [ "$FM_PR_PROVIDER" = github ] || return 1
  head=$(cd "$1" && fm_run_timed 30 gh pr view "$PARK_URL" --json headRefOid -q .headRefOid 2>/dev/null) || return 1
  fm_pr_head_valid "$head" || return 1
  printf '%s\n' "$head"
}

park_agent_idle() {
  local verdict
  verdict=$(fm_busy_classify_meta "$META" "$ID" "$STATE")
  case "$verdict" in
    idle*|dead*) ;;
    *) PARK_WHY="its agent reads '$verdict', not idle"; return 1 ;;
  esac
}

park_no_live_run() {
  local out
  [ "$PARK_MODE" = no-mistakes ] || return 0
  out=$(cd "$PARK_WT" && fm_run_timed 30 no-mistakes axi status 2>/dev/null) || { PARK_WHY="its no-mistakes run cannot be read"; return 1; }
  ! fm_nm_run_is_active "$out" || { PARK_WHY="its no-mistakes run is still active"; return 1; }
}

# Rewrite the record without the keys <drop-regex> matches, adding <line>s.
# New lines go before the first pr_at= or pr= line, because the PR identity
# parse (fm_pr_metadata_identity_parse) refuses unknown fields after pr=.
park_rewrite_meta() {  # <drop-regex> <line>...
  local drop=$1 tmp line placed=0
  shift
  tmp=$(mktemp "$STATE/.fm-tree-park-meta.XXXXXX") || return 1
  cp -p "$META" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  {
    while IFS= read -r line || [ -n "$line" ]; do
      if printf '%s\n' "$line" | grep -qE "^($drop)="; then continue; fi
      case "$line" in
        pr_at=*|pr=*)
          if [ "$placed" = 0 ]; then
            [ "$#" -eq 0 ] || printf '%s\n' "$@"
            placed=1
          fi
          ;;
      esac
      printf '%s\n' "$line"
    done < "$META"
    [ "$placed" = 1 ] || [ "$#" -eq 0 ] || printf '%s\n' "$@"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f -- "$tmp" "$META" || { rm -f "$tmp"; return 1; }
}

LOCKS_HELD=()
park_lock() {  # <path> try|wait
  if [ "$2" = try ]; then
    fm_lock_try_acquire "$1" || return 1
  else
    fm_lock_acquire_wait "$1" || return 1
  fi
  LOCKS_HELD+=("$1")
}
park_unlock_all() {
  local i
  for ((i=${#LOCKS_HELD[@]} - 1; i >= 0; i--)); do
    fm_lock_release "${LOCKS_HELD[$i]}" || true
  done
  LOCKS_HELD=()
}
trap park_unlock_all EXIT

park_take_locks() {
  local project_lock
  project_lock=$(fm_treehouse_project_lock_path "$PARK_PROJ") || { PARK_WHY="the project Treehouse lock cannot be resolved"; return 1; }
  fm_lock_acquire_wait_max "$project_lock" 60 || { PARK_WHY="another slot allocation or return holds the project lock"; return 1; }
  LOCKS_HELD+=("$project_lock")
  park_lock "$STATE/.control-$ID.lock" try || { PARK_WHY="another lifecycle action is running for the task"; return 1; }
  park_lock "$(fm_meta_lock_path "$META")" wait || { PARK_WHY="the task record cannot be locked"; return 1; }
}

park_report() {  # <text>: an actionable failure for the next sweep to print once
  printf '%s\n' "$*" >> "$STATE/$ID.park-report" 2>/dev/null || true
  printf 'error: %s\n' "$*" >&2
}

park_remove_wiring() {  # <worktree>
  local path harness
  harness=$(park_meta_value harness)
  rm -f "$1/.claude/settings.local.json" "$1/.opencode/plugins/fm-turn-end.js" \
    "$1/.opencode/plugins/fm-busy-state.js" "$1/.fm-grok-turnend" "$1/.fm-kimi-turnend"
  while IFS= read -r path; do
    case "$path" in "$1"/*) ;; *) continue ;; esac
    git -C "$1" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 && continue
    rm -f "$path"
  done <<EOF
$(fm_control_harness_wiring_paths "$harness" "$1" "$STATE" "$ID" 2>/dev/null || true)
EOF
}

cmd_park() {
  local out
  park_candidate || refuse "$ID: $PARK_WHY"
  park_agent_idle || retry_later "$ID: $PARK_WHY"
  if ! park_copy_preserved; then
    [ "$PARK_TRANSIENT" = 1 ] && retry_later "$ID: $PARK_WHY"
    refuse "$ID: $PARK_WHY"
  fi
  park_no_live_run || retry_later "$ID: $PARK_WHY"
  out=$("$SCRIPT_DIR/fm-control.sh" "$ID" exit --stop-background 2>&1) \
    || retry_later "$ID: the control plane could not prove its agent stopped: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  if ! park_take_locks; then
    park_report "$ID's agent was stopped to park its copy, but $PARK_WHY; relaunch it with bin/fm-control.sh $ID relaunch --note <text> or retry the park"
    exit 1
  fi
  # Everything is re-read under the locks: a steer, a commit made while the
  # agent exited, or a new head all keep today's behaviour.
  if ! park_candidate || ! park_copy_preserved; then
    park_report "$ID's agent was stopped to park its copy, but the copy can no longer be released ($PARK_WHY); relaunch it with bin/fm-control.sh $ID relaunch --note <text>"
    exit 1
  fi
  park_remove_wiring "$PARK_WT"
  if ! out=$( (cd "$PARK_PROJ" && fm_run_timed 120 treehouse return --force "$PARK_WT") 2>&1 ); then
    park_report "$ID's agent was stopped to park its copy, but treehouse return failed for $PARK_WT, so the slot is still its: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
    exit 1
  fi
  fm_treehouse_slot_owner_release "$PARK_WT" "$ID"
  if ! park_rewrite_meta 'worktree|parked|parked_branch|parked_head|parked_worktree|parked_at' \
      parked=1 "parked_branch=$PARK_BRANCH" "parked_head=$PARK_HEAD" "parked_worktree=$PARK_WT" "parked_at=$(date +%s)"; then
    park_report "$ID's copy $PARK_WT was returned to the pool, but its record could not be rewritten and still names that slot; set parked=1, parked_branch=$PARK_BRANCH, parked_head=$PARK_HEAD and remove worktree= in $META by hand"
    exit 1
  fi
  git -C "$PARK_PROJ" branch -D "$PARK_BRANCH" >/dev/null 2>&1 || true
  printf 'parked: %s returned its copy %s; its PR %s waits on its merger at %s\n' "$ID" "$PARK_WT" "$PARK_URL" "$PARK_HEAD"
}

UNPARK_WT=
unpark_rollback() {
  [ -n "$UNPARK_WT" ] || return 0
  ( cd "$PARK_PROJ" && fm_run_timed 120 treehouse return --force "$UNPARK_WT" ) >/dev/null 2>&1 \
    || printf 'warning: could not return the fresh copy %s for %s; run treehouse return --force %s from %s\n' "$UNPARK_WT" "$ID" "$UNPARK_WT" "$PARK_PROJ" >&2
  fm_treehouse_slot_owner_release "$UNPARK_WT" "$ID"
  UNPARK_WT=
}

cmd_unpark() {
  local head branch remote forge project_lock note out
  [ -f "$META" ] && [ ! -L "$META" ] || die "$ID has no task record"
  [ "$(park_meta_value parked)" = 1 ] || { printf 'unparked: %s is not parked\n' "$ID"; return 0; }
  PARK_PROJ=$(park_meta_value project)
  PARK_URL=$(park_meta_value pr)
  branch=$(park_meta_value parked_branch)
  head=$(park_meta_value parked_head)
  if [ -z "$PARK_PROJ" ] || [ ! -d "$PARK_PROJ" ] || [ -z "$branch" ] || ! fm_pr_head_valid "$head"; then
    die "$ID's parked record is incomplete (project, parked_branch, parked_head)"
  fi
  project_lock=$(fm_treehouse_project_lock_path "$PARK_PROJ") || die "the project Treehouse lock for $PARK_PROJ cannot be resolved"
  fm_lock_acquire_wait_max "$project_lock" 60 || die "another slot allocation or return holds the project lock for $PARK_PROJ"
  LOCKS_HELD+=("$project_lock")
  park_lock "$(fm_meta_lock_path "$META")" wait || die "$ID's record cannot be locked"
  [ "$(park_meta_value parked)" = 1 ] || { park_unlock_all; printf 'unparked: %s is not parked\n' "$ID"; return 0; }
  # As bin/fm-spawn.sh does before its own get: lease every slot this home's
  # records still name and claim, so get cannot hand out and reset one of them.
  fm_treehouse_lease_recorded_slots "$PARK_PROJ" "$STATE"/*.meta \
    || die "could not lease the pool slots this home's task records still name ($FM_TREEHOUSE_SLOT_LEASE_ERROR); $ID stays parked"
  UNPARK_WT=$(cd "$PARK_PROJ" && treehouse get --lease --lease-holder "$ID" 2>/dev/null) && [ -n "$UNPARK_WT" ] \
    || { UNPARK_WT=; die "treehouse get --lease could not lease a fresh copy for $ID from $PARK_PROJ"; }
  if ! fm_treehouse_pool_slot "$PARK_PROJ" "$UNPARK_WT"; then
    unpark_rollback; die "the leased copy for $ID is not a pool slot of $PARK_PROJ"
  fi
  if ! fm_treehouse_slot_owner_claim "$UNPARK_WT" "$ID" "$FM_HOME"; then
    unpark_rollback; die "could not claim the fresh copy for $ID"
  fi
  if ! fm_run_timed 60 git -C "$UNPARK_WT" fetch --quiet origin "+refs/heads/$branch:refs/remotes/origin/$branch" >/dev/null 2>&1 \
      || ! remote=$(git -C "$UNPARK_WT" rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}"); then
    unpark_rollback; die "origin/$branch cannot be fetched for $ID"
  fi
  if [ "$remote" != "$head" ]; then
    unpark_rollback; die "origin/$branch is $remote, not $ID's parked head $head; the PR branch moved while the copy was parked"
  fi
  if ! forge=$(park_forge_head "$UNPARK_WT") || [ "$forge" != "$head" ]; then
    unpark_rollback; die "the forge's head for $PARK_URL is ${forge:-unreadable}, not $ID's parked head $head"
  fi
  if ! git -C "$UNPARK_WT" checkout --quiet -B "$branch" "$head" 2>/dev/null \
      || ! git -C "$UNPARK_WT" branch --quiet --set-upstream-to="origin/$branch" "$branch" 2>/dev/null \
      || [ "$(git -C "$UNPARK_WT" rev-parse HEAD)" != "$head" ]; then
    unpark_rollback; die "could not check out $branch at $head in the fresh copy for $ID"
  fi
  if ! park_rewrite_meta 'worktree|parked|parked_branch|parked_head|parked_worktree|parked_at' "worktree=$UNPARK_WT"; then
    unpark_rollback; die "could not record the fresh copy in $ID's record"
  fi
  park_unlock_all
  note=$(mktemp "${TMPDIR:-/tmp}/fm-tree-park-note.XXXXXX") || die "could not write the relaunch note"
  printf '%s\n' \
    "Your previous copy was returned to the pool while your PR $PARK_URL waited for its merger." \
    "This is a fresh copy of branch $branch at $head, matching the PR head; your earlier conversation is gone." \
    "Do not create the branch again: it is checked out. Read your steering inbox now for the instruction that brought you back." > "$note"
  if ! out=$("$SCRIPT_DIR/fm-control.sh" "$ID" relaunch --note-file "$note" 2>&1); then
    rm -f "$note"
    park_take_locks_for_rollback
    die "$ID was given a fresh copy but its worker could not be relaunched, so it was parked again: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  fi
  rm -f "$note"
  printf 'unparked: %s relaunched in %s at %s\n' "$ID" "$UNPARK_WT" "$head"
}

# A relaunch that failed leaves no agent in the fresh copy, so the record goes
# back to parked and the copy back to the pool.
park_take_locks_for_rollback() {
  local project_lock
  project_lock=$(fm_treehouse_project_lock_path "$PARK_PROJ") || return 0
  fm_lock_acquire_wait_max "$project_lock" 60 || return 0
  LOCKS_HELD+=("$project_lock")
  park_lock "$(fm_meta_lock_path "$META")" wait || return 0
  park_rewrite_meta 'worktree|parked|parked_branch|parked_head|parked_worktree|parked_at' \
    parked=1 "parked_branch=$(git -C "$UNPARK_WT" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
    "parked_head=$(git -C "$UNPARK_WT" rev-parse HEAD 2>/dev/null)" "parked_worktree=$UNPARK_WT" "parked_at=$(date +%s)" || return 0
  unpark_rollback
  park_unlock_all
}

cmd_sweep() {
  local meta report handoff
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    ID=${meta##*/}
    ID=${ID%.meta}
    fm_pr_task_id_valid "$ID" || continue
    META=$meta
    report="$STATE/$ID.park-report"
    if [ -f "$report" ] && [ ! -L "$report" ]; then
      cat "$report" 2>/dev/null || true
      rm -f "$report"
    fi
    park_candidate || continue
    park_agent_idle || continue
    handoff=$PARK_HANDOFF
    [ "$(park_record_line "$STATE/$ID.park-attempt" || true)" != "$handoff" ] || continue
    printf '%s\n' "$handoff" > "$STATE/$ID.park-attempt" || continue
    fm_detach_session "$STATE/$ID.park-log" "$SCRIPT_DIR/fm-tree-park.sh" park "$ID" || \
      printf '%s could not start parking its copy\n' "$ID"
  done
}

[ "$#" -ge 1 ] || { echo "usage: fm-tree-park.sh sweep | park <task-id> | unpark <task-id>" >&2; exit 2; }
VERB=$1
shift
case "$VERB" in
  sweep)
    [ "$#" -eq 0 ] || { echo "usage: fm-tree-park.sh sweep" >&2; exit 2; }
    cmd_sweep
    ;;
  park|unpark)
    [ "$#" -eq 1 ] || { echo "usage: fm-tree-park.sh $VERB <task-id>" >&2; exit 2; }
    ID=$1
    fm_pr_task_id_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
    META="$STATE/$ID.meta"
    "cmd_$VERB"
    ;;
  *) echo "usage: fm-tree-park.sh sweep | park <task-id> | unpark <task-id>" >&2; exit 2 ;;
esac
