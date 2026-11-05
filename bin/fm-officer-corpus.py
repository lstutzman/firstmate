#!/usr/bin/env python3
"""fm-officer-corpus.py - the corpus officer's daily pass over the agent training corpus.

Run only through `bin/fm-officer.sh run <id>`, which owns the officer
contract; docs/configuration.md "Corpus officer" owns the registry fields.

Usage:
  fm-officer-corpus.py run --archive <dir|host:dir> --date <YYYY-MM-DD> --out <lane-dir>
                           [--hosts a,b] [--harvest <path|host:path>] [--prep <path|host:path>]
                           [--local-jev <dir|host:dir>] [--now <epoch>]

The officer reads counts, sizes, timestamps and names only, never a
transcript, a corpus row or a harvested memory record. A `host:path` input is
read by sending this script to the host (`ssh -o BatchMode=yes <host> python3
-I - probe ...`), where the probe opens each file and returns only the fields
listed below, so nothing else leaves the host; a plain path is probed in
process. One ssh call reads every input on a host, and an unreachable host or
a missing or unreadable file is a coverage gap, never a failed run.

Inputs (relative paths are under the host's home directory):
  ingest   <archive>/transcript-archive/last-result.json: outcome and counts
           (archived, unchanged, withheld, errors, sources_ok,
           sources_not_collected, hosts_offline); and the last RUNS_TAIL lines
           of runs.jsonl beside it: each run's `finished`, the source names
           its `sources` reads not collected for a reason other than host
           offline, and the hosts it reads offline.
  harvest  --harvest, default <archive>/memory-harvest/last-result.json: its
           outcome and counts listed, total (the tier's own total), written,
           withheld, deleted and superseded. The memory harvest has not
           shipped, so these names are the design's and a missing file is a
           coverage note.
  bosun    each --hosts host's ~/services/bosun-maintenance/last-result.json:
           its date and the counts of its `archive` section (reached, checked,
           archived, pending, missing, mismatched, withheld), never its lists.
  prep     --prep, default slartibartfast:Documents/GitHub/local-jev/data/prep/ready.json
           (the prep timer runs on slartibartfast): finished and rows.
  weekly   <local-jev>/results/weekly/history.jsonl, --local-jev default
           deepthought:Documents/GitHub/local-jev: the newest record's run,
           started, finished and status.
  judge    <local-jev>/results/judge/: the number of eval-*.json results and
           the newest name, from the listing only.

Finding classes, each with a fingerprint:
  not-collected   a source the newest ingester run did not collect, for that
                  run and the one before it at least. A source not collected
                  because its host is offline (the MacBook asleep) is not a
                  finding; the digest names offline hosts.
  archive-gap     a Bosun host whose archive check found missing or
                  out-of-date session logs on its two most recent nights. The
                  Bosun keeps only its last result, so the lane's nights.json
                  remembers each host's count per Bosun date (seven at most).
                  An archive section that is absent or not reached is a
                  coverage gap.
  harvest-failed  the harvest's outcome is failed.
  harvest-drift   listed and total differ by more than 1% of total.
  prep-stale      the prep store finished more than PREP_HOURS hours ago.
  retrain-missed  the newest weekly retrain started more than RETRAIN_DAYS
                  days ago, there is none, or it failed.

A finding is reported once: reported.json maps each open fingerprint to the
run key that first reported it, a finding counts as new only at that key, and
a fingerprint that clears is dropped, so a recurrence after a fix is new
again. Re-running a key on unchanged inputs writes identical bytes: no output
holds the clock, only source timestamps and thresholds.

Outputs <date>.json and <date>.md in --out, prints one `Coverage gap:` line
per gap and `DIGEST <date> <n-new> <date>.md` last.
"""

import argparse
import collections
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import time

