#!/usr/bin/env bash
# Behavior tests for Claude Code's usage-limit stall: the prompt signature
# (fm_composer_blocking_dialog), the stated-reset reading in
# bin/fm-claude-limit-lib.sh, and the guarded recovery in bin/fm-limit-resume.sh.
#
# Adapted from the tests of nikzorz/firstmate commit 100698b12 (MIT licence,
# "Copyright (c) 2026 Kun Chen" as carried in that repository's LICENSE), which
# pin the same safety direction. The quota-window cases there become the
# stated-reset cases here, and the recovery cases drive the Escape through
# bin/fm-control.sh instead of a backend key call.
#
# The fork's incident these pin: three crewmates exhausted the account usage
# limit and stopped on Claude Code's interactive choice prompt, which waits for a
# human indefinitely. They idled about 8.7 hours after the five-hour window had
# already reset. Two properties made it expensive, and both are covered here:
# the stalled pane looks healthy, and it never self-resumes.
#
# The safety direction matters more than the happy path. Every case that sends a
# key first proves the condition; every case that cannot prove it sends nothing:
#   (a) signature: the real prompt matches; ordinary worker output that discusses
#       limits does not, and neither does the prompt's own text quoted inside a
#       working pane;
#   (b) stated reset: read from the pane and placed at its first occurrence
#       after the earliest evidence the stall had begun, so it never lands
#       before the stated moment, and an unreadable or unplaceable one refuses;
#   (c) recovery: only a fresh live match plus a passed reset sends the interrupt
#       (through fm-control.sh), the prompt must be PROVABLY gone before the
#       resume instruction is sent (a pane that cannot be re-read refuses too),
#       and the steer tells the crew to re-read its own state;
#   (d) before the reset the wait is recorded with the fleet's `paused:`
#       vocabulary and an `until` time, idempotently, and nothing is sent - and
#       once recovery lands, that wait is closed again, but only ever the one
#       this script itself opened.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-claude-limit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-limit-resume)

# --- pane fixtures ----------------------------------------------------------

# clock_phrase <epoch> [zone]: the clock time Claude prints, in the same shape
# (`6:40pm`, lowercase meridiem, no leading zero), for the zone's wall clock.
clock_phrase() {
  local epoch=$1 zone=${2:-UTC} out
  out=$(TZ=$zone date -d "@$epoch" +%I:%M%p 2>/dev/null || TZ=$zone date -r "$epoch" +%I:%M%p)
  out=$(printf '%s' "$out" | tr 'APM' 'apm' | sed 's/^0//')
  printf '%s' "$out"
}

# The prompt as the installed Claude Code 2.1.319 builds it from its own strings:
# the limit line above, the question, the continue-automatically row carrying the
# time, the stop row, and the confirm footer. Nothing is drawn below it because
# the prompt replaces the composer.
limit_prompt_pane() {  # <reset-phrase>
  cat <<EOF
● Pushed the branch and opened the pull request.

You've hit your limit · resets $1

   What do you want to do?

 ❯ 1. Wait here, then continue automatically at $1
   2. Upgrade your plan
   3. Stop and wait for limit to reset

   Enter to confirm · Esc to cancel
EOF
}

# The prompt exactly as the fork captured it in its incident: no time-bearing
# row, the time in a sentence above, and the long stop label.
fork_incident_pane() {
  cat <<'EOF'
● Pushed the branch and opened the pull request.

Claude usage limit reached. Your limit will reset at 6:40pm.

   What do you want to do?

 ❯ 1. Stop and wait for limit to reset
   2. Upgrade your plan

   Enter to confirm · Esc to cancel
EOF
}

# Ordinary worker output that uses the word "limit" in prose, including the
# prompt's own question, inside a healthy pane whose composer box is still drawn.
limit_prose_pane() {
  cat <<'EOF'
● Bash(git commit -m "fix(api): back off when the provider rate limit is hit")
  ⎿  [fm/api-retry 1a2b3c4] fix(api): back off when the provider rate limit is hit

● The note records that we wait for limit to reset instead of hammering the
  endpoint, and that the limit resets 6:40pm each day.
  What do you want to do?

╭────────────────────────────────────────────────────────╮
│ >                                                      │
╰────────────────────────────────────────────────────────╯
  ? for shortcuts
EOF
}

# The prompt's own text quoted inside tool output on a WORKING pane - a crewmate
# reading these very fixtures. Every text anchor is present and in order; only
# the composer box still drawn underneath separates it from the real stall.
limit_quoted_pane() {
  cat <<'EOF'
● Read(tests/fm-limit-resume.test.sh)
  ⎿     What do you want to do?
      ❯ 1. Stop and wait for limit to reset
        2. Upgrade your plan
        Enter to confirm · Esc to cancel

╭────────────────────────────────────────────────────────╮
│ >                                                      │
╰────────────────────────────────────────────────────────╯
  ? for shortcuts
EOF
}

# A dismissed prompt: the composer is back and the crew is idle.
dismissed_pane() {
  cat <<'EOF'
● Pushed the branch and opened the pull request.

╭────────────────────────────────────────────────────────╮
│ >                                                      │
╰────────────────────────────────────────────────────────╯
  ? for shortcuts
EOF
}

# --- (a) dialog signature ---------------------------------------------------

test_signature_matches_the_real_prompt() {
  limit_prompt_pane '6:40pm (UTC)' | fm_claude_limit_dialog_match \
    || fail "the 2.1.319 usage-limit prompt did not match"
  fork_incident_pane | fm_claude_limit_dialog_match \
    || fail "the prompt as the fork captured it did not match"
  [ "$(fm_composer_blocking_dialog "$(fork_incident_pane)")" = "$FM_COMPOSER_CLAUDE_LIMIT_DIALOG_NAME" ] \
    || fail "the dialog recogniser did not name the usage-limit prompt"
  pass "the claude usage-limit prompt matches, in the observed and the 2.1.319 shapes"
}

