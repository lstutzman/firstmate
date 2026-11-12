#!/usr/bin/env bash
# Atomic directory claim, shared by every mkdir-as-mutual-exclusion site.
#
# fm_atomic_mkdir <dir>: create <dir> (mode 0700) and exit 0 only for the one
# caller that created it; exit non-zero when it already existed or could not be
# created. Source this file; it has no source-time side effects.
#
# It uses python3 os.mkdir (EEXIST means lost) and never the system mkdir,
# because uutils coreutils 0.10.0 (the Ubuntu 26.04 default) lets several
# concurrent mkdir calls on one path all report success. A real error other than
# EEXIST is printed to stderr, as mkdir would. Non-claim directory creation
# (mkdir -p) stays on the system mkdir.
# Race proof: tests/fm-atomic-mkdir.test.sh.

fm_atomic_mkdir() { # <dir>
  [ "$#" = 1 ] && [ -n "$1" ] || return 2
  python3 -I -c '
import os, sys
try:
    os.mkdir(sys.argv[1], 0o700)
except FileExistsError:
    sys.exit(1)
except OSError as exc:
    print("fm_atomic_mkdir: cannot create %s: %s" % (sys.argv[1], exc.strerror), file=sys.stderr)
    sys.exit(1)
' "$1"
}
