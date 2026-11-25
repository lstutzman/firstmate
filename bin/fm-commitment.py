#!/usr/bin/env python3
"""fm-commitment.py - the standing-commitments register: its format, spec grammar, recorder and evaluator.

Run through bin/fm-commitment.sh (the contract's owner). The page-check officer imports this file
(bin/fm-officer-page-check.py) to evaluate every row, so the recorder and the officer share one grammar.
"""

import argparse
import datetime
import fcntl
import glob
import json
import os
import re
import sys
import tempfile

REGISTER = os.path.join("data", "standing-commitments.json")
ID_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,63}")
HOME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
MARK_RE = re.compile(r"\[commitment=([A-Za-z0-9][A-Za-z0-9-]*)\]")
MAX_TEXT = 1000
MAX_READ = 8 * 1024 * 1024
MAX_LINE = 4000
AT_RE = re.compile(r"\[at=(\d{9,11})\]")
ISO_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.\d+)?(Z|[+-]\d\d:\d\d)?")
MAX_AGE_RE = re.compile(r"max-age=(\d+)h")
# regex=<re>[;max-count=<N>][;max-age=<N>h]: the regex is everything before the trailing options, so it may hold a `;`.
REGEX_OPTS_RE = re.compile(r"\Aregex=(?P<re>.+?)(?:;max-count=(?P<count>\d+))?(?:;max-age=(?P<age>\d+)h)?\Z", re.S)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def default_owner():
    home = os.environ.get("FM_HOME") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    return os.path.basename(os.path.realpath(home))


# ---- specs -------------------------------------------------------------------------------------------------------

def parse_enforcement(spec):
    """(parsed, None) or (None, why). memory and none parse, and are always red when evaluated."""
    if spec in ("memory", "none"):
        return {"kind": spec}, None
    if not spec.startswith("file:"):
        return None, "enforcement must be file:<absolute path>[#contains=<literal>], memory or none"
    path, sep, literal = spec[5:].partition("#contains=")
    if not os.path.isabs(path) or "\0" in path:
        return None, "enforcement file path must be absolute"
    if sep and not literal:
        return None, "enforcement #contains= needs a literal"
    return {"kind": "file", "path": path, "contains": literal if sep else None}, None


def _opt_age(text):
    m = MAX_AGE_RE.fullmatch(text)
    return int(m.group(1)) if m and int(m.group(1)) > 0 else None


def parse_verify(spec):
    """(parsed, None) or (None, why)."""
    if spec == "none":
        return {"kind": "none"}, None
    kind, _, rest = spec.partition(":")
    if kind == "file":
        path, _, opts = rest.partition(";")
        age = None
        if opts:
            age = _opt_age(opts)
            if age is None:
                return None, "verify file option must be max-age=<N>h with N of at least 1"
        if not os.path.isabs(path) or "\0" in path:
            return None, "verify file path must be absolute"
        return {"kind": "file", "path": path, "age": age}, None
    if kind in ("log", "status"):
        target, _, opts = rest.partition(";")
        m = REGEX_OPTS_RE.match(opts)
        if not m:
            return None, "verify %s needs ;regex=<re> then optional ;max-count=<N> and ;max-age=<N>h" % kind
        if m.group("age") is not None and int(m.group("age")) < 1:
            return None, "verify max-age must be at least 1 hour"
        if kind == "status" and m.group("count") is not None:
            return None, "verify status has no max-count"
        if re.search(r";max-(?:count|age)=", m.group("re")):
            return None, "verify %s has a malformed or misplaced option (use ;max-count=<N> then ;max-age=<N>h after the regex)" % kind
        try:
            pattern = re.compile(m.group("re"))
        except re.error as exc:
            return None, "verify regex does not compile: %s" % exc
        parsed = {"kind": kind, "regex": pattern, "count": None if m.group("count") is None else int(m.group("count")),
                  "age": None if m.group("age") is None else int(m.group("age"))}
        if kind == "log":
            if not os.path.isabs(target) or "\0" in target:
                return None, "verify log path must be absolute"
            parsed["path"] = target
        else:
            if not HOME_RE.fullmatch(target):
                return None, "verify status needs a home id"
            parsed["home"] = target
        return parsed, None
    return None, "verify must be file:..., log:..., status:... or none"


