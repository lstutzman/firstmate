#!/usr/bin/env bash
# tests/fm-spawn-claude-launch-doorbell.test.sh - after a Claude spawn commits,
# bin/fm-spawn.sh checks that the launch-brief doorbell Claude took on its
# command line actually left the composer. A composer that reads empty needs
# nothing; one that keeps holding the doorbell gets one gated submit
# (fm_task_inbox_submit_pending: one Escape only when a plugin band holds the
# keyboard, then Enter); one that still holds it after that raises one check
# wake naming the task, and the spawn itself still succeeds.
#
# The pane is the shared spawn fake with a Claude 2.1.322-shaped composer
# drawn over it (the layout tests/fm-task-inbox.test.sh uses). FM_FAKE_CLAUDE
# picks what Claude does with the doorbell after launch: `submitted` leaves the
# composer empty, `stuck` keeps the doorbell there until an Enter submits it,
# `wedged` keeps it there whatever is pressed, and `band` keeps it while a
# focused plugin band (SGR 7 inverse `[ Hide ]`) takes the Enter until one
# Escape returns the focus (docs/verification/runtime-backends.md "Claude
# plugin band focus"). Keys after the launch line's Enter are logged one per line.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-launch-doorbell)

# claude_composer_fakebin <case-dir> -> fakebin whose tmux renders the composer
claude_composer_fakebin() {
  local fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$1/fake")
  mv "$fakebin/tmux" "$fakebin/tmux.spawn"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_CLAUDE_DIR
mode=$(cat "$D/mode")
doorbell() {
  local rec
  for rec in "$FM_FAKE_CLAUDE_OPINBOX"/*.msg; do
    [ -f "$rec" ] || continue
    printf ": Firstmate operational input waiting: read '%s' and handle its contents as Firstmate operational input." \
      "$(cd -P "${rec%/*}" && pwd -P)/${rec##*/}"
    return 0
  done
}
case "${1:-}" in
  send-keys)
    args=("$@")
    literal=0 key=
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) key=$*; break ;;
      esac
    done
    if [ ! -f "$D/launched" ]; then
      case "$literal:$key" in
        1:". '"*"'")
          staged=${key#". '"}
          staged=${staged%"'"}
          ! grep -q 'operational input waiting' "$staged" 2>/dev/null || : > "$D/launch-enter-due" ;;
        0:Enter)
          if [ -f "$D/launch-enter-due" ]; then
            mv "$D/launch-enter-due" "$D/launched"
            [ "$mode" = submitted ] || doorbell > "$D/composer"
          fi ;;
      esac
      exec "$(dirname "$0")/tmux.spawn" "${args[@]}"
    fi
    printf '%s\n' "$key" >> "$D/keys"
    case "$mode:$key" in
      stuck:Enter) : > "$D/composer" ;;
      band:Escape) printf 'stuck' > "$D/mode" ;;
    esac
    exit 0 ;;
  display-message)
    case "$*" in
      *cursor_y*)
        if [ -f "$D/launched" ]; then
          case "$mode" in band) printf '4\n' ;; *) printf '2\n' ;; esac
          exit 0
        fi ;;
    esac ;;
  capture-pane)
    if [ -f "$D/launched" ]; then
      styled=0
      for a in "$@"; do [ "$a" = -e ] && styled=1; done
      {
        rule=$(printf '─%.0s' $(seq 64))
        printf '● Claude Code v2.1.322\n'
        [ "$mode" != band ] || printf 'acct-a  5h 0%%\n\033[1m\033[7m[ Hide ]\033[0m\n'
        printf '%s\n' "$rule"
        if [ -s "$D/composer" ]; then
          fold -w 60 "$D/composer" | awk 'NR == 1 { print "❯ " $0; next } { print "  " $0 }'
        else
          printf '❯ \n'
        fi
        printf '%s\n  ? for shortcuts\n' "$rule"
      } | if [ "$styled" = 1 ]; then cat; else sed $'s/\033\\[[0-9;]*m//g'; fi
      exit 0
    fi ;;
esac
exec "$(dirname "$0")/tmux.spawn" "$@"
SH
  chmod +x "$fakebin/tmux"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

