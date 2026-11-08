#!/usr/bin/env python3
"""fm-officer-page-check.py - the page-check officer's timed pass over the fleet app.

Run only through `bin/fm-officer.sh run <id>`, which owns the officer
contract; docs/configuration.md "Page-check officer" owns the registry fields.

Usage:
  fm-officer-page-check.py run --key <YYYY-MM-DDTHH> --out <lane-dir> --app <https-url>
                               [--rules <file>] [--stale-days N] [--remind-hours N]
                               [--home <dir>]... [--now <epoch>]
                               [--writes none|linear] [--team PC] [--max-creates <n>]
                               [--max-linear-calls <n>] [--rubric <file>] [--jev <jev.py>]
                               [--fm-home <dir>] [--start-home <home>=<projects>[=<role>[=<mandate>]]]...

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
                 --stale-days (a pinned card or one in the Later band, which
                 cl-keeper parks on purpose, is never aged), already answered, names a merged or closed PR
                 (read with `gh-axi api GET`, at most MAX_PR_LOOKUPS a run), or
                 whose keyed status line a later `resolved` line settled.
                 Two live-decision exceptions keep this from false-flagging:
                 * A merged PR alone does not stale a card that asks for a
                   production or activation action on it: that action is
                   still open. A production card's question, title or id
                   names deploy, production or roll out (PRODUCTION_RE); an
                   activation card's question or title opens with run these,
                   run the, install, activate, enable or go live
                   (ACTIVATION_ASK_RE), or its id carries an -install,
                   -golive, -go-live, -activate or -run-these token
                   (ACTIVATION_ID_RE). Neither counts when the card asks for a
                   merge (MERGE_RE: a merge-word card is stale once its PR
                   merged; merely mentioning the merge is not asking).
                   A closed-unmerged PR still flags.
                 * A `resolved` line alone does not stale a card unless the
                   captain answered. Evidence is a card `answer`, or a
                   resolved line written by an answer: fm-send --resolve-key
                   ("answered: ...") or `fm-captain-hold.sh answer`
                   ("captain hold <id>: answered" or "...: released"). A
                   routing or reconcile acknowledgement (decision-sweep,
                   pending-reply, reconciled) is not evidence.
  shown-after-done  a card shown although its record is settled: its status
                 line was resolved by a captain answer before the card was (re)raised
                 (same evidence as stale-card; a routing resolve does not
                 count), or the app's
                 own card record for a facts source (GET
                 /api/captains-log/facts?source=bosun) is closed while the
                 page still shows it asked.
  page-old       a page whose newest publish is older than its normal cadence
                 allows (PAGES), a job on the Runs page that is failing or whose
                 latest finished run has no summary, or a page that is
                 unreachable, unreadable or never published. A page whose
                 JSON is not the expected shape is unreadable.

The pass reads current records, so --key (the scheduler's slot) only names the
run. It writes into --out: <key>.json (every open finding), <key>.md (the
digest) and state.json (when each finding was last reported). It prints
`DIGEST <key> <n> <key>.md` where n counts findings not yet reported, or
reported more than --remind-hours (default 24) ago, so an unchanged page set
does not wake firstmate every slot while a finding nobody fixed returns daily.
An unreachable app is a finding, not a failed run.

Linear. With --writes linear (the registry's `writes: linear`) the officer follows the
shared officer contract (docs/officers/contract.md; bin/fm-officer-linear.py owns the
mechanics) with its rubric docs/officers/page-check-rubric.md, which owns what counts
as work, the severity of each kind and what starts. Every open finding is filed once
in team PC, project Fleet, labels Bug, the Source label agent and area:fleet, keyed by
its id (kind, page and object), so a finding nobody fixed raises the item's
`Found: N times` line once a day and that count is the priority lever. A card's own
words never go to Linear: the item names the card by id. A repeat of a closed item
raises that item's Found line, files nothing new and never starts it (the Filer's
bump_closed). A page-old or shown-after-done
finding whose open item exists and whose score reaches the rubric minimum gets a start
request in the digest's `start_requests` (and, for this home, a <key>.start-requests.sh
handoff), addressed to the --start-home office that dispatches the fleet repositories
(the Quartermaster), else to --fm-home; fleet-app merges stay with Slarti. A
standing-rule or stale-card finding is filed so its card is cleared and never starts a
fix. The reserved-class check judges what the started fix would change, so it reads the
finding's own kind, page, evidence and route, and the object id only when the object is
the fix target (a page or a Runs job), never a card's id or question: a finding whose
fix is in a reserved class is held as one keyed needs-decision line in `asks_for_lee`.
A page-old or shown-after-done finding is a bug in fleet code, so its bad pattern (the
kind, the page or Runs job, and the route as the safe form, with no timestamps and no
card id) is remembered once through the shared pattern memory, a repeat on another card
or day raising its count, and handed on in the digest's `patterns` and one batched
pattern-memory start request. Without writes: linear nothing is filed and
nothing starts. What the create cap, call budget or a rate limit leaves unfiled is named
in the digest.
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
RUBRIC_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "officers", "page-check-rubric.md")
# The kinds the rubric may let start: a page or a card source that is broken, never a card a rule already settles.
START_SOURCES = ("page-old", "shown-after-done")
TYPE_LABEL = "Bug"
# "agent" is the Source label of Lee's Linear setup (2026-10-13) for any worker filing on his behalf.
SOURCE_LABEL = "agent"
FACTS_SOURCES = ("bosun",)
PR_RE = re.compile(r"https://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)")
# A card names a production action when its question, title or own id matches PRODUCTION_RE and does not ask for a merge.
PRODUCTION_RE = re.compile(r"\b(production|deploy\w*|roll(?:ed|s|ing)?[ -]?out)\b", re.I)
# A card asks to activate or run its subject when its question or title opens with the ask, or its id carries the token.
ACTIVATION_ASK_RE = re.compile(r"^(?:run these|run the|install|activate|enable|go live)\b", re.I)
ACTIVATION_ID_RE = re.compile(r"-(?:install|golive|go-live|activate|run-these)(?:-|$)", re.I)
MERGE_RE = re.compile(r"\bmerge[ -]words?\b|^merge\s|\bmerge (?:this|it|the PR|PR)\b", re.I)
# A resolved status line written by an answer, as opposed to a routing or reconcile acknowledgement.
ANSWER_RE = re.compile(r"^(?:answered:|captain hold \S+: (?:answered|released))", re.I)
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
    """card id -> (epoch, text) of its keyed status line's last word, when that word is `resolved`."""
    out = {}
    for home in homes:
        for task, stream in friction.status_streams(triage.Home(home)).items():
            last = {}
            for e in stream:
                if e["key"]:
                    last[e["key"]] = e
            for key, e in last.items():
                if e["state"] == "resolved":
                    out[friction.card_id(task, key)] = (e["at"], e["text"])
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


