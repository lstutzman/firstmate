#!/usr/bin/env bash
# fm-pending-reply-sweep.sh - settle or list escalated parent pending-reply records.
#
# Usage: FM_HOME=<home> fm-pending-reply-sweep.sh [--apply [--key <key>[,<key>...]]...]
#
# An escalated record (bin/fm-pending-reply-lib.sh) stays escalated until a
# correlated report lands, and the watcher re-checks it on every poll. This
# sweep reads every record under state/pending-replies/ in phase=escalated and
# gives each one verdict; it never guesses whether a free-text request was done.
# Verdicts:
#   settled    its escalation decision was already closed in its parent status
#              log in the owning library's vocabulary and is no longer open
#              (fm_pending_reply_closed_escalation_line), for example by an
#              operator fm-send --resolve-key that predates the record close;
#   review     its decision is still open. Listed under its own heading with
#              the request summary and a reason - corr-line-unmatched (a line
#              in its parent status names the corr= token but does not resolve
#              the request), undelivered (delivery was never confirmed, so the
#              owner may still resend under the same correlation), prs (the
#              request names PR URLs, shown with their current state), or none;
#   unproven   its decision is neither open nor closed in that vocabulary
#              (for example the escalation line was never written), its
#              decision is closed but its delivery was never confirmed (the
#              owner may still resend under that correlation), or a
#              backlog-handoff wake still names it; never changed here.
# Every other phase is counted and never touched; fm-retention.sh prunes old
# resolved records.
#
# Default is a dry run: one line per record, the review list, and totals;
# nothing changed. --apply settles every settled record (phase=resolved,
# resolved_via from its close line). --key (repeatable, or a comma list; needs
# --apply) also closes exactly the listed pending-reply-<corr> keys, each only if
# it is still a review record at apply time, its delivery was confirmed, and
# its parent status log lies in this home's state directory; any other listed key is refused with its reason
# and makes the exit status 1. A keyed close appends one line to the record's
# parent status log, never a message to the mate (a sent message would open a
# new reply expectation):
#   resolved [key=pending-reply-<corr>] [at=<epoch>]: pending-reply-resolved: task=<id> pending-reply-id=<corr> via=sweep
# stamped and announced by fm_wake_status_append_self_announced and recorded in
# the fleet ledger when config/fleet-ledger exists, then settles the record. A
# key that is still open after its append is reported and makes the exit status 1.
#
# Environment: FM_HOME (required), FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE.
# Exit: 0 done, 1 a close did not take effect or a --key was refused,
# 2 usage or setup error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: FM_HOME=<home> fm-pending-reply-sweep.sh [--apply [--key <key>[,<key>...]]...]" >&2; exit 2; }
APPLY=0 KEYS=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --key) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; KEYS="$KEYS,$2"; shift ;;
    -h | --help) sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) usage ;;
  esac
  shift
done
KEYS="$KEYS,"
[ "$KEYS" = , ] || [ "$APPLY" -eq 1 ] || usage

if [ -z "${FM_HOME:-}" ] || [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME must name an existing firstmate home" >&2
  exit 2
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 2; }

# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

CLOSE_MAX=$((FM_LINE_CAP_DEFAULT - $(status_stamp_width)))

key_open() {  # <status-file> <key>
  case $'\n'"$(status_open_decisions "$1")" in *$'\n'"$2"$'\t'*) return 0 ;; esac
  return 1
}
listed() { case "$KEYS" in *",$1,"*) return 0 ;; esac; return 1; }
HANDLED=,
refused=0
refuse() {  # <key> <reason>
  HANDLED="$HANDLED$1,"
  echo "error: --key '$1' refused: $2" >&2
  refused=$((refused + 1))
}

# Print "<url>=<STATE>" for each PR, "unreadable" when gh cannot answer.
pr_states() {  # <comma-separated-urls>
  local url out='' state
  for url in ${1//,/ }; do
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || state=unreadable
    case "$state" in MERGED | CLOSED | OPEN) ;; *) state=unreadable ;; esac
    out="$out${out:+,}$url=$state"
  done
  printf '%s' "$out"
}

escalated=0 settled=0 keyed=0 review=0 unproven=0 skipped=0 failed=0
REVIEW_OUT=''

