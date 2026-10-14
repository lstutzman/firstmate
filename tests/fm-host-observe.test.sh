#!/usr/bin/env bash
# Behavior tests for the supervision host's observer (bin/fm-host-observe.sh,
# docs/supervision-host.md "The observer pane"): the read-only renderer over a
# fixture home's host files, and the opt-in herdr pane ensure against a fake
# herdr CLI. No test here reaches a real herdr server: every case runs with the
# inherited Herdr identity removed and a fake `herdr` first on PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OBSERVE="$ROOT/bin/fm-host-observe.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-host-observe)
trap fm_test_cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND FM_BACKEND_HERDR_BIN
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
export TZ=UTC

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/claude/projects/-code-root"
  printf '%s\n' "$home"
}

observe_once() {  # <home>
  FM_HOME="$1" CLAUDE_CONFIG_DIR="$1/claude" "$OBSERVE" follow --once 2>&1
}

test_ledger_lines_render_with_time_kind_and_fields() {
  local home out
  home=$(make_home ledger)
  printf '%s\t%s\t%s\t%s\n' 1700000000 pass-through attended 'main-only	check: demo' > "$home/state/.supervision-host.log"
  out=$(observe_once "$home")
  assert_contains "$out" "22:13:20 [host] pass-through: attended | main-only | check: demo" \
    "a ledger line must render its time, kind, and fields"
  pass "observe: a host ledger line renders readably"
}

test_outcomes_render_their_verdict_task_and_summary() {
  local home out
  home=$(make_home outcomes)
  {
    printf '%s\n' '{"seq":1,"epoch":1700000000,"task":"demo","wake":"signal: demo","verdict":"routine","summary":"stack built","silent":false}'
    printf '%s\n' '{"seq":2,"epoch":1700000060,"task":"demo","wake":"signal: demo","verdict":"captain","summary":"PR 12 needs your merge","silent":false}'
    printf '%s\n' '{"seq":3,"epoch":1700000120,"task":"demo","wake":"heartbeat","verdict":"routine","summary":"nothing new","silent":true}'
  } > "$home/state/.branch-outcomes-tail.jsonl"
  out=$(observe_once "$home")
  assert_contains "$out" "22:13:20 [outcome] routine demo: stack built" "a routine outcome must render its verdict"
  assert_contains "$out" "22:14:20 [outcome] CAPTAIN demo: PR 12 needs your merge" "a captain outcome must stand out"
  assert_contains "$out" "22:15:20 [outcome] routine (silent) demo: nothing new" "a silent outcome must say so"
  pass "observe: outcomes render their verdict, task, and summary"
}

SESSION_A=11111111-2222-3333-4444-555555555555
SESSION_B=66666666-7777-8888-9999-000000000000

# transcript_turn <file> <second> <label>: append one engine turn in the shape
# Claude's print mode persists (docs/supervision-host.md "Engines"): the wake
# prompt, an assistant text and Bash call, the tool result, and bookkeeping
# rows the observer skips.
transcript_turn() {
  local file=$1 s=$2 label=$3
  {
    printf '{"type":"queue-operation","timestamp":"2023-11-14T22:13:%02d.000Z"}\n' "$s"
    printf '{"type":"user","timestamp":"2023-11-14T22:13:%02d.000Z","message":{"role":"user","content":"FIRSTMATE SUPERVISION WAKE: signal: demo"}}\n' "$s"
    printf '{"type":"assistant","timestamp":"2023-11-14T22:13:%02d.100Z","message":{"role":"assistant","content":[{"type":"text","text":"%s: the demo\\ntask moved on."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"bin/fm-wake-drain.sh\\n| head"}}]}}\n' "$s" "$label"
    printf '{"type":"user","timestamp":"2023-11-14T22:13:%02d.200Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":[{"type":"text","text":"recorded seq 7 [routine]\\nsecond line"}]}]}}\n' "$s"
    printf '{"type":"assistant","timestamp":"2023-11-14T22:13:%02d.300Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/fm/state/demo.status"}}]}}\n' "$s"
    printf '{"type":"user","timestamp":"2023-11-14T22:13:%02d.400Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"permission denied"}]}}\n' "$s"
    printf '{"type":"last-prompt"}\n'
  } >> "$file"
}

engine_record() {  # <home> <session>
  printf 'engine=claude\nmodel=sonnet\nsession=%s\nkey=k\nturns=1\nconversation_cost=0.1\n' "$2" > "$1/state/.supervision-host-engine"
}