# ---- evaluation (read-only) --------------------------------------------------------------------------------------

def check_enforcement(parsed):
    """(ok, reason)."""
    kind = parsed["kind"]
    if kind == "memory":
        return False, "enforcement is a memory note only, which is not enforcement"
    if kind == "none":
        return False, "no enforcement point is named"
    path = parsed["path"]
    if not os.path.isfile(path):
        return False, "enforcement file %s does not exist" % path
    if parsed["contains"] is not None:
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                body = fh.read(MAX_READ)
        except OSError as exc:
            return False, "enforcement file %s is unreadable: %s" % (path, exc.strerror)
        if parsed["contains"] not in body:
            return False, "enforcement file %s lacks the required text, so the check is not wired in" % path
    return True, "enforcement point present"


def line_epoch(line):
    m = AT_RE.search(line)
    if m:
        return int(m.group(1))
    m = ISO_RE.match(line)
    if not m:
        return None
    try:
        dt = datetime.datetime.fromisoformat(m.group(1) + ("+00:00" if m.group(2) in (None, "Z") else m.group(2)))
    except ValueError:
        return None
    return int(dt.timestamp())


def read_lines(path):
    """Lines of the last MAX_READ bytes of a file, each cut to MAX_LINE; None when unreadable."""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - MAX_READ))
            data = fh.read()
    except OSError:
        return None
    return [l[:MAX_LINE] for l in data.decode("utf-8", "replace").splitlines()]


def _hours(seconds):
    return "%.1f" % (seconds / 3600.0)


def _matches(parsed, lines):
    return [l for l in lines if parsed["regex"].search(l)]


def _fresh_match(parsed, path, lines, now):
    """(ok, reason) for a regex needing one recent matching line. A match with a stamp is judged by its newest stamp;
    with no stamped match, the file's own age stands in."""
    hits = _matches(parsed, lines)
    if not hits:
        return False, "no line in %s matches /%s/" % (path, parsed["regex"].pattern)
    if parsed["age"] is None:
        return True, "%d matching line(s) in %s" % (len(hits), path)
    stamps = [t for t in (line_epoch(l) for l in hits) if t is not None]
    if stamps:
        age = now - max(stamps)
        what = "newest match"
    else:
        try:
            age = now - os.stat(path).st_mtime
        except OSError:
            return False, "%s vanished" % path
        what = "file (matches carry no stamp)"
    if age > parsed["age"] * 3600:
        return False, "%s in %s is %sh old; the limit is %dh" % (what, path, _hours(age), parsed["age"])
    return True, "%s in %s is %sh old" % (what, path, _hours(age))


def check_verify(parsed, now, homes):
    """(ok, reason). homes maps a home id to the directory holding its state/*.status logs."""
    kind = parsed["kind"]
    if kind == "none":
        return False, "no verification is named"
    if kind == "file":
        found = [p for p in glob.glob(parsed["path"]) if os.path.isfile(p)]
        if not found:
            return False, "no file matches %s" % parsed["path"]
        if parsed["age"] is None:
            return True, "%d file(s) match %s" % (len(found), parsed["path"])
        newest = max(os.stat(p).st_mtime for p in found)
        if now - newest > parsed["age"] * 3600:
            return False, "newest file matching %s is %sh old; the limit is %dh" % (parsed["path"], _hours(now - newest), parsed["age"])
        return True, "newest file matching %s is %sh old" % (parsed["path"], _hours(now - newest))
    if kind == "status":
        root = homes.get(parsed["home"])
        if root is None:
            return False, "home %s is not read by this officer" % parsed["home"]
        state = os.path.join(root, "state")
        try:
            names = sorted(n for n in os.listdir(state) if n.endswith(".status") and not n.startswith("."))
        except OSError:
            return False, "home %s has no readable state directory" % parsed["home"]
        lines = []
        for name in names:
            lines += read_lines(os.path.join(state, name)) or []
        return _fresh_match(parsed, "home %s status logs" % parsed["home"], lines, now)
    paths = sorted(p for p in glob.glob(parsed["path"]) if os.path.isfile(p))
    if parsed["count"] is not None:
        if parsed["age"] is not None:
            paths = [p for p in paths if now - os.stat(p).st_mtime <= parsed["age"] * 3600]
        if not paths:
            return False, "no log matches %s%s" % (parsed["path"], " within %dh" % parsed["age"] if parsed["age"] else "")
        for p in paths:
            lines = read_lines(p)
            if lines is None:
                return False, "log %s is unreadable" % p
            n = len(_matches(parsed, lines))
            if n > parsed["count"]:
                return False, "%s has %d line(s) matching /%s/; the limit is %d" % (p, n, parsed["regex"].pattern, parsed["count"])
        return True, "%d log(s) matching %s, none over %d matching line(s)" % (len(paths), parsed["path"], parsed["count"])
    if not paths:
        return False, "no log matches %s" % parsed["path"]
    reasons = []
    for p in paths:
        lines = read_lines(p)
        if lines is None:
            reasons.append("log %s is unreadable" % p)
            continue
        ok, why = _fresh_match(parsed, p, lines, now)
        if ok:
            return True, why
        reasons.append(why)
    return False, reasons[0] if len(reasons) == 1 else "%d logs match %s and none proves it (%s)" % (len(reasons), parsed["path"], reasons[0])


