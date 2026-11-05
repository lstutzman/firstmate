#!/usr/bin/env python3
"""fm-officer-library.py - the library officer's daily judgement of the weekly librarian audit.

Run only through `bin/fm-officer.sh run <id>`, which owns the officer
contract; docs/configuration.md "Library officer" owns the registry fields.

Usage:
  fm-officer-library.py run --audit <runs-dir> --date <YYYY-MM-DD> --out <lane-dir> [--now <epoch>]

The fleet-app librarian-audit job collects (deploy/README.md section 21 in
fleet-app); this officer only judges. It reads the newest
<runs-dir>/<YYYY-MM-DD>/ folder (a moved-aside folder such as
`2026-10-31.stale-<id>` is skipped): result.json for its outcome and counts,
and findings.json, the audit's list of findings (kind, severity, title, path,
evidence, disposition). It never reads the report or any audited file, and
never edits the audit job or its inbox note.

Each finding goes to one bucket, from its kind, path and proposed disposition
alone, in this order:
  code       kind unneeded-code, or a disposition that needs an implementation,
             upgrade or own brief or scope: code work, not a docs PR;
  needs-lee  kind conflict (the librarian never rewrites requirements to settle
             one), an instruction or hook file (AGENTS.md, CLAUDE.md, SKILL.md,
             .claude/, .agents/, .codex/), or a disposition naming Lee, an
             owner, an approval or a decision;
  hold       a disposition that starts unresolved, keep, leave, report only or
             no action;
  needs-lee  a disposition naming a delete, removal, retirement or archive
             (fleet rules section 6);
  safe       kind readme, stack-drift or misplaced with a disposition that
             proposes, records, adds, corrects, moves, links or regenerates: one
             docs PR per repository can ship it;
  hold       everything else: unresolved, keep, report only, or a check still
             to make.
The run's `counts.decisions`, Lee's calls in the report, is one needs-lee
item naming the report beside the run's result.

A finding is reported once (fm-officer-corpus.py's reported.json rule): its
fingerprint hashes kind, path and title. The digest line counts new code,
needs-lee and safe items; hold items are listed and never counted. A missing
run, result or findings file is a coverage gap, a failed or partial outcome or
a run older than AUDIT_DAYS days is a coverage note, and none of them fails the
run. Re-running a key on unchanged inputs writes identical bytes.

Outputs <date>.json and <date>.md in --out, prints one `Coverage gap:` line
per gap and `DIGEST <date> <n-new> <date>.md` last.
"""

import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import re
import sys
import time

AUDIT_DAYS = 8
RUN_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
INSTRUCTION_RE = re.compile(r"(^|/)(AGENTS\.md|CLAUDE\.md|SKILL\.md)$|(^|/)\.(claude|agents|codex)/")
CODE_RE = re.compile(r"\b(implementation|upgrade|own) (brief|scope)\b|\bits own brief\b", re.I)
LEE_RE = re.compile(r"\b(lee|owner|approv\w*|decides?|decision)\b", re.I)
HOLD_RE = re.compile(r"^\s*(unresolved|keep|leave|report only|no action)\b", re.I)
DESTRUCTIVE_RE = re.compile(r"\b(delet|remov|retir|archiv|trash)\w*", re.I)
SAFE_RE = re.compile(r"\b(propose|record|add|correct|move|link|point|regenerate|make sure)\w*", re.I)
SAFE_KINDS = ("readme", "stack-drift", "misplaced")
COUNTED = ("code", "needs-lee", "safe")


