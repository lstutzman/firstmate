#!/usr/bin/env python3
"""fm-officer-corpus.py - the corpus officer's daily pass over the agent training corpus.

Run only through `bin/fm-officer.sh run <id>`, which owns the officer
contract; docs/configuration.md "Corpus officer" owns the registry fields.

Usage:
  fm-officer-corpus.py run --archive <dir|host:dir> --date <YYYY-MM-DD> --out <lane-dir>
                           [--hosts a,b] [--harvest <path|host:path>] [--prep <path|host:path>]
                           [--local-jev <dir|host:dir>] [--now <epoch>]
                           [--writes none|linear] [--team PC] [--max-creates <n>]
                           [--max-linear-calls <n>] [--rubric <file>] [--jev <jev.py>]
                           [--fm-home <dir>] [--start-home <home>=<projects>[=<role>[=<mandate>]]]...

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
  harvest  --harvest, default <archive>/memory-harvest/last-result.json, as
           memory_harvest.py writes it: `result` (ok, partial or failed) and the
           flat counts listed, tier_total (the tier's own total, null when the
           backend gives none), written, withheld, deleted and superseded. A
           file without a known `result` is unreadable; a missing file is a
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
  harvest-failed  the harvest's result is failed; a partial run is left to
                  harvest-drift.
  harvest-drift   listed and tier_total differ by more than 1% of total.
  prep-stale      the prep store finished more than PREP_HOURS hours ago.
  retrain-missed  the newest weekly retrain started more than RETRAIN_DAYS
                  days ago, there is none, or it failed.

A finding is reported once: reported.json maps each open fingerprint to the
run key that first reported it, a finding counts as new only at that key, and
a fingerprint that clears is dropped, so a recurrence after a fix is new
again. A fingerprint whose input was a coverage gap this run is kept, not
cleared, so an outage does not re-report it. Re-running a key on unchanged inputs with the same --now writes identical
bytes: only the digest's generated_at holds the clock; every other output holds
source timestamps and thresholds.

Linear. The officer follows the shared officer contract (docs/officers/contract.md;
bin/fm-officer-linear.py owns the mechanics) with its rubric docs/officers/corpus-rubric.md,
which owns what counts as work, how a finding is scored and what starts. With
--writes linear (the registry's `writes: linear`, with max-creates, max-linear-calls and
jev) every open finding is filed in team PC as a Chore, Source label agent, in the Fleet
project with the area:fleet label, searched for first by its `corpus-fp:<sha256>` marker and
then by title with local-jev, and every night it is still open raises the item's Found line
once. The item body holds only the finding's class, subject, severity and the summary built
above from counts, timestamps and names, never a transcript, a corpus row or a memory record.
A finding whose item exists and whose score reaches the rubric minimum gets a start request in
`start_requests` (and, for this home, a <date>.start-requests.sh handoff), addressed to the
--start-home office whose dispatch list names its repository (transcript-archive for the
ingester, archive and harvest, local-jev for the prep store and the retrain), else to
--fm-home; no office dispatches either repository until the Alchemist is registered. A finding
whose fix may touch the scan gate (an archive gap, a failed or drifting harvest: scrub.py, the
re-scan in archive.py, private-projects.json or pii_gate.py) says so in its start request:
the corpus-owning office never merges that pull request, it goes to Slarti on a fresh
reviewer's no-loosening record. A finding that matches a reserved class is held as one keyed
needs-decision `corpus-holds-<date>`. The lane keeps filed-fingerprints.json, found.json and
review-state.json only when it writes.

Outputs <date>.json and <date>.md in --out, prints one `Coverage gap:` line
per gap and `DIGEST <date> <n-new> <date>.md` last.
"""

