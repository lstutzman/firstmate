#!/usr/bin/env python3
"""fm-officer-landing.py - the landing (records) officer's daily pass.

Run only through `bin/fm-officer.sh run <id>`, which owns the officer
contract; docs/configuration.md "Officers" owns the registry schema.

Usage:
  fm-officer-landing.py run --facts <path|host:path|https-url> --date <YYYY-MM-DD>
                            --out <lane-dir> [--team PC] [--done-window 100]
                            [--writes corrections|none] [--max-corrections 10]
                            [--reopen-state "In Progress"] [--max-facts-age 36]
                            [--now <epoch>]

Landing facts come from the fleet-app landing-truth job and are never
re-collected here. Schema 2 has exactly the top-level keys schema_version,
generated_at, staging_sha, production_sha, records, and items: `records`
holds one record per PR keyed "<repo>#<pr>" (repo, pr, head_sha, merged_sha,
merged_at, on_staging, staging_deployed, on_main, main_promoted_at,
in_production, production_release, linear_ids, landed_via, and linear_state,
an object keyed by Linear id), and `items` maps each Linear id to its record
keys. Any other schema version or layout fails the run. This pass adds the officer's judgements from
those facts plus Linear:

  A1 false done      the item is Done, but a PR linked to it is merged and not
                     in production, no linked PR is merged, or no landing fact
                     names the item at all;
  B1 false not-done  every PR linked to the item is in production, but the
                     item is not Done (proposed state Done); or a linked PR is
                     on staging while the item is still before In Staging
                     (proposed state In Staging, never written here).

Linear's request budget is shared by the whole fleet, so Done items are read
as one paged list of at most --done-window items, and no call is made per
item except to re-check an item just before correcting it.

Only production-code landing is decidable from the facts; the other kinds of
work in the audit's definition need a probe or Lee's recorded word, so an A1
with no facts is raised for a person, never acted on.

PropertyCompass2's release workflow (linear-production-done.yml) is the
routine Done writer; this officer only corrects what it misses. With
--writes corrections (the default) it makes two corrections:

  close   an item not Done whose every linked PR is merged and in production,
          and that has no sub-issues, moves to Done;
  reopen  a Done item that a landing fact names, with a linked PR merged that
          never reached main (on_main false) or any release, moves to
          --reopen-state (In Progress by default; In Staging and Done are
          refused). A Done item whose PR is on main but not yet in production
          is release lag: it is reported, never written.

No Linear write is made when the facts name no production_sha or their
generated_at is missing or older than --max-facts-age hours; a stale-facts
finding is raised instead. A null or absent fact is unknown, never false.

Each correction re-checks that Linear still shows the state the facts
recorded, writes an evidence comment quoting the landing-truth record it
used, then changes the state, each through linear-axi --dry-run and then
--verify. At most --max-corrections items per run are written; a skipped
item does not count, and a run re-checks at most five items per allowed
correction. Every correction and skip
is also logged with that record in the findings file. It never writes In
Staging, never files an item, and leaves a Done item no fact names to a
person. --writes none writes nothing to Linear.

Outputs <date>.json and <date>.md in --out and prints
`DIGEST <date> <n-actionable> <date>.md` as its last stdout line.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time

FACT_FIELDS = ("repo", "pr", "merged_sha", "merged_at", "on_staging", "staging_deployed",
               "on_main", "main_promoted_at", "in_production", "production_release", "landed_via")
NOT_STARTED = {"Triage", "Backlog", "Todo", "In Progress"}
CLOSED = {"Done", "Canceled", "Cancelled", "Duplicate"}
VIEWS_PER_CORRECTION = 5
TOP_KEYS = {"schema_version", "generated_at", "staging_sha", "production_sha", "records", "items"}


def load_facts(source):
    remote = re.match(r"^([A-Za-z0-9][A-Za-z0-9._@-]*):(/.*)$", source)
    if source.startswith("https://"):
        proc = subprocess.run(["curl", "-fsS", "--max-time", "30", source],
                              capture_output=True, check=False)
        if proc.returncode != 0:
            raise RuntimeError("landing facts endpoint unreachable (curl exit %d)" % proc.returncode)
        raw = proc.stdout
    elif remote:
        proc = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                               remote.group(1), "cat " + shell_quote(remote.group(2))],
                              capture_output=True, check=False)
        if proc.returncode != 0:
            raise RuntimeError("landing facts host %s unreachable (ssh exit %d)"
                               % (remote.group(1), proc.returncode))
        raw = proc.stdout
    else:
        try:
            with open(source, "rb") as fh:
                raw = fh.read()
        except OSError as exc:
            raise RuntimeError("landing facts unreadable: %s" % exc.strerror)
    try:
        doc = json.loads(raw.decode("utf-8"))
    except ValueError:
        raise RuntimeError("landing facts are not JSON")
    if not isinstance(doc, dict) or doc.get("schema_version") != 2:
        raise RuntimeError("landing facts schema_version is not 2")
    if set(doc) != TOP_KEYS:
        raise RuntimeError("landing facts top-level keys are not exactly %s" % ", ".join(sorted(TOP_KEYS)))
    records = doc["records"]
    if not isinstance(records, dict):
        raise RuntimeError("landing facts records is not an object keyed <repo>#<pr>")
    for key, rec in records.items():
        if not isinstance(rec, dict) or key != "%s#%s" % (rec.get("repo"), rec.get("pr")):
            raise RuntimeError("landing facts record %s is not keyed by its <repo>#<pr>" % key)
        if not isinstance(rec.get("linear_state"), dict):
            raise RuntimeError("landing facts record %s linear_state is not an object keyed by Linear id" % key)
    items = doc["items"]
    if not isinstance(items, dict):
        raise RuntimeError("landing facts items is not an object keyed by Linear id")
    for item, keys in items.items():
        if not isinstance(keys, list) or any(k not in records for k in keys):
            raise RuntimeError("landing facts item %s does not list record keys present in records" % item)
    return doc


def shell_quote(text):
    return "'" + text.replace("'", "'\\''") + "'"


def linear(args):
    proc = subprocess.run(["linear-axi"] + args + ["--output", "json"],
                          capture_output=True, check=False)
    try:
        doc = json.loads(proc.stdout.decode("utf-8"))
    except ValueError:
        raise RuntimeError("linear-axi %s returned no JSON (exit %d)" % (args[0:2], proc.returncode))
    if not doc.get("ok"):
        error = doc.get("error") or {}
        raise RuntimeError("linear-axi %s failed: %s: %s" % (
            " ".join(args[0:2]), error.get("code", "unknown"),
            str(error.get("message", ""))[:120]))
    return doc.get("data") or {}


def done_items(team, window):
    data = linear(["issue", "list", "--team", team, "--state", "Done", "--all",
                   "--max-items", str(window)])
    return sorted(i["identifier"] for i in data.get("issues") or [] if i.get("identifier"))


def judge(doc, done_listed, reopen_state="In Progress"):
    """Per-item landing view and findings; a pure function of its inputs."""
    items = {}
    for item, keys in doc["items"].items():
        entry = items.setdefault(item, {"item": item, "states": set(), "prs": []})
        for key in keys:
            rec = doc["records"][key]
            if rec["linear_state"].get(item):
                entry["states"].add(rec["linear_state"][item])
            entry["prs"].append({k: rec.get(k) for k in FACT_FIELDS})
    findings = []
    view = []
    for item in sorted(items):
        entry = items[item]
        prs = sorted(entry["prs"], key=lambda p: (str(p.get("repo")), str(p.get("pr"))))
        states = sorted(entry["states"])
        state = states[0] if len(states) == 1 else None
        merged = [p for p in prs if p.get("merged_sha")]
        in_prod = [p for p in merged if p.get("in_production") is True]
        record = {"item": item, "linear_state": state, "linear_states_seen": states,
                  "prs": prs, "class": None, "proposed_state": None, "correction": None}
        if state is None and len(states) > 1:
            findings.append({"class": "conflict", "item": item, "severity": "medium",
                             "summary": "landing facts disagree on its Linear state: %s" % ", ".join(states)})
        elif state == "Done":
            never = [p for p in merged if p.get("on_main") is False and p.get("production_release") is None]
            lag = [p for p in merged if p not in never and p.get("in_production") is False]
            unknown = [p for p in merged if p not in never and not isinstance(p.get("in_production"), bool)]
            if never:
                record["class"] = "A1"
                record["proposed_state"] = reopen_state
                record["correction"] = "reopen"
                findings.append({"class": "A1", "item": item, "severity": "high",
                                 "summary": "Done, but %s merged and never reached main or any release"
                                 % pr_list(never)})
            elif not merged:
                record["class"] = "A1"
                findings.append({"class": "A1", "item": item, "severity": "low",
                                 "summary": "Done, but no linked PR (%s) is merged; needs a probe or Lee's recorded word"
                                 % (pr_list(prs) or "none")})
            elif lag or unknown:
                record["class"] = "A1"
                parts = (["%s not yet in production (release lag)" % pr_list(lag)] if lag else []) + \
                        (["%s production status unknown" % pr_list(unknown)] if unknown else [])
                findings.append({"class": "A1", "item": item, "severity": "low",
                                 "summary": "Done, but %s; reported only" % "; ".join(parts)})
        elif state is not None and state not in CLOSED and merged:
            if len(in_prod) == len(merged) == len(prs):
                record["class"] = "B1"
                record["proposed_state"] = "Done"
                record["correction"] = "close"
                findings.append({"class": "B1", "item": item, "severity": "medium",
                                 "summary": "%s, but %s in production (%s)" % (
                                     state, pr_list(in_prod), releases(in_prod))})
            elif state in NOT_STARTED and any(p.get("on_staging") for p in merged):
                record["class"] = "B1"
                record["proposed_state"] = "In Staging"
                findings.append({"class": "B1", "item": item, "severity": "low",
                                 "summary": "%s, but %s merged to staging" % (
                                     state, pr_list([p for p in merged if p.get("on_staging")]))})
        view.append(record)
    for item in done_listed:
        if item not in items:
            findings.append({"class": "A1", "item": item, "severity": "low",
                             "summary": "Done with no landing fact naming it; needs a probe or Lee's recorded word"})
    rank = {"high": 0, "medium": 1, "low": 2}
    findings.sort(key=lambda f: (rank[f["severity"]], f["class"], f["item"]))
    return view, findings


def pr_list(prs):
    return ", ".join("%s#%s" % (str(p.get("repo")).split("/")[-1], p.get("pr")) for p in prs)


def releases(prs):
    found = sorted({str(p.get("production_release")) for p in prs if p.get("production_release")})
    return "release " + ", ".join(found) if found else "production release not named"


def facts_age_problem(doc, max_hours, now):
    """Why the facts cannot be written from, or None when they are fresh."""
    if not doc.get("production_sha"):
        return "landing facts name no production_sha, so production status is unknown"
    stamp = doc.get("generated_at")
    try:
        made = datetime.datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
        age = now - made.timestamp()
    except (TypeError, ValueError):
        return "landing facts generated_at is missing or unreadable (%s)" % json.dumps(stamp)
    if made.tzinfo is None:
        return "landing facts generated_at has no time zone (%s)" % stamp
    if age > max_hours * 3600:
        return "landing facts generated %s are older than %d hours" % (stamp, max_hours)
    return None


def evidence_comment(record, doc, action, to_state):
    why = ("every linked PR is merged and in production, but the release workflow did not set Done"
           if action == "close" else
           "it is Done, but a linked PR is merged and never reached main or any release")
    lines = ["Landing officer correction: moving to %s because %s." % (to_state, why), "",
             "Landing-truth record used (schema %s, generated %s, production %s, staging %s):" % (
                 doc.get("schema_version"), doc.get("generated_at"),
                 doc.get("production_sha"), doc.get("staging_sha")), ""]
    for p in record["prs"]:
        lines.append("- " + ", ".join("%s=%s" % (k, json.dumps(p.get(k))) for k in FACT_FIELDS))
    return "\n".join(lines) + "\n"


def correct_items(view, doc, out, date, max_corrections, reopen_state):
    """Apply the officer's two corrections; returns one result per item tried.

    close:  an item not Done whose every linked PR is merged and in production
            (the release workflow, the routine Done writer, missed it);
    reopen: a Done item a landing fact names with a linked PR merged that never
            reached main or any release; it moves to reopen_state, never In
            Staging.
    """
    results = []
    attempts = 0
    for record in [r for r in view if r["correction"]][:max_corrections * VIEWS_PER_CORRECTION]:
        if attempts >= max_corrections:
            break
        item = record["item"]
        action = record["correction"]
        to_state = "Done" if action == "close" else reopen_state
        used = {"facts_generated_at": doc.get("generated_at"),
                "production_sha": doc.get("production_sha"), "prs": record["prs"]}
        try:
            current = linear(["issue", "view", item, "--sub-issues"])
            state = (current.get("issue") or {}).get("state")
            if state != record["linear_state"]:
                results.append({"item": item, "action": "skipped", "to": to_state, "record": used,
                                "reason": "Linear now says %s" % state})
                continue
            if action == "close" and current.get("subIssues"):
                results.append({"item": item, "action": "skipped", "to": to_state, "record": used,
                                "reason": "item has sub-issues"})
                continue
            attempts += 1
            body = os.path.join(out, ".evidence-%s-%s.md" % (date, item))
            with open(body, "w", encoding="utf-8") as fh:
                fh.write(evidence_comment(record, doc, action, to_state))
            try:
                linear(["issue", "comment", item, "--body-file", body, "--dry-run"])
                linear(["issue", "comment", item, "--body-file", body, "--verify"])
            finally:
                os.remove(body)
            linear(["issue", "update", item, "--state", to_state, "--dry-run"])
            linear(["issue", "update", item, "--state", to_state, "--verify"])
            results.append({"item": item, "action": "reopened" if action == "reopen" else "closed",
                            "to": to_state, "record": used, "reason": "landing-truth record"})
        except RuntimeError as exc:
            results.append({"item": item, "action": "failed", "to": to_state, "record": used,
                            "reason": str(exc)})
    return results


def render_md(doc):
    lines = ["# Landing officer digest for %s" % doc["date"], ""]
    lines.append("%d actionable finding(s); Linear writes: %s%s." % (
        doc["actionable"], doc["writes"],
        " (none made: %s)" % doc["writes_blocked"] if doc["writes_blocked"] else ""))
    lines.append("Facts generated %s; production %s; staging %s." % (
        doc["facts"]["generated_at"], doc["facts"]["production_sha"], doc["facts"]["staging_sha"]))
    lines += ["", "## Counts", ""]
    for k, n in doc["counts"].items():
        lines.append("- %s: %d" % (k, n))
    if doc["writes_done"]:
        lines += ["", "## Linear writes", ""]
        for w in doc["writes_done"]:
            lines.append("- %s: %s to %s (%s; facts generated %s)" % (
                w["item"], w["action"], w["to"], w["reason"], w["record"]["facts_generated_at"]))
    lines += ["", "## Findings", ""]
    for f in doc["findings"]:
        lines.append("- [%s] %s %s: %s" % (f["severity"], f["class"], f["item"], f["summary"]))
    if not doc["findings"]:
        lines.append("- None.")
    return "\n".join(lines) + "\n"


def write_if_changed(path, text):
    try:
        with open(path, encoding="utf-8") as fh:
            if fh.read() == text:
                return
    except OSError:
        pass
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-officer-landing.py")
    parser.add_argument("action", choices=["run"])
    parser.add_argument("--facts", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--team", default="PC")
    parser.add_argument("--done-window", type=int, default=100)
    parser.add_argument("--writes", choices=["none", "corrections"], default="corrections")
    parser.add_argument("--max-corrections", type=int, default=10)
    parser.add_argument("--reopen-state", default="In Progress")
    parser.add_argument("--max-facts-age", type=int, default=36)
    parser.add_argument("--now", type=int)
    args = parser.parse_args(argv)
    if args.reopen_state in ("In Staging", "Done"):
        parser.error("--reopen-state may not be In Staging or Done")
    try:
        facts = load_facts(args.facts)
        done_listed = done_items(args.team, args.done_window) if args.done_window > 0 else []
        view, findings = judge(facts, done_listed, args.reopen_state)
        stale = facts_age_problem(facts, args.max_facts_age,
                                  time.time() if args.now is None else args.now)
        if stale:
            findings.insert(0, {"class": "stale-facts", "item": "-", "severity": "high",
                                "summary": stale + "; no Linear write made"})
        writes = correct_items(view, facts, args.out, args.date, args.max_corrections,
                               args.reopen_state) if args.writes == "corrections" and not stale else []
    except RuntimeError as exc:
        print("fm-officer-landing: %s" % exc, file=sys.stderr)
        return 1
    counts = {}
    for f in findings:
        counts[f["class"]] = counts.get(f["class"], 0) + 1
    doc = {
        "officer_role": "landing",
        "date": args.date,
        "writes": args.writes,
        "facts": {k: facts.get(k) for k in ("schema_version", "generated_at", "staging_sha", "production_sha")},
        "counts": dict(sorted(counts.items())),
        "findings": findings,
        "actionable": sum(1 for f in findings if f["severity"] in ("high", "medium")),
        "items": view,
        "writes_done": writes,
        "writes_blocked": stale if args.writes == "corrections" else None,
    }
    write_if_changed(os.path.join(args.out, args.date + ".json"),
                     json.dumps(doc, sort_keys=True, indent=1, ensure_ascii=False) + "\n")
    write_if_changed(os.path.join(args.out, args.date + ".md"), render_md(doc))
    print("DIGEST %s %d %s.md" % (args.date, doc["actionable"], args.date))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
