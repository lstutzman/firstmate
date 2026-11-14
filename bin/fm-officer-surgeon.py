#!/usr/bin/env python3
"""fm-officer-surgeon.py - the Ship's Surgeon's daily pass: triage, then intake.

Run only through `bin/fm-officer.sh run <id>`, which owns the officer contract;
docs/configuration/officers.md "Officers" owns the registry schema, the officer-roles
skill owns what the Surgeon may and may never do, docs/officers/contract.md owns the
FIND, FILE, TRIAGE, START contract that bin/fm-officer-linear.py implements for every officer,
and docs/officers/surgeon-rubric.md owns what counts as work, how it is scored and what starts by itself.

Usage:
  fm-officer-surgeon.py fold --out <lane-dir> [--friction-out <lane-dir>] [--page-check-out <lane-dir>] [--apply] [--team PC]
                           [--bundle-cap 15] [--max-items 1000] ...
  fm-officer-surgeon.py run --archive <dir|host:dir> --date <YYYY-MM-DD> --out <lane-dir>
                            --app <https url> [--home <dir>]... [--hosts a,b] [--model none]
                            [--team PC] [--writes none|linear] [--max-creates 100] [--bundle-cap 15]
                            [--max-linear-calls 450] [--triage-label triage] [--area <ignored>]
                            [--staging-repo <git remote>] [--visual-findings <file>] [--visual-captures <dir>]
                            [--rubric <file>] [--jev <jev.py>] [--sweeper-runs <dir>]
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
                        promotion-blocking item per job while the run stays
                        invalid (each day bumps its Found line), never starts
                        by itself.
  nightly review        critical, high, medium: real at severity high, medium, low;
                        a low finding is won't fix. Ids in the result's `resolved`
                        list (or findings whose status is resolved/fixed) are fixed,
                        not findings.
  sweeper bug           disposition new/regressed: real; unclear/idea or any
                        unknown disposition: needs a decision; duplicate,
                        fixed-live, noise: won't fix; fixed-staging-only:
                        needs a decision. Severity P1/critical/high: high;
                        P2/medium: medium; else low. When the cluster's
                        `environment` is production a non-won't-fix
                        finding moves up one step (low, medium, high, critical).
                        Production is never inferred from text. The environment
                        comes from the bug, the run's intake, or the cluster in the
                        sweeper's own run bundle (<--sweeper-runs>/<run id>/bundle.json;
                        default $PC_SWEEPER_RUNS, then ~/services/pc-sweeper/runs):
                        /api/sweeper-results carries neither `environment` nor
                        `environments` ({env: {count, first_seen, last_seen}}),
                        so with no bundle readable there is no bump and a
                        named `Coverage gap:`. A cluster whose newest last_seen is
                        more than SWEEP_STALE_DAYS (3) before the run started
                        (its started_at, else the time in its run id) is
                        stale: won't fix, never offered as fresh, and back in the
                        queue the day it is seen again.

  visual review         with --visual-findings, the nightly visual review's findings file (PropertyCompass2
                        scripts/visual-review/README.md owns the format; only schema_version 2 is read, and each
                        row's own fingerprint and class are trusted). Findings sharing a fingerprint (route plus
                        rubric item; viewports do not split them) are one finding with every screenshot listed.
                        A `defect` is real at the file's own severity (high, medium or low; none stated: medium).
                        Anything not `defect` is held for Lee: never filed, never started, one keyed needs-decision
                        `surgeon-visual-held-<date>` per run for the ones not yet announced, and low severity so
                        it never raises the high-severity wake. The `visual` source is not a start source. A file
                        that is missing, unreadable, of another schema_version, or unchanged since the last run is a
                        named `Coverage gap:`, as are a row without a route, rubric item or 64-hex fingerprint
                        (skipped), a non-empty errors list or a run.images_failed, run.images_deferred or
                        run.malformed_findings_dropped above zero (the review is incomplete). The finding's bundle line
                        carries its visual-review-fp and names its screenshots (resolved against --visual-captures when
                        given and the file is there).
                        With --visual-captures and writes: linear, the bundle a finding is newly added to gets each of
                        its screenshots attached with `linear-attach <issue> <file> --verify` (never on a repeat, each call counted
                        against the Linear call budget); a missing linear-attach, a missing screenshot file, exit 3
                        (upload rights) or exit 75 (rate limited, stops the run's attaching) is a named `Coverage gap:`.
                        A screenshot not attached (other than a missing file) is kept as `pending_attach` in the
                        lane's state and retried first on each later run, and dropped as abandoned, a named gap, once
                        it was first left ATTACH_DAYS ago.

A won't-fix finding is always low. A finding the source already put in Linear (an
`issue` on the nightly failure, a filing on the review finding, a Linear item
or `duplicate_of` on the sweeper bug) is `tracked`: reported, never filed again. A sweeper
Linear item counts from any earlier run too: each earlier run that filed or updated one is
read once (GET /api/sweeper-results/<run id>) and kept in the lane state (`sweeper_items`).
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
     (AREA_RULES, feature first: the feature rules on its path and then its words before
     `testing`); with no fit it is --triage-label; a label missing from team PC
     means the finding is reported and not filed. The Surgeon never creates a label.
     Fleet work (lib.fleet_work: a finding from firstmate, skills or fleet-app) takes
     area:fleet instead and goes in the Fleet project, and its bundles are apart from PropertyCompass2 ones.
  2. every finding is a line on its source family's feature-area bundle (docs/officers/contract.md "Bundles";
     lib.Bundles): families code review, nightly E2E, bug sweeper and visual review (FAMILY), the area from
     area_for(..., feature_first=True), grouped by file inside, at most --bundle-cap open lines a part. A finding
     on the reviewer's resolved list is ticked. The one single item is an invalid nightly E2E run, which blocks
     promotion: it keeps its own item (special e2e-invalid) and the steps below.
  3. dedupe, in order: the fingerprint (`issue search "surgeon-fp:<sha256>"`, read
     with `issue view`, plus the lane's filed-fingerprints.json); then a text
     search of the title, each candidate asked of local-jev ("same issue?"), a
     duplicate only at confidence > JEV_SAME. A lower near match is noted on the
     finding's line. Without local-jev, only the fingerprint decides. A bundle is never a match.
  4. a duplicate bumps the existing single item's one machine-maintained line
     `Found: N times (first <date>, last <date>, by surgeon)` in place
     (`issue update --dry-run`, then `--verify`), at most once a day per item, and
     adds one comment on that first sighting. A finding already on its bundle is
     not a new sighting; it keeps its own found count.
  5. `issue create --dry-run`, then `--verify`, with exactly one Type (Bug), one
     Source and one area label. A failed verify is never retried; the item counts as created (and is ledgered)
     when the error names it (data.issue.identifier) or the team's issue list holds one new open item of exactly its title, else it is logged failed
     and tried again next run. A bundle with no ledgered item first adopts the oldest open item of exactly its title.
It never deletes an item. It marks Duplicate (relation, then state, then one comment, each dry-run first)
only a single item it filed itself (the ledger names it and its body opens with the Surgeon's own line) once a written bundle
lists its finding, never a started, assigned, closed, person-authored or reserved-class one; the lane's `folded` map keeps
that to once (a comment that failed waits in `uncommented` and is posted first next run),
with writes: none it only reports (duplicates.would_mark), and every call carries LINEAR_JOB=officer:surgeon. Every linear-axi call is counted; --max-linear-calls
stops the run's Linear work (the next run continues from the ledger). --max-creates bounds
new items (bundles) a run. One RATE_LIMITED answer stops every Linear call in the run, writes
linear-resume-after.json (one hour on) and reports the rest as not filed; later runs
skip Linear until then. Nothing is dropped silently: the digest names what was not filed.

Start requests: a real, untracked, filed finding whose severity (medium, high, critical)
and source the rubric admits, whose score reaches the rubric's minimum (so a medium
finding starts once it is found 3 times), and that matches no reserved class (each anchored
to its action, e.g. rotating a credential, rewording member-facing text) becomes a start request on the progress officer's path (start-requests.sh for this
home, `execute` entries for each --start-home office); the reserved classes become one
keyed needs-decision line (asks_for_lee). The rubric can only narrow.

Pattern memory (review and sweeper findings): one whole-sentence line per bad pattern, built from the finding's
full title and fix, deduped by normalised title and then by local-jev. Every pattern is stored and counted, but one
is handed on only once it has a stated safe form and was seen on at least two findings: then it goes in one batched
start request to the Navigator (quality-patterns.md), in the digest for memory capture (no scriptable memory-tier
path exists), and a mechanical one gets a proposed lint rule. A one-off, or a pattern with no fix, stays in the store.

`fold` (fold_main) is the one-off move of the existing open automated items into area bundles: the Surgeon's (one per
finding, or one per component cluster), the friction and page-check officers', and fleet-app's "Dependency a major version
behind" and "Nightly E2E" items (written in fleet-app's own bundle format so its filers adopt them). A dry run unless --apply;
see `fm-officer-surgeon.py fold --help`.

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
import os
import re
import subprocess
import sys
import tempfile
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
lib = _load("fm_officer_linear", "fm-officer-linear.py")

dicts, text, norm, fingerprint = lib.dicts, lib.text, lib.norm, lib.fingerprint
read_json, write_json, write_if_changed, iso = lib.read_json, lib.write_json, lib.write_if_changed, lib.iso
finding, score_of, apply_found = lib.make_finding, lib.score_of, lib.apply_found
RANK, PRIORITY, BUMP, LinearError = lib.RANK, lib.PRIORITY, lib.BUMP, lib.LinearError
STATE_FILE, FOUND_FILE, LEDGER_FILE, PATTERN_FILE = lib.STATE_FILE, lib.FOUND_FILE, lib.LEDGER_FILE, lib.PATTERN_FILE
LIN = lib.Linear(job="officer:surgeon")

NOISE_WORDS = ("flaky", "load", "host", "infra")
DECISION_WORDS = ("product", "spec", "intended")
SWEEP_REAL = ("new", "regressed")
SWEEP_DECISION = ("unclear", "idea", "fixed-staging-only")
SWEEP_NOISE = ("duplicate", "fixed-live", "noise")
SWEEP_HIGH = ("p1", "critical", "high")
SWEEP_MEDIUM = ("p2", "medium")
# A sweeper cluster with no sighting in this many days is stale, not fresh (the sweeper's 14-day window keeps counting old events).
SWEEP_STALE_DAYS = 3
SWEEP_RUN_ID = re.compile(r"sweep-[0-9]{8}T[0-9]{4}Z")
# Earlier sweeper runs read per Surgeon run to learn the Linear items the sweeper filed before; the rest wait for the next run.
SWEEP_HISTORY_READS = 45
REVIEW_SEVERITY = {"critical": "high", "high": "medium", "medium": "low"}
SOURCE_LABEL = {"nightly": "scheduled-review", "review": "scheduled-review", "sweeper": "bug-sweep", "visual": "scheduled-review"}
SOURCE_NAME = {"nightly": "nightly E2E", "review": "nightly code review", "sweeper": "bug sweeper", "visual": "nightly visual review"}
# The visual review's findings file (PropertyCompass2 scripts/visual-review/evaluate.py): its findings' job name, the area
# label used when the route maps to none, and the severities it may state.
VISUAL_JOB = "visual-review"
VISUAL_AREA_FALLBACK = "ui-ux"
VISUAL_SEVERITY = {"high": "high", "medium": "medium", "low": "low"}
# The source family each source's findings are bundled under (one open item per family and feature area).
FAMILY = {"nightly": "nightly E2E", "review": "code review", "sweeper": "bug sweeper", "visual": "visual review"}
# A screenshot left unattached is retried each run, and dropped as abandoned once it was first left this many days ago.
ATTACH_DAYS = 7
STAGING_REPO = "git@github.com:lstutzman/PropertyCompass2.git"
RUBRIC_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "officers", "surgeon-rubric.md")

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


def sweeper_runs_dir(arg):
    """The sweeper's run directory: --sweeper-runs, else $PC_SWEEPER_RUNS, else ~/services/pc-sweeper/runs."""
    return arg or os.environ.get("PC_SWEEPER_RUNS") or os.path.expanduser("~/services/pc-sweeper/runs")


