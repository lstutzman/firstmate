#!/usr/bin/env python3
"""fm-officer-surgeon.py - the Ship's Surgeon's daily pass: triage, then intake.

Run only through `bin/fm-officer.sh run <id>`, which owns the officer contract;
docs/configuration.md "Officers" owns the registry schema, the officer-roles
skill owns what the Surgeon may and may never do, and docs/officers/surgeon-rubric.md
owns what counts as work, how it is scored and what starts by itself.

Usage:
  fm-officer-surgeon.py run --archive <dir|host:dir> --date <YYYY-MM-DD> --out <lane-dir>
                            --app <https url> [--home <dir>]... [--hosts a,b] [--model none]
                            [--team PC] [--writes none|linear] [--max-creates 100]
                            [--max-linear-calls 450] [--triage-label triage] [--area <ignored>]
                            [--staging-repo <git remote>] [--rubric <file>] [--jev <jev.py>]
                            [--fm-home <dir>] [--start-home <home>=<project,...>]... [--now <epoch>]

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
  nightly E2E invalid   a run whose shared or result status is invalid/skipped (or
                        invalid: true) is itself work: one real, critical,
                        promotion-blocking finding per day, never starts by itself.
  nightly review        critical, high, medium: real at severity high, medium, low;
                        a low finding is won't fix. Ids in the result's `resolved`
                        list (or findings whose status is resolved/fixed) are fixed,
                        not findings.
  sweeper bug           disposition new/regressed: real; unclear/idea or any
                        unknown disposition: needs a decision; duplicate,
                        fixed-live, noise: won't fix; fixed-staging-only:
                        needs a decision. Severity P1/critical/high: high;
                        P2/medium: medium; else low. When the bug (or the run's
                        intake) carries `environment: production` a non-won't-fix
                        finding moves up one step (low, medium, high, critical).
                        Production is never inferred from text; a payload with
                        no environment field gets no bump.

A won't-fix finding is always low. A finding the source already put in Linear (an
`issue` on the nightly failure, a filing on the review finding, a Linear item
or `duplicate_of` on the sweeper bug) is `tracked`: reported, never filed again.
A real finding whose source gave no key is fingerprinted from its normalised
title plus location (digits dropped), and filed like any other.
Each finding also carries `found` (times seen, from the item's Found line) and
`score` = severity weight x log2(1 + found), the priority lever the rubric names.
`findings` holds the intake findings, so the `severity: high` the office lane
source reads means a high intake finding, not an archive coverage gap.

With --writes linear (and only then) every real, untracked finding is filed in
team PC, highest score first:
  1. one `label list --team PC`; Bug, the Source label (scheduled-review for the
     nightly E2E and review, bug-sweep for the sweeper) and one area label must all
     exist there. The area label comes from the finding's file path or component
     (AREA_RULES); with no fit it is --triage-label; a label missing from team PC
     means the finding is reported and not filed. The Surgeon never creates a label.
  2. medium or higher findings, and every non-review finding, each get their own
     item. Low review findings are clustered, one item per component: the group of
     the first CLUSTER_PARTS directory parts of the file, split one level deeper
     when a group passes CLUSTER_SPLIT_OVER findings, subgroups under
     CLUSTER_MIN_SUBGROUP folded into "<parent> (other)", groups under
     CLUSTER_MIN_GROUP folded into "<first part> (misc)". A finding keeps its
     cluster once assigned (review-state.json), so the key stays stable. The item
     lists every finding (fingerprint, title, file) as a tick box; a new finding
     updates the item, and a finding on the reviewer's resolved list is ticked.
  3. dedupe, in order: the fingerprint (`issue search "surgeon-fp:<sha256>"`, read
     with `issue view`, plus the lane's filed-fingerprints.json); then a text
     search of the title, each candidate asked of local-jev ("same issue?"), a
     duplicate only at confidence > JEV_SAME. A lower near match is noted in the
     new item. Without local-jev, only the fingerprint decides.
  4. a duplicate bumps the existing item's one machine-maintained line
     `Found: N times (first <date>, last <date>, by surgeon)` in place
     (`issue update --dry-run`, then `--verify`), at most once a day per item, and
     adds one comment on that first sighting. A finding already on its own
     cluster's list is not a new sighting.
  5. `issue create --dry-run`, then `--verify`, with exactly one Type (Bug), one
     Source and one area label. A failed verify is never retried; if the fingerprint
     search finds the item within a few seconds, it counts as created (and is ledgered), else it is logged failed.
It never closes or deletes an item. Every linear-axi call is counted; --max-linear-calls
stops the run's Linear work (the next run continues from the ledger). --max-creates bounds
new items a run. One RATE_LIMITED answer stops every Linear call in the run, writes
linear-resume-after.json (one hour on) and reports the rest as not filed; later runs
skip Linear until then. Nothing is dropped silently: the digest names what was not filed.

Start requests: a real, untracked, newly filed finding whose severity and source the
rubric admits, whose score reaches the rubric's minimum, and that matches no reserved
class becomes a start request on the progress officer's path (start-requests.sh for this
home, `execute` entries for each --start-home office); the reserved classes become one
keyed needs-decision line (asks_for_lee). The rubric can only narrow.

Pattern memory (review and sweeper findings): one line per bad pattern with its safe form,
deduped by normalised title and then by local-jev; new patterns go in one batched start
request to the Navigator (quality-patterns.md), in the digest for memory capture (no
scriptable memory-tier path exists), and mechanical ones get a proposed lint rule.

Outputs <date>.json and <date>.md in --out and prints
`DIGEST <date> <n-actionable> <date>.md` as its last stdout line, plus a
`Coverage gap:` line for each source it could not read and for a paused Linear.
"""

import argparse
import collections
import datetime
import hashlib
import importlib.util
import json
import math
import os
import re
import subprocess
import sys
import time


def _load(name, filename):
    mod = sys.modules.get(name)
    if mod is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), filename)
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        sys.modules[name] = mod
    return mod


triage = _load("fm_officer_triage", "fm-officer-triage.py")
progress = _load("fm_officer_progress", "fm-officer-progress.py")

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
SEVERITIES = ("critical", "high", "medium", "low")
RANK = {s: i for i, s in enumerate(SEVERITIES)}
PRIORITY = {"critical": "1", "high": "2", "medium": "3", "low": "3"}
SEVERITY_WEIGHT = {"critical": 8, "high": 4, "medium": 2, "low": 1}
BUMP = {"low": "medium", "medium": "high", "high": "critical", "critical": "critical"}
# Clustering of low review findings (the rule main measured on the 4 Nov findings file).
CLUSTER_PARTS = 2
CLUSTER_SPLIT_OVER = 25
CLUSTER_MIN_SUBGROUP = 10
CLUSTER_MIN_GROUP = 3
DEFAULT_MAX_CREATES = 100
# A linear-axi call count, not an API request count (one call can be several requests). One single finding
# costs up to about 10 calls (fingerprint search and views, title search and views, dry-run, verify), a cluster
# about 6, so 450 covers roughly 50 to 80 items a run; a first real run should be watched against Linear's hourly limit.
DEFAULT_MAX_LINEAR_CALLS = 450
JEV_SAME = 0.85
JEV_NEAR = 0.5
JEV_CANDIDATES = 3
JEV_CALLS_MAX = 300
JEV_TIMEOUT = 20
START_MIN_SCORE = 4.0
PATTERN_BATCH = 40
EXISTING_VIEWS = 3
VERIFY_SEARCH_WAITS = (0, 0.5, 1.0)
RESUME_FILE = "linear-resume-after.json"
LEDGER_FILE = "filed-fingerprints.json"
STATE_FILE = "review-state.json"
FOUND_FILE = "found.json"
PATTERN_FILE = "patterns.json"
STAGING_REPO = "git@github.com:lstutzman/PropertyCompass2.git"
RUBRIC_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "officers", "surgeon-rubric.md")
JEV_DEFAULT = os.path.expanduser("~/.claude/skills/local-jev/jev.py")
PATTERN_TARGET = ".agents/skills/sdlc-review/references/quality-patterns.md"
DEFAULT_PROJECT = "PropertyCompass2"

