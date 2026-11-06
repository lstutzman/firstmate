# shellcheck shell=bash
# fm-claude-limit-lib.sh - the ONE owner of what Claude Code's usage-limit
# prompt says on a pane: whether the pane is parked on it, which reset time it
# states, and the epoch that time means. bin/fm-limit-resume.sh owns every
# decision and keystroke built on that.
#
# Adapted from nikzorz/firstmate (MIT licence, "Copyright (c) 2026 Kun Chen" as
# carried in that repository's LICENSE, the same notice as this repository's),
# commit 100698b12 "detect and recover a crewmate stalled on Claude's
# usage-limit prompt" (bin/fm-claude-limit-lib.sh). What changed here: the
# prompt signature lives in fm-composer-lib.sh beside the other recognised
# dialogs, and the "has the window reset" verdict comes from the reset time the
# prompt itself states rather than from a quota read.
#
# WHY THIS EXISTS (the fork's incident, 2026-07-29): three of four live
# crewmates exhausted the account usage limit mid-turn and stopped on Claude
# Code's interactive choice prompt. That prompt waits for a human indefinitely,
# including long after the window clears, and the pane it leaves is idle with no
# error - indistinguishable from a crew between turns. They sat about 8.7 hours
# after the five-hour window had reset. Recovery was one Escape plus one steer.
#
# SCOPE: claude-specific on purpose. No other verified harness has been observed
# presenting a blocking usage-limit prompt, and harness-adapters is where
# per-harness knowledge belongs, so nothing here generalises to "any harness
# dialog". Callers gate on the recorded harness=claude.
#
# EVERYTHING HERE FAILS CLOSED. An unreadable pane, an uncertain match, an
# unparseable or unknown-zone reset time reports "no match" or failure rather
# than a guess, because a false positive sends keystrokes into a live
# crewmate's pane - worse than the stall it would fix.
#
# THE STATED RESET TIME. Claude Code 2.1.319 renders it (function aP in the
# binary) as a clock time like `6:40pm` when the reset is within a day, or
# `Nov 9, 3pm` (with `, 2027` when the year differs) beyond that, each with a
# trailing ` (Zone/Name)` when it prints the zone. It appears in the limit line
# ("... resets 6:40pm") and in the menu row "Wait here, then continue
# automatically at 6:40pm". The older text "Your limit will reset at 6:40pm" is
# read the same way. docs/verification/supervision.md "Claude usage-limit
# recovery" records how that was checked and what was not.

# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-composer-lib.sh"

# Pane tail (lines) a caller should capture. Large enough to hold the whole
# prompt plus the limit line above it, small enough to stay cheap.
FM_CLAUDE_LIMIT_SCAN_LINES_DEFAULT=40

# Seconds past the stated reset before anything is sent. The prompt prints the
# reset to the minute, so the true instant can sit up to a minute after the
# printed one; this keeps "never before the stated reset" true despite that and
# small clock skew.
FM_CLAUDE_LIMIT_RESET_MARGIN_DEFAULT=60

# fm_claude_limit_scan_lines: the pane tail every capturing caller should ask
# for, with the operator override read and validated here rather than at each
# call site.
fm_claude_limit_scan_lines() {  # -> positive integer
  local n=${FM_CLAUDE_LIMIT_SCAN_LINES:-$FM_CLAUDE_LIMIT_SCAN_LINES_DEFAULT}
  case "$n" in ''|*[!0-9]*|0) n=$FM_CLAUDE_LIMIT_SCAN_LINES_DEFAULT ;; esac
  printf '%s' "$n"
}

# fm_claude_limit_reset_margin: seconds to wait past the stated reset.
fm_claude_limit_reset_margin() {  # -> non-negative integer
  local n=${FM_CLAUDE_LIMIT_RESET_MARGIN:-$FM_CLAUDE_LIMIT_RESET_MARGIN_DEFAULT}
  case "$n" in ''|*[!0-9]*) n=$FM_CLAUDE_LIMIT_RESET_MARGIN_DEFAULT ;; esac
  printf '%s' "$((10#$n))"
}

