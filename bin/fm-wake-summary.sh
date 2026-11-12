#!/usr/bin/env bash
# fm-wake-summary.sh - one line per drained wake row, with the current state that decides it and
# a deterministic verdict: `no-action` or `ACTION`.
#
# Usage: fm-wake-summary.sh [--annotations <file>] < <deduped wake rows>
#
# stdin is the drain's deduplicated queue rows (epoch, sequence, kind, key and payload, tab
# separated). --annotations names the drain's own `wake annotation:` lines for the same
# presentation, so a signal row is judged on the exact unread status lines the drain showed,
# never on a later read. Prints, for each row:
#   #<seq> <kind> <subject>: <verdict> - <deciding state>
# and exits 0 when every row is `no-action` (and there was at least one), 1 otherwise.
# It is read-only: it never writes state, acknowledges a row or runs a gate.
#
# `no-action` is claimed for exactly these cases, each decided from a read that needs no
# judgement; every other row, and any case where a read fails, is `ACTION`:
#   - signal: the drain's annotations carry no unread line for the status file (an unread line,
#     a pause included, is the supervisor's to read in the turn it surfaces), the newest status
#     line is a `paused:` line that is not a captain hold, not a keyed decision, carries no cause
#     other than external, names no clearing time that has passed, and bin/fm-crew-state.sh
#     reports the task's state as paused.
#   - stale: bin/fm-crew-state.sh reports the task paused, its newest status line is such a
#     pause, and the wake text is not the watcher's "declared clearing time has passed" recheck.
#   - check `merge landed: <task> <pr-url>`: the task is already torn down (its record is gone;
#     teardown removes it together with the backlog move). A task with a live record, merged or
#     not, always wakes: that wake is what triggers cleanup and re-evaluating queued work.
#   - check `<state>/office-lane-<lane>.check.sh: office <id>: <officer> digest <key>; <n> start
#     request(s) delivered to this office's inbox` (a custom check's payload is its script path
#     and its output) with no findings clause, since an office must read findings that were not
#     delivered as start requests: bin/fm-office.sh starts-handled <officer> says every start
#     request in the lane digest is already acknowledged.
# FM_WAKE_SUMMARY_CREW_STATE and FM_WAKE_SUMMARY_OFFICE override the two helper scripts (a test
# seam). The verdict is the whole handling of a `no-action` row: the drain's --summary mode may
# acknowledge a batch of only those rows when the home opts in (docs/configuration/supervision.md "Wake
# auto-acknowledge").
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

ANNOTATIONS=
case "${1:-}" in
  '') ;;
  --annotations)
    ANNOTATIONS=${2:-}
    [ -n "$ANNOTATIONS" ] && [ "$#" -eq 2 ] || { echo "usage: fm-wake-summary.sh [--annotations <file>] < rows" >&2; exit 2; }
    ;;
  *) echo "usage: fm-wake-summary.sh [--annotations <file>] < rows" >&2; exit 2 ;;
esac

CREW_STATE=${FM_WAKE_SUMMARY_CREW_STATE:-$SCRIPT_DIR/fm-crew-state.sh}
OFFICE=${FM_WAKE_SUMMARY_OFFICE:-$SCRIPT_DIR/fm-office.sh}
NOW=$(date +%s)

VERDICT=
DETAIL=

verdict() { VERDICT=$1; DETAIL=$2; }