test_engine_turn_activity_renders_condensed() {
  local home out
  home=$(make_home transcript)
  engine_record "$home" "$SESSION_A"
  transcript_turn "$home/claude/projects/-code-root/$SESSION_A.jsonl" 21 first
  out=$(observe_once "$home")
  assert_contains "$out" "22:13:21 [engine] first: the demo task moved on." "assistant text must render on one line"
  assert_contains "$out" "22:13:21 [engine] > Bash: bin/fm-wake-drain.sh | head" "a Bash call must render its command"
  assert_contains "$out" "22:13:21 [engine] < recorded seq 7 [routine]" "a tool result must render its first line"
  assert_contains "$out" "22:13:21 [engine] > Read: /fm/state/demo.status" "a Read call must render its path"
  assert_contains "$out" "22:13:21 [engine] < error: permission denied" "a failed tool result must say so"
  assert_not_contains "$out" "FIRSTMATE SUPERVISION WAKE" "the wake prompt is the [wake] line's, not the engine's"
  assert_not_contains "$out" "second line" "a tool result renders only its first line"
  pass "observe: the engine's turn activity renders as condensed text and tool calls"
}

# A live follower over <home>, its output in <home>/follow.out.
start_follow() {  # <home>
  FM_HOME="$1" CLAUDE_CONFIG_DIR="$1/claude" FM_HOST_OBSERVE_POLL=0.1 \
    "$OBSERVE" follow > "$1/follow.out" 2>&1 &
  FOLLOW_PID=$!
}
stop_follow() {
  kill -TERM "$FOLLOW_PID" 2>/dev/null || true
  wait "$FOLLOW_PID" 2>/dev/null || true
}
# wait_rendered <home> <text> [count]: wait until <text> was rendered <count>
# times (default 1).
wait_rendered() {
  local i=0 n
  while [ "$i" -lt 100 ]; do
    n=$(grep -cF -- "$2" "$1/follow.out" 2>/dev/null)
    [ "${n:-0}" -ge "${3:-1}" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  stop_follow
  fail "the follower never rendered '$2' ${3:-1} time(s)"$'\n'"--- follow.out ---"$'\n'"$(cat "$1/follow.out")"
}
rendered_count() {  # <home> <text>
  local n
  n=$(grep -cF -- "$2" "$1/follow.out" 2>/dev/null)
  printf '%s\n' "${n:-0}"
}
ledger() {  # <home> <epoch> <kind> <text>
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> "$1/state/.supervision-host.log"
}

test_follow_renders_each_new_event_once_across_absence_rotation_and_restart() {
  local home transcript
  home=$(make_home follow)
  start_follow "$home"
  sleep 0.3
  ledger "$home" 1700000000 start 'gen=host-1'
  wait_rendered "$home" "[host] start: gen=host-1"
  ledger "$home" 1700000001 handled 'turn=host-1.1'
  wait_rendered "$home" "[host] handled: turn=host-1.1"
  # The host rotates its ledger by rewriting it with its newest lines.
  { tail -n 1 "$home/state/.supervision-host.log"; printf '%s\t%s\t%s\n' 1700000002 latch 'errors=2'; } > "$home/state/.log.tmp"
  mv -f "$home/state/.log.tmp" "$home/state/.supervision-host.log"
  wait_rendered "$home" "[host] latch: errors=2"
  # A truncated ledger, as after a home reset, starts over.
  : > "$home/state/.supervision-host.log"
  ledger "$home" 1700000003 start 'gen=host-2'
  wait_rendered "$home" "[host] start: gen=host-2"
  # A conversation that appears after the follower started is followed live.
  transcript="$home/claude/projects/-code-root/$SESSION_A.jsonl"
  engine_record "$home" "$SESSION_A"
  transcript_turn "$transcript" 21 first
  wait_rendered "$home" "[engine] first: the demo task moved on."
  transcript_turn "$transcript" 22 second
  wait_rendered "$home" "[engine] second: the demo task moved on."
  # A new conversation replaces it.
  engine_record "$home" "$SESSION_B"
  transcript_turn "$home/claude/projects/-code-root/$SESSION_B.jsonl" 23 third
  wait_rendered "$home" "[engine] third: the demo task moved on."
  printf '%s\n' '{"seq":1,"epoch":1700000000,"task":"demo","verdict":"routine","summary":"one","silent":false}' > "$home/state/.branch-outcomes-tail.jsonl"
  wait_rendered "$home" "[outcome] routine demo: one"
  # The tail copy is replaced whole after each append.
  printf '%s\n%s\n' '{"seq":1,"epoch":1700000000,"task":"demo","verdict":"routine","summary":"one","silent":false}' \
    '{"seq":2,"epoch":1700000001,"task":"demo","verdict":"captain","summary":"two","silent":false}' > "$home/state/.tail.tmp"
  mv -f "$home/state/.tail.tmp" "$home/state/.branch-outcomes-tail.jsonl"
  wait_rendered "$home" "[outcome] CAPTAIN demo: two"
  sleep 0.5
  stop_follow
  assert_equals 1 "$(rendered_count "$home" "[host] handled: turn=host-1.1")" "a rotated ledger line must not render again"
  assert_equals 1 "$(rendered_count "$home" "[engine] first: the demo task moved on.")" "a followed turn must render once"
  assert_equals 1 "$(rendered_count "$home" "[outcome] routine demo: one")" "an outcome must render once"
  pass "observe: the follower renders each new event once across absent files, rotation, truncation, and a new conversation"
}

test_a_running_turn_renders_its_wake_and_follows_its_new_conversation() {
  local home out
  home=$(make_home wake)
  # A new conversation's session is recorded only once its turn succeeds, so a
  # running turn names it in the turn record.
  engine_record "$home" "$SESSION_A"
  transcript_turn "$home/claude/projects/-code-root/$SESSION_A.jsonl" 21 older
  printf 'turn=host-9.4\nrows=12 13\ntasks=demo\nunscoped=0\nwake=signal: demo\nposture=away\nsession=%s\n' "$SESSION_B" \
    > "$home/state/.supervision-host-turn"
  fm_touch_epoch 1700000100 "$home/state/.supervision-host-turn"
  transcript_turn "$home/claude/projects/-code-root/$SESSION_B.jsonl" 22 running
  out=$(observe_once "$home")
  assert_contains "$out" "22:15:00 [wake] away turn=host-9.4 tasks=demo: signal: demo" \
    "a running turn must render its posture, turn, tasks, and wake"
  assert_contains "$out" "22:13:22 [engine] running: the demo task moved on." "the running turn's conversation must be followed"
  assert_not_contains "$out" "older:" "the recorded earlier conversation is not the running turn's"
  pass "observe: a running turn renders its wake and its own conversation"
}

test_a_finished_new_conversation_turn_does_not_render_the_earlier_one_again() {
  local home
  home=$(make_home flip)
  engine_record "$home" "$SESSION_A"
  transcript_turn "$home/claude/projects/-code-root/$SESSION_A.jsonl" 21 earlier
  start_follow "$home"
  wait_rendered "$home" "[engine] earlier: the demo task moved on."
  # A turn starts a new conversation; its record names it.
  printf 'turn=host-9.5\nrows=14\ntasks=demo\nunscoped=0\nwake=signal: demo\nposture=away\nsession=%s\n' "$SESSION_B" \
    > "$home/state/.supervision-host-turn"
  transcript_turn "$home/claude/projects/-code-root/$SESSION_B.jsonl" 22 newer
  wait_rendered "$home" "[engine] newer: the demo task moved on."
  # The host removes the turn record before it writes the engine record, which
  # still names the earlier conversation until then (or for good, after a
  # failed turn).
  rm -f "$home/state/.supervision-host-turn"
  sleep 0.5
  engine_record "$home" "$SESSION_B"
  transcript_turn "$home/claude/projects/-code-root/$SESSION_B.jsonl" 23 latest
  wait_rendered "$home" "[engine] latest: the demo task moved on."
  sleep 0.3
  stop_follow
  assert_equals 1 "$(rendered_count "$home" "[engine] earlier: the demo task moved on.")" \
    "the earlier conversation must not render again when the follower falls back to it"
  assert_equals 1 "$(rendered_count "$home" "[engine] newer: the demo task moved on.")" \
    "the new conversation must not render again once the engine record names it"
  pass "observe: moving between conversations renders each conversation's lines once"
}

# --- the observer pane -------------------------------------------------------

# A stateful fake herdr: it logs every call to $FAKE_HERDR_DIR/calls, answers
# status as a running protocol-20 server, mints workspace and pane ids on
# workspace create, and reports a pane present while its id is listed in
# $FAKE_HERDR_DIR/panes (a case closes a pane by removing it).
# A $FAKE_HERDR_DIR/run-fails file makes the next pane run fail.
# FAKE_HERDR_DOWN=1 makes every call fail as an unreachable server would.
FAKEBIN=$(fm_fakebin "$TMP_ROOT/herdr")
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
dir=${FAKE_HERDR_DIR:?}
printf '%s\n' "$*" >> "$dir/calls"
[ "${FAKE_HERDR_DOWN:-0}" != 1 ] || { printf 'error: could not connect to the herdr server\n' >&2; exit 1; }
case "$1 ${2:-}" in
  'status --json')
    printf '{"client":{"version":"0.9.0","protocol":20},"server":{"running":true,"protocol":20,"compatible":true}}\n' ;;
  'workspace create')
    [ -z "${FAKE_HERDR_SLOW:-}" ] || sleep "$FAKE_HERDR_SLOW"
    n=$(( $(wc -l < "$dir/panes" 2>/dev/null || echo 0) + $(cat "$dir/closed" 2>/dev/null || echo 0) + 1 ))
    printf 'p%s\n' "$n" >> "$dir/panes"
    printf '{"result":{"workspace":{"workspace_id":"w%s"},"tab":{"tab_id":"t%s"},"root_pane":{"pane_id":"p%s"}}}\n' "$n" "$n" "$n" ;;
  'pane get')
    if grep -qx -- "$3" "$dir/panes" 2>/dev/null; then
      printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3"
    else
      printf '{"error":{"code":"pane_not_found"}}\n'
      exit 1
    fi ;;
  'pane run')
    if [ -e "$dir/run-fails" ]; then rm -f "$dir/run-fails"; exit 1; fi ;;
  'pane close')
    grep -vx -- "$3" "$dir/panes" > "$dir/panes.tmp" 2>/dev/null; mv -f "$dir/panes.tmp" "$dir/panes"
    echo $(( $(cat "$dir/closed" 2>/dev/null || echo 0) + 1 )) > "$dir/closed" ;;
  *) printf '{"error":{"code":"unexpected"}}\n'; exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/herdr"