# The reserved classes: always held, whatever a rubric says.
RESERVED = collections.OrderedDict([
    ("payments-billing", re.compile(r"\b(payments?|billing|invoices?|refunds?|stripe|direct debit)\b", re.I)),
    ("legal", re.compile(r"\b(terms (of|and) (service|use)|privacy policy|legal text|cookie banner|gdpr|licen[cs]e text)\b", re.I)),
    ("product", re.compile(r"\b(product decision|pricing|paywall|plan limits?)\b", re.I)),
    ("member-copy", re.compile(r"\b(copy|wording|microcopy|member-facing|user-facing text)\b", re.I)),
    ("credentials", re.compile(r"\b(credentials?|secrets?|api[- ]?keys?|passwords?|private key|token rotation)\b", re.I)),
    ("production-actions", re.compile(r"\b(production (deploy|restart|database|data|config|setting)s?|prod (deploy|restart)|deploy to production)\b", re.I)),
    ("data-rewriting", re.compile(r"\b(drop (table|column)|rename (column|table)|data[- ]rewriting|backfill|delete (rows|records)|truncate table)\b", re.I)),
])
BUILTIN_START_SEVERITIES = ("high", "critical")
BUILTIN_START_SOURCES = ("nightly", "review", "sweeper")

# Area labels from a finding's file path (first match whose label exists in team PC wins).
AREA_RULES = [(label, re.compile(rx)) for label, rx in (
    ("testing", r"(^|/)(tests?|__tests__|e2e|playwright|cypress)(/|$)|\.(spec|test)\.[a-z]+$|\be2e\b"),
    ("ci-cd", r"\.github/|(^|/)(workflows?|pipelines?)(/|$)|azure-pipelines|dockerfile|(^|/)\.?ci(/|$)"),
    ("infrastructure", r"(^|/)(infra|infrastructure|bicep|terraform|deploy|deployment|k8s|helm|scripts)(/|$)|\.bicep$"),
    ("calculators", r"calculator|(^|/)calcs?(/|$)|stamp[-_]?duty|mortgage"),
    ("deal-finder", r"deal[-_]?finder"),
    ("watchlist", r"watch[-_]?list"),
    ("portfolio", r"portfolio"),
    ("maps", r"(^|[/_-])maps?([/_.-]|$)"),
    ("property-data", r"property[-_]?data"),
    ("billing", r"billing|payment|stripe|subscription"),
    ("authentication", r"auth|login|oauth|jwt"),
    ("ingestion", r"ingest|importer|scrap|crawler|(^|/)feeds?(/|$)|\betl\b"),
    ("notifications", r"notif|mailer|email|alert"),
    ("api", r"(^|/)(controllers?|endpoints?|api|routes?|handlers?)(/|$)|controller\.cs$"),
    ("performance", r"perf|caching|(^|/)cache(/|$)"),
    ("ui-ux", r"(^|/)client(/|$)|\.(tsx|jsx|css|scss|html)$|(^|/)(components?|pages)(/|$)"),
)]
TEXT_AREA_LABELS = ("testing", "ci-cd", "calculators", "deal-finder", "watchlist", "portfolio", "maps", "property-data",
                    "billing", "authentication", "ingestion", "notifications", "performance")
MECHANICAL = re.compile(r"\b(unused|null (check|reference)|dispos|await|async void|\.result\b|string concat|sql|hard-?coded|"
                        r"console\.log|magic number|empty catch|missing using|swallow|unchecked|todo|dead (code|branch))", re.I)
FOUND_RE = re.compile(r"^Found: (\d+) times \(first (\d{4}-\d{2}-\d{2}), last (\d{4}-\d{2}-\d{2}), by [a-z-]+\)$", re.M)


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


def norm(value):
    """Lowercase words with digits dropped: stable across the numbers that vary run to run."""
    return " ".join(re.sub(r"[^a-z]+", " ", re.sub(r"\d+", "", str(value or "").lower())).split())


def fingerprint(source, job, key):
    return hashlib.sha256(("%s\0%s\0%s" % (source, job, key)).encode("utf-8")).hexdigest()


def finding(source, job, key, title, summary, klass, severity, tracked, evidence, location="", project="", fix="", special=None):
    if klass == "wont-fix":
        severity = "low"
    if key:
        fp = fingerprint(source, job, key)
    elif norm(title) or norm(location):
        fp = fingerprint(source, job, "norm:%s|%s" % (norm(title), norm(location)))
    else:
        fp = None
    return {"kind": "intake", "source": source, "job": job, "key": key, "keyless": not key, "title": text(title, 120),
            "summary": text(summary, 240), "class": klass, "severity": severity, "tracked": tracked,
            "fingerprint": fp, "evidence": evidence, "location": text(location, 200), "project": text(project, 80),
            "fix": text(fix, 200), "special": special, "found": 1, "score": 0.0, "filing": None}


def score_of(f):
    return round(SEVERITY_WEIGHT[f["severity"]] * math.log2(1 + max(1, f["found"])), 2)


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
                           level, text(f.get("issue")) or None, evidence, location=f.get("where") or "e2e",
                           project=f.get("repo") or f.get("project") or ""))
    return out


def e2e_invalid(detail):
    """Why the nightly E2E run itself is invalid (not a failed test), or None."""
    for holder in (detail.get("shared"), detail.get("result")):
        if isinstance(holder, dict) and (holder.get("invalid") is True or text(holder.get("status")).lower() in ("invalid", "skipped")):
            return text(holder.get("reason") or holder.get("invalid_reason") or holder.get("error") or holder.get("status") or "run invalid", 160)
    return None