def sweeper_bundle(runs_dir, run_id):
    """{fp: {environment, environments}} from the sweeper's own <runs_dir>/<run_id>/bundle.json, or None when unreadable.

    The fleet app's /api/sweeper-results keeps neither field, but the bundle the sweeper writes carries each cluster's
    `environment` and `environments` ({env: {count, first_seen, last_seen}}).
    """
    if not SWEEP_RUN_ID.fullmatch(text(run_id, 64)):
        return None
    doc = read_json(os.path.join(runs_dir, run_id, "bundle.json"), None)
    if not isinstance(doc, dict) or not isinstance(doc.get("clusters"), list):
        return None
    return {text(c.get("fp"), 100): {"environment": text(c.get("environment")).lower(), "environments": c.get("environments")}
            for c in dicts(doc["clusters"]) if c.get("fp")}


def utc_epoch(stamp):
    """Epoch seconds of an ISO-8601 UTC stamp (any fraction), or None."""
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})", text(stamp, 40))
    if not m:
        return None
    return datetime.datetime(*(int(g) for g in m.groups()), tzinfo=datetime.timezone.utc).timestamp()


def sweeper_last_seen(environments):
    """({env: last_seen}, newest last_seen epoch or None) from a cluster's `environments` map."""
    seen = {text(name, 30): text(v.get("last_seen"), 40) for name, v in (environments if isinstance(environments, dict) else {}).items()
            if isinstance(v, dict) and utc_epoch(v.get("last_seen")) is not None}
    return seen, max((utc_epoch(v) for v in seen.values()), default=None)


def judge_sweeper(doc, history=None, bundle=None):
    """The sweeper's clusters as findings.

    history: {fp: Linear id} from earlier runs' linear lists; this run's lists win over it. bundle: sweeper_bundle(), the
    source of `environment` and last-seen when the bug itself carries none. A cluster last seen more than SWEEP_STALE_DAYS
    before the run started (its started_at, else the time in its run id) is won't fix (stale), never a fresh finding.
    """
    latest = doc.get("latest")
    run = latest.get("run") if isinstance(latest, dict) else None
    intake_doc = run.get("intake") if isinstance(run, dict) else None
    if not isinstance(intake_doc, dict):
        return []
    linear_doc = intake_doc.get("linear") if isinstance(intake_doc.get("linear"), dict) else {}
    items = dict(history or {})
    items.update({text(i.get("fp"), 100): text(i.get("id"), 20)
                  for k in ("filed", "updated", "cancelled", "dismissed") for i in dicts(linear_doc.get(k)) if i.get("fp")})
    started = utc_epoch(run.get("started_at"))
    run_id = text(run.get("run_id"), 64)
    if started is None and SWEEP_RUN_ID.fullmatch(run_id):
        try:
            started = datetime.datetime.strptime(run_id, "sweep-%Y%m%dT%H%MZ").replace(tzinfo=datetime.timezone.utc).timestamp()
        except ValueError:
            pass
    out = []
    for b in dicts(intake_doc.get("bugs")):
        disposition = text(b.get("disposition")).lower()
        severity = text(b.get("severity")).lower()
        key = text(b.get("fp"), 100)
        extra = (bundle or {}).get(key) or {}
        klass = ("real" if disposition in SWEEP_REAL else "wont-fix" if disposition in SWEEP_NOISE else "needs-decision")
        level = "high" if severity in SWEEP_HIGH else "medium" if severity in SWEEP_MEDIUM else "low"
        env = text(b.get("environment") or intake_doc.get("environment") or run.get("environment") or extra.get("environment")).lower()
        seen, newest = sweeper_last_seen(b.get("environments") if isinstance(b.get("environments"), dict) else extra.get("environments"))
        idle = round((started - newest) / 86400, 1) if started is not None and newest is not None else None
        stale = klass != "wont-fix" and idle is not None and idle > SWEEP_STALE_DAYS
        if stale:
            klass = "wont-fix"
        if env in ("production", "prod") and klass != "wont-fix":
            level = BUMP[level]
        if klass == "wont-fix":
            level = "low"
        evidence = {"disposition": disposition, "severity": b.get("severity"), "occurrences": b.get("occurrences"),
                    "cause": text(b.get("cause")), "run": run.get("run_id"), "environment": env or None,
                    "last_seen": seen or None, "stale_days": idle if stale else None}
        label = "%s, %s" % (disposition or "no disposition", b.get("severity") or "no severity")
        out.append(finding("sweeper", "pc-sweeper-intake", key, b.get("title"),
                           "%s (%s%s)" % (text(b.get("title"), 140), label, ", stale: last seen %s days before the run" % idle if stale else ""),
                           klass, level, items.get(key) or text(b.get("duplicate_of"), 20) or None, evidence,
                           location=b.get("file") or b.get("url") or b.get("page") or b.get("route") or "",
                           project=b.get("repo") or b.get("project") or "",
                           fix=b.get("fix") or b.get("recommendation") or ""))
    return out


def sweeper_history(app, sweeps, state, gaps):
    """{fp: Linear id} the sweeper filed or updated in earlier runs, kept in the lane state so each run reads only new ones.

    The latest run's own linear lists name only that run's filings, so a cluster filed days ago (PC-3659 on 2026-10-25) looked
    untracked. Each earlier run that filed or updated something is one GET of /api/sweeper-results/<run id>, oldest first so the
    newest item for a fingerprint wins; a run that cannot be read is a named gap and tried again next run.
    """
    items = state.setdefault("sweeper_items", {})
    done = set(state.setdefault("sweeper_runs_read", []))
    latest = ((sweeps.get("latest") or {}).get("run") or {}).get("run_id") if isinstance(sweeps.get("latest"), dict) else None
    todo = sorted((r for r in dicts(sweeps.get("runs")) if r.get("mode") == "intake" and (r.get("filed") or r.get("updated"))
                   and SWEEP_RUN_ID.fullmatch(text(r.get("runId"), 64)) and r["runId"] not in done and r["runId"] != latest),
                  key=lambda r: text(r.get("startedAt"), 40))
    failed = 0
    for row in todo[:SWEEP_HISTORY_READS]:
        got, doc = fetch(app, "/api/sweeper-results/%s" % row["runId"])
        run = doc.get("run") if got == "read" and isinstance(doc.get("run"), dict) else None
        lists = ((run or {}).get("intake") or {}).get("linear") if isinstance((run or {}).get("intake"), dict) else None
        if not isinstance(lists, dict):
            failed += 1
            continue
        for kind in ("filed", "updated"):
            for i in dicts(lists.get(kind)):
                if i.get("fp") and i.get("id"):
                    items[text(i["fp"], 100)] = text(i["id"], 20)
        done.add(row["runId"])
    if failed:
        gaps.append("fleet app: %d earlier sweeper run(s) unreadable, so their Linear items are not joined yet" % failed)
    if len(todo) > SWEEP_HISTORY_READS:
        gaps.append("sweeper history: %d earlier run(s) wait for the next run (at most %d read a run)" % (len(todo) - SWEEP_HISTORY_READS, SWEEP_HISTORY_READS))
    state["sweeper_runs_read"] = sorted(done)
    return items