# No real herdr is reachable from these cases, whatever the developer runs in.
SAFE_PATH="$FAKEBIN:$(fm_test_base_path_sans "$PATH" herdr)"

ensure() {  # <home> [extra env assignments...]
  local home=$1
  shift
  env FM_HOME="$home" FAKE_HERDR_DIR="$home/herdr" HERDR_SESSION=fm-observe-fake PATH="$SAFE_PATH" \
    FM_BACKEND=herdr "$@" "$OBSERVE" ensure 2>&1
}

make_observer_home() {  # <name>
  local home
  home=$(make_home "$1")
  mkdir -p "$home/herdr"
  : > "$home/config/supervision-host-observer"
  printf '%s\n' "$home"
}

test_ensure_opens_one_observer_pane_and_reuses_it() {
  local home out
  home=$(make_observer_home ensure-once)
  out=$(ensure "$home")
  assert_contains "$out" "observer pane p1" "the first ensure must report the pane it opened"
  assert_grep "workspace create --cwd $home --label firstmate-host-observer --no-focus --session fm-observe-fake" "$home/herdr/calls" \
    "the observer must open its own clearly labeled workspace in the selected session"
  assert_grep "pane run p1 " "$home/herdr/calls" "the observer must start in the new pane"
  assert_grep "bin/fm-host-observe.sh follow" "$home/herdr/calls" "the pane must run the follower"
  out=$(ensure "$home")
  assert_equals "" "$out" "a second ensure with the pane present must say nothing"
  assert_equals 1 "$(grep -c '^workspace create' "$home/herdr/calls")" "a second ensure must not open another pane"
  pass "observe: ensure opens exactly one observer pane and reuses it while it exists"
}

