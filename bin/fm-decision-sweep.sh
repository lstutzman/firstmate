#!/usr/bin/env bash
# fm-decision-sweep.sh - close open needs-decision lines whose PRs have all landed.
#
# Usage: FM_HOME=<home> fm-decision-sweep.sh [--apply]
#
# Resolved decisions linger in a home's status logs as needs-decision lines no
# one reconciled, so the OPEN DECISIONS fold keeps listing them. This sweep
# reads the open set with status_open_decisions (bin/fm-classify-lib.sh, the
# only owner of the status grammar) for every state/*.status in FM_HOME and
# looks at needs-decision entries only.
#
# A candidate names one or more full GitHub PR URLs
# (https://github.com/<owner>/<repo>/pull/<n>) in its note; bare "#123" or
# "PR 123" text is never matched. Each named PR is read through `gh pr view`.
# A candidate is settled only when both hold:
#   - its key names a PR-subject ask: it starts merge-handoff-, or one of its
#     hyphen-separated parts is merge, merged, pr, land, landing, review, word
#     or admit;
#   - EVERY named PR reads MERGED. A CLOSED-unmerged PR settles nothing, since
#     it may still need a reopen-or-abandon call.
# Verdicts: settled; open (a named PR is open); unreadable (a PR could not be
# read: network, auth, rate limit); manual (any other candidate, such as a
# release or go ask that only mentions a PR, or a merge ask whose PR closed
# unmerged, or an unkeyed line); truncated. Only settled is ever closed.
# Never swept, whatever the PRs say:
#   - keys starting captain-hold- or pending-reply-: those close only through
#     bin/fm-captain-hold.sh answer and the pending-reply owner;
#   - decisions naming no PR URL;
#   - a note cut by the status-line cap (ending " [truncated]"), because the
#     cut may have shortened or dropped a PR URL.
#
# Default is a dry run: one line per candidate plus totals, nothing changed.
# --apply appends, for each settled candidate only, one line to the same
# status file:
#   resolved [key=<key>] [at=<epoch>]: decision-sweep: <pr url> merged <mergedAt>
# (several PRs are joined with "; "), stamped and
# announced by fm_wake_status_append_self_announced, then recorded in the fleet
# ledger when config/fleet-ledger exists. A closed key leaves the fold, so a
# re-run finds nothing to do. After the append the fold is read again, and a key
# that is still open is reported and makes the exit status 1.
#
# Environment: FM_HOME (required), FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE.
# Exit: 0 done, 1 a close did not take effect, 2 usage or setup error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APPLY=0
case "${1:-}" in
  '') ;;
  --apply) APPLY=1 ;;
  -h | --help) sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: FM_HOME=<home> fm-decision-sweep.sh [--apply]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: FM_HOME=<home> fm-decision-sweep.sh [--apply]" >&2; exit 2; }

if [ -z "${FM_HOME:-}" ] || [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME must name an existing firstmate home" >&2
  exit 2
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 2; }

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

PR_URL_RE='https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+'
PR_CACHE=''  # newline-separated "<url> <state> <date>" or "<url> unreadable"
CLOSE_MAX=$((FM_LINE_CAP_DEFAULT - $(status_stamp_width)))

pr_subject_key() {  # <key>
  case "$1" in merge-handoff-*) return 0 ;; esac
  case "-$1-" in *-merge-* | *-merged-* | *-pr-* | *-land-* | *-landing-* | *-review-* | *-word-* | *-admit-*) return 0 ;; esac
  return 1
}