CASE_OUT=
CASE_RC=
CASE_DIR=
# spawn_case <name> <mode>: one Claude spawn whose pane behaves as <mode>.
spawn_case() {
  local name=$1 mode=$2 home proj wt fakebin id="ld-$1"
  CASE_DIR="$TMP_ROOT/$name"
  home="$CASE_DIR/home"; proj="$CASE_DIR/project"; wt="$CASE_DIR/wt"
  mkdir -p "$CASE_DIR/claude"
  printf '%s' "$mode" > "$CASE_DIR/claude/mode"
  fakebin=$(claude_composer_fakebin "$CASE_DIR")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  CASE_OUT=$(FM_FAKE_CLAUDE_DIR="$CASE_DIR/claude" FM_FAKE_CLAUDE_OPINBOX="$home/state/operational-inbox" \
    FM_CLAUDE_LAUNCH_DOORBELL_POLLS=6 FM_CLAUDE_LAUNCH_DOORBELL_SETTLE_POLLS=2 FM_BACKEND_BAND_FOCUS_POLLS=1 \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  CASE_RC=$?
  [ -f "$CASE_DIR/claude/launched" ] || fail "$name: the fake pane never saw the launch Enter: $CASE_OUT"
}

keys() { cat "$CASE_DIR/claude/keys" 2>/dev/null; }
wake_rows() {
  local queue="$CASE_DIR/home/state/.wake-queue"
  if [ -f "$queue" ]; then grep -c 'launch-doorbell-pending:' "$queue"; else echo 0; fi
}

test_submitted_doorbell_needs_nothing() {
  spawn_case submitted submitted
  [ "$CASE_RC" -eq 0 ] || fail "a spawn whose doorbell submitted should succeed ($CASE_RC): $CASE_OUT"
  [ -z "$(keys)" ] || fail "an empty composer needs no key, sent: $(keys)"
  [ "$(wake_rows)" = 0 ] || fail "a submitted doorbell must raise no wake"
  pass "claude launch doorbell: a composer that reads empty after launch is left alone"
}

test_stuck_doorbell_gets_one_gated_submit() {
  spawn_case stuck stuck
  [ "$CASE_RC" -eq 0 ] || fail "a recovered spawn should succeed ($CASE_RC): $CASE_OUT"
  [ "$(keys)" = Enter ] || fail "a doorbell still in the composer should get exactly one Enter, sent: $(keys)"
  [ ! -s "$CASE_DIR/claude/composer" ] || fail "the gated submit should have emptied the composer"
  assert_contains "$CASE_OUT" "one gated submit sent it" "the spawn should say it recovered the doorbell"
  [ "$(wake_rows)" = 0 ] || fail "a recovered doorbell must raise no wake"
  pass "claude launch doorbell: a doorbell left in the composer gets one Enter and is confirmed gone"
}

test_focused_band_is_released_before_the_enter() {
  spawn_case band band
  [ "$CASE_RC" -eq 0 ] || fail "a band-trapped spawn should succeed ($CASE_RC): $CASE_OUT"
  [ "$(keys)" = $'Escape\nEnter' ] || fail "a focused band should get one Escape, then one Enter, sent: $(keys)"
  [ ! -s "$CASE_DIR/claude/composer" ] || fail "the Enter after the Escape should have submitted the doorbell"
  [ "$(wake_rows)" = 0 ] || fail "a recovered doorbell must raise no wake"
  pass "claude launch doorbell: a plugin band holding the keyboard gets one Escape before the Enter"
}

test_wedged_doorbell_raises_one_check_wake() {
  local queue
  spawn_case wedged wedged
  [ "$CASE_RC" -eq 0 ] || fail "a wedged doorbell must not fail the spawn ($CASE_RC): $CASE_OUT"
  [ "$(grep -c '^Enter$' <<<"$(keys)")" -le 2 ] || fail "the gated submit sends at most two Enters, sent: $(keys)"
  [ -s "$CASE_DIR/claude/composer" ] || fail "the fake should still hold the doorbell"
  [ "$(wake_rows)" = 1 ] || fail "a doorbell still pending after the submit should raise exactly one wake"
  queue=$(cat "$CASE_DIR/home/state/.wake-queue")
  assert_contains "$queue" "launch-doorbell-pending:ld-wedged:" "the wake key should name the task"
  assert_contains "$queue" "check: launch doorbell pending: ld-wedged" "the wake should name the task"
  assert_contains "$queue" "fm-control.sh ld-wedged submit-pending" "the wake should name the recovery verb"
  assert_contains "$CASE_OUT" "launch doorbell is still unsubmitted" "the spawn should warn"
  pass "claude launch doorbell: a doorbell that stays after the gated submit raises one check wake and the spawn still succeeds"
}

test_submitted_doorbell_needs_nothing
test_stuck_doorbell_gets_one_gated_submit
test_focused_band_is_released_before_the_enter
test_wedged_doorbell_raises_one_check_wake