def judge_review(job, detail):
    """(findings, fingerprints the reviewer marked resolved)."""
    result = detail.get("result")
    if not isinstance(result, dict):
        return [], []
    filings = result.get("filings") if isinstance(result.get("filings"), dict) else {}
    filed = {text(x.get("finding"), 100): text(x.get("issue"), 20)
             for k in ("filed", "digested", "commented") for x in dicts(filings.get(k)) if text(x.get("finding"))}
    resolved = set()
    for x in result.get("resolved") if isinstance(result.get("resolved"), list) else []:
        rid = text(x if isinstance(x, str) else x.get("id") or x.get("finding") if isinstance(x, dict) else "", 100)
        if rid:
            resolved.add(rid)
    out = []
    for f in dicts(result.get("findings")):
        key = text(f.get("id"), 100)
        if key in resolved or text(f.get("status") or f.get("state")).lower() in ("resolved", "fixed"):
            if key:
                resolved.add(key)
            continue
        severity = REVIEW_SEVERITY.get(f.get("severity"))
        evidence = {"file": text(f.get("file")), "category": f.get("category"), "reviewer_severity": f.get("severity"),
                    "run": job["run"]}
        out.append(finding("review", job["id"], key, f.get("summary"), "%s (%s)" % (text(f.get("summary"), 160), text(f.get("file"), 60)),
                           "real" if severity else "wont-fix", severity or "low", filed.get(key) or None, evidence,
                           location=f.get("file") or "", project=f.get("repo") or f.get("project") or "",
                           fix=f.get("fix") or f.get("recommendation") or f.get("suggestion") or f.get("remediation") or ""))
    return out, [fingerprint("review", job["id"], r) for r in sorted(resolved)]


def judge_sweeper(doc):
    latest = doc.get("latest")
    run = latest.get("run") if isinstance(latest, dict) else None
    intake_doc = run.get("intake") if isinstance(run, dict) else None
    if not isinstance(intake_doc, dict):
        return []
    linear_doc = intake_doc.get("linear") if isinstance(intake_doc.get("linear"), dict) else {}
    items = {text(i.get("fp"), 100): text(i.get("id"), 20)
             for k in ("filed", "updated", "cancelled", "dismissed") for i in dicts(linear_doc.get(k)) if i.get("fp")}
    out = []
    for b in dicts(intake_doc.get("bugs")):
        disposition = text(b.get("disposition")).lower()
        severity = text(b.get("severity")).lower()
        klass = ("real" if disposition in SWEEP_REAL else "wont-fix" if disposition in SWEEP_NOISE else "needs-decision")
        level = "high" if severity in SWEEP_HIGH else "medium" if severity in SWEEP_MEDIUM else "low"
        env = text(b.get("environment") or intake_doc.get("environment") or run.get("environment")).lower()
        if env in ("production", "prod") and klass != "wont-fix":
            level = BUMP[level]
        key = text(b.get("fp"), 100)
        evidence = {"disposition": disposition, "severity": b.get("severity"), "occurrences": b.get("occurrences"),
                    "cause": text(b.get("cause")), "run": run.get("run_id"), "environment": env or None}
        out.append(finding("sweeper", "pc-sweeper-intake", key, b.get("title"),
                           "%s (%s, %s)" % (text(b.get("title"), 140), disposition or "no disposition", b.get("severity") or "no severity"),
                           klass, level, items.get(key) or text(b.get("duplicate_of"), 20) or None, evidence,
                           location=b.get("file") or b.get("url") or b.get("page") or b.get("route") or "",
                           project=b.get("repo") or b.get("project") or "",
                           fix=b.get("fix") or b.get("recommendation") or ""))
    return out


def intake(app, staging_repo, date):
    """(findings, coverage gaps, fingerprints the reviewer marked resolved); every read is a GET."""
    findings, gaps, resolved, tip = [], [], [], False
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
            found, fixed = judge_review(ref, detail)
            findings += found
            resolved += fixed
            continue
        reason = e2e_invalid(detail)
        if reason:
            findings.append(finding(
                "nightly", ref["id"], "e2e-invalid:" + date, "Nightly E2E run invalid: promotion blocked (%s)" % date,
                "Nightly E2E run %s is invalid, not a test failure: %s" % (ref["run"], reason), "real", "critical", None,
                {"promotion_blocking": "yes", "invalid_reason": reason, "run": ref["run"]}, location="e2e nightly",
                special="e2e-invalid"))
            continue
        if not isinstance(detail.get("shared"), dict) and not isinstance(detail.get("result"), dict):
            gaps.append("no E2E input: result of %s has no readable content" % ref["id"])
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
    return findings, gaps, resolved


# ---- rubric -----------------------------------------------------------------------------

class Rubric:
    """What the rubric file allows; it can only narrow the built-in allowances."""

    def __init__(self):
        self.loaded = False
        self.start_severities = set()
        self.start_sources = set()
        self.min_score = START_MIN_SCORE
        self.pattern_memory = False
        self.gaps = []


def load_rubric(path):
    rubric = Rubric()
    try:
        with open(path, encoding="utf-8") as fh:
            body = fh.read()
    except OSError:
        rubric.gaps.append("rubric %s unreadable, so nothing starts by itself" % os.path.basename(path))
        return rubric
    section = body.partition("## Settings the code reads")[2]
    settings = {m.group(1): [v.strip().lower() for v in m.group(2).split(",") if v.strip()]
                for m in re.finditer(r"^- ([a-z-]+): *(.*?) *$", section, re.M)}
    rubric.loaded = True

    def narrow(key, allowed):
        asked = settings.get(key)
        if asked is None:
            return set(allowed)
        extra = [v for v in asked if v not in allowed]
        if extra:
            rubric.gaps.append("rubric %s names %s, which the code does not admit; ignored" % (key, ", ".join(extra)))
        return {v for v in asked if v in allowed}

    rubric.start_severities = narrow("start-severities", BUILTIN_START_SEVERITIES)
    rubric.start_sources = narrow("start-sources", BUILTIN_START_SOURCES)
    held = settings.get("hold-classes")
    if held is not None:
        missing = [c for c in RESERVED if c not in held]
        if missing:
            rubric.gaps.append("rubric hold-classes omits %s; held anyway" % ", ".join(missing))
    try:
        rubric.min_score = max(START_MIN_SCORE, float((settings.get("start-min-score") or [START_MIN_SCORE])[0]))
    except ValueError:
        rubric.gaps.append("rubric start-min-score is not a number; ignored")
    rubric.pattern_memory = (settings.get("pattern-memory") or ["on"])[0] != "off"
    return rubric


def reserved_class(f):
    haystack = " ".join([f["title"], f["summary"], f["location"], text(f["evidence"].get("cause"))])
    for name, rx in RESERVED.items():
        if rx.search(haystack):
            return name
    return None


# ---- area, clusters ---------------------------------------------------------------------

def area_for(location, words, names, fallback):
    """The area label for a finding: from its path, else its words, else the fallback; None if the label is absent."""
    loc = location.lower().replace("\\", "/")
    for label, rx in AREA_RULES:
        if label in names and loc and rx.search(loc):
            return label
    if not loc:
        lowered = words.lower()
        for label, rx in AREA_RULES:
            if label in TEXT_AREA_LABELS and label in names and rx.search(lowered):
                return label
    return fallback if fallback.lower() in names else None


def path_dirs(location):
    path = re.sub(r":\d+(:\d+)?$", "", location.replace("\\", "/")).strip()
    path = re.sub(r"^[a-z]+://[^/]+", "", path)
    return [p for p in path.split("/") if p and p not in (".", "..")][:-1]


def base_group(location):
    """The path-only cluster group: the first CLUSTER_PARTS directories of the file."""
    if not location:
        return "(no file)"
    return "/".join(path_dirs(location)[:CLUSTER_PARTS]) or "(root)"


