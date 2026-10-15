#!/usr/bin/env bash
# Behavior tests for the daily archive pass (bin/fm-retention.sh).
#
# Coverage:
#   1. A handled process-event sequence older than the bound is archived and
#      truncated in place; younger, unhandled, and already-archived sequences are
#      left alone, and a second pass changes nothing
#   2. Archiving never lets the next capture of that source reuse a sequence
#   3. A resolved pending-reply record older than the bound is archived and
#      removed; a younger one, an open one, and one whose escalation is still
#      open stay, while a resolved record with a closed escalation goes
#   4. The pass runs at most once a day, --force overrides, --dry-run changes
#      nothing, and a failed archive removes nothing
#   5. The per-pass bound drains a larger backlog over several passes
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RETENTION="$ROOT/bin/fm-retention.sh"
TMP_ROOT=$(fm_test_tmproot fm-retention)

# touch -t is the one portable way to age a file on both GNU and BSD systems.
age_file() {  # <path> <days-ago>
  local stamp
  stamp=$(perl -e '@t = gmtime(time - $ARGV[0] * 86400); printf "%04d%02d%02d%02d%02d.%02d", $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]' "$2")
  TZ=UTC touch -t "$stamp" "$1"
}

new_home() {  # <name>
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state/procevent-inbox" "$home/state/pending-replies"
  printf '%s\n' "$home"
}

# A captured sequence: result, adapter, and (when handled) the marker.
add_sequence() {  # <home> <id> <seq> <handled-days-ago|unhandled>
  local inbox="$1/state/procevent-inbox" base
  base="$inbox/$2.$3"
  printf 'payload for %s %s\n' "$2" "$3" > "$base.result"
  printf 'quota\n' > "$base.adapter"
  chmod 0600 "$base.result" "$base.adapter"
  if [ "$4" != unhandled ]; then
    : > "$base.handled"
    chmod 0600 "$base.handled"
    age_file "$base.handled" "$4"
  fi
}

add_record() {  # <home> <corr> <phase> <resolved-epoch|-> <escalated-epoch|-> <closed-epoch|->
  local rec="$1/state/pending-replies/$2"
  {
    printf 'schema=fm-pending-reply.v1\ncorr_id=%s\ntask_id=hibit\nphase=%s\n' "$2" "$3"
    [ "$4" = - ] || printf 'resolved_epoch=%s\n' "$4"
    [ "$5" = - ] || printf 'escalated_epoch=%s\n' "$5"
    [ "$6" = - ] || printf 'escalation_closed_epoch=%s\n' "$6"
  } > "$rec"
}

run_retention() {  # <home> [args...]
  local home=$1; shift
  FM_HOME="$home" FM_RETENTION_NOW=2000000 "$RETENTION" run "$@"
}

archive_count() {  # <home> <prefix>
  find "$1/state/archive" -maxdepth 1 -name "$2-*.tar.gz" 2>/dev/null | wc -l | tr -d ' '
}

test_procevent_archive_truncates_old_handled_sequences() (
  local home out inbox
  home=$(new_home procevent)
  inbox="$home/state/procevent-inbox"
  add_sequence "$home" src 1 5
  add_sequence "$home" src 2 5
  add_sequence "$home" src 3 1
  add_sequence "$home" src 4 unhandled
  out=$(run_retention "$home" --force) || fail "retention failed: $out"
  [ "$(archive_count "$home" procevent-inbox)" = 1 ] || fail "expected one procevent archive"
  [ ! -s "$inbox/src.1.result" ] && [ -f "$inbox/src.1.result" ] || fail "an old handled result must be truncated in place"
  [ ! -s "$inbox/src.2.adapter" ] && [ -f "$inbox/src.2.adapter" ] || fail "an old handled adapter must be truncated in place"
  [ -f "$inbox/src.1.handled" ] || fail "the handled marker must stay"
  [ -s "$inbox/src.3.result" ] || fail "a sequence handled within the bound must stay"
  [ -s "$inbox/src.4.result" ] && [ -s "$inbox/src.4.adapter" ] || fail "an unhandled sequence must never be touched"
  tar -tzf "$home/state/archive"/procevent-inbox-*.tar.gz | grep -qx 'src.1.result' || fail "the archive must hold the old payload"
  [ "$(tar -xzOf "$home/state/archive"/procevent-inbox-*.tar.gz src.2.result)" = 'payload for src 2' ] \
    || fail "the archived payload must be intact"
  # A second pass has nothing left to do.
  out=$(run_retention "$home" --force) || fail "second pass failed: $out"
  [ "$(archive_count "$home" procevent-inbox)" = 1 ] || fail "an idempotent pass must not archive again"
  pass "old handled sequences are archived and truncated; young and unhandled ones stay; a rerun is a no-op"
)

test_archived_sequences_are_not_reallocated() (
  local home inbox next
  home=$(new_home realloc)
  inbox="$home/state/procevent-inbox"
  add_sequence "$home" src 1 5
  add_sequence "$home" src 2 5
  run_retention "$home" --force >/dev/null || fail "retention failed"
  # shellcheck source=bin/fm-pr-lib.sh
  . "$ROOT/bin/fm-pr-lib.sh"
  # shellcheck source=bin/fm-procevent-lib.sh
  . "$ROOT/bin/fm-procevent-lib.sh"
  printf 'fresh\n' > "$TMP_ROOT/fresh-output"
  fm_procevent_capture "$home/state" src quota "$TMP_ROOT/fresh-output" >/dev/null || fail "capture failed"
  next="$inbox/src.3.result"
  [ -s "$next" ] || fail "the next capture must take a new sequence, not reuse an archived one"
  fm_procevent_pending "$home/state" | grep -q 'src.3.result' || fail "the new capture must be pending"
  [ "$(fm_procevent_pending "$home/state" | wc -l | tr -d ' ')" = 1 ] || fail "only the new capture may be pending"
  pass "a capture after archiving takes a fresh sequence number"
)

