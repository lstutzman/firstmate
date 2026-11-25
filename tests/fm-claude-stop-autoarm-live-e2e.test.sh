#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the Stop-owned auto-arm
# (bin/fm-claude-stop-autoarm.sh + bin/fm-turnend-guard.sh --claude).
# Proves, against the real installed Claude Code and the real tracked hook
# registration: a fresh session with in-flight work, no watcher, and a stale
# session lock receives the full session-start digest through the tracked
# SessionStart hook; session start reclaims the dead owner; at least two
# tokenless auto-arm and rewake cycles then complete with zero model-issued arm
# commands; and the cooperative guard consumes no forced continuation while the
# hook's launch is healthy; and on every real Stop the auto-arm runs as a
# sibling of the turn-end guard under one parent (FLEET-199).
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication. No live fleet home, worktree, or session is touched.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_LIVE_E2E claude

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

LAB="$ROOT/.claude-autoarm-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
LIVE_OWNER_HOME="$LAB/live-owner-home"
TRANSCRIPT="$LAB/claude.jsonl"
CLAUDE_VERSION=$(claude --version)

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
# git clone of this worktree carries only committed state, so copy the
# working-tree surfaces under test (same pattern as the continuity live E2E).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
# The lab keeps the real tracked .claude/settings.json SessionStart run hook,
# Stop guard, and asyncRewake auto-arm registration.
# The local hooks record model-issued Bash calls and the Stop hook process
# tree without acquiring the session lock or otherwise changing lifecycle
# behavior.
cat > "$PROJECT/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/tool-logger.sh" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "[ -z \"${GROK_AGENT:-}${GROK_HOOK_EVENT:-}\" ] || exit 0; exec \"$CLAUDE_PROJECT_DIR\"/bin/stop-sibling-probe.sh", "timeout": 10 }
        ]
      }
    ]
  }
}
JSON

# FLEET-199 sibling probe: registered in the same exec form as the tracked
# turn-end guard, it records, per real Stop, its own parent and every live
# auto-arm and guard process with its parent, so the test can prove the guard's
# sibling assumption against the real harness instead of a fixture tree.
cat > "$PROJECT/bin/stop-sibling-probe.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
i=0
while :; do
  SNAP=$(ps -eo pid=,ppid=,args= 2>/dev/null | awk -v proj="$CLAUDE_PROJECT_DIR/bin/" 'index($0, proj) && /fm-claude-stop-autoarm\.sh|fm-turnend-guard\.sh/ && !/awk/')
  printf '%s\n' "$SNAP" | awk -v p="$PPID" '$2 == p && /fm-claude-stop-autoarm\.sh/ {a=1} $2 == p && /fm-turnend-guard\.sh/ {g=1} END {exit !(a && g)}' && break
  [ "$i" -ge 50 ] && break
  i=$((i + 1))
  sleep 0.1
done
{ printf 'probe ppid=%s\n' "$PPID"; printf '%s\n' "$SNAP"; printf 'end\n'; } >> "$FM_HOME/state/stop-siblings.log"
exit 0
SH
chmod +x "$PROJECT/bin/stop-sibling-probe.sh"

cat > "$PROJECT/bin/tool-logger.sh" <<'SH'
#!/usr/bin/env bash
P=$(cat 2>/dev/null || true)
printf '%s\n' "$P" | jq -r '.tool_input.command // "unknown"' >> "$FM_HOME/state/tool-calls.log" 2>/dev/null
exit 0
SH
chmod +x "$PROJECT/bin/tool-logger.sh"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"
# A numeric pid above the supported OS pid range is a demonstrably dead prior
# harness owner under fm_harness_pid_alive, matching the reproduced incident.
printf '9999999\n' > "$HOME_DIR/state/.lock"

# Rapid-death arm fixture: started plus an immediate actionable reason, the
# exact spent-Stop edge shape. Runs 1-2 close actionable; run 3 closes clean so
# a misbehaving session can never loop forever.
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
echo "arm-run=$N pid=$$" >> "$FM_HOME/state/arm-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
  exit 0
fi
printf 'pending:downtime:fixture-generation-%s\n' "$N" > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-rapid-%s\n' "$N"
exit 0
SH
# Drain fixture: session start invokes it once, then the model invokes it once
# per rewake. The third total drain ends the in-flight need after two complete
# Stop-owned cycles.
cat > "$PROJECT/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/drain-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/drain-count"
echo "drain-run=$N" >> "$FM_HOME/state/drain-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
fi
printf 'stale: fixture-rapid drained\n'
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-wake-drain.sh"