def _corpus():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-officer-corpus.py")
    spec = importlib.util.spec_from_file_location("fm_officer_corpus", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


corpus = _corpus()


def bucket(f):
    kind, path, disposition = f["kind"], f["path"], f["disposition"]
    if kind == "unneeded-code" or CODE_RE.search(disposition):
        return "code", "code work, not a docs change"
    if kind == "conflict":
        return "needs-lee", "a conflict is never settled by rewriting requirements"
    if INSTRUCTION_RE.search(path):
        return "needs-lee", "an instruction or hook file"
    m = LEE_RE.search(disposition)
    if m:
        return "needs-lee", "the disposition says %s" % m.group(0).lower()
    if HOLD_RE.search(disposition):
        return "hold", "nothing to ship yet"
    m = DESTRUCTIVE_RE.search(disposition)
    if m:
        return "needs-lee", "the disposition says %s" % m.group(0).lower()
    if kind in SAFE_KINDS and SAFE_RE.search(disposition):
        return "safe", "a docs change one PR can ship"
    return "hold", "nothing to ship yet"


def text(value, limit):
    return " ".join(str(value).split())[:limit] if isinstance(value, str) else ""


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def judge(run_dir, date, now):
    """(items, coverage, notes) for one audit run folder."""
    coverage, notes, items = [], [], []
    result = load(os.path.join(run_dir, "result.json"))
    raw = load(os.path.join(run_dir, "findings.json"))
    if not isinstance(result, dict):
        coverage.append("audit run %s has no readable result.json" % date)
        result = {}
    if not isinstance(raw, list):
        coverage.append("audit run %s has no readable findings.json" % date)
        raw = []
    counts = result.get("counts") if isinstance(result.get("counts"), dict) else {}
    outcome = result.get("outcome")
    if result and outcome != "ok":
        coverage.append("audit run %s outcome is %s, so its findings may be incomplete" % (date, outcome))
    made = datetime.datetime.strptime(date, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()
    if now - made > AUDIT_DAYS * 86400:
        coverage.append("the newest audit run, %s, is more than %d days old" % (date, AUDIT_DAYS))
    if result:
        notes.append("Audit run %s: outcome %s; %s." % (date, outcome, ", ".join(
            "%s %s" % (k, counts[k]) for k in sorted(counts))))
    for f in raw:
        if not isinstance(f, dict):
            continue
        f = {k: text(f.get(k), 300) for k in ("kind", "severity", "title", "path", "evidence", "disposition")}
        b, why = bucket(f)
        items.append(dict(f, bucket=b, why=why, fingerprint=hashlib.sha256(
            "\0".join(("library", f["kind"], f["path"], f["title"])).encode("utf-8")).hexdigest()))
    decisions = counts.get("decisions")
    if isinstance(decisions, int) and decisions > 0:
        items.append({"kind": "decisions", "severity": "high", "title": "%d decision(s) for Lee" % decisions,
                      "path": os.path.join(run_dir, "report.md"), "evidence": "", "disposition": "one Captain's Log card for the run",
                      "bucket": "needs-lee", "why": "the audit's decisions for Lee",
                      "fingerprint": hashlib.sha256(("library\0decisions\0" + date).encode("utf-8")).hexdigest()})
    order = {b: n for n, b in enumerate(COUNTED + ("hold",))}
    rank = {"high": 0, "medium": 1, "low": 2}
    items.sort(key=lambda i: (order[i["bucket"]], rank.get(i["severity"], 3), i["path"], i["title"]))
    return items, coverage, notes


def render_md(doc):
    lines = ["# Library officer digest for %s" % doc["date"], "",
             "%d new item(s) to act on. Audit run: %s." % (doc["actionable"], doc["run"] or "none"), ""]
    lines += ["- " + n for n in doc["notes"]]
    heads = {"needs-lee": "Needs Lee", "safe": "Safe to ship", "code": "Code work", "hold": "On hold"}
    for b in ("needs-lee", "safe", "code", "hold"):
        found = [i for i in doc["items"] if i["bucket"] == b]
        lines += ["", "## %s (%d)" % (heads[b], len(found)), ""]
        for i in found:
            lines.append("- %s[%s] %s %s: %s (%s). Proposed: %s" % (
                "NEW " if i["new"] and b != "hold" else "", i["severity"], i["kind"], i["path"], i["title"], i["why"], i["disposition"]))
        if not found:
            lines.append("- None.")
    if doc["coverage"]:
        lines += ["", "## Coverage gaps", ""] + ["- " + c for c in doc["coverage"]]
    return "\n".join(lines) + "\n"


def run(args):
    now = args.now if args.now is not None else int(time.time())
    try:
        runs = sorted(n for n in os.listdir(args.audit) if RUN_RE.match(n) and os.path.isdir(os.path.join(args.audit, n)))
    except OSError:
        runs = []
    latest = runs[-1] if runs else None
    if latest:
        items, coverage, notes = judge(os.path.join(args.audit, latest), latest, now)
    else:
        items, coverage, notes = [], ["no audit run folder under %s" % args.audit], []
    os.makedirs(args.out, exist_ok=True)
    corpus.mark_new(args.out, args.date, items)
    new = sum(1 for i in items if i["new"] and i["bucket"] in COUNTED)
    doc = {"officer_role": "library", "date": args.date, "run": latest, "actionable": new,
           "counts": {b: sum(1 for i in items if i["bucket"] == b) for b in COUNTED + ("hold",)},
           "items": items, "findings": [i for i in items if i["bucket"] in COUNTED],
           "coverage": coverage, "notes": notes}
    corpus.write_if_changed(os.path.join(args.out, args.date + ".json"),
                            json.dumps(doc, sort_keys=True, indent=1, ensure_ascii=False) + "\n")
    corpus.write_if_changed(os.path.join(args.out, args.date + ".md"), render_md(doc))
    for c in coverage:
        print("Coverage gap: library: %s" % c)
    print("DIGEST %s %d %s.md" % (args.date, new, args.date))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-officer-library.py")
    parser.add_argument("action", choices=["run"])
    parser.add_argument("--audit", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--now", type=int)
    args = parser.parse_args(argv)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}(T\d{2})?", args.date):
        parser.error("--date must be YYYY-MM-DD or YYYY-MM-DDTHH")
    args.audit = os.path.expanduser(args.audit)
    return run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
