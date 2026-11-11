#!/usr/bin/env bash
# fm-nm-daemon-env.sh - keep the no-mistakes daemon's agents on a 5m prompt-cache TTL.
#
# Usage: fm-nm-daemon-env.sh check|install|status
#
# The no-mistakes daemon starts every pipeline agent as a child that inherits the
# daemon's own environment, so CLAUDE_CODE_PROMPT_CACHE_TTL=5m on the daemon puts
# each `claude -p` run on the 5-minute cache TTL instead of the 1-hour one. Those
# runs rarely re-read a cache entry after 5 minutes, so the 1-hour write premium
# is wasted spend.
#
# The value lives in a systemd user drop-in, <unit>.service.d/firstmate-cache-ttl.conf,
# beside the unit that `no-mistakes daemon start` and `no-mistakes update`
# regenerate. A drop-in is a separate file, so a regenerated unit keeps it.
# Only a unit whose ExecStart `--root` is this machine's no-mistakes root
# (NM_HOME, default ~/.no-mistakes) is touched; other roots' units are left alone.
#
# macOS (launchd) route: the daemon's LaunchAgent plist is not a place to put the
# value. no-mistakes renders the whole plist itself and its EnvironmentVariables
# hold only the proxy variables (HTTP_PROXY, HTTPS_PROXY, ALL_PROXY, NO_PROXY and
# their lowercase forms), and every `no-mistakes daemon start` or `update` writes
# it again, so an edit to the plist is lost. `launchctl setenv` and any other
# user-domain setting are out too: apps and terminals launched by launchd would
# inherit it and change interactive Claude sessions. The durable, daemon-only
# route is no-mistakes' own setting, `agent_path_override.claude` in
# <root>/config.yaml (a user-owned file no-mistakes does not regenerate), pointing
# at a small wrapper, <root>/firstmate/claude-cache-ttl, that exports the variable
# and execs the real claude. Only the claude the daemon starts goes through it.
# The route applies when a LaunchAgent plist
# com.kunchenguid.no-mistakes.daemon*.plist in the LaunchAgents directory has this
# machine's root as its `--root` (no `--root` means the default root). It never
# runs launchctl. An existing agent_path_override.claude that is not this wrapper
# is left alone and reported.
#
#   check    Prints nothing when every matching unit carries the exact drop-in
#            (systemd) or the override and wrapper are current (launchd), or when
#            neither a systemd user unit nor a launchd plist matches. Otherwise
#            prints one NM_DAEMON_ENV line per gap. Writes nothing, exits 0.
#            fm-bootstrap.sh runs this, so a gap is an ordinary diagnostic.
#   install  Writes the drop-in for each matching unit (atomic, idempotent) and
#            runs `systemctl --user daemon-reload`; on launchd it writes the
#            wrapper and adds the one config key (atomic, idempotent). It never
#            restarts the daemon: the daemon is shared, and a restart kills every
#            lane's live run. The setting takes effect at the next restart that
#            no-mistakes or firstmate already performs (`no-mistakes update`,
#            fm-install-pinned.sh).
#   status   Per matching unit: whether the drop-in is current, and whether the
#            running daemon process already carries the variable; on launchd the
#            override and wrapper state.
#
# Verify a run: a no-mistakes claude run's usage shows ephemeral_5m_input_tokens
# instead of ephemeral_1h_input_tokens.
# Test hooks: FM_NM_DAEMON_UNIT_DIR replaces the systemd user unit directory,
# FM_NM_DAEMON_LAUNCHD_DIR the LaunchAgents directory, NM_HOME the no-mistakes root.
set -u

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
DROPIN_NAME=firstmate-cache-ttl.conf
DROPIN_BODY='# Managed by firstmate (bin/fm-nm-daemon-env.sh); do not edit.
# The no-mistakes daemon passes its environment to every claude -p agent it starts.
# 5m stops those runs paying the 1h cache-write premium for reads that never come.
[Service]
Environment="CLAUDE_CODE_PROMPT_CACHE_TTL=5m"'