def open_production_action(card):
    """True when the card asks for a production or activation action, which a merged PR does not close."""
    head = [str(card.get(k) or "").strip() for k in ("id", "question", "title")]
    asks = (any(PRODUCTION_RE.search(h) for h in head) or ACTIVATION_ID_RE.search(head[0])
            or any(ACTIVATION_ASK_RE.search(h) for h in head[1:]))
    return bool(asks) and not any(MERGE_RE.search(h) for h in head)


def finding(kind, page, ref, title, evidence, route, severity="medium"):
    return {"id": "%s:%s:%s" % (kind, page, ref), "kind": kind, "page": page, "title": friction.scrub(title, 110),
            "evidence": evidence, "route": route, "severity": severity}


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
                                   "cl-keeper: close the card citing the rule", "low"))
        asked = friction.epoch_of(c.get("reasked")) or friction.epoch_of(c.get("asked"))
        done_at, done_text = settled.get(cid, (None, ""))
        if cid in known_closed:
            out.append(finding("shown-after-done", page, cid, title,
                               "the app's own record for this card is closed but the page shows it %s" % c.get("state"),
                               "cl-keeper: close the card; fix the source that re-raises it"))
        elif done_at is not None:
            answered = c.get("answer") or ANSWER_RE.match(done_text.strip())
            if asked is not None and asked > done_at and answered:
                out.append(finding("shown-after-done", page, cid, title,
                                   "status line resolved at %s, re-raised at %s" % (
                                       time.strftime("%Y-%m-%d %H:%MZ", time.gmtime(done_at)),
                                       time.strftime("%Y-%m-%d %H:%MZ", time.gmtime(asked))),
                                   "cl-keeper: close the card; fix the source that re-raises it"))
            elif answered:
                out.append(finding("stale-card", page, cid + ":resolved", title, "its status line was resolved elsewhere",
                                   "cl-keeper: close the card", "low"))
        until = friction.epoch_of(c.get("until"))
        if c.get("state") == "snoozed" and until is not None and until < now:
            out.append(finding("stale-card", page, cid + ":snooze", title, "snooze ended %d day(s) ago" % ((now - until) // 86400),
                               "cl-keeper: re-ask or close", "low"))
        elif c.get("state") == "asked" and asked is not None and now - asked > stale_days * 86400 and not c.get("pinned") and c.get("band") != "later":
            out.append(finding("stale-card", page, cid + ":unanswered", title, "unanswered for %d day(s)" % ((now - asked) // 86400),
                               "cl-keeper: close or re-word", "low"))
        if c.get("state") == "asked" and c.get("answer"):
            out.append(finding("stale-card", page, cid + ":answered", title, "already answered but still shown", "cl-keeper: close", "low"))
        for repo, number in PR_RE.findall(text):
            state = pr_state(repo, number, cache, budget)
            if state == "merged" and open_production_action(c):
                continue
            if state in ("merged", "closed"):
                out.append(finding("stale-card", page, "%s:%s#%s" % (cid, repo, number), title,
                                   "names %s#%s, which is %s" % (repo, number, state), "cl-keeper: close or correct", "low"))
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
                               "GET %s was %s" % (path, state), "page owner: restore the page's feed", "high"))
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
                           "page owner: restore the page's feed", "high"))
    else:
        for job in items(runs, "jobs"):
            if job.get("state") != "live":
                continue
            last = job.get("latest") if isinstance(job.get("latest"), dict) else {}
            if last.get("status") == "running":
                last = job.get("lastDone") if isinstance(job.get("lastDone"), dict) else {}
            blank = last.get("status") == "finished" and not str(last.get("summary") or "").strip()
            name = job.get("label") or job.get("id")
            if job.get("health") == "failing":
                note = "; its latest finished run (%s) also has no summary" % last.get("finishedAt") if blank else ""
                out.append(finding("page-old", "Runs", str(job.get("id")), "%s is failing" % name,
                                   "officer %s: health failing, next due %s%s" % (job.get("officer"), job.get("nextDueAt"), note),
                                   "page owner: fix the job"))
            elif blank:
                out.append(finding("page-old", "Runs", str(job.get("id")), "%s finished without a summary" % name,
                                   "officer %s: latest finished run at %s has no summary" % (
                                       job.get("officer"), last.get("finishedAt") or last.get("startedAt")),
                                   "page owner: fix the job's result"))
    state, _ = fetch(app, "/api/health")
    if state != "read":
        out.append(finding("page-old", "Home", "health", "Home: app %s" % WHY[state], "GET /api/health was %s" % state,
                           "page owner: restore the app", "high"))
    return out, docs