import argparse
import collections
import datetime
import hashlib
import importlib.util
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
HARVEST_OUTCOMES = ("ok", "partial", "failed")
HARVEST_COUNTS = ("listed", "tier_total", "written", "withheld", "deleted", "superseded")
BOSUN_COUNTS = ("checked", "archived", "pending", "missing", "mismatched", "withheld")
RUBRIC_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "officers", "corpus-rubric.md")
TYPE_LABEL = "Chore"
SOURCE_LABEL = "agent"
# Per finding class: the repository its fix lands in, whether the fix may touch the scan gate, and what a start asks for.
CLASSES = {
    "not-collected": ("transcript-archive", False, "Find why the ingester does not collect this source and restore it."),
    "archive-gap": ("transcript-archive", True, "Find why the archive misses or holds an out-of-date copy of session logs on this host and close the gap."),
    "harvest-failed": ("transcript-archive", True, "Find why the memory harvest failed and make it run to completion."),
    "harvest-drift": ("transcript-archive", True, "Find why the memory harvest lists fewer or more records than the tier holds and make them agree."),
    "prep-stale": ("local-jev", False, "Find why the prep store stopped refreshing and restart it."),
    "retrain-missed": ("local-jev", False, "Find why the weekly retrain did not run or failed and get it running."),
}
SCAN_GATE_ROUTE = ("This fix may touch the scan gate (scrub.py, the re-scan in archive.py, private-projects.json or pii_gate.py). "
                   "Open the pull request as usual, but the corpus-owning office never merges it: it goes to Slarti, who merges it on green "
                   "once a fresh reviewer records on it that it loosens no check; a change that loosens, skips or deletes a check needs Lee's word.")


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
    if doc.get("result") not in HARVEST_OUTCOMES:
        raise ValueError("no known result field")  # the writer's schema only: never guess
    return {"outcome": doc["result"], "counts": _ints(doc, HARVEST_COUNTS)}


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


