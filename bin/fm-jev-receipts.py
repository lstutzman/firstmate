#!/usr/bin/env python3
"""fm-jev-receipts.py - append local-jev decision receipts to this machine's append-only stream.

docs/local-jev-receipts.md owns the local-jev-receipt.v1 schema and what each caller records; this header owns
the writer's mechanics.

Usage:
  fm-jev-receipts.py append <call|decision|outcome>
      Reads one JSON object of record fields on stdin, adds the shared fields, appends the record, and prints its
      receipt_id on stdout (nothing when the record was not written).
  fm-jev-receipts.py new-id      prints a fresh receipt id
  fm-jev-receipts.py path        prints the file this month's records go to

Library (python callers load this file by path, as bin/fm-officer-linear.py does):
  append(kind, fields) -> receipt_id, or None when not written
  new_id() -> a fresh receipt id
  canonical_hash(request) -> the sha256 hex of the request as compact, key-sorted UTF-8 JSON
  stream_path(now=None) -> the stream file for that UTC month

Shared fields: the writer sets schema, kind, ts (UTC ISO 8601 with milliseconds), host (the short host name) and
  home (fields' home, else FM_HOME, else null). receipt_id is kept when the fields carry one (a decision or outcome
  naming its call) and minted otherwise. A call that carries request and no input_hash gets input_hash, the sha256
  of the canonical request (canonical_hash).

Stream: FM_JEV_RECEIPTS_DIR, else ${XDG_STATE_HOME:-$HOME/.local/state}/local-jev/receipts, holding one file per UTC
  month, YYYY-MM.jsonl, shared by every home on the machine. The directory is created 0700 and each file 0600,
  because records carry brief and issue text. Each record is one line, written by a single os.write on an O_APPEND
  descriptor under an exclusive flock, so concurrent writers never interleave and earlier lines are never
  rewritten.

Failure: a record that cannot be written prints one "local-jev receipt: not written (<why>)" line on stderr and
  append() returns None; the CLI still exits 0, so a receipt failure never changes a caller's result or exit code.
  Exit 2 only for a usage error.
"""
import datetime
import hashlib
import json
import os
import socket
import sys
import uuid

try:
    import fcntl
except ImportError:  # no flock here; the single O_APPEND write still keeps each line whole
    fcntl = None

SCHEMA = "local-jev-receipt.v1"
KINDS = ("call", "decision", "outcome")
SOURCES = ("model", "timeout", "abstain", "rule", "heuristic")


def warn(why):
    try:
        sys.stderr.write("local-jev receipt: not written (%s)\n" % why)
    except (OSError, ValueError):
        pass


def canonical_hash(request):
    text = json.dumps(request, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def new_id():
    return "jr-" + uuid.uuid4().hex


def stream_dir():
    explicit = os.environ.get("FM_JEV_RECEIPTS_DIR")
    if explicit:
        return explicit
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(state, "local-jev", "receipts")


def stream_path(now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    return os.path.join(stream_dir(), now.strftime("%Y-%m") + ".jsonl")


def short_host():
    return (socket.gethostname() or "").split(".")[0].lower() or None


def _write_line(path, data):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        if fcntl:
            fcntl.flock(fd, fcntl.LOCK_EX)
        while data:
            data = data[os.write(fd, data):]
    finally:
        os.close(fd)


def append(kind, fields):
    """Appends one record; returns its receipt_id, or None (with one stderr warning) when it was not written."""
    try:
        if kind not in KINDS:
            warn("unknown kind %r" % (kind,))
            return None
        if not isinstance(fields, dict):
            warn("fields are not a JSON object")
            return None
        source = fields.get("source")
        if kind == "decision" and not (source in SOURCES or (isinstance(source, str) and source.startswith("fallback:"))):
            warn("decision source must be one of %s or fallback:<name>" % ", ".join(SOURCES))
            return None
        now = datetime.datetime.now(datetime.timezone.utc)
        record = {
            "schema": SCHEMA,
            "kind": kind,
            "receipt_id": fields.get("receipt_id") or new_id(),
            "ts": now.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (now.microsecond // 1000),
            "host": short_host(),
            "home": fields.get("home") or os.environ.get("FM_HOME") or None,
        }
        for key, value in fields.items():
            if key not in record:
                record[key] = value
        if kind == "call" and "request" in record and not record.get("input_hash"):
            record["input_hash"] = canonical_hash(record["request"])
        line = json.dumps(record, ensure_ascii=False, separators=(",", ":"), default=str) + "\n"
        _write_line(stream_path(now), line.encode("utf-8"))
        return record["receipt_id"]
    except Exception as exc:  # a receipt must never break its caller
        warn("%s: %s" % (type(exc).__name__, exc))
        return None


def main(argv):
    if len(argv) == 2 and argv[1] == "new-id":
        print(new_id())
        return 0
    if len(argv) == 2 and argv[1] == "path":
        print(stream_path())
        return 0
    if len(argv) == 3 and argv[1] == "append":
        try:
            fields = json.loads(sys.stdin.read())
        except (ValueError, OSError, UnicodeDecodeError) as exc:
            warn("stdin is not JSON: %s" % exc)
            return 0
        receipt_id = append(argv[2], fields)
        if receipt_id:
            print(receipt_id)
        return 0
    sys.stderr.write("usage: fm-jev-receipts.py append <call|decision|outcome> | new-id | path\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