test_signature_matches_stop_label_status_line_and_styling() {
  # The build that offers to continue automatically labels the stop row `Stop`.
  limit_prompt_pane '6:40pm' | sed 's/Stop and wait for limit to reset/Stop/' | fm_claude_limit_dialog_match \
    || fail "the short Stop label did not match"
  # A status line under the footer is admitted, up to two rows.
  { limit_prompt_pane '6:40pm'; printf '  ~/proj  main  ctx 42%%\n'; } | fm_claude_limit_dialog_match \
    || fail "one status row under the footer broke the match"
  { limit_prompt_pane '6:40pm'; printf '  row one\n  row two\n'; } | fm_claude_limit_dialog_match \
    || fail "two status rows under the footer broke the match"
  # A plain '>' selection marker and SGR styling are structural noise.
  limit_prompt_pane '6:40pm' | sed 's/❯/>/' | fm_claude_limit_dialog_match \
    || fail "a plain '>' selection marker did not match"
  limit_prompt_pane '6:40pm' | sed 's/^\(.*\)$/\x1b[2m\1\x1b[0m/' | fm_claude_limit_dialog_match \
    || fail "a styled capture of the prompt did not match"
  pass "the signature tolerates the Stop label, a status line under the footer, the plain marker and ANSI styling"
}

test_signature_ignores_ordinary_limit_prose() {
  limit_prose_pane | fm_claude_limit_dialog_match \
    && fail "prose discussing rate limits matched the usage-limit signature"
  limit_quoted_pane | fm_claude_limit_dialog_match \
    && fail "the prompt's own text quoted in tool output matched on a working pane"
  # The same question under a different dialog is not this prompt.
  printf '%s\n' 'What do you want to do?' ' ❯ 1. Upgrade now' '   2. Continue with Pro' \
    '   Enter to confirm · Esc to cancel' | fm_claude_limit_dialog_match \
    && fail "another dialog that asks the same question matched"
  # The background-task exit picker keeps its own name.
  [ "$(fm_composer_blocking_dialog "$(printf '%s\n' 'Background work is running' '❯ 1. Exit and stop tasks' \
    'Enter to confirm · Esc to cancel')")" = 'Claude background-task exit picker' ] \
    || fail "the background-task exit picker was no longer recognised"
  pass "ordinary worker output never matches, quoted prompt text included"
}

test_signature_requires_every_anchor_in_order() {
  local base
  base=$(limit_prompt_pane '6:40pm')

  printf '%s' "$base" | grep -v 'What do you want to do' | fm_claude_limit_dialog_match \
    && fail "a missing question anchor still matched"
  printf '%s' "$base" | grep -v 'Stop and wait for limit to reset' | fm_claude_limit_dialog_match \
    && fail "a missing stop-row anchor still matched"
  printf '%s' "$base" | grep -v 'Enter to confirm' | fm_claude_limit_dialog_match \
    && fail "a missing confirm anchor still matched"

  # Same anchors, reversed order: not a rendered prompt.
  printf '   Enter to confirm · Esc to cancel\n ❯ 1. Stop and wait for limit to reset\n   What do you want to do?\n' \
    | fm_claude_limit_dialog_match && fail "out-of-order anchors matched"

  # Same anchors, but with content below them: the live prompt owns the bottom
  # of the pane, so a block buried above other output is not one.
  { printf '%s\n' "$base"; printf '● Continuing with the next file.\n● And the next one.\n● And another.\n'; } \
    | fm_claude_limit_dialog_match && fail "a prompt block with output below it matched"

  printf '' | fm_claude_limit_dialog_match && fail "empty input matched"
  pass "the signature requires all three anchors, in order, owning the bottom of the pane"
}

# --- (b) stated reset -------------------------------------------------------

test_reset_phrase_reads_every_wording() {
  local phrase
  phrase=$(limit_prompt_pane '6:40pm (Europe/London)' | fm_claude_limit_reset_phrase) \
    || fail "the 2.1.319 prompt stated no reset"
  assert_equals '6:40pm (Europe/London)' "$phrase" "the nearest stated reset was not the one read"
  phrase=$(fork_incident_pane | fm_claude_limit_reset_phrase) || fail "the fork's wording stated no reset"
  assert_equals '6:40pm' "$phrase" "the fork's 'will reset at' wording was misread"
  phrase=$(printf 'You have hit your limit · resets 3pm\n' | fm_claude_limit_reset_phrase) || fail "a bare hour stated no reset"
  assert_equals '3pm' "$phrase" "a bare hour was misread"
  phrase=$(printf "You've hit your limit · resets Nov 9, 3pm (America/New_York)\n" | fm_claude_limit_reset_phrase) \
    || fail "a dated reset stated no reset"
  assert_equals 'Nov 9, 3pm (America/New_York)' "$phrase" "a dated reset was misread"
  phrase=$(printf 'resets Jan 2, 2027, 9:05am\n' | fm_claude_limit_reset_phrase) || fail "a dated reset with a year stated no reset"
  assert_equals 'Jan 2, 2027, 9:05am' "$phrase" "a dated reset with a year was misread"
  # The row nearest the prompt wins over an older limit line above it.
  phrase=$(printf 'resets 3pm\nWait here, then continue automatically at 4:15pm\n' | fm_claude_limit_reset_phrase) \
    || fail "two stated resets stated none"
  assert_equals '4:15pm' "$phrase" "an older stated reset beat the one nearest the prompt"
  pass "the stated reset is read from the limit line, the menu row and the fork's wording"
}

test_reset_phrase_ignores_unanchored_times() {
  printf 'The meeting is at 6:40pm, the build resets nightly.\n' | fm_claude_limit_reset_phrase \
    && fail "a time in prose with no reset wording was read as a stated reset"
  printf 'Wait here, then continue automatically shortly\n' | fm_claude_limit_reset_phrase \
    && fail "a menu row with no time was read as a stated reset"
  printf 'resets 25pm\n' | fm_claude_limit_reset_phrase \
    && fail "an out-of-range hour was read as a stated reset"
  printf '' | fm_claude_limit_reset_phrase && fail "empty input stated a reset"
  pass "a time without reset wording, and a row with no time, state no reset"
}