def finding(source, klass, subject, severity, summary):
    return {"class": klass, "subject": subject, "severity": severity, "summary": summary,
            "source": source, "fingerprint": fingerprint(klass, subject)}


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
    """(findings, coverage, notes, nights, unread) from the probe results; nights is the updated
    nights.json, and unread names each finding source this run could not judge."""
    findings, coverage, notes, unread = [], [], [], set()
    ingest = facts["ingest"]
    if ingest["state"] != "read":
        unread.add("ingest")
        coverage.append(gap(ingest, "the ingester's last result"))
    else:
        c = ingest["counts"]
        notes.append("Ingester: outcome %s; %s." % (ingest["outcome"], ", ".join("%s %d" % (k, c[k]) for k in INGEST_COUNTS if k in c)))
        runs = ingest["runs"]
        if not runs:
            unread.add("ingest")
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
                    findings.append(finding("ingest", "not-collected", source, "medium",
                                            "%s was not collected in the last %d%s runs (newest finished %s)" % (
                                                source, streak, " or more" if streak == len(runs) else "",
                                                latest["finished"])))
            if latest["offline"]:
                notes.append("Hosts offline in the newest ingester run: %s." % ", ".join(latest["offline"]))
    harvest = facts["harvest"]
    if harvest["state"] != "read":
        unread.update(("harvest", "harvest-counts"))
    if harvest["state"] == "missing":
        coverage.append("the memory harvest has no result yet (%s); the harvest job has not shipped" % harvest["where"])
    elif harvest["state"] != "read":
        coverage.append(gap(harvest, "the memory harvest's last result"))
    else:
        c = harvest["counts"]
        notes.append("Memory harvest: outcome %s; %s." % (harvest["outcome"], ", ".join("%s %d" % (k, c[k]) for k in HARVEST_COUNTS if k in c)))
        if harvest["outcome"] == "failed":
            findings.append(finding("harvest", "harvest-failed", "memory-harvest", "high", "the memory harvest's last run failed"))
        if "listed" in c and "tier_total" in c:
            if c["tier_total"] and abs(c["listed"] - c["tier_total"]) > DRIFT * c["tier_total"]:
                findings.append(finding("harvest-counts", "harvest-drift", "memory-harvest", "medium",
                                        "the memory harvest listed %d records against the tier's %d, more than 1%% apart" % (
                                            c["listed"], c["tier_total"])))
        else:
            unread.add("harvest-counts")
            coverage.append("the memory harvest's result names no %s count" % " or ".join(k for k in ("listed", "tier_total") if k not in c))
    for name in sorted(k for k in facts if k.startswith("bosun:")):
        host, read = name[len("bosun:"):], facts[name]
        if read["state"] != "read":
            unread.add(name)
            coverage.append(gap(read, "the Bosun result on %s" % host))
            continue
        archive = read["archive"]
        if archive is None or not archive["reached"] or not read["date"]:
            unread.add(name)
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
            findings.append(finding(name, "archive-gap", host, "high",
                                    "%s: the archive misses or holds an out-of-date copy of %d session logs on %s, and of %d on %s" % (
                                        host, last_two[1][1], last_two[1][0], last_two[0][1], last_two[0][0])))
    prep = facts["prep"]
    if prep["state"] != "read":
        unread.add("prep")
        coverage.append(gap(prep, "the local-jev prep store's ready.json"))
    elif stamp(prep["finished"]) is None:
        unread.add("prep")
        coverage.append("the local-jev prep store's ready.json has no readable finished time (%s)" % prep["where"])
    else:
        notes.append("Prep store: finished %s, %s rows." % (prep["finished"], prep["rows"]))
        if now - stamp(prep["finished"]) > PREP_HOURS * 3600:
            findings.append(finding("prep", "prep-stale", "local-jev-prep", "medium",
                                    "the local-jev prep store last finished %s, more than %d hours ago" % (prep["finished"], PREP_HOURS)))
    weekly = facts["weekly"]
    if weekly["state"] != "read":
        unread.add("weekly")
        coverage.append(gap(weekly, "the weekly retrain history"))
    else:
        rec = weekly["newest"]
        started = stamp(rec["started"]) if rec else None
        if rec:
            notes.append("Weekly retrain: newest run %s started %s, status %s." % (rec["run"], rec["started"], rec["status"]))
        if started is None or now - started > RETRAIN_DAYS * 86400:
            findings.append(finding("weekly", "retrain-missed", "weekly:%s:missed" % (rec or {}).get("run"), "medium",
                                    "no weekly retrain started in the last %d days (newest: %s)" % (
                                        RETRAIN_DAYS, "run %s, started %s" % (rec["run"], rec["started"]) if rec else "none")))
        elif rec["status"] == "failed":
            findings.append(finding("weekly", "retrain-missed", "weekly:%s:failed" % rec["run"], "medium",
                                    "the weekly retrain %s, started %s, failed" % (rec["run"], rec["started"])))
    judge_read = facts["judge"]
    if judge_read["state"] != "read":
        coverage.append(gap(judge_read, "the judge's results folder"))
    else:
        notes.append("Judge: %d evaluation results, newest %s." % (judge_read["count"], judge_read["newest"]))
    rank = {"high": 0, "medium": 1, "low": 2}
    findings.sort(key=lambda f: (rank[f["severity"]], f["class"], f["subject"]))
    return findings, coverage, notes, nights, unread


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


def mark_new(out, key, findings, unread):
    """Sets each finding's `new` from the lane's reported.json and rewrites it; returns the count of new ones.

    reported.json maps a fingerprint to the key that first reported it and the finding's source; an
    entry whose source is in `unread` was not judged this run, so it is kept rather than cleared."""
    path = os.path.join(out, "reported.json")
    ledger = {fp: e for fp, e in read_json(path, {}).items() if isinstance(e, dict)}
    kept = {fp: e for fp, e in ledger.items() if e.get("source") in unread}
    for f in findings:
        kept[f["fingerprint"]] = {"key": ledger.get(f["fingerprint"], {}).get("key", key), "source": f["source"]}
        f["new"] = kept[f["fingerprint"]]["key"] == key
    write_if_changed(path, json.dumps(kept, sort_keys=True, indent=1) + "\n")
    return sum(1 for f in findings if f["new"])


# ---- Linear: the shared officer contract.

