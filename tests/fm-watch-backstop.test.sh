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
  printf '# kept\n' >> "$dir/$name.service"
  run_backstop "$home" timer-files linux "$dir" >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "a second timer-files run on the same home must succeed"
  assert_contains "$(cat "$dir/$name.service")" '# kept' "timer-files must never overwrite an existing scheduler file"
  out=$(run_backstop "$home" timer-files darwin "$dir") || fail "darwin timer-files failed"
  python3 -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); assert d["ProgramArguments"][1]=="check" and d["StartInterval"]==300, d' \
    "$dir/$out" || fail "the launchd plist is not a valid five-minute check agent"
  [ "$(run_backstop "$(make_home "$TMP_ROOT/timer-other")" timer-files linux "$TMP_ROOT/timer-other-out" | head -n 1)" != "$name.service" ] \
    || fail "two homes must get distinct unit names"
  pass "backstop: timer-files writes per-home scheduler files, and a rerun keeps them"
}

# Stateful systemctl, launchctl, and uname stand-ins: <dir>/enabled marks the
# timer enabled, <dir>/unreachable models a user bus that cannot be reached.
make_scheduler_fakes() {  # <dir> <Linux|Darwin>
  local fb="$1/bin" st="$1"
  mkdir -p "$fb"
  : > "$st/calls.log"
  printf '#!/usr/bin/env bash\necho %s\n' "$2" > "$fb/uname"
  {
    printf '#!/usr/bin/env bash\nST=%q\n' "$st"
    cat <<'SH'
printf '%s\n' "$*" >> "$ST/calls.log"
[ ! -e "$ST/unreachable" ] || { echo "Failed to connect to user scope bus" >&2; exit 1; }
case "$2" in
  daemon-reload) exit 0 ;;
  enable) [ "$3" = --now ] && touch "$ST/enabled" ;;
  is-enabled) if [ -e "$ST/enabled" ]; then echo enabled; else echo not-found; exit 4; fi ;;
esac
SH
  } > "$fb/systemctl"
  {
    printf '#!/usr/bin/env bash\nST=%q\n' "$st"
    cat <<'SH'
printf '%s\n' "$*" >> "$ST/calls.log"
case "$1" in
  print) [ -e "$ST/enabled" ] ;;
  bootstrap) [ -f "$3" ] && touch "$ST/enabled" ;;
  *) exit 1 ;;
esac
SH
  } > "$fb/launchctl"
  chmod +x "$fb/uname" "$fb/systemctl" "$fb/launchctl"
  printf '%s\n' "$fb"
}

test_install_is_idempotent_and_verify_reports_a_missing_timer() {
  local home st fb user out status=0 unit
  home=$(make_home "$TMP_ROOT/install-linux")
  st="$TMP_ROOT/install-linux-sched"
  user="$TMP_ROOT/install-linux-user"
  mkdir -p "$user"
  fb=$(make_scheduler_fakes "$st" Linux)
  [ -z "$(PATH="$fb:$PATH" HOME="$user" XDG_CONFIG_HOME='' run_backstop "$home" verify)" ] \
    || fail "verify must stay silent for a home with no endpoint the timer could ring"
  record_as "$home" tmux '%3'
  out=$(PATH="$fb:$PATH" HOME="$user" XDG_CONFIG_HOME='' run_backstop "$home" verify)
  assert_contains "$out" 'WATCH_BACKSTOP:' "verify must report a home whose timer is not installed"
  assert_contains "$out" "(not-found)" "verify must name the scheduler's own state"
  assert_contains "$out" "fm-watch-backstop.sh install" "verify must name the install command"
  out=$(PATH="$fb:$PATH" HOME="$user" XDG_CONFIG_HOME='' run_backstop "$home" install) || status=$?
  expect_code 0 "$status" "install must succeed: $out"
  unit=$(find "$user/.config/systemd/user" -name '*.timer' -exec basename {} .timer \;)
  [ -n "$unit" ] || fail "install did not write the timer into the user unit directory"
  assert_contains "$(cat "$st/calls.log")" "--user enable --now $unit.timer" "install must enable and start the timer"
  [ -z "$(PATH="$fb:$PATH" HOME="$user" XDG_CONFIG_HOME='' run_backstop "$home" verify)" ] \
    || fail "verify must be silent once the timer is enabled"
  printf '# kept\n' >> "$user/.config/systemd/user/$unit.service"
  status=0
  PATH="$fb:$PATH" HOME="$user" XDG_CONFIG_HOME='' run_backstop "$home" install >/dev/null || status=$?
  expect_code 0 "$status" "a second install on an installed home must succeed"
  assert_contains "$(cat "$user/.config/systemd/user/$unit.service")" '# kept' "a second install must not overwrite the unit"
  [ "$(find "$user/.config/systemd/user" -type f | grep -c .)" -eq 2 ] || fail "a second install duplicated scheduler files"
  touch "$st/unreachable"
  [ -z "$(PATH="$fb:$PATH" HOME="$user" XDG_CONFIG_HOME='' run_backstop "$home" verify)" ] \
    || fail "verify must stay silent when the user scheduler cannot be asked"

  home=$(make_home "$TMP_ROOT/install-darwin")
  st="$TMP_ROOT/install-darwin-sched"
  user="$TMP_ROOT/install-darwin-user"
  mkdir -p "$user"
  fb=$(make_scheduler_fakes "$st" Darwin)
  record_as "$home" tmux '%4'
  assert_contains "$(PATH="$fb:$PATH" HOME="$user" run_backstop "$home" verify)" '(not loaded)' \
    "verify must report a macOS home whose agent is not loaded"
  PATH="$fb:$PATH" HOME="$user" run_backstop "$home" install >/dev/null || fail "macOS install failed"
  PATH="$fb:$PATH" HOME="$user" run_backstop "$home" install >/dev/null || fail "a second macOS install failed"
  [ "$(grep -c '^bootstrap ' "$st/calls.log")" -eq 1 ] || fail "a loaded agent must not be bootstrapped again: $(cat "$st/calls.log")"
  [ -z "$(PATH="$fb:$PATH" HOME="$user" run_backstop "$home" verify)" ] || fail "verify must be silent once the agent is loaded"
  pass "backstop: install is one idempotent command, and verify names it while the timer is missing"
}

