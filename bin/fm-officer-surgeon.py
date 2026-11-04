#!/usr/bin/env python3
"""fm-officer-surgeon.py - the Ship's Surgeon's daily pass: triage, then intake.

Run only through `bin/fm-officer.sh run <id>`, which owns the officer contract;
docs/configuration.md "Officers" owns the registry schema and the officer-roles
skill owns what the Surgeon may and may never do.

Usage:
  fm-officer-surgeon.py run --archive <dir|host:dir> --date <YYYY-MM-DD> --out <lane-dir>
                            --app <https url> [--home <dir>]... [--hosts a,b] [--model none]
                            [--team PC] [--writes none|linear] [--max-creates 5]
                            [--area <label>] [--staging-repo <git remote>] [--now <epoch>]

Pass 1 is bin/fm-officer-triage.py's session join, unchanged (that script stays: the
friction pass imports it by path); its findings are kept under `archive_findings`.
Pass 2 is intake: read-only GETs of the fleet app's /api/runs (and, for each live
nightly E2E or code-review job, that job's latest result) and /api/sweeper-results.
Each finding is classified with the tables below and no model:

  nightly E2E failure   real, unless its triage class names flaky/load/host/infra or
                        its rerun alone passed (won't fix); needs a decision when the
                        class names product/spec/intended. Severity: high when
                        the run's `result.sha` is the staging tip (`git ls-remote
                        <--staging-repo> refs/heads/staging`, 30 s at most),
                        medium for an older run; with no sha or no readable tip,
                        medium and a `Coverage gap:` line.
  nightly review        critical, high, medium: real at severity high, medium, low;
                        a low finding is won't fix.
  sweeper bug           disposition new/regressed: real; unclear/idea or any
                        unknown disposition: needs a decision; duplicate,
                        fixed-live, noise: won't fix; fixed-staging-only:
                        needs a decision. Severity P1/critical/high: high;
                        P2/medium: medium; else low. The sweeper payload
                        carries no production-source marker, so the
                        production-error-class rule is deliberately absent
                        (never guessed from text) until the sweeper sends an
                        environment field.

A won't-fix finding is always low. A finding the source already put in Linear
(an `issue` on the nightly failure, a filing on the review finding, a Linear item
or `duplicate_of` on the sweeper bug) is `tracked`: reported, never filed again.
A real finding whose source gave no key has no stable fingerprint, so it is
reported and never filed.
`findings` holds the intake findings, so the `severity: high` the office lane
source reads means a high intake finding, not an archive coverage gap.

With --writes linear (and only then) every real, untracked finding is filed in
team PC, highest severity first, at most --max-creates attempts a run:
  1. one `label list --team PC`; Bug, the Source label (scheduled-review for the
     nightly E2E and review, bug-sweep for the sweeper) and --area must all exist
     there, or the finding is reported and not filed;
  2. `issue search "surgeon-fp:<sha256>"` (the finding's fingerprint, also kept in
     the lane's filed-fingerprints.json); Linear's search is fuzzy, so it is already
     filed only when one of the first three hits, read with `issue view`, has the
     marker in its description;
  3. `issue create --dry-run`, then `--verify`, with exactly one Type (Bug), one
     Source and one area label. A failed verify is logged and never retried.
It never edits, comments on, closes or deletes an item. One RATE_LIMITED answer
stops every Linear call in the run, writes linear-resume-after.json (one hour on)
and reports the rest as not filed; later runs skip Linear until then.

Outputs <date>.json and <date>.md in --out and prints
`DIGEST <date> <n-actionable> <date>.md` as its last stdout line, plus a
`Coverage gap:` line for each source it could not read and for a paused Linear.
"""

import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import time