RUNS_TAIL = 24
PREP_HOURS = 36
RETRAIN_DAYS = 8
DRIFT = 0.01
NIGHTS_KEPT = 7
BOSUN_RESULT = "~/services/bosun-maintenance/last-result.json"
DEFAULT_PREP = "slartibartfast:Documents/GitHub/local-jev/data/prep/ready.json"
DEFAULT_LOCAL_JEV = "deepthought:Documents/GitHub/local-jev"
OFFLINE = "not collected: host offline"
REMOTE_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._@-]*):(.+)$")
INGEST_COUNTS = ("archived", "unchanged", "withheld", "errors", "sources_ok", "sources_not_collected", "hosts_offline")
HARVEST_COUNTS = ("listed", "total", "written", "withheld", "deleted", "superseded")
BOSUN_COUNTS = ("checked", "archived", "pending", "missing", "mismatched", "withheld")


# ---- probe: runs where the file is, and returns only the fields named in the header.

def _path(p):
    p = os.path.expanduser(p)
    return p if os.path.isabs(p) else os.path.join(os.path.expanduser("~"), p)


def _json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _ints(d, keys):
    d = d if isinstance(d, dict) else {}
    return {k: d[k] for k in keys if isinstance(d.get(k), int) and not isinstance(d.get(k), bool)}


def _text(v):
    return v if isinstance(v, str) and len(v) <= 80 else None


def probe_ingest(path):
    doc = _json(os.path.join(path, "last-result.json"))
    runs = []
    try:
        with open(os.path.join(path, "runs.jsonl"), encoding="utf-8") as fh:
            tail = collections.deque(fh, maxlen=RUNS_TAIL)
    except FileNotFoundError:
        tail = None
    for line in tail or []:
        try:
            run = json.loads(line)
        except ValueError:
            continue
        sources = run.get("sources") if isinstance(run, dict) else None
        sources = sources if isinstance(sources, dict) else {}
        runs.append({"finished": _text(run.get("finished")),
                     "not_collected": sorted(k for k, v in sources.items()
                                             if isinstance(v, str) and v.startswith("not collected") and v != OFFLINE),
                     "offline": sorted({k.split("/")[0] for k, v in sources.items() if v == OFFLINE})})
    return {"outcome": _text(doc.get("outcome")), "counts": _ints(doc.get("counts"), INGEST_COUNTS),
            "runs": runs if tail is not None else None}


def probe_harvest(path):
    doc = _json(path)
    return {"outcome": _text(doc.get("outcome")), "counts": _ints(doc.get("counts"), HARVEST_COUNTS)}


def probe_bosun(path):
    doc = _json(path)
    archive = doc.get("archive")
    out = {"date": _text(doc.get("date")), "archive": None}
    if isinstance(archive, dict):
        out["archive"] = dict(_ints(archive, BOSUN_COUNTS), reached=archive.get("reached") is True)
    return out


def probe_prep(path):
    doc = _json(path)
    return {"finished": _text(doc.get("finished")), "rows": _ints(doc, ("rows",)).get("rows")}


def probe_weekly(path):
    newest = None
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict):
                newest = rec
    if newest is None:
        return {"newest": None}
    return {"newest": {k: _text(newest.get(k)) for k in ("run", "started", "finished", "status")}}


def probe_judge(path):
    names = sorted(n for n in os.listdir(path) if n.startswith("eval-") and n.endswith(".json"))
    return {"count": len(names), "newest": _text(names[-1]) if names else None}


PROBES = {"ingest": probe_ingest, "harvest": probe_harvest, "bosun": probe_bosun,
          "prep": probe_prep, "weekly": probe_weekly, "judge": probe_judge}


def probe(items):
    """[(kind, path)] -> one {"state": read|missing|unreadable, ...} per item."""
    out = []
    for kind, path in items:
        try:
            out.append(dict(PROBES[kind](_path(path)), state="read"))
        except FileNotFoundError:
            out.append({"state": "missing"})
        except (OSError, ValueError, TypeError, AttributeError):
            out.append({"state": "unreadable"})
    return out


# ---- gather: one ssh call per host.

def shell_quote(text):
    return "'" + text.replace("'", "'\\''") + "'"


def split(source):
    m = REMOTE_RE.match(source)
    return (m.group(1), m.group(2)) if m else (None, source)