def intake(app, staging_repo, lane=None, runs_dir=""):
    """(findings, coverage gaps, fingerprints the reviewer marked resolved); every read is a GET.

    lane: the lane state, where the sweeper's earlier Linear items are kept. runs_dir: the sweeper's run directory (sweeper_runs_dir).
    """
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
                "nightly", ref["id"], "e2e-invalid", "Nightly E2E run invalid: promotion blocked",
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
        latest = sweeps.get("latest") if isinstance(sweeps.get("latest"), dict) else {}
        run = latest.get("run") if isinstance(latest.get("run"), dict) else {}
        history = sweeper_history(app, sweeps, lane if lane is not None else {}, gaps)
        bundle = sweeper_bundle(runs_dir or sweeper_runs_dir(""), run.get("run_id"))
        bugs = dicts((run.get("intake") or {}).get("bugs")) if isinstance(run.get("intake"), dict) else []
        if bugs and bundle is None and not any(b.get("environment") or isinstance(b.get("environments"), dict) for b in bugs):
            gaps.append("sweeper environment and last-seen: /api/sweeper-results carries neither field and %s/%s/bundle.json is unreadable, "
                        "so no cluster is rated by environment or judged stale" % (runs_dir or sweeper_runs_dir(""), text(run.get("run_id"), 64)))
        findings += judge_sweeper(sweeps, history, bundle)
    return findings, gaps, resolved

def visual_severity(row):
    return VISUAL_SEVERITY.get(text(row.get("severity"), 10).lower(), "medium")


def screenshot_where(captures, rel):
    """Where a screenshot is: its real path when it is a file inside the capture directory, else its relative path, named."""
    if not captures:
        return "%s (relative to the nightly capture directory)" % rel
    root = os.path.realpath(captures)
    full = os.path.realpath(os.path.join(root, rel))
    if full.startswith(root + os.sep) and os.path.isfile(full):
        return full
    return "%s (not found under %s)" % (rel, captures)


def visual_intake(path, captures, state, ledger, date, writes):
    """(findings, held to announce, coverage gaps) from the nightly visual review's findings file; no path means the source is off.

    A `defect` is a real finding; anything else is held for Lee as a needs-decision finding, which file_findings and plan_starts
    never touch. A findings file this lane already read on an earlier date adds only the defects no item exists for yet.
    """
    if not path:
        return [], [], []
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        return [], [], ["visual findings file %s not found" % path]
    except (OSError, ValueError) as exc:
        return [], [], ["visual findings file %s unreadable: %s" % (path, text(exc, 80))]
    version = doc.get("schema_version") if isinstance(doc, dict) else None
    rows = doc.get("findings") if isinstance(doc, dict) else None
    if type(version) is not int or version != 2 or not isinstance(rows, list):
        return [], [], ["visual findings file %s has schema_version %s and %s findings; only a version 2 file with a findings list is read"
                        % (path, text(version, 20), "no" if not isinstance(rows, list) else "a list of")]
    run = doc.get("run") if isinstance(doc.get("run"), dict) else {}
    stamp = text(run.get("date"), 40)
    seen = state.setdefault("visual", {})
    gaps, groups, skipped = [], collections.OrderedDict(), 0
    errors = doc.get("errors")
    if isinstance(errors, list) and errors:
        gaps.append("visual findings file %s reports %d review error(s), so its findings are incomplete" % (path, len(errors)))
    for count in ("images_failed", "images_deferred", "malformed_findings_dropped"):
        value = run.get(count)
        if type(value) is int and value > 0:
            gaps.append("visual findings file %s: run.%s is %d, so its findings are incomplete" % (path, count, value))
    for row in dicts(rows):
        route, item = text(row.get("route"), 200), text(row.get("rubric_item"), 60)
        fp = text(row.get("fingerprint"), 100)
        if not route or not item or not re.fullmatch(r"[0-9a-f]{64}", fp):
            skipped += 1
            continue
        klass = text(row.get("class"), 20)
        group = groups.setdefault(fp, {"route": route, "item": item, "held": False, "rows": []})
        group["held"] = group["held"] or klass != "defect"
        group["rows"].append(row)
    if skipped:
        gaps.append("visual findings file %s: %d finding(s) without a route, rubric item and 64-hex fingerprint skipped" % (path, skipped))
    findings, held = [], []
    for fp, g in groups.items():
        rows = g["rows"]
        top = min(rows, key=lambda r: RANK[visual_severity(r)])
        reviewer = visual_severity(top)
        shots = sorted({text(r.get("screenshot"), 300) for r in rows if r.get("screenshot")})
        evidence = {"rubric_item": g["item"], "evidence": text(top.get("evidence"), 240), "region": text(top.get("region"), 80),
                    "reason": text(top.get("reason"), 20), "viewports": ", ".join(sorted({text(r.get("viewport"), 20) for r in rows if r.get("viewport")})),
                    "reviewer_severity": reviewer, "review_run": stamp, "visual_review_fp": fp,
                    "screenshots": [screenshot_where(captures, s) for s in shots]}
        f = finding("visual", VISUAL_JOB, fp, "Visual review: %s on %s" % (g["item"], g["route"]),
                    "%s on %s: %s" % (g["item"], g["route"], text(top.get("evidence"), 120)),
                    "needs-decision" if g["held"] else "real", "low" if g["held"] else reviewer, None, evidence, location=g["route"])
        findings.append(f)
        if g["held"]:
            held.append(f)
    if stamp and seen.get("run") == stamp and seen.get("date") != date:
        gaps.append("visual findings file %s is unchanged since the review run of %s, so no nightly visual review ran since" % (path, stamp))
        findings = [f for f in findings if f["class"] != "real" or f["fingerprint"] not in ledger]
    else:
        seen["run"], seen["date"] = stamp, date
        if not stamp:
            gaps.append("visual findings file %s has no run.date, so a repeat of the same file cannot be told from a new review" % path)
    announced = seen.setdefault("announced", {})
    held = [f for f in held if announced.setdefault(f["fingerprint"], date) == date]
    todo = [f for f in findings if f["class"] == "real"]
    if todo and writes == "linear" and not captures:
        gaps.append("visual review screenshots are named in the Linear items, not attached: no visual-captures directory is set (%d finding(s))" % len(todo))
    return findings, held, gaps


def attach_screenshots(entries, gaps, run, date):
    """Attaches each {"issue", "file", "first"} entry with `linear-attach <issue> <file> --verify`; returns those still pending.

    Failures are named in gaps. `run` holds "stopped" once linear-attach is missing, rate limited, refused for upload rights
    or out of the Linear call budget this run; the entries after that stay pending. A file that is not there is a gap and
    is not retried. An entry first left ATTACH_DAYS or more days ago is dropped as abandoned. Each call counts against the
    Linear call budget.
    """
    pending = []
    for e in entries:
        ident, where = e["issue"], e["file"]
        if (datetime.date.fromisoformat(date) - datetime.date.fromisoformat(e["first"])).days >= ATTACH_DAYS:
            gaps.append("screenshot abandoned for %s after %d days unattached: %s" % (ident, ATTACH_DAYS, where))
            continue
        if not os.path.isfile(where):
            gaps.append("screenshot not attached to %s: %s" % (ident, where))
            continue
        if run.get("stopped"):
            pending.append(e)
            continue
        if LIN.n >= LIN.budget:
            run["stopped"] = True
            pending.append(e)
            gaps.append("screenshots not attached: Linear call budget of %d reached" % LIN.budget)
            continue
        LIN.n += 1
        try:
            proc = subprocess.run(["linear-attach", ident, where, "--verify"], capture_output=True, check=False)
        except OSError as exc:
            run["stopped"] = True
            pending.append(e)
            gaps.append("screenshots not attached: linear-attach is not available (%s)" % text(exc, 80))
            continue
        if proc.returncode == 0:
            continue
        pending.append(e)
        if proc.returncode == 75:
            run["stopped"] = True
            gaps.append("screenshots not attached: linear-attach was rate limited at %s" % ident)
        elif proc.returncode == 3:
            run["stopped"] = True
            gaps.append("screenshots not attached: the Linear app token lacks upload rights (linear-attach exit 3); Lee's call")
        else:
            gaps.append("screenshot not attached to %s: linear-attach exit %d for %s" % (ident, proc.returncode, where))
    return pending


def visual_ask(held, date):
    """The one keyed needs-decision line for the wording or product findings held for Lee this run, or None."""
    if not held:
        return None
    key = "surgeon-visual-held-%s" % date
    names = ["%s (%s)" % (f["location"], f["evidence"]["rubric_item"]) for f in held]
    return {"key": key, "findings": [{"fingerprint": f["fingerprint"], "title": f["title"], "class": "held-for-lee"} for f in held],
            "line": "needs-decision [key=%s]: %d visual-review finding(s) on wording or product held for Lee, not filed and never started: %s" % (
                key, len(held), "; ".join(names[:10]) + ("; and %d more" % (len(names) - 10) if len(names) > 10 else ""))}


# ---- area -----------------------------------------------------------------------------

def area_for(location, words, names, fallback, feature_first=False):
    """The area label for a finding: from its path, else its words, else the fallback; None if the label is absent.

    With feature_first (nightly E2E failures, whose path is always a spec file) the feature rules are tried on
    the path and then the words before `testing`, which is only their fallback.
    """
    loc = location.lower().replace("\\", "/")
    lowered = words.lower()

    def first(rules, haystack, words_only=False):
        for label, rx in rules:
            if label in names and haystack and (not words_only or label in TEXT_AREA_LABELS) and rx.search(haystack):
                return label
        return None

    if feature_first:
        feature = [r for r in AREA_RULES if r[0] != "testing"]
        hit = first(feature, loc) or first(feature, lowered, True) or first(AREA_RULES, loc)
    else:
        hit = first(AREA_RULES, loc) or (None if loc else first(AREA_RULES, lowered, True))
    return hit or (fallback if fallback.lower() in names else None)


