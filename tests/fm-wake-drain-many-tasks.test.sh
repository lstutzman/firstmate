#!/usr/bin/env bash
# tests/fm-wake-drain-many-tasks.test.sh - the drain must stay fast on a home
# with many live tasks and long status logs (FLEET-235: a 98-task home spent
# about two minutes in one --summary drain, so session start hit its limit).
# Two behaviors are pinned through the real drain: the printed sections for a
# mixed fixture are exactly the recorded text (the output the slow per-line
# implementation printed for the same input), and a 100-task home drains
# within a generous CPU bound (about 2.5 times the measured cost; the per-line implementation took about 58s), so a return to per-line forks fails here.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-many-tasks-tests)

# A home that does not run the supervision host, as the sibling drain suites do.
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

test_mixed_fixture_output_is_unchanged() {
  local dir state out i f
  dir=$(make_case equivalence)
  state="$dir/state"
  out="$dir/drain.out"
  for i in 1 2 3 4 5 6; do
    f="$state/t$i.status"
    : > "$f"
    printf 'working: routine line 1\nworking: routine line 2\n\n   \n' >> "$f"
    printf 'note: heads up from t%s\n' "$i" >> "$f"
    printf 'needs-decision [key=k%s]: choose A or B for t%s\n' "$i" "$i" >> "$f"
    case "$i" in
      2) printf 'resolved [key=k2]: picked A\n' >> "$f" ;;
      3) printf 'blocked [key=b3]: waiting on tool\n' >> "$f" ;;
      4) printf 'notebook working: not a note\n' >> "$f" ;;
      5) printf 'working: tail with no newline' >> "$f" ;;
    esac
  done

  FM_STATE_OVERRIDE="$state" "$DRAIN" --summary > "$out" 2>/dev/null \
    || fail "drain failed on the mixed fixture"

  cat > "$dir/expected" <<'EXP'
UNREAD STATUS (new since last drain, not re-printed after this presentation):
t1 note: heads up from t1
t2 note: heads up from t2
t3 note: heads up from t3
t4 note: heads up from t4
t5 note: heads up from t5
t6 note: heads up from t6
OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):
t1 [key=k1] needs-decision: choose A or B for t1
t3 [key=k3] needs-decision: choose A or B for t3
t3 [key=b3] blocked: waiting on tool
t4 [key=k4] needs-decision: choose A or B for t4
t5 [key=k5] needs-decision: choose A or B for t5
t6 [key=k6] needs-decision: choose A or B for t6
OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'
OPEN DECISIONS: <key> is the [key=...] printed before the verb; a token inside a note is prose, not a key.
EXP
  diff "$dir/expected" "$out" >/dev/null \
    || fail "drain output changed for the mixed fixture: $(diff "$dir/expected" "$out")"

  # A second drain over one new note shows only that note, and the open
  # decisions stay listed (the cursor advanced exactly through the first drain).
  printf 'note: later\n' >> "$state/t1.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --summary > "$out" 2>/dev/null \
    || fail "second drain failed on the mixed fixture"
  [ "$(grep -c '^t[0-9]* note:' "$out")" = 1 ] && grep -qxF 't1 note: later' "$out" \
    || fail "second drain did not show exactly the one new note: $(cat "$out")"
  grep -qxF 't3 [key=b3] blocked: waiting on tool' "$out" \
    || fail "second drain dropped an open decision: $(cat "$out")"
  pass "a mixed fixture drains to the recorded sections, then shows only the new note"
}

test_hundred_task_home_drains_within_the_bound() {
  local dir state out i j f shown omitted bound=${FM_DRAIN_MANY_TASKS_CPU_BOUND:-35} cpu
  dir=$(make_case hundred-tasks)
  state="$dir/state"
  out="$dir/drain.out"
  for i in $(seq 1 100); do
    f="$state/task$i.status"
    {
      printf 'needs-decision [key=k%s]: pick option %s\n' "$i" "$i"
      for j in $(seq 1 300); do printf 'working: routine filler line %s of task %s\n' "$j" "$i"; done
    } > "$f"
  done

  local TIMEFORMAT='%U %S'
  cpu=$( { time FM_STATE_OVERRIDE="$state" "$DRAIN" --summary > "$out" 2>/dev/null; } 2>&1 ) \
    || fail "drain failed on the 100-task home"
  cpu=$(printf '%s\n' "$cpu" | awk '{ printf "%d", $1 + $2 }')
  # The section is byte-capped: listed entries plus the omitted count cover all 100.
  shown=$(grep -c '\] needs-decision: pick option' "$out")
  omitted=$(sed -n 's/^OPEN DECISIONS: \([0-9]*\) more omitted.*/\1/p' "$out")
  [ "$((shown + ${omitted:-0}))" = 100 ] \
    || fail "the drain accounted for $shown shown + ${omitted:-0} omitted of 100 open decisions"
  [ "$cpu" -le "$bound" ] \
    || fail "drain of 100 tasks took ${cpu}s CPU, over the ${bound}s bound (per-line forks are back)"
  pass "a 100-task home drains in ${cpu}s CPU, within the ${bound}s bound"
}

fm_test_run test_mixed_fixture_output_is_unchanged test_hundred_task_home_drains_within_the_bound