def officer(lib):
    """The page-check officer as the contract (docs/officers/contract.md) knows it: Fleet work, two kinds may start."""
    return lib.Officer("page-check", "Page-check officer", "Page check", RUBRIC_FILE, START_SOURCES,
                       severities=("high", "medium"), pattern_sources=START_SOURCES, project=lib.FLEET_PROJECT)


def fix_target(lf):
    """What a started fix changes: the page, or the Runs job a page-old finding names; never the card a card finding observed."""
    ref = lf["key"].split(":", 2)[2]
    return "%s job %s" % (lf["job"], ref) if lf["source"] == "page-old" and lf["job"] == "Runs" and ref != "runs" else lf["job"]


def fix_view(lf):
    """The finding as the reserved-class check reads it: its kind and fix target in place of a title that may carry a card id."""
    return dict(lf, title="%s: %s" % (fix_target(lf), lf["source"]))


def pattern_findings(lib, findings):
    """The bad pattern of each filed page or card-source defect: its kind and fix target, with the route as the safe form."""
    return [dict(lf, title=lib.text("%s on %s (route: %s)" % (lf["source"], fix_target(lf), lf["raw"]["route"]), 120),
                 fix=lib.text(lf["raw"]["route"], 200)) for lf in findings if (lf["filing"] or {}).get("issue")]


def lib_findings(lib, findings):
    """One shared-library finding per page-check finding, built from the kind, page, object id, evidence and route only,
    never from a card's words, because Linear is third-party storage."""
    out = []
    for f in findings:
        ref = f["id"].split(":", 2)[2]
        lf = lib.make_finding(f["kind"], f["page"], f["id"], "%s: %s %s" % (f["page"], f["kind"], ref),
                              "%s. Route: %s." % (f["evidence"], f["route"]), "real", f["severity"], False, {})
        lf["raw"] = f
        out.append(lf)
    return out