test_reset_epoch_places_a_clock_time_without_going_early() {
  local since got want
  since=$(date -u -d '2026-11-06 12:00' +%s 2>/dev/null || date -u -j -f '%Y-%m-%d %H:%M' '2026-11-06 12:00' +%s)

  got=$(fm_claude_limit_reset_epoch '6:40pm (UTC)' "$since") || fail "a UTC clock time was not placed"
  want=$((since + 6 * 3600 + 40 * 60))
  assert_equals "$want" "$got" "6:40pm UTC after noon was not placed at 18:40 the same day"

  # Already past on the day of the bound: the NEXT such time, never an earlier one.
  got=$(fm_claude_limit_reset_epoch '9:15am (UTC)' "$since") || fail "a past clock time was not placed"
  want=$((since + 21 * 3600 + 15 * 60))
  assert_equals "$want" "$got" "9:15am UTC after noon was not placed at 09:15 the next day"

  # A zone moves the instant: 6:40pm in New York in November is 23:40 UTC.
  got=$(fm_claude_limit_reset_epoch '6:40pm (America/New_York)' "$since") || fail "a named zone was not placed"
  want=$((since + 11 * 3600 + 40 * 60))
  assert_equals "$want" "$got" "6:40pm New York was not placed at 23:40 UTC"

  # 12am and 12pm are midnight and noon.
  got=$(fm_claude_limit_reset_epoch '12am (UTC)' "$since") || fail "12am was not placed"
  assert_equals "$((since + 12 * 3600))" "$got" "12am was not placed at the next midnight"
  got=$(fm_claude_limit_reset_epoch '12pm (UTC)' "$since") || fail "12pm was not placed"
  assert_equals "$since" "$got" "12pm was not placed at noon on the day of the bound"

  # A later bound can only move the answer later.
  got=$(fm_claude_limit_reset_epoch '6:40pm (UTC)' "$((since + 7 * 3600))") || fail "a later bound was not placed"
  assert_equals "$((since + 30 * 3600 + 40 * 60))" "$got" "a bound past the stated time did not roll to the next day"
  pass "a clock time lands on its first occurrence at or after the bound, in its own zone"
}

utc_epoch() {  # <YYYY-MM-DD HH:MM> -> epoch of that UTC wall-clock time
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d %H:%M' "$1" +%s
}

# Worked examples, each expected instant written out by hand from the stated
# clock time and the moment the stall began.
test_reset_epoch_follows_when_the_stall_began() {
  local got
  # Stalled at 14:00 on "resets 6:40pm": the reset is 18:40 that day, which a
  # watcher restarting at 22:00 must see as passed, not as tomorrow's.
  got=$(fm_claude_limit_reset_epoch '6:40pm (UTC)' "$(utc_epoch '2026-11-06 14:00')") \
    || fail "a reset after a 14:00 stall was not placed"
  assert_equals "$(utc_epoch '2026-11-06 18:40')" "$got" "the 18:40 after a 14:00 stall was misplaced"
  [ "$got" -lt "$(utc_epoch '2026-11-06 22:00')" ] || fail "the 18:40 reset was not passed by 22:00"
  # A weekly limit hit at 08:00 on "resets 6:40pm" is ten hours out, not passed.
  got=$(fm_claude_limit_reset_epoch '6:40pm (UTC)' "$(utc_epoch '2026-11-06 08:00')") \
    || fail "a weekly reset after an 08:00 stall was not placed"
  assert_equals "$(utc_epoch '2026-11-06 18:40')" "$got" "a reset more than five hours out was not kept for the same day"
  # A crew last wrote status at 09:00 and hit a weekly limit at 15:00 with
  # "resets 10am": seen at 15:00 that is tomorrow's 10:00, never today's.
  got=$(fm_claude_limit_reset_epoch '10am (UTC)' "$(utc_epoch '2026-11-06 15:00')") \
    || fail "a weekly reset seen at 15:00 was not placed"
  assert_equals "$(utc_epoch '2026-11-07 10:00')" "$got" "10am seen at 15:00 was not placed at tomorrow's 10:00"
  pass "a clock time is the first occurrence after the stall began, whether five or more hours out"
}

test_reset_epoch_places_a_dated_reset() {
  local since got want
  since=$(date -u -d '2026-11-06 12:00' +%s 2>/dev/null || date -u -j -f '%Y-%m-%d %H:%M' '2026-11-06 12:00' +%s)
  want=$(date -u -d '2026-11-09 15:00' +%s 2>/dev/null || date -u -j -f '%Y-%m-%d %H:%M' '2026-11-09 15:00' +%s)
  got=$(fm_claude_limit_reset_epoch 'Nov 9, 3pm (UTC)' "$since") || fail "a dated reset was not placed"
  assert_equals "$want" "$got" "Nov 9, 3pm was not placed in the current year"

  # A month already behind the bound by more than half a year is next year's.
  want=$(date -u -d '2027-01-02 09:05' +%s 2>/dev/null || date -u -j -f '%Y-%m-%d %H:%M' '2027-01-02 09:05' +%s)
  got=$(fm_claude_limit_reset_epoch 'Jan 2, 9:05am (UTC)' "$(( $(date -u -d '2026-11-06 12:00' +%s 2>/dev/null || date -u -j -f '%Y-%m-%d %H:%M' '2026-11-06 12:00' +%s) ))") \
    || fail "a dated reset in the new year was not placed"
  # Jan 2 2026 is ten months before the bound, so the year rolls to 2027.
  assert_equals "$want" "$got" "a month far behind the bound was not rolled to next year"

  got=$(fm_claude_limit_reset_epoch 'Jan 2, 2027, 9:05am (UTC)' "$since") || fail "a dated reset naming its year was not placed"
  assert_equals "$want" "$got" "a dated reset naming its year was misplaced"
  pass "a dated reset lands on its date, in the year it names or the nearest one"
}