def description(f, date, near=None, recurrence=None):
    lines = ["Filed by the Ship's Surgeon from the %s %s results." % (date, SOURCE_NAME[f["source"]]),
             "What it is for: a finding no Linear item tracked yet, so it is not lost.",
             "Epic: not assigned; whoever triages this picks one.", "",
             "Severity: %s. Source job: %s." % (f["severity"], f["job"]), found_line(1, date, date)]
    if f.get("special") == "e2e-invalid":
        lines.append("Promotion-blocking: yes. No nightly E2E result can be read until this run is valid again.")
    if recurrence:
        lines.append(recurrence)
    if near:
        lines.append("Near match (not treated as the same issue): %s, local-jev %.2f." % near)
    shots = f["evidence"].get("screenshots") or []
    lines += ["%s: %s" % (k, text(v, 300)) for k, v in sorted(f["evidence"].items()) if v not in (None, "") and k not in ("screenshots", "visual_review_fp")]
    if f["location"]:
        lines.append("Location: " + f["location"])
    lines += ["Screenshot: " + s for s in shots[:10]] + (["Screenshot: and %d more" % (len(shots) - 10)] if len(shots) > 10 else [])
    # No trailing newline: Linear trims it, and `create --verify` then reports a mismatch on a good create.
    marker = "\nvisual-review-fp:%s" % f["evidence"]["visual_review_fp"] if f["source"] == "visual" else ""
    return "\n".join(lines) + marker + "\nsurgeon-fp:%s" % f["fingerprint"]


def update_review_state(state, findings, resolved, date):
    """Tracks every real review finding (open or fixed) for the burn-down and the bundle ticks."""
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


# ---- filing -----------------------------------------------------------------------------

OFFICER = lib.Officer("surgeon", "Ship's Surgeon", "Surgeon", RUBRIC_FILE, BUILTIN_START_SOURCES,
                      start_word="Start them through the Navigator's start path, per the surgeon's rubric", start_source="",
                      pattern_sources=("review", "sweeper"))
iso_week = lib.iso_week


def found_line(count, first, last):
    return OFFICER.found_line(count, first, last)


def file_findings(findings, args, date, out, state, found, jev, gaps, marks=None):
    """Files the real, untracked findings; returns (writes_done, why Linear was stopped or None).

    Every finding goes to its source family's feature-area bundle (lib.Bundles), except a promotion-blocking invalid
    nightly E2E run (special e2e-invalid), which keeps its own item.
    """
    todo = [f for f in findings if f["class"] == "real" and not f["tracked"]]
    marks = {"marked": [], "would_mark": [], "skipped": [], "stopped": None, "noted": False} if marks is None else marks
    stopped = lib.paused_until(out, args.now)
    ledger_path = os.path.join(out, LEDGER_FILE)
    ledger = read_json(ledger_path, {})
    filer = lib.Filer(OFFICER, LIN, args.team, date, out, ledger, found, jev, args.max_creates)
    names = {}
    attach = {"pending": state.pop("pending_attach", [])}

    def area(f):
        fallback = VISUAL_AREA_FALLBACK if f["source"] == "visual" else args.triage_label
        return area_for(f["location"], f["title"] + " " + f["summary"], names["names"], fallback, not f.get("special")) or args.triage_label

    bundles = lib.Bundles(filer, args.bundle_cap, area=area)
    bundles_for = [f for f in todo if f["fingerprint"] and not f.get("special")]
    for f in bundles_for:
        f["bundle"] = {"family": FAMILY[f["source"]], "area": None}
        if f["source"] == "visual":
            shots = f["evidence"].get("screenshots") or []
            f["bundle"]["line"] = "visual-review-fp:%s%s" % (f["evidence"]["visual_review_fp"], "; screenshots: %s%s" % (
                ", ".join(shots[:3]), " and %d more" % (len(shots) - 3) if len(shots) > 3 else "") if shots else "")
    for f in todo:
        if not f["fingerprint"]:
            f["filing"] = {"action": "not-filed", "reason": "no key, title or location to fingerprint"}
    for fp, r in sorted(state.get("review", {}).items()):
        if r["state"] == "fixed":
            bundles.tick(fp)
    quiet = lib.file_bundled(filer, [f for f in todo if f["fingerprint"]], None, None, bundles)
    by_fp = {f["fingerprint"]: f for f in todo if f["fingerprint"]}
    quiet = quiet and not absorbed_singles(bundles, ledger, by_fp) and not bundles.state.get("uncommented")

    def flush_attach():
        if attach["pending"]:
            state["pending_attach"] = attach["pending"]
            gaps.append("%d screenshot(s) not attached yet; the next run retries them" % len(attach["pending"]))

    def attach_new(items):
        for f in items:
            filing = f["filing"] or {}
            if f["source"] == "visual" and args.visual_captures and (
                    filing.get("action") == "created" or (filing.get("action") == "bundled" and filing.get("new"))):
                attach["pending"] += attach_screenshots([{"issue": filing["issue"], "file": w, "first": date}
                                                         for w in f["evidence"]["screenshots"]], gaps, attach, date)

    def stop(reason, rate_limited=False):
        attach_new(todo)
        flush_attach()
        for f in todo:
            if not f["filing"] or "pending" in f["filing"]:
                f["filing"] = {"action": "not-filed", "reason": reason}
        if rate_limited:
            lib.pause_for_rate_limit(out, args.now)
        save(ledger_path, ledger, state, found, bundles)
        return lib.summary_rows(todo), reason

    if quiet and not attach["pending"]:
        save(ledger_path, ledger, state, found, bundles)
        return lib.summary_rows(todo), None
    if stopped:
        return stop(stopped)
    attach["pending"] = attach_screenshots(attach["pending"], gaps, attach, date)
    try:
        names["names"] = lib.label_names(LIN, args.team)
    except LinearError as exc:
        return stop("label lookup failed: %s" % exc, exc.code == "RATE_LIMITED")

    def label_set(f):
        if f.get("bundle") and f["bundle"]["area"] is None:
            f["bundle"]["area"] = area(f)
        wanted = ["Bug", SOURCE_LABEL[f["source"]], f["bundle"]["area"] if f.get("bundle") else area(f)]
        return wanted, [w for w in wanted if w.lower() not in names["names"]]

    def describe(f, near=None, recurrence=None):
        return description(f, date, near=near, recurrence=recurrence)

    try:
        lib.file_bundled(filer, [f for f in todo if f["fingerprint"]], label_set, describe, bundles)
        attach_new(todo)
        flush_attach()
        # Singles the Surgeon filed that a written bundle now lists are marked Duplicate of it (a reserved class is only noted on its line).
        marks.update(mark_absorbed(filer, bundles, absorbed_singles(bundles, ledger, by_fp), by_fp, True))
        if marks["noted"] and not marks["stopped"]:
            bundles.write(label_set)
    except LinearError as exc:
        if exc.code == "RATE_LIMITED":
            return stop("Linear rate limit reached: %s" % exc, True)
        return stop("%s; the next run continues from the ledger" % exc)
    if marks["stopped"]:
        code, why = marks["stopped"]
        if code == "RATE_LIMITED":
            lib.pause_for_rate_limit(out, args.now)
        save(ledger_path, ledger, state, found, bundles)
        return lib.summary_rows(todo), "duplicate marking stopped: %s" % why
    save(ledger_path, ledger, state, found, bundles)
    return lib.summary_rows(todo), None

def save(ledger_path, ledger, state, found, bundles):
    out = os.path.dirname(ledger_path)
    write_json(ledger_path, ledger)
    write_json(os.path.join(out, STATE_FILE), state)
    write_json(os.path.join(out, FOUND_FILE), found)
    bundles.save()



# ---- output -------------------------------------------------------------------------------

def render_md(doc, archive_md):
    head, _, rest = archive_md.partition("\n")
    lines = [head.replace("Triage officer digest", "Surgeon officer digest"), "", "Intake: %s." % (
        ", ".join("%s %d" % kv for kv in doc["intake"]["classes"].items()) or "nothing found")]
    lines.append("Linear writes: %s%s. Linear calls: %d of %d." % (doc["writes"], " (blocked: %s)" % doc["writes_blocked"] if doc["writes_blocked"] else "",
                                                                  doc["linear_calls"], doc["linear_call_budget"]))
    dup = doc["duplicates"]
    if dup["marked"] or dup["would_mark"] or dup["skipped"]:
        lines.append("Singles absorbed by a bundle: %d marked Duplicate, %d would be marked (writes: none), %d skipped%s." % (
            len(dup["marked"]), len(dup["would_mark"]), len(dup["skipped"]), "".join("; %s: %s" % (d["single"], d["why"]) for d in dup["skipped"])))
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


# ---- fold ---------------------------------------------------------------------------------

FOLD_OPENING = "Filed by the Ship's Surgeon from the "
FRICTION_OPENING = "Filed by the friction officer from the "
PAGE_CHECK_OPENING = "Filed by the page-check officer from the "
FOLD_OTHER = re.compile(r"^Filed by the (.+?) from ")
# fleet-app's own automated item families (its filers keep bundles of them in their own format; see fold_fleet_app).
DEP_TITLE = "Dependency a major version behind: "
E2E_TITLES = ("Nightly E2E: ", "Nightly E2E flaky: ")
CLUSTER_TITLE = "Code review findings: "
CLUSTER_LINE = re.compile(r"^- \[([ x])\] surgeon-fp:([0-9a-f]{64}) (.*) \((.*)\)$")
SOURCE_OF_NAME = {name: source for source, name in SOURCE_NAME.items()}


def fold_finding(ident, fp, source, title, location, severity, family, area=None, fleet=False, line=None):
    """One finding in the shape the bundle path takes; `fold_from` is the open item it is folded from."""
    return {"fingerprint": fp, "source": source, "title": text(title, 120), "summary": "", "location": text(location, 200),
            "severity": severity, "project": lib.FLEET_PROJECT if fleet else "", "class": "real", "tracked": None,
            "filing": None, "special": None, "fold_from": ident,
            "bundle": dict({"family": family, "area": area}, **({"line": line} if line else {}))}