def description(lf, key, off, near=None, recurrence=None):
    """The Linear item body: ids, evidence and the route, never a card's question or answer."""
    f = lf["raw"]
    day = key[:10]
    lines = ["Filed by the page-check officer from the %s page check." % key,
             "What it is for: a fleet-app page that shows a card a rule already settles, a stale card, a card shown after it was settled, or an old page.",
             "Epic: not assigned; whoever triages this picks one.", "",
             "Severity: %s. Kind: %s. Page: %s. Object: %s." % (lf["severity"], f["kind"], f["page"], f["id"].split(":", 2)[2]),
             off.found_line(1, day, day)]
    if recurrence:
        lines.append(recurrence)
    if near:
        lines.append("Near match (not treated as the same issue): %s, local-jev %.2f." % near)
    lines += ["Evidence: %s." % f["evidence"], "Route: %s." % f["route"]]
    # No trailing newline: Linear trims it, and `create --verify` then reports a mismatch on a good create.
    return "\n".join(lines) + "\n%s:%s" % (off.marker, lf["fingerprint"])


def file_findings(lib, off, findings, args, key, ledger, found, jev, lin):
    """Files every open finding, highest score first; returns (writes done, why Linear stopped or None)."""
    day, out = key[:10], args.out
    filer = lib.Filer(off, lin, args.team, day, out, ledger, found, jev, args.max_creates, bump_closed=True)

    def stop(reason, rate_limited=False):
        for f in findings:
            f["filing"] = f["filing"] or {"action": "not-filed", "reason": reason}
        if rate_limited:
            lib.pause_for_rate_limit(out, args.now)
        return lib.summary_rows(findings), reason

    for f in findings:
        if f["fingerprint"] in ledger:
            f["filing"], f["issue_hint"] = {"action": "exists", "issue": ledger[f["fingerprint"]]}, ledger[f["fingerprint"]]
            if found.get("issues", {}).get(ledger[f["fingerprint"]], {}).get("closed"):
                f["filing"]["closed"] = True
            filer.bumps.append(f)
    due = [f for f in filer.bumps if found.get("issues", {}).get(f["filing"]["issue"], {}).get("last") != day]
    if not any(not f["filing"] for f in findings) and not due:
        return lib.summary_rows(findings), None
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
        return description(f, key, off, near, recurrence)

    try:
        for f in findings:
            if not f["filing"]:
                filer.file_single(f, label_set, describe)
        filer.settle_bumps(label_set, describe)
    except lib.LinearError as exc:
        if exc.code == "RATE_LIMITED":
            return stop("Linear rate limit reached: %s" % exc, True)
        return stop("%s; the next run continues from the ledger" % exc)
    return lib.summary_rows(findings), None


def linear_pass(raw, args, key):
    """Files the findings in Linear (writes: linear) and hands the page defects to the owning office.

    Returns (the digest's Linear fields, the library findings). A start needs the finding's Linear item, so without
    writes: linear nothing is filed or started; a reserved class (docs/officers/contract.md) is held, not started.
    """
    lib = friction._lib()
    off, out, day, linear = officer(lib), args.out, key[:10], args.writes == "linear"
    lin = lib.Linear(args.max_linear_calls)
    state = lib.read_json(os.path.join(out, lib.STATE_FILE), {})
    found = lib.read_json(os.path.join(out, lib.FOUND_FILE), {})
    ledger = lib.read_json(os.path.join(out, lib.LEDGER_FILE), {})
    findings = lib_findings(lib, raw)
    rubric = lib.load_rubric(args.rubric, off)
    jev = lib.Jev(args.jev)
    lib.apply_found(findings, found, ledger)
    writes, blocked = file_findings(lib, off, findings, args, key, ledger, found, jev, lin) if linear else ([], None)
    lib.apply_found(findings, found, ledger)
    handled = state.setdefault("handled", {})
    gaps = rubric.gaps + ([jev.gap] if jev.gap and linear else [])
    if args.fm_home:
        starts, held, asks = lib.plan_starts(off, [fix_view(f) for f in findings], rubric, day, args.writes, args.fm_home, lib.parse_start_homes(args.start_home), handled)
    else:
        starts, held, asks = [], [], []
        gaps.append("no --fm-home, so nothing starts by itself")
    by_fp = {f["fingerprint"]: f for f in findings}
    for row in starts:
        row["id"] = by_fp[row["fingerprint"]]["raw"]["id"]
    store = lib.read_json(os.path.join(out, lib.PATTERN_FILE), {})
    captures, lint = [], []
    if linear and rubric.pattern_memory:
        lib.update_patterns(off, store, pattern_findings(lib, findings), jev, day)
    if linear and args.fm_home:
        pattern_requests, captures, lint = lib.pattern_outputs(off, store, rubric, day, args.fm_home, lib.parse_start_homes(args.start_home))
        starts.extend(pattern_requests)
    for rank, row in enumerate(starts, 1):
        row.update(rank=rank, owner_home=row["execute"]["env"]["FM_HOME"])
    if linear:
        lib.write_json(os.path.join(out, lib.LEDGER_FILE), ledger)
        lib.write_json(os.path.join(out, lib.STATE_FILE), state)
        lib.write_json(os.path.join(out, lib.FOUND_FILE), found)
        lib.write_json(os.path.join(out, lib.PATTERN_FILE), store)
    patterns = store.get("patterns", {})
    for lf in findings:
        lf["raw"]["linear"] = {"severity": lf["severity"], "found": lf["found"], "score": lf["score"],
                               **{k: v for k, v in (lf["filing"] or {}).items() if k in ("action", "issue", "reason", "found", "recurrence_of")}}
    return {"source": "page-check-officer", "generated_at": lib.iso(args.now), "writes": args.writes, "writes_done": writes,
            "writes_blocked": blocked, "linear_calls": lin.n, "linear_call_budget": lin.budget, "linear_gaps": gaps,
            "not_filed": lib.not_filed_lines(findings), "held": held, "asks_for_lee": asks, "start_requests": starts,
            "patterns": {"total": len(patterns), "new": [dict(id=i, line=p["line"], count=p["count"]) for i, p in sorted(patterns.items()) if p["first"] == day],
                         "captures": captures, "lint": lint}}


