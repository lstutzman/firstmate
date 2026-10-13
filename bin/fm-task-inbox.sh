#!/usr/bin/env bash
# fm-task-inbox.sh - the worker's side of the per-task steering inbox.
#
# Usage: fm-task-inbox.sh take <inbox-dir>
#
# `take` prints every waiting record in numeric order - a `--- <NNN.msg>` line,
# then the exact message text - and files each one into handled/ as it goes,
# which is the acknowledgement. An empty or absent inbox prints `inbox empty`
# and exits 0. It replaces the brief's old "list <inbox>/*.msg, then mv each"
# instruction, whose glob aborts a whole zsh command line when nothing matches
# and leaves the acknowledgement as a separate step.
# <inbox-dir> is the absolute inbox path the brief and $FM_TASK_INBOX name; the
# record format and handled/ contract are owned by bin/fm-task-inbox-lib.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

usage() {
  echo "usage: fm-task-inbox.sh take <inbox-dir>" >&2
  exit 2
}

cmd_take() {  # <inbox-dir>
  local dir=$1 f n name any=0
  local -a records=()
  for f in "$dir"/*.msg; do
    [ -f "$f" ] || continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    records+=("$n ${f##*/}")
  done
  if [ "${#records[@]}" -gt 0 ]; then
    mkdir -p "$dir/handled" || exit 1
    while read -r n name; do
      [ -n "$name" ] || continue
      any=1
      printf -- '--- %s\n' "$name"
      fm_task_inbox_body "$dir/$name" || cat "$dir/$name"
      printf '\n'
      mv "$dir/$name" "$dir/handled/$name" || {
        echo "error: could not file $dir/$name into handled/" >&2
        exit 1
      }
    done < <(printf '%s\n' "${records[@]}" | sort -n)
  fi
  [ "$any" -eq 1 ] || printf 'inbox empty\n'
}

case "${1:-}" in
  take) [ "$#" -eq 2 ] || usage; cmd_take "$2" ;;
  *) usage ;;
esac