def _triage():
    mod = sys.modules.get("fm_officer_triage")
    if mod is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-officer-triage.py")
        spec = importlib.util.spec_from_file_location("fm_officer_triage", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        sys.modules["fm_officer_triage"] = mod
    return mod


triage = _triage()

NOISE_WORDS = ("flaky", "load", "host", "infra")
DECISION_WORDS = ("product", "spec", "intended")
SWEEP_REAL = ("new", "regressed")
SWEEP_DECISION = ("unclear", "idea", "fixed-staging-only")
SWEEP_NOISE = ("duplicate", "fixed-live", "noise")
SWEEP_HIGH = ("p1", "critical", "high")
SWEEP_MEDIUM = ("p2", "medium")
REVIEW_SEVERITY = {"critical": "high", "high": "medium", "medium": "low"}
SOURCE_LABEL = {"nightly": "scheduled-review", "review": "scheduled-review", "sweeper": "bug-sweep"}
SOURCE_NAME = {"nightly": "nightly E2E", "review": "nightly code review", "sweeper": "bug sweeper"}
PRIORITY = {"high": "2", "medium": "3", "low": "3"}
RANK = {"high": 0, "medium": 1, "low": 2}
CANDIDATES_PER_CREATE = 5
EXISTING_VIEWS = 3
RESUME_FILE = "linear-resume-after.json"
LEDGER_FILE = "filed-fingerprints.json"
STAGING_REPO = "git@github.com:lstutzman/PropertyCompass2.git"


def staging_tip(repo):
    """The lowercase sha of <repo>'s staging branch, or None when it cannot be read."""
    try:
        proc = subprocess.run(["git", "ls-remote", repo, "refs/heads/staging"], capture_output=True, check=False,
                              timeout=30, stdin=subprocess.DEVNULL, env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))
    except (OSError, subprocess.TimeoutExpired):
        return None
    sha = proc.stdout.decode("utf-8", "replace").split("\t", 1)[0].strip().lower() if proc.returncode == 0 else ""
    return sha if re.fullmatch(r"[0-9a-f]{7,40}", sha) else None


def fetch(app, path):
    """(state, json): read (a JSON object), missing (404), unreachable or unreadable."""
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


def dicts(value):
    return [v for v in value if isinstance(v, dict)] if isinstance(value, list) else []


def text(value, limit=300):
    return " ".join(str(value if value is not None else "").split())[:limit]


def fingerprint(source, job, key):
    return hashlib.sha256(("%s\0%s\0%s" % (source, job, key)).encode("utf-8")).hexdigest()


def finding(source, job, key, title, summary, klass, severity, tracked, evidence):
    if klass == "wont-fix":
        severity = "low"
    return {"kind": "intake", "source": source, "job": job, "key": key, "title": text(title, 120),
            "summary": text(summary, 240), "class": klass, "severity": severity, "tracked": tracked,
            "fingerprint": fingerprint(source, job, key), "evidence": evidence, "filing": None}


def judge_nightly(job, detail, tip):
    shared = detail.get("shared")
    if not isinstance(shared, dict) or shared.get("status") != "failed":
        return []
    result = detail.get("result") if isinstance(detail.get("result"), dict) else {}
    sha = text(result.get("sha"), 64).lower()
    level = "high" if sha and tip and (sha.startswith(tip) or tip.startswith(sha)) else "medium"
    out = []
    for f in dicts(shared.get("findings")):
        label = (text(f.get("classification")) or "").lower()
        rerun = (text(f.get("rerun")) or "").lower()
        if any(w in label for w in NOISE_WORDS) or rerun.startswith("passed"):
            klass = "wont-fix"
        elif any(w in label for w in DECISION_WORDS):
            klass = "needs-decision"
        else:
            klass = "real"
        evidence = {"where": text(f.get("where")), "cause": text(f.get("cause")), "classification": f.get("classification"),
                    "rerun": f.get("rerun"), "release_blocking": f.get("release_blocking"), "run": job["run"],
                    "sha": sha or None, "staging_tip": tip}
        out.append(finding("nightly", job["id"], text(f.get("key"), 100), f.get("title"),
                           "%s: %s" % (text(f.get("title"), 100), text(f.get("cause"), 120)), klass,
                           level, text(f.get("issue")) or None, evidence))
    return out


def judge_review(job, detail):
    result = detail.get("result")
    if not isinstance(result, dict):
        return []
    filings = result.get("filings") if isinstance(result.get("filings"), dict) else {}
    filed = {text(x.get("finding"), 100): text(x.get("issue"), 20)
             for k in ("filed", "digested", "commented") for x in dicts(filings.get(k)) if text(x.get("finding"))}
    out = []
    for f in dicts(result.get("findings")):
        severity = REVIEW_SEVERITY.get(f.get("severity"))
        key = text(f.get("id"), 100)
        evidence = {"file": text(f.get("file")), "category": f.get("category"), "reviewer_severity": f.get("severity"),
                    "run": job["run"]}
        out.append(finding("review", job["id"], key, f.get("summary"), "%s (%s)" % (text(f.get("summary"), 160), text(f.get("file"), 60)),
                           "real" if severity else "wont-fix", severity or "low", filed.get(key) or None, evidence))
    return out


