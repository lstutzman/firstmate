# Review-standards follow-up: what the docs and comments say after 9ee1be9d

## docs/supervision-host.md, 'Attended' (lines 106-112)
```
### Attended

The host asks the Pi branch's offer rule (`branchOfferForWake`, through `bin/fm-branch-dispatch.mjs offer`) whether the branch may take the close.
So apart from the one rule below, a close reaches main off Pi exactly when it would on Pi: a check trigger, a decision-owned signal or stale trigger, and a scan that is unsafe or holds nothing for the branch stay main's.
The host adds one rule: while any check row, such as a captain inbox note, waits unread in the queue, every close stays main's; `branchOfferForWake` owns why.
On that main-only pass-through the host starts the successor watcher cycle and leaves it running, then prints the close unchanged.
That successor, like one a turn hands back at its start (see [Away](#away)), runs in a process group of its own, so the harness tearing down the hook's group after the rewake does not stop it.
```

## .pi/extensions/lib/fm-branch-dispatch.ts, owner comment above branchOfferForWake (lines 594-628)
```
// The offer rule for one actionable close: whether a branch may take it, in
// either posture. The Pi watcher (fm-primary-pi-watch.ts) and the supervision
// host off Pi (bin/fm-branch-dispatch.mjs offer) both route through this one
// owner, so a close reaches main off Pi exactly when it would on Pi, except
// for the host-only check-row rule below.
//
// A check-kind close (merge-confirmation polls, Relay mentions,
// credential/auth failures, and every other legitimately main-only class -
// docs/pi-supervision-branch.md) is never routed to the branch while attended,
// even when other currently-unread rows are individually eligible: this
// watcher cycle's own triggering event stays on main, exactly as before
// scopeForUnreadWake stopped letting a co-present check row veto the whole
// scan. That relaxation is what lets an UNRELATED eligible signal/stale row
// still reach the branch on this cycle; it must never also let a check-kind
// trigger itself slip past main's delivery.
//
// A signal close containing a needs-decision status file, or a stale close for
// a captain-held task, gets the identical main-only treatment as a check-kind
// trigger. The cross-reference deliberately includes every unread decision
// row: until that row is read, a later signal or stale trigger for the same
// task stays on main. Other tasks and heartbeat handling remain independent.
//
// For the attended supervision host (attendedHost), any unread check row also
// keeps the close on main. A row appended straight to the queue, such as a
// captain inbox note, has no close of its own once the watcher is already
// closing on another trigger, and the host's successor counts it as
// delivered, so a close the engine took would leave it queued with main
// parked. Main's drain of this close presents it instead.
//
// The away posture collapses that partition: every actionable row is
// branch-eligible and the trigger class no longer forces anything to main
// (scopeForUnreadWake owns the per-row rule).
export function branchOfferForWake(state: string, message: string, afk: boolean, attendedHost = false): BranchOfferVerdict {
  const heartbeat = /^heartbeat($|:)/.test(message);
  const isCheckTrigger = /^check:/.test(message);
```

## .pi/extensions/lib/fm-branch-dispatch.ts, the renamed guard (lines 643-647)
```
  const checkRowHoldsMain = attendedHost && !afk && scope.mainCheckQueued;
  const attendedEligible = !isCheckTrigger && !isNeedsDecisionTrigger && !checkRowHoldsMain && (
    afk ? scopeForUnreadWake(state, heartbeat, false).eligible : scope.eligible
  );
  const eligible = afk ? scope.eligible : attendedEligible;
```

## tests/fm-supervision-host.test.sh, regression test comment (lines 1061-1062)
```
# A check row queued before a close the branch could take keeps that close on main.
test_captain_inbox_note_queued_before_a_branch_close_reaches_main() {
```

## Stale identifier search over the worktree (ts, mjs, sh, md)
```
$ grep -rn mainCheckForHost --include=*.ts --include=*.mjs --include=*.sh --include=*.md .
(no matches)
```
