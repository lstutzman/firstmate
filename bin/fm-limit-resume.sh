#!/usr/bin/env bash
# fm-limit-resume.sh - recover ONE crewmate stalled on Claude Code's usage-limit
# prompt, but only after the reset time that prompt states.
#
# Usage: FM_HOME=<firstmate home> bin/fm-limit-resume.sh [--check] [--since <epoch>] <task-id>
#
#   --check          report the verdict and exit without sending or recording
#                    anything.
#   --since <epoch>  a bound at or after the moment the prompt was drawn, for a
#                    stated clock time with no date. The watcher passes the time
#                    it first saw the pane unchanged on the prompt; without it
#                    the bound is now. A bound that is too late only delays the
#                    answer, never advances it.
#
# Exit codes: 0 recovered, the timed wait was recorded, or --check reported a
#               verdict it could establish.
#             1 refused - the condition is not proven, or a step did not land.
#             2 usage error.
#
# Adapted from nikzorz/firstmate (MIT licence, "Copyright (c) 2026 Kun Chen" as
# carried in that repository's LICENSE, the same notice as this repository's),
# commit 100698b12, bin/fm-limit-resume.sh. Changed here: the resume gate is the
# reset time the prompt states instead of a quota read; the Escape goes through
# bin/fm-control.sh (the lifecycle control plane) instead of a backend key call;
# the wait is recorded with an `until` time so the watcher rechecks when it
# clears; and a second recovery for the same stated reset is refused for a while.
#
# WHY (the fork's incident, 2026-07-29): a crew that exhausts the account usage
# limit mid-turn stops on an interactive choice prompt that waits for a human
# indefinitely. Three crews sat about 8.7 hours after the five-hour window had
# reset. Manual recovery was one Escape plus one steer; this is that, with the
# proofs.
#
# WHAT IT WILL NOT DO. It never tears down, restarts, rebases, or discards work:
# the crewmate's own agent, worktree, commits, and any in-flight validation run
# are left exactly as they are, and recovery is only a dismissed prompt plus a
# resume instruction. It also never guesses:
#
#   1. The task must record `harness=claude` and a local endpoint. No other
#      verified harness has been observed presenting this prompt.
#   2. The viewport is captured and matched FRESH here, immediately before any
#      key is sent - a stale verdict from an earlier read is never sufficient,
#      because the crew may have moved on since. A backend with no verified
#      viewport read is refused.
#   3. The prompt must STATE a reset time this script can read (a known zone, an
#      hour and minute in range), and the current time must be past that time
#      plus FM_CLAUDE_LIMIT_RESET_MARGIN seconds (default 60). Elapsed time,
#      the window length, and a guess never stand in for it. A clock time with
#      no date is its first occurrence at or after --since, never earlier:
#      passed means recover now, ahead means a wait until it. See
#      bin/fm-claude-limit-lib.sh for the wordings read and that rule.
#   4. The same stated reset is not recovered twice within
#      FM_LIMIT_RESUME_COOLDOWN seconds (default 1800): a prompt that returns
#      with the same reset means the window had not reset, and sending Escape
#      again would only loop. This is checked before any wait is recorded, so
#      such a prompt is refused for inspection rather than absorbed as a pause.
#   5. The Escape goes through `fm-control.sh <id> interrupt`, never a raw key.
#   6. After Escape, the prompt must be PROVABLY gone on a re-read before the
#      steer is sent: a capture that succeeded, was non-empty, and did not match.
#      A prompt still showing stops the run rather than escalating keys, and a
#      pane that cannot be read proves nothing and stops it too.
#   7. The steer goes through fm-send.sh, the data plane.
#
# An unreadable pane, an uncertain match, or an unreadable reset time refuses
# and reports, because sending keys into a live crewmate's pane speculatively is
# worse than the stall it would fix.
#
# BEFORE THE RESET it records the wait with the fleet's `paused:` vocabulary and
# an `until <UTC time>` taken from the stated reset, on the task's status file.
# The one exception is a clock time with no date whose resume is more than five
# hours out: that records nothing and sends nothing, so the pane keeps reaching
# the supervisor as an ordinary stale wake naming the prompt and its stated
# reset, because a late bound may have pushed it a day out and a day-long
# declared pause would hide that. A dated reset is unambiguous and is declared
# however far out it is.
# From that point the ordinary declared-pause handling in the watcher and the
# away-mode daemon applies: the idle pane is absorbed and rechecked when the
# declared time arrives, instead of aging toward a possible-wedge escalation. The
# append is idempotent for the same stated reset, so re-running this on every
# recheck stacks no duplicate lines.
#
# That wait is OPENED and CLOSED here, as one contract. The crew never learns the
# line exists, so nothing else would close it: a `paused:` line left standing
# keeps a recovered crew on the declared-pause cadence when it should be back on
# the wedge cadence. So the recover path closes it, and only its OWN line,
# identified exactly as the idempotent open identifies it.
#
# THE STEER deliberately does not assert where the crew stopped. In the fork's
# incident the interrupted validation run had lost custody and the crew correctly
# started a fresh one; a steer that had asserted a remembered position would have
# been wrong. It tells the crew to re-read its own current state first.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034 # read by the sourced libraries
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Refuse before any fleet mutation: a no-mistakes gate agent must never steer a
# crewmate (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-limit-resume refuses to resolve a task without an explicit firstmate home" >&2
  exit 2
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing for FM_HOME '$FM_HOME'" >&2; exit 2; }

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-claude-limit-lib.sh
. "$SCRIPT_DIR/fm-claude-limit-lib.sh"