test_ensure_reopens_a_closed_observer_pane() {
  local home out
  home=$(make_observer_home ensure-reopen)
  ensure "$home" >/dev/null
  # The captain closes the pane.
  : > "$home/herdr/panes"
  echo 1 > "$home/herdr/closed"
  out=$(ensure "$home")
  assert_contains "$out" "observer pane p2" "a closed observer pane must be opened again"
  assert_equals 2 "$(grep -c '^workspace create' "$home/herdr/calls")" "exactly one new pane must replace the closed one"
  assert_grep "pane run p2 " "$home/herdr/calls" "the observer must start in the replacement pane"
  pass "observe: ensure reopens an observer pane the captain closed"
}

test_ensure_replaces_a_pane_the_observer_could_not_start_in() {
  local home out
  home=$(make_observer_home ensure-run-fails)
  : > "$home/herdr/run-fails"
  out=$(ensure "$home")
  assert_contains "$out" "could not start the observer in it; the host continues headless" \
    "a pane the observer could not start in must get one diagnostic"
  assert_grep "pane close p1" "$home/herdr/calls" "the idle pane must be closed"
  out=$(ensure "$home")
  assert_contains "$out" "observer pane p2" "the next ensure must open a new pane"
  assert_equals 1 "$(grep -c '^pane run p2 .*bin/fm-host-observe.sh follow' "$home/herdr/calls")" "the new pane must run the follower"
  pass "observe: ensure replaces a pane the observer could not start in"
}

