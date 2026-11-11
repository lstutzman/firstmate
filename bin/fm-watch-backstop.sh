#!/usr/bin/env bash
# fm-watch-backstop.sh - independent, out-of-session watcher backstop.
#
# Every routine re-arm owner (docs/watcher-continuity.md "Ownership") runs
# inside the primary harness session: Claude's Stop hook fires only when a turn
# ends, and the Pi, omp, and OpenCode adapters run inside their own process. A
# session that is killed and relaunched with `claude --resume <id>` comes back
# idle, and an idle session never ends a turn, so nothing inside it re-arms the
# watcher until someone types into it. This script is the one supervision path
# that runs outside the session: a per-home systemd user timer or launchd agent
# runs `check`, and when the home needs supervision and its watcher beacon has
# been stale for longer than the threshold, it rings the session's own endpoint
# once per stale episode so the next turn, and the turn end after it, restores
# supervision through the ordinary owners. It never starts, stops, or kills a
# session, a watcher, or any other process.
#
# Usage:
#   fm-watch-backstop.sh record-endpoint
#       Run inside the primary session (bin/fm-session-start.sh after a locked
#       start, and bin/fm-sessionstart-run.sh on resume, reload, and fork). It
#       resolves this session's endpoint through bin/fm-supervisor-target-lib.sh
#       and its harness through bin/fm-harness.sh, and writes them to
#       state/.watch-backstop-endpoint. It writes only when this session owns
#       the session lock, recorded it under its own trusted session id, or can
#       reclaim it (missing, dead, or otherwise reclaimable under
#       fm_session_lock_pid_blocks_reclaim), and only when discovery found a
#       real endpoint rather than the tmux fallback. Silent; always exits 0.
#   fm-watch-backstop.sh check
#       One poll, normally from the timer. Prints one outcome line and exits 0.
#   fm-watch-backstop.sh timer-files <linux|darwin> <dir>
#       Writes this home's scheduler files into <dir> and prints their names.
#       Never loads or starts a scheduler. A file that already exists is kept
#       as it is, so a second run changes nothing.
#   fm-watch-backstop.sh install
#       The one per-home install command: writes this host's scheduler files
#       (systemd user units on Linux, a launchd agent on macOS) into the user's
#       scheduler directory and enables the timer. Idempotent: on an installed
#       home it keeps the files and re-enables the same timer.
#   fm-watch-backstop.sh verify
#       Prints one WATCH_BACKSTOP diagnostic naming the install command when
#       this home has a recorded endpoint and the scheduler reports its timer
#       as not installed or not enabled; silent when there is no endpoint to
#       ring, the timer is enabled, or the scheduler cannot be asked.
#       Run by bin/fm-bootstrap.sh at session start. Always exits 0.
#   fm-watch-backstop.sh uninstall
#       Stops, disables, and removes this home's own scheduler files, named by
#       the same per-home hash install uses, and never matches another home's.
#       FM_HOME may name a directory already removed when it is the absolute
#       physical path the home had (bin/fm-teardown.sh's home retirement passes
#       it after removal). Does nothing, and never asks the scheduler, when this
#       home has no scheduler file. Prints one outcome line; exits non-zero,
#       keeping the files, when the scheduler cannot confirm the stop, or when
#       a file it found could not be removed.
#   fm-watch-backstop.sh -h|--help
#
# FM_HOME selects the home; FM_STATE_OVERRIDE overrides its state directory.
# FM_WATCH_BACKSTOP_STALE_SECS (default 900) is the beacon age at which a home
# that needs supervision and has no healthy watcher is treated as down.
#
# check, in order:
#   1. A home that does not need supervision (bin/fm-supervision-lib.sh), a
#      healthy identity-matched watcher (fm_watcher_healthy), or a beacon
#      younger than the threshold ends any stale episode and does nothing else.
#   2. The stale episode is keyed by the beacon's mtime (or "absent"), recorded
#      in state/.watch-backstop-episode after a confirmed ring. A key that was
#      already rung is not rung again; a beacon that moves starts a new episode.
#   3. The ring uses the recorded endpoint: the target must exist and its
#      composer must read affirmatively empty (fm_backend_composer_state), so a
#      busy turn, a half-typed line, a dialog, or a bare shell is never typed
#      into. A harness that strips invisible characters gets the record-backed
#      doorbell (fm_operational_record_write); any other gets the typed
#      `watcher` operational input. Only a confirmed submit records the episode;
#      a deferral or failure is retried on the next poll.
set -u