USAGE="usage: fm-limit-resume.sh [--check] [--since <epoch>] <task-id>"
CHECK_ONLY=0
SINCE=
ID=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --since)
      [ "$#" -ge 2 ] || { echo "$USAGE" >&2; exit 2; }
      SINCE=$2
      shift
      ;;
    --*) echo "$USAGE" >&2; exit 2 ;;
    *)
      [ -z "$ID" ] || { echo "$USAGE" >&2; exit 2; }
      ID=$1
      ;;
  esac
  shift
done
[ -n "$ID" ] || { echo "$USAGE" >&2; exit 2; }
case "$SINCE" in
  ''|*[!0-9]*) [ -z "$SINCE" ] || { echo "usage: --since takes an epoch in seconds" >&2; exit 2; } ;;
esac

refuse() {  # <message>
  echo "refused: $1" >&2
  exit 1
}

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
[ -f "$META" ] || refuse "no metadata for task '$ID' in $STATE"

HARNESS=$(fm_meta_get "$META" harness)
if [ "$HARNESS" != claude ]; then
  refuse "task '$ID' records harness='${HARNESS:-none}'; the usage-limit prompt is claude-specific"
fi
[ -z "$(fm_meta_get "$META" remote_host)" ] \
  || refuse "task '$ID' is placed on a remote host; this script reads and drives local endpoints only"
fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
TARGET=$FM_BACKEND_VALIDATED_TARGET
LABEL="fm-$ID"
fm_backend_visible_capture_supported "$BACKEND" \
  || refuse "the $BACKEND backend has no verified viewport read, so a fresh match cannot be proven"

PANE=
PROMPT_STATE=

# What a FRESH read of the live viewport proves, as three distinct outcomes:
#   showing    - the pane is parked on the usage-limit prompt right now;
#   absent     - the capture succeeded, was non-empty, and did not match, so the
#                prompt is provably not there;
#   unreadable - the capture failed or came back empty, which proves nothing.
# The two callers need OPPOSITE proofs, and conflating them is what would let an
# unreadable pane authorize a keystroke: the entry gate requires `showing`, and
# the post-Escape dismissal proof requires `absent` specifically.
prompt_state() {  # sets PROMPT_STATE and PANE
  PANE=$(fm_backend_visible_capture "$BACKEND" "$TARGET" "$LABEL" 2>/dev/null) \
    || { PANE=; PROMPT_STATE=unreadable; return 0; }
  [ -n "$PANE" ] || { PROMPT_STATE=unreadable; return 0; }
  PANE=$(printf '%s\n' "$PANE" | tail -n 40)
  if printf '%s\n' "$PANE" | fm_claude_limit_dialog_match; then
    PROMPT_STATE=showing
  else
    PROMPT_STATE=absent
  fi
  return 0
}

