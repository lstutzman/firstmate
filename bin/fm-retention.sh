#!/usr/bin/env bash
# fm-retention.sh - bounded, idempotent archive pass for two grow-only stores.
#
# Usage:
#   fm-retention.sh run [--force] [--dry-run]
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
#                            259200, 72 h) has its payload files written to
#                            procevent-inbox-<date>.tar.gz and then truncated to
#                            zero bytes in place. The names stay because
#                            bin/fm-procevent-lib.sh allocates the next sequence
#                            as the first <id>.<seq>.result that does not exist
#                            and records handling as an exclusive create of the
#                            marker: removing a name would hand a new capture an
#                            old sequence number whose marker already says
#                            handled. Unhandled sequences are never touched.
#   state/pending-replies/   a record whose phase is resolved for longer than
#                            FM_RETENTION_PENDING_SECS (default 604800, 7 days,
#                            counted from its resolved_epoch) and whose
#                            escalation is closed or never existed is written to
#                            pending-replies-<date>.tar.gz and then removed. Its
#                            lookups all treat a missing record like a settled one.
#
# Status logs are deliberately not rotated here: workers append to them with a
# bare `>>` that no lock can make safe against a rename. The remote reply
# mirror's state/.remote-reply-mirrored-<mate> ledger deduplicates against those
# logs, which stay as they are, so it stays consistent.
#
# Each category handles at most FM_RETENTION_MAX_ITEMS (default 5000) items per
# pass, oldest first; a larger backlog drains over the following passes.
# FM_RETENTION_NOW fixes the clock for the resolved_epoch comparison (tests).
# FM_HOME / FM_STATE_OVERRIDE select the home like every other script.
set -u
export LC_ALL=C

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ARCHIVE_DIR="$STATE/archive"
STAMP="$STATE/.retention-last-run"
LOCK="$STATE/.retention.lock"

