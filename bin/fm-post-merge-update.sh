#!/usr/bin/env bash
# Fast-forward every firstmate home after a firstmate merge.
#
# Two paths start an update, and only the primary home ever acts on either:
#   - launch: bin/fm-merge-outcome-lib.sh calls it once per merge it newly
#     records (its notified marker already deduplicates a merge seen by both
#     bin/fm-pr-merge.sh and the merge poll). The task's recorded project=
#     (state/<id>.meta) must share firstmate's own repository lineage
#     (fm_role_self_repo).
#   - scan: bin/fm-watch.sh runs it every cycle. It reads only the bytes
#     appended to state/*.status since its last pass and picks out each child's
#     merged outcome line, `done [key=merged-<id>]: merged <id> <pr-url>`, that
#     bin/fm-merge-outcome-lib.sh writes on the parent channel when a secondmate
#     or office home records a merge. Each one starts a detached `child`, which
#     trusts neither the line nor any task meta: the PR URL must name the
#     repository firstmate updates from (the code root's origin or its
#     config/self-update-source remote), and a read-only gh (or gh-axi) read
#     must show it merged. The first scan in a home only records where every
#     status log ends, so merges reported before this existed start nothing.
# Both paths claim the PR under one lock with a durable per-PR marker in
# state/.post-merge-update/, so a PR seen by both paths, or reported twice,
# starts one update.
#
#   fm-post-merge-update.sh launch <home> <state> <task-id> <pr-url>
#   fm-post-merge-update.sh scan <home> <state>
#   fm-post-merge-update.sh child <home> <state> <pr-url>
#   fm-post-merge-update.sh run <home> <state> <label>
#
# Every subcommand is a silent no-op in a home with a .fm-secondmate-home or
# .fm-office marker, or one that has opted out with an empty
# config/no-post-merge-update file (docs/configuration.md "Post-merge update").
# run executes bin/fm-update.sh, the one fast-forward-only implementation, whose
# own per-home lock serializes it with a manual /updatefirstmate. fm-update.sh
# moves homes and code roots together under its own guards (clean tree,
# ancestry, branch, self-update source) and never forces, stashes, or restarts
# anything; this wrapper discards its restart/nudge/reread summary, which stays
# with /updatefirstmate. Success is silent. A non-zero exit, any skipped home,
# or a child PR whose merge could not be read is reported as ONE `check:` wake
# in the primary home.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() { echo "usage: fm-post-merge-update.sh launch|scan|child|run <home> <state> [task-id pr-url|pr-url|label]" >&2; }

cmd=${1:-}
home=${2:-}
state=${3:-}
case "$cmd" in
  launch) [ $# -eq 5 ] || { usage; exit 2; } ;;
  scan) [ $# -eq 3 ] || { usage; exit 2; } ;;
  child|run) [ $# -eq 4 ] || { usage; exit 2; } ;;
  *) usage; exit 2 ;;
esac
[ ! -e "$home/.fm-secondmate-home" ] && [ ! -e "$home/.fm-office" ] || exit 0
[ ! -e "${FM_CONFIG_OVERRIDE:-$home/config}/no-post-merge-update" ] || exit 0
dir="$state/.post-merge-update"

# Load the wake queue and lock helpers scoped to <state>.
load_wake() {
  # shellcheck disable=SC2034 # Sourced wake helpers consume STATE.
  STATE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
}

# Parse <pr-url> into FM_PR_* and set key to the durable marker key of that PR.
pr_parse() {  # <pr-url>
  FM_HOME=$home
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  fm_pr_url_parse "$1" || return 1
  key=$(printf '%s %s %s %s' "$FM_PR_PROVIDER" "$FM_PR_HOST" \
    "$(printf '%s' "$FM_PR_PATH" | tr '[:upper:]' '[:lower:]')" "$FM_PR_NUMBER" \
    | git hash-object --stdin) && [ -n "$key" ]
}

# Print <host>/<path> of a git remote URL in lower case, without .git.
remote_repo() {  # <url>
  local u=$1 host
  case "$u" in
    *://*) u=${u#*://}; u=${u#*@} ;;
    *@*:*) u=${u#*@}; u=${u/:/\/} ;;
    *) return 1 ;;
  esac
  u=${u%/}; u=${u%.git}
  host=${u%%/*}; host=${host%%:*}
  [ "$u" != "${u#*/}" ] || return 1
  printf '%s/%s\n' "$host" "${u#*/}" | tr '[:upper:]' '[:lower:]'
}

