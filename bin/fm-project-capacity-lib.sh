#!/usr/bin/env bash
# fm-project-capacity-lib.sh - how many workers a project admits at once on this
# machine, whether a fresh worker spawn still fits, and whether the project's
# landing lags too far behind to start another ship.
#
# A project can depend on a machine-local resource that only a few workers can
# use at the same time: a heavy test suite, a local editor stack, a device.
# Firstmate cannot see which part of a worker's life touches that resource, so
# the captain declares how many workers the project admits on this machine, and
# bin/fm-spawn.sh defers a fresh worker beyond that number instead of launching
# it only to spend full-context turns retrying the resource. A deferred task
# keeps its queued backlog item and is dispatched again when a place frees.
# Without a declaration nothing changes and dispatch stays uncapped
# (AGENTS.md section 7).
#
# This file is the single owner of the declaration format, of what holds a
# place, and of the admission verdict. docs/configuration.md "Project capacity"
# is the operator reference, and bin/fm-spawn.sh owns where the check runs.
#
# Declaration: config/project-capacity in the local root Firstmate home (the home
# bin/fm-wake-lib.sh's fm_firstmate_root_home resolves), so every home on this
# machine reads the same number for the same machine's resources. One line per
# project:
#   <project-name> <capacity>
# <project-name> is the project's registered name, which is the basename of its
# clone directory, and <capacity> is a positive integer of at most six digits.
# The capacity is the last whitespace-separated field, so the name before it may
# contain spaces. Blank lines are ignored. A line is a comment when it is `#`,
# when `#` is followed by whitespace, or when it starts with `#` and its last
# field is not an integer. A project whose name begins with `#` is declared by
# writing that `#` immediately against the rest of the name and ending the line
# with the capacity, for example `#repo 2`. A name that is `#`, or that begins
# with `#` followed by a space, is the same spelling as a comment and cannot be
# declared. Any other shape, a project named twice, or an unreadable file makes
# the whole declaration unreadable, and bin/fm-spawn.sh then refuses every fresh
# ship or scout spawn from this machine's homes rather than guessing which limit
# was meant.
#
# Occupancy: a place is held by every task record, in any local Firstmate home on
# this machine (fm_local_firstmate_state_dirs in bin/fm-wake-lib.sh), that
#   - is not a secondmate, which is a persistent home rather than a worker,
#   - names the same project identity, meaning its project resolves to the same
#     shared project lock path (fm_treehouse_project_lock_path), which is keyed
#     by the project's resolved origin, so workers in any clone of that origin
#     are counted, and
#   - has no recorded PR handoff: the pr= line bin/fm-pr-check.sh records when a
#     worker's PR is ready, after which the worker waits on review or merge and
#     no longer uses local resources.
# A place therefore frees when a PR-based ship records its ready PR, or when any
# task is cleaned up and its record removed. A local-only ship and a scout have
# no recorded handoff and hold their place until cleanup. A worker that is
# steered back into work after its PR handoff is not counted again.
# The declaration is matched by the spawning clone's directory name, so clones
# of one origin share the cap only when they use that same directory name. A
# clone of that origin under a different directory name finds no declaration
# and is not capped, though its workers still count as holders for a
# same-origin clone that is capped.
# A record whose project directory no longer exists cannot be matched and holds
# no place. Remote homes are never walked, because their workers run on another
# machine.
#
# Race safety: bin/fm-spawn.sh evaluates admission while holding the shared
# project lock and keeps holding it until the new task record is published, so
# two concurrent spawns for one project can never both publish from the same
# count. A spawn on an uncapped project can still publish a holder for a capped
# same-origin clone, so every backend takes that lock whenever the declaration
# caps any project; Orca, which otherwise never takes it, is included. Freeing a
# place needs no lock, because removing a record or adding pr= only ever lowers
# the count.
#
# Landing lag: a project registered with landing-lag=<hours> in the spawning
# home's data/projects.md (bin/fm-project-mode.sh owns the token) starts no new
# ship while its oldest ready PR has waited more than that many hours to land.
# A ready PR is a task record of the same project identity, found by the same
# local-homes walk as occupancy above, that carries pr=; its age is now minus
# the pr_at=<epoch> bin/fm-pr-check.sh records when that PR is first recorded.
# Only a ready PR that can land counts. One is left out when its task's
# recorded yolo is not on, because it waits for the captain's merge word by
# definition, or when the task's row in its own home's backlog is held for the
# captain (bin/fm-captain-hold.sh) or has an unresolved blocked-by dependency.
# bin/fm-spawn.sh owns the verdict and the exemptions: a relaunch, a scout, a
# secondmate, and a ship spawned with --landing-exempt (a fix or landing work)
# are never held. A project with no landing-lag token is never held.
# Unlike occupancy, a signal that cannot be read never holds a spawn: when the
# local homes or a record cannot be read, or a ready PR has no pr_at= (one
# recorded before ready times existed), the spawn goes ahead with one warning
# line, unless a PR whose age is known already exceeds the lag, since the oldest
# PR is at least that old. A home's backlog that cannot be read is such a
# signal; a home that keeps no backlog holds no PR back. A registered value that is not a whole number of
# hours still refuses the spawn, like an unreadable capacity declaration.
# Known limits: a ready PR held for a release day counts like any other; a
# paused landing is not read; a merged PR counts until its task is cleaned up;
# and remote homes are never walked.
#
# Requires bin/fm-wake-lib.sh (root home, local homes, project lock path),
# bin/fm-secondmate-registry-lib.sh (which the local-homes walk reads),
# bin/fm-backend.sh (fm_meta_get), and bin/fm-tasks-axi-lib.sh with
# bin/fm-backlog-transition-lib.sh (the backlog row a ready PR is held by) to be
# sourced first. No side effects on source.