def render_md(key, findings, new_ids, coverage, linear):
    lines = ["# Page check %s" % key, "", "%d open finding(s), %d new." % (len(findings), len(new_ids)), ""]
    lines += ["Coverage: " + c for c in coverage]
    lines += ["- Linear: writes %s; %d of %d call(s) used%s." % (
        linear["writes"], linear["linear_calls"], linear["linear_call_budget"],
        "; stopped: " + linear["writes_blocked"] if linear["writes_blocked"] else "")]
    lines += ["- Linear: " + g for g in linear["linear_gaps"]] + ["- " + n for n in linear["not_filed"]]
    lines += ["- " + a["line"] for a in linear["asks_for_lee"]]
    pat = linear["patterns"]
    lines += ["- Patterns: %d known, %d new this run." % (pat["total"], len(pat["new"]))] + ["- Pattern: %s (x%d)" % (p["line"], p["count"]) for p in pat["new"]]
    if pat["captures"]:
        lines.append("- Memory capture needed (tags pattern + project): the office captures these %d line(s) from `patterns` in the digest json." % len(pat["captures"]))
    lines += ["- Proposed follow-up: %s" % p["proposal"] for p in pat["lint"]]
    for f in findings:
        lin = f.get("linear") or {}
        lines.append("- %s[%s] %s - %s: %s (evidence: %s) -> %s%s" % (
            "NEW " if f["id"] in new_ids else "", f["kind"], f["page"], f["id"].split(":", 2)[2], f["title"],
            f["evidence"], f["route"],
            " [Linear %s, found %d, score %.1f%s]" % (lin.get("issue") or lin.get("action", "not filed"), lin["found"], lin["score"],
                                                    ": " + lin["reason"] if lin.get("reason") else "") if lin else ""))
    return "\n".join(lines) + "\n"


def run(args):
    now = args.now
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
    os.makedirs(args.out, exist_ok=True)
    linear = linear_pass(findings, args, args.key)
    coverage.extend(linear["linear_gaps"])
    seen_path = os.path.join(args.out, "state.json")
    try:
        with open(seen_path, encoding="utf-8") as fh:
            seen = json.load(fh)
    except (OSError, ValueError):
        seen = {}
    window = args.remind_hours * 3600
    new_ids = {f["id"] for f in findings if now - seen.get(f["id"], -window - 1) >= window}
    kept = {f["id"]: (now if f["id"] in new_ids else seen[f["id"]]) for f in findings}
    triage.write_if_changed(seen_path, json.dumps(kept, sort_keys=True, indent=1) + "\n")
    triage.write_if_changed(os.path.join(args.out, args.key + ".json"),
                            json.dumps(dict(linear, key=args.key, findings=findings, new=sorted(new_ids), coverage=coverage),
                                       sort_keys=True, indent=1, ensure_ascii=False) + "\n")
    triage.write_if_changed(os.path.join(args.out, args.key + ".md"), render_md(args.key, findings, new_ids, coverage, linear))
    if args.fm_home:
        friction._progress().write_handoff(os.path.join(args.out, args.key + ".start-requests.sh"),
                                           [r["execute"] for r in linear["start_requests"] if r["execute"]["env"]["FM_HOME"] == args.fm_home])
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
    friction._lib().add_common_args(parser, RUBRIC_FILE)
    args = parser.parse_args(argv)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}(T\d{2})?", args.key):
        parser.error("--key must be YYYY-MM-DD or YYYY-MM-DDTHH")
    friction._lib().check_common_args(parser, args)
    return run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
