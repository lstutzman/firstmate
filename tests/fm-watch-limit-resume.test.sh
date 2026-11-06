#!/usr/bin/env bash
# tests/fm-watch-limit-resume.test.sh - the watcher's side of recovering a
# crewmate stalled on Claude Code's usage-limit prompt (bin/fm-limit-resume.sh
# owns the recovery itself and tests/fm-limit-resume.test.sh pins it).
#
# These drive a real fm-watch.sh subprocess against a pane parked on the prompt
# and assert the contract of limit_resume_check in bin/fm-watch.sh:
#   - a claude crew on the prompt makes the watcher ask the recovery script,
#     once per throttle window, with the earlier of the crew's last status-line
#     time and the pane-change time as the evidence of when the stall began,
#     and the stale wake names the prompt;
#   - nothing else does: not a crew of another harness, not the same words
#     quoted above a composer, not a second mate, not a crew checked a moment
#     ago.
# Shared fixtures live in tests/watch-triage-helpers.sh.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-limit-resume)

write_limit_prompt() {  # <file>
  printf '%s\n' \
    "You've hit your limit · resets 6:40pm" \
    '' \
    '   What do you want to do?' \
    '' \
    ' ❯ 1. Wait here, then continue automatically at 6:40pm' \
    '   2. Stop and wait for limit to reset' \
    '' \
    '   Enter to confirm · Esc to cancel' > "$1"
}

# The same words quoted in tool output above a normal composer: not the prompt.
write_quoted_limit_prompt() {  # <file>
  printf '%s\n' \
    '● Read(notes.md)' \
    '  ⎿     What do you want to do?' \
    '      ❯ 1. Stop and wait for limit to reset' \
    '        Enter to confirm · Esc to cancel' \
    '' \
    '╭──────────────╮' \
    '│ >            │' \
    '╰──────────────╯' \
    '  ? for shortcuts' > "$1"
}

# A recorder standing in for bin/fm-limit-resume.sh, so the case measures only
# whether and how the watcher asks.
write_fake_resume() {  # <file> <log>
  cat > "$1" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$2'
exit 0
SH
  chmod +x "$1"
}

prime_limit_window() {  # <state> <id> <window> <kind> <harness> <capture>
  local state=$1 id=$2 window=$3 kind=$4 harness=$5 capture=$6 key statusf
  statusf="$state/$id.status"
  printf 'window=%s\nkind=%s\nharness=%s\nbackend=tmux\n' "$window" "$kind" "$harness" > "$state/$id.meta"
  printf '%s\n' 'working: parked between turns' > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-${id}_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "$(cat "$capture")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$key"
}

# run_watch <dir> <window> <capture> <resume-log> [env...]: one watcher run to
# its first wake. Prints nothing; the wake text lands in <dir>/watch.out.
run_watch() {
  local dir=$1 window=$2 capture=$3 log=$4 pid
  shift 4
  write_fake_resume "$dir/fake-resume.sh" "$log"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  env "$@" PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_LIMIT_RESUME_BIN="$dir/fake-resume.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "the watcher did not surface the pane: $(cat "$dir/watch.out")"
  unset FM_FAKE_CREW_STATE
}

# The recovery runs detached, so give it a moment to record.
wait_for_file() {  # <file> [ticks]
  local f=$1 i=0 limit=${2:-50}
  while [ "$i" -lt "$limit" ]; do
    [ -s "$f" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_claude_crew_on_the_prompt_is_handed_to_the_recovery() {
  local dir state capture window key log since
  dir=$(make_case limit-claude); state="$dir/state"
  capture="$dir/pane.txt"; log="$dir/resume.log"; window="test:fm-stalled"
  write_limit_prompt "$capture"
  key=$(prime_limit_window "$state" stalled "$window" ship claude "$capture")
  run_watch "$dir" "$window" "$capture" "$log"
  grep -F "stale: $window" "$dir/watch.out" >/dev/null || fail "the wake was not a stale wake: $(cat "$dir/watch.out")"
  grep -F 'blocked-on-prompt: Claude usage-limit prompt' "$dir/watch.out" >/dev/null \
    || fail "the stale wake did not name the usage-limit prompt: $(cat "$dir/watch.out")"
  wait_for_file "$log" || fail "the watcher never asked the recovery script"
  [ "$(grep -c . "$log")" -eq 1 ] || fail "the watcher asked the recovery script more than once: $(cat "$log")"
  case "$(cat "$log")" in
    "--since "[0-9]*" stalled") ;;
    *) fail "the recovery was not asked for the right task with a bound: $(cat "$log")" ;;
  esac
  since=$(sed -n 's/^--since \([0-9]*\) stalled$/\1/p' "$log")
  [ "$since" -le "$(date +%s)" ] || fail "the evidence of when the stall began is in the future: $since"
  [ "$since" -ge "$(( $(date +%s) - 600 ))" ] || fail "the bound is not the time the watcher recorded: $since"
  assert_present "$state/.limit-resume-checked-$key" "no throttle record was left"
  pass "a claude crew parked on the usage-limit prompt is named and handed to the recovery once, with a bound"
}