# Exit status of a spawn deferred because the project is at capacity: the
# sysexits "temporary failure" code, so a caller can tell a deferral that leaves
# the task queued from an ordinary failure.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_PROJECT_CAPACITY_DEFER_EXIT=75

# The config directory holding this machine's declaration: the spawning home's
# own <config-dir> when that home is the local root (so an override of it
# applies), otherwise the root home's config/.
fm_project_capacity_config_dir() {  # <spawning-home> <spawning-config-dir>
  local home=$1 config=$2 root home_real
  root=$(fm_firstmate_root_home "$home") || return 1
  home_real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  if [ "$root" = "$home_real" ]; then
    printf '%s\n' "$config"
  else
    printf '%s/config\n' "$root"
  fi
}

# Read the declared capacity for one project.
# Sets FM_PROJECT_CAPACITY_FILE to the declaration path, FM_PROJECT_CAPACITY
# to the project's capacity, or to empty when the project declares none, and
# FM_PROJECT_CAPACITY_ANY to 1 when the declaration caps any project at all.
# Returns 1 with FM_PROJECT_CAPACITY_ERROR when the declaration is unreadable.
fm_project_capacity_lookup() {  # <config-dir> <project-name>
  local name=$2 line lineno=0 pname pcap seen='|'
  FM_PROJECT_CAPACITY_FILE="$1/project-capacity"
  FM_PROJECT_CAPACITY=
  FM_PROJECT_CAPACITY_ANY=
  FM_PROJECT_CAPACITY_ERROR=
  if [ ! -e "$FM_PROJECT_CAPACITY_FILE" ] && [ ! -L "$FM_PROJECT_CAPACITY_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_PROJECT_CAPACITY_FILE" ] || [ ! -r "$FM_PROJECT_CAPACITY_FILE" ]; then
    FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    # '#' followed by whitespace is always a comment, including one that ends
    # with a number. A line that begins with '#' glued to the rest of a name is
    # a declaration only when its last field is an integer; any other such line
    # stays a comment, so a note does not refuse every spawn.
    case "$line" in
      '' | '#' | '#'[[:space:]]*) continue ;;
      '#'*)
        case "${line##*[[:space:]]}" in
          *[!0-9]*) continue ;;
        esac
        ;;
    esac
    # The capacity is the last field, so the name before it may hold spaces.
    pcap=${line##*[[:space:]]}
    pname=${line%"$pcap"}
    pname=${pname%"${pname##*[![:space:]]}"}
    if [ -z "$pname" ]; then
      FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno is not '<project-name> <capacity>'"
      FM_PROJECT_CAPACITY=
      return 1
    fi
    case "$pcap" in
      '' | *[!0-9]* | 0*)
        FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno gives $pname a capacity that is not a positive integer"
        FM_PROJECT_CAPACITY=
        return 1
        ;;
    esac
    if [ "${#pcap}" -gt 6 ]; then
      FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno gives $pname a capacity longer than six digits"
      FM_PROJECT_CAPACITY=
      return 1
    fi
    case "$seen" in
      *"|$pname|"*)
        FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno names $pname a second time"
        FM_PROJECT_CAPACITY=
        return 1
        ;;
    esac
    seen="$seen$pname|"
    [ "$pname" != "$name" ] || FM_PROJECT_CAPACITY=$pcap
  done < "$FM_PROJECT_CAPACITY_FILE"
  [ "$seen" = '|' ] || FM_PROJECT_CAPACITY_ANY=1
  return 0
}