test_ensure_on_another_backend_says_so_once_and_touches_no_herdr() {
  local home out
  home=$(make_observer_home ensure-tmux)
  out=$(ensure "$home" FM_BACKEND=tmux)
  assert_contains "$out" "observer: the observer pane needs the herdr backend, and this home runs tmux; the host continues headless" \
    "another backend must get one clear diagnostic"
  out=$(ensure "$home" FM_BACKEND=tmux)
  assert_equals "" "$out" "the same diagnostic must not repeat at every park"
  assert_absent "$home/herdr/calls" "another backend must never reach herdr"
  pass "observe: ensure on another backend prints one diagnostic and does nothing"
}

test_ensure_degrades_once_when_herdr_is_unreachable() {
  local home out rc
  home=$(make_observer_home ensure-down)
  out=$(ensure "$home" FAKE_HERDR_DOWN=1)
  rc=$?
  expect_code 0 "$rc" "an unreachable herdr must not fail the caller"
  assert_contains "$out" "the host continues headless" "an unreachable herdr must get one diagnostic"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "an unreachable herdr must get exactly one line"
  out=$(ensure "$home" FAKE_HERDR_DOWN=1)
  assert_equals "" "$out" "the same diagnostic must not repeat at every park"
  out=$(ensure "$home")
  assert_contains "$out" "observer pane p1" "a herdr that comes back must get its pane"
  pass "observe: ensure degrades with one diagnostic while herdr is unreachable"
}

test_ensure_reports_a_problem_again_after_an_open() {
  local home out
  home=$(make_observer_home ensure-down-open-down)
  out=$(ensure "$home" FAKE_HERDR_DOWN=1)
  assert_contains "$out" "the host continues headless" "an unreachable herdr must get one diagnostic"
  out=$(ensure "$home")
  assert_contains "$out" "observer pane p1" "a herdr that comes back must get its pane"
  out=$(ensure "$home" FAKE_HERDR_DOWN=1)
  assert_contains "$out" "the host continues headless" "a problem that returns after an open must be reported again"
  pass "observe: ensure reports a problem again once a pane opened in between"
}

test_overlapping_ensures_open_one_pane() {
  local home
  home=$(make_observer_home ensure-overlap)
  # Two parks in quick succession while herdr answers slowly.
  ensure "$home" FAKE_HERDR_SLOW=1 > "$home/first.out" &
  ensure "$home" FAKE_HERDR_SLOW=1 > "$home/second.out" &
  wait
  assert_equals 1 "$(grep -c '^workspace create' "$home/herdr/calls")" "overlapping ensures must open exactly one pane"
  pass "observe: overlapping ensures open exactly one observer pane"
}

test_ensure_without_the_opt_in_does_nothing() {
  local home out
  home=$(make_home ensure-off)
  mkdir -p "$home/herdr"
  out=$(ensure "$home")
  assert_equals "" "$out" "a home without the opt-in must say nothing"
  assert_absent "$home/herdr/calls" "a home without the opt-in must never reach herdr"
  pass "observe: ensure without config/supervision-host-observer does nothing"
}

test_ledger_lines_render_with_time_kind_and_fields
test_a_running_turn_renders_its_wake_and_follows_its_new_conversation
test_follow_renders_each_new_event_once_across_absence_rotation_and_restart
test_a_finished_new_conversation_turn_does_not_render_the_earlier_one_again
test_engine_turn_activity_renders_condensed
test_outcomes_render_their_verdict_task_and_summary
test_ensure_opens_one_observer_pane_and_reuses_it
test_ensure_reopens_a_closed_observer_pane
test_ensure_replaces_a_pane_the_observer_could_not_start_in
test_ensure_on_another_backend_says_so_once_and_touches_no_herdr
test_ensure_degrades_once_when_herdr_is_unreachable
test_ensure_reports_a_problem_again_after_an_open
test_overlapping_ensures_open_one_pane
test_ensure_without_the_opt_in_does_nothing
