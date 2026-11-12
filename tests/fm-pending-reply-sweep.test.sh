#!/usr/bin/env bash
# tests/fm-pending-reply-sweep.test.sh - bin/fm-pending-reply-sweep.sh settles
# escalated pending-reply records whose escalation decision is already closed,
# lists every still-open one for review with its reason, closes those only when
# named with --apply --key, and never touches another phase, an unproven record,
# or a record a backlog-handoff wake still names. A fake gh on PATH answers
# `gh pr view <url> --json state -q .state` from per-URL files.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pending-reply-sweep-tests)
SWEEP="$ROOT/bin/fm-pending-reply-sweep.sh"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
PRS="$TMP_ROOT/prs"
mkdir -p "$PRS"
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "pr view" ] || exit 2
f="$FAKE_GH_PRS/$(printf '%s' "$3" | tr '/:' '__')"
[ -f "$f" ] || { echo "gh: could not resolve to a PullRequest" >&2; exit 1; }
cat "$f"
SH
chmod +x "$FAKEBIN/gh"
export FAKE_GH_PRS="$PRS"
export PATH="$FAKEBIN:$PATH"
U() { printf 'https://github.com/o/r/pull/%s' "$1"; }
printf 'MERGED\n' > "$PRS/https___github.com_o_r_pull_7"

C_SETTLED=a000000000000001
C_GLUED=a000000000000002
C_UNDELIVERED=a000000000000003
C_PRS=a000000000000004
C_NONE=a000000000000005
C_UNPROVEN=a000000000000006
C_AWAITING=a000000000000007
C_RESOLVED=a000000000000008
C_MARKED=a000000000000009
C_CLOSED_UNDELIVERED=a00000000000000a

# Write one record under <home>/state/pending-replies; extra key=value args override.
rec() {  # <home> <corr> <phase> [key=value...]
  local h=$1 corr=$2 phase=$3
  shift 3
  mkdir -p "$h/state/pending-replies"
  {
    printf 'schema=fm-pending-reply.v1\ncorr_id=%s\ntask_id=t\nparent_home=%s\n' "$corr" "$h"
    printf 'parent_status=%s\nrequest_summary=request %s\nrequest_prs=\n' "$h/state/t.status" "$corr"
    printf 'created_epoch=1790000000\ndelivered_epoch=1790000001\nphase=%s\n' "$phase"
    printf 'escalated_epoch=1790000050\nescalation_closed_epoch=\nresolved_epoch=\nresolved_via=\n'
    printf '%s\n' "$@"
  } > "$h/state/pending-replies/$corr"
}
held() {  # <corr>
  printf 'blocked [key=pending-reply-%s] [at=1790000050]: pending-reply-held: task=t pending-reply-id=%s request=request %s\n' "$1" "$1" "$1"
}