# Collect this machine's worker task records for one project identity.
# <project-lock> is fm_treehouse_project_lock_path for the project being
# admitted, and <project-dir> is that project's own directory, which matches
# without recomputing its identity. The local homes come from
# fm_local_firstmate_state_dirs <first-state>. <own-id> is the task being
# admitted; its own record in <first-state> is the one this spawn replaces, so
# it is skipped, and secondmate records are skipped.
# Sets FM_PROJECT_RECORDS to the record paths and FM_PROJECT_RECORD_LABELS to
# their task ids, each outside <first-state> qualified with its home. Returns 1
# with FM_PROJECT_CAPACITY_ERROR when the local homes cannot be enumerated, or
# when a state directory or task record in them cannot be read.
fm_project_records() {  # <project-lock> <project-dir> <first-state> <own-id>
  local want=$1 own=$2 first=$3 self=$4 state meta kind project lock id label i
  local -a cache_dirs cache_locks
  FM_PROJECT_RECORDS=()
  FM_PROJECT_RECORD_LABELS=()
  FM_PROJECT_CAPACITY_ERROR=
  fm_local_firstmate_state_dirs "$first" || {
    FM_PROJECT_CAPACITY_ERROR=$FM_LOCAL_FIRSTMATE_ERROR
    return 1
  }
  cache_dirs=("$own")
  cache_locks=("$want")
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    if [ -e "$state" ] && { [ ! -d "$state" ] || [ ! -r "$state" ] || [ ! -x "$state" ]; }; then
      FM_PROJECT_CAPACITY_ERROR="local Firstmate state directory $state cannot be read"
      return 1
    fi
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ "$meta" != "$first/$self.meta" ] || continue
      [ -r "$meta" ] || {
        FM_PROJECT_CAPACITY_ERROR="task record $meta cannot be read"
        return 1
      }
      kind=$(fm_meta_get "$meta" kind)
      [ "$kind" != secondmate ] || continue
      project=$(fm_meta_get "$meta" project)
      [ -n "$project" ] || continue
      lock=
      i=0
      while [ "$i" -lt "${#cache_dirs[@]}" ]; do
        if [ "${cache_dirs[$i]}" = "$project" ]; then
          lock=${cache_locks[$i]}
          break
        fi
        i=$((i + 1))
      done
      if [ "$i" -ge "${#cache_dirs[@]}" ]; then
        lock=$(fm_treehouse_project_lock_path "$project" 2>/dev/null) || lock=
        cache_dirs+=("$project")
        cache_locks+=("$lock")
      fi
      [ -n "$lock" ] && [ "$lock" = "$want" ] || continue
      id=$(basename "$meta" .meta)
      label=$id
      [ "$state" = "$first" ] || label="$id in $(dirname "$state")"
      FM_PROJECT_RECORDS+=("$meta")
      FM_PROJECT_RECORD_LABELS+=("$label")
    done
  done
  return 0
}

# Count the task records holding a place in one project's capacity: every
# fm_project_records record with no recorded pr= handoff.
# Sets FM_PROJECT_CAPACITY_OCCUPANTS to the count and
# FM_PROJECT_CAPACITY_OCCUPANT_IDS to a comma-separated list of the holders.
# Returns 1 with FM_PROJECT_CAPACITY_ERROR when fm_project_records does, since
# skipping an unreadable record could undercount the holders.
fm_project_capacity_occupants() {  # <project-lock> <project-dir> <first-state> <own-id>
  local i=0
  FM_PROJECT_CAPACITY_OCCUPANTS=0
  FM_PROJECT_CAPACITY_OCCUPANT_IDS=
  fm_project_records "$@" || return 1
  while [ "$i" -lt "${#FM_PROJECT_RECORDS[@]}" ]; do
    if [ -z "$(fm_meta_get "${FM_PROJECT_RECORDS[$i]}" pr)" ]; then
      FM_PROJECT_CAPACITY_OCCUPANTS=$((FM_PROJECT_CAPACITY_OCCUPANTS + 1))
      FM_PROJECT_CAPACITY_OCCUPANT_IDS="${FM_PROJECT_CAPACITY_OCCUPANT_IDS:+$FM_PROJECT_CAPACITY_OCCUPANT_IDS, }${FM_PROJECT_RECORD_LABELS[$i]}"
    fi
    i=$((i + 1))
  done
  return 0
}

