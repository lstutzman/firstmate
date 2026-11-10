#!/usr/bin/env bash
# Live Claude plugin-band focus guard (live-harness-optin family).
#
# A Claude Code plugin can draw a band with a Button above the composer (the
# mods API's AbovePrompt slot). Once that band holds the keyboard - after a
# click on it or ctrl+x Tab - an Enter presses its focused Button instead of
# submitting text already in the composer, so a pending doorbell stays
# unsubmitted. A stub cannot prove that the band draws its focus as an inverse
# `[ label ]`, nor that one Escape gives the focus back without touching the
# composer. This guard launches real Claude Code in an isolated Herdr lab with
# only the tests/fixtures/claude-band-mod band, then requires:
#   1. the focused Button reads as focus through fm_composer_band_focus;
#   2. a bare Enter on that focus leaves the typed text unsubmitted (the hazard
#      this guard exists for; if a Claude release stops trapping Enter, the
#      guard fails so the verification record is refreshed);
#   3. fm_task_inbox_submit_pending releases the focus with one Escape and
#      submits the text, and Claude renders the requested reply.
# It fails naming the harness and version rather than degrading quietly.
#
# Run explicitly with FM_CLAUDE_BAND_FOCUS_LIVE=1 after a Claude or Herdr
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Claude plugin band focus" entry. It submits two short prompts.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
FIXTURE="$ROOT/tests/fixtures/claude-band-mod"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_CLAUDE_BAND_FOCUS_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_CLAUDE_BAND_FOCUS_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name claude-band-focus)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-claude-band-focus-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

# The adapter passes a trailing --session; this wrapper routes it through the
# lab helper and refuses any other session.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"
fm_backend_source herdr || fail "could not load the herdr adapter"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-bandlive --no-focus) \
  || fail "could not create the isolated band-focus workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
WHO="Claude Code ($VERSION) on $HERDR_VER"

# Only the fixture band: the operator's own plugins that draw into the band or
# the composer are switched off for this session alone.
lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --plugin-dir '$FIXTURE' --settings '{\"feedbackDrafts\":\"off\",\"enabledPlugins\":{\"next-steps@claude-community\":false,\"lee-mods@lee-plugins\":false}}'" >/dev/null \
  || fail "could not launch $WHO in the isolated Herdr pane"

ready=0
trusted=0
i=0
while [ "$i" -lt 60 ]; do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in
    *'Yes, I trust this folder'*)
      # The prompt preselects "No, exit"; move to "Yes" before confirming.
      if [ "$trusted" = 0 ]; then
        trusted=1
        lab pane send-keys "$PANE" down enter >/dev/null \
          || fail "could not accept Claude's folder-trust prompt"
      fi
      ;;
    *'[ Noop ]'*'bypass permissions on'*) ready=1; break ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$ready" = 1 ] || fail "$WHO never drew the fixture band above an idle composer"

focus_band() {
  local cap n=0
  lab pane send-keys "$PANE" ctrl+x tab >/dev/null || fail "could not send ctrl+x Tab to $WHO"
  while [ "$n" -lt 10 ]; do
    cap=$(lab pane read "$PANE" --source visible --format ansi 2>/dev/null || true)
    [ "$(fm_composer_band_focus "$cap")" = Noop ] && return 0
    n=$((n + 1))
    sleep 0.3
  done
  fail "$WHO: after ctrl+x Tab the band's Button never read as focus (no inverse [ Noop ] above the composer rule)"
}

TOKEN="FMBANDPONG$$_$RANDOM"
TEXT="Reply with exactly $TOKEN and nothing else."
lab pane send-text "$PANE" "$TEXT" >/dev/null || fail "could not type into $WHO"
sleep 1
fm_task_inbox_composer_holds herdr "$TARGET" "$TEXT" || fail "$WHO: the typed text never showed in the composer"

# 1 and 2: the focused Button reads as focus, and a bare Enter is trapped.
focus_band
lab pane send-keys "$PANE" enter >/dev/null || fail "could not send Enter to $WHO"
sleep 3
fm_task_inbox_composer_holds herdr "$TARGET" "$TEXT" \
  || fail "$WHO: a bare Enter on the focused band submitted the composer; the hazard this guard covers is gone, so refresh the verification record"
CHECKED=1
pass "live band focus: $WHO draws a focused band Button in inverse and traps a bare Enter, leaving the text pending"