def gather(items):
    """{name: (host, kind, path)} -> {name: probe result}; an unreachable host's items read "unreachable"."""
    by_host = collections.defaultdict(list)
    for name, (host, kind, path) in sorted(items.items()):
        by_host[host].append((name, kind, path))
    with open(os.path.abspath(__file__), "rb") as fh:
        program = fh.read()
    results = {}
    for host, entries in by_host.items():
        pairs = [(kind, path) for _, kind, path in entries]
        if host is None:
            got = probe(pairs)
        else:
            cmd = "python3 -I - probe " + " ".join(shell_quote(k + "=" + p) for k, p in pairs)
            try:
                proc = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, cmd],
                                      input=program, capture_output=True, timeout=120, check=False)
                got = json.loads(proc.stdout.decode("utf-8")) if proc.returncode == 0 else None
            except (OSError, subprocess.TimeoutExpired, ValueError):
                got = None
            if not (isinstance(got, list) and len(got) == len(pairs) and all(isinstance(g, dict) for g in got)):
                got = [{"state": "unreachable"}] * len(pairs)
        for (name, _, path), result in zip(entries, got):
            results[name] = dict(result, where="%s:%s" % (host, path) if host else path)
    return results


# ---- judge the facts.

def fingerprint(*parts):
    return hashlib.sha256("\0".join(("corpus",) + parts).encode("utf-8")).hexdigest()


def finding(klass, subject, severity, summary):
    return {"class": klass, "subject": subject, "severity": severity, "summary": summary,
            "fingerprint": fingerprint(klass, subject)}


def stamp(value):
    """Epoch seconds of an ISO time with a zone, or None."""
    try:
        made = datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return made.timestamp() if made.tzinfo is not None else None


def gap(read, what):
    return "%s %s (%s)" % (what, {"missing": "is missing", "unreadable": "is unreadable",
                                  "unreachable": "is on a host that could not be reached"}[read["state"]], read["where"])