PROMPT='After reading the complete session-start digest, reply with exactly CYCLE0 and stop. Whenever a Stop hook feedback message wakes you, run exactly `bin/fm-wake-drain.sh` once with Bash, then reply with exactly ACK and stop. Never run bin/fm-watch-arm.sh or any other arm command, and never use any other tool.'

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
    claude -p "$PROMPT" --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' \
    --effort low --output-format stream-json --verbose
) > "$TRANSCRIPT" 2>&1 || fail "Claude credentialed auto-arm session failed: $(tail -20 "$TRANSCRIPT")"

# FLEET-199: bin/fm-turnend-guard.sh waits for an auto-arm that is a live
# sibling under its own parent whose ps args name fm-claude-stop-autoarm.sh.
# On every real Stop, the auto-arm must be a child of the probe's parent and
# any guard caught alive must be a child of that same parent; at least one Stop
# must catch the guard and the auto-arm together under that parent.
[ -s "$HOME_DIR/state/stop-siblings.log" ] || fail "the Stop sibling probe recorded no Stop event"
awk '
  /^probe ppid=/ { split($2, kv, "="); parent = kv[2]; arm = 0; guard = 0; bad = ""; next }
  /^end$/ {
    events++
    if (!arm) { print "no auto-arm sibling under parent " parent; failed = 1 }
    if (bad != "") { print "guard under another parent: " bad; failed = 1 }
    if (arm && guard) paired++
    next
  }
  {
    is_arm = 0; is_guard = 0
    for (i = 3; i <= NF; i++) {
      n = split($i, part, "/")
      if (part[n] == "fm-claude-stop-autoarm.sh") is_arm = 1
      if (part[n] == "fm-turnend-guard.sh") is_guard = 1
    }
    if (is_arm && $2 == parent) arm = 1
    if (is_guard && $2 == parent) guard = 1
    if (is_guard && $2 != parent) bad = $0
  }
  END {
    if (!events) { print "no complete probe record"; failed = 1 }
    if (!paired) { print "no Stop caught the guard and the auto-arm under one parent"; failed = 1 }
    exit failed
  }
' "$HOME_DIR/state/stop-siblings.log" >"$LAB/siblings.verdict" \
  || fail "Stop auto-arm is not a sibling of the turn-end guard: $(cat "$LAB/siblings.verdict"); log: $(cat "$HOME_DIR/state/stop-siblings.log")"