def cluster_keys(locations):
    """{location: cluster key}: the path decides the group, the counts only split or fold it."""
    groups = collections.Counter(base_group(l) for l in locations)
    deeper = collections.Counter("/".join(path_dirs(l)[:CLUSTER_PARTS + 1]) for l in locations if l and len(path_dirs(l)) > CLUSTER_PARTS)
    raw = {}
    for loc in set(locations):
        group = base_group(loc)
        key = group
        if groups[group] > CLUSTER_SPLIT_OVER and loc and len(path_dirs(loc)) > CLUSTER_PARTS:
            sub = "/".join(path_dirs(loc)[:CLUSTER_PARTS + 1])
            key = sub if deeper[sub] >= CLUSTER_MIN_SUBGROUP else group + " (other)"
        elif groups[group] > CLUSTER_SPLIT_OVER:
            key = group + " (other)"
        raw[loc] = key
    sizes = collections.Counter(raw[l] for l in locations)
    return {loc: (key if sizes[key] >= CLUSTER_MIN_GROUP or key in ("(no file)", "(root)")
                  else (key.split("/")[0].replace(" (other)", "") + " (misc)")) for loc, key in raw.items()}


def plain_words(key):
    return " ".join(re.sub(r"[/_\-]+", " ", re.sub(r"([a-z])([A-Z])", r"\1 \2", key)).split())


# ---- linear -----------------------------------------------------------------------------

class LinearError(RuntimeError):
    def __init__(self, code, message):
        super().__init__("%s: %s" % (code, message))
        self.code = code
        self.message = message


CALLS = {"n": 0, "budget": DEFAULT_MAX_LINEAR_CALLS}


def linear(args):
    if CALLS["n"] >= CALLS["budget"]:
        raise LinearError("CALL_BUDGET", "Linear call budget of %d reached" % CALLS["budget"])
    CALLS["n"] += 1
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


def write_json(path, doc):
    write_if_changed(path, json.dumps(doc, sort_keys=True, indent=1, ensure_ascii=False) + "\n")


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_week(date):
    year, week, _ = datetime.date.fromisoformat(date).isocalendar()
    return "%d-W%02d" % (year, week)


def found_line(count, first, last):
    return "Found: %d times (first %s, last %s, by surgeon)" % (count, first, last)


def description(f, date, near=None):
    lines = ["Filed by the Ship's Surgeon from the %s %s results." % (date, SOURCE_NAME[f["source"]]),
             "What it is for: a finding no Linear item tracked yet, so it is not lost.",
             "Epic: not assigned; whoever triages this picks one.", "",
             "Severity: %s. Source job: %s." % (f["severity"], f["job"]), found_line(1, date, date)]
    if f.get("special") == "e2e-invalid":
        lines.append("Promotion-blocking: yes. No nightly E2E result can be read until this run is valid again.")
    if near:
        lines.append("Near match (not treated as the same issue): %s, local-jev %.2f." % near)
    lines += ["%s: %s" % (k, text(v, 300)) for k, v in sorted(f["evidence"].items()) if v not in (None, "")]
    if f["location"]:
        lines.append("Location: " + f["location"])
    # No trailing newline: Linear trims it, and `create --verify` then reports a mismatch on a good create.
    return "\n".join(lines) + "\nsurgeon-fp:%s" % f["fingerprint"]


def cluster_body(key, members, date):
    open_n = sum(1 for m in members.values() if m["state"] == "open")
    lines = ["Filed by the Ship's Surgeon from the %s results." % SOURCE_NAME["review"],
             "What it is for: the lower-severity code-review findings in %s, kept in one item so one change can work them together and none is lost." % plain_words(key),
             "Epic: not assigned; whoever triages this picks one.", "",
             "Component: %s. Open: %d of %d. A ticked box is a finding the reviewer has marked resolved." % (key, open_n, len(members))]
    for fp, m in sorted(members.items(), key=lambda kv: (kv[1]["file"], kv[1]["title"], kv[0])):
        lines.append("- [%s] surgeon-fp:%s %s (%s)" % ("x" if m["state"] == "fixed" else " ", fp, m["title"], m["file"] or "no file"))
    return "\n".join(lines) + "\nsurgeon-fp:%s" % fingerprint("review", "cluster", key)


def issue_id(data):
    issue = data.get("issue") if isinstance(data.get("issue"), dict) else data
    return text(issue.get("identifier"), 20) or "unknown"


def view_issue(ident, cache):
    if ident not in cache:
        issue = linear(["issue", "view", ident]).get("issue")
        cache[ident] = issue if isinstance(issue, dict) else {}
    return cache[ident]


def search_hits(query, team, limit):
    found = linear(["issue", "search", query, "--team", team, "--limit", str(limit)]).get("issues")
    return [text(h.get("identifier"), 20) for h in dicts(found) if h.get("identifier")]


def existing_issue(fp, team, cache):
    """The Linear item whose description carries the fingerprint, or None.

    Linear's search is fuzzy and returns no descriptions, so a hit counts only once its
    description holds the marker; the first EXISTING_VIEWS hits are read (once a run each).
    """
    marker = "surgeon-fp:" + fp
    for ident in search_hits(marker, team, 5)[:EXISTING_VIEWS]:
        if ident and marker in str(view_issue(ident, cache).get("description") or ""):
            return ident
    return None


class Jev:
    """local-jev's yes/no answer to "is this the same issue?"; None when it cannot answer."""

    def __init__(self, path):
        self.path, self.calls, self.dead, self.gap = path, 0, not path or not os.path.exists(path or ""), None
        if self.dead:
            self.gap = "local-jev not found at %s, so duplicates are found by fingerprint only" % (path or "(none)")

    def same(self, a, b, what="issue"):
        if self.dead:
            return None
        if self.calls >= JEV_CALLS_MAX:
            self.gap = "local-jev call cap of %d reached; later duplicate checks used fingerprints only" % JEV_CALLS_MAX
            return None
        self.calls += 1
        try:
            proc = subprocess.run(
                ["python3", self.path, "noul", "Is report B the same %s as report A (the same defect in the same place)?" % what,
                 "--true", "same %s" % what, "--false", "different %s" % what, "--state",
                 json.dumps({"report_a": a[:900], "report_b": b[:900]})],
                capture_output=True, check=False, timeout=JEV_TIMEOUT, stdin=subprocess.DEVNULL)
        except (OSError, subprocess.TimeoutExpired):
            self.dead, self.gap = True, "local-jev timed out, so duplicates are found by fingerprint only"
            return None
        if proc.returncode == 3:
            self.dead, self.gap = True, "local-jev unreachable, so duplicates are found by fingerprint only"
            return None
        try:
            return float(json.loads(proc.stdout.decode("utf-8"))["noul"])
        except (ValueError, KeyError, TypeError):
            self.gap = "local-jev returned an unreadable answer once"
            return None


def finding_text(f):
    return "%s\n%s\n%s" % (f["title"], f["summary"], f["location"])


def similar_issue(f, team, cache, jev):
    """(issue, confidence, near): a duplicate above JEV_SAME, else the best near match (or None)."""
    best = (None, 0.0)
    for ident in search_hits(f["title"], team, 5)[:JEV_CANDIDATES]:
        issue = view_issue(ident, cache)
        confidence = jev.same(finding_text(f), "%s\n%s" % (issue.get("title") or "", str(issue.get("description") or "")[:600]))
        if confidence is None:
            return None, 0.0, None
        if confidence > JEV_SAME:
            return ident, confidence, None
        if confidence > best[1]:
            best = (ident, confidence)
    return None, 0.0, (best[0], best[1]) if best[0] and best[1] >= JEV_NEAR else None


