#!/usr/bin/env bash
# Ad-hoc adversarial drive of the real bin/fm-watch.sh wedge timer (not committed).
set -u
WT={run-worktree}
. "$WT/tests/watch-triage-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-landing-adversarial)
window="test:fm-wedge"; working='state: working · source: run-step · ci running'
url="https://github.com/o/fleet-app/pull/148"
mk() { # <name> <log>
  local dir; dir=$(wedge_threshold_fixture "$1" "$2" 0 5)
  printf 'pr=%s\n' "$url" >> "$dir/state/wedge.meta"
  printf '%s abc123\n' "$url" > "$dir/state/wedge.merge-handoff"
  printf '%s\n' "$dir"
}
run() { # <dir> <expect absorb|exit> <label>
  local d=$1; wedge_threshold_round "$d/state" "$d/fakebin" "$d/watch.out" "$d/pane.txt" "$window" "$working" "$2" \
    || fail "$3: round did not $2: $(cat "$d/watch.out")"
}
now=$(date +%s)
# A: a handed-off finished PR with a needs-decision opened AFTER its done line keeps alarming (a done line supersedes earlier decisions by design).
d=$(mk adv-open-decision "$(printf 'done [at=%s]: PR %s checks green\nneeds-decision [key=pick-colour]: which colour?' $((now-600)) "$url")")
run "$d" absorb "open other decision"
tl=$(find "$d" -name '*triage*' -exec cat {} +)
echo "A triage log: $(printf '%s\n' "$tl" | tail -1)"
printf '%s' "$tl" | grep -F 'landing:' >/dev/null && fail "a task with a decision opened after done was classed as landing"
printf '%s' "$tl" | grep -F 'open keyed decision' >/dev/null || fail "A: expected the pre-existing open-decision deferral"
pass "A: a decision opened after done is not landing (the existing open-decision deferral owns it)"
# B: same handed-off finished PR but kind=scout (not a ship) keeps alarming.
d=$(mk adv-scout "done [at=$((now-600))]: PR $url checks green")
sed -i 's/^kind=ship$/kind=scout/' "$d/state/wedge.meta"
run "$d" exit "scout"
grep -F 'possible wedge, escalation 1' "$d/watch.out" >/dev/null || fail "scout lost its alarm"
echo "B watch output: $(cat "$d/watch.out")"
pass "B: a non-ship task is never treated as landing"
# C: handoff file names a different PR than the task's record keeps alarming.
d=$(mk adv-wrong-pr "done [at=$((now-600))]: PR $url checks green")
printf '%s abc123\n' "https://github.com/o/fleet-app/pull/999" > "$d/state/wedge.merge-handoff"
run "$d" exit "wrong pr"
grep -F 'possible wedge, escalation 1' "$d/watch.out" >/dev/null || fail "wrong-pr handoff lost its alarm"
pass "C: a handoff record for a different PR does not make the task landing"
# D: landing task skipped -> triage log records the absorption reason.
d=$(mk adv-log "done [at=$((now-600))]: PR $url checks green")
run "$d" absorb "landing"
echo "D triage log: $(find "$d" -name '*triage*' -exec cat {} + | grep -F 'landing:' | tail -1)"
find "$d" -name '*triage*' -exec cat {} + | grep -F 'landing:' >/dev/null || fail "D: no landing audit line"
pass "D: landing skip leaves an audit line"