unit_dir=${FM_NM_DAEMON_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
nm_root=${NM_HOME:-$HOME/.no-mistakes}
nm_root=${nm_root%/}
launchd_dir=${FM_NM_DAEMON_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}
config_file=$nm_root/config.yaml
wrapper_path=$nm_root/firstmate/claude-cache-ttl

# Units whose ExecStart runs `daemon run --root <this root>`, one name per line.
matching_units() {
  local f root
  for f in "$unit_dir"/no-mistakes-daemon-*.service; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    root=$(sed -n 's/^ExecStart=.* daemon run .*--root[= ]\([^ ]*\).*$/\1/p' "$f" | head -1)
    root=${root%/}
    [ -n "$root" ] && [ "$root" = "$nm_root" ] && basename "$f"
  done
}

dropin_path() { printf '%s/%s.d/%s' "$unit_dir" "$1" "$DROPIN_NAME"; }

# current | missing | different
dropin_state() {
  local p
  p=$(dropin_path "$1")
  if [ ! -f "$p" ]; then
    echo missing
  elif [ "$(cat "$p" 2>/dev/null)" = "$DROPIN_BODY" ]; then
    echo current
  else
    echo different
  fi
}

# yes | no | unknown: does the running daemon already carry the variable?
daemon_has_value() {
  local pid
  pid=$(systemctl --user show -p MainPID --value "$1" 2>/dev/null) || { echo unknown; return; }
  case "$pid" in ''|0|*[!0-9]*) echo unknown; return ;; esac
  [ -r "/proc/$pid/environ" ] || { echo unknown; return; }
  if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -qx 'CLAUDE_CODE_PROMPT_CACHE_TTL=5m'; then
    echo yes
  else
    echo no
  fi
}

# ---- macOS launchd route (see the header: override + wrapper, never the plist) ----

# The --root a LaunchAgent plist passes to `daemon run`; empty when it passes none.
plist_root() {
  awk '
    !match($0, /<string>[^<]*<\/string>/) { next }
    { v = substr($0, RSTART + 8, RLENGTH - 17) }
    want { print v; exit }
    v == "--root" { want = 1; next }
    v ~ /^--root=/ { sub(/^--root=/, "", v); print v; exit }
  ' "$1"
}

# LaunchAgent plists whose daemon root is this machine's root, one name per line.
matching_plists() {
  local f root
  for f in "$launchd_dir"/com.kunchenguid.no-mistakes.daemon*.plist; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    root=$(plist_root "$f")
    [ -n "$root" ] || root=$HOME/.no-mistakes
    root=${root%/}
    [ "$root" = "$nm_root" ] && basename "$f"
  done
}

# none (no override) | block (agent_path_override: exists, no claude entry) |
# ours | foreign (another claude path) | unsupported (not a block mapping)
config_state() {
  [ -f "$config_file" ] || { echo none; return; }
  awk -v want="$wrapper_path" '
    function unq(v) {
      sub(/[ \t]+#.*$/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      return v
    }
    /^agent_path_override:/ {
      if (unq(substr($0, 21)) != "") { state = "unsupported"; exit }
      inblk = 1; state = "block"; next
    }
    inblk && /^[^ \t#]/ { inblk = 0 }
    inblk && /^[ \t]+claude:/ {
      v = $0; sub(/^[ \t]+claude:/, "", v)
      state = (unq(v) == want ? "ours" : "foreign")
    }
    END { print (state == "" ? "none" : state) }
  ' "$config_file"
}

wrapper_body() {  # <real claude path>
  # The single-quoted lines are the wrapper's own text; their $ must not expand here.
  # shellcheck disable=SC2016
  printf '%s\n' '#!/bin/sh' \
    '# Managed by firstmate (bin/fm-nm-daemon-env.sh); do not edit.' \
    '# no-mistakes starts its claude agents through this file (agent_path_override.claude' \
    '# in its config.yaml), so the 5m prompt-cache TTL reaches those runs and no other process.' \
    "FM_CLAUDE_REAL='$1'" \
    'if [ ! -x "$FM_CLAUDE_REAL" ]; then' \
    '  FM_CLAUDE_REAL=$(command -v claude 2>/dev/null) || FM_CLAUDE_REAL=' \
    '  [ -n "$FM_CLAUDE_REAL" ] || { echo "claude-cache-ttl: no claude found; run fm-nm-daemon-env.sh install" >&2; exit 127; }' \
    'fi' \
    'CLAUDE_CODE_PROMPT_CACHE_TTL=5m' \
    'export CLAUDE_CODE_PROMPT_CACHE_TTL' \
    'exec "$FM_CLAUDE_REAL" "$@"'
}

wrapper_real() { sed -n "s/^FM_CLAUDE_REAL='\\(.*\\)'\$/\\1/p" "$wrapper_path" 2>/dev/null | head -1; }

# current | missing | different | stale (the claude path baked into the wrapper is gone)
wrapper_state() {
  local real
  [ -f "$wrapper_path" ] || { echo missing; return; }
  real=$(wrapper_real)
  if [ -z "$real" ] || [ ! -x "$wrapper_path" ] || [ "$(cat "$wrapper_path")" != "$(wrapper_body "$real")" ]; then
    echo different
  elif [ ! -x "$real" ]; then
    echo stale
  else
    echo current
  fi
}

# current | missing | foreign | unsupported | wrapper-missing | wrapper-different | wrapper-stale
launchd_state() {
  local c w
  c=$(config_state)
  case "$c" in
    foreign|unsupported) echo "$c"; return ;;
    none|block) echo missing; return ;;
  esac
  w=$(wrapper_state)
  [ "$w" = current ] && echo current || echo "wrapper-$w"
}