test_reset_epoch_fails_closed() {
  local since
  since=$(date +%s)
  fm_claude_limit_reset_epoch '6:40pm (Not/AZone)' "$since" >/dev/null \
    && fail "an unknown zone was placed (it would silently read as UTC)"
  fm_claude_limit_reset_epoch '6:40pm (../../etc/passwd)' "$since" >/dev/null \
    && fail "a path-shaped zone was placed"
  fm_claude_limit_reset_epoch '13pm' "$since" >/dev/null && fail "hour 13 was placed"
  fm_claude_limit_reset_epoch '0am' "$since" >/dev/null && fail "hour 0 was placed"
  fm_claude_limit_reset_epoch '6:75pm' "$since" >/dev/null && fail "minute 75 was placed"
  fm_claude_limit_reset_epoch 'Foo 9, 3pm' "$since" >/dev/null && fail "an unknown month was placed"
  fm_claude_limit_reset_epoch 'Nov 40, 3pm' "$since" >/dev/null && fail "day 40 was placed"
  fm_claude_limit_reset_epoch 'soon' "$since" >/dev/null && fail "prose was placed"
  fm_claude_limit_reset_epoch '6:40pm' '' >/dev/null && fail "a missing bound was accepted"
  fm_claude_limit_reset_epoch '6:40pm' 'abc' >/dev/null && fail "a non-numeric bound was accepted"
  pass "an unknown zone, an out-of-range time or a missing bound is refused, never guessed"
}