# ---- review state, found count ----------------------------------------------------------

def update_review_state(state, findings, resolved, date):
    """Tracks every real review finding (open or fixed) for the burn-down and the cluster ticks."""
    seen = state.setdefault("review", {})
    for f in findings:
        if f["source"] == "review" and f["class"] == "real" and f["fingerprint"]:
            seen.setdefault(f["fingerprint"], {"state": "open", "seen": date, "fixed_on": None})
    for fp in resolved:
        if fp in seen and seen[fp]["state"] == "open":
            seen[fp].update(state="fixed", fixed_on=date)


def burn_down(state, date):
    week = iso_week(date)
    rows = list(state.get("review", {}).values())
    return {"week": week, "open": sum(1 for r in rows if r["state"] == "open"),
            "new": sum(1 for r in rows if iso_week(r["seen"]) == week),
            "fixed": sum(1 for r in rows if r["fixed_on"] and iso_week(r["fixed_on"]) == week)}


def apply_found(findings, found, ledger):
    """Found count and score per finding; the list ends up highest score first."""
    issues = found.get("issues", {})
    for f in findings:
        item = issues.get(ledger.get(f["fingerprint"]) or "", {})
        f["found"] = max(1, item.get("count", 1))
        f["score"] = score_of(f)
    findings.sort(key=lambda f: (-f["score"], RANK[f["severity"]], f["source"], f["job"], f["key"], f["title"]))


def plan_clusters(clustered, state, ledger):
    """The cluster items to make or refresh: [{key, fp, members, body, sha, action, findings}]."""
    clusters = state.setdefault("clusters", {})
    assigned = {m: cfp for cfp, c in clusters.items() for m in c["members"]}
    keys = cluster_keys([f["location"] for f in clustered])
    desired = {cfp: {"key": c["key"], "members": {m: dict(v) for m, v in c["members"].items()}, "findings": []}
               for cfp, c in clusters.items()}
    # A file keeps its cluster: a new finding in a file already listed joins that item, whatever the counts now say.
    by_file = {}
    for cfp, c in sorted(clusters.items()):
        for member in c["members"].values():
            if member["file"]:
                by_file.setdefault(member["file"], cfp)
    for f in clustered:
        cfp = assigned.get(f["fingerprint"]) or by_file.get(f["location"])
        if cfp is None:
            key = keys[f["location"]]
            cfp = fingerprint("review", "cluster", key)
            desired.setdefault(cfp, {"key": key, "members": {}, "findings": []})
        member = desired[cfp]["members"].setdefault(f["fingerprint"], {"title": f["title"], "file": f["location"], "state": "open"})
        member["title"], member["file"] = f["title"], f["location"]
        desired[cfp]["findings"].append(f)
    review = state.get("review", {})
    plan = []
    for cfp, c in sorted(desired.items(), key=lambda kv: kv[1]["key"]):
        for m, member in c["members"].items():
            if review.get(m, {}).get("state") == "fixed":
                member["state"] = "fixed"
        body = cluster_body(c["key"], c["members"], "")
        sha = hashlib.sha256(body.encode("utf-8")).hexdigest()
        known = clusters.get(cfp)
        action = None if known and known.get("sha") == sha and cfp in ledger else "update" if cfp in ledger else "create"
        if not c["members"] or (not c["findings"] and action == "create"):
            continue
        plan.append({"key": c["key"], "fp": cfp, "members": c["members"], "body": body, "sha": sha,
                     "action": action, "findings": c["findings"]})
    return plan


# ---- filing -----------------------------------------------------------------------------

def summary_rows(todo):
    return [dict(f["filing"], fingerprint=f["fingerprint"], title=f["title"], source=f["source"], severity=f["severity"])
            for f in todo if f["filing"]]


class Filer:
    def __init__(self, args, date, out, ledger, found, jev):
        self.args, self.date, self.out, self.ledger, self.found, self.jev = args, date, out, ledger, found, jev
        self.cache, self.creates = {}, 0

    def _write_body(self, fp, body):
        path = os.path.join(self.out, ".surgeon-%s-%s.md" % (self.date, fp[:12]))
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        return path

    def create(self, fp, title, body, labels, priority):
        """(issue, created, verify error): a new item; the caller has already searched for the fingerprint."""
        path = self._write_body(fp, body)
        try:
            cmd = ["issue", "create", "--team", self.args.team, "--title", title, "--body-file", path, "--priority", priority]
            for label in labels:
                cmd += ["--label", label]
            linear(cmd + ["--dry-run"])
            self.creates += 1
            try:
                return issue_id(linear(cmd + ["--verify"])), True, None
            except LinearError as exc:
                if exc.code in ("RATE_LIMITED", "CALL_BUDGET"):
                    raise
                # --verify writes before it reads back, so the item may exist; a created item is never
                # reported failed or left out of the ledger.
                found = None
                try:
                    for wait in VERIFY_SEARCH_WAITS:
                        time.sleep(wait)
                        found = existing_issue(fp, self.args.team, self.cache)
                        if found:
                            break
                except LinearError as search_exc:
                    if search_exc.code in ("RATE_LIMITED", "CALL_BUDGET"):
                        raise
                    raise LinearError(exc.code, "%s (then fingerprint search failed: %s)" % (exc.message, search_exc))
                if not found:
                    raise
                return found, True, str(exc)
        finally:
            if os.path.exists(path):
                os.remove(path)

    def update_body(self, ident, fp, body):
        path = self._write_body(fp, body)
        try:
            linear(["issue", "update", ident, "--body-file", path, "--dry-run"])
            linear(["issue", "update", ident, "--body-file", path, "--verify"])
        finally:
            if os.path.exists(path):
                os.remove(path)
        self.cache.pop(ident, None)

    def bump(self, ident, f):
        """The first sighting of the day: the Found line up by one, plus one comment."""
        today = self.found.setdefault("issues", {}).setdefault(ident, {})
        if today.get("last") == self.date:
            return today.get("count", 1)
        issue = view_issue(ident, self.cache)
        desc = str(issue.get("description") or "")
        match = FOUND_RE.search(desc)
        if match and match.group(3) == self.date:
            today.update(count=int(match.group(1)), last=self.date)
            return today["count"]
        if match:
            count, first = int(match.group(1)) + 1, match.group(2)
            new = desc[:match.start()] + found_line(count, first, self.date) + desc[match.end():]
        else:
            count, first = 2, self.date
            new = desc.rstrip("\n") + "\n" + found_line(count, first, self.date)
        self.update_body(ident, f["fingerprint"], new)
        linear(["issue", "comment", ident, "--body", "Seen again on %s by the Ship's Surgeon (found %d times)." % (self.date, count), "--dry-run"])
        linear(["issue", "comment", ident, "--body", "Seen again on %s by the Ship's Surgeon (found %d times)." % (self.date, count), "--verify"])
        today.update(count=count, last=self.date)
        return count