# A home holding one record of every class, and its status log.
mkhome() {  # <name>
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state"
  rec "$h" "$C_SETTLED" escalated
  rec "$h" "$C_GLUED" escalated
  rec "$h" "$C_UNDELIVERED" escalated delivered_epoch=
  rec "$h" "$C_PRS" escalated "request_prs=$(U 7)"
  rec "$h" "$C_NONE" escalated
  rec "$h" "$C_UNPROVEN" escalated
  rec "$h" "$C_AWAITING" awaiting_report escalated_epoch=
  rec "$h" "$C_RESOLVED" resolved resolved_epoch=1790000010 resolved_via=status escalated_epoch=
  rec "$h" "$C_MARKED" escalated
  rec "$h" "$C_CLOSED_UNDELIVERED" escalated delivered_epoch=
  printf 'pending:%s\n' "$C_MARKED" > "$h/state/.backlog-handoff-t.wake-pending"
  {
    held "$C_SETTLED"
    printf 'resolved [key=pending-reply-%s] [at=1790000100]: pending-reply-resolved: task=t pending-reply-id=%s via=operator-resolve-key ack\n' "$C_SETTLED" "$C_SETTLED"
    held "$C_GLUED"
    printf 'done [at=1790000060]: answered corr=%sneeds-decision [key=x]: glued\n' "$C_GLUED"
    held "$C_UNDELIVERED"
    held "$C_PRS"
    held "$C_NONE"
    held "$C_MARKED"
    printf 'resolved [key=pending-reply-%s] [at=1790000100]: pending-reply-resolved: task=t pending-reply-id=%s via=operator-resolve-key ack\n' "$C_MARKED" "$C_MARKED"
    held "$C_CLOSED_UNDELIVERED"
    printf 'resolved [key=pending-reply-%s] [at=1790000100]: pending-reply-resolved: task=t pending-reply-id=%s via=operator-resolve-key ack\n' "$C_CLOSED_UNDELIVERED" "$C_CLOSED_UNDELIVERED"
  } > "$h/state/t.status"
  printf '%s' "$h"
}
sweep() { FM_HOME=$1 bash "$SWEEP" "${@:2}"; }
field() { fm_pending_reply_get "$1/state/pending-replies/$2" "$3"; }
open_keys() { status_open_decisions "$1/state/t.status" | cut -f1 | tr '\n' ' '; }
snapshot() { (cd "$1/state" && find . -type f | sort | xargs cksum); }

test_dry_run_verdicts_and_changes_nothing() {
  local h out before
  h=$(mkhome dry)
  before=$(snapshot "$h")
  out=$(sweep "$h") || fail "dry run failed: $out"
  assert_contains "$out" "key=pending-reply-$C_SETTLED verdict=settled via=operator-resolve-key" "an operator-closed escalation is settled"
  assert_contains "$out" "key=pending-reply-$C_GLUED verdict=review reason=corr-line-unmatched" "a corr line that does not resolve is listed for review"
  assert_contains "$out" "key=pending-reply-$C_UNDELIVERED verdict=review reason=undelivered not-closable: its owner may still resend under the same correlation, so --apply --key refuses it; request=" "an undelivered request is listed for review as not closable"
  assert_not_contains "$out" "key=pending-reply-$C_NONE verdict=review reason=none not-closable" "a delivered review record stays closable"
  assert_contains "$out" "key=pending-reply-$C_PRS verdict=review reason=prs prs=$(U 7)=MERGED" "a request naming PRs is listed with their states"
  assert_contains "$out" "key=pending-reply-$C_NONE verdict=review reason=none" "a request with no evidence is listed for review"
  assert_contains "$out" "key=pending-reply-$C_UNPROVEN verdict=unproven" "an escalation with no decision line is unproven"
  assert_contains "$out" "key=pending-reply-$C_MARKED verdict=unproven" "a record a backlog-handoff wake names is never settled"
  assert_contains "$out" "key=pending-reply-$C_CLOSED_UNDELIVERED verdict=unproven" "a closed but undelivered request stays its owner's to resend"
  assert_not_contains "$out" "$C_AWAITING" "an awaiting record is never a candidate"
  assert_not_contains "$out" "$C_RESOLVED" "a resolved record is never a candidate"
  assert_contains "$out" "totals mode=dry-run escalated=8 settled=1 closed-by-key=0 review=4 unproven=3 other-phase=2 refused-key=0 failed=0" "totals"
  [ "$(snapshot "$h")" = "$before" ] || fail "a dry run changed the home"
  pass "dry run reports settled, review, and unproven records and changes nothing"
}

test_key_needs_apply() {
  local h rc
  h=$(mkhome needs-apply)
  sweep "$h" --key "pending-reply-$C_NONE" > /dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "--key without --apply is a usage error"
  pass "--key needs --apply"
}