usage() {
  cat <<'EOF'
Usage: fm-watch-backstop.sh record-endpoint
       fm-watch-backstop.sh check
       fm-watch-backstop.sh timer-files <linux|darwin> <dir>
       fm-watch-backstop.sh install
       fm-watch-backstop.sh verify
       fm-watch-backstop.sh uninstall
       fm-watch-backstop.sh -h|--help

record-endpoint  record this session's endpoint for the home (run in-session)
check            one poll: ring the recorded endpoint once per stale episode
timer-files      write this home's systemd user or launchd files into <dir>
install          write and enable this home's timer (idempotent)
verify           report when this home's timer is not installed or enabled
uninstall        stop and remove this home's own timer (for a retired home)
FM_HOME selects the home. FM_WATCH_BACKSTOP_STALE_SECS (default 900) is the
watcher beacon age treated as supervision down.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ENDPOINT_FILE="$STATE/.watch-backstop-endpoint"
EPISODE_FILE="$STATE/.watch-backstop-episode"
STALE_SECS=${FM_WATCH_BACKSTOP_STALE_SECS:-900}
case "$STALE_SECS" in ''|*[!0-9]*|0) STALE_SECS=900 ;; esac

ACTION=${1:-}
case "$ACTION" in
  -h|--help) usage; exit 0 ;;
  record-endpoint|check|install|verify|uninstall) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
  timer-files) [ "$#" -eq 3 ] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac

# Only the two in-home actions load the libraries: fm-wake-lib.sh creates the
# state directory, which the scheduler actions (verify runs in a detect-only
# bootstrap) must never do.
case "$ACTION" in
  record-endpoint|check)
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    # shellcheck source=bin/fm-session-lock-lib.sh
    . "$SCRIPT_DIR/fm-session-lock-lib.sh"
    # shellcheck source=bin/fm-supervision-lib.sh
    . "$SCRIPT_DIR/fm-supervision-lib.sh"
    ;;
esac

# Write <content> to <path> atomically, or fail.
write_atomic() {  # <path> <content>
  local tmp
  tmp=$(mktemp "$1.XXXXXX" 2>/dev/null) || return 1
  if ! { printf '%s' "$2" > "$tmp" && mv -f "$tmp" "$1"; } 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

# Read key=value field <key> from file <path>.
field() {  # <path> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

record_endpoint() {
  local lock_pid target backend harness
  [ -d "$STATE" ] || return 0
  if ! fm_session_lock_owned_by_self "$STATE" && ! fm_session_lock_same_session "$STATE"; then
    lock_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
    if [ -n "$lock_pid" ]; then
      fm_session_pid_valid "$lock_pid" || return 0
      fm_session_lock_pid_blocks_reclaim "$lock_pid" && return 0
    fi
  fi
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
  target=$(discover_supervisor_target 2>/dev/null) || return 0
  backend=$(discover_supervisor_backend 2>/dev/null) || return 0
  case "$target$backend" in *[!A-Za-z0-9_.:%@=+/-]*|'') return 0 ;; esac
  harness=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || true)
  case "$harness" in ''|*[!a-z0-9-]*) harness=unknown ;; esac
  write_atomic "$ENDPOINT_FILE" "$(printf 'backend=%s\ntarget=%s\nharness=%s\nrecorded_at=%s\n' \
    "$backend" "$target" "$harness" "$(date +%s)")" || true
}

