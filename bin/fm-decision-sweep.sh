#!/usr/bin/env bash
# fm-decision-sweep.sh - close open needs-decision lines whose PRs have all landed.
#
# Usage: FM_HOME=<home> fm-decision-sweep.sh [--settle-only] [--apply [--key <key>[,<key>...]]...]
#
# Resolved decisions linger in a home's status logs as needs-decision lines no
# one reconciled, so the OPEN DECISIONS fold keeps listing them. This sweep
# reads the open set with status_open_decisions (bin/fm-classify-lib.sh, the
# only owner of the status grammar) for every state/*.status in FM_HOME and
# looks at needs-decision entries, plus blocked entries that name a dependency.
#
# A candidate names one or more full GitHub PR URLs
# (https://github.com/<owner>/<repo>/pull/<n>) in its note; bare "#123" or
# "PR 123" text is never matched. Each named PR is read through `gh pr view`.
# The sweep never guesses what a free-text ask wants. Verdicts:
#   settled    key is merge-handoff-<n> (written by bin/fm-pr-merge.sh with the
#              PR as its subject), the note names exactly one PR URL, its
#              number is <n>, and that PR is MERGED; or the line that opened
#              the decision names a pr/<owner>/<repo>/<n> dependency
#              (status_line_dep in bin/fm-classify-lib.sh) and that PR is
#              MERGED, whatever the note says, because the tag is the writer's
#              own statement that the merge clears the wait;
#   review     every named PR is MERGED but the line is not a matching
#              merge-handoff; listed under its own heading with the start of
#              its note, for a reader to judge;
#   open       a named PR is still open;
#   manual     a named PR is CLOSED unmerged (it may still need a
#              reopen-or-abandon call);
#   unreadable a PR could not be read (network, auth, rate limit);
#   truncated  the note was cut by the status-line cap (ends " [truncated]"),
#              so a PR URL may be shortened or missing; never looked up.
# Never candidates: keys starting captain-hold- or pending-reply- (those close
# only through bin/fm-captain-hold.sh answer and the pending-reply owner), and
# decisions naming no PR URL.
#
# --settle-only looks up only candidates that could settle - a merge-handoff
# key matching its one named PR, or a pr dependency - so it costs one gh call
# per such decision and none for free-text asks; nothing else is listed or
# counted. bin/fm-watch.sh runs it with --apply on its own cadence
# (FM_DECISION_SWEEP_INTERVAL_SECS, default 600 seconds, 0 turns it off), so a
# wait on another home's merge clears itself once the PR lands.
#
# Default is a dry run: one line per candidate, the review list, and totals;
# nothing changed. --apply closes every settled candidate. --key (repeatable,
# or a comma list; needs --apply) also closes exactly the listed keys, each
# only if it is still an open candidate whose verdict is review at apply time;
# any other listed key is refused with its reason and makes the exit status 1.
# Each close appends one line to the decision's status file:
#   resolved [key=<key>] [at=<epoch>]: decision-sweep: <pr url> merged <mergedAt>
# (several PRs are joined with "; "), stamped and
# announced by fm_wake_status_append_self_announced, then recorded in the fleet
# ledger when config/fleet-ledger exists. A closed key leaves the fold, so a
# re-run finds nothing to do. After the append the fold is read again, and a key
# that is still open is reported and makes the exit status 1.
#
# Environment: FM_HOME (required), FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE.
# Exit: 0 done, 1 a close did not take effect or a --key was refused,
# 2 usage or setup error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: FM_HOME=<home> fm-decision-sweep.sh [--settle-only] [--apply [--key <key>[,<key>...]]...]" >&2; exit 2; }
APPLY=0 KEYS='' SETTLE_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --settle-only) SETTLE_ONLY=1 ;;
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

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

PR_URL_RE='https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+'
PR_CACHE=''  # newline-separated "<url> <state> <date>" or "<url> unreadable"
CLOSE_MAX=$((FM_LINE_CAP_DEFAULT - $(status_stamp_width)))

listed() { case "$KEYS" in *",$1,"*) return 0 ;; esac; return 1; }
HANDLED=,
refused=0
refuse() {  # <key> <reason>
  HANDLED="$HANDLED$1,"
  echo "error: --key '$1' refused: $2" >&2
  refused=$((refused + 1))
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

total=0 settled=0 keyed=0 review=0 open=0 manual=0 unreadable=0 truncated=0 skipped_reserved=0 skipped_no_pr=0 failed=0
REVIEW_OUT=''

# The pr dependency named by the line that opened <key>'s open decision, as a
# PR URL; fails when that line names none. The opener is the last
# needs-decision or blocked line carrying the key, because each such line
# reopens the decision under its own note.
dep_pr_url() {  # <status-file> <key>
  local line opener='' lkey lverb dep
  while IFS= read -r line; do
    status_line_verb "$line" lverb
    case "$lverb" in needs-decision | blocked) ;; *) continue ;; esac
    lkey=$(status_line_decision_key "$line") || continue
    [ "$lkey" = "$2" ] && opener=$line
  done < <(grep -aF -- "[key=$2]" "$1" 2>/dev/null)
  [ -n "$opener" ] && dep=$(status_line_dep "$opener") || return 1
  status_dep_pr_url "$dep"
}