# fm_claude_limit_dialog_match: 0 when the text on stdin is a pane parked on the
# usage-limit prompt, 1 otherwise (including empty input). Pure text
# classification delegated to the one dialog recogniser; no pane or tool access.
fm_claude_limit_dialog_match() {  # stdin: plain pane capture
  local text name
  IFS= read -r -d '' text || true
  [ -n "$text" ] || return 1
  name=$(fm_composer_blocking_dialog "$text") || return 1
  [ "$name" = "$FM_COMPOSER_CLAUDE_LIMIT_DIALOG_NAME" ]
}

# The time Claude prints: an optional `Mon D[, YYYY], ` date, a 12-hour clock,
# and an optional ` (Zone)`. One ERE for both extraction and parsing.
_FM_CLAUDE_LIMIT_TIME_ERE='(([A-Z][a-z]{2} [0-9]{1,2}(, [0-9]{4})?, )?(1[0-2]|[1-9])(:[0-5][0-9])?(am|pm)( \([A-Za-z0-9_+/-]+\))?)'

# fm_claude_limit_reset_phrase: print the LAST stated reset time on the pane on
# stdin (the one nearest the prompt), e.g. `6:40pm (Europe/London)`. Returns 1
# when the pane states none. The anchors are the three wordings above; a time
# that merely appears in prose without one of them is not a stated reset.
fm_claude_limit_reset_phrase() {  # stdin: plain pane capture
  local text found
  IFS= read -r -d '' text || true
  [ -n "$text" ] || return 1
  text=$(printf '%s\n' "$text" | fm_composer_strip_ansi)
  fm_composer_normalize_spaces_var text
  found=$(printf '%s\n' "$text" \
    | LC_ALL=C grep -oE "(resets?( at)?|continue automatically at) $_FM_CLAUDE_LIMIT_TIME_ERE" \
    | tail -1) || return 1
  [ -n "$found" ] || return 1
  found=$(printf '%s' "$found" \
    | LC_ALL=C sed -E 's/^(resets?( at)?|continue automatically at) //')
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

# _fm_claude_limit_fmt <tz-or-empty> <epoch> <date-format> -> text. GNU first,
# then BSD, so one spelling serves Linux and macOS.
_fm_claude_limit_fmt() {
  local tz=$1 epoch=$2 fmt=$3
  if [ -n "$tz" ]; then
    TZ=$tz date -d "@$epoch" "+$fmt" 2>/dev/null || TZ=$tz date -r "$epoch" "+$fmt" 2>/dev/null
  else
    date -d "@$epoch" "+$fmt" 2>/dev/null || date -r "$epoch" "+$fmt" 2>/dev/null
  fi
}

# _fm_claude_limit_local_epoch <tz-or-empty> <YYYY-MM-DD> <HH> <MM> -> epoch of
# that wall-clock time in the zone (the machine's own zone when empty).
_fm_claude_limit_local_epoch() {
  local tz=$1 day=$2 hh=$3 mm=$4 out
  if [ -n "$tz" ]; then
    out=$(TZ=$tz date -j -f '%Y-%m-%d %H:%M' "$day $hh:$mm" +%s 2>/dev/null) \
      || out=$(TZ=$tz date -d "$day $hh:$mm" +%s 2>/dev/null) || return 1
  else
    out=$(date -j -f '%Y-%m-%d %H:%M' "$day $hh:$mm" +%s 2>/dev/null) \
      || out=$(date -d "$day $hh:$mm" +%s 2>/dev/null) || return 1
  fi
  case "$out" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$out"
}

# fm_claude_limit_reset_epoch <phrase> <since-epoch>: the epoch the stated reset
# means, or failure.
#
# A clock time with no date means "the next such time after the prompt was
# drawn", and the pane does not say when that was. <since-epoch> is the caller's
# lower bound on it (the moment the pane last changed is the best one), and the
# answer is the FIRST such clock time at or after it. A bound that is too late
# can only push the answer later, never earlier, so a stall noticed late waits
# longer rather than resuming before the stated reset. A dated phrase is taken
# at its date, in the year it names, else the current year, rolled to the next
# year only when that would put it more than half a year before <since-epoch>.
#
# Fails (returns 1, prints nothing) for a phrase it cannot read, an hour or
# minute out of range, or a zone name with no zoneinfo entry: an unknown zone
# silently reads as UTC, which could be hours early.
fm_claude_limit_reset_epoch() {  # <phrase> <since-epoch>
  local phrase=${1-} since=${2-} body tz='' hh mm ap mon day year='' d noon cand i month_n
  case "$since" in ''|*[!0-9]*) return 1 ;; esac
  if [[ $phrase =~ ^(.*)\ \(([A-Za-z0-9_+/-]+)\)$ ]]; then
    body=${BASH_REMATCH[1]}
    tz=${BASH_REMATCH[2]}
    case "$tz" in *..*|/*) return 1 ;; esac
    [ -f "/usr/share/zoneinfo/$tz" ] || return 1
  else
    body=$phrase
  fi
  [[ $body =~ ([0-9]{1,2})(:([0-9]{2}))?(am|pm)$ ]] || return 1
  hh=$((10#${BASH_REMATCH[1]}))
  mm=$((10#${BASH_REMATCH[3]:-00}))
  ap=${BASH_REMATCH[4]}
  [ "$hh" -ge 1 ] && [ "$hh" -le 12 ] && [ "$mm" -le 59 ] || return 1
  [ "$hh" -ne 12 ] || hh=0
  [ "$ap" != pm ] || hh=$((hh + 12))
  if [[ $body =~ ^([A-Z][a-z]{2})\ ([0-9]{1,2})(,\ ([0-9]{4}))?,\  ]]; then
    mon=${BASH_REMATCH[1]}
    day=$((10#${BASH_REMATCH[2]}))
    year=${BASH_REMATCH[4]}
    case "$mon" in
      Jan) month_n=01 ;; Feb) month_n=02 ;; Mar) month_n=03 ;; Apr) month_n=04 ;;
      May) month_n=05 ;; Jun) month_n=06 ;; Jul) month_n=07 ;; Aug) month_n=08 ;;
      Sep) month_n=09 ;; Oct) month_n=10 ;; Nov) month_n=11 ;; Dec) month_n=12 ;;
      *) return 1 ;;
    esac
    [ "$day" -ge 1 ] && [ "$day" -le 31 ] || return 1
    if [ -n "$year" ]; then
      _fm_claude_limit_dated_epoch "$tz" "$year" "$month_n" "$day" "$hh" "$mm"
      return $?
    fi
    year=$(_fm_claude_limit_fmt "$tz" "$since" %Y) || return 1
    cand=$(_fm_claude_limit_dated_epoch "$tz" "$year" "$month_n" "$day" "$hh" "$mm") || return 1
    if [ "$cand" -lt $((since - 15552000)) ]; then
      cand=$(_fm_claude_limit_dated_epoch "$tz" "$((year + 1))" "$month_n" "$day" "$hh" "$mm") || return 1
    fi
    printf '%s' "$cand"
    return 0
  fi
  # Clock time only: walk forward day by day from the day of <since-epoch>,
  # anchoring each step at noon so a daylight-saving shift cannot skip or
  # repeat a calendar day.
  d=$(_fm_claude_limit_fmt "$tz" "$since" %Y-%m-%d) || return 1
  noon=$(_fm_claude_limit_local_epoch "$tz" "$d" 12 00) || return 1
  i=0
  while [ "$i" -le 2 ]; do
    d=$(_fm_claude_limit_fmt "$tz" "$((noon + i * 86400))" %Y-%m-%d) || return 1
    cand=$(_fm_claude_limit_local_epoch "$tz" "$d" "$(printf '%02d' "$hh")" "$(printf '%02d' "$mm")") || return 1
    if [ "$cand" -ge "$since" ]; then
      printf '%s' "$cand"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# _fm_claude_limit_dated_epoch <tz> <YYYY> <MM> <D> <h24> <min>
_fm_claude_limit_dated_epoch() {
  local tz=$1 year=$2 month=$3 day=$4 hh=$5 mm=$6
  _fm_claude_limit_local_epoch "$tz" "$(printf '%s-%s-%02d' "$year" "$month" "$day")" \
    "$(printf '%02d' "$hh")" "$(printf '%02d' "$mm")"
}
