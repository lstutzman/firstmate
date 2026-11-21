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
#     no longer uses local resources, or the ready_branch= line
#     bin/fm-ready-branch.sh records when the worker parked a pushed, verified
#     branch with no PR because the CI slots gate held its opening.
# A place therefore frees when a PR-based ship records its ready PR or ready branch, or when any
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
# local homes or a record cannot be read, the spawn goes ahead with one warning
# line. A ready PR whose wait is unknown, because it has no pr_at= (one
# recorded before ready times existed) or because its home's backlog or its
# backlog row cannot be read, also lets the spawn go ahead with one warning
# line, unless a PR whose age is known already exceeds the lag, since the
# oldest PR is at least that old. A home that keeps no backlog holds no PR back.
# A registered value that is not a whole number of hours still refuses the
# spawn, like an unreadable capacity declaration.
# Known limits, by the captain's decision until firstmate has a signal for
# them: a paused landing is not read, and a ready PR held for a release day
# counts like any other. A merged PR also counts until its task is cleaned up,
# and remote homes are never walked.
#
# CI slots: config/ci-slots in the spawning home's own config/ (inherited from
# the primary by bin/fm-config-inherit-lib.sh, so every dispatching home reads
# the same file) holds one `<project-name> <slots>` line per project, in the
# same format as project-capacity, where <slots> (S) is the total concurrent
# gate and admission slots across every host. They hold PR openings, never ship
# starts (Lee, 2026-11-21T20:15:32Z): bin/fm-spawn.sh reads neither S nor the
# cap, and a ship builds to a finished branch whatever the queue. The check
# lives in the worker's pre-PR step: `bin/fm-pr-drain.py gate` holds the
# opening while the project's eligible open PRs (drafts, promotion PRs and PRs waiting for the
# captain's merge word left out, fm_ci_slots_held below) reach the open-PR cap, and the worker parks the branch pushed with
# no PR. A project with no line is never held; a malformed file makes the gate
# read unknown. Waiting for a release day (Wednesday) has no signal, so such a
# PR counts. bin/fm-project-mode.sh --ci-slots and --open-pr-cap read S and the
# cap back; bin/fm-fleet-alarm.py announces P > S.
#
# Open-PR cap: config/open-pr-cap, same format and inheritance, holds one
# `<project-name> <cap>` line; a project that declares S and no cap line gets
# min(2 x S, FM_OPEN_PR_CAP_MAX) (Lee 2026-11-21: 2 x S, max 16). The cap counts eligible
# open PRs: drafts, PRs waiting for the captain's merge word and promotion PRs are left out; a project with no S has none.
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

# Read one project's number from a `<project-name> <number>` declaration file
# (the shared parser behind config/project-capacity and config/ci-slots; the
# format is described in this file's header).
# Sets FM_DECLARED_FILE to the declaration path, FM_DECLARED to the project's
# number or to empty when the project declares none, and FM_DECLARED_ANY to 1
# when the declaration names any project at all. Returns 1 with
# FM_DECLARED_ERROR when the declaration is unreadable. <noun> words the
# refusal ("capacity", "slot count").
fm_declared_number_lookup() {  # <declaration-file> <project-name> <noun>
  local name=$2 noun=$3 line lineno=0 pname pcap seen='|'
  FM_DECLARED_FILE=$1
  FM_DECLARED=
  FM_DECLARED_ANY=
  FM_DECLARED_ERROR=
  if [ ! -e "$FM_DECLARED_FILE" ] && [ ! -L "$FM_DECLARED_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_DECLARED_FILE" ] || [ ! -r "$FM_DECLARED_FILE" ]; then
    FM_DECLARED_ERROR="$FM_DECLARED_FILE is not a readable regular file"
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
    # The number is the last field, so the name before it may hold spaces.
    pcap=${line##*[[:space:]]}
    pname=${line%"$pcap"}
    pname=${pname%"${pname##*[![:space:]]}"}
    if [ -z "$pname" ]; then
      FM_DECLARED_ERROR="$FM_DECLARED_FILE line $lineno is not '<project-name> <$noun>'"
      FM_DECLARED=
      return 1
    fi
    case "$pcap" in
      '' | *[!0-9]* | 0*)
        FM_DECLARED_ERROR="$FM_DECLARED_FILE line $lineno gives $pname a $noun that is not a positive integer"
        FM_DECLARED=
        return 1
        ;;
    esac
    if [ "${#pcap}" -gt 6 ]; then
      FM_DECLARED_ERROR="$FM_DECLARED_FILE line $lineno gives $pname a $noun longer than six digits"
      FM_DECLARED=
      return 1
    fi
    case "$seen" in
      *"|$pname|"*)
        FM_DECLARED_ERROR="$FM_DECLARED_FILE line $lineno names $pname a second time"
        FM_DECLARED=
        return 1
        ;;
    esac
    seen="$seen$pname|"
    [ "$pname" != "$name" ] || FM_DECLARED=$pcap
  done < "$FM_DECLARED_FILE"
  [ "$seen" = '|' ] || FM_DECLARED_ANY=1
  return 0
}

