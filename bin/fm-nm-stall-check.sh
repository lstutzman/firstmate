#!/usr/bin/env bash
# fm-nm-stall-check.sh - raise one wake when a no-mistakes run of a task in this
# home looks stalled. It only reports; it never cancels, restarts or answers a run.
#
# Usage:
#   fm-nm-stall-check.sh sweep
#   fm-nm-stall-check.sh --help
#
# bin/fm-watch.sh runs `sweep` on every check sweep and turns its one output
# line into a `check: nm-stall:` wake. Two conditions are watched, for each local
# no-mistakes ship in state/*.meta (kind=ship, mode=no-mistakes, no remote_host,
# a branch and a worktree), read from `no-mistakes axi status` in the task's copy
# through bin/fm-nm-run-lib.sh, the same reader fm-crew-state.sh uses:
#   pending  the run is pending and no step has started, for 5 minutes or more
#            (FM_NM_STALL_PENDING_SECS), while a run slot is free. A slot counts as
#            free unless this repo's overview shows as many running runs as
#            max_concurrent_runs in $NM_HOME/config.yaml (default ~/.no-mistakes),
#            so a run queued behind full slots stays silent and its clock does
#            not start. When the count or the cap cannot be read the wake still
#            goes out and says the slot state is unknown. The overview lists only
#            this repo while the cap is machine-wide, so a wake can fire for a
#            run queued behind other repos' runs; inspect before acting.
#   gate     the run is parked at a gate for 30 minutes or more
#            (FM_NM_STALL_GATE_SECS) with no answer. The wake names the gate and
#            routes it: a finding whose action column is ask-user is owed by the
#            captain through firstmate (the same rule as fm-crew-state.sh); any
#            other gate is the task's own worker's to answer.
# Age is the later of the time this check first saw the state and, for a gate, the
# `awaiting_agent: parked <duration>` the run reports itself. The pending age has
# no run-side timestamp, so it counts from first sight and a check that started
# after the run began undercounts it.
#
# Each (task, run id, state) wakes once. A gate in a new step or a new run is a new
# state. The record state/.nm-stall-check keeps one row per observed state and drops
# the row as soon as a read shows the run moved on (a step started, the gate was
# answered, the run ended), so a later stall wakes again. A read that fails or times
# out leaves the task's rows untouched: no wake, no reset. The sweep stops reading
# after FM_NM_STALL_BUDGET_SECS (default 20, under the watcher's 30 second check
# bound); tasks not reached keep their rows. The line is printed before the record
# is published, so a failed publish can repeat a wake but never swallow one.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.nm-stall-check"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

usage() {
  sed -n '2,40{s/^# \{0,1\}//;p;}' "$0"
}

