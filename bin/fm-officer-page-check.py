#!/usr/bin/env python3
"""fm-officer-page-check.py - the page-check officer's timed pass over the fleet app.

Run only through `bin/fm-officer.sh run <id>`, which owns the officer
contract; docs/configuration.md "Page-check officer" owns the registry fields.

Usage:
  fm-officer-page-check.py run --key <YYYY-MM-DDTHH> --out <lane-dir> --app <https-url>
                               [--rules <file>] [--stale-days N] [--remind-hours N]
                               [--home <dir>]... [--now <epoch>]

Lee's rule is that every fleet-app page stays current without being asked.
This pass reads each page's own GET endpoint (curl, never a write) and this
home's status logs, and flags four kinds of finding, each naming the page and
the object so firstmate can route the fix (cl-keeper closes or corrects a
card, a page owner fixes a page). It acts on nothing itself.

  standing-rule  a card or suggestion Lee is shown that a standing rule already
                 settles. Rules are lines in --rules (default this home's
                 data/captain-shared.md) of the form
                     - standing-rule <id> /<regex>/ - <rule text>
                 whose case-insensitive regex is matched against the card's
                 words. Other lines of the file are ignored; a file with no
                 rule line is a coverage note, since the check then covers nothing.
  stale-card     a shown card that is past its snooze date, unanswered for
                 --stale-days, already answered, names a merged or closed PR
                 (read with `gh-axi api GET`, at most MAX_PR_LOOKUPS a run), or
                 whose keyed status line a later `resolved` line settled.
  shown-after-done  a card shown although its record is settled: its status
                 line was resolved before the card was (re)raised, or the app's
                 own card record for a facts source (GET
                 /api/captains-log/facts?source=bosun) is closed while the
                 page still shows it asked.
  page-old       a page whose newest publish is older than its normal cadence
                 allows (PAGES), a job on the Runs page that is failing, or a
                 page that is unreachable, unreadable or never published. A
                 page whose JSON is not the expected shape is unreadable.

The pass reads current records, so --key (the scheduler's slot) only names the
run. It writes into --out: <key>.json (every open finding), <key>.md (the
digest) and state.json (when each finding was last reported). It prints
`DIGEST <key> <n> <key>.md` where n counts findings not yet reported, or
reported more than --remind-hours (default 24) ago, so an unchanged page set
does not wake firstmate every slot while a finding nobody fixed returns daily.
An unreachable app is a finding, not a failed run.
"""

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import time

MAX_PR_LOOKUPS = 40
FACTS_SOURCES = ("bosun",)
PR_RE = re.compile(r"https://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)")
RULE_RE = re.compile(r"^\s*(?:-\s*)?standing-rule\s+([a-z0-9-]+)\s+/(.+)/\s+-\s+(.+?)\s*$", re.M)

# page -> (GET path, dotted timestamp keys tried in order (newest value wins), longest normal gap in hours).
# A page the shell lists but this table omits has no state of its own: Home (covered by /api/health) or a
# result page covered by the Runs jobs that feed it.
PAGES = {
    "Captain's Log": ("/api/captains-log", ("value.updated", "at"), 6),
    "Top of Mind": ("/api/top-of-mind", ("homes[].observed_at",), 6),
    "Progress officer": ("/api/progress-officer", ("state.written_at", "value.state.written_at"), 48),
    "Velocity audit": ("/api/velocity-audit", ("value.generated_at", "generated_at"), 36),
    "Cost and cycle time": ("/api/cost-cycle", ("sources.workers.homes[].observed_at", "sources.prs.observed_at",
                                                 "sources.usage.observed_at"), 3),
    "Feature ideation": ("/api/ideation", ("value.generated_at", "generated_at"), 36),
    "Business health": ("/api/business-health", ("value.generated_at", "generated_at"), 36),
    "Bosun": ("/api/runs/bosun-maintenance/results", ("runs[].run.startedAt",), 26),
}