test_apply_settles_only_settled_and_is_idempotent() {
  local h out status_before
  h=$(mkhome apply)
  status_before=$(cksum < "$h/state/t.status")
  out=$(sweep "$h" --apply) || fail "apply failed: $out"
  assert_contains "$out" "settled=1 closed-by-key=0 review=4" "apply settles the settled record only"
  [ "$(field "$h" "$C_SETTLED" phase)" = resolved ] || fail "the settled record must become resolved"
  [ "$(field "$h" "$C_SETTLED" resolved_via)" = operator-resolve-key ] || fail "resolved_via comes from the close line"
  [ "$(field "$h" "$C_SETTLED" resolved_epoch)" = 1790000100 ] || fail "resolved_epoch is the close line's stamp"
  [ "$(field "$h" "$C_SETTLED" escalation_closed_epoch)" = 1790000100 ] || fail "escalation_closed_epoch is the close line's stamp"
  for c in "$C_GLUED" "$C_UNDELIVERED" "$C_PRS" "$C_NONE" "$C_UNPROVEN" "$C_MARKED" "$C_CLOSED_UNDELIVERED"; do
    [ "$(field "$h" "$c" phase)" = escalated ] || fail "record $c must stay escalated"
  done
  [ "$(field "$h" "$C_AWAITING" phase)" = awaiting_report ] || fail "an awaiting record must stay untouched"
  [ "$(cksum < "$h/state/t.status")" = "$status_before" ] || fail "settling writes no status line"
  out=$(sweep "$h" --apply) || fail "second apply failed: $out"
  assert_contains "$out" "escalated=7 settled=0" "a rerun finds nothing left to settle"
  pass "--apply settles only proven records and a rerun is a no-op"
}

test_key_closes_review_records() {
  local h out
  h=$(mkhome keyed)
  out=$(sweep "$h" --apply --key "pending-reply-$C_NONE,pending-reply-$C_GLUED") || fail "keyed apply failed: $out"
  assert_contains "$out" "key=pending-reply-$C_NONE verdict=closed-by-key" "a named review record is closed"
  assert_contains "$out" "closed-by-key=2" "both named keys closed"
  grep -Eq "^resolved \[key=pending-reply-$C_NONE\] \[at=[0-9]+\]: pending-reply-resolved: task=t pending-reply-id=$C_NONE via=sweep$" \
    "$h/state/t.status" || fail "the close line uses the owning library's vocabulary: $(tail -2 "$h/state/t.status")"
  case " $(open_keys "$h") " in *" pending-reply-$C_NONE "*) fail "the closed key is still open" ;; esac
  case " $(open_keys "$h") " in *" pending-reply-$C_PRS "*) ;; *) fail "an unnamed review key must stay open" ;; esac
  [ "$(field "$h" "$C_NONE" phase)" = resolved ] && [ "$(field "$h" "$C_NONE" resolved_via)" = sweep ] \
    || fail "a keyed close settles the record via sweep"
  pass "--apply --key closes exactly the named review records"
}

test_key_refuses_everything_else() {
  local h out rc
  h=$(mkhome refuse)
  out=$(sweep "$h" --apply --key "pending-reply-$C_UNPROVEN" --key "pending-reply-$C_AWAITING,pending-reply-ffffffffffffffff" 2>&1); rc=$?
  expect_code 1 "$rc" "a refused key makes the exit status 1"
  assert_contains "$out" "--key 'pending-reply-$C_UNPROVEN' refused: verdict is unproven" "an unproven record is refused"
  assert_contains "$out" "--key 'pending-reply-$C_AWAITING' refused: not an escalated pending-reply record" "an awaiting record is refused"
  assert_contains "$out" "--key 'pending-reply-ffffffffffffffff' refused" "an unknown key is refused"
  [ "$(field "$h" "$C_AWAITING" phase)" = awaiting_report ] || fail "a refused key changed its record"
  pass "--key refuses unproven, other-phase, and unknown records"
}