num_or() {  # <value> <default>
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

PENDING_SECS=$(num_or "${FM_NM_STALL_PENDING_SECS:-}" 300)
GATE_SECS=$(num_or "${FM_NM_STALL_GATE_SECS:-}" 1800)
READ_SECS=$(num_or "${FM_NM_STALL_READ_SECS:-}" 5)
BUDGET_SECS=$(num_or "${FM_NM_STALL_BUDGET_SECS:-}" 20)

now_epoch() {
  case "${FM_NM_STALL_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_NM_STALL_NOW" ;;
  esac
}

# Seconds in a `parked 1h2m3s` style duration; 0 when it cannot be read.
parked_secs() {  # <toon-output>
  fm_nm_field "$1" awaiting_agent | awk '
    { s = $0; gsub(/"/, "", s); sub(/^parked[ \t]*/, "", s) }
    {
      total = 0
      while (match(s, /^[0-9]+[hms]/)) {
        n = substr(s, 1, RLENGTH - 1); u = substr(s, RLENGTH, 1)
        total += n * (u == "h" ? 3600 : u == "m" ? 60 : 1)
        s = substr(s, RLENGTH + 1)
      }
      print total; exit
    }
    END { if (NR == 0) print 0 }'
}

# Name of the gate a parked run waits at.
gate_name() {  # <toon-output>
  local out=$1 name steps statuses i=0 s
  name=$(fm_nm_strip_quotes "$(fm_nm_field "$out" gate)")
  if [ -z "$name" ]; then
    steps=$(fm_nm_table_column "$out" steps step)
    statuses=$(fm_nm_table_column "$out" steps status)
    while IFS= read -r s; do
      i=$((i + 1))
      case "$s" in
        awaiting_approval|fix_review) name=$(printf '%s\n' "$steps" | sed -n "${i}p"); break ;;
      esac
    done <<< "$statuses"
  fi
  printf '%s' "${name:-gate}"
}

# 0 when the machine's run slots are provably full. Prints the running/cap note.
SLOT_NOTE=
slots_full() {  # <worktree>
  local wt=$1 overview running cap cfg
  SLOT_NOTE="run slot state unknown"
  overview=$(fm_nm_run "$wt" "$READ_SECS" axi)
  [ -n "$overview" ] || return 1
  printf '%s\n' "$overview" | grep -q '^runs\[' || return 1
  running=$(fm_nm_table_column "$overview" runs status | grep -c '^running$')
  cfg="${NM_HOME:-$HOME/.no-mistakes}/config.yaml"
  cap=$(sed -n 's/^max_concurrent_runs:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$cfg" 2>/dev/null | head -1)
  [ -n "$cap" ] || return 1
  SLOT_NOTE="$running of $cap run slots in use in this repo"
  [ "$running" -ge "$cap" ]
}

# Who owes the gate's answer.
gate_owner() {  # <toon-output> <task>
  local ids actions i=0 a hit=''
  ids=$(fm_nm_table_column "$1" findings id)
  actions=$(fm_nm_table_column "$1" findings action)
  while IFS= read -r a; do
    i=$((i + 1))
    [ "$a" = ask-user ] || continue
    hit="${hit:+$hit,}$(printf '%s\n' "$ids" | sed -n "${i}p")"
  done <<< "$actions"
  if [ -n "$hit" ]; then
    printf 'owed by the captain through firstmate (ask-user findings %s)' "$hit"
  else
    printf "owed by the task's own worker (%s)" "$2"
  fi
}

mins() { printf '%s' $(( ($1 + 59) / 60 )); }

cmd_sweep() {
  local now meta id wt branch out run_id cond key first seen notified age
  local new_record="" lines="" keep="" parked_age have_started s prev
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 0
  now=$(now_epoch)
  prev=$(cat "$RECORD" 2>/dev/null || true)

  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_pr_task_id_valid "$id" || continue
    [ "$(fm_meta_get "$meta" kind)" = ship ] || continue
    [ "$(fm_meta_get "$meta" mode)" = no-mistakes ] || continue
    [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
    branch=$(fm_meta_get "$meta" branch)
    wt=$(fm_meta_get "$meta" worktree)
    [ -n "$branch" ] && [ -d "$wt" ] || continue
    # Out of read budget: leave this task's rows as they were.
    if [ "$SECONDS" -ge "$BUDGET_SECS" ]; then
      keep="$keep $id "
      continue
    fi
    out=$(fm_nm_run "$wt" "$READ_SECS" axi status)
    run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
    if [ -z "$out" ] || [ -z "$run_id" ] \
      || [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")" != "$branch" ]; then
      # Unreadable, or not this branch's run: keep what we knew, say nothing.
      keep="$keep $id "
      continue
    fi
    cond=
    if fm_nm_run_is_active "$out"; then
      if fm_nm_run_is_parked "$out"; then
        cond="gate:$(gate_name "$out")"
      elif [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")" = pending ]; then
        have_started=0
        while IFS= read -r s; do
          case "$s" in ''|pending) ;; *) have_started=1 ;; esac
        done < <(fm_nm_table_column "$out" steps status)
        if [ "$have_started" = 0 ]; then
          if slots_full "$wt"; then cond=; else cond=pending; fi
        fi
      fi
    fi
    [ -n "$cond" ] || continue
    key="$id	$run_id	$cond"
    seen=$(printf '%s\n' "$prev" | awk -F '\t' -v k="$key" '($1 "\t" $2 "\t" $3) == k { print $4 "\t" $5; exit }')
    if [ -n "$seen" ]; then first=${seen%%$'\t'*}; notified=${seen#*$'\t'}; else first=$now; notified=0; fi
    age=$((now - first))
    case "$cond" in
      gate:*)
        parked_age=$(parked_secs "$out")
        [ "$parked_age" -le "$age" ] || age=$parked_age
        if [ "$notified" = 0 ] && [ "$age" -ge "$GATE_SECS" ]; then
          lines="${lines:+$lines; }$id run $run_id parked at ${cond#gate:} for $(mins "$age")m with no answer, $(gate_owner "$out" "$id")"
          notified=1
        fi ;;
      pending)
        if [ "$notified" = 0 ] && [ "$age" -ge "$PENDING_SECS" ]; then
          lines="${lines:+$lines; }$id run $run_id pending with no step started for $(mins "$age")m while a run slot is free ($SLOT_NOTE); inspect it, nothing was cancelled or restarted"
          notified=1
        fi ;;
    esac
    new_record="${new_record}${key}	${first}	${notified}"$'\n'
  done

  # Rows of tasks this sweep could not read stay as they were; any other row
  # belongs to a run that moved on or a task that is gone.
  while IFS=$'\t' read -r id run_id cond first notified; do
    [ -n "$id" ] || continue
    case "$keep" in *" $id "*) ;; *) continue ;; esac
    new_record="${new_record}${id}	${run_id}	${cond}	${first}	${notified}"$'\n'
  done <<< "$prev"

  [ -z "$lines" ] || printf '%s\n' "$lines"
  if [ "${new_record%$'\n'}" != "$prev" ]; then
    local tmp
    tmp=$(umask 077; mktemp "$STATE/.nm-stall-check.XXXXXX" 2>/dev/null) || return 0
    if printf '%s' "$new_record" > "$tmp" && mv -f -- "$tmp" "$RECORD"; then :; else rm -f -- "$tmp"; fi
  fi
  return 0
}

case "${1:-}" in
  sweep) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_sweep ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