def judge(facts, nights, now):
    """(findings, coverage, notes, nights) from the probe results; nights is the updated nights.json."""
    findings, coverage, notes = [], [], []
    ingest = facts["ingest"]
    if ingest["state"] != "read":
        coverage.append(gap(ingest, "the ingester's last result"))
    else:
        c = ingest["counts"]
        notes.append("Ingester: outcome %s; %s." % (ingest["outcome"], ", ".join("%s %d" % (k, c[k]) for k in INGEST_COUNTS if k in c)))
        runs = ingest["runs"]
        if not runs:
            coverage.append("the ingester's runs.jsonl beside %s has no readable runs" % ingest["where"])
        else:
            latest = runs[-1]
            for source in latest["not_collected"]:
                streak = 0
                for run in reversed(runs):
                    if source not in run["not_collected"]:
                        break
                    streak += 1
                if streak >= 2:
                    findings.append(finding("not-collected", source, "medium",
                                            "%s was not collected in the last %d%s runs (newest finished %s)" % (
                                                source, streak, " or more" if streak == len(runs) else "",
                                                latest["finished"])))
            if latest["offline"]:
                notes.append("Hosts offline in the newest ingester run: %s." % ", ".join(latest["offline"]))
    harvest = facts["harvest"]
    if harvest["state"] == "missing":
        coverage.append("the memory harvest has no result yet (%s); the harvest job has not shipped" % harvest["where"])
    elif harvest["state"] != "read":
        coverage.append(gap(harvest, "the memory harvest's last result"))
    else:
        c = harvest["counts"]
        notes.append("Memory harvest: outcome %s; %s." % (harvest["outcome"], ", ".join("%s %d" % (k, c[k]) for k in HARVEST_COUNTS if k in c)))
        if harvest["outcome"] == "failed":
            findings.append(finding("harvest-failed", "memory-harvest", "high", "the memory harvest's last run failed"))
        if "listed" in c and c.get("total"):
            if abs(c["listed"] - c["total"]) > DRIFT * c["total"]:
                findings.append(finding("harvest-drift", "memory-harvest", "medium",
                                        "the memory harvest listed %d records against the tier's %d, more than 1%% apart" % (
                                            c["listed"], c["total"])))
        else:
            coverage.append("the memory harvest's result names no listed and total counts")
    for name in sorted(k for k in facts if k.startswith("bosun:")):
        host, read = name[len("bosun:"):], facts[name]
        if read["state"] != "read":
            coverage.append(gap(read, "the Bosun result on %s" % host))
            continue
        archive = read["archive"]
        if archive is None or not archive["reached"] or not read["date"]:
            coverage.append("the Bosun result on %s (%s) %s" % (host, read["date"], "has no archive section" if archive is None
                                                                  else "says the archive could not be read" if not archive["reached"]
                                                                  else "has no date"))
            continue
        gaps = archive.get("missing", 0) + archive.get("mismatched", 0)
        seen = dict(nights.get(host) or {})
        seen[read["date"]] = gaps
        nights[host] = dict(sorted(seen.items())[-NIGHTS_KEPT:])
        notes.append("Bosun %s (%s): archive holds %s of %s session logs; %s pending, %s missing, %s out of date, %s withheld." % (
            host, read["date"], archive.get("archived"), archive.get("checked"), archive.get("pending"),
            archive.get("missing"), archive.get("mismatched"), archive.get("withheld")))
        last_two = sorted(nights[host].items())[-2:]
        if len(last_two) == 2 and last_two[1][0] == read["date"] and all(n > 0 for _, n in last_two):
            findings.append(finding("archive-gap", host, "high",
                                    "%s: the archive misses or holds an out-of-date copy of %d session logs on %s, and of %d on %s" % (
                                        host, last_two[1][1], last_two[1][0], last_two[0][1], last_two[0][0])))
    prep = facts["prep"]
    if prep["state"] != "read":
        coverage.append(gap(prep, "the local-jev prep store's ready.json"))
    elif stamp(prep["finished"]) is None:
        coverage.append("the local-jev prep store's ready.json has no readable finished time (%s)" % prep["where"])
    else:
        notes.append("Prep store: finished %s, %s rows." % (prep["finished"], prep["rows"]))
        if now - stamp(prep["finished"]) > PREP_HOURS * 3600:
            findings.append(finding("prep-stale", "local-jev-prep", "medium",
                                    "the local-jev prep store last finished %s, more than %d hours ago" % (prep["finished"], PREP_HOURS)))
    weekly = facts["weekly"]
    if weekly["state"] != "read":
        coverage.append(gap(weekly, "the weekly retrain history"))
    else:
        rec = weekly["newest"]
        started = stamp(rec["started"]) if rec else None
        if rec:
            notes.append("Weekly retrain: newest run %s started %s, status %s." % (rec["run"], rec["started"], rec["status"]))
        if started is None or now - started > RETRAIN_DAYS * 86400:
            findings.append(finding("retrain-missed", "weekly:%s:missed" % (rec or {}).get("run"), "medium",
                                    "no weekly retrain started in the last %d days (newest: %s)" % (
                                        RETRAIN_DAYS, "run %s, started %s" % (rec["run"], rec["started"]) if rec else "none")))
        elif rec["status"] == "failed":
            findings.append(finding("retrain-missed", "weekly:%s:failed" % rec["run"], "medium",
                                    "the weekly retrain %s, started %s, failed" % (rec["run"], rec["started"])))
    judge_read = facts["judge"]
    if judge_read["state"] != "read":
        coverage.append(gap(judge_read, "the judge's results folder"))
    else:
        notes.append("Judge: %d evaluation results, newest %s." % (judge_read["count"], judge_read["newest"]))
    rank = {"high": 0, "medium": 1, "low": 2}
    findings.sort(key=lambda f: (rank[f["severity"]], f["class"], f["subject"]))
    return findings, coverage, notes, nights


# ---- the lane's records, shared with fm-officer-library.py.

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


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        return doc if isinstance(doc, type(default)) else default
    except (OSError, ValueError):
        return default


