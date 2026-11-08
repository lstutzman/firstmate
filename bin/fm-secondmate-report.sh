#!/usr/bin/env bash
# fm-secondmate-report.sh - optional helper to append a correlated parent report.
#
# A secondmate answering a marked from-firstmate request must report on the
# parent status channel with the request's corr=<id> token. This helper makes
# that easy, but correctness must not depend on using it: a plain echo of a
# status line that includes the same corr token is equally valid
# (bin/fm-pending-reply-lib.sh).
#
# The write destination is mechanical: this helper never takes a status path.
# It resolves the parent channel through fm_parent_channel_destination
# (bin/fm-parent-channel-lib.sh): a local mate writes the parent home's
# state/<id>.status, and a remote mate writes this home's
# state/parent-replies.status. Call it from the secondmate home with FM_HOME
# set to that home.
#
# Usage:
#   fm-secondmate-report.sh <verb> <corr_id> <note...>
#   fm-secondmate-report.sh --doc <verb> <corr_id> <doc-path> <note...>
#
# <corr_id> is the 16 hex characters after "corr=" in the marked request. When
# it is wrong or missing and the parent's pending-reply records are readable
# (a local mate), the refusal names the open expected id and prints the
# corrected command to rerun, so a retry is one step.
#
# Examples:
#   fm-secondmate-report.sh done abcdef0123456789 "audit clean"
#   fm-secondmate-report.sh --doc done abcdef0123456789 data/x/report.md "see report"
#   The first appends: done [corr=abcdef0123456789]: audit clean (via-helper)
set -eu

CALLER_FM_HOME=${FM_HOME:-}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

# Print, best effort, the open correlation ids the parent expects from this
# mate and the command to rerun. Falls back to a generic hint when the parent's
# records are not readable from here (a remote mate, or an unseeded home).
corr_hint() {  # <rerun-head> <rerun-tail>
  local head=$1 tail=$2 home=${FM_HOME:-} state id dir rec c ids=
  if [ -n "$home" ]; then
    state="${FM_STATE_OVERRIDE:-$home/state}"
    if fm_parent_channel_destination "$home" "$state" >/dev/null 2>&1 \
      && id=$(fm_parent_channel_home_id "$home" 2>/dev/null) \
      && [ "$FM_PARENT_CHANNEL_ROUTE" = local ]; then
      dir=$(fm_pending_reply_dir "$FM_SECONDMATE_PARENT_HOME/state")
      for rec in "$dir"/*; do
        [ -f "$rec" ] || continue
        [ "$(fm_pending_reply_get "$rec" task_id)" = "$id" ] || continue
        [ -z "$(fm_pending_reply_get "$rec" resolved_epoch)" ] || continue
        ids="$ids $(fm_pending_reply_get "$rec" corr_id)"
      done
    fi
  fi
  if [ -n "$ids" ]; then
    for c in $ids; do
      echo "hint: the open request from the parent expects corr=$c; rerun: $0 $head $c $tail" >&2
    done
  else
    echo "hint: take <corr_id> from the marked request's corr=<id> token; rerun: $0 $head <corr_id> $tail" >&2
  fi
}

usage() {
  cat <<'EOF' >&2
Usage:
  fm-secondmate-report.sh <verb> <corr_id> <note...>
  fm-secondmate-report.sh --doc <verb> <corr_id> <doc-path> <note...>
Example (appends: done [corr=<id>]: audit clean (via-helper)):
  fm-secondmate-report.sh done abcdef0123456789 "audit clean"
EOF
  exit 2
}

DOC_MODE=0
if [ "${1:-}" = "--doc" ]; then
  DOC_MODE=1
  shift
fi

[ $# -ge 2 ] || usage
VERB=$1
CORR=$2
shift 2

CORR_PREFIXED=0
case "$CORR" in
  corr=*) CORR=${CORR#corr=}; CORR_PREFIXED=1 ;;
esac
case "$CORR" in
  [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
  *)
    echo "error: corr_id must be 16 hex characters (got '$CORR')" >&2
    case "$CORR_PREFIXED:$CORR" in
      0:*[!a-fA-F0-9]*) set -- "$CORR" "$@" ;;
    esac
    if [ "$DOC_MODE" = 1 ]; then
      if [ $# -ge 1 ]; then
        doc=$1
        shift
        corr_hint "--doc $VERB" "$doc${*:+ \"$*\"}"
      else
        corr_hint "--doc $VERB" "<doc-path> \"<note>\""
      fi
    else
      corr_hint "$VERB" "\"${*:-<note>}\""
    fi
    exit 1
    ;;
esac

if [ "$DOC_MODE" = 1 ]; then
  [ $# -ge 1 ] && [ -n "$1" ] || usage
else
  [ $# -ge 1 ] && [ -n "$*" ] || usage
fi

HOME_DIR=$CALLER_FM_HOME
case "$HOME_DIR" in
  '')
    echo "error: FM_HOME is required so the helper can resolve the parent channel" >&2
    exit 1
    ;;
esac
STATE_DIR="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"

DESTINATION=
DEST_RC=0
DESTINATION=$(fm_parent_channel_destination "$HOME_DIR" "$STATE_DIR") || DEST_RC=$?
if [ "$DEST_RC" -ne 0 ] || [ -z "$DESTINATION" ]; then
  echo "error: cannot resolve the parent channel from this home (not a seeded secondmate?)" >&2
  exit 1
fi
mkdir -p "$(dirname "$DESTINATION")" 2>/dev/null || true
if [ ! -d "$(dirname "$DESTINATION")" ]; then
  echo "error: cannot create parent directory for status file '$DESTINATION'" >&2
  exit 1
fi

token=$(fm_pending_reply_corr_token "$CORR")
if [ "$DOC_MODE" = 1 ]; then
  DOC_PATH=$1
  shift
  NOTE=$*
  if [ -n "$NOTE" ]; then
    printf -v line '%s [%s]: %s (%s via-helper)' "$VERB" "$token" "$NOTE" "$DOC_PATH"
  else
    printf -v line '%s [%s]: %s (via-helper)' "$VERB" "$token" "$DOC_PATH"
  fi
else
  NOTE=$*
  printf -v line '%s [%s]: %s (via-helper)' "$VERB" "$token" "$NOTE"
fi
printf '%s\n' "$(status_stamp_line "$line")" >> "$DESTINATION"