prompt_state
[ "$PROMPT_STATE" = showing ] \
  || refuse "$ID is not showing the claude usage-limit prompt (pane unreadable, or the crew has moved on)"
PHRASE=$(printf '%s\n' "$PANE" | fm_claude_limit_reset_phrase) \
  || refuse "$ID is parked on the claude usage-limit prompt but the pane states no reset time this script can read; not sending keys"

NOW=$(date +%s)
case "$NOW" in ''|*[!0-9]*) refuse "the clock could not be read" ;; esac
MARGIN=$(fm_claude_limit_reset_margin)

# A prompt back with the very reset we already recovered from means the window
# had not reset; another Escape would loop, and recording a wait would hide it.
COOLDOWN=${FM_LIMIT_RESUME_COOLDOWN:-1800}
case "$COOLDOWN" in ''|*[!0-9]*) COOLDOWN=1800 ;; esac
MARKER="$STATE/.limit-resumed-$ID"
if [ -f "$MARKER" ]; then
  IFS=$'\t' read -r PRIOR_AT PRIOR_PHRASE < "$MARKER" || true
  case "${PRIOR_AT:-}" in ''|*[!0-9]*) PRIOR_AT= ;; esac
  if [ -n "$PRIOR_AT" ] && [ "${PRIOR_PHRASE:-}" = "$PHRASE" ] && [ $((NOW - PRIOR_AT)) -lt "$COOLDOWN" ]; then
    refuse "$ID already recovered from this stated reset ($PHRASE) $((NOW - PRIOR_AT))s ago and the prompt is back; the window had not reset, left untouched for inspection"
  fi
fi

# The wait this script recorded earlier for THIS stated reset is the stable
# answer: the epoch it names does not move as the clock does. Anything else is
# computed from the phrase.
PAUSE_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
PAUSE_HEAD="claude usage limit reached; resumes after the stated reset ($PHRASE); until "
LAST=$(last_status_line "$LOG")
OWNED_PAUSE=0
if status_is_paused "$LAST"; then
  case "${LAST#*:}" in
    " $PAUSE_HEAD"*) OWNED_PAUSE=1 ;;
  esac
fi
if [ "$OWNED_PAUSE" = 1 ] && RESUME_AT=$(status_paused_until "$LAST"); then
  :
else
  OWNED_PAUSE=0
  REF=${SINCE:-$NOW}
  [ "$REF" -le "$NOW" ] || REF=$NOW
  RESET_AT=$(fm_claude_limit_reset_epoch "$PHRASE" "$REF") \
    || refuse "$ID states the reset time '$PHRASE', which this script cannot place (unknown zone or unreadable time); not sending keys"
  # Round the earliest resume up to the minute: the declared `until` has minute
  # resolution, and the watcher must never recheck before it.
  RESUME_AT=$(( (RESET_AT + MARGIN + 59) / 60 * 60 ))
fi
RESUME_ISO=$(_fm_claude_limit_fmt UTC "$RESUME_AT" %Y-%m-%dT%H:%MZ) \
  || refuse "the resume time could not be formatted"
PAUSE_NOTE="$PAUSE_HEAD$RESUME_ISO"