# Prints the delivery outcome; returns 0 only for a confirmed submit.
ring_endpoint() {  # <body>
  local body=$1 backend target harness composer msg verdict err
  [ -f "$ENDPOINT_FILE" ] || { printf 'no endpoint recorded for this home'; return 1; }
  backend=$(field "$ENDPOINT_FILE" backend)
  target=$(field "$ENDPOINT_FILE" target)
  harness=$(field "$ENDPOINT_FILE" harness)
  [ -n "$backend" ] && [ -n "$target" ] || { printf 'the endpoint record is incomplete'; return 1; }
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  # shellcheck source=bin/fm-operational-input.sh
  . "$SCRIPT_DIR/fm-operational-input.sh"
  fm_backend_target_exists "$backend" "$target" \
    || { printf 'endpoint %s on %s does not exist' "$target" "$backend"; return 1; }
  composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  [ "$composer" = empty ] \
    || { printf 'deferred: composer of %s is %s, not an idle empty prompt' "$target" "${composer:-unknown}"; return 1; }
  if fm_operational_harness_needs_record "$harness"; then
    fm_operational_record_write "$STATE" watcher "$body" msg \
      || { printf 'could not publish the operational record'; return 1; }
  else
    fm_operational_input_encode watcher "$body" msg \
      || { printf 'could not encode the operational input'; return 1; }
  fi
  err=$(mktemp "$STATE/.watch-backstop-err.XXXXXX" 2>/dev/null) || err=/dev/null
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$msg" 3 0.5 0.5 2>"$err")
  if [ "$verdict" = empty ]; then
    [ "$err" = /dev/null ] || rm -f "$err"
    printf 'rang %s on %s' "$target" "$backend"
    return 0
  fi
  printf 'submit to %s on %s unconfirmed (verdict=%s): %s' "$target" "$backend" "${verdict:-none}" \
    "$(tr '\n' ' ' < "$err" 2>/dev/null | cut -c1-300)"
  [ "$err" = /dev/null ] || rm -f "$err"
  return 1
}

check() {
  local grace beat age key need_desc body outcome
  [ -d "$STATE" ] || { printf 'backstop: no state directory at %s\n' "$STATE"; return 0; }
  grace=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}
  fm_supervision_status "$STATE" "$grace"
  beat="$STATE/.last-watcher-beat"
  age=$(fm_path_age "$beat")
  if [ "$FM_SUP_NEEDED" != true ] \
    || fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$grace" "$FM_HOME" \
    || [ "$age" -lt "$STALE_SECS" ]; then
    rm -f "$EPISODE_FILE" 2>/dev/null || true
    printf 'backstop: supervised or not needed\n'
    return 0
  fi
  key=$(fm_path_mtime "$beat" 2>/dev/null) || key=
  [ -n "$key" ] || key=absent
  if [ "$(field "$EPISODE_FILE" episode)" = "$key" ]; then
    printf 'backstop: episode %s already rung\n' "$key"
    return 0
  fi
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
    need_desc="$FM_SUP_IN_FLIGHT task(s) in flight"
  elif [ "$FM_SUP_SOURCES" -gt 0 ]; then
    need_desc="$FM_SUP_SOURCES process-event source(s) registered"
  elif [ "$FM_SUP_CHECKS" -gt 0 ]; then
    need_desc="$FM_SUP_CHECKS registered custom check(s)"
  else
    need_desc="X-mode relay polling active"
  fi
  if [ "$key" = absent ]; then
    body="Independent watcher backstop: this home has $need_desc, no watcher beacon exists, and no live watcher holds the home lock."
  else
    body="Independent watcher backstop: this home has $need_desc, but its watcher beacon is $((age / 60)) minutes old and no live watcher holds the home lock."
  fi
  body="$body Supervision is down and nothing inside this session re-armed it, for example after a resume. If this session has not run bin/fm-session-start.sh since it opened, run it now; otherwise run bin/fm-wake-drain.sh. Then restore supervision as the session-start operating block says before ending the turn."
  if outcome=$(ring_endpoint "$body"); then
    write_atomic "$EPISODE_FILE" "$(printf 'episode=%s\nrung_at=%s\n' "$key" "$(date +%s)")" || true
    printf 'backstop: %s for episode %s\n' "$outcome" "$key"
    return 0
  fi
  printf 'backstop: supervision down (beacon %s) but not rung: %s\n' "$FM_SUP_BEACON_DESC" "$outcome"
  return 0
}