# --- (c)/(d) guarded recovery ----------------------------------------------
#
# Each case gets a private bin/ of symlinks to the real scripts so the real
# fm-limit-resume.sh runs against its real source graph, with only fm-control.sh
# and fm-send.sh replaced by recorders. A fake tmux serves the viewport from a
# file; the recorded control call swaps in the after-interrupt pane when the case
# supplies one.
make_case() {  # <name> -> echoes case dir
  local d="$TMP_ROOT/$1" fb f name
  mkdir -p "$d/state" "$d/bin" "$d/wt" "$d/proj"
  for f in "$ROOT"/bin/*; do
    name=$(basename "$f")
    case "$name" in fm-control.sh|fm-send.sh) continue ;; esac
    ln -s "$f" "$d/bin/$name"
  done
  cat > "$d/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FM_FAKE_CONTROL_FAILS:-0}" = 1 ]; then exit 1; fi
printf '%s\n' "$*" >> "${FM_FAKE_CONTROLLOG:?}"
if [ "${FM_FAKE_PANE_UNREADABLE_AFTER_KEY:-0}" = 1 ]; then
  rm -f "${FM_FAKE_PANE_FILE:-}"
elif [ -n "${FM_FAKE_PANE_AFTER_KEY:-}" ] && [ -f "${FM_FAKE_PANE_AFTER_KEY:-}" ]; then
  cat "$FM_FAKE_PANE_AFTER_KEY" > "$FM_FAKE_PANE_FILE"
fi
exit 0
SH
  cat > "$d/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FM_FAKE_SEND_FAILS:-0}" = 1 ]; then exit 1; fi
printf '%s\n' "$*" >> "${FM_FAKE_SENDLOG:?}"
exit 0
SH
  chmod +x "$d/bin/fm-control.sh" "$d/bin/fm-send.sh"
  fb="$d/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  capture-pane)
    [ -f "${FM_FAKE_PANE_FILE:-}" ] || exit 1
    cat "$FM_FAKE_PANE_FILE" ;;
  send-keys)
    shift
    printf '%s\n' "$*" >> "${FM_FAKE_KEYLOG:?}" ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  : > "$d/control.log"
  : > "$d/sent.log"
  : > "$d/keys.log"
  printf '%s\n' "$d"
}

run_resume() {  # <case-dir> <args...>
  local d=$1; shift
  PATH="$d/fakebin:$PATH" \
  FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
  FM_FAKE_CONTROLLOG="$d/control.log" FM_FAKE_SENDLOG="$d/sent.log" FM_FAKE_KEYLOG="$d/keys.log" \
  FM_LIMIT_RESUME_SETTLE="${FM_LIMIT_RESUME_SETTLE:-0}" \
    "$d/bin/fm-limit-resume.sh" "$@"
}

setup_task() {  # <case-dir> <id> <harness>
  fm_write_meta "$1/state/$2.meta" "window=fm:fm-$2" "worktree=$1/wt" "project=$1/proj" \
    "kind=ship" "harness=$3" "backend=tmux"
}

# stated_reset <seconds-from-now> -> a clock phrase in UTC for that moment
stated_reset() {
  clock_phrase "$(( $(date +%s) + $1 ))" UTC | sed 's/$/ (UTC)/'
}

# long_ago: the --since a watcher would pass for a stall that began four hours
# ago, so a stated reset a few hours back is placed on today's clock.
long_ago() { printf '%s' "$(( $(date +%s) - 4 * 3600 ))"; }

test_recovery_refuses_non_claude_harness() {
  local d; d=$(make_case refuse-harness)
  setup_task "$d" stalled codex
  limit_prompt_pane "$(stated_reset -3600)" > "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" run_resume "$d" --since "$(long_ago)" stalled >/dev/null 2>&1 \
    && fail "recovery ran against a non-claude harness"
  [ ! -s "$d/control.log" ] || fail "an interrupt was sent to a non-claude harness"
  pass "recovery refuses a task whose recorded harness is not claude"
}

test_recovery_refuses_unresolvable_targets() {
  local d out; d=$(make_case refuse-target)
  out=$(run_resume "$d" ghost 2>&1) && fail "recovery ran for a task with no metadata"
  assert_contains "$out" "no metadata" "an unknown task did not report a missing record"

  fm_write_meta "$d/state/notarget.meta" "worktree=$d/wt" "project=$d/proj" "kind=ship" "harness=claude" "backend=tmux"
  out=$(run_resume "$d" notarget 2>&1) && fail "recovery ran for a task with no recorded endpoint"
  assert_contains "$out" "REFUSED" "a task with no endpoint did not report the refusal"

  fm_write_meta "$d/state/remote.meta" "window=fm:fm-remote" "worktree=$d/wt" "project=$d/proj" \
    "kind=secondmate" "harness=claude" "backend=tmux" "remote_host=elsewhere"
  out=$(run_resume "$d" remote 2>&1) && fail "recovery ran for a remotely placed task"
  assert_contains "$out" "remote host" "a remotely placed task did not report why it was refused"
  [ ! -s "$d/control.log" ] || fail "an interrupt was sent for an unresolvable target"
  pass "recovery refuses, with a diagnostic, when the task, its endpoint or its placement cannot be used"
}

test_recovery_refuses_without_a_live_match() {
  local d; d=$(make_case refuse-no-match)
  setup_task "$d" stalled claude
  limit_prose_pane > "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" run_resume "$d" --since "$(long_ago)" stalled >/dev/null 2>&1 \
    && fail "recovery ran against a working pane"
  [ ! -s "$d/control.log" ] || fail "an interrupt was sent to a working pane"

  # An unreadable pane must refuse too, never assume.
  FM_FAKE_PANE_FILE="$d/missing.txt" run_resume "$d" --since "$(long_ago)" stalled >/dev/null 2>&1 \
    && fail "recovery ran against an unreadable pane"
  [ ! -s "$d/control.log" ] || fail "an interrupt was sent to an unreadable pane"
  [ ! -s "$d/state/stalled.status" ] || fail "a pane that was not the prompt got a status line"
  pass "recovery refuses unless the live viewport proves the prompt is showing"
}

test_recovery_refuses_when_no_reset_is_stated() {
  local d out; d=$(make_case refuse-no-reset)
  setup_task "$d" stalled claude
  printf '%s\n' '● Pushed the branch.' '' '   What do you want to do?' '' ' ❯ 1. Stop and wait for limit to reset' \
    '   2. Upgrade your plan' '' '   Enter to confirm · Esc to cancel' > "$d/pane.txt"
  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" run_resume "$d" --since "$(long_ago)" stalled 2>&1) \
    && fail "recovery ran for a prompt that states no reset"
  assert_contains "$out" "states no reset time" "the missing reset was not reported"
  [ ! -s "$d/control.log" ] || fail "an interrupt was sent without a stated reset"
  [ ! -s "$d/state/stalled.status" ] || fail "an unstated reset was recorded as a settled wait"
  pass "recovery refuses, and records nothing, when the prompt states no reset it can read"
}

test_recovery_refuses_an_unplaceable_reset() {
  local d out; d=$(make_case refuse-unplaceable)
  setup_task "$d" stalled claude
  limit_prompt_pane '6:40pm (Not/AZone)' > "$d/pane.txt"
  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" run_resume "$d" --since "$(long_ago)" stalled 2>&1) \
    && fail "recovery ran for a reset in an unknown zone"
  assert_contains "$out" "cannot place" "the unplaceable reset was not reported"
  [ ! -s "$d/control.log" ] || fail "an interrupt was sent for an unplaceable reset"
  [ ! -s "$d/state/stalled.status" ] || fail "an unplaceable reset was recorded as a settled wait"
  pass "recovery refuses when the stated reset is in a zone it does not know"
}

test_future_reset_records_a_timed_wait() {
  local d out last until_iso; d=$(make_case future-wait)
  setup_task "$d" stalled claude
  limit_prompt_pane "$(stated_reset 7200)" > "$d/pane.txt"
  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" run_resume "$d" stalled) || fail "recording a timed wait exited non-zero"
  [ ! -s "$d/control.log" ] || fail "an interrupt was sent before the stated reset"
  [ ! -s "$d/sent.log" ] || fail "a steer was sent before the stated reset"
  assert_contains "$out" "not reached" "the pre-reset outcome was not reported"
  last=$(grep -v '^[[:space:]]*$' "$d/state/stalled.status" | tail -1)
  case "$last" in
    paused*) ;;
    *) fail "the wait was not recorded with the paused vocabulary: $last" ;;
  esac
  until_iso=$(printf '%s' "$last" | sed -n 's/.* until \([0-9T:Z-]*\).*/\1/p')
  [ -n "$until_iso" ] || fail "the recorded wait names no until time: $last"
  # shellcheck source=/dev/null
  ( . "$ROOT/bin/fm-classify-lib.sh"; status_paused_until "$last" >/dev/null ) \
    || fail "the watcher's own declared-wait reader could not read the recorded until time: $last"
  # The recorded time is never before the stated reset: at least an hour out here.
  [ "$(( $(TZ=UTC date -d "${until_iso%Z}:00" +%s 2>/dev/null || TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "${until_iso%Z}:00" +%s) - $(date +%s) ))" -gt 3000 ] \
    || fail "the recorded wait ends sooner than the stated reset: $last"

  # Idempotent: a recheck on the same unchanged wait must not stack lines, since
  # every status append is a wake-worthy event for the watcher.
  FM_FAKE_PANE_FILE="$d/pane.txt" run_resume "$d" stalled >/dev/null || fail "the second recheck exited non-zero"
  [ "$(grep -c '^paused' "$d/state/stalled.status")" -eq 1 ] \
    || fail "re-running against an unchanged wait stacked duplicate paused lines"
  # A later, different lower bound must not move the recorded answer either.
  FM_FAKE_PANE_FILE="$d/pane.txt" run_resume "$d" --since "$(( $(date +%s) + 90000 ))" stalled >/dev/null \
    || fail "a recheck with another bound exited non-zero"
  [ "$(grep -c '^paused' "$d/state/stalled.status")" -eq 1 ] \
    || fail "a recheck with a different lower bound re-recorded the wait"
  pass "a stated reset still ahead records one timed wait (until its reset) and sends nothing"
}

test_a_reset_inside_the_margin_still_waits() {
  local d; d=$(make_case margin-wait)
  setup_task "$d" stalled claude
  limit_prompt_pane "$(stated_reset -3600)" > "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_CLAUDE_LIMIT_RESET_MARGIN=7200 \
    run_resume "$d" --since "$(long_ago)" stalled >/dev/null || fail "a margin wait exited non-zero"
  [ ! -s "$d/control.log" ] || fail "an interrupt was sent inside the margin past the stated reset"
  grep -q '^paused' "$d/state/stalled.status" || fail "the margin wait was not recorded"
  pass "the margin keeps a just-passed reset waiting"
}

