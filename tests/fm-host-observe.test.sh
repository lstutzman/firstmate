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

test_ledger_lines_render_with_time_kind_and_fields
test_a_running_turn_renders_its_wake_and_follows_its_new_conversation
test_follow_renders_each_new_event_once_across_absence_rotation_and_restart
test_engine_turn_activity_renders_condensed
test_outcomes_render_their_verdict_task_and_summary