test_pending_reply_archive_keeps_open_and_unclosed_records() (
  local home pr
  home=$(new_home pending)
  pr="$home/state/pending-replies"
  add_record "$home" aaaaaaaaaaaaaaa1 resolved 1000 - -
  add_record "$home" aaaaaaaaaaaaaaa2 resolved 1000 900 1100
  add_record "$home" aaaaaaaaaaaaaaa3 resolved 1000 900 -
  add_record "$home" aaaaaaaaaaaaaaa4 resolved 1999000 - -
  add_record "$home" aaaaaaaaaaaaaaa5 escalated - 900 -
  add_record "$home" aaaaaaaaaaaaaaa6 awaiting_report - - -
  : > "$pr/.delivery-confirmed-aaaaaaaaaaaaaaa1"
  run_retention "$home" --force >/dev/null || fail "retention failed"
  [ ! -e "$pr/aaaaaaaaaaaaaaa1" ] || fail "an old resolved record with no escalation must be archived"
  [ ! -e "$pr/.delivery-confirmed-aaaaaaaaaaaaaaa1" ] || fail "its delivery marker goes with it"
  [ ! -e "$pr/aaaaaaaaaaaaaaa2" ] || fail "an old resolved record with a closed escalation must be archived"
  [ -e "$pr/aaaaaaaaaaaaaaa3" ] || fail "a record whose escalation is still open must stay"
  [ -e "$pr/aaaaaaaaaaaaaaa4" ] || fail "a recently resolved record must stay"
  [ -e "$pr/aaaaaaaaaaaaaaa5" ] || fail "an escalated, unresolved record must stay"
  [ -e "$pr/aaaaaaaaaaaaaaa6" ] || fail "an open record must stay"
  [ "$(archive_count "$home" pending-replies)" = 1 ] || fail "expected one pending-replies archive"
  tar -tzf "$home/state/archive"/pending-replies-*.tar.gz | grep -qx 'aaaaaaaaaaaaaaa2' || fail "the archive must hold the record"
  pass "only old resolved records without an open escalation are archived"
)

test_cadence_dry_run_and_failed_archive() (
  local home out inbox fakebin
  home=$(new_home cadence)
  inbox="$home/state/procevent-inbox"
  add_sequence "$home" src 1 5
  out=$(run_retention "$home" --dry-run) || fail "dry run failed"
  case "$out" in *'would archive 1 sequence'*) ;; *) fail "dry run must report what it would do: $out" ;; esac
  [ -s "$inbox/src.1.result" ] && [ ! -e "$home/state/archive" ] && [ ! -e "$home/state/.retention-last-run" ] \
    || fail "a dry run must change nothing, including the cadence stamp"
  # A failing archive removes nothing.
  fakebin="$TMP_ROOT/fakebin-$RANDOM"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/tar"
  chmod +x "$fakebin/tar"
  PATH="$fakebin:$PATH" run_retention "$home" --force >/dev/null 2>&1 && fail "a failed archive must fail the pass"
  [ -s "$inbox/src.1.result" ] || fail "a failed archive must not truncate anything"
  # The cadence: a pass inside the interval does nothing, --force overrides.
  run_retention "$home" >/dev/null || fail "first timed pass failed"
  [ -f "$home/state/.retention-last-run" ] || fail "a pass must stamp its cadence"
  add_sequence "$home" src 2 5
  run_retention "$home" >/dev/null || fail "second timed pass failed"
  [ -s "$inbox/src.2.result" ] || fail "a second pass inside the interval must do nothing"
  run_retention "$home" --force >/dev/null || fail "forced pass failed"
  [ ! -s "$inbox/src.2.result" ] || fail "--force must run inside the interval"
  pass "the pass runs once a day, honours --force and --dry-run, and a failed archive loses nothing"
)

test_pass_is_bounded_per_run() (
  local home n=1 files
  home=$(new_home bounded)
  while [ "$n" -le 5 ]; do
    add_sequence "$home" src "$n" 5
    n=$((n + 1))
  done
  FM_RETENTION_MAX_ITEMS=2 run_retention "$home" --force >/dev/null || fail "bounded pass failed"
  files=$(find "$home/state/procevent-inbox" -name '*.result' -size +0 | wc -l | tr -d ' ')
  [ "$files" = 3 ] || fail "a pass of 2 must leave 3 of 5 sequences, left $files"
  FM_RETENTION_MAX_ITEMS=2 run_retention "$home" --force >/dev/null || fail "second bounded pass failed"
  FM_RETENTION_MAX_ITEMS=2 run_retention "$home" --force >/dev/null || fail "third bounded pass failed"
  files=$(find "$home/state/procevent-inbox" -name '*.result' -size +0 | wc -l | tr -d ' ')
  [ "$files" = 0 ] || fail "repeated passes must drain the backlog, left $files"
  pass "a larger backlog drains over several bounded passes"
)

test_procevent_archive_truncates_old_handled_sequences || exit 1
test_archived_sequences_are_not_reallocated || exit 1
test_pending_reply_archive_keeps_open_and_unclosed_records || exit 1
test_cadence_dry_run_and_failed_archive || exit 1
test_pass_is_bounded_per_run || exit 1

printf 'ok - all retention tests passed\n'