# The fork's overnight case end to end: stalled about eight hours ago (the
# evidence the watcher passes), first asked about now, on a clock time that
# passed over three hours ago. That reset has passed: recover now.
test_a_reset_passed_since_the_stall_recovers_at_once() {
  local d out; d=$(make_case passed-since-stall)
  setup_task "$d" stalled claude
  limit_prompt_pane "$(stated_reset -12000)" > "$d/pane.txt"
  dismissed_pane > "$d/after.txt"
  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    run_resume "$d" --since "$(( $(date +%s) - 8 * 3600 ))" stalled) || fail "a passed reset exited non-zero"
  assert_contains "$out" "dismissed" "a reset that passed since the stall was not recovered"
  [ "$(grep -c . "$d/control.log")" -eq 1 ] || fail "a passed reset did not send exactly one interrupt"
  ! grep -q '^paused' "$d/state/stalled.status" 2>/dev/null \
    || fail "a reset that passed since the stall was put off as a wait until the next day"
  pass "a stated clock time that passed after the stall began recovers at once"
}

# A wait more than five hours out records nothing and sends nothing, so the
# stall keeps reaching the supervisor as an ordinary stale wake.
expect_no_wait_and_nothing_sent() {  # <case-dir> <what>
  [ ! -s "$1/control.log" ] || fail "an interrupt was sent before the stated reset ($2)"
  [ ! -s "$1/sent.log" ] || fail "a steer was sent before the stated reset ($2)"
  ! grep -q '^paused' "$1/state/stalled.status" 2>/dev/null \
    || fail "a wait more than five hours out was declared as a pause ($2)"
}

# A weekly limit prints a clock time too, and it can be many hours out: ten
# hours after a stall the watcher saw now is not reached.
test_a_reset_many_hours_out_sends_nothing_and_declares_no_wait() {
  local d out; d=$(make_case weekly-wait)
  setup_task "$d" stalled claude
  limit_prompt_pane "$(stated_reset 38400)" > "$d/pane.txt"
  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" run_resume "$d" --since "$(date +%s)" stalled) \
    || fail "a reset ten hours out exited non-zero"
  expect_no_wait_and_nothing_sent "$d" "ten hours out"
  assert_contains "$out" "more than five hours out" "the undeclared long wait was not reported"
  pass "a clock time more than five hours out sends nothing and declares no pause"
}

# The crew last wrote status before the stated clock time and stalled after
# it: the watcher's bound is when it saw the prompt, so "resets <5h ago>" is
# tomorrow's, about nineteen hours out, and nothing is sent before it.
test_a_clock_time_behind_the_stall_is_tomorrows() {
  local d; d=$(make_case behind-the-stall)
  setup_task "$d" stalled claude
  printf 'working: implementing the parser\n' > "$d/state/stalled.status"
  limit_prompt_pane "$(stated_reset -18000)" > "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" run_resume "$d" --since "$(date +%s)" stalled >/dev/null \
    || fail "a clock time behind the stall exited non-zero"
  expect_no_wait_and_nothing_sent "$d" "nineteen hours out"
  pass "a stated clock time already behind the stall is tomorrow's, and nothing is sent early"
}

# No bound at all: the next occurrence after now, so a stated time that has
# already gone by today is tomorrow's, never a resume before the stated reset.
test_without_a_bound_the_next_occurrence_is_awaited() {
  local d; d=$(make_case no-reference)
  setup_task "$d" stalled claude
  limit_prompt_pane "$(stated_reset -7200)" > "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" run_resume "$d" stalled >/dev/null || fail "a wait with no bound exited non-zero"
  expect_no_wait_and_nothing_sent "$d" "twenty-two hours out"
  pass "with no bound, the next occurrence is awaited and nothing is sent"
}

test_a_passed_reset_dismisses_and_resumes() {
  local d out; d=$(make_case reset-recover)
  setup_task "$d" stalled claude
  limit_prompt_pane "$(stated_reset -7200)" > "$d/pane.txt"
  dismissed_pane > "$d/after.txt"
  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    run_resume "$d" --since "$(long_ago)" stalled) || fail "recovery after the stated reset exited non-zero"
  [ "$(grep -c . "$d/control.log")" -eq 1 ] || fail "recovery made other than one control call"
  assert_equals "stalled interrupt" "$(cat "$d/control.log")" "the Escape did not go through fm-control.sh interrupt"
  [ ! -s "$d/keys.log" ] || fail "recovery sent a raw key to the endpoint"
  [ -s "$d/sent.log" ] || fail "recovery did not send a resume instruction"
  assert_contains "$(cat "$d/sent.log")" "stalled" "the steer was not addressed to the task"
  assert_contains "$(cat "$d/sent.log")" "re-read your own current state" \
    "the resume instruction did not tell the crew to re-check its actual state"
  assert_not_contains "$(cat "$d/sent.log")" "resume where you" \
    "the resume instruction asserted a remembered position"
  assert_contains "$out" "dismissed" "the recovery outcome was not reported"
  assert_present "$d/state/.limit-resumed-stalled" "the recovery left no cooldown record"
  pass "a passed reset is recovered with one interrupt through fm-control plus a re-check-your-state steer"
}

test_recovery_stops_when_the_prompt_survives_the_interrupt() {
  local d; d=$(make_case escape-ignored)
  setup_task "$d" stalled claude
  limit_prompt_pane "$(stated_reset -7200)" > "$d/pane.txt"
  # No after-key pane: the prompt is still showing on the re-read.
  FM_FAKE_PANE_FILE="$d/pane.txt" run_resume "$d" --since "$(long_ago)" stalled >/dev/null 2>&1 \
    && fail "recovery continued past a prompt that survived the interrupt"
  [ "$(grep -c . "$d/control.log")" -eq 1 ] || fail "recovery escalated more keys after the interrupt did not land"
  [ ! -s "$d/sent.log" ] || fail "a resume instruction was sent while the prompt was still showing"
  pass "a prompt that survives the interrupt stops the run instead of escalating keys"
}

test_recovery_stops_when_the_pane_is_unreadable_after_the_interrupt() {
  local d out; d=$(make_case escape-unreadable)
  setup_task "$d" stalled claude
  limit_prompt_pane "$(stated_reset -7200)" > "$d/pane.txt"
  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_UNREADABLE_AFTER_KEY=1 \
    run_resume "$d" --since "$(long_ago)" stalled 2>&1) \
    && fail "recovery continued past a pane it could not re-read after the interrupt"
  assert_contains "$out" "could not be read" "an unreadable re-read was not reported"
  [ "$(grep -c . "$d/control.log")" -eq 1 ] || fail "recovery escalated more keys after an unreadable re-read"
  [ ! -s "$d/sent.log" ] || fail "a resume instruction was sent without proof the prompt was gone"
  pass "an unreadable pane after the interrupt refuses instead of steering on unproven dismissal"
}