def mark_new(out, key, findings):
    """Sets each finding's `new` from the lane's reported.json and rewrites it; returns the count of new ones."""
    path = os.path.join(out, "reported.json")
    ledger = read_json(path, {})
    kept = {}
    for f in findings:
        kept[f["fingerprint"]] = ledger.get(f["fingerprint"], key)
        f["new"] = kept[f["fingerprint"]] == key
    write_if_changed(path, json.dumps(kept, sort_keys=True, indent=1) + "\n")
    return sum(1 for f in findings if f["new"])


def render_md(doc):
    lines = ["# Corpus officer digest for %s" % doc["date"], "",
             "%d new finding(s) of %d open. Counts, timestamps and names only; no transcript, corpus row or memory record was read." % (
                 doc["actionable"], len(doc["findings"])), "", "## Findings", ""]
    for f in doc["findings"]:
        lines.append("- %s[%s] %s %s: %s" % ("NEW " if f["new"] else "", f["severity"], f["class"], f["subject"], f["summary"]))
    if not doc["findings"]:
        lines.append("- None.")
    lines += ["", "## Corpus", ""] + ["- " + n for n in doc["notes"]]
    if doc["coverage"]:
        lines += ["", "## Coverage gaps", ""] + ["- " + c for c in doc["coverage"]]
    return "\n".join(lines) + "\n"


def run(args):
    now = args.now if args.now is not None else int(time.time())
    host, root = split(args.archive.rstrip("/"))
    harvest_host, harvest = split(args.harvest) if args.harvest else (host, root + "/memory-harvest/last-result.json")
    prep_host, prep = split(args.prep)
    jev_host, jev = split(args.local_jev.rstrip("/"))
    items = {"ingest": (host, "ingest", root + "/transcript-archive"),
             "harvest": (harvest_host, "harvest", harvest),
             "prep": (prep_host, "prep", prep),
             "weekly": (jev_host, "weekly", jev + "/results/weekly/history.jsonl"),
             "judge": (jev_host, "judge", jev + "/results/judge")}
    for h in [h for h in (x.strip() for x in args.hosts.split(",")) if h]:
        items["bosun:" + h] = (h, "bosun", BOSUN_RESULT)
    facts = gather(items)
    os.makedirs(args.out, exist_ok=True)
    nights_path = os.path.join(args.out, "nights.json")
    findings, coverage, notes, nights = judge(facts, read_json(nights_path, {}), now)
    write_if_changed(nights_path, json.dumps(nights, sort_keys=True, indent=1) + "\n")
    new = mark_new(args.out, args.date, findings)
    doc = {"officer_role": "corpus", "date": args.date, "actionable": new, "findings": findings,
           "coverage": coverage, "notes": notes, "facts": facts}
    write_if_changed(os.path.join(args.out, args.date + ".json"),
                     json.dumps(doc, sort_keys=True, indent=1, ensure_ascii=False) + "\n")
    write_if_changed(os.path.join(args.out, args.date + ".md"), render_md(doc))
    for c in coverage:
        print("Coverage gap: corpus: %s" % c)
    print("DIGEST %s %d %s.md" % (args.date, new, args.date))
    return 0


def main(argv):
    if argv[:1] == ["probe"]:
        json.dump(probe([tuple(a.split("=", 1)) for a in argv[1:]]), sys.stdout, sort_keys=True)
        return 0
    parser = argparse.ArgumentParser(prog="fm-officer-corpus.py")
    parser.add_argument("action", choices=["run"])
    parser.add_argument("--archive", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--hosts", default="")
    parser.add_argument("--harvest")
    parser.add_argument("--prep", default=DEFAULT_PREP)
    parser.add_argument("--local-jev", default=DEFAULT_LOCAL_JEV)
    parser.add_argument("--now", type=int)
    args = parser.parse_args(argv)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}(T\d{2})?", args.date):
        parser.error("--date must be YYYY-MM-DD or YYYY-MM-DDTHH")
    return run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