def evaluate(row, now, homes):
    """(green, reasons): reasons names each failed part, enforcement first, or the passing proof when green."""
    enforcement, why = parse_enforcement(str(row.get("enforcement")))
    verify, vwhy = parse_verify(str(row.get("verify")))
    bad = []
    e_ok, e_why = (False, "enforcement spec is malformed: %s" % why) if enforcement is None else check_enforcement(enforcement)
    v_ok, v_why = (False, "verify spec is malformed: %s" % vwhy) if verify is None else check_verify(verify, now, homes)
    if not e_ok:
        bad.append("enforcement: " + e_why)
    if not v_ok:
        bad.append("verification: " + v_why)
    return (not bad), bad or ["enforcement: %s; verification: %s" % (e_why, v_why)]


# ---- unrecorded commitments --------------------------------------------------------------------------------------

QUOTED_RE = re.compile(r'"[^"]*"|`[^`]*`|\u201c[^\u201d]*\u201d')
PHRASES = (
    ("from now on", re.compile(r"\bfrom now on\b", re.I)),
    # A clause that opens with it, or a first-person promise before it; "fails every time" describes a result.
    ("every time", re.compile(r"(?:(?:\A|[.;:!?,]\s+|\b(?:and|so|then)\s+)every time\b)|"
                              r"(?:\b(?:I'll|we'll|I will|we will|I shall|we shall|I must|we must|I now|we now)\b[^.;]{0,50}\bevery time\b)", re.I)),
    # A new commitment named as one; "outstanding", the Linear Standing label and a rule id such as standing-rule do not match.
    ("standing", re.compile(r"\b(?:new|my|our|a|this|as)\s+standing\s+(?:rule|order|commitment|practice|policy|instruction|check)\b", re.I)),
)


def commitment_phrase(text):
    """The commitment phrase a status text makes about its own behaviour, or None. Quoted spans are other people's words."""
    plain = QUOTED_RE.sub(" ", text or "")
    for name, pattern in PHRASES:
        if pattern.search(plain):
            return name
    return None


# ---- register ----------------------------------------------------------------------------------------------------

def register_path(root):
    return os.path.join(root, REGISTER)


def load_register(root):
    """(rows, notes): a missing register is an empty one; an unreadable one is (None, [why])."""
    path = register_path(root)
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        return [], []
    except (OSError, ValueError) as exc:
        return None, ["register %s is unreadable: %s" % (path, exc)]
    rows = doc.get("rows") if isinstance(doc, dict) else None
    if not isinstance(rows, list):
        return None, ["register %s has no rows list" % path]
    good = [r for r in rows if isinstance(r, dict) and isinstance(r.get("id"), str)]
    notes = ["register %s has %d malformed row(s), skipped" % (path, len(rows) - len(good))] if len(good) != len(rows) else []
    return good, notes


def is_retired(row):
    return bool(row.get("retired"))