def judge_sweeper(doc):
    latest = doc.get("latest")
    run = latest.get("run") if isinstance(latest, dict) else None
    intake = run.get("intake") if isinstance(run, dict) else None
    if not isinstance(intake, dict):
        return []
    linear = intake.get("linear") if isinstance(intake.get("linear"), dict) else {}
    items = {text(i.get("fp"), 100): text(i.get("id"), 20)
             for k in ("filed", "updated", "cancelled", "dismissed") for i in dicts(linear.get(k)) if i.get("fp")}
    out = []
    for b in dicts(intake.get("bugs")):
        disposition = text(b.get("disposition")).lower()
        severity = text(b.get("severity")).lower()
        klass = ("real" if disposition in SWEEP_REAL else "wont-fix" if disposition in SWEEP_NOISE else "needs-decision")
        level = "high" if severity in SWEEP_HIGH else "medium" if severity in SWEEP_MEDIUM else "low"
        key = text(b.get("fp"), 100)
        evidence = {"disposition": disposition, "severity": b.get("severity"), "occurrences": b.get("occurrences"),
                    "cause": text(b.get("cause")), "run": run.get("run_id")}
        out.append(finding("sweeper", "pc-sweeper-intake", key, b.get("title"),
                           "%s (%s, %s)" % (text(b.get("title"), 140), disposition or "no disposition", b.get("severity") or "no severity"),
                           klass, level, items.get(key) or text(b.get("duplicate_of"), 20) or None, evidence))
    return out


def intake(app, staging_repo):
    """(findings, coverage gaps) from the fleet app; every read is a GET."""
    findings, gaps, tip = [], [], False
    state, runs = fetch(app, "/api/runs")
    if state != "read":
        gaps.append("fleet app /api/runs %s" % state)
    for job in dicts((runs or {}).get("jobs")):
        kind = (job.get("results") or {}).get("kind") if isinstance(job.get("results"), dict) else None
        record = job.get("lastDone") or job.get("latest")
        if kind not in ("e2e", "review") or not isinstance(record, dict) or not record.get("runId"):
            continue
        ref = {"id": text(job.get("id"), 64), "run": text(record.get("runId"), 128)}
        state, detail = fetch(app, "/api/runs/%s/results/%s" % (ref["id"], ref["run"]))
        if state != "read":
            gaps.append("fleet app result of %s %s" % (ref["id"], state))
            continue
        if kind == "review":
            findings += judge_review(ref, detail)
            continue
        if tip is False:
            tip = staging_tip(staging_repo)
        found = judge_nightly(ref, detail, tip)
        if found and not tip:
            gaps.append("staging tip unreadable from %s, so %s is rated medium" % (staging_repo, ref["id"]))
        elif found and not found[0]["evidence"]["sha"]:
            gaps.append("result of %s has no sha, so it is rated medium" % ref["id"])
        findings += found
    state, sweeps = fetch(app, "/api/sweeper-results")
    if state != "read":
        gaps.append("fleet app /api/sweeper-results %s" % state)
    else:
        findings += judge_sweeper(sweeps)
    findings.sort(key=lambda f: (RANK[f["severity"]], f["source"], f["job"], f["key"]))
    return findings, gaps


class LinearError(RuntimeError):
    def __init__(self, code, message):
        super().__init__("%s: %s" % (code, message))
        self.code = code


def linear(args):
    proc = subprocess.run(["linear-axi"] + args + ["--output", "json"], capture_output=True, check=False)
    try:
        doc = json.loads(proc.stdout.decode("utf-8"))
    except ValueError:
        raise LinearError("NO_JSON", "linear-axi %s returned no JSON (exit %d)" % (" ".join(args[0:2]), proc.returncode))
    if not doc.get("ok"):
        error = doc.get("error") or {}
        raise LinearError(error.get("code", "unknown"), str(error.get("message", ""))[:120])
    return doc.get("data") or {}


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def write_if_changed(path, body):
    try:
        with open(path, encoding="utf-8") as fh:
            if fh.read() == body:
                return
    except OSError:
        pass
    with open(path + ".tmp", "w", encoding="utf-8") as fh:
        fh.write(body)
    os.replace(path + ".tmp", path)


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def description(f, date):
    lines = ["Filed by the Ship's Surgeon from the %s %s results." % (date, SOURCE_NAME[f["source"]]),
             "What it is for: a finding no Linear item tracked yet, so it is not lost.",
             "Epic: not assigned; whoever triages this picks one.", "",
             "Severity: %s. Source job: %s." % (f["severity"], f["job"])]
    lines += ["%s: %s" % (k, text(v, 300)) for k, v in sorted(f["evidence"].items()) if v not in (None, "")]
    return "\n".join(lines) + "\nsurgeon-fp:%s\n" % f["fingerprint"]


