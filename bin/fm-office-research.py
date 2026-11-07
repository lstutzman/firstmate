#!/usr/bin/env python3
"""Body of the office `research` source (bin/fm-office.sh check research).

Delivers the oldest tooling-research run directory this office has not yet been
told about: appends the run's "Lines for knowledge.md" to the office's knowledge
file, writes a digest the office can act on, and prints one wake line.
Starts and files nothing. Silent when there is nothing new or the run is not
complete (report.md, suggestions.json and result.json must all exist).

A run is delivered once: its directory name goes into <record>/research.seen only
after the knowledge lines are appended, and a knowledge line already in the file
(whole-line match) is never appended again, so a crash between the two steps
cannot duplicate it. Once per ISO week the digest also lists the research and
scout reports found under data/*/report.md of every --home, with whether another
backlog line or a commit in --code-root names each (adopted) or not.

usage: fm-office-research.py --office ID --runs DIR --knowledge FILE --record DIR
       --code-root DIR [--home DIR]... [--now EPOCH]
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys

SECTIONS = {"articles read": "## Articles read", "bookmarks": "## Bookmark", "findings": "## Findings"}


def read(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return None


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp, path)


def knowledge_lines(report):
    """The run's 'Lines for knowledge.md' as [(section heading or None, bullet line)]."""
    match = re.search(r"^## Lines for knowledge\.md\s*$(.*?)(?=^## |\Z)", report, re.M | re.S)
    out, heading = [], None
    for line in (match.group(1).splitlines() if match else []):
        if line.startswith("- "):
            out.append((heading, line.rstrip()))
        elif line.strip():
            label = re.split(r"[:(]", line.strip().lower())[0].strip()
            heading = SECTIONS.get(label)
    return out


def append_lines(path, lines):
    """Insert each bullet at the end of its section; a line already in the file is skipped. Returns (added, unplaced)."""
    text = read(path)
    if text is None:
        return 0, [line for _, line in lines]
    rows = text.split("\n")
    present = set(rows)
    added, unplaced = 0, []
    for heading, line in lines:
        if line in present:
            continue
        start = next((i for i, r in enumerate(rows) if heading and r.strip() == heading), None)
        if start is None:
            unplaced.append(line)
            continue
        end = next((i for i in range(start + 1, len(rows)) if rows[i].startswith("## ")), len(rows))
        while end > start + 1 and not rows[end - 1].strip():
            end -= 1
        rows.insert(end, line)
        present.add(line)
        added += 1
    if added:
        write_atomic(path, "\n".join(rows))
    return added, unplaced


def proposals(path):
    """(list of proposals, problem). Anything but a JSON list of objects with id and a title or tldr is a problem."""
    raw = read(path)
    try:
        data = json.loads(raw or "")
    except (TypeError, ValueError) as err:
        return [], "not valid JSON (%s)" % err
    if not isinstance(data, list) or not all(isinstance(p, dict) and p.get("id") and (p.get("title") or p.get("tldr")) for p in data):
        return [], "not a list of proposals with an id and a title"
    return data, None


def own_item(line, task):
    return re.match(r"^- \[.\] %s( |$)" % re.escape(task), line) is not None


def follow_through(homes, code_root):
    """Markdown section: each report's recommendation and whether anything else names it."""
    backlog = []
    for home in homes:
        backlog += (read(os.path.join(home, "data", "backlog.md")) or "").splitlines()
    rows, adopted, skipped = [], 0, 0
    for home in homes:
        data = os.path.join(home, "data")
        for task in sorted(os.listdir(data)) if os.path.isdir(data) else []:
            text = read(os.path.join(data, task, "report.md"))
            if text is None:
                continue
            rec = re.search(r"^#{2,3} [^\n]*recommend[^\n]*\n+((?:[^\n#][^\n]*\n?){1,3})", text, re.M | re.I)
            if not rec:
                skipped += 1
                continue
            names = {task, *re.findall(r"\bPC-\d+\b", text)}
            hit = any(re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(n), line) and not own_item(line, task)
                      for n in names for line in backlog)
            if not hit:
                log = subprocess.run(["git", "-C", code_root, "log", "--all", "-E", "-n", "1", "--format=%h"]
                                     + ["--grep=(^|[^[:alnum:]_-])" + re.escape(n) + "($|[^[:alnum:]_-])" for n in names], capture_output=True, text=True)
                hit = bool(log.stdout.strip())
            adopted += hit
            if not hit:
                rows.append("- %s (%s): %s" % (task, os.path.basename(home), " ".join(rec.group(1).split())[:240]))
    head = "## Research follow-through\n\nAdopted (a backlog line or commit names the report or a PC id in it): %d. No recommendation heading: %d.\nNot adopted: %d (evidence, not proof; the office decides).\n" % (adopted, skipped, len(rows))
    return head + ("\n" + "\n".join(rows) + "\n" if rows else "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--office", required=True)
    ap.add_argument("--runs", required=True)
    ap.add_argument("--knowledge", required=True)
    ap.add_argument("--record", required=True)
    ap.add_argument("--code-root", required=True)
    ap.add_argument("--home", action="append", default=[])
    ap.add_argument("--now", type=int, default=None)
    args = ap.parse_args()

    seen_path = os.path.join(args.record, "research.seen")
    seen = set((read(seen_path) or "").split())
    try:
        runs = sorted(r for r in os.listdir(args.runs) if re.fullmatch(r"\d{4}-\d{2}-\d{2}", r))
    except OSError:
        return 0
    run = next((r for r in runs if r not in seen
                and all(os.path.isfile(os.path.join(args.runs, r, f)) for f in ("report.md", "suggestions.json", "result.json"))), None)
    if run is None:
        return 0
    folder = os.path.join(args.runs, run)
    added, unplaced = append_lines(args.knowledge, knowledge_lines(read(os.path.join(folder, "report.md")) or ""))
    items, problem = proposals(os.path.join(folder, "suggestions.json"))

    when = datetime.datetime.fromtimestamp(args.now if args.now is not None else datetime.datetime.now().timestamp(), datetime.timezone.utc)
    week = "%d-W%02d" % when.isocalendar()[:2]
    week_path = os.path.join(args.record, "research.week")
    doc = ["# Tooling research %s\n\nRun: %s\nKnowledge lines appended: %d to %s\n" % (run, folder, added, args.knowledge)]
    if unplaced:
        doc.append("Not appended (no matching section in the knowledge file; place by hand): %d\n" % len(unplaced))
    doc.append("## Proposals\n")
    if problem:
        doc.append("suggestions.json is unreadable: %s. Read %s yourself; nothing was guessed.\n" % (problem, os.path.join(folder, "suggestions.json")))
    for p in items:
        doc.append("- %s (rank %s, effort %s): %s\n  %s\n" % (p["id"], p.get("rank", "?"), p.get("effort", "?"), p.get("title", ""), " ".join(str(p.get("tldr", "")).split())))
    if (read(week_path) or "").strip() != week:
        doc.append("\n" + follow_through(args.home, args.code_root))
        write_atomic(week_path, week + "\n")
    digest = os.path.join(args.record, "research", run + ".md")
    write_atomic(digest, "\n".join(doc))
    write_atomic(seen_path, "\n".join(sorted(seen | {run})) + "\n")
    print("office %s: research %s: %s, %d knowledge line(s) appended; digest %s" % (
        args.office, run, "suggestions.json unreadable" if problem else "%d proposal(s)" % len(items), added, digest))
    return 0


if __name__ == "__main__":
    sys.exit(main())