test_a_failed_interrupt_sends_no_steer() {
  local d out; d=$(make_case control-fails)
  setup_task "$d" stalled claude
  limit_prompt_pane "$(stated_reset -7200)" > "$d/pane.txt"
  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_CONTROL_FAILS=1 \
    run_resume "$d" --since "$(long_ago)" stalled 2>&1) \
    && fail "a control-plane refusal was reported as success"
  assert_contains "$out" "control plane" "the control-plane refusal was not reported"
  [ ! -s "$d/sent.log" ] || fail "a steer was sent after the interrupt failed"
  assert_absent "$d/state/.limit-resumed-stalled" "a failed interrupt left a cooldown record"
  pass "an interrupt the control plane refuses sends no steer and leaves no cooldown"
}

test_a_returned_prompt_with_the_same_reset_is_not_looped() {
  local d out phrase; d=$(make_case cooldown)
  setup_task "$d" stalled claude
  # Recovered just after the stated reset, as the watcher would.
  phrase=$(stated_reset -120)
  limit_prompt_pane "$phrase" > "$d/pane.txt"
  dismissed_pane > "$d/after.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    run_resume "$d" --since "$(long_ago)" stalled >/dev/null || fail "the first recovery exited non-zero"
  # The prompt is back with the same stated reset: the window had not reset.
  # The redraw is the latest evidence, so the watcher's bound is now, which
  # places the same clock time on the next day.
  limit_prompt_pane "$phrase" > "$d/pane.txt"
  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    run_resume "$d" --since "$(date +%s)" stalled 2>&1) \
    && fail "recovery looped on a prompt that returned with the same stated reset"
  assert_contains "$out" "already recovered" "the repeat refusal was not explained"
  [ "$(grep -c . "$d/control.log")" -eq 1 ] || fail "the repeat sent a second interrupt"
  ! grep -q '^paused' "$d/state/stalled.status" 2>/dev/null \
    || fail "a returned prompt with the same reset was hidden as a declared wait"
  # A different stated reset is a new prompt and recovers again.
  limit_prompt_pane "$(stated_reset -5400)" > "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    run_resume "$d" --since "$(long_ago)" stalled >/dev/null || fail "a prompt with a new stated reset was not recovered"
  [ "$(grep -c . "$d/control.log")" -eq 2 ] || fail "the new stated reset did not send its own interrupt"
  pass "the same stated reset is refused for inspection, never re-sent or absorbed as a wait; a new one recovers"
}

test_recovery_uses_the_wait_it_recorded() {
  local d last before; d=$(make_case recorded-wait)
  setup_task "$d" stalled claude
  limit_prompt_pane "$(stated_reset 7200)" > "$d/pane.txt"
  dismissed_pane > "$d/after.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" run_resume "$d" stalled >/dev/null || fail "recording the wait exited non-zero"
  last=$(grep -v '^[[:space:]]*$' "$d/state/stalled.status" | tail -1)
  [ -n "$(printf '%s' "$last" | sed -n 's/.* until \([0-9T:Z-]*\).*/\1/p')" ] || fail "no until time was recorded: $last"
  # Time passes: the recorded until moves into the past. The recorded line, not
  # a recomputation, decides - so a bound that would roll to tomorrow changes nothing.
  sed -i.bak 's/ until [0-9T:Z-]*/ until 2020-01-01T00:00Z/' "$d/state/stalled.status"
  before=$(grep -c . "$d/control.log")
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    run_resume "$d" --since "$(( $(date +%s) + 90000 ))" stalled >/dev/null \
    || fail "recovery after the recorded wait elapsed exited non-zero"
  [ "$(grep -c . "$d/control.log")" -eq $((before + 1)) ] || fail "the elapsed recorded wait did not recover the crew"
  pass "once the recorded wait's until time passes, recovery follows it rather than recomputing"
}

# The wait this script opens must not outlive the condition it describes. The
# crew never learns that line exists, so if recovery leaves it standing, a resume
# that silently does not take idles on the declared-pause cadence instead of
# surfacing on the wedge cadence - the exact hours-unnoticed failure this feature
# exists to end.
test_recovery_closes_the_wait_it_opened() {
  local d last; d=$(make_case close-pause)
  setup_task "$d" stalled claude
  limit_prompt_pane "$(stated_reset 7200)" > "$d/pane.txt"
  dismissed_pane > "$d/after.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" run_resume "$d" stalled >/dev/null || fail "recording the timed wait exited non-zero"
  grep -q '^paused' "$d/state/stalled.status" || fail "the timed wait was not recorded"
  sed -i.bak 's/ until [0-9T:Z-]*/ until 2020-01-01T00:00Z/' "$d/state/stalled.status"

  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    run_resume "$d" stalled >/dev/null || fail "recovery after a recorded wait exited non-zero"
  [ -s "$d/sent.log" ] || fail "recovery did not send the resume instruction"
  last=$(grep -v '^[[:space:]]*$' "$d/state/stalled.status" | tail -1)
  case "$last" in
    paused*) fail "recovery left its own paused line standing as the crew's last event" ;;
    working*) ;;
    *) fail "recovery closed the wait with an unexpected line: $last" ;;
  esac
  pass "recovery closes the timed wait it opened, returning the crew to the wedge cadence"
}