test_key_refuses_undelivered() {
  local h out rc status_before
  h=$(mkhome undelivered)
  status_before=$(cksum < "$h/state/t.status")
  out=$(sweep "$h" --apply --key "pending-reply-$C_UNDELIVERED" 2>&1); rc=$?
  expect_code 1 "$rc" "a key whose delivery was never confirmed is refused"
  assert_contains "$out" "--key 'pending-reply-$C_UNDELIVERED' refused: delivery was never confirmed" "the refusal names the reason"
  [ "$(cksum < "$h/state/t.status")" = "$status_before" ] || fail "a refused undelivered key wrote to the status log"
  [ "$(field "$h" "$C_UNDELIVERED" phase)" = escalated ] || fail "a refused undelivered record must stay escalated"
  case " $(open_keys "$h") " in *" pending-reply-$C_UNDELIVERED "*) ;; *) fail "the undelivered key must stay open" ;; esac
  pass "--key refuses an undelivered record and writes nothing"
}

test_key_refuses_status_outside_home() {
  local h other out rc
  h=$(mkhome outside)
  other="$TMP_ROOT/other-home/state"
  mkdir -p "$other"
  held "$C_NONE" > "$other/t.status"
  rec "$h" "$C_NONE" escalated "parent_status=$other/t.status"
  out=$(sweep "$h" --apply --key "pending-reply-$C_NONE" 2>&1); rc=$?
  expect_code 1 "$rc" "a key whose status log is in another home is refused"
  assert_contains "$out" "is outside $h/state" "the refusal names the reason"
  [ "$(wc -l < "$other/t.status" | tr -d ' ')" = 1 ] || fail "the sweep wrote into another home"
  pass "--key never writes into a status log outside this home"
}

test_dry_run_verdicts_and_changes_nothing
test_key_needs_apply
test_apply_settles_only_settled_and_is_idempotent
test_key_closes_review_records
test_key_refuses_everything_else
test_key_refuses_undelivered
test_key_refuses_status_outside_home