# Read the declared capacity for one project.
# Sets FM_PROJECT_CAPACITY_FILE to the declaration path, FM_PROJECT_CAPACITY
# to the project's capacity, or to empty when the project declares none, and
# FM_PROJECT_CAPACITY_ANY to 1 when the declaration caps any project at all.
# Returns 1 with FM_PROJECT_CAPACITY_ERROR when the declaration is unreadable.
fm_project_capacity_lookup() {  # <config-dir> <project-name>
  local rc=0
  fm_declared_number_lookup "$1/project-capacity" "$2" capacity || rc=$?
  FM_PROJECT_CAPACITY_FILE=$FM_DECLARED_FILE
  FM_PROJECT_CAPACITY=$FM_DECLARED
  FM_PROJECT_CAPACITY_ANY=$FM_DECLARED_ANY
  FM_PROJECT_CAPACITY_ERROR=$FM_DECLARED_ERROR
  return "$rc"
}

# Read the declared CI slots (S) for one project from <config-dir>/ci-slots, the
# same format as project-capacity but read from the spawning home's own config/.
# Sets FM_CI_SLOTS_FILE, FM_CI_SLOTS (the project's S, or empty when it declares
# none) and FM_CI_SLOTS_ERROR; returns 1 when the declaration is unreadable.
fm_ci_slots_lookup() {  # <config-dir> <project-name>
  local rc=0
  fm_declared_number_lookup "$1/ci-slots" "$2" "slot count" || rc=$?
  FM_CI_SLOTS_FILE=$FM_DECLARED_FILE
  FM_CI_SLOTS=$FM_DECLARED
  FM_CI_SLOTS_ERROR=$FM_DECLARED_ERROR
  return "$rc"
}

# The open-PR cap for a project that declares CI slots: its line in
# <config-dir>/open-pr-cap, else min(2 x S, FM_OPEN_PR_CAP_MAX). Sets FM_OPEN_PR_CAP
# (empty when the project declares no CI slots) and FM_OPEN_PR_CAP_ERROR;
# returns 1 when either declaration is unreadable.
FM_OPEN_PR_CAP_MAX=16
fm_open_pr_cap_lookup() {  # <config-dir> <project-name>
  local rc=0
  FM_OPEN_PR_CAP=
  FM_OPEN_PR_CAP_ERROR=
  fm_ci_slots_lookup "$1" "$2" || {
    FM_OPEN_PR_CAP_ERROR=$FM_CI_SLOTS_ERROR
    return 1
  }
  [ -n "$FM_CI_SLOTS" ] || return 0
  fm_declared_number_lookup "$1/open-pr-cap" "$2" "open-PR cap" || rc=$?
  if [ "$rc" -ne 0 ]; then
    FM_OPEN_PR_CAP_ERROR=$FM_DECLARED_ERROR
    return 1
  fi
  FM_OPEN_PR_CAP=${FM_DECLARED:-$((FM_CI_SLOTS * 2 > FM_OPEN_PR_CAP_MAX ? FM_OPEN_PR_CAP_MAX : FM_CI_SLOTS * 2))}
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
    if [ -z "$(fm_meta_get "${FM_PROJECT_RECORDS[$i]}" pr)" ] && [ -z "$(fm_meta_get "${FM_PROJECT_RECORDS[$i]}" ready_branch)" ]; then
      FM_PROJECT_CAPACITY_OCCUPANTS=$((FM_PROJECT_CAPACITY_OCCUPANTS + 1))
      FM_PROJECT_CAPACITY_OCCUPANT_IDS="${FM_PROJECT_CAPACITY_OCCUPANT_IDS:+$FM_PROJECT_CAPACITY_OCCUPANT_IDS, }${FM_PROJECT_RECORD_LABELS[$i]}"
    fi
    i=$((i + 1))
  done
  return 0
}