def file_findings(findings, args, date, out, state, found, jev):
    """Files the real, untracked findings; returns (writes_done, why Linear was stopped or None)."""
    todo = [f for f in findings if f["class"] == "real" and not f["tracked"]]
    clustered = [f for f in todo if f["source"] == "review" and f["severity"] == "low" and f["fingerprint"]]
    clustered_ids = {id(f) for f in clustered}
    singles = [f for f in todo if id(f) not in clustered_ids]
    resume = read_json(os.path.join(out, RESUME_FILE), {}).get("resume_after", 0)
    stopped = "Linear paused after a rate limit until %s" % iso(resume) if args.now < resume else None
    ledger_path = os.path.join(out, LEDGER_FILE)
    ledger = read_json(ledger_path, {})
    filer = Filer(args, date, out, ledger, found, jev)
    plan = plan_clusters(clustered, state, ledger)
    bumps = []
    for c in plan:
        if not c["action"]:
            for f in c["findings"]:
                f["filing"] = {"action": "clustered", "issue": ledger[c["fp"]], "cluster": c["key"], "new": False}

    def stop(reason, rate_limited=False):
        for f in todo:
            f["filing"] = f["filing"] or {"action": "not-filed", "reason": reason}
        if rate_limited:
            write_if_changed(os.path.join(out, RESUME_FILE), json.dumps(
                {"resume_after": args.now + 3600, "resume_after_utc": iso(args.now + 3600)}) + "\n")
        save(ledger_path, ledger, state, found)
        return summary_rows(todo), reason

    for f in singles:
        if not f["fingerprint"]:
            f["filing"] = {"action": "not-filed", "reason": "no key, title or location to fingerprint"}
        elif f["fingerprint"] in ledger:
            f["filing"] = {"action": "exists", "issue": ledger[f["fingerprint"]]}
            f["issue_hint"] = ledger[f["fingerprint"]]
            bumps.append(f)
    due = [f for f in bumps if found.get("issues", {}).get(f["filing"]["issue"], {}).get("last") != date]
    if not any(not f["filing"] for f in todo) and not any(c["action"] for c in plan) and not due:
        return summary_rows(todo), None
    if stopped:
        return stop(stopped)
    try:
        labels = linear(["label", "list", "--team", args.team, "--limit", "250"])
    except LinearError as exc:
        return stop("label lookup failed: %s" % exc, exc.code == "RATE_LIMITED")
    names = {text(l.get("name")).lower() for l in dicts(labels.get("labels"))}

    def label_set(f, location, words):
        area = area_for(location, words, names, args.triage_label)
        wanted = ["Bug", SOURCE_LABEL[f["source"]], area or args.triage_label]
        missing = [w for w in wanted if w.lower() not in names]
        return wanted, missing

    def over_cap():
        return filer.creates >= args.max_creates

    order = [("single", f) for f in singles if not f["filing"] and RANK[f["severity"]] <= RANK["medium"]]
    order += [("cluster", c) for c in plan if c["action"]]
    order += [("single", f) for f in singles if not f["filing"] and RANK[f["severity"]] > RANK["medium"]]
    try:
        for kind, item in order:
            if kind == "single":
                f = item
                wanted, missing = label_set(f, f["location"], f["title"] + " " + f["summary"])
                if missing:
                    f["filing"] = {"action": "not-filed", "reason": "label(s) not found in team %s: %s" % (args.team, ", ".join(missing))}
                    continue
                if over_cap():
                    f["filing"] = {"action": "not-filed", "reason": "over max-creates for this run"}
                    continue
                try:
                    ident = existing_issue(f["fingerprint"], args.team, filer.cache)
                    if ident:
                        ledger[f["fingerprint"]] = ident
                        f["filing"], f["issue_hint"] = {"action": "exists", "issue": ident}, ident
                        bumps.append(f)
                        continue
                    near = None
                    if not jev.dead:
                        ident, confidence, near = similar_issue(f, args.team, filer.cache, jev)
                        if ident:
                            ledger[f["fingerprint"]] = ident
                            f["filing"], f["issue_hint"] = {"action": "duplicate", "issue": ident, "confidence": round(confidence, 2)}, ident
                            bumps.append(f)
                            continue
                    ident, created, verify = filer.create(f["fingerprint"], f["title"], description(f, date, near), wanted, PRIORITY[f["severity"]])
                    ledger[f["fingerprint"]] = ident
                    found.setdefault("issues", {})[ident] = {"count": 1, "last": date} if created else found.get("issues", {}).get(ident, {})
                    f["filing"] = {"action": "created" if created else "exists", "issue": ident}
                    f["issue_hint"] = ident
                    if verify:
                        f["filing"]["verify"] = verify
                    if near:
                        f["filing"]["near_match"] = {"issue": near[0], "confidence": round(near[1], 2)}
                except LinearError as exc:
                    if exc.code in ("RATE_LIMITED", "CALL_BUDGET"):
                        f["filing"] = {"action": "failed", "reason": str(exc)}
                        raise
                    f["filing"] = {"action": "failed", "reason": str(exc)}
            else:
                c = item
                wanted, missing = label_set({"source": "review"}, c["key"], c["key"])
                title = "Code review findings: %s" % plain_words(c["key"])
                try:
                    if missing:
                        reason = "label(s) not found in team %s: %s" % (args.team, ", ".join(missing))
                        for f in c["findings"]:
                            f["filing"] = {"action": "not-filed", "reason": reason}
                        continue
                    action, ident = c["action"], ledger.get(c["fp"])
                    if not ident and over_cap():
                        for f in c["findings"]:
                            f["filing"] = {"action": "not-filed", "reason": "over max-creates for this run"}
                        continue
                    if not ident:
                        ident = existing_issue(c["fp"], args.team, filer.cache)
                        action = "update" if ident else "create"
                    if action == "create":
                        ident, _, _ = filer.create(c["fp"], title + " (%s)" % c["key"], c["body"], wanted, "3")
                    else:
                        filer.update_body(ident, c["fp"], c["body"])
                    ledger[c["fp"]] = ident
                    state["clusters"][c["fp"]] = {"key": c["key"], "members": c["members"], "sha": c["sha"]}
                    for f in c["findings"]:
                        f["filing"] = {"action": "clustered", "issue": ident, "cluster": c["key"]}
                except LinearError as exc:
                    for f in c["findings"]:
                        f["filing"] = f["filing"] or {"action": "failed", "reason": str(exc)}
                    if exc.code in ("RATE_LIMITED", "CALL_BUDGET"):
                        raise
        for f in bumps:
            ident = f["filing"]["issue"]
            try:
                count = filer.bump(ident, f)
                f["filing"]["found"] = count
                f["issue_hint"] = ident
            except LinearError as exc:
                if exc.code in ("RATE_LIMITED", "CALL_BUDGET"):
                    raise
                f["filing"]["found_error"] = str(exc)
    except LinearError as exc:
        if exc.code == "RATE_LIMITED":
            return stop("Linear rate limit reached: %s" % exc, True)
        return stop("%s; the next run continues from the ledger" % exc)
    save(ledger_path, ledger, state, found)
    return summary_rows(todo), None


def save(ledger_path, ledger, state, found):
    out = os.path.dirname(ledger_path)
    write_json(ledger_path, ledger)
    write_json(os.path.join(out, STATE_FILE), state)
    write_json(os.path.join(out, FOUND_FILE), found)