# Stale-handoff mode: undelivered records whose named PRs are all closed or merged.
S_OLD=a0000000000000b1 S_OPEN=a0000000000000b2 S_NOPR=a0000000000000b3 S_UNREAD=a0000000000000b4
S_YOUNG=a0000000000000b5 S_CLOSEDKEY=a0000000000000b6 S_MARKED=a0000000000000b7 S_MIXED=a0000000000000b8
S_OUTSIDE=a0000000000000b9 S_NEVER=a0000000000000ba S_SUMMARY=a0000000000000bb S_CUT=a0000000000000bc
S_LEGLOG=a0000000000000bd S_LEGOPEN=a0000000000000be S_LEGRELAY=a0000000000000bf
printf 'OPEN\n' > "$PRS/https___github.com_o_r_pull_8"
printf 'OPEN\n' > "$PRS/https___github.com_o_r_pull_98"
# A pre-request_prs summary cut by the 120-character cap inside PR 98's URL, so
# it reads as PR 9 (CLOSED) unless the cut is noticed.
CUT_SUMMARY=$(fm_pending_reply_summarize "$(printf '%087d' 0) $(U 98) and more")
case "$CUT_SUMMARY" in *" $(U 9)...") ;; *) echo "fixture: unexpected cut summary: $CUT_SUMMARY" >&2; exit 1 ;; esac
printf 'CLOSED\n' > "$PRS/https___github.com_o_r_pull_9"
OLD=$(( $(date +%s) - 10 * 86400 ))
mkstale() {  # <name>
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state"
  rec "$h" "$S_OLD" escalated delivered_epoch= created_epoch="$OLD" "request_prs=$(U 7),$(U 9)"
  rec "$h" "$S_OPEN" escalated delivered_epoch= created_epoch="$OLD" "request_prs=$(U 7),$(U 8)"
  rec "$h" "$S_NOPR" escalated delivered_epoch= created_epoch="$OLD"
  rec "$h" "$S_UNREAD" escalated delivered_epoch= created_epoch="$OLD" "request_prs=$(U 77)"
  rec "$h" "$S_YOUNG" escalated delivered_epoch= created_epoch="$(( $(date +%s) - 3600 ))" "request_prs=$(U 7)"
  rec "$h" "$S_CLOSEDKEY" escalated delivered_epoch= created_epoch="$OLD" "request_prs=$(U 7)"
  rec "$h" "$S_MARKED" escalated delivered_epoch= created_epoch="$OLD" "request_prs=$(U 7)"
  rec "$h" "$S_MIXED" escalated created_epoch="$OLD" "request_prs=$(U 7)"
  mkdir -p "$h-other/state"
  held "$S_OUTSIDE" > "$h-other/state/t.status"
  rec "$h" "$S_OUTSIDE" escalated delivered_epoch= created_epoch="$OLD" "request_prs=$(U 7)" "parent_status=$h-other/state/t.status"
  rec "$h" "$S_NEVER" escalated delivered_epoch= created_epoch="$OLD" "request_prs=$(U 7)"
  rec "$h" "$S_SUMMARY" escalated delivered_epoch= created_epoch="$OLD" "request_summary=please land $(U 9) today"
  rec "$h" "$S_CUT" escalated delivered_epoch= created_epoch="$OLD" "request_summary=$CUT_SUMMARY"
  # Legacy records (no request_prs, summary cut before the PR URLs): the full
  # request is recovered by corr id from the parent status log or the relay file.
  for c in "$S_LEGLOG" "$S_LEGOPEN" "$S_LEGRELAY"; do
    rec "$h" "$c" escalated delivered_epoch= created_epoch="$OLD" "request_summary=please land the old pile in order, the long list first ..."
  done
  mkdir -p "$h/state/t.inbox/handled"
  printf 'schema=fm-task-inbox.v1\n--\n%scorr=%s land %s and %s\n' "$FM_FROMFIRST_MARK" "$S_LEGOPEN" "$(U 7)" "$(U 8)" > "$h/state/t.inbox/handled/1.msg"
  printf 'schema=fm-task-inbox.v1\n--\n%scorr=%s land %s\n' "$FM_FROMFIRST_MARK" "$S_LEGRELAY" "$(U 9)" > "$h/state/t.inbox/2.msg"
  printf 'pending:%s\n' "$S_MARKED" > "$h/state/.backlog-handoff-t.wake-pending"
  {
    for c in "$S_LEGLOG" "$S_LEGOPEN" "$S_LEGRELAY"; do held "$c"; done
    printf 'working [at=1790000020]: corr=%s handoff text: land %s and %s\n' "$S_LEGLOG" "$(U 7)" "$(U 9)"
    for c in "$S_OLD" "$S_OPEN" "$S_NOPR" "$S_UNREAD" "$S_YOUNG" "$S_CLOSEDKEY" "$S_MARKED" "$S_MIXED" "$S_SUMMARY" "$S_CUT"; do held "$c"; done
    printf 'resolved [key=pending-reply-%s] [at=1790000100]: pending-reply-resolved: task=t pending-reply-id=%s via=operator-resolve-key ack\n' "$S_CLOSEDKEY" "$S_CLOSEDKEY"
  } > "$h/state/t.status"
  printf '%s' "$h"
}

