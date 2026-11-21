#!/usr/bin/env python3
"""fm-backlog-reconcile.py - report `## Queued` backlog rows that reality has already closed.

Usage: fm-backlog-reconcile.py [--home <home>] [--max-linear N] [--max-prs N] [--json]

Nothing else reconciles queued rows: fm-secondmate-reconcile.sh checks only `## In flight` rows against task
metadata, and a deferred spawn, a cross-home handoff or a re-sent start request leaves a queued row behind
that no one ever closes. This sweep is read-only. It never edits, moves or deletes a row; it writes its
findings to <home>/state/backlog-reconcile.json (atomically) and prints one line per finding, so an officer
or the owner of the home decides what to close. Exit 0 whether or not it found anything; 1 when the
backlog cannot be read; 2 on a usage error.

A queued row is a finding when:
  linear-closed   a Linear identifier in the row (`ABC-123`) is Done, Released, Canceled or a Duplicate
                  (`linear-axi issue view`), so the work is finished or abandoned;
  pr-closed       a pull request URL in the row is merged or closed (`gh pr view`);
  duplicate       the row's id is already an In flight or Done row in this backlog or in another registered
                  local home (data/secondmates.md). A remote home (host: ...) is not read; the count of
                  homes skipped is printed, so a duplicate held only there is named as unchecked.

A held row (`(hold` marker) is skipped, because it waits on something by design. Linear and GitHub reads are
bounded by --max-linear (default 25) and --max-prs (default 25) per run, oldest rows first, and the rows left
unchecked are counted in the output; a lookup that fails is reported as unchecked, never as a finding.
FM_HOME selects the home when --home is not given.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time

ROW = re.compile(r"^- \[( |x)\] ([A-Za-z0-9._-]+) - (.*)$")
HEADING = re.compile(r"^## (.+?)\s*$")
HELD = re.compile(r"\(hold(?:-kind)?:")
SINCE = re.compile(r"\(since (\d{4}-\d{2}-\d{2})")
LINEAR_ID = re.compile(r"\b[A-Z][A-Z0-9]{1,9}-\d{1,6}\b")
PR_URL = re.compile(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+")
LINEAR_CLOSED = {"done", "released", "canceled", "cancelled", "duplicate"}
LANES = {"in flight": "in_flight", "queued": "queued", "done": "done"}


def parse(path):
    """{lane: [row]}; a row is {id, head, body}. A missing file is an empty backlog."""
    lanes = {"in_flight": [], "queued": [], "done": []}
    lane = row = None
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        return lanes
    for line in text.splitlines():
        heading = HEADING.match(line)
        if heading:
            lane, row = LANES.get(heading.group(1).strip().lower()), None
            continue
        match = ROW.match(line)
        if lane and match:
            row = {"id": match.group(2), "head": match.group(3), "body": ""}
            lanes[lane].append(row)
        elif row is not None and line.startswith("  "):
            row["body"] += line.strip() + "\n"
        else:
            row = None
    return lanes


def other_homes(home):
    """(local home paths, number of remote homes skipped) from data/secondmates.md."""
    local, remote = [], 0
    try:
        with open(os.path.join(home, "data", "secondmates.md"), encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return local, remote
    for line in lines:
        if not line.startswith("- "):
            continue
        if re.search(r"\(host:", line):
            remote += 1
            continue
        found = re.search(r"home:\s*([^;)]+)", line)
        if found and os.path.isdir(found.group(1).strip()):
            local.append(os.path.realpath(found.group(1).strip()))
    return local, remote


def run_json(argv, env=None):
    proc = subprocess.run(argv, capture_output=True, timeout=60, check=False, stdin=subprocess.DEVNULL, env=env)
    if proc.returncode:
        raise RuntimeError("exit %d" % proc.returncode)
    return json.loads(proc.stdout.decode("utf-8"))


def linear_state(identifier):
    doc = run_json(["linear-axi", "issue", "view", identifier, "--output", "json"],
                   dict(os.environ, LINEAR_JOB=os.environ.get("LINEAR_JOB") or "reconcile:backlog"))
    if not doc.get("ok"):
        raise RuntimeError("not ok")
    issue = (doc.get("data") or {}).get("issue") or {}
    state = issue.get("state")
    if isinstance(state, dict):
        state = state.get("name")
    return str(state or "")


def pr_state(url):
    return str(run_json(["gh", "pr", "view", url, "--json", "state"]).get("state") or "")


def oldest_first(rows):
    def filed(row):
        found = SINCE.search(row["head"])
        return found.group(1) if found else "9999-12-31"
    return sorted(rows, key=filed)


def reconcile(home, max_linear, max_prs):
    lanes = parse(os.path.join(home, "data", "backlog.md"))
    findings, unchecked = [], {"linear": 0, "pr": 0}
    siblings, remote_skipped = other_homes(home)
    taken = {}
    for lane in ("in_flight", "done"):
        for row in lanes[lane]:
            taken.setdefault(row["id"], "this home (%s)" % lane.replace("_", " "))
    for path in siblings:
        if path == os.path.realpath(home):
            continue
        other = parse(os.path.join(path, "data", "backlog.md"))
        for lane in ("in_flight", "done"):
            for row in other[lane]:
                taken.setdefault(row["id"], "%s (%s)" % (path, lane.replace("_", " ")))
    linear_left, pr_left = max_linear, max_prs
    seen_linear, seen_pr = {}, {}
    for row in oldest_first([r for r in lanes["queued"] if not HELD.search(r["head"])]):
        text = row["head"] + "\n" + row["body"]
        if row["id"] in taken:
            findings.append({"id": row["id"], "kind": "duplicate", "detail": "already a row in " + taken[row["id"]]})
        for url in dict.fromkeys(PR_URL.findall(text)):
            if url not in seen_pr:
                if pr_left <= 0:
                    unchecked["pr"] += 1
                    continue
                pr_left -= 1
                try:
                    seen_pr[url] = pr_state(url)
                except (RuntimeError, ValueError, OSError, subprocess.SubprocessError):
                    seen_pr[url] = None
                    unchecked["pr"] += 1
            if seen_pr.get(url) in ("MERGED", "CLOSED"):
                findings.append({"id": row["id"], "kind": "pr-closed", "detail": "%s is %s" % (url, seen_pr[url].lower())})
        for identifier in dict.fromkeys(LINEAR_ID.findall(text)):
            if identifier not in seen_linear:
                if linear_left <= 0:
                    unchecked["linear"] += 1
                    continue
                linear_left -= 1
                try:
                    seen_linear[identifier] = linear_state(identifier)
                except (RuntimeError, ValueError, OSError, subprocess.SubprocessError):
                    seen_linear[identifier] = None
                    unchecked["linear"] += 1
            if (seen_linear.get(identifier) or "").lower() in LINEAR_CLOSED:
                findings.append({"id": row["id"], "kind": "linear-closed", "detail": "%s is %s" % (identifier, seen_linear[identifier])})
    return {"schema": "fm-backlog-reconcile.v1", "home": os.path.realpath(home), "generated_epoch": int(time.time()),
            "queued": len(lanes["queued"]), "findings": findings, "unchecked": unchecked,
            "remote_homes_skipped": remote_skipped}


def write_atomic(path, document):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    handle, temp = tempfile.mkstemp(prefix=".backlog-reconcile.", suffix=".tmp", dir=os.path.dirname(path))
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            json.dump(document, out, indent=2, sort_keys=True)
            out.write("\n")
        os.chmod(temp, 0o644)
        os.replace(temp, path)
    except BaseException:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--home", default=os.environ.get("FM_HOME") or os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    parser.add_argument("--max-linear", type=int, default=25)
    parser.add_argument("--max-prs", type=int, default=25)
    parser.add_argument("--json", action="store_true", help="print the report document instead of lines")
    args = parser.parse_args(argv)
    if not os.path.isfile(os.path.join(args.home, "data", "backlog.md")):
        sys.stderr.write("fm-backlog-reconcile: %s has no data/backlog.md\n" % args.home)
        return 1
    try:
        report = reconcile(args.home, args.max_linear, args.max_prs)
    except (OSError, UnicodeDecodeError) as error:
        sys.stderr.write("fm-backlog-reconcile: cannot read the backlog: %s\n" % error)
        return 1
    try:
        write_atomic(os.path.join(args.home, "state", "backlog-reconcile.json"), report)
    except OSError as error:
        sys.stderr.write("fm-backlog-reconcile: cannot write the report: %s\n" % error)
        return 1
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0
    for finding in report["findings"]:
        print("%s: %s: %s" % (finding["kind"], finding["id"], finding["detail"]))
    notes = []
    if report["unchecked"]["linear"] or report["unchecked"]["pr"]:
        notes.append("%d Linear and %d PR lookups unchecked" % (report["unchecked"]["linear"], report["unchecked"]["pr"]))
    if report["remote_homes_skipped"]:
        notes.append("%d remote homes not read for duplicates" % report["remote_homes_skipped"])
    print("backlog-reconcile: %d queued, %d finding(s)%s; nothing changed" % (
        report["queued"], len(report["findings"]), "; " + "; ".join(notes) if notes else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