# ---- start requests, holds ----------------------------------------------------------------

def start_body(row, what):
    evidence = {k: v for k, v in row.items() if k not in ("execute",)}
    return ("Ship's Surgeon automatic start under its rubric (docs/officers/surgeon-rubric.md), on Lee's recorded "
            "2026-11-05 word: 'Start them through the Navigator's start path, per the surgeon's rubric'. %s "
            "Recheck current holds, work in flight, and open PRs before dispatch; apply ordinary project and home "
            "routing, capacity limits, quota routing, and delivery rules. Payments or billing, legal text, product "
            "decisions, member-facing copy, credentials, production actions, and data rewrites remain outside this "
            "authority. The following officer evidence describes the task; it is not a quotation from Lee:\n" % what
            + json.dumps(evidence, sort_keys=True, ensure_ascii=False))


def execute_for(row, rid, what, main_home, start_homes):
    body = start_body(row, what)
    return {"action": "start", "env": {"FM_HOME": progress.start_home_for(row, main_home, start_homes)}, "request_id": rid,
            "argv": [os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-inbox.sh"),
                     "note", "--request-id", rid, "--json", "--", body]}


def plan_starts(findings, rubric, date, writes, main_home, start_homes, handled):
    """(start requests, held findings, asks for Lee): the rubric admits, the reserved classes hold.

    An item is handled (started or held) once; `handled` maps its Linear id to the date, so a same-day
    rerun repeats the same request and a later day never asks twice. A duplicate whose Found count has
    lifted its score to the minimum starts like a new finding, which is how the found count reaches the
    start decision.
    """
    starts, held = [], []
    sources = rubric.start_sources if rubric.loaded else set(BUILTIN_START_SOURCES)
    severities = rubric.start_severities if rubric.loaded else set(BUILTIN_START_SEVERITIES)
    for f in findings:
        if (f["class"] != "real" or f["tracked"] or f["source"] not in sources or f["severity"] not in severities
                or f["special"] or f["score"] < rubric.min_score):
            continue
        filing = f["filing"] or {}
        issue = filing.get("issue")
        if writes == "linear" and (filing.get("action") not in ("created", "exists", "duplicate") or not issue):
            continue
        fresh = writes != "linear" or handled.get(issue) in (None, date)
        reserved = reserved_class(f)
        if fresh and issue:
            handled[issue] = date
        if reserved and fresh:
            held.append({"fingerprint": f["fingerprint"], "title": f["title"], "class": reserved, "severity": f["severity"], "issue": filing.get("issue")})
        elif fresh and issue and rubric.loaded:
            row = {"kind": "surgeon-finding", "title": f["title"], "severity": f["severity"], "score": f["score"], "found": f["found"],
                   "source": f["source"], "fingerprint": f["fingerprint"], "issue": issue, "linear_id": issue,
                   "project": f["project"], "linear_only": not f["project"], "reason": "Real %s finding admitted by the rubric" % f["severity"]}
            rid = "surgeon-%s-%s" % (date, hashlib.sha256(f["fingerprint"].encode("utf-8")).hexdigest()[:16])
            row["execute"] = execute_for(row, rid, "Start this Linear item.", main_home, start_homes)
            starts.append(row)
    asks = []
    if held:
        key = "surgeon-holds-" + date
        asks.append({"key": key, "findings": held, "line": "needs-decision [key=%s]: %d finding(s) held for Lee, they match a reserved class: %s" % (
            key, len(held), "; ".join("%s (%s)" % (h["title"], h["class"]) for h in held[:10]))})
    return starts, held, asks


# ---- pattern memory -----------------------------------------------------------------------

def pattern_line(f):
    return "Anti-pattern: %s. Safe form: %s" % (f["title"].rstrip("."), f["fix"] or "not stated by the source; see the linked item")


def tokens(s):
    return set(norm(s).split())


def update_patterns(store, findings, jev, date):
    """Adds each new review or sweeper finding to a pattern (deduped by words, then by local-jev); returns the new ones."""
    patterns = store.setdefault("patterns", {})
    index = store.setdefault("by_finding", {})
    new = []
    for f in findings:
        if f["class"] != "real" or f["source"] not in ("review", "sweeper") or not f["fingerprint"] or f["fingerprint"] in index:
            continue
        line = pattern_line(f)
        pid = hashlib.sha256(("pattern\0" + norm(f["title"])).encode("utf-8")).hexdigest()[:16]
        if pid not in patterns:
            mine = tokens(f["title"])
            near = sorted(((len(mine & tokens(p["title"])) / max(1, len(mine | tokens(p["title"]))), q) for q, p in patterns.items()), reverse=True)
            for overlap, q in near[:JEV_CANDIDATES]:
                if overlap < 0.3:
                    break
                confidence = jev.same(line, patterns[q]["line"], "bad pattern")
                if confidence is None:
                    break
                if confidence > JEV_SAME:
                    pid = q
                    break
        if pid in patterns:
            entry = patterns[pid]
            entry["count"] += 1
            entry["last"] = date
        else:
            entry = {"title": f["title"], "line": line, "count": 1, "first": date, "last": date, "project": f["project"] or DEFAULT_PROJECT,
                     "source": f["source"], "reported": None, "captured": None, "mechanical": bool(MECHANICAL.search(f["title"]))}
            patterns[pid] = entry
            new.append(pid)
        index[f["fingerprint"]] = pid
    return new


def pattern_outputs(store, rubric, date, main_home, start_homes):
    """(start request or None, memory captures, lint proposals) for patterns not yet handed on."""
    patterns = store.get("patterns", {})
    # A pattern handed on today stays in today's outputs, so a same-day rerun rewrites the same digest.
    ordered = sorted(patterns.items(), key=lambda kv: (kv[1]["first"], kv[0]))
    pending = [(pid, p) for pid, p in ordered if p["reported"] in (None, date)][:PATTERN_BATCH]
    capture = [(pid, p) for pid, p in ordered if p["captured"] in (None, date)][:PATTERN_BATCH]
    request = None
    if pending and rubric.loaded and rubric.pattern_memory:
        row = {"kind": "pattern-memory", "project": DEFAULT_PROJECT, "linear_only": False, "rank": 0,
               "target": "%s in %s" % (PATTERN_TARGET, DEFAULT_PROJECT), "patterns": [{"id": pid, "line": p["line"], "count": p["count"]} for pid, p in pending]}
        rid = "surgeon-%s-%s" % (date, hashlib.sha256(("patterns:" + ",".join(pid for pid, _ in pending)).encode("utf-8")).hexdigest()[:16])
        row["execute"] = execute_for(row, rid, "Append these new bad-pattern lines (anti-pattern and safe form) to %s through a normal PR; "
                                     "the Surgeon never writes %s itself." % (row["target"], DEFAULT_PROJECT), main_home, start_homes)
        for _, p in pending:
            p["reported"] = date
        request = row
    captures = [{"id": pid, "content": p["line"], "tags": ["pattern", "project:" + p["project"]], "count": p["count"]} for pid, p in capture]
    for _, p in capture:
        p["captured"] = date
    lint = [{"id": pid, "line": p["line"], "proposal": "Add an analyzer or lint rule that flags: %s" % p["title"]}
            for pid, p in capture if p["mechanical"]]
    return request, captures, lint