test_stale_dry_run_changes_nothing() {
  local h out before
  h=$(mkstale stale-dry)
  before=$(snapshot "$h")
  out=$(sweep "$h" --stale-handoffs) || fail "stale dry run failed: $out"
  assert_contains "$out" "key=pending-reply-$S_OLD verdict=stale-handoff-candidate" "an old all-closed handoff is a candidate"
  assert_contains "$out" "key=pending-reply-$S_CLOSEDKEY verdict=stale-handoff-candidate" "an already-closed decision is a candidate"
  assert_contains "$out" "key=pending-reply-$S_OPEN verdict=stale-handoff-kept reason=pr-open" "an open PR is kept"
  assert_contains "$out" "key=pending-reply-$S_NOPR verdict=stale-handoff-kept reason=no-pr" "no PR is kept"
  assert_contains "$out" "key=pending-reply-$S_UNREAD verdict=stale-handoff-kept reason=pr-unreadable" "an unreadable PR is kept"
  assert_contains "$out" "key=pending-reply-$S_YOUNG verdict=stale-handoff-kept reason=too-young" "a young record is kept"
  assert_contains "$out" "key=pending-reply-$S_MARKED verdict=stale-handoff-kept reason=wake-named" "a wake-named record is kept"
  assert_contains "$out" "key=pending-reply-$S_OUTSIDE verdict=stale-handoff-kept reason=outside-home" "a status log in another home is kept"
  assert_contains "$out" "key=pending-reply-$S_NEVER verdict=stale-handoff-kept reason=decision-never-recorded" "a record with no decision line is kept"
  assert_contains "$out" "key=pending-reply-$S_SUMMARY verdict=stale-handoff-candidate prs=$(U 9)=CLOSED" "PR URLs come from a whole summary when request_prs is empty"
  assert_contains "$out" "key=pending-reply-$S_CUT verdict=stale-handoff-kept reason=full-request-unavailable" "a cut summary with no recoverable full text is kept"
  assert_contains "$out" "key=pending-reply-$S_LEGLOG verdict=stale-handoff-candidate prs=$(U 7)=MERGED,$(U 9)=CLOSED recovered-from=status-log" "a legacy record whose status corr line names only closed PRs is a candidate"
  assert_contains "$out" "key=pending-reply-$S_LEGRELAY verdict=stale-handoff-candidate prs=$(U 9)=CLOSED recovered-from=relay-message" "a legacy record is recovered from its relay message file"
  assert_contains "$out" "key=pending-reply-$S_LEGOPEN verdict=stale-handoff-kept reason=pr-open" "a recovered open PR keeps a legacy record"
  assert_contains "$out" "stale-handoff-candidates=5 stale-handoff-kept=9" "totals"
  [ "$(snapshot "$h")" = "$before" ] || fail "a stale dry run changed the home"
  pass "--stale-handoffs without --apply lists candidates and changes nothing"
}