# Record the timed wait once, with the fleet's own pause vocabulary. Idempotent:
# a status stream whose last event is already this pause is left alone, so
# repeated rechecks add no duplicate wake-triggering lines.
append_status() {  # <line>
  local rc=0
  fm_wake_status_append_self_announced "$STATE" "$LOG" "$1" || rc=$?
  [ "$rc" -ne 2 ] || return 1
  [ ! -e "$CONFIG/fleet-ledger" ] \
    || "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$LOG" >/dev/null 2>&1 || true
  return 0
}
record_pause() {
  [ "$OWNED_PAUSE" = 0 ] || return 0
  append_status "$PAUSE_VERB [cause=external]: $PAUSE_NOTE" \
    || echo "warning: could not record the wait for $ID in $LOG" >&2
  return 0
}

# Close that wait once recovery has landed, by appending the fleet's ordinary
# non-paused progress verb so the crew's last event stops satisfying
# status_is_paused and the wedge cadence applies again. Ownership is the same
# exact-match identity the idempotent open uses: a `paused:` line the CREW wrote
# for its own reason still means what it says and is left alone. Nothing to
# close is a no-op, and a close can never fail the recovery it follows.
RESUME_NOTE="claude usage limit window reset; prompt dismissed and the crew re-steered"
close_pause() {
  [ "$OWNED_PAUSE" = 1 ] || return 0
  append_status "working: $RESUME_NOTE" 2>/dev/null || true
  return 0
}

if [ "$NOW" -lt "$RESUME_AT" ]; then
  if [ "$CHECK_ONLY" = 1 ]; then
    echo "$ID: parked on the claude usage-limit prompt; the stated reset ($PHRASE) is not reached, resumable after $RESUME_ISO (bounded external wait)"
    exit 0
  fi
  if [ "$OWNED_PAUSE" = 0 ] && ! [[ $PHRASE =~ ^[A-Z][a-z]{2}\ [0-9] ]] && [ $((RESUME_AT - NOW)) -gt 18000 ]; then
    echo "$ID: the stated clock-time reset ($PHRASE) is not reached and is more than five hours out ($RESUME_ISO); recorded no wait and sent nothing, so the stall stays visible"
    exit 0
  fi
  record_pause
  echo "$ID: the stated reset ($PHRASE) is not reached; recorded the wait until $RESUME_ISO and sent nothing"
  exit 0
fi

if [ "$CHECK_ONLY" = 1 ]; then
  echo "$ID: parked on the claude usage-limit prompt and the stated reset ($PHRASE) has passed; recoverable"
  exit 0
fi

if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$ID" interrupt >/dev/null; then
  refuse "could not deliver the interrupt to $ID through the control plane"
fi
printf '%s\t%s\n' "$NOW" "$PHRASE" > "$MARKER" 2>/dev/null || true

# Settle, then require positive proof the prompt is GONE before steering. A
# prompt still showing means the dismissal did not take, and escalating more keys
# blind is exactly what this script exists to avoid. A malformed settle value
# falls back to the default rather than reaching sleep: aborting here, after
# Escape has already been sent, would leave the crew dismissed but unsteered with
# none of the refusals below reported.
SETTLE_DEFAULT=1
SETTLE=${FM_LIMIT_RESUME_SETTLE:-$SETTLE_DEFAULT}
[[ $SETTLE =~ ^[0-9]+(\.[0-9]+)?$ ]] || SETTLE=$SETTLE_DEFAULT
[ "$SETTLE" = 0 ] || sleep "$SETTLE"
prompt_state
case "$PROMPT_STATE" in
  absent) ;;
  showing)
    refuse "$ID still shows the claude usage-limit prompt after Escape; left untouched for inspection"
    ;;
  *)
    refuse "$ID's pane could not be read after Escape, so the prompt's dismissal is unproven; left untouched for inspection"
    ;;
esac

STEER="The claude usage limit that stalled you has reset. Do not assume where you stopped: re-read your own current state first, including whether your validation run still exists and belongs to your current commit, then continue from what you actually find."

if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$ID" "$STEER" >/dev/null; then
  refuse "dismissed the prompt on $ID but the resume instruction did not land; steer it by hand"
fi

close_pause

echo "$ID: dismissed the claude usage-limit prompt after its stated reset ($PHRASE) and sent the resume instruction"
