#!/usr/bin/env bash
# fm-commitment.sh - the standing-commitments register: record, list and retire a home's "from now on" promises.
#
# Usage:
#   fm-commitment.sh add --id <slug> --commitment <text> --lee-words <quoted words, where and when>
#                        [--owner <home id>] --enforcement <spec> --verify <spec>
#   fm-commitment.sh retire --id <slug> --reason <text>
#   fm-commitment.sh list [--all] [--json]
#
# Why: a promise to behave differently "from now on" that nothing enforces is how a fix gets announced and never turned on.
# Every home keeps its own register at <FM_HOME>/data/standing-commitments.json ({"version":1,"rows":[...]}), and the
# page-check officer (bin/fm-officer-page-check.py) evaluates every unretired row of every home it reads on each run.
# A row: id, commitment, lee_words, owner, enforcement, verify, recorded_at (UTC), retired (null, or {at, reason}).
# --owner defaults to this home's id (the basename of FM_HOME); a row may be recorded here on another home's behalf.
# A status line that makes the commitment carries the mark [commitment=<id>] so the officer sees it was recorded.
# Rows are never deleted: retire marks one (the officer then skips it), and its id stays taken.
#
# Specs (typed and read-only: the officer never runs a shell command from a row). Both are validated at add; a malformed
# one is refused with exit 2.
#   --enforcement  the check, hook or guard that makes the old behaviour fail:
#     file:<absolute path>                        the file must exist (refused at add when it does not)
#     file:<absolute path>#contains=<literal>     and contain that literal, proving the check is wired in
#     memory | none                               accepted, always red: a memory note is not enforcement
#   --verify  the proof that the commitment ran, which must exist after each occurrence:
#     file:<absolute path or glob>[;max-age=<N>h]                  a matching file exists, newer than N hours when given
#     log:<absolute path or glob>;regex=<re>[;max-count=<N>][;max-age=<N>h]
#                                                                  a line matches (Python re, per line, so lookaheads can
#                                                                  exclude lines); with max-age the newest stamped match
#                                                                  (an [at=<epoch>] or leading ISO stamp), else the file's
#                                                                  mtime, must be recent enough. With max-count every
#                                                                  matching file is checked on its own and the row is red
#                                                                  when any one holds more than N matching lines; the evidence
#                                                                  names the file and its count. max-age then keeps only
#                                                                  files modified within N hours.
#     status:<home id>;regex=<re>[;max-age=<N>h]                   a line of that home's state/*.status matches
#     none                                                         accepted, always red
#   Every path and glob is resolved on the machine that runs the officer, so a row's files and logs must be readable there.
#   The regex is everything between `regex=` and the trailing options, so it may contain `;`. A path holds no `;`.
#   Logs are read from their last 8 MiB, each line cut to 4000 characters.
#
# Exit: 0 done, 2 refused (usage, malformed spec, missing enforcement file, duplicate or unknown id), 1 unreadable register.
# The register is rewritten atomically under a lock (data/.standing-commitments.lock); docs/configuration/home-and-state.md
# places it among the home's data files.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I "$SCRIPT_DIR/fm-commitment.py" "$@"