launchd_gap_line() {  # <plist> <state>
  local why
  case "$2" in
    foreign) why="agent_path_override.claude in $config_file is already set to something else, which firstmate leaves alone; wrap it by hand or remove it, then run install" ;;
    unsupported) why="agent_path_override in $config_file is not a plain mapping, which firstmate leaves alone; edit it by hand" ;;
    missing) why="the cache-TTL override for $1 (launchd) is missing, so its claude -p runs keep the 1h prompt-cache TTL; install: \"$SCRIPT_PATH\" install (written now, applied at the next daemon restart, never restarts it)" ;;
    *) why="the cache-TTL wrapper for $1 (launchd) is ${2#wrapper-}, so its claude -p runs may keep the 1h prompt-cache TTL; install: \"$SCRIPT_PATH\" install (written now, applied at the next daemon restart, never restarts it)" ;;
  esac
  echo "NM_DAEMON_ENV: $why"
}

# Atomically replace <dest> with stdin; <mode> applies to a new file, an existing file keeps its own.
write_atomic() {  # <dest> <mode>
  local dest=$1 mode=$2 dir tmp
  dir=$(dirname "$dest")
  tmp=$(mktemp "$dir/.$(basename "$dest").XXXXXX") || { echo "fm-nm-daemon-env.sh: cannot write in $dir" >&2; return 1; }
  if [ -f "$dest" ]; then cp -p "$dest" "$tmp" 2>/dev/null || :; else chmod "$mode" "$tmp"; fi
  if ! { cat > "$tmp" && mv -f "$tmp" "$dest"; }; then
    rm -f "$tmp"
    echo "fm-nm-daemon-env.sh: cannot write $dest" >&2
    return 1
  fi
}

