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
#   check    Prints nothing when every matching unit carries the exact drop-in
#            or when there is no matching systemd user unit (macOS launchd, no
#            daemon service). Otherwise prints one NM_DAEMON_ENV line per unit
#            that has no drop-in or a different one. Writes nothing, exits 0.
#            fm-bootstrap.sh runs this, so a gap is an ordinary diagnostic.
#   install  Writes the drop-in for each matching unit (atomic, idempotent) and
#            runs `systemctl --user daemon-reload`. It never restarts the daemon:
#            the daemon is shared, and a restart kills every lane's live run.
#            The drop-in takes effect at the next restart that no-mistakes or
#            firstmate already performs (`no-mistakes update`, fm-install-pinned.sh).
#   status   Per matching unit: whether the drop-in is current, and whether the
#            running daemon process already carries the variable.
#
# Verify a run: a no-mistakes claude run's usage shows ephemeral_5m_input_tokens
# instead of ephemeral_1h_input_tokens.
# Test hooks: FM_NM_DAEMON_UNIT_DIR replaces the systemd user unit directory,
# NM_HOME replaces the no-mistakes root.
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

cmd_check() {
  local unit state
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    state=$(dropin_state "$unit")
    [ "$state" = current ] && continue
    echo "NM_DAEMON_ENV: the cache-TTL drop-in for $unit is $state, so its claude -p runs keep the 1h prompt-cache TTL; install: \"$SCRIPT_PATH\" install (written now, applied at the next daemon restart, never restarts it)"
  done < <(matching_units)
  return 0
}

cmd_install() {
  local unit p dir tmp found=0
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
  if [ "$found" = 0 ]; then
    echo "no no-mistakes-daemon unit for root $nm_root in $unit_dir; nothing to install"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload || echo "fm-nm-daemon-env.sh: systemctl --user daemon-reload failed; run it by hand" >&2
  fi
  echo "takes effect at the next daemon restart; the running daemon was not touched"
}

cmd_status() {
  local unit found=0
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    found=1
    echo "$unit: drop-in $(dropin_state "$unit"); running daemon carries CLAUDE_CODE_PROMPT_CACHE_TTL=5m: $(daemon_has_value "$unit")"
  done < <(matching_units)
  [ "$found" = 1 ] || echo "no no-mistakes-daemon unit for root $nm_root in $unit_dir"
}

case "${1:-}" in
  check) cmd_check ;;
  install) cmd_install ;;
  status) cmd_status ;;
  *) echo "usage: fm-nm-daemon-env.sh check|install|status" >&2; exit 2 ;;
esac