INTERVAL_SECS=${FM_RETENTION_INTERVAL_SECS:-86400}
PROCEVENT_SECS=${FM_RETENTION_PROCEVENT_SECS:-259200}
PENDING_SECS=${FM_RETENTION_PENDING_SECS:-604800}
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
retain_procevent() {  # <work-dir> <dry-run>
  local work=$1 dry=$2 inbox="$STATE/procevent-inbox" mins marker base member name
  local list="$work/procevent.list" candidates="$work/procevent.candidates" count=0 seqs=0 sequence_has_payload archive
  : > "$list"
  [ -d "$inbox" ] && [ ! -L "$inbox" ] || return 0
  mins=$((PROCEVENT_SECS / 60))
  find "$inbox" -maxdepth 1 -type f -name '*.handled' -mmin "+$mins" 2>/dev/null | sort > "$candidates"
  while IFS= read -r marker; do
    [ "$seqs" -lt "$MAX_ITEMS" ] || break
    base=${marker%.handled}
    # A sequence without a readable result and adapter is not one the capture
    # path wrote; leave whatever it is alone.
    [ -f "$base.result" ] && [ ! -L "$base.result" ] || continue
    [ -f "$base.adapter" ] && [ ! -L "$base.adapter" ] || continue
    sequence_has_payload=0
    for member in "$base.result" "$base.adapter" "$base.owner-task" "$base.extension"; do
      [ -f "$member" ] && [ ! -L "$member" ] && [ -s "$member" ] || continue
      name=${member##*/}
      printf '%s\n' "$name" >> "$list"
      sequence_has_payload=1
    done
    [ "$sequence_has_payload" -eq 1 ] && seqs=$((seqs + 1))
  done < "$candidates"
  count=$(wc -l < "$list" | tr -d ' ')
  [ "$count" -gt 0 ] || return 0
  if [ "$dry" -eq 1 ]; then
    printf 'retention: procevent-inbox would archive %s sequence(s)\n' "$seqs"
    return 0
  fi
  archive=$(write_archive procevent-inbox "$inbox" "$list") \
    || { echo "fm-retention: procevent-inbox archive failed; nothing was truncated" >&2; return 1; }
  while IFS= read -r name; do
    : > "$inbox/$name"
  done < "$list"
  printf 'retention: procevent-inbox archived %s sequence(s) to %s\n' "$seqs" "$archive"
}

# Archive every resolved record that is old enough and holds no open escalation.
retain_pending_replies() {  # <work-dir> <dry-run>
  local work=$1 dry=$2 dir="$STATE/pending-replies" now rec name corr archive
  local list="$work/pending.list" records="$work/pending.records" count=0
  : > "$list"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  now=$(now_epoch)
  for rec in "$dir"/*; do
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    printf '%s\n' "$rec"
  done > "$records.all"
  [ -s "$records.all" ] || return 0
  awk -v now="$now" -v secs="$PENDING_SECS" -v max="$MAX_ITEMS" '
    {
      path = $0
      phase = ""; resolved = ""; escalated = ""; closed = ""
      while ((rc = (getline line < path)) > 0) {
        if (index(line, "phase=") == 1) phase = substr(line, 7)
        else if (index(line, "resolved_epoch=") == 1) resolved = substr(line, 16)
        else if (index(line, "escalated_epoch=") == 1) escalated = substr(line, 17)
        else if (index(line, "escalation_closed_epoch=") == 1) closed = substr(line, 25)
      }
      close(path)
      if (rc < 0 || phase != "resolved" || resolved !~ /^[0-9]+$/) next
      if (now - resolved < secs) next
      if (escalated != "" && closed == "") next
      if (n >= max) next
      n++
      print path
    }
  ' "$records.all" > "$records"
  while IFS= read -r rec; do
    name=${rec##*/}
    printf '%s\n' "$name" >> "$list"
    corr=$name
    if [ -f "$dir/.delivery-confirmed-$corr" ] && [ ! -L "$dir/.delivery-confirmed-$corr" ]; then
      printf '%s\n' ".delivery-confirmed-$corr" >> "$list"
    fi
    count=$((count + 1))
  done < "$records"
  [ "$count" -gt 0 ] || return 0
  if [ "$dry" -eq 1 ]; then
    printf 'retention: pending-replies would archive %s record(s)\n' "$count"
    return 0
  fi
  archive=$(write_archive pending-replies "$dir" "$list") \
    || { echo "fm-retention: pending-replies archive failed; nothing was removed" >&2; return 1; }
  while IFS= read -r name; do
    rm -f -- "$dir/$name"
  done < "$list"
  printf 'retention: pending-replies archived %s record(s) to %s\n' "$count" "$archive"
}

cmd_run() {
  local force=0 dry=0 arg last now work rc=0 pid
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      --dry-run) dry=1 ;;
      *) usage 2 ;;
    esac
  done
  positive_int FM_RETENTION_INTERVAL_SECS "$INTERVAL_SECS"
  positive_int FM_RETENTION_PROCEVENT_SECS "$PROCEVENT_SECS"
  positive_int FM_RETENTION_PENDING_SECS "$PENDING_SECS"
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
  if ! mkdir "$LOCK" 2>/dev/null; then
    pid=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      exit 0
    fi
    rm -rf -- "$LOCK"
    mkdir "$LOCK" 2>/dev/null || exit 0
  fi
  printf '%s\n' "$$" > "$LOCK/pid"
  work=$(mktemp -d "$STATE/.retention.XXXXXX") || { rm -rf -- "$LOCK"; die "cannot create a work directory"; }
  # A dry run changes nothing, including the cadence stamp.
  if [ "$dry" -eq 0 ]; then
    printf '%s\n' "$now" > "$STAMP" 2>/dev/null || true
  fi
  retain_procevent "$work" "$dry" || rc=1
  retain_pending_replies "$work" "$dry" || rc=1
  rm -rf -- "$work" "$LOCK"
  exit "$rc"
}

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  -h|--help) usage 0 ;;
  *) usage 2 ;;
esac