def fold_findings(ident, issue):
    """(findings, why it stays single or None) for one open item the Surgeon filed; each finding is a dict the bundle
    path takes. A component cluster gives one finding per open line; a single item gives its own finding."""
    desc = str(issue.get("description") or "")
    title = text(issue.get("title"), 300)
    fleet = text(issue.get("project"), 80).lower() == lib.FLEET_PROJECT.lower()

    def one(fp, source, title, location, severity, line=None):
        return fold_finding(ident, fp, source, title, location, severity, FAMILY[source], fleet=fleet, line=line)
    if title.startswith(CLUSTER_TITLE):
        out = []
        for line in desc.splitlines():
            m = CLUSTER_LINE.match(line)
            if m and m.group(1) == " ":
                out.append(one(m.group(2), "review", m.group(3), "" if m.group(4) == "no file" else m.group(4), "low"))
        return out, None if out else "no open line"
    if "\nPromotion-blocking: yes" in desc:
        return [], "promotion-blocking, kept single"
    marks = re.findall(r"surgeon-fp:([0-9a-f]{64})", desc)
    first = desc.split("\n", 1)[0]
    source = next((s for name, s in SOURCE_OF_NAME.items() if first.endswith(" %s results." % name)), None)
    if not marks or not source:
        return [], "not a Surgeon finding item"
    severity = re.search(r"^Severity: (critical|high|medium|low)\.", desc, re.M)
    location = re.search(r"^Location: (.*)$", desc, re.M)
    visual = re.search(r"^visual-review-fp:([0-9a-f]{64})$", desc, re.M)
    return [one(marks[-1], source, title, location.group(1) if location else "", severity.group(1) if severity else "medium",
                "visual-review-fp:%s" % visual.group(1) if visual else None)], None


def fold_severity(desc, default):
    m = re.search(r"^Severity: (critical|high|medium|low)\b", desc, re.M)
    return m.group(1) if m else default


def fold_friction(ident, issue):
    """The one finding of an open item the friction officer filed (its category bundle is the area), else why it stays."""
    desc, friction = str(issue.get("description") or ""), _load("fm_officer_friction", "fm-officer-friction.py")
    mark = re.search(r"^friction-fp:([0-9a-f]{64})$", desc, re.M)
    if not desc.startswith(FRICTION_OPENING) or not mark:
        return [], "not a friction finding item"
    root = re.search(r"Root cause: ([^\s,]+) / ([^\s,]+?)(?:, (.*))?\.$", desc, re.M)
    cause, name = (root.group(1), root.group(3) or "") if root else ("other", "")
    return [fold_finding(ident, mark.group(1), cause, issue.get("title"), name, fold_severity(desc, "low"), "friction",
                         area=friction.CATEGORY.get(cause, "other"), fleet=True)], None


def fold_page_check(ident, issue):
    """The one finding of an open item the page-check officer filed (its page is the area), else why it stays."""
    desc = str(issue.get("description") or "")
    mark = re.search(r"^page-check-fp:([0-9a-f]{64})$", desc, re.M)
    page = re.search(r"^Severity: \w+\. Kind: \S+\. Page: (.+?)\. Object: ", desc, re.M)
    if not desc.startswith(PAGE_CHECK_OPENING) or not mark or not page:
        return [], "not a page-check finding item"
    return [fold_finding(ident, mark.group(1), "page-check", issue.get("title"), "", fold_severity(desc, "medium"), "page check",
                         area=page.group(1), fleet=True)], None


def in_hand(issue):
    """Why an item is a person's, not a bot's: someone started it or it is assigned (the design's "stay single")."""
    if text(issue.get("stateType")).lower() == "started" or text(issue.get("state")).lower() == "in progress":
        return "started, kept single"
    if issue.get("assignee"):
        return "assigned, kept single"
    return None


def lane_specs(args, names):
    """The officers whose open items fold into lib.Bundles in their own lane: the Surgeon, friction and the page check."""
    friction = _load("fm_officer_friction", "fm-officer-friction.py")
    page_check = _load("fm_officer_page_check", "fm-officer-page-check.py")

    def surgeon_area(f):
        fallback = VISUAL_AREA_FALLBACK if f["source"] == "visual" else args.triage_label
        return area_for(f["location"], f["title"], names, fallback, True) or args.triage_label

    def surgeon_labels(f):
        wanted = ["Bug", SOURCE_LABEL[f["source"]], f["bundle"]["area"] or surgeon_area(f)]
        return wanted, [w for w in wanted if w.lower() not in names]

    return [
        {"key": "surgeon", "maker": "Surgeon", "opening": FOLD_OPENING, "out": args.out, "officer": OFFICER, "parse": fold_findings,
         "area": surgeon_area, "labels": surgeon_labels, "recur_closed": True, "bump_closed": False, "in_hand": False},
        {"key": "friction", "maker": "friction officer", "opening": FRICTION_OPENING, "out": args.friction_out, "flag": "--friction-out",
         "officer": friction.officer(lib), "parse": fold_friction, "area": lambda f: f["bundle"]["area"],
         "labels": lambda f: lib.fleet_labels(friction.SOURCE_LABEL, names, friction.TYPE_LABEL),
         "recur_closed": True, "bump_closed": False, "in_hand": True},
        {"key": "page-check", "maker": "page-check officer", "opening": PAGE_CHECK_OPENING, "out": args.page_check_out,
         "flag": "--page-check-out", "officer": page_check.officer(lib), "parse": fold_page_check, "area": lambda f: f["bundle"]["area"],
         "labels": lambda f: lib.fleet_labels(page_check.SOURCE_LABEL, names, page_check.TYPE_LABEL),
         "recur_closed": False, "bump_closed": True, "in_hand": True},
    ]


def mark_duplicate(filer, ident, target):
    """Relates an original to its bundle and moves it to Duplicate (--dry-run before --verify); never deletes.
    A state update whose verify failed still counts when Linear now shows the item as Duplicate (relation written first)."""
    relate, move = ["issue", "relation", "add", ident, "--duplicate-of", target], ["issue", "update", ident, "--state", "Duplicate"]
    LIN(relate + ["--dry-run"])
    LIN(relate + ["--verify"])
    LIN(move + ["--dry-run"])
    try:
        LIN(move + ["--verify"])
    except LinearError as exc:
        if exc.code in lib.RATE_OR_BUDGET:
            raise
        filer.cache.pop(ident, None)
        try:
            if text(filer.view_issue(ident).get("stateType")).lower() != "duplicate":
                raise exc
        except LinearError:
            raise exc


MARK_CALLS = 7  # relation and state (dry-run, verify, and a re-read if the verify fails), then the comment (dry-run, verify)
RESERVED_LABELS = ("payments", "billing", "legal", "member copy", "member-copy", "data-rewriting", "data rewriting", "product")


def reserved_in(*texts):
    """The reserved class any of the texts asks for (lib.RESERVED, matched by the action), or None."""
    return next((name for name, rx in lib.RESERVED.items() if any(rx.search(t) for t in texts if t)), None)


def single_kept(issue):
    """(why a single item the Surgeon filed stays open, whether that is permanent) or (None, False) when it may be marked."""
    desc, title = str(issue.get("description") or ""), text(issue.get("title"), 300)
    labels = issue.get("labels") or []
    labels = [text(l.get("name") if isinstance(l, dict) else l, 60).lower() for l in (labels if isinstance(labels, list) else [labels])]
    if lib.is_closed(issue):
        return "already closed", True
    if title.startswith(lib.BUNDLE_PREFIX):
        return "is a bundle", True
    if not desc.startswith(FOLD_OPENING):
        return "not filed by the Surgeon (person-authored)", True
    if "\nPromotion-blocking: yes" in desc:
        return "promotion-blocking, kept single", True
    reserved = next((l for l in labels if l in RESERVED_LABELS), None) or reserved_in(title, desc)
    if reserved:
        return "reserved class: %s" % reserved, True
    held = in_hand(issue)
    return (held, False) if held else (None, False)


def absorbed_singles(bundles, ledger, fps):
    """(fingerprint, single item, bundle state) for each finding of `fps` that sits on a written open bundle while the
    ledger still names an older single item of its own; items already marked or kept are left out (lane state)."""
    done = set(bundles.state.get("folded", {})) | set(bundles.state.get("kept_single", {}))
    rows = []
    for fp in sorted(fps):
        b = bundles.bundles.get(bundles.member_of.get(fp, ""))
        single = ledger.get(fp)
        if b and single and single != b.get("issue") and single not in done and not b.get("closed") and bundles.written(b):
            rows.append((fp, single, b))
    return rows


def mark_absorbed(filer, bundles, rows, by_fp, apply):
    """Marks each single item the Surgeon filed as Duplicate of the bundle that now lists its finding, with one comment
    on it, once (the lane's `folded` map). Person-authored items, started or assigned ones and reserved classes stay open;
    a reserved class is named on its bundle line. Not apply: only reports what it would mark. Returns the counts."""
    res = {"marked": [], "would_mark": [], "skipped": [], "stopped": None, "noted": False}
    folded, kept = bundles.state.setdefault("folded", {}), bundles.state.setdefault("kept_single", {})
    uncommented = bundles.state.setdefault("uncommented", {})

    def comment(single, bundle):
        body = ("Marked Duplicate of %s: the Ship's Surgeon now lists this finding on that bundle's checklist, "
                "so one pull request fixes it with the rest. Reopen this item if it should stay on its own." % bundle)
        call = ["issue", "comment", single, "--body", body]
        try:
            LIN(call + ["--dry-run"])
            LIN(call + ["--verify"])
            uncommented.pop(single, None)
        except LinearError as exc:
            if exc.code in lib.RATE_OR_BUDGET:
                res["stopped"] = (exc.code, str(exc))
                return
            uncommented.pop(single, None)
            res["skipped"].append((single, "marked Duplicate, comment failed: %s" % exc))

    if apply:
        for single, bundle in sorted(uncommented.items()):
            comment(single, bundle)
            if res["stopped"]:
                return res
    for fp, single, b in rows:
        f = by_fp.get(fp)
        reserved = lib.reserved_class(f) if f else None
        if reserved:
            note = "single %s kept open: reserved class %s" % (single, reserved)
            m = b["members"][fp]
            if note not in m.get("note", ""):
                m["note"] = "; ".join(x for x in (m.get("note"), note) if x)
                bundles.dirty.add(b["fp"])
                res["noted"] = True
            res["skipped"].append((single, "reserved class: %s" % reserved))
            if apply:
                kept[single] = "reserved class: %s" % reserved
            continue
        if not apply:
            res["would_mark"].append((single, b["issue"]))
            continue
        try:
            why, permanent = single_kept(filer.view_issue(single))
            if why:
                res["skipped"].append((single, why))
                if permanent:
                    kept[single] = why
                continue
            if LIN.budget - LIN.n < MARK_CALLS:
                raise LinearError("CALL_BUDGET", "Linear call budget of %d too low to mark %s" % (LIN.budget, single))
            mark_duplicate(filer, single, b["issue"])
            folded[single] = uncommented[single] = b["issue"]
            res["marked"].append((single, b["issue"]))
        except LinearError as exc:
            if exc.code in lib.RATE_OR_BUDGET:
                res["stopped"] = (exc.code, str(exc))
                break
            res["skipped"].append((single, "not marked: %s" % exc))
            continue
        comment(single, b["issue"])
        if res["stopped"]:
            break
    return res