# A Herdr CLI stand-in scoped to one session and pane: it answers only calls
# that carry that exact --session, renders the composer as a bare Claude
# prompt, and reports the agent working once after each submitted Enter.
make_fake_herdr() {  # <dir> <session> <pane>
  local fb="$1/bin" st="$1/state"
  mkdir -p "$fb" "$st"
  : > "$st/buffer"
  : > "$st/submitted"
  {
    printf '#!/usr/bin/env bash\nST=%q\nSESSION=%q\nPANE=%q\n' "$st" "$2" "$3"
    cat <<'SH'
args=("$@")
n=${#args[@]}
[ "$n" -ge 2 ] && [ "${args[$((n - 2))]}" = --session ] && [ "${args[$((n - 1))]}" = "$SESSION" ] || exit 1
case "$1 $2" in
  "status --json") printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n' ;;
  "pane get") [ "$3" = "$PANE" ] && printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$PANE" ;;
  "pane read") [ "$3" = "$PANE" ] && printf '\xe2\x9d\xaf %s\n' "$(cat "$ST/buffer")" ;;
  "pane send-text") [ "$3" = "$PANE" ] && printf '%s' "$4" >> "$ST/buffer" ;;
  "pane send-keys")
    [ "$3" = "$PANE" ] || exit 1
    case "$4" in
      enter) { cat "$ST/buffer"; printf '\n'; } >> "$ST/submitted"; : > "$ST/buffer"; : > "$ST/working" ;;
      ctrl+u) : > "$ST/buffer" ;;
    esac
    ;;
  "agent get")
    [ "$3" = "$PANE" ] || exit 1
    status=idle
    if [ -e "$ST/working" ]; then status=working; rm -f "$ST/working"; fi
    printf '{"result":{"agent":{"agent":"claude","agent_status":"%s"}}}\n' "$status"
    ;;
  *) exit 1 ;;
esac
SH
  } > "$fb/herdr"
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# The timer runs check with only FM_HOME and the PATH captured at install.
unit_check() {  # <home> <path>
  env -i FM_HOME="$1" PATH="$2" "$BACKSTOP" check
}

test_ring_herdr_from_bare_unit_env() {
  local home fb out
  command -v jq >/dev/null 2>&1 || { pass "backstop: herdr ring skipped (jq not installed)"; return; }
  fb=$(make_fake_herdr "$TMP_ROOT/herdr" fmhome 'w1:p2')
  home=$(make_down_home "$TMP_ROOT/down-herdr" 35000)
  record_as "$home" herdr 'fmhome:w1:p2'
  assert_contains "$(cat "$home/state/.watch-backstop-endpoint")" 'backend=herdr' "the herdr endpoint must be recorded"

  out=$(unit_check "$home" "$fb:$PATH")
  assert_contains "$out" 'rang fmhome:w1:p2 on herdr' "the bare unit environment must ring the recorded herdr pane: $out"
  [ "$(grep -c . "$TMP_ROOT/herdr/state/submitted")" -eq 1 ] || fail "the herdr pane did not receive exactly one submit"
  assert_contains "$(cat "$TMP_ROOT/herdr/state/submitted")" '.msg' "a Claude primary on herdr must receive the record-backed doorbell"

  out=$(unit_check "$home" "$fb:$PATH")
  assert_contains "$out" 'already rung' "a second unit poll in the same episode must not ring"
  [ "$(grep -c . "$TMP_ROOT/herdr/state/submitted")" -eq 1 ] || fail "the herdr episode rang more than once"

  fm_touch_epoch "$(( $(date +%s) - 1500 ))" "$home/state/.last-watcher-beat"
  out=$(unit_check "$home" "$fb:$PATH")
  assert_contains "$out" 'rang fmhome:w1:p2 on herdr' "a new stale episode must ring the herdr pane again: $out"
  [ "$(grep -c . "$TMP_ROOT/herdr/state/submitted")" -eq 2 ] || fail "the new herdr episode did not ring exactly once"
  pass "backstop: the unit's bare environment rings a herdr endpoint once per stale episode"
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
  test_install_is_idempotent_and_verify_reports_a_missing_timer \
  test_ring_herdr_from_bare_unit_env \
  test_ring_once_per_stale_episode \
  test_ring_typed_input_for_other_harnesses \
  test_ring_defers_on_pending_composer_and_dead_target