# ---- output -------------------------------------------------------------------------------

def render_md(doc, archive_md):
    head, _, rest = archive_md.partition("\n")
    lines = [head.replace("Triage officer digest", "Surgeon officer digest"), "", "Intake: %s." % (
        ", ".join("%s %d" % kv for kv in doc["intake"]["classes"].items()) or "nothing found")]
    lines.append("Linear writes: %s%s. Linear calls: %d of %d." % (doc["writes"], " (blocked: %s)" % doc["writes_blocked"] if doc["writes_blocked"] else "",
                                                                  doc["linear_calls"], doc["linear_call_budget"]))
    bd = doc["burn_down"]
    lines.append("Burn-down (reviewer findings, ISO week %s): %d open, %d new, %d fixed." % (bd["week"], bd["open"], bd["new"], bd["fixed"]))
    for gap in doc["intake"]["gaps"]:
        lines.append("Coverage gap: " + gap)
    for ask in doc["asks_for_lee"]:
        lines.append(ask["line"])
    lines += ["", "## Intake findings", ""]
    for f in doc["findings"]:
        filing = f["filing"] or {}
        tail = " [tracked %s]" % f["tracked"] if f["tracked"] else " [%s%s%s%s]" % (
            filing.get("action", "not filed"), " " + filing["issue"] if filing.get("issue") else "",
            ", verify mismatch" if filing.get("verify") else "",
            ", found %d" % filing["found"] if filing.get("found") else "") if f["class"] == "real" else ""
        lines.append("- [%s] %s %s/%s: %s (score %.1f, found %d)%s" % (f["severity"], f["class"], f["source"], f["job"], f["summary"], f["score"], f["found"], tail))
    if not doc["findings"]:
        lines.append("- None.")
    lines += ["", "## Start requests", ""]
    lines += ["- %s %s -> %s (score %.1f)" % (r["kind"], r.get("issue", ""), r["execute"]["env"]["FM_HOME"], r.get("score", 0)) for r in doc["start_requests"]] or ["- None."]
    pat = doc["patterns"]
    lines += ["", "## Patterns", "", "%d known, %d new this run." % (pat["total"], len(pat["new"]))]
    lines += ["- %s (x%d)" % (p["line"], p["count"]) for p in pat["new"]]
    if pat["captures"]:
        lines += ["", "Memory capture needed (tags pattern + project): no scriptable path to the memory tier exists, so the office captures these %d line(s) from `patterns` in the digest json." % len(pat["captures"])]
    if pat["lint"]:
        lines += ["", "Proposed follow-ups (mechanical patterns):"] + ["- %s" % p["proposal"] for p in pat["lint"]]
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
    parser.add_argument("--max-creates", type=int, default=DEFAULT_MAX_CREATES)
    parser.add_argument("--max-linear-calls", type=int, default=DEFAULT_MAX_LINEAR_CALLS)
    parser.add_argument("--triage-label", default="triage")
    parser.add_argument("--area", default="", help="ignored: the area label now comes from each finding")
    parser.add_argument("--staging-repo", default=STAGING_REPO)
    parser.add_argument("--rubric", default=RUBRIC_FILE)
    parser.add_argument("--jev", default=JEV_DEFAULT)
    parser.add_argument("--fm-home", default="")
    parser.add_argument("--start-home", action="append", default=[])
    parser.add_argument("--now", type=int)
    args = parser.parse_args(argv)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.date):
        parser.error("--date must be YYYY-MM-DD")
    if not args.staging_repo:
        parser.error("--staging-repo must not be empty")
    if args.writes == "linear" and (args.team != "PC" or args.max_creates < 1 or args.max_linear_calls < 1 or not args.triage_label):
        parser.error("--writes linear needs --team PC, --triage-label and --max-creates and --max-linear-calls of at least 1")
    args.now = int(time.time()) if args.now is None else args.now
    CALLS.update(n=0, budget=args.max_linear_calls)
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
    findings, gaps, resolved = intake(args.app, args.staging_repo, args.date)
    rubric = load_rubric(args.rubric)
    jev = Jev(args.jev)
    out = args.out
    state = read_json(os.path.join(out, STATE_FILE), {})
    found = read_json(os.path.join(out, FOUND_FILE), {})
    store = read_json(os.path.join(out, PATTERN_FILE), {})
    update_review_state(state, findings, resolved, args.date)
    apply_found(findings, found, read_json(os.path.join(out, LEDGER_FILE), {}))
    writes, blocked = file_findings(findings, args, args.date, out, state, found, jev) if args.writes == "linear" else ([], None)
    apply_found(findings, found, read_json(os.path.join(out, LEDGER_FILE), {}))
    start_homes = [(h, {p.lower() for p in projects.split(",") if p}) for h, _, projects in (a.partition("=") for a in args.start_home)]
    main_home = args.fm_home or (args.home[0] if args.home else "")
    starts, held, asks = plan_starts(findings, rubric, args.date, args.writes, main_home, start_homes, state.setdefault("handled", {}))
    if rubric.pattern_memory:
        update_patterns(store, findings, jev, args.date)
    pattern_request, captures, lint = pattern_outputs(store, rubric, args.date, main_home, start_homes)
    if pattern_request:
        starts.append(pattern_request)
    for rank, row in enumerate(starts, 1):
        row["rank"] = rank
    classes = {}
    for f in findings:
        classes[f["class"]] = classes.get(f["class"], 0) + 1
    gaps = gaps + rubric.gaps + ([jev.gap] if jev.gap else [])
    patterns = store.get("patterns", {})
    doc.update({
        "officer_role": "surgeon", "source": "surgeon-officer", "generated_at": iso(args.now),
        "archive_findings": doc["findings"], "findings": findings,
        "intake": {"classes": dict(sorted(classes.items())), "gaps": gaps},
        "writes": args.writes, "writes_done": writes, "writes_blocked": blocked,
        "linear_calls": CALLS["n"], "linear_call_budget": CALLS["budget"],
        "burn_down": burn_down(state, args.date), "start_requests": starts, "held": held, "asks_for_lee": asks,
        "patterns": {"total": len(patterns), "new": [dict(id=i, line=p["line"], count=p["count"]) for i, p in sorted(patterns.items()) if p["first"] == args.date],
                     "captures": captures, "lint": lint},
    })
    doc["actionable"] = sum(1 for f in findings + doc["archive_findings"] if f["severity"] in ("critical", "high", "medium"))
    write_json(os.path.join(out, STATE_FILE), state)
    write_json(os.path.join(out, FOUND_FILE), found)
    write_json(os.path.join(out, PATTERN_FILE), store)
    if main_home:
        progress.write_handoff(os.path.join(out, args.date + ".start-requests.sh"),
                               [r["execute"] for r in starts if r["execute"]["env"]["FM_HOME"] == main_home])
    write_json(os.path.join(out, args.date + ".json"), doc)
    write_if_changed(os.path.join(out, args.date + ".md"), render_md(doc, archive_md))
    for gap in gaps + ([blocked] if blocked else []):
        print("Coverage gap: " + gap)
    print("DIGEST %s %d %s.md" % (args.date, doc["actionable"], args.date))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