def _lib():
    mod = sys.modules.get("fm_officer_linear")
    if mod is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-officer-linear.py")
        spec = importlib.util.spec_from_file_location("fm_officer_linear", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        sys.modules["fm_officer_linear"] = mod
    return mod


def officer(lib):
    return lib.Officer("corpus", "Corpus officer", "Corpus officer", RUBRIC_FILE, tuple(CLASSES), project=lib.FLEET_PROJECT)


def lib_findings(lib, findings):
    """One shared-library finding per open corpus finding; its source is its class, which the rubric's start-sources names."""
    out = []
    for f in findings:
        lf = lib.make_finding(f["class"], "corpus", f["subject"], "%s: %s" % (f["class"], f["subject"]), f["summary"], "real",
                              f["severity"], False, {}, location=f["subject"])
        lf["item"] = f
        out.append(lf)
    return out


def description(lf, date, off, near=None, recurrence=None):
    """The Linear item body: class, subject, severity and the counts, timestamps and names of the summary; nothing else."""
    f = lf["item"]
    lines = ["Filed by the corpus officer from the %s corpus check." % date,
             "What it is for: keep the agent training corpus complete, scrubbed and current.",
             "Epic: not assigned; whoever triages this picks one.", "",
             "Severity: %s. Class: %s. Subject: %s." % (lf["severity"], f["class"], f["subject"]),
             off.found_line(1, date, date)]
    if recurrence:
        lines.append(recurrence)
    if near:
        lines.append("Near match (not treated as the same issue): %s, local-jev %.2f." % near)
    lines += ["Finding: %s." % f["summary"].rstrip("."), "Repository: %s." % CLASSES[f["class"]][0]]
    if CLASSES[f["class"]][1]:
        lines.append("Scan gate: the fix may touch the scan gate files, so its pull request goes to Slarti, never the corpus-owning office.")
    # No trailing newline: Linear trims it, and `create --verify` then reports a mismatch on a good create.
    return "\n".join(lines) + "\n%s:%s" % (off.marker, lf["fingerprint"])


def file_findings(lib, off, todo, args, date, out, ledger, found, jev, lin):
    """Files the findings highest score first; returns (writes done, why Linear stopped or None)."""
    filer = lib.Filer(off, lin, args.team, date, out, ledger, found, jev, args.max_creates)

    def stop(reason, rate_limited=False):
        for f in todo:
            f["filing"] = f["filing"] or {"action": "not-filed", "reason": reason}
        if rate_limited:
            lib.pause_for_rate_limit(out, args.now)
        return lib.summary_rows(todo), reason

    for f in todo:
        if f["fingerprint"] in ledger:
            f["filing"], f["issue_hint"] = {"action": "exists", "issue": ledger[f["fingerprint"]]}, ledger[f["fingerprint"]]
            filer.bumps.append(f)
    due = [f for f in filer.bumps if found.get("issues", {}).get(f["filing"]["issue"], {}).get("last") != date]
    if not any(not f["filing"] for f in todo) and not due:
        return lib.summary_rows(todo), None
    stopped = lib.paused_until(out, args.now)
    if stopped:
        return stop(stopped)
    try:
        names = lib.label_names(lin, args.team)
    except lib.LinearError as exc:
        return stop("label lookup failed: %s" % exc, exc.code == "RATE_LIMITED")

    def label_set(f):
        return lib.fleet_labels(SOURCE_LABEL, names, TYPE_LABEL)

    def describe(f, near=None, recurrence=None):
        return description(f, date, off, near, recurrence)

    try:
        for f in todo:
            if not f["filing"]:
                filer.file_single(f, label_set, describe)
        filer.settle_bumps(label_set, describe)
    except lib.LinearError as exc:
        if exc.code == "RATE_LIMITED":
            return stop("Linear rate limit reached: %s" % exc, True)
        return stop("%s; the next run continues from the ledger" % exc)
    return lib.summary_rows(todo), None


def linear_pass(args, date, findings, offices, main_home):
    """Files the open findings (writes: linear) and hands the ones the rubric admits to the owning office; returns digest fields."""
    lib = _lib()
    off = officer(lib)
    out, linear = args.out, args.writes == "linear"
    lin = lib.Linear(args.max_linear_calls)
    state = lib.read_json(os.path.join(out, lib.STATE_FILE), {})
    found = lib.read_json(os.path.join(out, lib.FOUND_FILE), {})
    ledger = lib.read_json(os.path.join(out, lib.LEDGER_FILE), {})
    todo = lib_findings(lib, findings)
    rubric = lib.load_rubric(args.rubric, off)
    jev = lib.Jev(args.jev)
    lib.apply_found(todo, found, ledger)
    writes, blocked = file_findings(lib, off, todo, args, date, out, ledger, found, jev, lin) if linear else ([], None)
    lib.apply_found(todo, found, ledger)
    for f in todo:
        repo, gate, what = CLASSES[f["item"]["class"]]
        f.update(start_what=what + (" " + SCAN_GATE_ROUTE if gate else ""),
                 start_row={"project": repo, "linear_only": False, "scan_gate": gate, "class": f["item"]["class"], "subject": f["item"]["subject"]})
    handled = state.setdefault("handled", {})
    starts, held, asks = lib.plan_starts(off, todo, rubric, date, args.writes, main_home, offices, handled)
    for rank, row in enumerate(starts, 1):
        row["rank"] = rank
    gaps = rubric.gaps + ([jev.gap] if jev.gap and linear else [])
    if linear:
        for name, doc in ((lib.LEDGER_FILE, ledger), (lib.STATE_FILE, state), (lib.FOUND_FILE, found)):
            lib.write_json(os.path.join(out, name), doc)
    for f in todo:
        f["item"]["linear"] = {"found": f["found"], "score": f["score"],
                               **{k: v for k, v in (f["filing"] or {}).items() if k in ("action", "issue", "reason", "found", "recurrence_of")}}
    return {"writes": args.writes, "writes_done": writes, "writes_blocked": blocked, "linear_calls": lin.n,
            "linear_call_budget": lin.budget, "linear_gaps": gaps, "not_filed": lib.not_filed_lines(todo),
            "start_requests": starts, "held": held, "asks_for_lee": asks}


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
    lines += ["", "## Linear", "",
              "Writes: %s; %d linear-axi call(s) of %d%s." % (
                  doc["writes"], doc["linear_calls"], doc["linear_call_budget"],
                  "; stopped: " + doc["writes_blocked"] if doc["writes_blocked"] else "")]
    lines += ["- " + n for n in doc["not_filed"] + doc["linear_gaps"]]
    lines += ["- Start request: %s (%s, score %.1f)%s." % (r["title"], r["issue"], r["score"], ", scan-gate route" if r["scan_gate"] else "")
              for r in doc["start_requests"]]
    lines += ["- " + a["line"] for a in doc["asks_for_lee"]]
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
    findings, coverage, notes, nights, unread = judge(facts, read_json(nights_path, {}), now)
    write_if_changed(nights_path, json.dumps(nights, sort_keys=True, indent=1) + "\n")
    new = mark_new(args.out, args.date, findings, unread)
    lib = _lib()
    args.now = now
    lib.check_common_args(argparse.ArgumentParser(prog="fm-officer-corpus.py"), args)
    linear = linear_pass(args, args.date, findings, lib.parse_start_homes(args.start_home), args.fm_home)
    doc = {"officer_role": "corpus", "source": "corpus-officer", "generated_at": lib.iso(now), "date": args.date, "actionable": new,
           "findings": findings, "coverage": coverage + linear["linear_gaps"], "notes": notes, "facts": facts, **linear}
    if args.fm_home:
        lib.progress.write_handoff(os.path.join(args.out, args.date + ".start-requests.sh"),
                                   [r["execute"] for r in linear["start_requests"] if r["execute"]["env"]["FM_HOME"] == args.fm_home])
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
    _lib().add_common_args(parser, RUBRIC_FILE)
    args = parser.parse_args(argv)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}(T\d{2})?", args.date):
        parser.error("--date must be YYYY-MM-DD or YYYY-MM-DDTHH")
    return run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