def _friction():
    mod = sys.modules.get("fm_officer_friction")
    if mod is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-officer-friction.py")
        spec = importlib.util.spec_from_file_location("fm_officer_friction", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        sys.modules["fm_officer_friction"] = mod
    return mod


friction = _friction()
triage = friction.triage


def fetch(app, path):
    """(state, json): state is read (a JSON object), missing (404), unreachable or unreadable."""
    proc = subprocess.run(["curl", "-sS", "--max-time", "30", "-w", "\n%{http_code}", app.rstrip("/") + path],
                          capture_output=True, check=False)
    if proc.returncode != 0:
        return "unreachable", None
    body, _, code = proc.stdout.decode("utf-8", "replace").rpartition("\n")
    if code == "404":
        return "missing", None
    try:
        doc = json.loads(body) if code == "200" else None
    except ValueError:
        doc = None
    return ("read", doc) if isinstance(doc, dict) else ("unreadable", None)


WHY = {"missing": "never published", "unreachable": "unreachable", "unreadable": "unreadable"}


def items(doc, key):
    value = doc.get(key)
    return [v for v in value if isinstance(v, dict)] if isinstance(value, list) else []


def pick(doc, dotted):
    """Every value at a dotted path; `name[]` walks a list."""
    values = [doc]
    for part in dotted.split("."):
        walk = part.endswith("[]")
        part = part[:-2] if walk else part
        nxt = []
        for v in values:
            v = v.get(part) if isinstance(v, dict) else None
            if walk and isinstance(v, list):
                nxt.extend(v)
            elif v is not None:
                nxt.append(v)
        values = nxt
    return values


def newest(doc, keys):
    stamps = [friction.epoch_of(v) for k in keys for v in pick(doc, k)]
    stamps = [s for s in stamps if s is not None]
    return max(stamps) if stamps else None


def load_rules(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return [], ["standing rules file %s is unreadable" % path]
    rules, bad = [], []
    for rid, pattern, rule_text in RULE_RE.findall(text):
        try:
            rules.append((rid, re.compile(pattern, re.I), rule_text))
        except re.error:
            bad.append(rid)
    notes = ["standing rule(s) %s have an invalid regex" % ", ".join(bad)] if bad else []
    if not rules:
        notes.append("no standing-rule lines in %s; the standing-rule check covers nothing" % path)
    return rules, notes


def settled_by_status(homes):
    """card id -> (state, epoch) of its keyed status line's last word, when that word is `resolved`."""
    out = {}
    for home in homes:
        for task, stream in friction.status_streams(triage.Home(home)).items():
            last = {}
            for e in stream:
                if e["key"]:
                    last[e["key"]] = e
            for key, e in last.items():
                if e["state"] == "resolved":
                    out[friction.card_id(task, key)] = e["at"]
    return out


def pr_state(repo, number, cache, budget):
    key = (repo, number)
    if key not in cache:
        if budget[0] <= 0:
            return None
        budget[0] -= 1
        proc = subprocess.run(["gh-axi", "api", "GET", "/repos/%s/pulls/%s" % (repo, number), "--jq",
                               '"PRSTATE " + ({state: .state, merged: .merged} | tojson)'],
                              capture_output=True, check=False)
        out = proc.stdout.decode("utf-8", "replace").strip()
        try:
            got = json.loads(out[8:]) if proc.returncode == 0 and out.startswith("PRSTATE ") else {}
        except ValueError:
            got = {}
        cache[key] = ("merged" if got.get("merged") else got.get("state")) if got.get("state") in ("open", "closed") else None
    return cache[key]


def words(card):
    return " ".join(str(card.get(k) or "") for k in ("question", "advice", "detail", "title", "tldr"))


def finding(kind, page, ref, title, evidence, route):
    return {"id": "%s:%s:%s" % (kind, page, ref), "kind": kind, "page": page, "title": friction.scrub(title, 110),
            "evidence": evidence, "route": route}


def card_findings(log, rules, settled, known_closed, now, stale_days, coverage):
    out, cache, budget, unread = [], {}, [MAX_PR_LOOKUPS], set()
    page = "Captain's Log"
    shown = [c for c in items(log, "cards") if c.get("state") in ("asked", "snoozed")]
    shown += [dict(s, id="top10-%s" % s.get("id")) for s in items(log, "suggestions") if s.get("state") == "suggested"]
    shown += [dict(c, id="choice-%s" % c.get("id")) for c in items(log, "choice")
              if c.get("ask") and c.get("status") != "landed"]
    for c in shown:
        cid, title = str(c.get("id")), c.get("question") or c.get("title") or ""
        text = words(c)
        for rid, pattern, rule_text in rules:
            if pattern.search(text):
                out.append(finding("standing-rule", page, "%s:%s" % (cid, rid), title,
                                   "standing rule %s settles it: %s" % (rid, friction.scrub(rule_text, 120)),
                                   "cl-keeper: close the card citing the rule"))
        asked = friction.epoch_of(c.get("reasked")) or friction.epoch_of(c.get("asked"))
        done_at = settled.get(cid)
        if cid in known_closed:
            out.append(finding("shown-after-done", page, cid, title,
                               "the app's own record for this card is closed but the page shows it %s" % c.get("state"),
                               "cl-keeper: close the card; fix the source that re-raises it"))
        elif done_at is not None:
            if asked is not None and asked > done_at:
                out.append(finding("shown-after-done", page, cid, title,
                                   "status line resolved at %s, re-raised at %s" % (
                                       time.strftime("%Y-%m-%d %H:%MZ", time.gmtime(done_at)),
                                       time.strftime("%Y-%m-%d %H:%MZ", time.gmtime(asked))),
                                   "cl-keeper: close the card; fix the source that re-raises it"))
            else:
                out.append(finding("stale-card", page, cid + ":resolved", title, "its status line was resolved elsewhere",
                                   "cl-keeper: close the card"))
        until = friction.epoch_of(c.get("until"))
        if c.get("state") == "snoozed" and until is not None and until < now:
            out.append(finding("stale-card", page, cid + ":snooze", title, "snooze ended %d day(s) ago" % ((now - until) // 86400),
                               "cl-keeper: re-ask or close"))
        elif c.get("state") == "asked" and asked is not None and now - asked > stale_days * 86400 and not c.get("pinned"):
            out.append(finding("stale-card", page, cid + ":unanswered", title, "unanswered for %d day(s)" % ((now - asked) // 86400),
                               "cl-keeper: close or re-word"))
        if c.get("state") == "asked" and c.get("answer"):
            out.append(finding("stale-card", page, cid + ":answered", title, "already answered but still shown", "cl-keeper: close"))
        for repo, number in PR_RE.findall(text):
            state = pr_state(repo, number, cache, budget)
            if state in ("merged", "closed"):
                out.append(finding("stale-card", page, "%s:%s#%s" % (cid, repo, number), title,
                                   "names %s#%s, which is %s" % (repo, number, state), "cl-keeper: close or correct"))
            elif state is None:
                unread.add("%s#%s" % (repo, number))
    if unread:
        coverage.append("PR state unreadable (budget %d lookups a run) for %s" % (MAX_PR_LOOKUPS, ", ".join(sorted(unread)[:8])))
    return out


def page_findings(app, now):
    out, docs = [], {}
    for page, (path, keys, max_hours) in sorted(PAGES.items()):
        state, doc = fetch(app, path)
        limit = max_hours
        if state == "read" and page == "Progress officer":
            mins = pick(doc, "state.stale_after_minutes") + pick(doc, "value.state.stale_after_minutes")
            if mins and (isinstance(mins[0], bool) or not isinstance(mins[0], (int, float))):
                state = "unreadable"
            elif mins:
                limit = mins[0] / 60.0
        docs[page] = doc if state == "read" else None
        ref = path.rsplit("/", 1)[-1]
        if state != "read":
            out.append(finding("page-old", page, ref, "%s: %s" % (page, WHY[state]),
                               "GET %s was %s" % (path, state), "page owner: restore the page's feed"))
            continue
        at = newest(doc, keys)
        if at is None:
            out.append(finding("page-old", page, ref, "%s: no publish time" % page,
                               "GET %s carries none of %s" % (path, ", ".join(keys)), "page owner: add a publish time"))
        elif now - at > limit * 3600:
            out.append(finding("page-old", page, ref, "%s: not updated for %d hour(s)" % (page, (now - at) // 3600),
                               "normal gap is %s hour(s); last publish %s" % (
                                   ("%g" % limit), time.strftime("%Y-%m-%d %H:%MZ", time.gmtime(at))),
                               "page owner: fix the feed"))
    state, runs = fetch(app, "/api/runs")
    if state != "read":
        out.append(finding("page-old", "Runs", "runs", "Runs: %s" % WHY[state], "GET /api/runs was %s" % state,
                           "page owner: restore the page's feed"))
    else:
        for job in items(runs, "jobs"):
            if job.get("state") == "live" and job.get("health") == "failing":
                out.append(finding("page-old", "Runs", str(job.get("id")), "%s is failing" % (job.get("label") or job.get("id")),
                                   "officer %s: health failing, next due %s" % (job.get("officer"), job.get("nextDueAt")),
                                   "page owner: fix the job"))
    state, _ = fetch(app, "/api/health")
    if state != "read":
        out.append(finding("page-old", "Home", "health", "Home: app %s" % WHY[state], "GET /api/health was %s" % state,
                           "page owner: restore the app"))
    return out, docs


def render_md(key, findings, new_ids, coverage):
    lines = ["# Page check %s" % key, "", "%d open finding(s), %d new." % (len(findings), len(new_ids)), ""]
    lines += ["Coverage: " + c for c in coverage]
    for f in findings:
        lines.append("- %s[%s] %s - %s: %s (evidence: %s) -> %s" % (
            "NEW " if f["id"] in new_ids else "", f["kind"], f["page"], f["id"].split(":", 2)[2], f["title"],
            f["evidence"], f["route"]))
    return "\n".join(lines) + "\n"


def run(args):
    now = args.now if args.now is not None else int(time.time())
    rules, coverage = load_rules(args.rules) if args.rules else ([], ["no standing rules file"])
    findings, docs = page_findings(args.app, now)
    log = docs["Captain's Log"]
    if log is not None:
        doc = log.get("value")
        known_closed = set()
        for source in FACTS_SOURCES:
            fstate, facts = fetch(args.app, "/api/captains-log/facts?source=" + source)
            if fstate == "read":
                known_closed |= {c.get("id") for c in items(facts, "cards") if c.get("lifecycle") == "closed"}
            else:
                coverage.append("card record for source %s was %s" % (source, fstate))
        findings += card_findings(doc if isinstance(doc, dict) else {}, rules, settled_by_status(args.home), known_closed,
                                  now, args.stale_days, coverage)
    findings.sort(key=lambda f: f["id"])
    seen_path = os.path.join(args.out, "state.json")
    try:
        with open(seen_path, encoding="utf-8") as fh:
            seen = json.load(fh)
    except (OSError, ValueError):
        seen = {}
    window = args.remind_hours * 3600
    new_ids = {f["id"] for f in findings if now - seen.get(f["id"], -window - 1) >= window}
    os.makedirs(args.out, exist_ok=True)
    kept = {f["id"]: (now if f["id"] in new_ids else seen[f["id"]]) for f in findings}
    triage.write_if_changed(seen_path, json.dumps(kept, sort_keys=True, indent=1) + "\n")
    triage.write_if_changed(os.path.join(args.out, args.key + ".json"),
                            json.dumps({"key": args.key, "findings": findings, "new": sorted(new_ids), "coverage": coverage},
                                       sort_keys=True, indent=1, ensure_ascii=False) + "\n")
    triage.write_if_changed(os.path.join(args.out, args.key + ".md"), render_md(args.key, findings, new_ids, coverage))
    print("DIGEST %s %d %s.md" % (args.key, len(new_ids), args.key))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-officer-page-check.py")
    parser.add_argument("action", choices=["run"])
    parser.add_argument("--key", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--rules")
    parser.add_argument("--stale-days", type=int, default=7)
    parser.add_argument("--remind-hours", type=int, default=24)
    parser.add_argument("--home", action="append", default=[])
    parser.add_argument("--now", type=int)
    args = parser.parse_args(argv)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}(T\d{2})?", args.key):
        parser.error("--key must be YYYY-MM-DD or YYYY-MM-DDTHH")
    return run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
