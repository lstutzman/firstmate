#!/usr/bin/env bash
# Behavior tests for bin/fm-watch-backstop.sh, the out-of-session watcher
# backstop: endpoint recording and its ownership gate, the once-per-stale-
# episode ring through a real tmux pane, every deferral that must not ring, and
# the generated scheduler files.
#
# The ring cases reproduce the overnight outage shape: a home with work in
# flight whose Claude session was killed mid-cycle (its interrupted Stop hook
# left a consumed failure notice bound to the dead session) and relaunched as
# an idle resumed session that never ends a turn, so no in-session owner re-arms
# and the beacon ages for hours. The pane is a deterministic composer on a
# private tmux socket reached through a PATH shim; nothing touches a live
# server.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKSTOP="$ROOT/bin/fm-watch-backstop.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-backstop)
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"

make_home() {  # <dir>
  mkdir -p "$1/state"
  : > "$1/AGENTS.md"
  printf '%s\n' "$1"
}

# A dead pid: a finished child's pid is not reused within the test.
dead_pid() {
  local pid
  sleep 0 &
  pid=$!
  wait "$pid" 2>/dev/null || true
  printf '%s\n' "$pid"
}

# The incident's pre-state: one task in flight, the previous session's dead pid
# on the lock, its interrupted hook's consumed notice, and a beacon <age> old.
make_down_home() {  # <dir> <beacon-age-seconds>
  local dir
  dir=$(make_home "$1")
  : > "$dir/state/task-a.meta"
  dead_pid > "$dir/state/.lock"
  printf 'sess-resumed\n' > "$dir/state/.lock-session"
  printf 'session_identity=linux-starttime=1 cmdline-hex=00\nsession_id=sess-resumed\n' \
    > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.last-watcher-beat"
  fm_touch_epoch "$(( $(date +%s) - $2 ))" "$dir/state/.last-watcher-beat"
  printf '%s\n' "$dir"
}

run_backstop() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$BACKSTOP" "$@"
}

# record-endpoint with discovery pinned to an explicit endpoint.
record_as() {  # <home> <backend> <target>
  local home=$1
  FM_SUPERVISOR_BACKEND=$2 FM_SUPERVISOR_TARGET=$3 run_backstop "$home" record-endpoint
}

test_usage() {
  local out status=0
  out=$("$BACKSTOP" --help) || status=$?
  expect_code 0 "$status" "--help must exit 0"
  assert_contains "$out" 'timer-files <linux|darwin> <dir>' "--help must name every action"
  status=0
  "$BACKSTOP" bogus >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an unknown action must be refused"
  status=0
  "$BACKSTOP" check extra >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "a stray argument must be refused"
  pass "backstop: usage is explicit and refuses unknown input"
}

test_record_endpoint_gate() {
  local home out status=0 standin_dir standin pid
  home=$(make_home "$TMP_ROOT/record-free")
  out=$(record_as "$home" tmux '%7' 2>&1) || status=$?
  expect_code 0 "$status" "record-endpoint must exit 0"
  [ -z "$out" ] || fail "record-endpoint must be silent, got: $out"
  assert_contains "$(cat "$home/state/.watch-backstop-endpoint")" 'target=%7' "a home with no lock must record the endpoint"
  assert_contains "$(cat "$home/state/.watch-backstop-endpoint")" 'backend=tmux' "the record must carry the backend"

  home=$(make_home "$TMP_ROOT/record-dead")
  dead_pid > "$home/state/.lock"
  record_as "$home" tmux '%8'
  assert_contains "$(cat "$home/state/.watch-backstop-endpoint")" 'target=%8' \
    "a resumed session facing the dead session's lock must record its endpoint"

  # A live harness outside this ancestry owns the lock: never record over it.
  home=$(make_home "$TMP_ROOT/record-foreign")
  standin_dir="$TMP_ROOT/standin"
  if standin=$(fm_agent_standin "$standin_dir"); then
    cp "$standin" "$standin_dir/claude" 2>/dev/null || ln -sf "$standin" "$standin_dir/claude"
    "$standin_dir/claude" 60 >/dev/null 2>&1 &
    pid=$!
    printf '%s\n' "$pid" > "$home/state/.lock"
    record_as "$home" tmux '%9'
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    assert_absent "$home/state/.watch-backstop-endpoint" "a session must not record over a live foreign lock owner"
  fi

  # No endpoint discovered (only the tmux fallback): nothing is recorded.
  home=$(make_home "$TMP_ROOT/record-none")
  env -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u TERM_PROGRAM -u HC_TERMINAL_ID \
    -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND -u FM_BACKEND \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$BACKSTOP" record-endpoint
  assert_absent "$home/state/.watch-backstop-endpoint" "the tmux fallback target must never be recorded"
  pass "backstop: record-endpoint records only for a reclaimable or own lock and a discovered endpoint"
}