# Find one project's oldest ready PR that can land: the fm_project_records
# record carrying pr= and yolo=on, whose backlog row is neither held for the
# captain nor blocked, with the earliest pr_at=. A record in <first-state> reads
# the backlog in <first-config> and <first-data>; one in another local home
# reads that home's config/ and data/.
# Sets FM_PROJECT_LANDING_AGE to that PR's age in seconds at <now-epoch>, or to
# empty when no such PR has a readable pr_at=, FM_PROJECT_LANDING_PR to its URL,
# and FM_PROJECT_LANDING_TASK to its task label. Sets
# FM_PROJECT_LANDING_UNTIMED to a comma-separated list of the task labels of
# such PRs whose pr_at= is missing or not an epoch, and
# FM_PROJECT_LANDING_UNTIMED_COUNT to their number. Returns 1 with
# FM_PROJECT_CAPACITY_ERROR when fm_project_records does, or when a home's
# backlog cannot be read.
fm_project_landing_oldest() {  # <project-lock> <project-dir> <first-state> <own-id> <first-config> <first-data> <now-epoch>
  local first=$3 now=$7 i=0 meta label pr at age state config data id rc row
  FM_PROJECT_LANDING_AGE=
  FM_PROJECT_LANDING_PR=
  FM_PROJECT_LANDING_TASK=
  FM_PROJECT_LANDING_UNTIMED=
  FM_PROJECT_LANDING_UNTIMED_COUNT=0
  fm_project_records "$1" "$2" "$3" "$4" || return 1
  while [ "$i" -lt "${#FM_PROJECT_RECORDS[@]}" ]; do
    meta=${FM_PROJECT_RECORDS[$i]}
    label=${FM_PROJECT_RECORD_LABELS[$i]}
    i=$((i + 1))
    pr=$(fm_meta_get "$meta" pr)
    [ -n "$pr" ] && [ "$(fm_meta_get "$meta" yolo)" = on ] || continue
    state=$(dirname "$meta")
    if [ "$state" = "$first" ]; then
      config=$5
      data=$6
    else
      config="$(dirname "$state")/config"
      data="$(dirname "$state")/data"
    fi
    id=$(basename "$meta" .meta)
    rc=0
    fm_backlog_transition_applies "$config" "$data" ship || rc=$?
    if [ "$rc" -eq 2 ]; then
      FM_PROJECT_CAPACITY_ERROR="the backlog for $data cannot be read: $FM_BACKLOG_TRANSITION_ERROR"
      return 1
    fi
    if [ "$rc" -eq 0 ]; then
      if fm_backlog_row_probe "$data" "$id"; then
        row=${FM_BACKLOG_ROW_STATE%% *}
        [ "$row" = "done" ] || [ "$FM_BACKLOG_ROW_HOLD_KIND" != captain ] || continue
        [ "${FM_BACKLOG_ROW_STATE##* }" != yes ] || continue
      elif [ "$FM_BACKLOG_ROW_RESULT" != not_found ]; then
        FM_PROJECT_CAPACITY_ERROR="the backlog row for task $id in $data cannot be read: $FM_BACKLOG_ROW_ERROR"
        return 1
      fi
    fi
    at=$(fm_meta_get "$meta" pr_at)
    if [ -z "$at" ] || [ -n "${at//[0-9]/}" ]; then
      FM_PROJECT_LANDING_UNTIMED_COUNT=$((FM_PROJECT_LANDING_UNTIMED_COUNT + 1))
      FM_PROJECT_LANDING_UNTIMED="${FM_PROJECT_LANDING_UNTIMED:+$FM_PROJECT_LANDING_UNTIMED, }$label"
    else
      age=$((now - 10#$at))
      if [ -z "$FM_PROJECT_LANDING_AGE" ] || [ "$age" -gt "$FM_PROJECT_LANDING_AGE" ]; then
        FM_PROJECT_LANDING_AGE=$age
        FM_PROJECT_LANDING_PR=$pr
        FM_PROJECT_LANDING_TASK=$label
      fi
    fi
  done
  return 0
}