# systemd unit value quoting and plist text escaping.
quote() { local v=${1//\\/\\\\}; v=${v//\"/\\\"}; v=${v//%/%%}; printf '"%s"' "$v"; }
xml() { local v=${1//&/&amp;}; v=${v//</&lt;}; v=${v//>/&gt;}; printf '%s' "$v"; }

# This home's resolved path and its per-home scheduler name.
home_path() { cd -P "$FM_HOME" 2>/dev/null && pwd -P; }
unit_name() {  # <linux|darwin> [<physical-home-path>]
  local home=${2:-} slug
  [ -n "$home" ] || home=$(home_path) || { echo "error: FM_HOME $FM_HOME is not a directory" >&2; return 1; }
  slug=$(printf '%s' "$home" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-12)
  case "$1" in
    linux) printf 'firstmate-watch-backstop-%s' "$slug" ;;
    darwin) printf 'com.firstmate.watch-backstop.%s' "$slug" ;;
    *) echo "error: platform must be linux or darwin" >&2; return 2 ;;
  esac
}

host_platform() {
  case "$(uname -s 2>/dev/null)" in
    Linux) printf linux ;;
    Darwin) printf darwin ;;
    *) return 1 ;;
  esac
}

scheduler_dir() {  # <linux|darwin>
  case "$1" in
    linux) printf '%s/systemd/user' "${XDG_CONFIG_HOME:-$HOME/.config}" ;;
    darwin) printf '%s/Library/LaunchAgents' "$HOME" ;;
  esac
}

timer_files() {  # <linux|darwin> <dir>
  local platform=$1 dir=$2 home name env_path self
  home=$(home_path) || { echo "error: FM_HOME $FM_HOME is not a directory" >&2; return 1; }
  name=$(unit_name "$platform") || return $?
  self="$SCRIPT_DIR/fm-watch-backstop.sh"
  env_path=${PATH:-/usr/bin:/bin}
  mkdir -p "$dir" || return 1
  case "$platform" in
    linux)
      [ -e "$dir/$name.service" ] \
        || printf '[Unit]\nDescription=Firstmate watcher backstop for %s\n[Service]\nType=oneshot\nEnvironment=%s\nEnvironment=%s\nExecStart=%s check\n' \
          "$home" "$(quote "FM_HOME=$home")" "$(quote "PATH=$env_path")" "$(quote "$self")" > "$dir/$name.service" || return 1
      [ -e "$dir/$name.timer" ] \
        || printf '[Unit]\nDescription=Firstmate watcher backstop for %s\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec=5min\n[Install]\nWantedBy=timers.target\n' \
          "$home" > "$dir/$name.timer" || return 1
      printf '%s\n%s\n' "$name.service" "$name.timer"
      ;;
    darwin)
      [ -e "$dir/$name.plist" ] || cat > "$dir/$name.plist" <<EOF || return 1
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$name</string>
  <key>ProgramArguments</key><array><string>$(xml "$self")</string><string>check</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>FM_HOME</key><string>$(xml "$home")</string>
    <key>PATH</key><string>$(xml "$env_path")</string>
  </dict>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
      printf '%s\n' "$name.plist"
      ;;
  esac
}

install_timer() {
  local platform dir name
  platform=$(host_platform) || { echo "error: no systemd user timer or launchd agent on $(uname -s 2>/dev/null)" >&2; return 2; }
  dir=$(scheduler_dir "$platform")
  timer_files "$platform" "$dir" >/dev/null || return 1
  name=$(unit_name "$platform") || return 1
  case "$platform" in
    linux)
      systemctl --user daemon-reload || return 1
      systemctl --user enable --now "$name.timer" || return 1
      printf 'installed: %s/%s.timer\n' "$dir" "$name"
      ;;
    darwin)
      launchctl print "gui/$(id -u)/$name" >/dev/null 2>&1 \
        || launchctl bootstrap "gui/$(id -u)" "$dir/$name.plist" || return 1
      printf 'installed: %s/%s.plist\n' "$dir" "$name"
      ;;
  esac
}