# 0 when FM_PR_HOST/FM_PR_PATH is the repository fm-update.sh fetches from.
pr_is_firstmate() {
  local want remote src
  want=$(printf '%s/%s' "$FM_PR_HOST" "$FM_PR_PATH" | tr '[:upper:]' '[:lower:]')
  remote=origin
  src="$home/config/self-update-source"
  [ ! -f "$src" ] || remote="origin $(awk 'NR == 1 { print $1 }' "$src")"
  for r in $remote; do
    case "$r" in -*|*/*) continue ;; esac
    [ "$(remote_repo "$(git -C "$FM_ROOT" remote get-url "$r" 2>/dev/null)")" = "$want" ] && return 0
  done
  return 1
}

start_run() {  # <label>
  ( nohup "$SCRIPT_DIR/fm-post-merge-update.sh" run "$home" "$state" "$1" \
      >/dev/null 2>&1 </dev/null & )
}

case "$cmd" in
  launch)
    id=$4
    meta="$state/$id.meta"
    [ -f "$meta" ] || exit 0
    proj=$(sed -n 's/^project=//p' "$meta" | tail -1)
    [ -n "$proj" ] && [ -d "$proj" ] || exit 0
    # shellcheck source=bin/fm-role-lib.sh
    . "$SCRIPT_DIR/fm-role-lib.sh"
    fm_role_self_repo "$proj" "$FM_ROOT" || exit 0
    pr_parse "$5" || exit 0
    load_wake
    mkdir -p "$dir" || exit 1
    fm_lock_acquire_wait "$dir/claim.lock" || exit 1
    if [ -e "$dir/$key.launched" ]; then
      fm_lock_release "$dir/claim.lock"
      exit 0
    fi
    printf '%s\n' "$5" > "$dir/$key.launched" || { fm_lock_release "$dir/claim.lock"; exit 1; }
    fm_lock_release "$dir/claim.lock"
    start_run "post-merge-update-$id-$(date +%s)"
    exit 0
    ;;
  scan)
    mkdir -p "$dir/offsets" || exit 1
    baseline=false
    [ -e "$dir/scanned" ] || baseline=true
    stamp="$dir/scanned.next"
    : > "$stamp" || exit 1
    if $baseline; then
      files=$(find "$state" -maxdepth 1 -name '*.status' -type f 2>/dev/null)
    else
      files=$(find "$state" -maxdepth 1 -name '*.status' -type f -newer "$dir/scanned" 2>/dev/null)
    fi
    re='^done \[key=merged-([^]]+)\]( \[at=[0-9]+\])?: merged ([^ ]+) ([^ ]+)( (away|external|yolo|away-grant))?$'
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      base=${f##*/}
      size=$(wc -c < "$f" | tr -d ' ') || continue
      off=$(cat "$dir/offsets/$base" 2>/dev/null || echo 0)
      case "$off" in ''|*[!0-9]*) off=0 ;; esac
      [ "$size" -ge "$off" ] || off=0
      if ! $baseline && [ "$size" -gt "$off" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
          [[ "$line" =~ $re ]] || continue
          [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[3]}" ] || continue
          ( nohup "$SCRIPT_DIR/fm-post-merge-update.sh" child "$home" "$state" "${BASH_REMATCH[4]}" \
              >/dev/null 2>&1 </dev/null & )
        done < <(tail -c +$((off + 1)) "$f" | head -c $((size - off)))
      fi
      printf '%s\n' "$size" > "$dir/offsets/$base"
    done <<EOF
$files
EOF
    mv -f "$stamp" "$dir/scanned"
    exit 0
    ;;
  child)
    url=$4
    pr_parse "$url" || exit 0
    [ "$FM_PR_PROVIDER" = github ] || exit 0
    pr_is_firstmate || exit 0
    load_wake
    mkdir -p "$dir" || exit 1
    fm_lock_acquire_wait "$dir/claim.lock" || exit 1
    verdict=no
    if [ ! -e "$dir/$key.launched" ]; then
      if fm_pr_github_read_record "$FM_PR_HOST" "$FM_PR_OWNER" "$FM_PR_REPO" "$FM_PR_NUMBER"; then
        [ "$FM_PR_RECORD_MERGED" != true ] || verdict=yes
      else
        verdict=unread
      fi
    fi
    [ "$verdict" != yes ] || printf '%s\n' "$url" > "$dir/$key.launched" || verdict=no
    fm_lock_release "$dir/claim.lock"
    case "$verdict" in
      yes) start_run "post-merge-update-pr-$FM_PR_NUMBER-$(date +%s)" ;;
      unread)
        fm_wake_append check "post-merge-update-read-$key" \
          "check: post-merge update could not confirm a child-reported merge of $url (gh read failed); nothing updated - run /updatefirstmate if it merged" || true
        ;;
    esac
    exit 0
    ;;
  run)
    label=$4
    out=$(mktemp "${TMPDIR:-/tmp}/fm-post-merge-update.XXXXXX") || exit 1
    load_wake
    rc=0
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$SCRIPT_DIR/fm-update.sh" >"$out" 2>&1 </dev/null || rc=$?
    problems=$(grep -E 'skipped|^error:' "$out" | head -3 | tr '\n' ';' | cut -c1-400)
    if [ "$rc" -ne 0 ] || [ -n "$problems" ]; then
      [ -n "$problems" ] || problems="fm-update.sh exited $rc"
      fm_wake_append check "$label" \
        "check: post-merge update needs a look (nothing forced): $problems" || true
    fi
    /usr/bin/trash "$out" 2>/dev/null || true
    exit 0
    ;;
esac