short() { # <text> [<max>]: single-line text cut at <max> characters
  local t=${1//$'\t'/ } max=${2:-100}
  t=${t//$'\n'/ }
  if [ "${#t}" -gt "$max" ]; then t="${t:0:max}..."; fi
  printf '%s' "$t"
}

# crew_state_line <task>: the first line of bin/fm-crew-state.sh, or empty on failure.
crew_state_line() {
  local out
  out=$(fm_run_timed 25 "$CREW_STATE" "$1" 2>/dev/null) || return 1
  printf '%s' "${out%%$'\n'*}"
}

crew_state_word() { # <crew-state-line> -> state word
  local rest=${1#state: }
  printf '%s' "${rest%% *}"
}

# pause_line_ok <status-line>: 0 when the line is a declared pause that still needs nothing from
# the supervisor (see the header); otherwise prints why not and returns 1.
pause_line_ok() {
  local line=$1 cause until
  if ! status_is_paused "$line"; then
    printf 'newest status line is not a pause: %s' "$(short "$line" 80)"; return 1
  fi
  if status_is_keyed_decision "$line"; then printf 'the pause line carries a decision key'; return 1; fi
  cause=$(status_line_cause "$line")
  case "$cause" in
    external|unstated) ;;
    *) printf 'the pause names cause=%s, which a supervisor must answer' "$cause"; return 1 ;;
  esac
  if until=$(status_paused_until "$line") && [ -n "$until" ] && [ "$until" -le "$NOW" ]; then
    printf 'the pause names a clearing time that has passed'; return 1
  fi
  return 0
}

# annotation_lines <status-key>: the drain's unread status lines for the file, oldest first.
annotation_lines() {
  [ -n "$ANNOTATIONS" ] && [ -r "$ANNOTATIONS" ] || return 0
  awk -v want=": $1: " '
    index($0, "wake annotation:") == 1 {
      i = index($0, want)
      if (i > 0) print substr($0, i + length(want))
    }
  ' "$ANNOTATIONS"
}

classify_signal() { # <key> <payload>
  local key=$1 payload=$2 id line lines newest word why verb
  case "$payload" in needs-decision:*) verdict ACTION "decision-owned signal"; return ;; esac
  if ! fm_wake_status_key_map "$key"; then verdict ACTION "not a status file signal"; return; fi
  if [ "$FM_WAKE_STATUS_HISTORICAL" = true ]; then
    verdict ACTION "turn-ended row, read the task's status"; return
  fi
  id=${FM_WAKE_STATUS_KEY%.status}
  lines=$(annotation_lines "$FM_WAKE_STATUS_KEY")
  if [ -n "$lines" ]; then
    newest=${lines##*$'\n'}
    status_line_verb "$newest" verb
    verdict ACTION "unread $verb line: $(short "$newest" 90)"; return
  fi
  newest=$(last_status_line "$STATE/$FM_WAKE_STATUS_KEY")
  if [ -z "$newest" ]; then verdict ACTION "no status line to judge"; return; fi
  if why=$(pause_line_ok "$newest"); then :; else verdict ACTION "$why"; return; fi
  if ! line=$(crew_state_line "$id") || [ -z "$line" ]; then
    verdict ACTION "crew state unreadable"; return
  fi
  word=$(crew_state_word "$line")
  if [ "$word" != paused ]; then verdict ACTION "$line"; return; fi
  verdict no-action "declared pause already presented; $line"
}

classify_stale() { # <key> <payload>
  local key=$1 payload=$2 task line word newest why
  task=$(window_to_task "$key" "$STATE")
  if [ -z "$task" ] || [ ! -e "$STATE/$task.meta" ]; then verdict ACTION "no task record for $key"; return; fi
  case "$payload" in
    *"declared clearing time has passed"*) verdict ACTION "the declared pause time has passed, confirm the wait cleared"; return ;;
  esac
  if ! line=$(crew_state_line "$task") || [ -z "$line" ]; then verdict ACTION "crew state unreadable"; return; fi
  word=$(crew_state_word "$line")
  if [ "$word" != paused ]; then verdict ACTION "$line"; return; fi
  newest=$(last_status_line "$STATE/$task.status")
  if why=$(pause_line_ok "$newest"); then :; else verdict ACTION "$why"; return; fi
  verdict no-action "declared pause, recheck cadence only; $line"
}

classify_check() { # <key> <payload>
  local key=$1 payload=$2 id url officer line
  if [[ "$payload" =~ ^check:\ merge\ landed:\ ([A-Za-z0-9._-]+)\ (https?://[^[:space:]]+) ]]; then
    id=${BASH_REMATCH[1]}; url=${BASH_REMATCH[2]}
    if [ -e "$STATE/$id.meta" ]; then
      line=$(crew_state_line "$id") || line="crew state unreadable"
      verdict ACTION "task $id is still recorded, so this wake triggers its teardown, backlog move and re-evaluation; $line"
    else
      verdict no-action "task $id is already torn down (no task record); $url"
    fi
    return
  fi
  if [[ "$payload" =~ ^check:\ [^[:space:]]*/office-lane-([a-z0-9-]+)\.check\.sh:\ office\ [a-z0-9-]+:\ ([a-z0-9-]+)\ digest\ [0-9T-]{10,13}\;\ [0-9]+\ start\ request\(s\)\ delivered\ to\ this\ office\'s\ inbox$ ]]; then
    officer=${BASH_REMATCH[2]}
    if fm_run_timed 20 "$OFFICE" starts-handled "$officer" >/dev/null 2>&1; then
      verdict no-action "every $officer start request in the digest is already acknowledged"
    else
      verdict ACTION "the $officer start request(s) are not all acknowledged yet"
    fi
    return
  fi
  verdict ACTION "$(short "$payload" 100)"
}

total=0
actions=0
while IFS=$'\t' read -r _epoch seq kind key payload; do
  [ -n "$seq" ] || continue
  case "$kind" in
    signal) classify_signal "$key" "$payload"; subject=$key ;;
    stale) classify_stale "$key" "$payload"; subject=$key ;;
    check) classify_check "$key" "$payload"; subject=$key ;;
    heartbeat) verdict ACTION "fleet review"; subject=fleet ;;
    *) verdict ACTION "unrecognised row kind"; subject=$key ;;
  esac
  total=$((total + 1))
  [ "$VERDICT" = no-action ] || actions=$((actions + 1))
  printf '#%s %s %s: %s - %s\n' "$seq" "$kind" "$subject" "$VERDICT" "$(short "$DETAIL" 160)"
done
[ "$total" -gt 0 ] && [ "$actions" -eq 0 ]