verify_timer() {
  local platform name state home
  [ -f "$ENDPOINT_FILE" ] || return 0
  platform=$(host_platform) || return 0
  name=$(unit_name "$platform" 2>/dev/null) || return 0
  case "$platform" in
    linux)
      state=$(systemctl --user is-enabled "$name.timer" 2>/dev/null) || true
      state=$(printf '%s' "$state" | head -n 1)
      [ -n "$state" ] || return 0
      [ "$state" != enabled ] || return 0
      name="$name.timer ($state)"
      ;;
    darwin)
      command -v launchctl >/dev/null 2>&1 || return 0
      ! launchctl print "gui/$(id -u)/$name" >/dev/null 2>&1 || return 0
      name="$name (not loaded)"
      ;;
  esac
  home=$(home_path)
  printf 'WATCH_BACKSTOP: this home'"'"'s out-of-session watcher backstop timer %s is not installed or not enabled, so an idle resumed session with supervision down is never rung; install it with: FM_HOME=%q %q install\n' \
    "$name" "$home" "$SCRIPT_DIR/fm-watch-backstop.sh"
}

# A home that still exists resolves physically; a retired one is named only by
# the absolute path it had, which its caller resolved before removing it.
uninstall_home_path() {
  if [ -d "$FM_HOME" ]; then home_path; return; fi
  case "$FM_HOME" in
    /*) printf '%s' "${FM_HOME%/}" ;;
    *) echo "error: FM_HOME $FM_HOME is neither a directory nor an absolute path" >&2; return 1 ;;
  esac
}

uninstall_timer() {
  local platform dir home name files=() f rc=0
  platform=$(host_platform) || { echo "error: no systemd user timer or launchd agent on $(uname -s 2>/dev/null)" >&2; return 2; }
  dir=$(scheduler_dir "$platform")
  home=$(uninstall_home_path) || return 1
  name=$(unit_name "$platform" "$home") || return 1
  case "$platform" in
    linux) for f in "$dir/$name.timer" "$dir/$name.service"; do [ -e "$f" ] || [ -L "$f" ] && files+=("$f"); done ;;
    darwin) f="$dir/$name.plist"; { [ -e "$f" ] || [ -L "$f" ]; } && files+=("$f") ;;
  esac
  if [ "${#files[@]}" -eq 0 ]; then
    printf 'not installed: %s\n' "$name"
    return 0
  fi
  # Stop and disable while the files exist: disable reads the timer's [Install]
  # section to find the link it removes. When the scheduler cannot confirm the
  # stop, the files are kept so a rerun still finds and stops this unit.
  case "$platform" in
    linux)
      systemctl --user disable --now "$name.timer" >/dev/null 2>&1 \
        || { echo "error: could not disable $name.timer; kept its files in $dir for a rerun" >&2; return 1; }
      systemctl --user stop "$name.service" >/dev/null 2>&1 || true
      ;;
    darwin)
      if launchctl print "gui/$(id -u)/$name" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/$name" >/dev/null 2>&1 \
          || { echo "error: could not boot out $name; kept its file in $dir for a rerun" >&2; return 1; }
      fi
      ;;
  esac
  for f in "${files[@]}"; do
    rm -f -- "$f" || rc=1
  done
  [ "$platform" != linux ] || systemctl --user daemon-reload >/dev/null 2>&1 || true
  [ "$rc" -eq 0 ] || { echo "error: could not remove every scheduler file of $name in $dir" >&2; return 1; }
  printf 'uninstalled: %s/%s\n' "$dir" "$name"
}

case "$ACTION" in
  record-endpoint) record_endpoint >/dev/null 2>&1; exit 0 ;;
  check) check ;;
  timer-files) timer_files "$2" "$3" ;;
  install) install_timer ;;
  verify) verify_timer; exit 0 ;;
  uninstall) uninstall_timer ;;
esac
