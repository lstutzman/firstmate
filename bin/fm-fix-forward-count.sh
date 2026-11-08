#!/usr/bin/env bash
# fm-fix-forward-count.sh - weekly fix-forward evidence for merge-on-green: per repository, how many pull
# requests merged in the last N days, how many of those carry a `Fixes-regression-from: <full PR URL>` line in
# their body, and how many are reverts (title starts with "Revert").
#
# The fleet fixes forward, so reverts alone read near zero while merge-on-green hides regressions; the line
# links a fix to the PR that caused the bug, and the counts are a velocity evidence source (docs/configuration.md
# "Fix-forward count"). The ship brief's rule 9 (bin/fm-brief.sh) tells workers to write the line.
#
# Usage: fm-fix-forward-count.sh [--days N] [--json] [--limit N] [--repo owner/name]...
#   --days N    window length in days, default 7
#   --json      print one JSON document instead of one line per repository
#   --limit N   most merged PRs read per repository, default 200 (a repository that hits it is marked truncated)
#   --repo R    a repository to count; repeatable. Default: FM_FIX_FORWARD_REPOS (space-separated), else the fleet
#               merge table repositories lstutzman/{firstmate,skills,fleet-app,PropertyCompass2}
#
# Text output, one line per repository:
#   <owner/name> merged=<n> fix_forward=<n> reverts=<n> [truncated]   or   <owner/name> unreadable: <reason>
# JSON: {"days":N,"since":"YYYY-MM-DD","repos":[{"repo":...,"merged":n,"fix_forward":n,"reverts":n,"truncated":bool}
# | {"repo":...,"error":"..."}]}
# The window is the N UTC calendar days ending today, and since is its first day, so runs N days apart never overlap.
# Read-only: one `gh pr list` per repository, no write call, no model. Exit 0 when every repository was read,
# 1 when any was unreadable (the other repositories are still printed), 2 on usage errors.
set -eu

DAYS=7
LIMIT=200
JSON=0
REPOS=()
usage() { sed -n '/^# Usage:/,/^# JSON:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --days) [ $# -ge 2 ] || usage; DAYS=$2; shift 2 ;;
    --limit) [ $# -ge 2 ] || usage; LIMIT=$2; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage; REPOS+=("$2"); shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done
case $DAYS in ''|*[!0-9]*|0) echo "error: --days needs a positive integer" >&2; exit 2 ;; esac
case $LIMIT in ''|*[!0-9]*|0) echo "error: --limit needs a positive integer" >&2; exit 2 ;; esac
if [ ${#REPOS[@]} -eq 0 ]; then
  # shellcheck disable=SC2206 # Word splitting of the space-separated list is the contract.
  REPOS=(${FM_FIX_FORWARD_REPOS:-lstutzman/firstmate lstutzman/skills lstutzman/fleet-app lstutzman/PropertyCompass2})
fi
for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 2; }
done

SINCE=$(date -u -d "$((DAYS - 1)) days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"$((DAYS - 1))"d +%Y-%m-%d)
LINE_RE='(^|\n)Fixes-regression-from: https://[^ \n]+/pull/[0-9]+'

rows=()
failed=0
for repo in "${REPOS[@]}"; do
  if ! raw=$(gh pr list --repo "$repo" --state merged --search "merged:>=$SINCE" --limit "$LIMIT" \
      --json number,title,body 2>&1); then
    failed=1
    rows+=("$(jq -cn --arg repo "$repo" --arg error "$(printf '%s' "$raw" | head -1)" '{repo:$repo,error:$error}')")
    continue
  fi
  rows+=("$(printf '%s' "$raw" | jq -c --arg repo "$repo" --argjson limit "$LIMIT" --arg re "$LINE_RE" '
    {repo:$repo, merged:length,
     fix_forward:([.[] | select((.body // "") | test($re))] | length),
     reverts:([.[] | select((.title // "") | startswith("Revert"))] | length),
     truncated:(length >= $limit)}')")
done

if [ "$JSON" = 1 ]; then
  printf '%s\n' "${rows[@]}" | jq -s --argjson days "$DAYS" --arg since "$SINCE" '{days:$days,since:$since,repos:.}'
else
  printf '%s\n' "${rows[@]}" | jq -r '
    if .error then "\(.repo) unreadable: \(.error)"
    else "\(.repo) merged=\(.merged) fix_forward=\(.fix_forward) reverts=\(.reverts)\(if .truncated then " truncated" else "" end)" end'
fi
exit "$failed"
