#!/usr/bin/env bash
# Atomic directory claim, shared by every mkdir-as-mutual-exclusion site.
#
# fm_atomic_mkdir <dir> [mode]: create <dir> (mode 0700 unless an octal mode such
# as 0777 is given; the umask still applies, as with mkdir) and exit 0 only for
# the one caller that created it; exit non-zero when it already existed or could
# not be created. Source this file; it has no source-time side effects.
#
# It uses python3 os.mkdir (EEXIST means lost) and never the system mkdir,
# because uutils coreutils 0.10.0 (the Ubuntu 26.04 default) lets several
# concurrent mkdir calls on one path all report success. A real error other than
# EEXIST is printed to stderr, as mkdir would. Non-claim directory creation
# (mkdir -p) stays on the system mkdir.
#
# fm_atomic_takeover <dir> <verify-fn> [args...]: remove a stale lock directory
# so that exactly one racer completes the removal. A caller decides a lock looks
# stale, then calls this. Takeovers on locks in one parent directory are
# serialized by a flock on that directory, held by a short-lived python3 helper
# that exits (and so frees the flock) when it is killed or its caller dies. Under
# that flock this runs "<verify-fn> <dir> [args...]" on the live path, and only
# when <dir> still exists and the verifier still calls it stale does it remove
# <dir> and exit 0; the caller then claims with fm_atomic_mkdir, which may still
# lose to another claimant. Exit 1 means nothing was removed: the lock was
# already gone, a racer ahead of this one replaced it with a live claim, or the
# lock is not stale after all. Without this, two racers that both see a dead
# owner can both rm -rf the lock, and the second removal deletes the first
# racer's fresh claim. (Renaming the lock aside instead is not safe: a racer
# with a stale view can rename a new owner's lock away, leaving the path free
# for a third claimant.)
# Race proof: tests/fm-atomic-mkdir.test.sh.

fm_atomic_mkdir() { # <dir> [mode]
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] && [ -n "$1" ] || return 2
  python3 -I -c '
import os, sys
try:
    mode = int(sys.argv[2], 8) if len(sys.argv) > 2 else 0o700
except ValueError:
    sys.exit(2)
try:
    os.mkdir(sys.argv[1], mode)
except FileExistsError:
    sys.exit(1)
except OSError as exc:
    print("fm_atomic_mkdir: cannot create %s: %s" % (sys.argv[1], exc.strerror), file=sys.stderr)
    sys.exit(1)
' "$@"
}

fm_atomic_takeover() { # <dir> <verify-fn> [args...]
  local dir=${1:-} verify=${2:-} parent ready holder tries=0 rc=1
  [ -n "$dir" ] && [ -n "$verify" ] || return 2
  shift 2
  case "$dir" in */*) parent=${dir%/*} ;; *) parent=. ;; esac
  [ -n "$parent" ] || parent=/
  ready=$(mktemp "${TMPDIR:-/tmp}/fm-takeover.XXXXXX") || return 1
  python3 -I -c '
import fcntl, os, sys, time
parent = os.getppid()
fcntl.flock(os.open(sys.argv[1], os.O_RDONLY), fcntl.LOCK_EX)
with open(sys.argv[2], "w") as out:
    out.write("locked\n")
while os.getppid() == parent:
    time.sleep(0.02)
' "$parent" "$ready" </dev/null >/dev/null 2>&1 &
  holder=$!
  while [ ! -s "$ready" ] && [ "$tries" -lt 1000 ] && kill -0 "$holder" 2>/dev/null; do
    tries=$((tries + 1))
    sleep 0.02
  done
  if [ -s "$ready" ] && { [ -e "$dir" ] || [ -L "$dir" ]; } && "$verify" "$dir" "$@"; then
    rm -rf -- "$dir" && rc=0
  fi
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  rm -f -- "$ready"
  return "$rc"
}
