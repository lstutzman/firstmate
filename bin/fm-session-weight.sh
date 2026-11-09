#!/usr/bin/env bash
# fm-session-weight.sh - list long-lived or retired-model claude/codex sessions, without a model turn.
#
# Usage: fm-session-weight.sh [--ps FILE] [--proc-root DIR] [--db PATH] [--now EPOCH]
#                             [--min-age-hours N] [--retired REGEX] [--window-hours N]
#                             [--note-dir DIR] [--summary]
#
# Reads the process table (`ps -eo pid=,etimes=,args=`, or FILE in the same format) and keeps each
# process whose command is `claude` or `codex`. A session is flagged when it is older than
# --min-age-hours (default 24) or its --model flag matches --retired (default
# $FM_SESSION_WEIGHT_RETIRED, else config/session-weight-retired in the home, else claude-opus-4).
# One line per flagged session names process id, home (an fm-homes path in its --add-dir or working
# directory, else the last two directory components), age and model flag, then the account-level
# context of recent requests for that model.
#
# LIMIT, stated in every line: the usage database (CPA_USAGE_DB, default
# ~/.local/share/cpa-usage/usage.db, opened read-only; cpa-usage-axi has no per-request command, so
# its database is read directly) holds account logins and models but no session key. A session's
# context is therefore inferred from the model's recent request sizes (input + cache read + cache
# write over the last --window-hours, default 6), never measured per session. No per-session source
# other than a transcript exists, and transcripts are never read.
#
# Only the pid, age, --model value and home path are printed; the rest of a command line and the
# process environment are never read or printed. It never kills, signals or restarts anything.
#
# --note-dir DIR writes DIR/<UTC day>.txt once per day when something is flagged. With --summary the
# output is then one wake line (key session-weight-<day>) printed only on the run that wrote the note.
# --proc-root DIR replaces /proc for the working-directory lookup (tests).
set -u

PS_FILE="${FM_SESSION_WEIGHT_PS:-}" PROC_ROOT=/proc DB="${CPA_USAGE_DB:-$HOME/.local/share/cpa-usage/usage.db}" NOW=""
MIN_AGE=24 WINDOW=6 NOTE_DIR="" SUMMARY=0 RETIRED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ps) PS_FILE=${2:-}; shift 2 ;;
    --proc-root) PROC_ROOT=${2:-}; shift 2 ;;
    --db) DB=${2:-}; shift 2 ;;
    --now) NOW=${2:-}; shift 2 ;;
    --min-age-hours) MIN_AGE=${2:-}; shift 2 ;;
    --window-hours) WINDOW=${2:-}; shift 2 ;;
    --retired) RETIRED=${2:-}; shift 2 ;;
    --note-dir) NOTE_DIR=${2:-}; shift 2 ;;
    --summary) SUMMARY=1; shift ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;;
    *) printf 'fm-session-weight: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ "$MIN_AGE" =~ ^[0-9]+$ && "$WINDOW" =~ ^[0-9]+$ ]] || { printf 'fm-session-weight: hours must be whole numbers\n' >&2; exit 2; }
[ -n "$NOW" ] || NOW=$(date +%s)
if [ -z "$RETIRED" ]; then
  RETIRED=${FM_SESSION_WEIGHT_RETIRED:-}
  [ -n "$RETIRED" ] || RETIRED=$(grep -Ev '^[[:space:]]*(#|$)' "${FM_HOME:-/nonexistent}/config/session-weight-retired" 2>/dev/null | head -n 1)
  [ -n "$RETIRED" ] || RETIRED='claude-opus-4'
fi

if [ -n "$PS_FILE" ]; then table=$(cat "$PS_FILE" 2>/dev/null) || exit 0
else table=$(ps -eo pid=,etimes=,args= 2>/dev/null) || exit 0; fi

printf '%s\n' "$table" | python3 -I -c '
import os, re, sqlite3, sys, datetime
proc_root, db, now, min_age, window, retired, note_dir, summary = sys.argv[1:9]
now, min_age, window, summary = int(now), int(min_age), int(window), summary == "1"
retired_re = re.compile(retired)
rows = []
for line in sys.stdin:
    m = re.match(r"\s*(\d+)\s+(\d+)\s+(\S+)(.*)$", line.rstrip("\n"))
    if not m:
        continue
    pid, age, exe, rest = m.group(1), int(m.group(2)), m.group(3), m.group(4)
    if os.path.basename(exe) not in ("claude", "codex"):
        continue
    if os.path.basename(exe) == "codex" and re.match(r"(?:\s+(?:-c|--config)\s+\S+|\s+-\S+)*\s+app-server(?:\s|$)", rest):
        continue
    mm = re.search(r"(?:^|\s)--model(?:=|\s+)([A-Za-z0-9._:-]+)", rest)
    model = mm.group(1) if mm else "default"
    home = None
    for cand in re.findall(r"--add-dir\s+(\S+)", rest) + [None]:
        if cand is None:
            try:
                cand = os.readlink(os.path.join(proc_root, pid, "cwd"))
            except OSError:
                break
        fm = re.search(r"/fm-homes/([^/]+)", cand)
        if fm:
            home = "home=" + fm.group(1)
            break
        if home is None and cand.startswith("/") and "/state/" not in cand:
            home = "cwd=" + "/".join(cand.rstrip("/").split("/")[-2:])
    if home is None:
        home = "home=unknown"
    rows.append((pid, age, os.path.basename(exe), model, home))

ctx = {}
if os.path.exists(db):
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=5)
        for model in {r[3] for r in rows if r[3] != "default"}:
            vals = sorted(r[0] for r in con.execute(
                "select input+cache_read+cache_write from usage where failed=0 and model like ? and ts>?",
                (model + "%", now - window * 3600)))
            if vals:
                ctx[model] = (len(vals), vals[len(vals) // 2], vals[min(len(vals) - 1, int(len(vals) * 0.9))])
    except sqlite3.Error:
        pass

def k(v):
    return "%dK" % round(v / 1000)

out = []
for pid, age, exe, model, home in rows:
    old = age > min_age * 3600
    ret = model != "default" and bool(retired_re.search(model))
    if not (old or ret):
        continue
    why = ",".join(w for w, f in (("age>%dh" % min_age, old), ("retired-model", ret)) if f)
    c = ctx.get(model)
    cs = ("account recent %s requests (last %dh, n=%d): median %s, p90 %s" % (model, window, c[0], k(c[1]), k(c[2]))
          if c else "account recent context: no data for model %s" % model)
    out.append("session-weight: pid=%s %s %s age=%.1fh model=%s [%s]; %s; per-session context is inferred from account-level requests, not measured"
               % (pid, exe, home, age / 3600, model, why, cs))

if not out:
    sys.exit(0)
if not note_dir:
    print("\n".join(out))
    sys.exit(0)
day = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime("%Y-%m-%d")
path = os.path.join(note_dir, day + ".txt")
if os.path.exists(path):
    sys.exit(0)
os.makedirs(note_dir, exist_ok=True)
with open(path, "w") as f:
    f.write("\n".join(out) + "\n")
if summary:
    pids = ",".join(l.split("pid=")[1].split()[0] for l in out)
    print("session-weight %s [key=session-weight-%s]: %d session(s) older than %dh or on a retired model (pids %s); context is inferred from account-level requests, not measured; detail in %s; this check only reports and never stops a session"
          % (day, day, len(out), min_age, pids, path))
else:
    print("\n".join(out))
' "$PROC_ROOT" "$DB" "$NOW" "$MIN_AGE" "$WINDOW" "$RETIRED" "$NOTE_DIR" "$SUMMARY"