def plan_marks(findings, args, out, marks):
    """A run with writes: none changes nothing: it only reports the singles it would mark (local checks only, no Linear call)."""
    todo = {f["fingerprint"]: f for f in findings if f["class"] == "real" and not f["tracked"] and f["fingerprint"] and not f.get("special")}
    ledger = read_json(os.path.join(out, LEDGER_FILE), {})
    filer = lib.Filer(OFFICER, LIN, args.team, args.date, out, ledger, {}, lib.Jev(None), args.max_creates)
    bundles = lib.Bundles(filer, args.bundle_cap)
    marks.update(mark_absorbed(filer, bundles, absorbed_singles(bundles, ledger, todo), todo, False))


def fold_lane(args, lane, idents, names, date, apply_ok=True):
    """Folds the open items of one officer into its feature-area bundles (lib.Bundles, state in the officer's lane).
    Returns the exit status. Prints the plan; with --apply writes the bundles, then marks each original a duplicate."""
    out = lane["out"]
    if out is None and not idents:
        return 0
    if out is None and args.apply:
        print("- not folded: %d open item(s) the %s made (pass %s <its lane directory> so the officer sees the bundles)" % (
            len(idents), lane["maker"], lane["flag"]))
        return 1
    if out is None:
        out = tempfile.mkdtemp(prefix="fm-fold-")  # a dry run reads no lane state; the plan assumes a lane with no bundles
    if args.apply:
        os.makedirs(out, exist_ok=True)
    ledger = read_json(os.path.join(out, LEDGER_FILE), {})
    found = read_json(os.path.join(out, FOUND_FILE), {})
    filer = lib.Filer(lane["officer"], LIN, args.team, date, out, ledger, found, lib.Jev(None), args.max_creates, bump_closed=lane["bump_closed"])
    bundles = lib.Bundles(filer, args.bundle_cap, recur_closed=lane["recur_closed"], area=lane["area"])
    folded = bundles.state.setdefault("folded", {})
    items, kept, findings = [], [], []
    for ident in idents:
        if ident in folded:
            continue
        try:
            issue = filer.view_issue(ident)
            held = lane["in_hand"] and in_hand(issue)
            fs, why = ([], held) if held else lane["parse"](ident, issue)
        except LinearError as exc:
            print("fm-officer-surgeon fold: reading %s failed: %s" % (ident, exc), file=sys.stderr)
            return 1
        if why:
            kept.append((ident, why))
            continue
        items.append(ident)
        for f in fs:
            if f["bundle"]["area"] is None:
                f["bundle"]["area"] = lane["area"](f)
            findings.append(f)
    plan = collections.OrderedDict()
    for f in sorted(findings, key=lambda f: (f["bundle"]["family"], f["bundle"]["area"], bool(f["project"]), f["location"], f["title"])):
        key = bundles.key(f)
        plan.setdefault(key, {"findings": [], "items": [], "known": 0})
        row = plan[key]
        if f["fingerprint"] in bundles.member_of and not bundles.bundles[bundles.member_of[f["fingerprint"]]].get("closed"):
            row["known"] += 1
        elif all(g["fingerprint"] != f["fingerprint"] for g in row["findings"]):
            row["findings"].append(f)
        if f["fold_from"] not in row["items"]:
            row["items"].append(f["fold_from"])
    if items or kept or lane["key"] == "surgeon":
        print("Fold %s: %d open item(s) the %s made fold into %d area bundle(s); %d finding(s), cap %d a bundle." % (
            "plan (dry run, nothing written)" if not args.apply else "run", len(items), lane["maker"], len(plan), len({f["fingerprint"] for f in findings}), bundles.cap))
    for (family, area_name, fleet), row in plan.items():
        open_parts = bundles.open_parts((family, area_name, fleet))
        room = sum(bundles.room(b) for b in open_parts)
        new_parts = max(0, -(-(len(row["findings"]) - room) // bundles.cap))
        print("- %s%s: %d finding(s) from %d item(s) (%s)%s; %s" % (
            lib.bundle_title(area_name, family, 1), " [Fleet]" if fleet else "", len(row["findings"]) + row["known"], len(row["items"]),
            ", ".join(sorted(row["items"], key=lambda i: (int(re.sub(r"\D", "", i) or 0), i))), ", %d already listed" % row["known"] if row["known"] else "",
            "%d new bundle(s)" % new_parts + (" and appends to %s" % ", ".join(b["issue"] for b in open_parts if b.get("issue")) if open_parts else "")))
    for ident, why in kept:
        print("- kept: %s (%s)" % (ident, why))
    if not args.apply:
        return 0
    for f in findings:
        # One fingerprint is queued once, however many items carried it (those items all point at its one bundle line).
        if f["fingerprint"] in bundles.seen:
            continue
        if f["fingerprint"] not in bundles.member_of or bundles.bundles[bundles.member_of[f["fingerprint"]]].get("closed"):
            bundles.unkeyed.append((f, ""))
            bundles.seen[f["fingerprint"]] = f
    # Self-heal a half-written earlier run: a bundle whose Linear body differs from its state is rewritten from state.
    for b in bundles.bundles.values():
        if b.get("issue") and not b.get("closed") and not bundles.written(b):
            bundles.dirty.add(b["fp"])
    try:
        bundles.write(lane["labels"])
    except LinearError as exc:
        print("fm-officer-surgeon fold: stopped: %s" % exc, file=sys.stderr)
    status = 0
    for ident in items:
        homes = [bundles.bundles.get(bundles.member_of.get(f["fingerprint"], "")) for f in findings if f["fold_from"] == ident]
        if not homes or not all(bundles.written(b) for b in homes):
            print("- not folded: %s (not every finding of it is on a written bundle)" % ident)
            status = 1
            continue
        targets = collections.Counter(b["issue"] for b in homes)
        target = min(targets, key=lambda t: (-targets[t], t))
        try:
            mark_duplicate(filer, ident, target)
            folded[ident] = target
            print("- folded: %s is a duplicate of %s" % (ident, target))
        except LinearError as exc:
            print("- not folded: %s (%s)" % (ident, exc))
            status = 1
            if exc.code in lib.RATE_OR_BUDGET:
                break
    bundles.save()
    write_json(os.path.join(out, LEDGER_FILE), ledger)
    return status


# ---- fleet-app's own bundles ---------------------------------------------------------------
# fleet-app keeps its dependency-major bundles (src/dependencies/scan/bundle.ts) and its nightly E2E bundles
# (deploy/nightly-e2e/nightly_linear.py) in a body format of its own: a marker line, `Part: N`, `### <file>` headings and one
# `- [ ] <fingerprint> — <text>` line per finding. The fold writes that format so those filers adopt the bundle and keep
# appending to it. The ports below follow fleet-app origin/main 62e6802; nothing here changes fleet-app.

FA_LINE = re.compile(r"^- \[( |x)\] (\S+) — (.*)$")
FA_HEADING = re.compile(r"^### (.*)$")
FA_DEP_AREA = "developer-tools"
FA_DEP_FAMILY = "dependency majors"
FA_AREA_TOKENS = {
    "deal": "deal-finder", "deals": "deal-finder", "finder": "deal-finder", "dealfinder": "deal-finder", "watchlist": "watchlist", "portfolio": "portfolio",
    "map": "maps", "maps": "maps", "calculator": "calculators", "calculators": "calculators", "calc": "calculators", "propertydata": "property-data",
    "ingest": "ingestion", "ingestion": "ingestion", "api": "api", "infra": "infrastructure", "infrastructure": "infrastructure", "ci": "ci-cd",
    "ui": "ui-ux", "nav": "ui-ux", "navigation": "ui-ux", "layout": "ui-ux", "banner": "ui-ux", "login": "ui-ux", "auth": "ui-ux",
}


def fa_area(spec_file):
    """The feature area of a failing test, from its spec file's name (nightly_linear.py area_of); "testing" when no word names one."""
    for token in re.split(r"[^a-z0-9]+", spec_file.lower()):
        if token in FA_AREA_TOKENS:
            return FA_AREA_TOKENS[token]
    return "testing"


def fa_title(area, family, part):
    return "%s%s (%s)%s" % (lib.BUNDLE_PREFIX, area, family, " part %d" % part if part > 1 else "")


def fa_marker(kind, area, family):
    return "Bundle: dependency-major/%s" % area if kind == "dependency-major" else "Bundle: nightly-e2e/%s/%s" % (area, family.replace(" ", "-"))


def fa_open_count(b):
    return sum(1 for ln in b["lines"] if not ln["done"])


def fa_parse(desc):
    """A fleet-app bundle body as its filers read it: head, checklist lines (with their file heading), tail and part."""
    rows = str(desc or "").split("\n")
    is_list = [bool(FA_HEADING.match(r.strip()) or FA_LINE.match(r.strip())) for r in rows]
    part = re.search(r"^Part: (\d+)$", str(desc or ""), re.M)
    if not any(is_list):
        return {"part": int(part.group(1)) if part else 1, "head": rows, "lines": [], "tail": []}
    first, last = is_list.index(True), len(rows) - 1 - is_list[::-1].index(True)
    lines, where = [], ""
    for row in rows[first:last + 1]:
        h, m = FA_HEADING.match(row.strip()), FA_LINE.match(row.strip())
        if h:
            where = h.group(1)
        elif m:
            lines.append({"fingerprint": m.group(2), "done": m.group(1) == "x", "text": m.group(3), "file": where})
    head = rows[:first]
    while head and not head[-1].strip():
        head.pop()
    return {"part": int(part.group(1)) if part else 1, "head": head, "lines": lines, "tail": rows[last + 1:]}


def fa_render(b):
    """The body to write: head and tail as they are, the checklist grouped by file (files and fingerprints in order)."""
    rows = []
    for where in sorted({ln["file"] for ln in b["lines"]}):
        rows += ["", "### %s" % where] + ["- [%s] %s — %s" % ("x" if ln["done"] else " ", ln["fingerprint"], ln["text"])
                                          for ln in sorted((ln for ln in b["lines"] if ln["file"] == where), key=lambda ln: ln["fingerprint"])]
    return "\n".join(b["head"] + rows + b["tail"])


def fa_new(key, part, cap, app_url):
    """A new bundle with the head and tail fleet-app's own filer writes for its family."""
    kind, area, family = key
    marker = fa_marker(kind, area, family)
    if kind == "dependency-major":
        head = ["Direct packages a major version behind in %s, found by the nightly dependency scan. One bundle holds up to %d findings: the scan appends each new one here, ticks a line when its finding is fixed on staging or gone, and never removes one." % (area, cap),
                "", marker, "Part: %d" % part]
        tail = ["", "Rule (Lee, 21 Oct 2026): a direct package a major version behind is a High-priority item. One worker fixes the unticked lines in one PR, tested once."]
        tail += ["Dependencies page: %s/dependencies#major" % app_url] if app_url else []
    else:
        head = ["Failing and flaky tests in %s from the nightly E2E run (systemd user timers nightly-e2e and nightly-e2e-midday). One bundle holds up to %d open findings: each new test is appended here, a line is ticked when a merged change fixes or quarantines its test (a pass on the same commit is not a fix), and none is removed. The release runbook needs a green nightly before a release, so these need a fix or a ruling from Lee. One worker fixes the unticked lines in one PR." % (area, cap),
                "", marker, "Part: %d" % part]
        tail = ["", "Per the release runbook: never quarantine, skip, retry or weaken a test. If the product is wrong, fix the product; if the test is wrong, say why in a comment."]
    return {"part": part, "head": head, "lines": [], "tail": tail}


def fa_labels(key):
    kind, area, family = key
    if kind == "dependency-major":
        return ["Chore", "scheduled-review", FA_DEP_AREA]
    return ["Bug", "agent", "testing"] + ([area] if area != "testing" else []) + (["flaky"] if family == "flaky tests" else [])


def fa_dependency(ident, desc, title):
    """(finding, why it stays single) for a "Dependency a major version behind" item, as fleet-app's lineText and fileOf write it."""
    fp = re.search(r"^Fingerprint: (major:\S+)$", desc, re.M)
    intro = re.search(r"found that (npm|NuGet) package \*\*(.+?)\*\* is a major version behind", desc)
    used = re.search(r"^[*-] Versions in use: (.+)$", desc, re.M)
    latest = re.search(r"^[*-] Newest release: (.+)$", desc, re.M)
    state = re.search(r"^Fix state: (\S+)$", desc, re.M)
    if not (fp and intro and used and latest and state):
        return None, "not a major-version item fleet-app's scan can read back"
    if state.group(1) != "unfixed":
        return None, "fix state %s, kept single" % state.group(1)
    projects = re.search(r"^[*-] Projects: (.+)$", desc, re.M)
    shown = projects.group(1).strip() if projects else ""
    page = re.search(r"(https?://[^\s\]()<>]+?)/dependencies#findings", desc)
    return {"kind": "dependency-major", "area": FA_DEP_AREA, "family": FA_DEP_FAMILY, "fingerprint": fp.group(1), "high": True,
            "file": "project not known" if not shown or shown == "not known" else shown, "app_url": page.group(1) if page else "",
            "text": "%s %s to %s (%s)" % (intro.group(2), used.group(1).split(", ")[0], latest.group(1).strip(), intro.group(1))}, None


def fa_nightly(ident, desc, title):
    """(finding, why it stays single) for a "Nightly E2E" test item, as nightly_linear.py's line_text and area_of write it."""
    fp = re.search(r"^fingerprint: (e2e-[0-9a-f]+)$", desc, re.M) or re.search(r"^Fingerprint: (e2e-[0-9a-f]+)$", desc, re.M)
    test = re.search(r"^Test: (.+)$", desc, re.M)
    if not (fp and test):
        return None, "a night roll-up or run notice, not one test; kept single"
    test_id = test.group(1).strip()
    spec_file = test_id.split(" › ")[0]
    staging = re.search(r"^Staging: (\S+) .*run on (\d{4}-\d{2}-\d{2})", desc, re.M)
    result = re.search(r"^Result file: (.+)$", desc, re.M)
    klass = re.search(r"^Classification: ([A-Za-z0-9_-]+)\.", desc, re.M)
    error = re.search(r"^First error line: (.*)$", desc, re.M)
    flaky = title.startswith("Nightly E2E flaky: ")
    return {"kind": "nightly-e2e", "area": fa_area(spec_file), "family": "flaky tests" if flaky else "nightly E2E", "fingerprint": fp.group(1),
            "high": not re.search(r"^Release-blocking: no$", desc, re.M), "file": spec_file, "app_url": "",
            "text": "%s — %s: %s (first seen %s, staging %s; result %s)" % (
                test_id.split(" › ", 1)[-1], klass.group(1) if klass else "unclassified", " ".join((error.group(1) if error else "").split())[:160],
                staging.group(2) if staging else "unknown", staging.group(1)[:12] if staging else "unknown", result.group(1).strip() if result else "unknown")}, None


def fa_part_of(title, base):
    if title == base:
        return 1
    m = re.fullmatch(re.escape(base) + r" part (\d+)", title)
    return int(m.group(1)) if m else None


def fa_load(filer, key):
    """(open bundles, every part number seen): the family's items by exact title, then those whose body holds the marker line."""
    base, marker = fa_title(key[1], key[2], 1), fa_marker(*key)
    seen, open_bundles = [], []
    for h in filer.title_index():
        ident, part = text(h.get("identifier"), 20), fa_part_of(text(h.get("title"), 300), base)
        if part is None:
            continue
        seen.append(part)
        if lib.is_closed(h):
            continue
        desc = str(filer.view_issue(ident).get("description") or "")
        if marker in [row.strip() for row in desc.split("\n")]:
            b = fa_parse(desc)
            b.update(id=ident, dirty=False, items=[], new=False)
            seen.append(b["part"])
            open_bundles.append(b)
    return sorted(open_bundles, key=lambda b: b["part"]), seen


def fold_fleet_app(args, names, idents, date, titles):
    """Folds fleet-app's open "Dependency a major version behind" and "Nightly E2E" items into bundles in fleet-app's own format."""
    out = args.out
    filer = lib.Filer(OFFICER, LIN, args.team, date, out, {}, {}, lib.Jev(None), args.max_creates)
    filer.titles = list(titles)  # the list the fold already read, so bundle titles are looked up with no second read
    findings, kept = [], []
    for ident in idents:
        try:
            issue = filer.view_issue(ident)
        except LinearError as exc:
            print("fm-officer-surgeon fold: reading %s failed: %s" % (ident, exc), file=sys.stderr)
            return 1
        held = in_hand(issue)
        title, desc = text(issue.get("title"), 300), str(issue.get("description") or "")
        f, why = (None, held) if held else (fa_dependency if title.startswith(DEP_TITLE) else fa_nightly)(ident, desc, title)
        if why:
            kept.append((ident, why))
            continue
        f["fold_from"] = ident
        findings.append(f)
    groups = collections.OrderedDict()
    for f in sorted(findings, key=lambda f: (f["kind"], f["area"], f["family"], f["file"], f["fingerprint"])):
        groups.setdefault((f["kind"], f["area"], f["family"]), []).append(f)
    app_url = next((f["app_url"] for f in findings if f["app_url"]), "")
    homes, plan, status = {}, [], 0  # item -> its bundle (a dict) or None when the bundle could not be made
    for key, fs in groups.items():
        try:
            bundles, seen = fa_load(filer, key)
        except LinearError as exc:
            print("fm-officer-surgeon fold: reading the %s bundles failed: %s" % (fa_title(key[1], key[2], 1), exc), file=sys.stderr)
            return 1
        listed = {ln["fingerprint"]: b for b in bundles for ln in b["lines"]}
        added, appended_to, news = 0, [], []
        for f in fs:
            if f["fingerprint"] in listed:
                homes[f["fold_from"]] = listed[f["fingerprint"]]
                continue
            target = next((b for b in bundles if fa_open_count(b) < args.bundle_cap), None)
            if target is None:
                target = dict(fa_new(key, max(seen + [0]) + 1, args.bundle_cap, app_url), id=None, dirty=True, items=[], new=True)
                seen.append(target["part"])
                bundles.append(target)
                news.append(target)
            target["lines"].append({"fingerprint": f["fingerprint"], "done": False, "text": f["text"], "file": f["file"]})
            target["items"].append(f["fold_from"])
            target["dirty"] = True
            if target["id"] and target["id"] not in appended_to:
                appended_to.append(target["id"])
            listed[f["fingerprint"]] = target
            homes[f["fold_from"]] = target
            added += 1
        plan.append((key, fs, bundles, news, appended_to, len(fs) - added))
    print("Fold %s: %d open item(s) fleet-app filed fold into %d bundle(s) of its own format; %d finding(s), cap %d a bundle." % (
        "plan (dry run, nothing written)" if not args.apply else "run", len(findings), len(plan), len(findings), args.bundle_cap))
    for key, fs, bundles, news, appended_to, known in plan:
        print("- %s: %d finding(s) from %d item(s) (%s)%s; %d new bundle(s)%s" % (
            fa_title(key[1], key[2], 1), len(fs), len(fs), ", ".join(sorted((f["fold_from"] for f in fs), key=lambda i: (int(re.sub(r"\D", "", i) or 0), i))),
            ", %d already listed" % known if known else "", len(news), " and appends to %s" % ", ".join(appended_to) if appended_to else ""))
    for ident, why in kept:
        print("- kept: %s (%s)" % (ident, why))
    if not args.apply:
        return 0
    written = {}
    for key, fs, bundles, news, appended_to, known in plan:
        for b in [b for b in bundles if b["dirty"]]:
            title, body, fp = fa_title(key[1], key[2], b["part"]), fa_render(b), "fold:%s:%s:%s:%d" % (key[0], key[1], key[2], b["part"])
            try:
                if b["id"]:
                    filer.update_body(b["id"], fp, body)
                else:
                    wanted = fa_labels(key)
                    missing = [w for w in wanted if w.lower() not in names]
                    if missing:
                        raise LinearError("LABELS", "label(s) missing in team %s: %s" % (args.team, ", ".join(missing)))
                    if filer.over_cap():
                        raise LinearError("CAP", "over max-creates for this run")
                    b["id"], _, _ = filer.create(fp, title, body, wanted, "2" if key[0] == "dependency-major" or any(f["high"] for f in fs) else "3")
                written[id(b)] = b
            except LinearError as exc:
                print("- not written: %s (%s)" % (title, exc))
                status = 1
                if exc.code in lib.RATE_OR_BUDGET:
                    return status
    for ident, b in homes.items():
        if b["dirty"] and id(b) not in written:
            print("- not folded: %s (its bundle was not written)" % ident)
            status = 1
            continue
        try:
            mark_duplicate(filer, ident, b["id"])
            print("- folded: %s is a duplicate of %s" % (ident, b["id"]))
        except LinearError as exc:
            print("- not folded: %s (%s)" % (ident, exc))
            status = 1
            if exc.code in lib.RATE_OR_BUDGET:
                break
    return status


def fold(args):
    """Lists the open automated items the fold knows and folds each into its bundle; see `fold --help`."""
    LIN.reset(args.max_linear_calls)
    date = datetime.datetime.fromtimestamp(args.now, datetime.timezone.utc).strftime("%Y-%m-%d")
    try:
        names = lib.label_names(LIN, args.team)
        listed = LIN(["issue", "list", "--team", args.team, "--all", "--max-items", str(args.max_items), "--limit", "100",
                      "--fields", "description,stateType,project"])
    except LinearError as exc:
        print("fm-officer-surgeon fold: Linear read failed: %s" % exc, file=sys.stderr)
        return 1
    lanes = lane_specs(args, names)
    mine, fleet_app, others = {lane["key"]: [] for lane in lanes}, [], collections.Counter()
    for h in dicts(listed.get("issues")):
        ident, desc, title = text(h.get("identifier"), 20), str(h.get("description") or ""), text(h.get("title"), 300)
        if not ident or lib.is_closed(h) or title.startswith(lib.BUNDLE_PREFIX):
            continue
        lane = next((lane for lane in lanes if desc.startswith(lane["opening"])), None)
        if lane:
            mine[lane["key"]].append(ident)
        elif not FOLD_OTHER.match(desc) and (title.startswith(DEP_TITLE) or title.startswith(E2E_TITLES)):
            fleet_app.append(ident)
        elif FOLD_OTHER.match(desc):
            others["filed by the %s" % FOLD_OTHER.match(desc).group(1)] += 1
    status = 0
    for lane in lanes:
        status = fold_lane(args, lane, mine[lane["key"]], names, date) or status
    if fleet_app:
        status = fold_fleet_app(args, names, fleet_app, date, dicts(listed.get("issues"))) or status
    for name, n in sorted(others.items()):
        print("- not folded yet: %d open item(s) %s; this command folds only the Surgeon's, friction's, page check's and fleet-app's" % (n, name))
    return status


def fold_main(argv):
    parser = argparse.ArgumentParser(prog="fm-officer-surgeon.py fold", description=(
        "Fold the open PC items the automated sources made (one per finding, or one per component cluster) into feature-area bundles: "
        "the Surgeon's, the friction officer's, the page-check officer's, and fleet-app's \"Dependency a major version behind\" and "
        "\"Nightly E2E\" items. "
        "A dry run by default: it reads Linear (label list, issue list, issue view) and prints, per bundle, the findings and "
        "items that would go there, what stays single (an invalid nightly E2E run blocks promotion, a night roll-up, an item someone "
        "started or is assigned, a fixed-on-staging dependency) and other officers' items it leaves alone. "
        "With --apply it creates or updates the bundles, then marks each original a duplicate of its bundle "
        "(`issue relation add --duplicate-of`, then state Duplicate; --dry-run before --verify). It never deletes an item. "
        "The Surgeon's, friction's and page check's bundles keep their state in that officer's lane directory; fleet-app's are "
        "written in fleet-app's own body format (marker, Part, file headings, `- [ ] <fingerprint> — <text>`) so its nightly filers adopt them."))
    parser.add_argument("--out", required=True, help="the Surgeon's lane directory (its bundles.json and ledger)")
    parser.add_argument("--friction-out", help="the friction officer's lane directory; --apply folds friction items only with it")
    parser.add_argument("--page-check-out", help="the page-check officer's lane directory; --apply folds page-check items only with it")
    parser.add_argument("--team", default="PC")
    parser.add_argument("--triage-label", default="triage")
    parser.add_argument("--bundle-cap", type=int, default=lib.DEFAULT_BUNDLE_CAP)
    parser.add_argument("--max-items", type=int, default=1000, help="newest items of the team read")
    parser.add_argument("--max-creates", type=int, default=100, help="new bundles one source (Surgeon, friction, page check, fleet-app) may create")
    parser.add_argument("--max-linear-calls", type=int, default=1500)
    parser.add_argument("--now", type=int)
    parser.add_argument("--apply", action="store_true", help="write: create or update bundles and mark each original Duplicate")
    args = parser.parse_args(argv)
    if args.team != "PC" or args.bundle_cap < 1 or args.max_items < 1 or args.max_creates < 1 or args.max_linear_calls < 1:
        parser.error("fold needs --team PC and --bundle-cap, --max-items, --max-creates and --max-linear-calls of at least 1")
    args.now = int(time.time()) if args.now is None else args.now
    return fold(args)


def main(argv):
    if argv[:1] == ["fold"]:
        return fold_main(argv[1:])
    parser = argparse.ArgumentParser(prog="fm-officer-surgeon.py")
    parser.add_argument("action", choices=["run"])
    parser.add_argument("--archive", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--home", action="append", default=[])
    parser.add_argument("--hosts", default="")
    parser.add_argument("--model", default="none")
    lib.add_common_args(parser, RUBRIC_FILE)
    parser.add_argument("--area", default="", help="ignored: the area label now comes from each finding")
    parser.add_argument("--staging-repo", default=STAGING_REPO)
    parser.add_argument("--visual-findings", default="", help="the nightly visual review's findings file; empty leaves the source off")
    parser.add_argument("--sweeper-runs", default="", help="the sweeper's run directory (<run id>/bundle.json); default $PC_SWEEPER_RUNS, then ~/services/pc-sweeper/runs")
    parser.add_argument("--visual-captures", default="", help="the capture directory that file's screenshot paths are relative to")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.date):
        parser.error("--date must be YYYY-MM-DD")
    if not args.staging_repo:
        parser.error("--staging-repo must not be empty")
    lib.check_common_args(parser, args)
    LIN.reset(args.max_linear_calls)
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
    out = args.out
    state = read_json(os.path.join(out, STATE_FILE), {})
    findings, gaps, resolved = intake(args.app, args.staging_repo, state, args.sweeper_runs)
    rubric = lib.load_rubric(args.rubric, OFFICER)
    jev = lib.Jev(args.jev)
    found = read_json(os.path.join(out, FOUND_FILE), {})
    store = read_json(os.path.join(out, PATTERN_FILE), {})
    visual, visual_held, visual_gaps = visual_intake(args.visual_findings, args.visual_captures, state,
                                                     read_json(os.path.join(out, LEDGER_FILE), {}), args.date, args.writes)
    findings, gaps = findings + visual, gaps + visual_gaps
    update_review_state(state, findings, resolved, args.date)
    apply_found(findings, found, read_json(os.path.join(out, LEDGER_FILE), {}))
    marks = {"marked": [], "would_mark": [], "skipped": [], "stopped": None, "noted": False}
    if args.writes == "linear":
        writes, blocked = file_findings(findings, args, args.date, out, state, found, jev, gaps, marks)
    else:
        writes, blocked = [], None
        plan_marks(findings, args, out, marks)
    apply_found(findings, found, read_json(os.path.join(out, LEDGER_FILE), {}))
    start_homes = lib.parse_start_homes(args.start_home)
    main_home = args.fm_home or (args.home[0] if args.home else "")
    starts, held, asks = lib.plan_starts(OFFICER, findings, rubric, args.date, args.writes, main_home, start_homes, state.setdefault("handled", {}), state.setdefault("starts_by_fp", {}))
    asks.extend(a for a in [visual_ask(visual_held, args.date)] if a)
    if rubric.pattern_memory:
        lib.update_patterns(OFFICER, store, findings, jev, args.date)
    pattern_requests, captures, lint = lib.pattern_outputs(OFFICER, store, rubric, args.date, main_home, start_homes)
    starts.extend(pattern_requests)
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
        "duplicates": {"marked": [dict(single=a, bundle=b) for a, b in marks["marked"]], "would_mark": [dict(single=a, bundle=b) for a, b in marks["would_mark"]],
                       "skipped": [dict(single=a, why=w) for a, w in marks["skipped"]]},
        "linear_calls": LIN.n, "linear_call_budget": LIN.budget,
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