ARM_RUNS=$(wc -l < "$HOME_DIR/state/arm-ran" 2>/dev/null | tr -d ' ')
[ "$ARM_RUNS" = 2 ] || fail "expected exactly 2 hook-owned arm cycles, got $ARM_RUNS: $(cat "$HOME_DIR/state/arm-ran" 2>/dev/null)"
DRAIN_RUNS=$(wc -l < "$HOME_DIR/state/drain-ran" 2>/dev/null | tr -d ' ')
[ "$DRAIN_RUNS" = 3 ] || fail "expected one session-start drain plus two model wake drains, got $DRAIN_RUNS drains"
REWAKES=$(jq -r '
  select(.type == "user")
  | .message.content[]?
  | select(.type == "text")
  | .text
' "$TRANSCRIPT" 2>/dev/null | awk '/^Stop hook feedback:/{count++} END{print count+0}')
[ "$REWAKES" -ge 2 ] || fail "expected at least 2 exit-2 rewake deliveries, got $REWAKES"
grep -q 'stale: fixture-rapid-1' "$TRANSCRIPT" || fail "first rapid rewake reason missing from the transcript"
grep -q 'stale: fixture-rapid-2' "$TRANSCRIPT" || fail "second rapid rewake reason missing from the transcript"
[ -s "$HOME_DIR/state/tool-calls.log" ] \
  || fail "Claude emitted no logged Bash tool calls"
! grep -q 'fm-session-start.sh' "$HOME_DIR/state/tool-calls.log" \
  || fail "model issued a redundant session-start command: $(cat "$HOME_DIR/state/tool-calls.log")"
DIGEST_EVENTS=$(jq -c --arg heading "SESSION START - $HOME_DIR" '
  select(.type == "system" and .subtype == "hook_response" and .hook_event == "SessionStart")
  | select(.stdout | contains($heading))
' "$TRANSCRIPT" 2>/dev/null)
[ "$(printf '%s' "$DIGEST_EVENTS" | jq -s 'length')" = 1 ] \
  || fail "expected exactly one SessionStart hook_response carrying the session-start digest"
DIGEST=$(printf '%s' "$DIGEST_EVENTS" | jq -r '.stdout')
printf '%s' "$DIGEST" | grep -q '^lock acquired: harness pid [0-9][0-9]*$' \
  || fail "SessionStart hook digest lacks the stale-lock reclaim"
! printf '%s' "$DIGEST" | grep -q '^●  STARTUP TRUNCATED - ' \
  || fail "SessionStart hook digest was truncated"
printf '%s' "$DIGEST" | grep -q '^The digest above is complete for this session start\.' \
  || fail "SessionStart hook digest lacks its completion marker"
[ "$(cat "$HOME_DIR/state/.lock" 2>/dev/null)" != 9999999 ] \
  || fail "session start did not reclaim the stale dead-owner lock"
if [ -f "$HOME_DIR/state/tool-calls.log" ]; then
  ! grep -q 'fm-watch-arm.sh' "$HOME_DIR/state/tool-calls.log" \
    || fail "model issued an arm command despite Stop-owned continuity: $(cat "$HOME_DIR/state/tool-calls.log")"
  ! grep -q '&' "$HOME_DIR/state/tool-calls.log" \
    || fail "model used a shell ampersand: $(cat "$HOME_DIR/state/tool-calls.log")"
fi
! grep -q 'TURN WOULD END BLIND' "$TRANSCRIPT" \
  || fail "cooperative guard consumed a forced continuation while the auto-arm launch was healthy"
[ "$(sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null)" = rewake ] \
  || fail "auto-arm epoch ledger must record the rewake outcome"
# The claim is bound to the Claude session its Stop payload names, the session
# that receives the hook's rewake (docs/turnend-guard.md "Auto-arm generation
# claim"), so the real payload must carry this session's own id.
SESSION_ID=$(jq -r 'select(.type == "system" and .subtype == "init") | .session_id' "$TRANSCRIPT" 2>/dev/null | head -n 1)
[ -n "$SESSION_ID" ] || fail "the stream-json transcript names no session id"
grep -q "^epoch=.* claude_session=$SESSION_ID\$" "$HOME_DIR/state/.claude-autoarm-epoch" \
  || fail "auto-arm epoch ledger must record the Stop payload's session $SESSION_ID: $(sed -n '1p' "$HOME_DIR/state/.claude-autoarm-epoch")"
[ ! -e "$HOME_DIR/state/.claude-autoarm.lock" ] || fail "auto-arm owner lock was left behind"

# Live-owner negative control: a separate supported-harness process owns a
# second isolated home while another Stop hook fires from the same primary
# project. The competing hook must not replace the session lock, arm, write an
# epoch, or rewake.
FAKE_CLAUDE="$LAB/claude"
ln -s /bin/bash "$FAKE_CLAUDE"
mkdir -p "$LIVE_OWNER_HOME/state" "$LIVE_OWNER_HOME/config"
printf 'project=fixture\n' > "$LIVE_OWNER_HOME/state/task.meta"
"$FAKE_CLAUDE" -c 'sleep 3; :' &
LIVE_OWNER_PID=$!
printf '%s\n' "$LIVE_OWNER_PID" > "$LIVE_OWNER_HOME/state/.lock"
LIVE_OWNER_RC=0
printf '%s\n' '{"session_id":"live-owner-control"}' \
  | FM_HOME="$LIVE_OWNER_HOME" FM_ROOT_OVERRIDE="$PROJECT" "$FAKE_CLAUDE" -c '"$FM_ROOT_OVERRIDE/bin/fm-claude-stop-autoarm.sh"' \
      >"$LAB/live-owner.out" 2>"$LAB/live-owner.err" || LIVE_OWNER_RC=$?
[ "$LIVE_OWNER_RC" -eq 0 ] || fail "competing Stop hook returned $LIVE_OWNER_RC while another live session owned the home"
[ "$(cat "$LIVE_OWNER_HOME/state/.lock")" = "$LIVE_OWNER_PID" ] || fail "competing Stop hook replaced the live session owner"
[ ! -e "$LIVE_OWNER_HOME/state/arm-ran" ] || fail "competing Stop hook armed while another live session owned the home"
[ ! -e "$LIVE_OWNER_HOME/state/.claude-autoarm-epoch" ] || fail "competing Stop hook wrote an epoch while another live session owned the home"
[ ! -s "$LAB/live-owner.out" ] && [ ! -s "$LAB/live-owner.err" ] || fail "competing Stop hook produced a rewake while another live session owned the home"
wait "$LIVE_OWNER_PID"

printf 'ok - Claude %s live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary\n' "$CLAUDE_VERSION"
