#!/usr/bin/env bash
# fm-retention.sh - bounded, idempotent archive pass for the process-event inbox.
#
# Usage:
#   fm-retention.sh run [--force]
#   fm-retention.sh --help
#
# The watcher calls `run` on every poll once state/.retention-last-run is a day
# old; `run` itself re-checks that cadence (--force skips it), stamps the file
# before it works so a failing pass is not retried every poll, and takes a lock
# so two passes never overlap. It never touches an unhandled or open item and
# archives, never deletes: everything it removes from a live store is first
# written to a verified gzip tarball under state/archive/.
#
#   state/procevent-inbox/   a captured sequence is <id>.<seq>.{result,adapter,
#                            owner-task,extension} plus a <id>.<seq>.handled
#                            marker once handled. A sequence whose marker is
#                            older than FM_RETENTION_PROCEVENT_SECS (default
#                            259200, 72 h) has its files written to
#                            procevent-inbox-<date>.tar.gz and its .result, the
#                            only large file, truncated to zero bytes in place.
#                            The name stays because bin/fm-procevent-lib.sh
#                            allocates the next sequence as the first
#                            <id>.<seq>.result that does not exist and records
#                            handling as an exclusive create of the marker:
#                            removing it would hand a new capture an old
#                            sequence number whose marker already says handled.
#                            The small .adapter, .owner-task and .extension
#                            sidecars and the marker are left as they are.
#                            Unhandled sequences are never touched.
#
# Status logs are deliberately not rotated here: workers append to them with a
# bare `>>` that no lock can make safe against a rename. The remote reply
# mirror's state/.remote-reply-mirrored-<mate> ledger deduplicates against those
# logs, which stay as they are, so it stays consistent.
#
# A pass handles at most FM_RETENTION_MAX_ITEMS (default 5000) sequences, oldest
# first; a larger backlog drains over the following passes.
# FM_RETENTION_NOW fixes the clock for the cadence stamp (tests).
# FM_HOME / FM_STATE_OVERRIDE select the home like every other script.
set -u
export LC_ALL=C

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ARCHIVE_DIR="$STATE/archive"
STAMP="$STATE/.retention-last-run"
LOCK="$STATE/.retention.lock"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

INTERVAL_SECS=${FM_RETENTION_INTERVAL_SECS:-86400}
PROCEVENT_SECS=${FM_RETENTION_PROCEVENT_SECS:-259200}
MAX_ITEMS=${FM_RETENTION_MAX_ITEMS:-5000}

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

die() {
  echo "fm-retention: $*" >&2
  exit 1
}

positive_int() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0) die "$1 must be a positive whole number: $2" ;;
  esac
}

now_epoch() {
  if [ -n "${FM_RETENTION_NOW:-}" ]; then
    printf '%s' "$FM_RETENTION_NOW"
  else
    date +%s
  fi
}

# Create the archive for the names listed (one per line, relative to <dir>) in
# <list>, verify it, and publish it under a fresh dated name. Prints the final
# path. A tarball that cannot be listed back with every member is never published.
write_archive() {  # <prefix> <dir> <list>
  local prefix=$1 dir=$2 list=$3 tmp label final n=1 want got
  label=$(date -u +%Y-%m-%d)
  (umask 077; mkdir -p "$ARCHIVE_DIR") || return 1
  tmp=$(umask 077; mktemp "$ARCHIVE_DIR/.$prefix.XXXXXX") || return 1
  if ! tar -czf "$tmp" -C "$dir" -T "$list" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  want=$(wc -l < "$list" | tr -d ' ')
  got=$(tar -tzf "$tmp" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$got" != "$want" ]; then
    rm -f -- "$tmp"
    return 1
  fi
  final="$ARCHIVE_DIR/$prefix-$label.tar.gz"
  while [ -e "$final" ]; do
    n=$((n + 1))
    final="$ARCHIVE_DIR/$prefix-$label-$n.tar.gz"
  done
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -- "$tmp" "$final" || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$final"
}

# Archive the payload files of every sequence handled longer ago than the bound.
retain_procevent() {  # <work-dir>
  local work=$1 inbox="$STATE/procevent-inbox" mins marker base member name
  local list="$work/procevent.list" truncate_list="$work/procevent.truncate" candidates="$work/procevent.candidates" seqs=0 archive
  : > "$list"
  : > "$truncate_list"
  [ -d "$inbox" ] && [ ! -L "$inbox" ] || return 0
  mins=$((PROCEVENT_SECS / 60))
  find "$inbox" -maxdepth 1 -type f -name '*.handled' -mmin "+$mins" 2>/dev/null | sort > "$candidates"
  while IFS= read -r marker; do
    [ "$seqs" -lt "$MAX_ITEMS" ] || break
    base=${marker%.handled}
    # A sequence without a readable result and adapter is not one the capture
    # path wrote; leave whatever it is alone.
    [ -f "$base.result" ] && [ ! -L "$base.result" ] && [ -s "$base.result" ] || continue
    [ -f "$base.adapter" ] && [ ! -L "$base.adapter" ] || continue
    printf '%s\n' "${base##*/}.result" >> "$truncate_list"
    for member in "$base.result" "$base.adapter" "$base.owner-task" "$base.extension"; do
      [ -f "$member" ] && [ ! -L "$member" ] || continue
      printf '%s\n' "${member##*/}" >> "$list"
    done
    seqs=$((seqs + 1))
  done < "$candidates"
  [ "$seqs" -gt 0 ] || return 0
  archive=$(write_archive procevent-inbox "$inbox" "$list") \
    || { echo "fm-retention: procevent-inbox archive failed; nothing was truncated" >&2; return 1; }
  while IFS= read -r name; do
    : > "$inbox/$name"
  done < "$truncate_list"
  printf 'retention: procevent-inbox archived %s sequence(s) to %s\n' "$seqs" "$archive"
}

cmd_run() {
  local force=0 arg last now work rc=0
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      *) usage 2 ;;
    esac
  done
  positive_int FM_RETENTION_INTERVAL_SECS "$INTERVAL_SECS"
  positive_int FM_RETENTION_PROCEVENT_SECS "$PROCEVENT_SECS"
  positive_int FM_RETENTION_MAX_ITEMS "$MAX_ITEMS"
  [ -d "$STATE" ] || exit 0
  now=$(now_epoch)
  if [ "$force" -eq 0 ] && [ -f "$STAMP" ]; then
    last=$(cat "$STAMP" 2>/dev/null || true)
    case "$last" in
      ''|*[!0-9]*) ;;
      *) [ $((now - last)) -ge "$INTERVAL_SECS" ] || exit 0 ;;
    esac
  fi
  # Another pass in flight is not an error: it is already doing this work.
  fm_lock_try_acquire "$LOCK" || exit 0
  work=$(mktemp -d "$STATE/.retention.XXXXXX") || { fm_lock_release "$LOCK"; die "cannot create a work directory"; }
  printf '%s\n' "$now" > "$STAMP" 2>/dev/null || true
  retain_procevent "$work" || rc=1
  rm -rf -- "$work"
  fm_lock_release "$LOCK"
  exit "$rc"
}

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  -h|--help) usage 0 ;;
  *) usage 2 ;;
esac