def issue_id(data):
    issue = data.get("issue") if isinstance(data.get("issue"), dict) else data
    return text(issue.get("identifier"), 20) or "unknown"


def existing_issue(fingerprint, team):
    """The Linear item whose description carries the fingerprint, or None.

    Linear's search is fuzzy and returns no descriptions, so a hit counts only once its
    description holds the marker; the first EXISTING_VIEWS hits are read.
    """
    marker = "surgeon-fp:" + fingerprint
    for hit in dicts(linear(["issue", "search", marker, "--team", team, "--limit", "5"]).get("issues"))[:EXISTING_VIEWS]:
        ident = text(hit.get("identifier"), 20)
        issue = linear(["issue", "view", ident]).get("issue")
        if ident and isinstance(issue, dict) and marker in str(issue.get("description") or ""):
            return ident
    return None


def summary_rows(todo):
    return [dict(f["filing"], fingerprint=f["fingerprint"], title=f["title"], source=f["source"], severity=f["severity"])
            for f in todo if f["filing"]]


def file_findings(findings, args, date, out):
    """Files the real, untracked findings; returns (writes_done, why Linear was stopped or None)."""
    todo = [f for f in findings if f["class"] == "real" and not f["tracked"]]
    if not todo:
        return [], None
    resume = read_json(os.path.join(out, RESUME_FILE), {}).get("resume_after", 0)
    stopped = "Linear paused after a rate limit until %s" % iso(resume) if args.now < resume else None
    ledger_path = os.path.join(out, LEDGER_FILE)
    ledger = read_json(ledger_path, {})
    attempts = 0

    def stop(reason, rate_limited=False):
        for f in todo:
            f["filing"] = f["filing"] or {"action": "not-filed", "reason": reason}
        if rate_limited:
            write_if_changed(os.path.join(out, RESUME_FILE), json.dumps(
                {"resume_after": args.now + 3600, "resume_after_utc": iso(args.now + 3600)}) + "\n")
        return summary_rows(todo), reason

    for f in todo:
        if not f["key"]:
            f["filing"] = {"action": "not-filed", "reason": "source gave no stable key"}
        elif f["fingerprint"] in ledger:
            f["filing"] = {"action": "exists", "issue": ledger[f["fingerprint"]]}
    if stopped:
        return stop(stopped)
    if all(f["filing"] for f in todo):
        return summary_rows(todo), None
    try:
        labels = linear(["label", "list", "--team", args.team, "--limit", "250"])
    except LinearError as exc:
        return stop("label lookup failed: %s" % exc, exc.code == "RATE_LIMITED")
    names = {text(l.get("name")).lower() for l in dicts(labels.get("labels"))}
    for index, f in enumerate(f for f in todo if not f["filing"]):
        if attempts >= args.max_creates or index >= args.max_creates * CANDIDATES_PER_CREATE:
            f["filing"] = {"action": "not-filed", "reason": "over max-creates for this run"}
            continue
        wanted = ["Bug", SOURCE_LABEL[f["source"]], args.area]
        missing = [w for w in wanted if w.lower() not in names]
        if missing:
            f["filing"] = {"action": "not-filed", "reason": "label(s) not found in team %s: %s" % (args.team, ", ".join(missing))}
            continue
        body = os.path.join(out, ".surgeon-%s-%s.md" % (date, f["fingerprint"][:12]))
        try:
            found = existing_issue(f["fingerprint"], args.team)
            if found:
                ledger[f["fingerprint"]] = found
                f["filing"] = {"action": "exists", "issue": found}
                continue
            with open(body, "w", encoding="utf-8") as fh:
                fh.write(description(f, date))
            create = ["issue", "create", "--team", args.team, "--title", f["title"], "--body-file", body,
                      "--priority", PRIORITY[f["severity"]]]
            for label in wanted:
                create += ["--label", label]
            linear(create + ["--dry-run"])
            attempts += 1
            ledger[f["fingerprint"]] = issue_id(linear(create + ["--verify"]))
            f["filing"] = {"action": "created", "issue": ledger[f["fingerprint"]]}
        except LinearError as exc:
            f["filing"] = {"action": "failed", "reason": str(exc)}
            if exc.code == "RATE_LIMITED":
                write_if_changed(ledger_path, json.dumps(ledger, sort_keys=True, indent=1) + "\n")
                return stop("Linear rate limit reached: %s" % exc, True)
        finally:
            if os.path.exists(body):
                os.remove(body)
    write_if_changed(ledger_path, json.dumps(ledger, sort_keys=True, indent=1) + "\n")
    return summary_rows(todo), None