# The close is owned, not blanket: it fires only for the line this script wrote.
test_recovery_closes_only_a_wait_it_owns() {
  local d; d=$(make_case foreign-pause)
  setup_task "$d" stalled claude
  limit_prompt_pane "$(stated_reset -7200)" > "$d/pane.txt"
  dismissed_pane > "$d/after.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    run_resume "$d" --since "$(long_ago)" stalled >/dev/null \
    || fail "recovery with no recorded wait exited non-zero"
  [ ! -s "$d/state/stalled.status" ] \
    || fail "recovery wrote a status line although it had no wait to close"

  # A pause the CREW declared for its own reason still means what it says.
  printf 'paused: waiting on the upstream release\n' > "$d/state/stalled.status"
  rm -f "$d/state/.limit-resumed-stalled"
  limit_prompt_pane "$(stated_reset -7200)" > "$d/pane.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" \
    run_resume "$d" --since "$(long_ago)" stalled >/dev/null \
    || fail "recovery over a crew-declared pause exited non-zero"
  [ "$(cat "$d/state/stalled.status")" = "paused: waiting on the upstream release" ] \
    || fail "recovery closed a paused line it did not open"
  pass "recovery writes nothing when there is no wait of its own, and never closes the crew's"
}

# A malformed operator knob must never abort the run between the interrupt and
# the steer: that would leave the crew dismissed, unsteered, and undiagnosed.
test_malformed_settle_falls_back_to_the_default() {
  local d; d=$(make_case settle-malformed)
  setup_task "$d" stalled claude
  limit_prompt_pane "$(stated_reset -7200)" > "$d/pane.txt"
  dismissed_pane > "$d/after.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" FM_LIMIT_RESUME_SETTLE=1.2.3 \
    run_resume "$d" --since "$(long_ago)" stalled >/dev/null 2>&1 \
    || fail "a malformed settle value aborted the run after the interrupt had been sent"
  [ -s "$d/sent.log" ] || fail "the resume instruction did not land under a malformed settle value"
  pass "a malformed settle value falls back to the default instead of aborting mid-recovery"
}

test_failed_steer_is_reported_not_swallowed() {
  local d; d=$(make_case steer-fails)
  setup_task "$d" stalled claude
  limit_prompt_pane "$(stated_reset -7200)" > "$d/pane.txt"
  dismissed_pane > "$d/after.txt"
  FM_FAKE_PANE_FILE="$d/pane.txt" FM_FAKE_PANE_AFTER_KEY="$d/after.txt" FM_FAKE_SEND_FAILS=1 \
    run_resume "$d" --since "$(long_ago)" stalled >/dev/null 2>&1 \
    && fail "a resume instruction that did not land was reported as success"
  pass "a resume instruction that does not land is reported, not swallowed"
}

test_check_only_never_sends_or_records() {
  local d out; d=$(make_case check-only)
  setup_task "$d" stalled claude
  limit_prompt_pane "$(stated_reset -7200)" > "$d/pane.txt"
  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" run_resume "$d" --check --since "$(long_ago)" stalled) \
    || fail "--check exited non-zero on a recoverable stall"
  assert_contains "$out" "recoverable" "--check did not report a recoverable stall"
  [ ! -s "$d/control.log" ] || fail "--check sent an interrupt"
  [ ! -s "$d/sent.log" ] || fail "--check sent a steer"
  [ ! -s "$d/state/stalled.status" ] || fail "--check wrote a status line"

  limit_prompt_pane "$(stated_reset 7200)" > "$d/pane.txt"
  out=$(FM_FAKE_PANE_FILE="$d/pane.txt" run_resume "$d" --check stalled) \
    || fail "--check exited non-zero on a wait still ahead"
  assert_contains "$out" "not reached" "--check did not report the wait still ahead"
  [ ! -s "$d/state/stalled.status" ] || fail "--check wrote a status line for a wait still ahead"
  pass "--check reports the verdict without sending or recording anything"
}

test_usage_errors_exit_two() {
  local d; d=$(make_case usage)
  run_resume "$d" >/dev/null 2>&1; expect_code 2 $? "no task id"
  run_resume "$d" --since >/dev/null 2>&1; expect_code 2 $? "--since without a value"
  run_resume "$d" --since soon stalled >/dev/null 2>&1; expect_code 2 $? "--since with a non-epoch"
  run_resume "$d" --bogus stalled >/dev/null 2>&1; expect_code 2 $? "an unknown flag"
  (unset FM_HOME; PATH="$d/fakebin:$PATH" "$d/bin/fm-limit-resume.sh" stalled >/dev/null 2>&1); expect_code 2 $? "no FM_HOME"
  pass "a missing task id, a bad flag or an unset FM_HOME is a usage error"
}

fm_test_run \
  test_signature_matches_the_real_prompt \
  test_signature_matches_stop_label_status_line_and_styling \
  test_signature_ignores_ordinary_limit_prose \
  test_signature_requires_every_anchor_in_order \
  test_reset_phrase_reads_every_wording \
  test_reset_phrase_ignores_unanchored_times \
  test_reset_epoch_places_a_clock_time_without_going_early \
  test_reset_epoch_follows_when_the_stall_began \
  test_reset_epoch_places_a_dated_reset \
  test_reset_epoch_fails_closed \
  test_recovery_refuses_non_claude_harness \
  test_recovery_refuses_unresolvable_targets \
  test_recovery_refuses_without_a_live_match \
  test_recovery_refuses_when_no_reset_is_stated \
  test_recovery_refuses_an_unplaceable_reset \
  test_future_reset_records_a_timed_wait \
  test_a_reset_inside_the_margin_still_waits \
  test_a_reset_passed_since_the_stall_recovers_at_once \
  test_a_reset_many_hours_out_sends_nothing_and_declares_no_wait \
  test_a_clock_time_behind_the_stall_is_tomorrows \
  test_without_a_bound_the_next_occurrence_is_awaited \
  test_a_passed_reset_dismisses_and_resumes \
  test_recovery_stops_when_the_prompt_survives_the_interrupt \
  test_recovery_stops_when_the_pane_is_unreadable_after_the_interrupt \
  test_a_failed_interrupt_sends_no_steer \
  test_a_returned_prompt_with_the_same_reset_is_not_looped \
  test_recovery_uses_the_wait_it_recorded \
  test_recovery_closes_the_wait_it_opened \
  test_recovery_closes_only_a_wait_it_owns \
  test_malformed_settle_falls_back_to_the_default \
  test_failed_steer_is_reported_not_swallowed \
  test_check_only_never_sends_or_records \
  test_usage_errors_exit_two