test_check_without_need_or_with_fresh_beat_does_nothing() {
  local home out
  home=$(make_home "$TMP_ROOT/no-need")
  : > "$home/state/.last-watcher-beat"
  fm_touch_epoch "$(( $(date +%s) - 40000 ))" "$home/state/.last-watcher-beat"
  printf 'episode=x\n' > "$home/state/.watch-backstop-episode"
  out=$(run_backstop "$home" check)
  assert_contains "$out" 'supervised or not needed' "an idle home must not be treated as down"
  assert_absent "$home/state/.watch-backstop-episode" "an idle home must end any stale episode"

  home=$(make_down_home "$TMP_ROOT/fresh" 60)
  out=$(run_backstop "$home" check)
  assert_contains "$out" 'supervised or not needed' "a beacon under the threshold must not be treated as down"
  pass "backstop: a home with no need or a fresh beacon is left alone"
}

test_check_without_endpoint_reports_and_retries() {
  local home out
  home=$(make_down_home "$TMP_ROOT/no-endpoint" 35000)
  out=$(run_backstop "$home" check)
  assert_contains "$out" 'not rung: no endpoint recorded' "a down home with no endpoint must say why it could not ring"
  assert_absent "$home/state/.watch-backstop-episode" "an unrung episode must stay open for the next poll"
  pass "backstop: a down home with no recorded endpoint reports and stays retryable"
}

test_timer_files() {
  local home dir out status=0 name
  home=$(make_home "$TMP_ROOT/timer")
  dir="$TMP_ROOT/timer-out"
  out=$(run_backstop "$home" timer-files linux "$dir") || fail "linux timer-files failed"
  name=$(printf '%s\n' "$out" | sed -n '1s/\.service$//p')
  [ -n "$name" ] || fail "timer-files did not name its service: $out"
  assert_contains "$(cat "$dir/$name.service")" "\"FM_HOME=$(cd -P "$home" && pwd -P)\"" "the service must bind this home"
  assert_contains "$(cat "$dir/$name.service")" "fm-watch-backstop.sh\" check" "the service must run one check"
  assert_contains "$(cat "$dir/$name.timer")" 'OnUnitActiveSec=5min' "the timer must poll every five minutes"
  run_backstop "$home" timer-files linux "$dir" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "timer-files must never overwrite existing scheduler files"
  out=$(run_backstop "$home" timer-files darwin "$dir") || fail "darwin timer-files failed"
  python3 -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); assert d["ProgramArguments"][1]=="check" and d["StartInterval"]==300, d' \
    "$dir/$out" || fail "the launchd plist is not a valid five-minute check agent"
  [ "$(run_backstop "$(make_home "$TMP_ROOT/timer-other")" timer-files linux "$TMP_ROOT/timer-other-out" | head -n 1)" != "$name.service" ] \
    || fail "two homes must get distinct unit names"
  pass "backstop: timer-files writes per-home scheduler files and never overwrites"
}

# --- real ring through a private tmux socket --------------------------------

REAL_TMUX=$(command -v tmux 2>/dev/null || true)
SOCKET="fm-backstop-$$"
SHIM_DIR=
PANE=
SUBMITTED=

tmux_cleanup() {
  [ -z "$REAL_TMUX" ] || "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
}
trap 'tmux_cleanup; fm_test_cleanup' EXIT

start_composer_pane() {
  local loop="$TMP_ROOT/composer.sh"
  SUBMITTED="$TMP_ROOT/submitted.log"
  : > "$SUBMITTED"
  cat > "$loop" <<'LOOP'
#!/usr/bin/env bash
LOG=$1
stty -echo -icanon min 1 time 0 2>/dev/null || true
_buf=
redraw() { printf '\r\033[K\xe2\x9d\xaf %s' "$_buf"; }
redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ] || [ "$_ch" = $'\r' ] || [ "$_ch" = $'\n' ]; then
    printf '%s\n' "$_buf" >> "$LOG"
    _buf=
    printf '\r\033[K\n'
    redraw
    continue
  fi
  case "$_ch" in
    $'\177'|$'\b') _buf=${_buf%?} ;;
    *) _buf="$_buf$_ch" ;;
  esac
  redraw
done
LOOP
  chmod +x "$loop"
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s main -x 220 -y 50
  PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t main '#{pane_id}')
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" "bash '$loop' '$SUBMITTED'" Enter
  SHIM_DIR="$TMP_ROOT/shim"
  mkdir -p "$SHIM_DIR"
  printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$REAL_TMUX" "$SOCKET" > "$SHIM_DIR/tmux"
  chmod +x "$SHIM_DIR/tmux"
  local i=0
  while [ "$i" -lt 50 ]; do
    "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$PANE" | grep -q $'\xe2\x9d\xaf' && return 0
    sleep 0.1
    i=$((i + 1))
  done
  fail "the composer pane never drew its prompt"
}

ring_check() {  # <home>
  PATH="$SHIM_DIR:$PATH" TMUX='' run_backstop "$1" check
}

