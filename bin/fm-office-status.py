#!/usr/bin/env python3
"""fm-office-status.py - project an office home's backlog onto data/office-status.json.

Called by `fm-office.sh status`; docs/configuration.md "Office status
(data/office-status.json)" owns the schema and the lane rules. This file owns
the mechanics.

Reads <data>/backlog.md and <state>/<task>.meta in one office home and writes
only <data>/office-status.json, atomically (temp file in the same directory,
then rename). It prints nothing and exits 0 on success; a failure prints one
line to stderr and exits 1 without touching the projection.

Usage:
  fm-office-status.py --office <id> --data <dir> --state <dir>
                      [--now <epoch>] [--done-window-hours <n>]
                      [--refresh-secs <n>]
"""
import argparse
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone

SCHEMA_VERSION = 1
NEXT_LIMIT = 10
TITLE_LIMIT = 200

ROW_RE = re.compile(r"^- \[( |x)\] ([A-Za-z0-9._-]+) - (.*)$")
HEADING_RE = re.compile(r"^## (.+?)\s*$")
TAIL_RE = re.compile(
    r"\s*\((?:repo|kind|priority|hold|hold-kind|since|merged|done|blocked-by|blocked)\b[^()]*\)\s*$"
)
URL_TAIL_RE = re.compile(r"\s*https://\S+\s*$")
URL_RE = re.compile(r"https://[^\s)>\]]+")
DATE_RE = re.compile(r"\((since|merged|done) (\d{4}-\d{2}-\d{2})[^)]*\)")
HOLD_KIND_RE = re.compile(r"\(hold-kind: ([^)]*)\)")

LANES = {"in flight": "working", "queued": "next", "done": "done"}


def iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def date_midnight(text):
    return datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=timezone.utc)


def parse_backlog(path):
    """Return rows in file order: dicts with lane, id, head, body."""
    rows = []
    lane = None
    row = None
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except FileNotFoundError:
        return rows
    for line in lines:
        heading = HEADING_RE.match(line)
        if heading:
            lane = LANES.get(heading.group(1).strip().lower())
            row = None
            continue
        if lane is None:
            continue
        match = ROW_RE.match(line)
        if match:
            row = {"lane": lane, "id": match.group(2), "head": match.group(3), "body": []}
            rows.append(row)
        elif row is not None and line.startswith("  "):
            row["body"].append(line.strip())
        else:
            row = None
    return rows


def clean_title(head):
    title = head
    while True:
        stripped = URL_TAIL_RE.sub("", TAIL_RE.sub("", title))
        if stripped == title:
            break
        title = stripped
    title = title.strip()
    if len(title) > TITLE_LIMIT:
        title = title[: TITLE_LIMIT - 1].rstrip() + "…"
    return title


def first_url(row):
    for text in [row["head"]] + row["body"]:
        found = URL_RE.search(text)
        if found:
            return found.group(0)
    return ""


def meta_pr(state_dir, task_id):
    try:
        with open(os.path.join(state_dir, task_id + ".meta"), encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("pr=https://"):
                    return line[3:].strip()
    except OSError:
        pass
    return ""


def row_date(row):
    found = DATE_RE.search(row["head"])
    return (found.group(1), found.group(2)) if found else (None, None)


def load_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def previous_done_times(previous):
    times = {}
    if not previous:
        return times
    for card in previous.get("cards", []):
        if isinstance(card, dict) and card.get("state") == "done" and card.get("done_at"):
            times[card.get("id")] = card["done_at"]
    return times


def parse_iso(text):
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def build_cards(rows, state_dir, now, window, previous):
    working, queued, done = [], [], []
    seen_done = previous_done_times(previous)
    today = now.strftime("%Y-%m-%d")
    for row in rows:
        card = {"id": row["id"], "title": clean_title(row["head"])}
        if row["lane"] == "working":
            card["state"] = "working"
            card["link"] = meta_pr(state_dir, row["id"]) or first_url(row)
            kind, day = row_date(row)
            if kind == "since":
                card["since"] = iso(date_midnight(day))
            working.append(card)
        elif row["lane"] == "next":
            if len(queued) >= NEXT_LIMIT:
                continue
            card["state"] = "next"
            card["link"] = first_url(row)
            hold = HOLD_KIND_RE.search(row["head"])
            card["waiting"] = "Lee" if hold and hold.group(1).strip() == "captain" else ""
            queued.append(card)
        else:
            # The backlog records only a date for a finished item, so the first
            # sweep that sees it stamps the time and later sweeps carry it on.
            done_at = parse_iso(seen_done.get(row["id"]))
            if done_at is None:
                _, day = row_date(row)
                if day is None:
                    continue
                done_at = now if day == today else date_midnight(day)
            if now - done_at > window:
                continue
            card["state"] = "done"
            card["link"] = first_url(row)
            card["done_at"] = iso(done_at)
            done.append(card)
    done.sort(key=lambda card: card["done_at"], reverse=True)
    return working + queued + done


def comparable(document):
    return {key: value for key, value in document.items() if key != "written_at"}


def write_atomic(path, document):
    directory = os.path.dirname(path)
    handle, temp = tempfile.mkstemp(prefix=".office-status.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            json.dump(document, out, indent=2, ensure_ascii=False)
            out.write("\n")
        os.chmod(temp, 0o644)
        os.replace(temp, path)
    except BaseException:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--office", required=True)
    parser.add_argument("--data", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--now", type=int)
    parser.add_argument("--done-window-hours", type=float, default=24)
    parser.add_argument("--refresh-secs", type=int, default=900)
    args = parser.parse_args()

    now = datetime.fromtimestamp(args.now, timezone.utc) if args.now is not None else datetime.now(timezone.utc)
    now = now.replace(microsecond=0)
    out_path = os.path.join(args.data, "office-status.json")
    if not os.path.isdir(args.data):
        sys.stderr.write("office-status: data directory %s is missing\n" % args.data)
        return 1
    try:
        rows = parse_backlog(os.path.join(args.data, "backlog.md"))
    except (OSError, UnicodeDecodeError) as err:
        sys.stderr.write("office-status: cannot read backlog.md: %s\n" % err)
        return 1

    previous = load_json(out_path)
    document = {
        "schema_version": SCHEMA_VERSION,
        "office": args.office,
        "title": args.office[:1].upper() + args.office[1:],
        "written_at": iso(now),
        "cards": build_cards(rows, args.state, now, timedelta(hours=args.done_window_hours), previous),
    }
    if previous and comparable(previous) == comparable(document):
        written = parse_iso(previous.get("written_at"))
        if written is not None and timedelta(0) <= now - written < timedelta(seconds=args.refresh_secs):
            return 0
    try:
        write_atomic(out_path, document)
    except OSError as err:
        sys.stderr.write("office-status: cannot write %s: %s\n" % (out_path, err))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