# Count the ready open PRs of one project that wait for the captain's merge
# word, so they stay out of the CI slots. <urls> is the newline-separated list
# of the project's ready open PR URLs. A PR is left out only on positive
# evidence from a task record of this project in a local home (fm_project_records;
# remote homes are never walked) whose pr= is in <urls> and whose task either
# recorded yolo that is not on, which waits for the captain's merge word by
# definition, or has a backlog row held for the captain that is not done. A
# record or backlog that cannot be read, or a PR no record owns, leaves the PR
# counted. A record in <first-state> reads the backlog in <first-config> and
# <first-data>; one in another local home reads that home's config/ and data/.
# Sets FM_CI_SLOTS_HELD to the number of distinct PRs left out. Returns 1 with
# FM_PROJECT_CAPACITY_ERROR when fm_project_records does.
fm_ci_slots_held() {  # <project-lock> <project-dir> <first-state> <first-config> <first-data> <urls>
  local first=$3 urls=$6 i=0 meta pr state config data id rc row seen=$'\n'
  local wedged=$FM_BACKLOG_ROW_SHOW_WEDGED
  FM_CI_SLOTS_HELD=0
  fm_project_records "$1" "$2" "$3" "" || return 1
  while [ "$i" -lt "${#FM_PROJECT_RECORDS[@]}" ]; do
    meta=${FM_PROJECT_RECORDS[$i]}
    i=$((i + 1))
    pr=$(fm_meta_get "$meta" pr)
    [ -n "$pr" ] || continue
    case "$urls" in
      "$pr" | "$pr"$'\n'* | *$'\n'"$pr" | *$'\n'"$pr"$'\n'*) ;;
      *) continue ;;
    esac
    case "$seen" in *$'\n'"$pr"$'\n'*) continue ;; esac
    if [ "$(fm_meta_get "$meta" yolo)" != on ]; then
      seen="$seen$pr"$'\n'
      FM_CI_SLOTS_HELD=$((FM_CI_SLOTS_HELD + 1))
      continue
    fi
    state=$(dirname "$meta")
    if [ "$state" = "$first" ]; then
      config=$4
      data=$5
    else
      config="$(dirname "$state")/config"
      data="$(dirname "$state")/data"
    fi
    id=$(basename "$meta" .meta)
    rc=0
    fm_backlog_transition_applies "$config" "$data" ship || rc=$?
    [ "$rc" -eq 0 ] || continue
    fm_backlog_row_probe "$data" "$id" || continue
    row=${FM_BACKLOG_ROW_STATE%% *}
    if [ "$row" != "done" ] && [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ]; then
      seen="$seen$pr"$'\n'
      FM_CI_SLOTS_HELD=$((FM_CI_SLOTS_HELD + 1))
    fi
  done
  FM_BACKLOG_ROW_SHOW_WEDGED=$wedged
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
# yolo=on ready PRs whose wait is unknown: their pr_at= is missing or not an
# epoch, or their home's backlog or backlog row cannot be read, each of the
# latter labelled "(backlog unreadable)". Sets FM_PROJECT_LANDING_UNTIMED_COUNT
# to their number. Returns 1 with FM_PROJECT_CAPACITY_ERROR when
# fm_project_records does. A backlog read that exceeds its bound latches
# FM_BACKLOG_ROW_SHOW_WEDGED only for the rest of this walk, so another home's
# slow backlog never refuses the caller's own later backlog reads.
fm_project_landing_oldest() {  # <project-lock> <project-dir> <first-state> <own-id> <first-config> <first-data> <now-epoch>
  local first=$3 now=$7 i=0 meta label pr at age state config data id rc row
  local wedged=$FM_BACKLOG_ROW_SHOW_WEDGED
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
    if [ "$rc" -eq 0 ]; then
      if fm_backlog_row_probe "$data" "$id"; then
        row=${FM_BACKLOG_ROW_STATE%% *}
        [ "$row" = "done" ] || [ "$FM_BACKLOG_ROW_HOLD_KIND" != captain ] || continue
        [ "${FM_BACKLOG_ROW_STATE##* }" != yes ] || continue
      elif [ "$FM_BACKLOG_ROW_RESULT" != not_found ]; then
        rc=2
      fi
    fi
    at=$(fm_meta_get "$meta" pr_at)
    if [ "$rc" -eq 2 ]; then
      FM_PROJECT_LANDING_UNTIMED_COUNT=$((FM_PROJECT_LANDING_UNTIMED_COUNT + 1))
      FM_PROJECT_LANDING_UNTIMED="${FM_PROJECT_LANDING_UNTIMED:+$FM_PROJECT_LANDING_UNTIMED, }$label (backlog unreadable)"
    elif [ -z "$at" ] || [ -n "${at//[0-9]/}" ]; then
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
  FM_BACKLOG_ROW_SHOW_WEDGED=$wedged
  return 0
}