test_stale_apply_retires_only_proven() {
  local h out c n
  h=$(mkstale stale-apply)
  out=$(sweep "$h" --apply --stale-handoffs) || fail "stale apply failed: $out"
  assert_contains "$out" "key=pending-reply-$S_OLD verdict=stale-handoff-retired" "retired"
  assert_contains "$out" "stale-handoff-retired=5 stale-handoff-kept=9" "totals"
  for c in "$S_OLD" "$S_CLOSEDKEY" "$S_SUMMARY" "$S_LEGLOG" "$S_LEGRELAY"; do
    [ "$(field "$h" "$c" phase)" = resolved ] && [ "$(field "$h" "$c" resolved_via)" = sweep-stale-handoff ] || fail "$c must be retired"
  done
  for c in "$S_OPEN" "$S_NOPR" "$S_UNREAD" "$S_YOUNG" "$S_MARKED" "$S_MIXED" "$S_OUTSIDE" "$S_NEVER" "$S_CUT" "$S_LEGOPEN"; do
    [ "$(field "$h" "$c" phase)" = escalated ] || fail "$c must stay escalated"
  done
  n=$(grep -c "pending-reply-id=$S_OLD via=sweep-stale-handoff prs=" "$h/state/t.status")
  [ "$n" = 1 ] || fail "exactly one resolved line for $S_OLD, got $n"
  grep -q "$(U 7)=MERGED" "$h/state/t.status" || fail "the line carries PR states"
  grep -q "^resolved .*pending-reply-id=$S_LEGLOG .*recovered-from=status-log" "$h/state/t.status" || fail "the line names the recovery source: $(grep "pending-reply-id=$S_LEGLOG" "$h/state/t.status")"
  grep -q "^request_prs=$" "$h/state/pending-replies/$S_LEGLOG" || fail "a legacy record is never backfilled"
  n=$(grep -c "^resolved .*pending-reply-id=$S_CLOSEDKEY" "$h/state/t.status")
  [ "$n" = 1 ] || fail "an already-closed decision gets no second line"
  [ "$(wc -l < "$h/state/t.status" | tr -d ' ')" = 19 ] || fail "one line appended per open decision: $(wc -l < "$h/state/t.status")"
  [ "$(wc -l < "$h-other/state/t.status" | tr -d ' ')" = 1 ] || fail "the sweep wrote into another home"
  [ "$(find "$h/state/t.inbox" -type f | wc -l | tr -d " ")" = 2 ] || fail "nothing is sent to the mate"
  case " $(open_keys "$h") " in *" pending-reply-$S_OLD "*) fail "the key stays open" ;; esac
  out=$(sweep "$h" --apply --stale-handoffs) || fail "rerun failed: $out"
  assert_contains "$out" "stale-handoff-retired=0 stale-handoff-kept=9" "a rerun retires nothing"
  [ "$(wc -l < "$h/state/t.status" | tr -d ' ')" = 19 ] || fail "a rerun appended a line"
  printf 'phase=escalated\n' >> "$h/state/pending-replies/$S_OLD"
  out=$(sweep "$h" --apply --stale-handoffs) || fail "retry failed: $out"
  assert_contains "$out" "key=pending-reply-$S_OLD verdict=stale-handoff-retired" "a record whose settle failed is retired on retry"
  [ "$(field "$h" "$S_OLD" phase)" = resolved ] || fail "the retry settles the record"
  [ "$(wc -l < "$h/state/t.status" | tr -d ' ')" = 19 ] || fail "a retry after its resolved line appended a second one"
  pass "--stale-handoffs --apply retires only proven records, once"
}

test_stale_min_age_and_usage() {
  local h out rc
  h=$(mkstale stale-age)
  out=$(sweep "$h" --stale-handoffs --min-age-days 30) || fail "failed: $out"
  assert_contains "$out" "key=pending-reply-$S_OLD verdict=stale-handoff-kept reason=too-young" "the age floor is overridable"
  sweep "$h" --min-age-days 5 > /dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "--min-age-days needs --stale-handoffs"
  pass "--min-age-days overrides the floor"
}

test_stale_key_refuses_kept() {
  local h out rc
  h=$(mkstale stale-key)
  out=$(sweep "$h" --apply --stale-handoffs --key "pending-reply-$S_OPEN" 2>&1); rc=$?
  expect_code 1 "$rc" "a key naming a kept stale record is refused"
  assert_contains "$out" "--key 'pending-reply-$S_OPEN' refused: delivery was never confirmed" "the refusal names the reason"
  [ "$(field "$h" "$S_OPEN" phase)" = escalated ] || fail "a refused kept record must stay escalated"
  case " $(open_keys "$h") " in *" pending-reply-$S_OPEN "*) ;; *) fail "the refused key must stay open" ;; esac
  pass "--apply --key refuses a kept stale record"
}

test_review_hides_cut_url() {
  local h out
  h=$(mkstale stale-review)
  out=$(sweep "$h") || fail "dry run failed: $out"
  printf '%s\n' "$out" | grep "key=pending-reply-$S_CUT verdict=review" | grep -qF "$(U 9)=CLOSED" \
    && fail "a URL cut by the summary cap is shown as another PR"
  assert_contains "$out" "key=pending-reply-$S_SUMMARY verdict=review reason=undelivered prs=$(U 9)=CLOSED" "a whole summary URL is shown"
  pass "review leaves out a URL cut by the summary cap"
}

test_stale_dry_run_changes_nothing
test_stale_apply_retires_only_proven
test_stale_key_refuses_kept
test_review_hides_cut_url
test_stale_min_age_and_usage