# 3: the firstmate path releases the focus and submits.
cap=$(lab pane read "$PANE" --source visible --format ansi 2>/dev/null || true)
[ "$(fm_composer_band_focus "$cap")" = Noop ] || focus_band
rc=0
fm_task_inbox_submit_pending herdr "$TARGET" "$TEXT" || rc=$?
[ "$rc" = 0 ] || fail "$WHO: fm_task_inbox_submit_pending returned $rc on a focused band"
landed=0
i=0
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  if [ "$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] || fail "$WHO: the pending text was not submitted after the band focus was released"
pass "live band focus: $WHO submits the pending text once one Escape returns the focus from the band"

# 4: ctrl+x and a separate Tab. On lee-mods the band holds the keyboard with no
# inverse Button (ring on nothing), so every Enter is swallowed with no visible
# sign; the fixture band draws an inverse Button for the same chord. Both trap Enter.
ring_case() { # label pane target expect_no_inverse
  local label=$1 pane=$2 target=$3 noinv=$4 cap text token i landed rc
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(fm_backend_busy_state herdr "$target" 2>/dev/null)" != busy ] && break
    i=$((i + 1))
    sleep 1
  done
  token="FMBANDRING$$_$RANDOM"
  text="Reply with exactly $token and nothing else."
  lab pane send-text "$pane" "$text" >/dev/null || fail "could not type into $label"
  sleep 1
  fm_task_inbox_composer_holds herdr "$target" "$text" || fail "$label: the typed text never showed in the composer"
  lab pane send-keys "$pane" ctrl+x >/dev/null || fail "could not send ctrl+x to $label"
  sleep 1
  lab pane send-keys "$pane" tab >/dev/null || fail "could not send Tab to $label"
  sleep 1
  cap=$(lab pane read "$pane" --source visible --format ansi 2>/dev/null || true)
  if [ "$noinv" = 1 ] && fm_composer_band_focus "$cap" >/dev/null; then
    fail "$label: ctrl+x then a separate Tab drew an inverse Button; the ring-on-nothing state is gone, so refresh the verification record"
  fi
  lab pane send-keys "$pane" enter >/dev/null || fail "could not send Enter to $label"
  sleep 3
  fm_task_inbox_composer_holds herdr "$target" "$text" \
    || fail "$label: a bare Enter submitted after ctrl+x then a separate Tab; the trap this guard covers is gone, so refresh the verification record"
  cap=$(lab pane read "$pane" --source visible --format ansi 2>/dev/null || true)
  fm_composer_band_drawn "$cap" >/dev/null || fail "$label: the band was not drawn above the composer after ctrl+x then a separate Tab"
  pass "live band focus: $label swallows a bare Enter with the band drawn after ctrl+x then a separate Tab"
  rc=0
  fm_task_inbox_submit_pending herdr "$target" "$text" || rc=$?
  [ "$rc" = 0 ] || fail "$label: fm_task_inbox_submit_pending returned $rc after ctrl+x then a separate Tab"
  landed=0
  i=0
  while [ "$i" -lt 45 ]; do
    cap=$(lab pane read "$pane" --source recent --lines 200 2>/dev/null || true)
    if [ "$(printf '%s\n' "$cap" | grep -F -c "$token" || true)" -ge 2 ]; then
      landed=1
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  [ "$landed" = 1 ] || fail "$label: the pending text was not submitted after the behavioural Escape"
  pass "live band focus: $label submits the pending text through one behavioural Escape then Enter"
}

ring_case "$WHO fixture band" "$PANE" "$TARGET" 0

# The installed lee-mods band, named by version; skipped by name when absent.
LEE_VER=$(PATH="$ORIGINAL_PATH" claude plugin list 2>/dev/null | awk '/lee-mods@lee-plugins/{f=1;next} f&&/Version:/{print $2;exit}')
if [ -z "$LEE_VER" ]; then
  printf 'ok - live band focus # SKIP lee-mods ring-on-nothing: lee-mods is not installed\n'
else
  WS2=$(lab workspace create --cwd "$ROOT" --label fm-bandlive-lee --no-focus) \
    || fail "could not create the lee-mods workspace"
  PANE2=$(printf '%s' "$WS2" | jq -er '.result.root_pane.pane_id') || fail "no pane id for the lee-mods workspace"
  TARGET2="$SESSION:$PANE2"
  lab pane run "$PANE2" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"enabledPlugins\":{\"next-steps@claude-community\":false}}'" >/dev/null \
    || fail "could not launch $WHO with lee-mods in the second pane"
  ready=0
  trusted=0
  i=0
  while [ "$i" -lt 60 ]; do
    screen=$(lab pane read "$PANE2" --source visible 2>/dev/null || true)
    case "$screen" in
      *'Yes, I trust this folder'*)
        if [ "$trusted" = 0 ]; then
          trusted=1
          lab pane send-keys "$PANE2" down enter >/dev/null || fail "could not accept Claude's folder-trust prompt"
        fi
        ;;
      *'[ Hide ]'*'bypass permissions on'*) ready=1; break ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  [ "$ready" = 1 ] || fail "$WHO never drew the lee-mods band above an idle composer"
  ring_case "$WHO with lee-mods $LEE_VER" "$PANE2" "$TARGET2" 1
fi

[ "$CHECKED" -gt 0 ] || fail "FM_CLAUDE_BAND_FOCUS_LIVE=1 checked no harness"