for f in "$STATE"/*.status; do
  [ -f "$f" ] || continue
  decisions=$(status_open_decisions "$f")
  [ -n "$decisions" ] || continue
  has_deps=0
  ! grep -qaF -- '[dep=' "$f" 2>/dev/null || has_deps=1
  close_lines=() close_keys=()
  while IFS=$'\t' read -r key verb note; do
    case "$verb" in needs-decision | blocked) ;; *) continue ;; esac
    dep_url=''
    [ "$has_deps" -eq 0 ] || dep_url=$(dep_pr_url "$f" "$key") || dep_url=''
    [ "$verb" = needs-decision ] || [ -n "$dep_url" ] || continue
    case "$key" in
      captain-hold-* | pending-reply-*)
        [ "$SETTLE_ONLY" -eq 1 ] && ! listed "$key" && continue
        skipped_reserved=$((skipped_reserved + 1))
        ! listed "$key" || refuse "$key" "reserved key"
        continue
        ;;
    esac
    if [ -n "$dep_url" ]; then
      urls=$dep_url
    else
      urls=$(printf '%s\n' "$note" | grep -oE "$PR_URL_RE" | awk '!seen[$0]++' || true)
    fi
    if [ "$SETTLE_ONLY" -eq 1 ] && [ -z "$dep_url" ] \
      && { [ -z "$urls" ] || [ "$key" != "merge-handoff-${urls##*/}" ] || [ "$urls" != "${urls%%$'\n'*}" ]; }; then
      continue
    fi
    if [ -z "$urls" ]; then
      skipped_no_pr=$((skipped_no_pr + 1))
      ! listed "$key" || refuse "$key" "names no PR URL"
      continue
    fi
    total=$((total + 1))
    base=${f##*/}
    case "$dep_url:$note" in
      :*' [truncated]')
        truncated=$((truncated + 1))
        echo "home=$FM_HOME file=$base key=$key verdict=truncated prs=$(printf '%s' "$urls" | tr '\n' ',')"
        ! listed "$key" || refuse "$key" "note is truncated"
        continue
        ;;
    esac
    verdict=merged prs='' note_out=''
    while IFS= read -r url; do
      s=$(pr_state "$url")
      prs="$prs${prs:+,}$url=${s%% *}"
      case "$s" in
        unreadable) verdict=unreadable ;;
        OPEN*) [ "$verdict" = unreadable ] || verdict=open ;;
        CLOSED*) [ "$verdict" != merged ] || verdict=manual ;;
        MERGED*) note_out="$note_out${note_out:+; }$url merged ${s#* }" ;;
      esac
    done <<EOF
$urls
EOF
    if [ "$verdict" = merged ]; then
      verdict=review
      [ -z "$dep_url" ] || verdict=settled
      [ "$key" != "merge-handoff-${urls##*/}" ] || [ "$urls" != "${urls%%$'\n'*}" ] || verdict=settled
    fi
    line="home=$FM_HOME file=$base key=$key verdict=$verdict prs=$prs"
    if [ "$verdict" = review ]; then
      if [ "$APPLY" -eq 1 ] && listed "$key"; then
        HANDLED="$HANDLED$key,"
        verdict=keyed
        echo "${line/verdict=review/verdict=closed-by-key}"
      else
        REVIEW_OUT="$REVIEW_OUT$line note=${note:0:160}"$'\n'
      fi
    else
      echo "$line"
      if [ "$verdict" = settled ]; then
        HANDLED="$HANDLED$key,"
      elif listed "$key"; then
        refuse "$key" "verdict is $verdict ($prs)"
      fi
    fi
    case "$verdict" in
      settled | keyed)
        if [ "$verdict" = settled ]; then settled=$((settled + 1)); else keyed=$((keyed + 1)); fi
        fm_cap_line_var "resolved [key=$key]: decision-sweep: $note_out" "$CLOSE_MAX"
        close_lines+=("$FM_LINE_CAP_LINE")
        close_keys+=("$key")
        ;;
      review) review=$((review + 1)) ;;
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

IFS=, read -r -a listed_keys <<<"${KEYS#,}"
for key in ${listed_keys[@]+"${listed_keys[@]}"}; do
  [ -n "$key" ] || continue
  case "$HANDLED" in *",$key,"*) ;; *) refuse "$key" "not an open needs-decision" ;; esac
done

if [ -n "$REVIEW_OUT" ]; then
  echo "review: every named PR merged, but the ask is free text; read each and close with --apply --key <key>"
  printf '%s' "$REVIEW_OUT"
fi
mode=dry-run
[ "$APPLY" -eq 0 ] || mode=apply
echo "totals mode=$mode candidates=$total settled=$settled closed-by-key=$keyed review=$review still-open=$open manual=$manual unreadable=$unreadable truncated=$truncated skipped-reserved-key=$skipped_reserved skipped-no-pr-url=$skipped_no_pr refused-key=$refused failed-to-close=$failed"
[ "$failed" -eq 0 ] && [ "$refused" -eq 0 ]