install_launchd() {
  local state real
  state=$(launchd_state)
  case "$state" in
    foreign|unsupported)
      launchd_gap_line "launchd" "$state" | sed 's/^NM_DAEMON_ENV: /fm-nm-daemon-env.sh: /' >&2
      return 1 ;;
    current) echo "launchd: override and wrapper already current"; return 0 ;;
  esac
  [ -d "$nm_root" ] || { echo "fm-nm-daemon-env.sh: no-mistakes root $nm_root does not exist" >&2; return 1; }
  real=$(wrapper_real)
  if [ -z "$real" ] || [ ! -x "$real" ]; then
    real=$(command -v claude 2>/dev/null) || real=
  fi
  case "$real" in
    "") echo "fm-nm-daemon-env.sh: no claude on PATH to wrap; nothing written" >&2; return 1 ;;
    *\'*) echo "fm-nm-daemon-env.sh: claude path $real has a quote; nothing written" >&2; return 1 ;;
  esac
  mkdir -p "$(dirname "$wrapper_path")" || { echo "fm-nm-daemon-env.sh: cannot create $(dirname "$wrapper_path")" >&2; return 1; }
  if [ "$(wrapper_state)" != current ]; then
    wrapper_body "$real" | write_atomic "$wrapper_path" 0755 || return 1
    chmod 0755 "$wrapper_path"
    echo "launchd: wrote $wrapper_path (claude: $real)"
  fi
  state=$(config_state)
  if [ "$state" != ours ]; then
    {
      if [ "$state" = block ]; then
        awk -v line="  claude: \"$wrapper_path\"" '{ print } /^agent_path_override:/ && !done { print line; done = 1 }' "$config_file"
      else
        if [ -s "$config_file" ]; then
          cat "$config_file"
          [ -z "$(tail -c1 "$config_file")" ] || echo
          echo
        fi
        printf '%s\n' '# Managed by firstmate (bin/fm-nm-daemon-env.sh): the claude agents this daemon starts run on a 5m prompt-cache TTL.' \
          'agent_path_override:' "  claude: \"$wrapper_path\""
      fi
    } | write_atomic "$config_file" 0644 || return 1
    echo "launchd: set agent_path_override.claude in $config_file"
  fi
}

cmd_check() {
  local unit state
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    state=$(dropin_state "$unit")
    [ "$state" = current ] && continue
    echo "NM_DAEMON_ENV: the cache-TTL drop-in for $unit is $state, so its claude -p runs keep the 1h prompt-cache TTL; install: \"$SCRIPT_PATH\" install (written now, applied at the next daemon restart, never restarts it)"
  done < <(matching_units)
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    state=$(launchd_state)
    [ "$state" = current ] && continue
    launchd_gap_line "$unit" "$state"
  done < <(matching_plists)
  return 0
}

cmd_install() {
  local unit p dir tmp found=0 plist rc=0
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    found=1
    p=$(dropin_path "$unit")
    dir=$(dirname "$p")
    if [ "$(dropin_state "$unit")" = current ]; then
      echo "$unit: drop-in already current"
      continue
    fi
    mkdir -p "$dir" || { echo "fm-nm-daemon-env.sh: cannot create $dir" >&2; return 1; }
    tmp=$(mktemp "$dir/.$DROPIN_NAME.XXXXXX") || { echo "fm-nm-daemon-env.sh: cannot write in $dir" >&2; return 1; }
    if ! { printf '%s\n' "$DROPIN_BODY" > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$p"; }; then
      rm -f "$tmp"
      echo "fm-nm-daemon-env.sh: cannot write $p" >&2
      return 1
    fi
    echo "$unit: wrote $p"
  done < <(matching_units)
  plist=$(matching_plists | head -1)
  if [ "$found" = 0 ] && [ -z "$plist" ]; then
    echo "no no-mistakes-daemon unit for root $nm_root in $unit_dir; nothing to install"
    return 0
  fi
  if [ "$found" = 1 ] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload || echo "fm-nm-daemon-env.sh: systemctl --user daemon-reload failed; run it by hand" >&2
  fi
  [ -z "$plist" ] || install_launchd || rc=1
  echo "takes effect at the next daemon restart; the running daemon was not touched"
  return "$rc"
}

cmd_status() {
  local unit found=0
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    found=1
    echo "$unit: drop-in $(dropin_state "$unit"); running daemon carries CLAUDE_CODE_PROMPT_CACHE_TTL=5m: $(daemon_has_value "$unit")"
  done < <(matching_units)
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    found=1
    echo "$unit: launchd route $(launchd_state); config override $(config_state), wrapper $(wrapper_state); a running daemon is not inspected, so treat the setting as live only after its next restart"
  done < <(matching_plists)
  [ "$found" = 1 ] || echo "no no-mistakes-daemon unit for root $nm_root in $unit_dir"
}

case "${1:-}" in
  check) cmd_check ;;
  install) cmd_install ;;
  status) cmd_status ;;
  *) echo "usage: fm-nm-daemon-env.sh check|install|status" >&2; exit 2 ;;
esac