def _mutate(root, change):
    path = register_path(root)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(os.path.join(os.path.dirname(path), ".standing-commitments.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rows, notes = load_register(root)
        if rows is None:
            raise Unreadable(notes[0])
        change(rows)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".standing-commitments.")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump({"version": 1, "rows": rows}, fh, indent=1, sort_keys=True, ensure_ascii=False)
                fh.write("\n")
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise


class Refused(Exception):
    """A refusal the caller can fix: exit 2."""


class Unreadable(Exception):
    """The register cannot be read: exit 1."""


def refuse(message):
    sys.stderr.write("fm-commitment.sh: %s\n" % message)
    return 2


def text_arg(name, value):
    value = (value or "").strip()
    if not value or "\n" in value or "\r" in value:
        return None, "%s must be one non-empty line" % name
    if len(value) > MAX_TEXT:
        return None, "%s is %d characters; the limit is %d" % (name, len(value), MAX_TEXT)
    return value, None


def cmd_add(args, root):
    if not ID_RE.fullmatch(args.id or ""):
        return refuse("--id must be a slug of lowercase letters, digits and dashes (at most 64)")
    fields = {}
    for name, value in (("--commitment", args.commitment), ("--lee-words", args.lee_words)):
        fields[name], why = text_arg(name, value)
        if why:
            return refuse(why)
    owner = args.owner or default_owner()
    if not HOME_RE.fullmatch(owner):
        return refuse("--owner must be a home id")
    enforcement, why = parse_enforcement(args.enforcement or "")
    if enforcement is None:
        return refuse(why)
    if enforcement["kind"] == "file":
        ok, why = check_enforcement(enforcement)
        if not ok:
            return refuse(why + "; name an enforcement point that exists, or use none")
    verify, why = parse_verify(args.verify or "")
    if verify is None:
        return refuse(why)
    row = {"id": args.id, "commitment": fields["--commitment"], "lee_words": fields["--lee-words"], "owner": owner,
           "enforcement": args.enforcement, "verify": args.verify, "recorded_at": now_iso(), "retired": None}

    def change(rows):
        if any(r.get("id") == args.id for r in rows):
            raise Refused("a row with id %s exists already (rows are never deleted; retire it and record a new id)" % args.id)
        rows.append(row)

    _mutate(root, change)
    print("recorded %s (owner %s)" % (args.id, owner))
    return 0


def cmd_retire(args, root):
    reason, why = text_arg("--reason", args.reason)
    if why:
        return refuse(why)

    def change(rows):
        for r in rows:
            if r.get("id") == args.id:
                if is_retired(r):
                    raise Refused("%s is retired already" % args.id)
                r["retired"] = {"at": now_iso(), "reason": reason}
                return
        raise Refused("no row with id %s" % args.id)

    _mutate(root, change)
    print("retired %s" % args.id)
    return 0


def cmd_list(args, root):
    rows, notes = load_register(root)
    if rows is None:
        raise Unreadable(notes[0])
    shown = [r for r in rows if args.all or not is_retired(r)]
    if args.json:
        print(json.dumps(shown, indent=1, sort_keys=True, ensure_ascii=False))
        return 0
    for r in shown:
        print("%s\t%s\t%s\tenforcement=%s\tverify=%s\t%s" % (
            r["id"], r.get("owner", "?"), "retired" if is_retired(r) else "active", r.get("enforcement"), r.get("verify"),
            r.get("commitment", "")))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-commitment.sh")
    sub = parser.add_subparsers(dest="action", required=True)
    add = sub.add_parser("add")
    for flag in ("--id", "--commitment", "--lee-words", "--owner", "--enforcement", "--verify"):
        add.add_argument(flag)
    retire = sub.add_parser("retire")
    retire.add_argument("--id", required=True)
    retire.add_argument("--reason", required=True)
    lst = sub.add_parser("list")
    lst.add_argument("--all", action="store_true")
    lst.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.action == "add":
        missing = [f for f in ("id", "commitment", "lee_words", "enforcement", "verify") if getattr(args, f) is None]
        if missing:
            return refuse("add needs " + ", ".join("--" + m.replace("_", "-") for m in missing))
    root = os.environ.get("FM_HOME") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    try:
        return {"add": cmd_add, "retire": cmd_retire, "list": cmd_list}[args.action](args, os.path.abspath(root))
    except Refused as exc:
        return refuse(str(exc))
    except Unreadable as exc:
        sys.stderr.write("fm-commitment.sh: %s\n" % exc)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
