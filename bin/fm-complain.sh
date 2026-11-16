#!/usr/bin/env bash
# fm-complain.sh - a worker's one-sentence complaint about the system.
#
# Usage: fm-complain.sh "<one sentence>"
#
# Appends one JSON line to <FM_HOME>/data/agent-complaints.jsonl:
#   {"at":"<UTC ISO time>","task":"<task id>","home":"<FM_HOME>","project":"<name>","sentence":"<text>"}
# The friction officer (bin/fm-officer-friction.py) reads that file with the home's other records.
# It records only the sentence passed, never command output, so a secret is never captured unless the
# worker types one into the sentence; do not.
#
# Task id: $FM_TASK_ID, which every launched worker carries. Project: the basename of `project=` in
# <FM_HOME>/state/<task>.meta, or "unknown" when that record is absent. Home: $FM_HOME, else the code root.
# Refused with exit 2: no sentence, more than one argument, an empty or whitespace-only sentence, a
# sentence with a newline, one over 500 characters, or no task id.
# The line is written by one O_APPEND write, which the kernel makes atomic for a line this short, so
# concurrent complainers never interleave and no lock is needed (flock is absent on macOS).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MAX=500

die() {
  echo "fm-complain.sh: $*" >&2
  echo "usage: fm-complain.sh \"<one sentence>\"" >&2
  exit 2
}

[ "$#" -eq 1 ] || die "expected exactly one sentence argument, got $#"
SENTENCE=$1
case $SENTENCE in *$'\n'* | *$'\r'*) die "the sentence must be one line" ;; esac
case $SENTENCE in *[![:space:]]*) ;; *) die "the sentence is empty" ;; esac
[ "${#SENTENCE}" -le "$MAX" ] || die "the sentence is ${#SENTENCE} characters; the limit is $MAX"
TASK=${FM_TASK_ID:-}
[ -n "$TASK" ] || die "FM_TASK_ID is not set; run this from a task's own session"

PROJECT=unknown
if [ -f "$FM_HOME/state/$TASK.meta" ]; then
  p=$(sed -n 's/^project=//p' "$FM_HOME/state/$TASK.meta" | head -n 1)
  p=${p%/}
  [ -z "$p" ] || PROJECT=${p##*/}
fi

mkdir -p "$FM_HOME/data" || exit 1
FM_COMPLAIN_FILE="$FM_HOME/data/agent-complaints.jsonl" FM_COMPLAIN_TASK=$TASK FM_COMPLAIN_HOME=$FM_HOME \
  FM_COMPLAIN_PROJECT=$PROJECT FM_COMPLAIN_SENTENCE=$SENTENCE python3 -I -c '
import json, os, time
e = os.environ
rec = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "task": e["FM_COMPLAIN_TASK"],
       "home": e["FM_COMPLAIN_HOME"], "project": e["FM_COMPLAIN_PROJECT"], "sentence": e["FM_COMPLAIN_SENTENCE"]}
line = (json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
fd = os.open(e["FM_COMPLAIN_FILE"], os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
try:
    if os.write(fd, line) != len(line):
        raise SystemExit("short write")
finally:
    os.close(fd)
' || exit 1
echo "complaint recorded"
