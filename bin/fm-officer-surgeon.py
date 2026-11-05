#!/usr/bin/env python3
"""fm-officer-surgeon.py - the Ship's Surgeon's daily pass: triage, then intake.

Run only through `bin/fm-officer.sh run <id>`, which owns the officer contract;
docs/configuration.md "Officers" owns the registry schema, the officer-roles
skill owns what the Surgeon may and may never do, docs/officers/contract.md owns the
FIND, FILE, TRIAGE, START contract that bin/fm-officer-linear.py implements for every officer,
and docs/officers/surgeon-rubric.md owns what counts as work, how it is scored and what starts by itself.

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
     (AREA_RULES; a nightly E2E failure tries the feature rules on its spec path and words
     before `testing`); with no fit it is --triage-label; a label missing from team PC
     means the finding is reported and not filed. The Surgeon never creates a label.
  2. medium or higher findings, and every non-review finding, each get their own
     item. Low review findings are clustered, one item per component: the group of
     the first CLUSTER_PARTS directory parts of the file, split one level deeper
     (again while a subgroup still passes it) when a group passes CLUSTER_SPLIT_OVER findings, subgroups under
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

Start requests: a real, untracked, filed finding whose severity (medium, high, critical)
and source the rubric admits, whose score reaches the rubric's minimum (so a medium
finding starts once it is found 3 times), and that matches no reserved class (each anchored
to its action, e.g. rotating a credential, rewording member-facing text) becomes a start request on the progress officer's path (start-requests.sh for this
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
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys


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
LIN = lib.Linear()

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
# Clustering of low review findings (the rule main measured on the 4 Nov findings file).
CLUSTER_PARTS = 2
CLUSTER_SPLIT_OVER = 25
CLUSTER_MIN_SUBGROUP = 10
CLUSTER_MIN_GROUP = 3
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


def intake(app, staging_repo):
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
        findings += judge_sweeper(sweeps)
    return findings, gaps, resolved

# ---- area, clusters ---------------------------------------------------------------------

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
    """{location: cluster key}: the path decides the group, the counts only split or fold it.

    A group over CLUSTER_SPLIT_OVER findings splits one level deeper, again while a subgroup is still over
    it; subgroups under CLUSTER_MIN_SUBGROUP (and files with no deeper directory) fold into "<parent> (other)";
    a cluster still under CLUSTER_MIN_GROUP folds into "<first part> (misc)".
    """
    weight = collections.Counter(locations)
    state = {}
    for loc in weight:
        state[loc] = ["(no file)" if not loc else "/".join(path_dirs(loc)[:CLUSTER_PARTS]) or "(root)", CLUSTER_PARTS, False]
    progressed = True
    while progressed:
        progressed = False
        groups = collections.defaultdict(list)
        for loc, (key, level, done) in state.items():
            if not done:
                groups[(key, level)].append(loc)
        for (key, level), locs in groups.items():
            if sum(weight[l] for l in locs) <= CLUSTER_SPLIT_OVER or not any(len(path_dirs(l)) > level for l in locs):
                for l in locs:
                    state[l][2] = True
                continue
            sub = collections.Counter()
            for l in locs:
                dirs = path_dirs(l)
                if len(dirs) > level:
                    sub["/".join(dirs[:level + 1])] += weight[l]
            for l in locs:
                dirs = path_dirs(l)
                if len(dirs) > level and sub["/".join(dirs[:level + 1])] >= CLUSTER_MIN_SUBGROUP:
                    state[l][0], state[l][1] = "/".join(dirs[:level + 1]), level + 1
                else:
                    state[l][0], state[l][2] = key + " (other)", True
            progressed = True
    sizes = collections.Counter()
    for loc, (key, _, _) in state.items():
        sizes[key] += weight[loc]
    return {loc: (key if sizes[key] >= CLUSTER_MIN_GROUP or key in ("(no file)", "(root)")
                  else key.split("/")[0].replace(" (other)", "") + " (misc)") for loc, (key, _, _) in state.items()}


def plain_words(key):
    return " ".join(re.sub(r"[/_\-]+", " ", re.sub(r"([a-z])([A-Z])", r"\1 \2", key)).split())

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
    lines += ["%s: %s" % (k, text(v, 300)) for k, v in sorted(f["evidence"].items()) if v not in (None, "")]
    if f["location"]:
        lines.append("Location: " + f["location"])
    # No trailing newline: Linear trims it, and `create --verify` then reports a mismatch on a good create.
    return "\n".join(lines) + "\nsurgeon-fp:%s" % f["fingerprint"]


def cluster_fp(key, project=""):
    """A PropertyCompass2 cluster's fingerprint is its key's; a Fleet cluster with the same key is a different item."""
    return fingerprint("review", "cluster-fleet" if project else "cluster", key)


def cluster_body(key, members, recurrence=None, project=""):
    open_n = sum(1 for m in members.values() if m["state"] == "open")
    lines = ["Filed by the Ship's Surgeon from the %s results." % SOURCE_NAME["review"],
             "What it is for: the lower-severity code-review findings in %s, kept in one item so one change can work them together and none is lost." % plain_words(key),
             "Epic: not assigned; whoever triages this picks one.", "",
             "Component: %s. Open: %d of %d. A ticked box is a finding the reviewer has marked resolved." % (key, open_n, len(members))]
    for fp, m in sorted(members.items(), key=lambda kv: (kv[1]["file"], kv[1]["title"], kv[0])):
        lines.append("- [%s] surgeon-fp:%s %s (%s)" % ("x" if m["state"] == "fixed" else " ", fp, m["title"], m["file"] or "no file"))
    if recurrence:
        lines.append(recurrence)
    return "\n".join(lines) + "\nsurgeon-fp:%s" % cluster_fp(key, project)

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


def plan_clusters(clustered, state, ledger):
    """The cluster items to make or refresh: [{key, fp, project, members, body, sha, action, findings}].

    Fleet findings (lib.fleet_work) cluster apart from PropertyCompass2 ones, so no item mixes the two.
    """
    clusters = state.setdefault("clusters", {})
    project_of = {id(f): lib.FLEET_PROJECT if lib.fleet_work(OFFICER, f["project"]) else "" for f in clustered}
    assigned = {m: cfp for cfp, c in clusters.items() for m in c["members"]}
    keys = {p: cluster_keys([f["location"] for f in clustered if project_of[id(f)] == p]) for p in set(project_of.values())}
    desired = {cfp: {"key": c["key"], "project": c.get("project", ""), "members": {m: dict(v) for m, v in c["members"].items()},
                     "findings": [], "recurrence": c.get("recurrence")} for cfp, c in clusters.items()}
    # A file keeps its cluster: a new finding in a file already listed joins that item, whatever the counts now say.
    by_file = {}
    for cfp, c in sorted(clusters.items()):
        for member in c["members"].values():
            if member["file"]:
                by_file.setdefault((c.get("project", ""), member["file"]), cfp)
    for f in clustered:
        project = project_of[id(f)]
        cfp = assigned.get(f["fingerprint"])
        if cfp is None or desired[cfp]["project"] != project:
            cfp = by_file.get((project, f["location"]))
        if cfp is None:
            key = keys[project][f["location"]]
            cfp = cluster_fp(key, project)
            desired.setdefault(cfp, {"key": key, "project": project, "members": {}, "findings": [], "recurrence": None})
        member = desired[cfp]["members"].setdefault(f["fingerprint"], {"title": f["title"], "file": f["location"], "state": "open"})
        member["title"], member["file"] = f["title"], f["location"]
        desired[cfp]["findings"].append(f)
    review = state.get("review", {})
    plan = []
    for cfp, c in sorted(desired.items(), key=lambda kv: kv[1]["key"]):
        for m, member in c["members"].items():
            if review.get(m, {}).get("state") == "fixed":
                member["state"] = "fixed"
        body = cluster_body(c["key"], c["members"], c["recurrence"], c["project"])
        sha = hashlib.sha256(body.encode("utf-8")).hexdigest()
        known = clusters.get(cfp)
        action = None if known and known.get("sha") == sha and cfp in ledger else "update" if cfp in ledger else "create"
        if not c["members"] or (not c["findings"] and action == "create"):
            continue
        plan.append({"key": c["key"], "fp": cfp, "project": c["project"], "members": c["members"], "body": body, "sha": sha,
                     "action": action, "findings": c["findings"], "recurrence": c["recurrence"]})
    return plan

# ---- filing -----------------------------------------------------------------------------

OFFICER = lib.Officer("surgeon", "Ship's Surgeon", "Surgeon", RUBRIC_FILE, BUILTIN_START_SOURCES,
                      start_word="Start them through the Navigator's start path, per the surgeon's rubric", start_source="",
                      pattern_sources=("review", "sweeper"))
iso_week = lib.iso_week


def found_line(count, first, last):
    return OFFICER.found_line(count, first, last)


def file_findings(findings, args, date, out, state, found, jev):
    """Files the real, untracked findings; returns (writes_done, why Linear was stopped or None)."""
    todo = [f for f in findings if f["class"] == "real" and not f["tracked"]]
    clustered = [f for f in todo if f["source"] == "review" and f["severity"] == "low" and f["fingerprint"]]
    clustered_ids = {id(f) for f in clustered}
    singles = [f for f in todo if id(f) not in clustered_ids]
    stopped = lib.paused_until(out, args.now)
    ledger_path = os.path.join(out, LEDGER_FILE)
    ledger = read_json(ledger_path, {})
    filer = lib.Filer(OFFICER, LIN, args.team, date, out, ledger, found, jev, args.max_creates)
    plan = plan_clusters(clustered, state, ledger)
    bumps = filer.bumps
    for c in plan:
        if not c["action"]:
            for f in c["findings"]:
                f["filing"] = {"action": "clustered", "issue": ledger[c["fp"]], "cluster": c["key"], "new": False}

    def stop(reason, rate_limited=False):
        for f in todo:
            f["filing"] = f["filing"] or {"action": "not-filed", "reason": reason}
        if rate_limited:
            lib.pause_for_rate_limit(out, args.now)
        save(ledger_path, ledger, state, found)
        return lib.summary_rows(todo), reason

    for f in singles:
        if not f["fingerprint"]:
            f["filing"] = {"action": "not-filed", "reason": "no key, title or location to fingerprint"}
        elif f["fingerprint"] in ledger:
            f["filing"] = {"action": "exists", "issue": ledger[f["fingerprint"]]}
            f["issue_hint"] = ledger[f["fingerprint"]]
            bumps.append(f)
    due = [f for f in bumps if found.get("issues", {}).get(f["filing"]["issue"], {}).get("last") != date]
    if not any(not f["filing"] for f in todo) and not any(c["action"] for c in plan) and not due:
        return lib.summary_rows(todo), None
    if stopped:
        return stop(stopped)
    try:
        names = lib.label_names(LIN, args.team)
    except LinearError as exc:
        return stop("label lookup failed: %s" % exc, exc.code == "RATE_LIMITED")

    def label_set(f, location=None, words=None):
        location = f["location"] if location is None else location
        words = f["title"] + " " + f["summary"] if words is None else words
        area = area_for(location, words, names, args.triage_label, f["source"] == "nightly" and not f.get("special"))
        wanted = ["Bug", SOURCE_LABEL[f["source"]], area or args.triage_label]
        missing = [w for w in wanted if w.lower() not in names]
        return wanted, missing

    def describe(f, near=None, recurrence=None):
        return description(f, date, near=near, recurrence=recurrence)

    order = [("single", f) for f in singles if not f["filing"] and RANK[f["severity"]] <= RANK["medium"]]
    order += [("cluster", c) for c in plan if c["action"]]
    order += [("single", f) for f in singles if not f["filing"] and RANK[f["severity"]] > RANK["medium"]]
    try:
        for kind, item in order:
            if kind == "single":
                filer.file_single(item, label_set, describe)
            else:
                c = item
                wanted, reason = filer.item_labels({"source": "review", "project": c["project"]},
                                                   lambda f, key=c["key"]: label_set(f, key, key))
                title = "Code review findings: %s" % plain_words(c["key"])
                try:
                    if reason:
                        for f in c["findings"]:
                            f["filing"] = {"action": "not-filed", "reason": reason}
                        continue
                    action, ident, old = c["action"], ledger.get(c["fp"]), None
                    if ident and lib.is_closed(filer.view_issue(ident)):
                        old, ident = ident, None
                    if not ident and filer.over_cap():
                        for f in c["findings"]:
                            f["filing"] = {"action": "not-filed", "reason": "over max-creates for this run"}
                        continue
                    if not ident:
                        ident, closed = filer.existing_issue(c["fp"])
                        old = old or (None if ident else closed)
                        action = "update" if ident else "create"
                    recurrence, body, sha = c["recurrence"], c["body"], c["sha"]
                    if old:
                        recurrence = lib.recurrence_line(old, filer.view_issue(old))
                        body = cluster_body(c["key"], c["members"], recurrence, c["project"])
                        sha = hashlib.sha256(body.encode("utf-8")).hexdigest()
                    if action == "create":
                        ident, _, _ = filer.create(c["fp"], title + " (%s)" % c["key"], body, wanted, "3", c["project"])
                    else:
                        filer.update_body(ident, c["fp"], body)
                    ledger[c["fp"]] = ident
                    state["clusters"][c["fp"]] = {"key": c["key"], "members": c["members"], "sha": sha, "recurrence": recurrence}
                    if c["project"]:
                        state["clusters"][c["fp"]]["project"] = c["project"]
                    error = filer.relate(ident, old) if old else None
                    for f in c["findings"]:
                        f["filing"] = {"action": "clustered", "issue": ident, "cluster": c["key"]}
                        if old:
                            f["filing"]["recurrence_of"] = old
                        if error:
                            f["filing"]["relation_error"] = error
                except LinearError as exc:
                    for f in c["findings"]:
                        f["filing"] = f["filing"] or {"action": "failed", "reason": str(exc)}
                    if exc.code in lib.RATE_OR_BUDGET:
                        raise
        filer.settle_bumps(label_set, describe)
    except LinearError as exc:
        if exc.code == "RATE_LIMITED":
            return stop("Linear rate limit reached: %s" % exc, True)
        return stop("%s; the next run continues from the ledger" % exc)
    save(ledger_path, ledger, state, found)
    return lib.summary_rows(todo), None

def save(ledger_path, ledger, state, found):
    out = os.path.dirname(ledger_path)
    write_json(ledger_path, ledger)
    write_json(os.path.join(out, STATE_FILE), state)
    write_json(os.path.join(out, FOUND_FILE), found)



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
    lib.add_common_args(parser, RUBRIC_FILE)
    parser.add_argument("--area", default="", help="ignored: the area label now comes from each finding")
    parser.add_argument("--staging-repo", default=STAGING_REPO)
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
    findings, gaps, resolved = intake(args.app, args.staging_repo)
    rubric = lib.load_rubric(args.rubric, OFFICER)
    jev = lib.Jev(args.jev)
    out = args.out
    state = read_json(os.path.join(out, STATE_FILE), {})
    found = read_json(os.path.join(out, FOUND_FILE), {})
    store = read_json(os.path.join(out, PATTERN_FILE), {})
    update_review_state(state, findings, resolved, args.date)
    apply_found(findings, found, read_json(os.path.join(out, LEDGER_FILE), {}))
    writes, blocked = file_findings(findings, args, args.date, out, state, found, jev) if args.writes == "linear" else ([], None)
    apply_found(findings, found, read_json(os.path.join(out, LEDGER_FILE), {}))
    start_homes = lib.parse_start_homes(args.start_home)
    main_home = args.fm_home or (args.home[0] if args.home else "")
    starts, held, asks = lib.plan_starts(OFFICER, findings, rubric, args.date, args.writes, main_home, start_homes, state.setdefault("handled", {}))
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