record_pane() {  # <home> <harness>
  printf 'backend=tmux\ntarget=%s\nharness=%s\nrecorded_at=%s\n' "$PANE" "$2" "$(date +%s)" \
    > "$1/state/.watch-backstop-endpoint"
}

test_ring_once_per_stale_episode() {
  local home out line record
  [ -n "$REAL_TMUX" ] || { pass "backstop: ring skipped (tmux not installed)"; return; }
  start_composer_pane
  home=$(make_down_home "$TMP_ROOT/down" 35000)
  record_pane "$home" claude

  out=$(ring_check "$home")
  assert_contains "$out" "rang $PANE on tmux" "a home down for hours must ring its recorded endpoint: $out"
  line=$(tail -n 1 "$SUBMITTED")
  record=$(printf '%s\n' "$line" | sed -n "s|^[^']*'\([^']*\.msg\)'.*$|\1|p")
  [ -n "$record" ] || fail "a Claude primary must receive the record-backed doorbell, got: $line"
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-operational-input.sh" open "$record")" \
    '583 minutes old' "the record must say how long supervision has been down"
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-operational-input.sh" open "$record")" '1 task(s) in flight' \
    "the record must name the in-flight work"
  [ "$(printf '%s' "$line" | FM_HOME="$home" "$ROOT/bin/fm-operational-input.sh" doorbell-kind)" = watcher ] \
    || fail "the doorbell must resolve to a watcher operational record"

  out=$(ring_check "$home")
  assert_contains "$out" 'already rung' "a second poll in the same episode must not ring again"
  [ "$(grep -c . "$SUBMITTED")" -eq 1 ] || fail "the episode rang more than once: $(cat "$SUBMITTED")"

  # The watcher recovers, then dies again: a new episode rings once more.
  touch "$home/state/.last-watcher-beat"
  out=$(ring_check "$home")
  assert_contains "$out" 'supervised or not needed' "a fresh beacon must end the episode"
  assert_absent "$home/state/.watch-backstop-episode" "a fresh beacon must clear the episode record"
  fm_touch_epoch "$(( $(date +%s) - 1200 ))" "$home/state/.last-watcher-beat"
  out=$(ring_check "$home")
  assert_contains "$out" "rang $PANE" "a new stale episode must ring again"
  [ "$(grep -c . "$SUBMITTED")" -eq 2 ] || fail "the new episode did not ring exactly once"
  pass "backstop: a down home is rung once per stale episode through a real pane"
}

test_ring_typed_input_for_other_harnesses() {
  local home out line kind
  [ -n "$REAL_TMUX" ] || { pass "backstop: typed ring skipped (tmux not installed)"; return; }
  home=$(make_down_home "$TMP_ROOT/down-codex" 1800)
  record_pane "$home" codex
  out=$(ring_check "$home")
  assert_contains "$out" "rang $PANE" "a codex primary must be rung: $out"
  line=$(tail -n 1 "$SUBMITTED")
  kind=$(printf '%s' "$line" | "$ROOT/bin/fm-operational-input.sh" kind) || kind=
  [ "$kind" = watcher ] || fail "a harness that keeps invisible characters must get the typed watcher input, got: $line"
  pass "backstop: a primary that keeps invisible characters gets the typed watcher input"
}

test_ring_defers_on_pending_composer_and_dead_target() {
  local home out before
  [ -n "$REAL_TMUX" ] || { pass "backstop: deferral skipped (tmux not installed)"; return; }
  home=$(make_down_home "$TMP_ROOT/down-busy" 3600)
  record_pane "$home" claude
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" -l 'half typed'
  sleep 0.3
  before=$(grep -c . "$SUBMITTED")
  out=$(ring_check "$home")
  assert_contains "$out" 'deferred: composer' "a half-typed line must defer the ring: $out"
  assert_absent "$home/state/.watch-backstop-episode" "a deferred ring must stay retryable"
  [ "$(grep -c . "$SUBMITTED")" -eq "$before" ] || fail "the deferred ring still submitted"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" C-h C-h C-h C-h C-h C-h C-h C-h C-h C-h
  sleep 0.3

  printf 'backend=tmux\ntarget=%%999\nharness=claude\n' > "$home/state/.watch-backstop-endpoint"
  out=$(ring_check "$home")
  assert_contains "$out" 'does not exist' "a vanished endpoint must be reported, not typed into: $out"
  assert_absent "$home/state/.watch-backstop-episode" "an unrung vanished endpoint must stay retryable"
  pass "backstop: a busy composer or a vanished endpoint defers without ringing"
}

fm_test_run \
  test_usage \
  test_record_endpoint_gate \
  test_check_without_need_or_with_fresh_beat_does_nothing \
  test_check_without_endpoint_reports_and_retries \
  test_timer_files \
  test_ring_once_per_stale_episode \
  test_ring_typed_input_for_other_harnesses \
  test_ring_defers_on_pending_composer_and_dead_target