for rec in "$STATE"/pending-replies/*; do
  [ -f "$rec" ] || continue
  corr=${rec##*/}
  printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' || continue
  if [ "$(fm_pending_reply_get "$rec" phase)" != escalated ]; then
    skipped=$((skipped + 1))
    continue
  fi
  escalated=$((escalated + 1))
  key=$(fm_pending_reply_escalation_key "$corr")
  task=$(fm_pending_reply_get "$rec" task_id)
  parent_status=$(fm_pending_reply_get "$rec" parent_status)
  line="home=$FM_HOME task=$task key=$key"

  if close=$(fm_pending_reply_closed_escalation_line "$STATE" "$corr"); then
    via=$(printf '%s' "$close" | sed -n 's/.* via=\([^ ]*\).*/\1/p')
    echo "$line verdict=settled via=${via:-unknown}"
    HANDLED="$HANDLED$key,"
    settled=$((settled + 1))
    [ "$APPLY" -eq 1 ] || continue
    fm_pending_reply_settle_closed_escalation "$STATE" "$corr" "${via:-unknown}" || {
      echo "error: record $corr could not be settled" >&2
      failed=$((failed + 1))
    }
    continue
  fi

  if fm_pending_reply_wake_marker_names "$STATE" "$corr" || ! key_open "$parent_status" "$key"; then
    echo "$line verdict=unproven"
    ! listed "$key" || refuse "$key" "verdict is unproven"
    unproven=$((unproven + 1))
    continue
  fi

  reason=none
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  prs=$(fm_pending_reply_get "$rec" request_prs)
  summary=$(fm_pending_reply_get "$rec" request_summary)
  [ -n "$prs" ] || prs=$(printf '%s\n' "$summary" | grep -oE "$FM_PENDING_REPLY_PR_URL_RE" | awk '!seen[$0]++' | paste -sd, - || true)
  if grep -qaF -- "$(fm_pending_reply_corr_token "$corr")" "$parent_status" 2>/dev/null; then
    reason='corr-line-unmatched'
  elif [ -z "$delivered" ]; then
    reason=undelivered
  elif [ -n "$prs" ]; then
    reason='prs'
  fi
  [ -z "$prs" ] || prs=" prs=$(pr_states "$prs")"

  if [ "$APPLY" -eq 0 ] || ! listed "$key"; then
    note=''
    [ -n "$delivered" ] || note=' not-closable: its owner may still resend under the same correlation, so --apply --key refuses it;'
    REVIEW_OUT="$REVIEW_OUT$line verdict=review reason=$reason$prs$note request=${summary:0:160}"$'\n'
    review=$((review + 1))
    continue
  fi
  HANDLED="$HANDLED$key,"
  if ! [ "${parent_status%/*}" -ef "$STATE" ]; then
    refuse "$key" "its parent status $parent_status is outside $STATE"
    continue
  fi
  if [ -z "$delivered" ]; then
    refuse "$key" "delivery was never confirmed"
    continue
  fi
  fm_cap_line_var "resolved [key=$key]: $(fm_pending_reply_resolved_note "$task" "$corr" sweep)" "$CLOSE_MAX"
  rc=0
  fm_wake_status_append_self_announced "$STATE" "$parent_status" "$FM_LINE_CAP_LINE" || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "error: could not append to $parent_status" >&2
    failed=$((failed + 1))
    continue
  fi
  [ ! -e "$CONFIG/fleet-ledger" ] \
    || "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$parent_status" >/dev/null 2>&1 || true
  if fm_pending_reply_settle_closed_escalation "$STATE" "$corr" sweep; then
    echo "$line verdict=closed-by-key"
    keyed=$((keyed + 1))
  else
    echo "error: key '$key' is still open in $parent_status after its resolved line" >&2
    failed=$((failed + 1))
  fi
done

IFS=, read -r -a listed_keys <<<"${KEYS#,}"
for key in ${listed_keys[@]+"${listed_keys[@]}"}; do
  [ -n "$key" ] || continue
  case "$HANDLED" in *",$key,"*) ;; *) refuse "$key" "not an escalated pending-reply record" ;; esac
done

if [ -n "$REVIEW_OUT" ]; then
  echo "review: the escalation is still open and nothing proves the request was answered; read each and close with --apply --key <key>"
  printf '%s' "$REVIEW_OUT"
fi
mode=dry-run
[ "$APPLY" -eq 0 ] || mode=apply
echo "totals mode=$mode escalated=$escalated settled=$settled closed-by-key=$keyed review=$review unproven=$unproven other-phase=$skipped refused-key=$refused failed=$failed"
[ "$failed" -eq 0 ] && [ "$refused" -eq 0 ]