def render_md(doc, archive_md):
    head, _, rest = archive_md.partition("\n")
    lines = [head.replace("Triage officer digest", "Surgeon officer digest"), "", "Intake: %s." % (
        ", ".join("%s %d" % kv for kv in doc["intake"]["classes"].items()) or "nothing found")]
    lines.append("Linear writes: %s%s." % (doc["writes"], " (blocked: %s)" % doc["writes_blocked"] if doc["writes_blocked"] else ""))
    for gap in doc["intake"]["gaps"]:
        lines.append("Coverage gap: " + gap)
    lines += ["", "## Intake findings", ""]
    for f in doc["findings"]:
        filing = f["filing"] or {}
        tail = " [tracked %s]" % f["tracked"] if f["tracked"] else " [%s%s]" % (
            filing.get("action", "not filed"), " " + filing["issue"] if filing.get("issue") else "") if f["class"] == "real" else ""
        lines.append("- [%s] %s %s/%s: %s%s" % (f["severity"], f["class"], f["source"], f["job"], f["summary"], tail))
    if not doc["findings"]:
        lines.append("- None.")
    return "\n".join(lines) + "\n\n## Archive pass\n" + rest


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-officer-surgeon.py")
    parser.add_argument("action", choices=["run"])
    parser.add_argument("--archive", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--home", action="append", default=[])
    parser.add_argument("--hosts", default="")
    parser.add_argument("--model", default="none")
    parser.add_argument("--team", default="PC")
    parser.add_argument("--writes", choices=["none", "linear"], default="none")
    parser.add_argument("--max-creates", type=int, default=5)
    parser.add_argument("--area", default="")
    parser.add_argument("--staging-repo", default=STAGING_REPO)
    parser.add_argument("--now", type=int)
    args = parser.parse_args(argv)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.date):
        parser.error("--date must be YYYY-MM-DD")
    if not args.staging_repo:
        parser.error("--staging-repo must not be empty")
    if args.writes == "linear" and (args.team != "PC" or not args.area or args.max_creates < 1):
        parser.error("--writes linear needs --team PC, --area and --max-creates of at least 1")
    args.now = int(time.time()) if args.now is None else args.now
    remote = re.match(r"^([A-Za-z0-9][A-Za-z0-9._@-]*):(/.*)$", args.archive)
    try:
        scanned = triage.remote_scan(remote.group(1), remote.group(2), args.date) if remote \
            else triage.scan(args.archive, args.date)
        triage.require_harvested(scanned)
        homes = [triage.Home(h) for h in args.home]
        triage.join_sessions(scanned, homes)
        triage.classify_mates(scanned, homes)
        triage.score_sessions(scanned["sessions"], args.model)
    except (RuntimeError, ValueError) as exc:
        print("fm-officer-surgeon: %s" % exc, file=sys.stderr)
        return 1
    hosts = [h for h in (x.strip() for x in args.hosts.split(",")) if h]
    doc = triage.summarise(scanned, homes, hosts, args.model)
    archive_md = triage.render_md(doc)
    findings, gaps = intake(args.app, args.staging_repo)
    writes, blocked = file_findings(findings, args, args.date, args.out) if args.writes == "linear" else ([], None)
    classes = {}
    for f in findings:
        classes[f["class"]] = classes.get(f["class"], 0) + 1
    doc.update({
        "officer_role": "surgeon", "archive_findings": doc["findings"], "findings": findings,
        "intake": {"classes": dict(sorted(classes.items())), "gaps": gaps},
        "writes": args.writes, "writes_done": writes, "writes_blocked": blocked,
    })
    doc["actionable"] = sum(1 for f in findings + doc["archive_findings"] if f["severity"] in ("high", "medium"))
    write_if_changed(os.path.join(args.out, args.date + ".json"),
                     json.dumps(doc, sort_keys=True, indent=1, ensure_ascii=False) + "\n")
    write_if_changed(os.path.join(args.out, args.date + ".md"), render_md(doc, archive_md))
    for gap in gaps + ([blocked] if blocked else []):
        print("Coverage gap: " + gap)
    print("DIGEST %s %d %s.md" % (args.date, doc["actionable"], args.date))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