# Print "<STATE> <date>" for one PR, or "unreadable". Cached per URL for the run.
pr_state() {  # <pr-url>
  local url=$1 json state hit
  hit=$(printf '%s' "$PR_CACHE" | awk -v u="$url" '$1 == u { sub(/^[^ ]+ /, ""); print; exit }')
  if [ -z "$hit" ]; then
    if json=$(gh pr view "$url" --json state,mergedAt,closedAt 2>/dev/null) \
      && state=$(printf '%s' "$json" | jq -r '.state + " " + ((if .state == "MERGED" then .mergedAt else .closedAt end) // "-")' 2>/dev/null) \
      && case "$state" in "MERGED "* | "CLOSED "* | "OPEN "*) true ;; *) false ;; esac; then
      hit=$state
    else
      hit=unreadable
    fi
    PR_CACHE="$PR_CACHE$url $hit"$'\n'
  fi
  printf '%s\n' "$hit"
}

total=0 settled=0 open=0 manual=0 unreadable=0 truncated=0 skipped_reserved=0 skipped_no_pr=0 failed=0

for f in "$STATE"/*.status; do
  [ -f "$f" ] || continue
  decisions=$(status_open_decisions "$f")
  [ -n "$decisions" ] || continue
  close_lines=() close_keys=()
  while IFS=$'\t' read -r key verb note; do
    [ "$verb" = needs-decision ] || continue
    case "$key" in captain-hold-* | pending-reply-*) skipped_reserved=$((skipped_reserved + 1)); continue ;; esac
    urls=$(printf '%s\n' "$note" | grep -oE "$PR_URL_RE" | awk '!seen[$0]++' || true)
    [ -n "$urls" ] || { skipped_no_pr=$((skipped_no_pr + 1)); continue; }
    total=$((total + 1))
    base=${f##*/}
    case "$note" in
      *' [truncated]')
        truncated=$((truncated + 1))
        echo "home=$FM_HOME file=$base key=$key verdict=truncated prs=$(printf '%s' "$urls" | tr '\n' ',')"
        continue
        ;;
    esac
    verdict=settled prs='' note_out=''
    while IFS= read -r url; do
      s=$(pr_state "$url")
      prs="$prs${prs:+,}$url=${s%% *}"
      case "$s" in
        unreadable) verdict=unreadable ;;
        OPEN*) [ "$verdict" = unreadable ] || verdict=open ;;
        MERGED*) note_out="$note_out${note_out:+; }$url merged ${s#* }" ;;
        CLOSED*) [ "$verdict" != settled ] || verdict=manual ;;
      esac
    done <<EOF
$urls
EOF
    pr_subject_key "$key" || verdict=manual
    echo "home=$FM_HOME file=$base key=$key verdict=$verdict prs=$prs"
    case "$verdict" in
      settled)
        settled=$((settled + 1))
        fm_cap_line_var "resolved [key=$key]: decision-sweep: $note_out" "$CLOSE_MAX"
        close_lines+=("$FM_LINE_CAP_LINE")
        close_keys+=("$key")
        ;;
      open) open=$((open + 1)) ;;
      unreadable) unreadable=$((unreadable + 1)) ;;
      manual) manual=$((manual + 1)) ;;
    esac
  done <<EOF
$decisions
EOF

  [ "$APPLY" -eq 1 ] && [ "${#close_lines[@]}" -gt 0 ] || continue
  rc=0
  fm_wake_status_append_self_announced "$STATE" "$f" "${close_lines[@]}" || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "error: could not append to $f" >&2
    failed=$((failed + ${#close_keys[@]}))
    continue
  fi
  [ ! -e "$CONFIG/fleet-ledger" ] \
    || "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$f" >/dev/null 2>&1 || true
  still=$(status_open_decisions "$f")
  for key in "${close_keys[@]}"; do
    case "$still" in
      "$key"$'\t'* | *$'\n'"$key"$'\t'*)
        echo "error: key '$key' is still open in $f after its resolved line" >&2
        failed=$((failed + 1))
        ;;
    esac
  done
done

mode=dry-run
[ "$APPLY" -eq 0 ] || mode=apply
echo "totals mode=$mode candidates=$total settled=$settled still-open=$open manual=$manual unreadable=$unreadable truncated=$truncated skipped-reserved-key=$skipped_reserved skipped-no-pr-url=$skipped_no_pr failed-to-close=$failed"
[ "$failed" -eq 0 ]