# The fork's overnight case: the crew last wrote its status at the stall, the
# watcher was down, and the pane-change time it records on restart is hours
# later. The earlier status-line time is the evidence the recovery must get.
test_the_crews_last_status_time_bounds_a_stall_seen_after_a_restart() {
  local dir state capture window log stalled_at since
  dir=$(make_case limit-restart); state="$dir/state"
  capture="$dir/pane.txt"; log="$dir/resume.log"; window="test:fm-restarted"
  write_limit_prompt "$capture"
  prime_limit_window "$state" restarted "$window" ship claude "$capture" >/dev/null
  stalled_at=$(( $(date +%s) - 8 * 3600 ))
  touch -d "@$stalled_at" "$state/restarted.status" 2>/dev/null \
    || touch -t "$(date -r "$stalled_at" +%Y%m%d%H%M.%S)" "$state/restarted.status"
  run_watch "$dir" "$window" "$capture" "$log"
  wait_for_file "$log" || fail "the watcher never asked the recovery script"
  since=$(sed -n 's/^--since \([0-9]*\) restarted$/\1/p' "$log")
  assert_equals "$stalled_at" "$since" "the bound was not the crew's last status-line time: $(cat "$log")"
  pass "a stall first seen after a watcher restart is bounded by the crew's last status-line time"
}

test_a_recent_check_throttles_the_recovery() {
  local dir state capture window key log
  dir=$(make_case limit-throttled); state="$dir/state"
  capture="$dir/pane.txt"; log="$dir/resume.log"; window="test:fm-throttled"
  write_limit_prompt "$capture"
  key=$(prime_limit_window "$state" throttled "$window" ship claude "$capture")
  touch "$state/.limit-resume-checked-$key"
  run_watch "$dir" "$window" "$capture" "$log"
  sleep 1
  [ ! -s "$log" ] || fail "the recovery was asked again inside the throttle window: $(cat "$log")"
  grep -F 'blocked-on-prompt: Claude usage-limit prompt' "$dir/watch.out" >/dev/null \
    || fail "a throttled check stopped naming the prompt: $(cat "$dir/watch.out")"
  pass "a crew checked inside the throttle window is not asked again, and is still named"
}

test_another_harness_is_never_handed_to_the_recovery() {
  local dir state capture window log
  dir=$(make_case limit-codex); state="$dir/state"
  capture="$dir/pane.txt"; log="$dir/resume.log"; window="test:fm-codex"
  write_limit_prompt "$capture"
  prime_limit_window "$state" codexer "$window" ship codex "$capture" >/dev/null
  run_watch "$dir" "$window" "$capture" "$log"
  sleep 1
  [ ! -s "$log" ] || fail "a crew of another harness was handed to the claude recovery: $(cat "$log")"
  pass "the recovery is claude-specific: another harness's pane is never handed to it"
}

test_quoted_prompt_text_is_never_handed_to_the_recovery() {
  local dir state capture window log
  dir=$(make_case limit-quoted); state="$dir/state"
  capture="$dir/pane.txt"; log="$dir/resume.log"; window="test:fm-quoted"
  write_quoted_limit_prompt "$capture"
  prime_limit_window "$state" quoted "$window" ship claude "$capture" >/dev/null
  run_watch "$dir" "$window" "$capture" "$log"
  sleep 1
  [ ! -s "$log" ] || fail "prompt text quoted above a composer was handed to the recovery: $(cat "$log")"
  grep -F 'blocked-on-prompt' "$dir/watch.out" >/dev/null && fail "quoted prompt text was named as a dialog: $(cat "$dir/watch.out")"
  pass "prompt text quoted above a composer stays an ordinary stale and is never handed to the recovery"
}

test_a_second_mate_is_never_handed_to_the_recovery() {
  local dir state capture window log pid
  dir=$(make_case limit-mate); state="$dir/state"
  capture="$dir/pane.txt"; log="$dir/resume.log"; window="test:fm-mate"
  write_limit_prompt "$capture"
  prime_limit_window "$state" mate "$window" secondmate claude "$capture" >/dev/null
  write_fake_resume "$dir/fake-resume.sh" "$log"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_LIMIT_RESUME_BIN="$dir/fake-resume.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a second mate on the prompt woke: $(cat "$dir/watch.out")"
  fi
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  sleep 1
  [ ! -s "$log" ] || fail "a second mate was handed to the recovery: $(cat "$log")"
  pass "a second mate is outside the recovery: an idle mate endpoint is healthy by design"
}

fm_test_run \
  test_claude_crew_on_the_prompt_is_handed_to_the_recovery \
  test_the_crews_last_status_time_bounds_a_stall_seen_after_a_restart \
  test_a_recent_check_throttles_the_recovery \
  test_another_harness_is_never_handed_to_the_recovery \
  test_quoted_prompt_text_is_never_handed_to_the_recovery \
  test_a_second_mate_is_never_handed_to_the_recovery
