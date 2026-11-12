#!/usr/bin/env python3
"""fm-officer-linear.py - the shared Linear filing, rubric, start and pattern library every officer uses.

A library, not a command: an officer script loads it by path, as fm-officer-surgeon.py does:

    lib = _load("fm_officer_linear", "fm-officer-linear.py")
    officer = lib.Officer("surgeon", "Ship's Surgeon", "Surgeon", rubric_file, sources=(...))

docs/officers/contract.md owns the contract (FIND, FILE, TRIAGE, START) and the reserved classes;
each officer's docs/officers/<id>-rubric.md owns what it counts as work; the officer script's own header owns
how it finds things. This file owns the mechanics every officer shares:

  finding     make_finding(): one finding dict (source, job, severity, class, fingerprint, found, score ...). A finding
              with no source key is fingerprinted from its normalised title plus location (digits dropped).
  filing      Filer: search before create, in order the fingerprint (`<officer>-fp:<sha256>` in the description and the
              lane's filed-fingerprints.json ledger), then a text search of the title whose candidates local-jev judges
              ("same issue?"): a duplicate only above JEV_SAME (0.85), a lower near match is noted in the new item.
              A duplicate raises the item's one `Found: N times (first <date>, last <date>, by <officer>)` line in place
              (`issue update --dry-run`, then `--verify`) and adds one comment, on the day's first sighting only.
              Every write is `--dry-run` then `--verify`. A failed verify is never retried; the item is taken as written when the
              error's data.issue.identifier names it, else when the team's issue list holds one new open item of exactly its title (Linear's full-text search matches
              neither fingerprints nor these titles, so no exact-title lookup uses it; see title_index()), and only then recorded failed (tried again next run). open_by_title() also lets a bundle adopt
              the oldest open item of its title. A Duplicate item counts as closed (is_closed()). An item a person closed (completed or canceled) is never reopened,
              edited or re-prioritised: a repeat finding files a new item that names it (`Recurrence of <id>`), unless
              the Filer is built with bump_closed (the page-check officer), when it bumps the closed item and starts nothing.
              An item gets exactly one Type, one Source and one area label; fleet work
              (is_fleet: a finding's repository, else its Officer's project) goes in the Fleet project, with the area:fleet label (fleet_labels). The library never creates a label and never deletes an item; the one
              close is close_with_comment(), which only the page-check officer calls, on an item it filed itself
              (docs/officers/contract.md "File").
  bundles     Bundles (docs/officers/contract.md "Bundles" owns the rule): one open item per (officer, source family, area,
              fleet or not), titled bundle_title(); its body is rebuilt from the lane's bundles.json on every write, so a line
              is never lost. place() (no Linear call) keeps a finding on its open bundle, keeps one already filed alone on that
              older item (legacy, bumped until closed), or queues it; dedupe() bumps a queued finding an existing single item
              tracks (fingerprint, then local-jev, never matching a bundle); write() appends the queue to the area's open part
              with room (at most bundle-cap open lines, none on a started part), else adopts an open item of the part's exact
              title (a lane that lost its state), else creates the next part, and reads each bundle it touches (and every
              bundle with a finding still reported, once a day): a closed one is never written again and its reported findings
              are queued again naming it (with recur_closed off, the page-check officer's case, they stay with it). Each
              bundled finding keeps its own found count in found.json `members`. file_bundled() and file_in_bundles() are the
              filing passes; plan_starts() gives a bundle one start (BUNDLE_START) and holds it whole on any reserved line.
  budget      Linear counts every linear-axi call against the officer's registry `max-linear-calls`, and Filer stops
              creating at its `max-creates`; whatever is left is reported by not_filed_lines() and filed by the next run
              from the ledger. One RATE_LIMITED answer stops every Linear call and pauses later runs for an hour.
  rubric      load_rubric(): reads docs/officers/<id>-rubric.md "Settings the code reads" on every run. A rubric can only
              narrow what the code admits; the RESERVED classes are fixed here and always hold.
  priority    score_of() = severity weight x log2(1 + found), the found-count lever the rubric's start decision and the
              digest both use; apply_found() sets it on each finding and orders them highest score first.
  start       plan_starts(): a real, untracked, filed finding the rubric admits whose score reaches the rubric minimum
              becomes a start request on the progress officer's path (execute_for), addressed to the --start-home office whose
              projects name the finding's project, else the main home (navigator for PropertyCompass2, quartermaster for fleet repositories); one
              matching a reserved class becomes one keyed needs-decision line (asks_for_lee). A finding is handled once.
              A finding that names no repository belongs to the Officer's project (owning_project: PropertyCompass2 by
              default, Fleet for a fleet officer); a Fleet item names no repository and goes to the office that dispatches
              the fleet repositories (FLEET_REPOS), the quartermaster.
  triage      triage_issue(): the progress officer's one Linear priority write, for an item another officer filed (its
              `<officer>-fp:<sha256>` marker). The score is score_of()'s from the severity fixed when the lane first saw the
              item (the filer's `Severity:` line, else what its priority then stood for) and the Found line's count; a score of 8 or more is Urgent (1), 4 or more High (2), else Medium (3). It only
              raises a priority, never lowers one, and never touches an item that is assigned or whose priority a person
              changed since the progress lane last saw it (its triage-state.json). `--dry-run`, then `--verify`.
  patterns    update_patterns() / pattern_outputs(): one anti-pattern line per bug or code-review finding, deduped by
              normalised title then local-jev, handed on as one batched start request per repository (PropertyCompass2's to
              the navigator for its quality-patterns.md, fleet code's to the office that dispatches that repository),
              a memory capture and a proposed lint rule when mechanical.
"""

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


progress = _load("fm_officer_progress", "fm-officer-progress.py")

SEVERITIES = ("critical", "high", "medium", "low")
RANK = {s: i for i, s in enumerate(SEVERITIES)}
PRIORITY = {"critical": "1", "high": "2", "medium": "3", "low": "3"}
SEVERITY_WEIGHT = {"critical": 8, "high": 4, "medium": 2, "low": 1}
BUMP = {"low": "medium", "medium": "high", "high": "critical", "critical": "critical"}
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
START_ATTEMPT_CAP = 3  # starts for one fingerprint (a recurrence is a new item) before the owning office hands the repeat to Lee
PATTERN_BATCH = 40
TRIAGE_FILE = "triage-state.json"
TRIAGE_BANDS = ((8.0, "1"), (START_MIN_SCORE, "2"))  # score at or above -> Linear priority; below both -> 3
PRIORITY_SEVERITY = {1: "critical", 2: "high", 3: "medium"}  # what a creating officer's priority stands for; 0 and 4 count as low
OFFICER_FILED = re.compile(r"\b([a-z][a-z-]*)-fp:[0-9a-f]{64}\b")
SEVERITY_LINE = re.compile(r"\bSeverity: (critical|high|medium|low)\b")
FOUND_ANY = re.compile(r"^Found: (\d+) times \(first \d{4}-\d{2}-\d{2}, last \d{4}-\d{2}-\d{2}, by [a-z-]+\)$", re.M)
EXISTING_VIEWS = 3
VERIFY_SEARCH_WAITS = (0, 0.5, 1.0)
TITLE_INDEX_ITEMS = 600  # newest items of the team read for an exact-title lookup (the list is newest first)
TITLE_INDEX_PAGE = 100
CLOSED_STATES = ("Done", "Released", "Canceled", "Cancelled", "Duplicate")
CLOSED_TYPES = ("completed", "canceled", "duplicate")
DEFAULT_BUNDLE_CAP = 15  # open findings in one bundle item (registry `bundle-cap`)
BUNDLE_PARTS_MAX = 20  # parts one run tries for one area before it names the rest not filed
BUNDLE_FILE = "bundles.json"
NO_FILE = "(no file)"
BUNDLE_HEAD = re.compile(r"^### (.+)$")
BUNDLE_LINE = re.compile(r"^- \[([ x])\] ([a-z][a-z-]*-fp):([0-9a-f]{64}) (.+)$")
RECUR = "recurred, was in "
BUNDLE_PREFIX = "Automated findings: "
BUNDLE_START = "Start this Linear item: fix every open line of its checklist in one pull request, tested once."
RESUME_FILE = "linear-resume-after.json"
LEDGER_FILE = "filed-fingerprints.json"
STATE_FILE = "review-state.json"
FOUND_FILE = "found.json"
PATTERN_FILE = "patterns.json"
JEV_DEFAULT = os.path.expanduser("~/.claude/skills/local-jev/jev.py")
PATTERN_TARGET = ".agents/skills/sdlc-review/references/quality-patterns.md"
DEFAULT_PROJECT = "PropertyCompass2"
FLEET_PROJECT = "Fleet"
FLEET_AREA = "area:fleet"
BUILTIN_START_SEVERITIES = ("medium", "high", "critical")
RATE_OR_BUDGET = ("RATE_LIMITED", "CALL_BUDGET")
FLEET_REPOS = ("firstmate", "skills", "fleet-app")
DEFAULT_START_WORD = "Each officer should have a different rubric for what they find as work and decide to start"
DEFAULT_START_SOURCE = "Lee, main chat 2026-11-05T17:59:01Z"

# The reserved classes: always held, whatever a rubric says. docs/officers/contract.md lists them.
RESERVED = collections.OrderedDict([
    ("payments-billing", re.compile(r"\b(payments?|billing|invoices?|refunds?|stripe|direct debit)\b", re.I)),
    ("legal", re.compile(r"\b(terms (of|and) (service|use)|privacy policy|legal text|cookie banner|gdpr|licen[cs]e text)\b", re.I)),
    ("product", re.compile(r"\b(product (decision|change)s?|(change|raise|lower|set|move)[a-z]* (the )?(prices?|pricing|plan limits?|paywall))\b", re.I)),
    ("member-copy", re.compile(r"\b(change|update|reword|rewrite|edit|replace)[a-z]*\b.{0,40}?\b(wording|copy|text|microcopy)\b.{0,40}?"
                               r"\b(shown to|seen by|visible to|for) (members|users|customers)\b", re.I)),
    ("credentials", re.compile(r"(^|[.;:!?] +|^\[[^\]]*\] *)((rotate|revoke|regenerate|reissue)( (the|a|an|our|this|that))?|(create|reset) (the|a|an|our|this|that|new))"
                               r"( [\w-]+){0,2}? (credentials?|secrets?|"
                               r"api[- ]?keys?|tokens?|(access|account|storage|signing|private|ssh|encryption) keys?|"
                               r"(database|db|admin|service account) passwords?|connection strings?)\b", re.I)),
    ("production-actions", re.compile(r"\b((deploy|restart|promot|releas)[a-z]* (it |this )?to (production|prod)|production (deploy|restart|promotion)s?|"
                                      r"(change|update|edit|set|scale|write)[a-z]* (to )?(the )?(production|prod) (database|data|config|configuration|settings?))\b", re.I)),
    ("data-rewriting", re.compile(r"\b(drop (table|column)|rename (column|table)|data[- ]rewriting|(migration|backfill|script)\b.{0,40}?\b(delet|updat|rewrit)[a-z]* (all |the )?existing (rows|records|data)|"
                                  r"truncate table|remov[a-z]* (an )?enum value)\b", re.I)),
])
MECHANICAL = re.compile(r"\b(unused|null (check|reference)|dispos|await|async void|\.result\b|string concat|sql|hard-?coded|"
                        r"console\.log|magic number|empty catch|missing using|swallow|unchecked|todo|dead (code|branch))", re.I)


class Officer:
    """Who is filing: its id (the marker and Found-line name), display labels, rubric, what its rubric may admit,
    and the repository (project) a finding that names none belongs to."""

    def __init__(self, ident, label, short, rubric_file, sources, severities=BUILTIN_START_SEVERITIES,
                 start_word=DEFAULT_START_WORD, start_source=DEFAULT_START_SOURCE, pattern_sources=(), project=DEFAULT_PROJECT):
        self.id, self.label, self.short, self.rubric_file = ident, label, short, rubric_file
        self.sources, self.severities, self.start_word, self.start_source = tuple(sources), tuple(severities), start_word, start_source
        self.project = project
        self.pattern_sources = tuple(pattern_sources)
        self.marker = ident + "-fp"
        self.found_re = re.compile(r"^Found: (\d+) times \(first (\d{4}-\d{2}-\d{2}), last (\d{4}-\d{2}-\d{2}), by [a-z-]+\)$", re.M)

    def found_line(self, count, first, last):
        return "Found: %d times (first %s, last %s, by %s)" % (count, first, last, self.id)

    def rubric_name(self):
        return "docs/officers/%s-rubric.md" % self.id


# ---- small helpers ----------------------------------------------------------------------

def dicts(value):
    return [v for v in value if isinstance(v, dict)] if isinstance(value, list) else []


def text(value, limit=300):
    return " ".join(str(value if value is not None else "").split())[:limit]


def norm(value):
    """Lowercase words with digits dropped: stable across the numbers that vary run to run."""
    return " ".join(re.sub(r"[^a-z]+", " ", re.sub(r"\d+", "", str(value or "").lower())).split())


def fingerprint(source, job, key):
    return hashlib.sha256(("%s\0%s\0%s" % (source, job, key)).encode("utf-8")).hexdigest()


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


# ---- findings, score ----------------------------------------------------------------------

def make_finding(source, job, key, title, summary, klass, severity, tracked, evidence, location="", project="", fix="", special=None):
    """One finding. A won't-fix finding is always low; a key-less one is fingerprinted from title plus location."""
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
    """The found-count priority lever: severity weight x log2(1 + found)."""
    return round(SEVERITY_WEIGHT[f["severity"]] * math.log2(1 + max(1, f["found"])), 2)


def apply_found(findings, found, ledger):
    """Found count and score per finding (a bundled one keeps its own count, found.json `members`); the list ends up
    highest score first."""
    issues, members = found.get("issues", {}), found.get("members", {})
    for f in findings:
        item = issues.get(ledger.get(f["fingerprint"]) or "", {})
        f["found"] = max(1, item.get("count", 1), members.get(f["fingerprint"] or "", {}).get("count", 1))
        f["score"] = score_of(f)
    findings.sort(key=lambda f: (-f["score"], RANK[f["severity"]], f["source"], f["job"], f["key"], f["title"]))


def reserved_class(f):
    """The reserved class a finding asks for (matched by the action, not the word), or None."""
    fields = [f["title"], f["summary"], f["location"], text(f["evidence"].get("cause"))]
    for name, rx in RESERVED.items():
        if any(rx.search(field) for field in fields):
            return name
    return None


# ---- rubric -----------------------------------------------------------------------------

class Rubric:
    """What the rubric file allows; it can only narrow the code's allowances."""

    def __init__(self):
        self.loaded = False
        self.start_severities = set()
        self.start_sources = set()
        self.min_score = START_MIN_SCORE
        self.pattern_memory = False
        self.settings = {}
        self.gaps = []


def load_rubric(path, officer):
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
    rubric.settings = settings

    def narrow(key, allowed):
        asked = settings.get(key)
        if asked is None:
            return set(allowed)
        extra = [v for v in asked if v not in allowed]
        if extra:
            rubric.gaps.append("rubric %s names %s, which the code does not admit; ignored" % (key, ", ".join(extra)))
        return {v for v in asked if v in allowed}

    rubric.start_severities = narrow("start-severities", officer.severities)
    rubric.start_sources = narrow("start-sources", officer.sources)
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


# ---- linear -----------------------------------------------------------------------------

class LinearError(RuntimeError):
    def __init__(self, code, message, doc=None):
        super().__init__("%s: %s" % (code, message))
        self.code = code
        self.message = message
        self.doc = doc if isinstance(doc, dict) else {}

    def written_ident(self):
        """The identifier a failed --verify write names in data.issue.identifier, or None."""
        data = self.doc.get("data")
        issue = data.get("issue") if isinstance(data, dict) else None
        return text(issue.get("identifier"), 20) or None if isinstance(issue, dict) else None


class Linear:
    """linear-axi calls, counted against a budget; every call asks for JSON and raises LinearError on a failure."""

    def __init__(self, budget=DEFAULT_MAX_LINEAR_CALLS, job=None):
        self.n, self.budget, self.job = 0, budget, job

    def reset(self, budget):
        self.n, self.budget = 0, budget

    def __call__(self, args):
        if self.n >= self.budget:
            raise LinearError("CALL_BUDGET", "Linear call budget of %d reached" % self.budget)
        self.n += 1
        job = os.environ.get("LINEAR_JOB") or self.job or "officer:linear"
        proc = subprocess.run(["linear-axi"] + args + ["--output", "json"], env=dict(os.environ, LINEAR_JOB=job), capture_output=True, check=False)
        try:
            # raw_decode: linear-verify may append plain text lines after the one JSON document.
            doc, _ = json.JSONDecoder().raw_decode(proc.stdout.decode("utf-8").lstrip())
            if not isinstance(doc, dict):
                raise ValueError
        except ValueError:
            raise LinearError("NO_JSON", "linear-axi %s returned no JSON (exit %d)" % (" ".join(args[0:2]), proc.returncode))
        if not doc.get("ok"):
            error = doc.get("error") if isinstance(doc.get("error"), dict) else {}
            raise LinearError(error.get("code", "unknown"), str(error.get("message", ""))[:120], doc)
        return doc.get("data") or {}


def issue_id(data):
    issue = data.get("issue") if isinstance(data.get("issue"), dict) else data
    return text(issue.get("identifier"), 20) or "unknown"


def is_closed(issue):
    """Done, canceled or a duplicate (Linear reports a duplicate's stateType as `duplicate`); else the state name."""
    kind = text(issue.get("stateType")).lower()
    return kind in CLOSED_TYPES if kind else text(issue.get("state")) in CLOSED_STATES


def recurrence_line(old, issue):
    return "Recurrence of %s (closed as %s)." % (old, text(issue.get("state"), 40) or "closed")


def fleet_labels(source_label, names, type_label="Bug"):
    """(labels, missing) for a fleet finding: one Type, one Source and the area:fleet label (Fleet project goes with it)."""
    wanted = [type_label, source_label, FLEET_AREA]
    return wanted, [w for w in wanted if w.lower() not in names]


def label_names(lin, team):
    """The lower-cased label names of the team; an officer never creates a label."""
    labels = lin(["label", "list", "--team", team, "--limit", "250"])
    return {text(l.get("name")).lower() for l in dicts(labels.get("labels"))}


def paused_until(out, now):
    """Why Linear is paused after a rate limit, or None."""
    resume = read_json(os.path.join(out, RESUME_FILE), {}).get("resume_after", 0)
    return "Linear paused after a rate limit until %s" % iso(resume) if now < resume else None


def pause_for_rate_limit(out, now):
    write_if_changed(os.path.join(out, RESUME_FILE), json.dumps(
        {"resume_after": now + 3600, "resume_after_utc": iso(now + 3600)}) + "\n")


class Jev:
    """local-jev's yes/no answer to "is this the same issue?"; None when it cannot answer.

    Every answer it asks for is a `call` receipt and the caller's use of it a `decision` receipt
    (docs/local-jev-receipts.md): same() leaves the call's receipt id in .receipt and where the answer came from in
    .source (None when no local-jev is installed, so nothing is recorded), and decide() records the option used.
    """

    def __init__(self, path):
        self.path, self.calls, self.dead, self.gap = path, 0, not path or not os.path.exists(path or ""), None
        self.installed, self.down, self.receipt, self.source, self.caller = not self.dead, None, None, None, None
        if self.dead:
            self.gap = "local-jev not found at %s, so duplicates are found by fingerprint only" % (path or "(none)")

    def same(self, a, b, what="issue", subject=None, caller="officer-duplicate"):
        self.receipt, self.source, self.caller = None, None, caller
        if self.dead:
            self.source = "fallback:" + (self.down or "local-jev-down") if self.installed else None
            return None
        if self.calls >= JEV_CALLS_MAX:
            self.gap = "local-jev call cap of %d reached; later duplicate checks used fingerprints only" % JEV_CALLS_MAX
            self.source = "fallback:call-cap"
            return None
        self.calls += 1
        question, yes, no = "Is report B the same %s as report A (the same defect in the same place)?" % what, "same %s" % what, "different %s" % what
        state = {"report_a": a[:900], "report_b": b[:900]}
        call = {"caller": caller, "subject": subject, "model": None, "route": "jev.py:noul", "served_adapter": None,
                "request": {"state": state, "question": question, "criteria": {"true": yes, "false": no}},
                "pick": None, "confidence": None, "probabilities": None, "floor": JEV_SAME, "latency_ms": None, "error": None}
        started = time.monotonic()
        try:
            proc = subprocess.run(
                ["python3", self.path, "noul", question, "--true", yes, "--false", no, "--state", json.dumps(state)],
                capture_output=True, check=False, timeout=JEV_TIMEOUT, stdin=subprocess.DEVNULL,
                env=dict(os.environ, LOCAL_JEV_RECEIPTS="0"))  # this officer writes its own receipts
        except (OSError, subprocess.TimeoutExpired) as exc:
            self.dead, self.gap = True, "local-jev timed out, so duplicates are found by fingerprint only"
            self.down, self.source = "local-jev-down", "timeout" if isinstance(exc, subprocess.TimeoutExpired) else "fallback:local-jev-down"
            call.update(latency_ms=int((time.monotonic() - started) * 1000), error=type(exc).__name__)
            self.receipt = progress.jev_receipt("call", call)
            return None
        call["latency_ms"] = int((time.monotonic() - started) * 1000)
        if proc.returncode == 3:
            self.dead, self.gap = True, "local-jev unreachable, so duplicates are found by fingerprint only"
            self.down, self.source = "unreachable", "fallback:unreachable"
            call["error"] = "exit 3 (unreachable)"
            self.receipt = progress.jev_receipt("call", call)
            return None
        try:
            answer = json.loads(proc.stdout.decode("utf-8"))
            p = float(answer["noul"])
        except (ValueError, KeyError, TypeError):
            self.gap = "local-jev returned an unreadable answer once"
            self.source = "fallback:unreadable"
            call["error"] = "unreadable answer (exit %d)" % proc.returncode
            self.receipt = progress.jev_receipt("call", call)
            return None
        call.update(pick="true" if p > JEV_SAME else "false", confidence=max(p, 1.0 - p),
                    probabilities={"true": p, "false": 1.0 - p})
        self.receipt, self.source = progress.jev_receipt("call", call), "model"
        return p

    def decide(self, decision, subject=None, **extra):
        """Records the option the caller used ("true" or "false") for the last same(), when local-jev is installed."""
        if self.source is None:
            return None
        fields = {"receipt_id": self.receipt, "caller": self.caller, "subject": subject, "decision": decision,
                  "source": self.source, "overridden": False, "override_by": None, "corrected_decision": None}
        fields.update(extra)
        return progress.jev_receipt("decision", fields)


def finding_text(f):
    return "%s\n%s\n%s" % (f["title"], f["summary"], f["location"])


def summary_rows(todo):
    return [dict(f["filing"], fingerprint=f["fingerprint"], title=f["title"], source=f["source"], severity=f["severity"])
            for f in todo if f["filing"]]


def not_filed_lines(findings):
    """One line per reason for everything not filed this run (cap, call budget, rate limit, missing label), so the digest names the overflow."""
    reasons = collections.OrderedDict()
    for f in findings:
        filing = f.get("filing") or {}
        if filing.get("action") == "not-filed":
            reasons.setdefault(filing.get("reason", "not filed"), []).append(f)
    return ["Not filed (%s): %d, highest score first: %s" % (
        reason, len(items), "; ".join("%s (%s, score %.1f)" % (i["title"], i["severity"], i["score"])
                                      for i in sorted(items, key=lambda i: -i["score"])[:5]))
            for reason, items in reasons.items()]


class Filer:
    """Files findings in one team under the contract; one per officer run (the cache lasts a run)."""

    def __init__(self, officer, lin, team, date, out, ledger, found, jev, max_creates, bump_closed=False):
        self.officer, self.lin, self.team, self.date, self.out = officer, lin, team, date, out
        self.bump_closed = bump_closed
        self.ledger, self.found, self.jev, self.max_creates = ledger, found, jev, max_creates
        self.cache, self.creates, self.bumps = {}, 0, []
        self.titles = None  # the team's newest items for exact-title lookups, read once a run (title_index)

    def over_cap(self):
        return self.creates >= self.max_creates

    # reading
    def view_issue(self, ident):
        if ident not in self.cache:
            issue = self.lin(["issue", "view", ident, "--full"]).get("issue")
            self.cache[ident] = issue if isinstance(issue, dict) else {}
        return self.cache[ident]

    def search_hits(self, query, limit):
        found = self.lin(["issue", "search", query, "--team", self.team, "--limit", str(limit)]).get("issues")
        return [text(h.get("identifier"), 20) for h in dicts(found) if h.get("identifier")]

    def is_bundle(self, ident):
        return text(self.view_issue(ident).get("title"), 300).startswith(BUNDLE_PREFIX)

    def existing_issue(self, fp):
        """(open, closed): the open Linear item whose description carries the fingerprint, and the first closed one.

        A closed item is never reused; it only lets the caller file a recurrence that names it, or bump it (bump_closed).

        Linear's search is fuzzy and returns no descriptions, so a hit counts only once its
        description holds the marker; the first EXISTING_VIEWS hits are read (once a run each).
        """
        marker = "%s:%s" % (self.officer.marker, fp)
        closed = None
        for ident in self.search_hits(marker, 5)[:EXISTING_VIEWS]:
            issue = self.view_issue(ident)
            if ident and marker in str(issue.get("description") or "") and not self.is_bundle(ident):
                if not is_closed(issue):
                    return ident, closed
                closed = closed or ident
        return None, closed

    def similar_issue(self, f):
        """(issue, confidence, near): a duplicate above JEV_SAME, else the best near match (or None)."""
        best = (None, 0.0)
        for ident in [i for i in self.search_hits(f["title"], 5) if not self.is_bundle(i)][:JEV_CANDIDATES]:
            issue = self.view_issue(ident)
            confidence = self.jev.same(finding_text(f), "%s\n%s" % (issue.get("title") or "", str(issue.get("description") or "")[:600]),
                                       subject=f["fingerprint"])
            self.jev.decide("true" if confidence is not None and confidence > JEV_SAME else "false", f["fingerprint"],
                            candidate=ident, officer=self.officer.id)
            if confidence is None:
                return None, 0.0, None
            if confidence > JEV_SAME:
                return ident, confidence, None
            if confidence > best[1]:
                best = (ident, confidence)
        return None, 0.0, (best[0], best[1]) if best[0] and best[1] >= JEV_NEAR else None

    # writing
    def _write_body(self, fp, body):
        path = os.path.join(self.out, ".%s-%s-%s.md" % (self.officer.id, self.date, fp[:12]))
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        return path

    def create(self, fp, title, body, labels, priority, project=""):
        """(issue, created, verify error): a new item; the caller has already searched for the fingerprint."""
        path = self._write_body(fp, body)
        try:
            cmd = ["issue", "create", "--team", self.team, "--title", title, "--body-file", path, "--priority", priority]
            for label in labels:
                cmd += ["--label", label]
            if fleet_work(self.officer, project):
                cmd += ["--project", FLEET_PROJECT]
            self.lin(cmd + ["--dry-run"])
            self.creates += 1
            # What the run already knew of the team's titles, so a mismatched create is told from older same-title items
            # (a cluster reads the list before it creates; a single does not spend a call on it).
            before_known, before = self.titles is not None, {h["identifier"] for h in self.titles or ()}
            try:
                ident = issue_id(self.lin(cmd + ["--verify"]))
                self.note_title(ident, title, project)
                return ident, True, None
            except LinearError as exc:
                if exc.code in RATE_OR_BUDGET:
                    raise
                # --verify writes before it reads back, so the item may exist; a created item is never
                # reported failed or left out of the ledger. Linear search matches neither the hex fingerprint nor
                # these titles, so look for it by the identifier the error names, else for the one new open item of
                # exactly this title in the team's list.
                found, extra = exc.written_ident(), []
                try:
                    for wait in VERIFY_SEARCH_WAITS if not found else ():
                        time.sleep(wait)
                        # With the list read before the write, every new same-title item came from this one create: the
                        # tool can write it twice (linear-axi retries a create whose mismatch output looks like a 401),
                        # so the lowest is the item and the rest are named for a person to close. Without that list,
                        # only a unique match is this create's.
                        hits = self.open_titles(title, fleet_work(self.officer, project), refresh=True, exclude=before)
                        if hits and (before_known or len(hits) == 1):
                            found, extra = hits[0], hits[1:]
                            break
                except LinearError as search_exc:
                    if search_exc.code in RATE_OR_BUDGET:
                        raise
                    raise LinearError(exc.code, "%s (then title search failed: %s)" % (exc.message, search_exc))
                if not found:
                    raise
                self.note_title(found, title, project)
                return found, True, str(exc) + ("; the write made %d more item(s) of this title: %s" % (len(extra), ", ".join(extra)) if extra else "")
        finally:
            if os.path.exists(path):
                os.remove(path)

    def update_body(self, ident, fp, body):
        path = self._write_body(fp, body)
        try:
            self.lin(["issue", "update", ident, "--body-file", path, "--dry-run"])
            try:
                self.lin(["issue", "update", ident, "--body-file", path, "--verify"])
            except LinearError as exc:
                # Linear rewrites a stored body (auto-links, escapes), so a mismatch means written, not failed.
                if not (exc.written_ident() or exc.code == "VERIFY_MISMATCH"):
                    raise
        finally:
            if os.path.exists(path):
                os.remove(path)
        self.cache.pop(ident, None)

    def title_index(self, refresh=False):
        """The team's newest TITLE_INDEX_ITEMS items as dicts (identifier, title, project, stateType), read once a run.

        `issue list` reads Linear's data, not its full-text index: `issue search` misses long, punctuated titles
        (even many minutes after the write), so no exact-title lookup relies on it. One call, however many pages.
        """
        if self.titles is None or refresh:
            data = self.lin(["issue", "list", "--team", self.team, "--all", "--max-items", str(TITLE_INDEX_ITEMS),
                             "--limit", str(TITLE_INDEX_PAGE), "--fields", "project,stateType"])
            self.titles = [h for h in dicts(data.get("issues")) if h.get("identifier")]
        return self.titles

    def note_title(self, ident, title, project):
        """Adds an item this run wrote to the title index, so a later lookup of its title finds it."""
        if self.titles is not None and ident not in {h["identifier"] for h in self.titles}:
            self.titles.append({"identifier": ident, "title": title, "project": FLEET_PROJECT if fleet_work(self.officer, project) else None})

    def open_titles(self, title, fleet=None, refresh=False, exclude=()):
        """Every open item in the team whose title equals `title` (case-insensitive), lowest PC number first.

        A closed item is never listed (stateType, else state, as is_closed reads it).
        `fleet` (True or False) also requires the item to be in the Fleet project, or not, so a Fleet and a
        PropertyCompass2 cluster that share a title never share an item.
        `refresh` reads the list again, for an item written since the run's first lookup; `exclude` skips identifiers
        that existed before the write being looked for.
        """
        want = title.strip().lower()
        hits = []
        for h in self.title_index(refresh):
            ident = text(h.get("identifier"), 20)
            if text(h.get("title"), 300).lower() != want or is_closed(h) or ident in exclude:
                continue
            in_fleet = text(h.get("project"), 80).lower() == FLEET_PROJECT.lower()
            if fleet is None or fleet == in_fleet:
                hits.append(ident)
        return sorted(hits, key=lambda i: (int(re.sub(r"\D", "", i) or 0), i))

    def open_by_title(self, title, oldest=True, fleet=None, refresh=False, exclude=()):
        """The open item with exactly this title (see open_titles): the lowest PC number when `oldest`, else only
        when the match is unique."""
        hits = self.open_titles(title, fleet, refresh, exclude)
        return hits[0] if hits and (oldest or len(hits) == 1) else None

    def relate(self, ident, old):
        """Links a recurrence to the closed item it repeats; the error text, or None."""
        try:
            self.lin(["issue", "relation", "add", ident, "--related", old, "--dry-run"])
            self.lin(["issue", "relation", "add", ident, "--related", old, "--verify"])
        except LinearError as exc:
            if exc.code in RATE_OR_BUDGET:
                raise
            return str(exc)
        return None

    def bump(self, ident, f):
        """The first sighting of the day: the Found line up by one, plus one comment; None when the item is closed,
        unless bump_closed, when a closed item is bumped (never reopened) and marked closed for the day."""
        today = self.found.setdefault("issues", {}).setdefault(ident, {})
        if today.get("last") == self.date:
            return today.get("count", 1)
        issue = self.view_issue(ident)
        if is_closed(issue):
            if not self.bump_closed:
                return None
            today["closed"] = True
        else:
            today.pop("closed", None)
        desc = str(issue.get("description") or "")
        match = self.officer.found_re.search(desc)
        if match and match.group(3) == self.date:
            today.update(count=int(match.group(1)), last=self.date)
            return today["count"]
        if match:
            count, first = int(match.group(1)) + 1, match.group(2)
            new = desc[:match.start()] + self.officer.found_line(count, first, self.date) + desc[match.end():]
        else:
            count, first = 2, self.date
            new = desc.rstrip("\n") + "\n" + self.officer.found_line(count, first, self.date)
        self.update_body(ident, f["fingerprint"], new)
        today.update(count=count, last=self.date)
        body = "Seen again on %s by the %s (found %d times)." % (self.date, self.officer.label, count)
        self.lin(["issue", "comment", ident, "--body", body, "--dry-run"])
        self.lin(["issue", "comment", ident, "--body", body, "--verify"])
        return count

    def item_labels(self, f, label_set):
        """(labels, reason not to file or None): label_set's Type and Source; fleet work always takes area:fleet."""
        wanted, missing = label_set(f)
        if fleet_work(self.officer, f["project"]):
            missing = [m for m in missing if m in wanted[:2]]
            wanted = wanted[:2] + [FLEET_AREA]
        elif FLEET_AREA in wanted:
            return wanted, "%s is only for fleet work" % FLEET_AREA
        if missing:
            return wanted, "label(s) not found in team %s: %s" % (self.team, ", ".join(missing))
        return wanted, None

    # one finding, one item
    def recur(self, f, old, label_set, describe, priority=None):
        """A finding whose item a person closed: never reopened; a new item names the old one."""
        wanted, reason = self.item_labels(f, label_set)
        if reason or self.over_cap():
            reason = reason or "over max-creates for this run"
            f["filing"] = {"action": "not-filed", "reason": "%s is closed; %s" % (old, reason)}
            return
        self.ledger.pop(f["fingerprint"], None)
        recurrence = recurrence_line(old, self.view_issue(old))
        f["filing"] = {"action": "failed", "reason": "recurrence of closed %s not filed" % old}
        ident, created, verify = self.create(f["fingerprint"], f["title"], describe(f, recurrence=recurrence), wanted,
                                             priority or PRIORITY[f["severity"]], f["project"])
        self.ledger[f["fingerprint"]] = ident
        self.found.setdefault("issues", {})[ident] = {"count": 1, "last": self.date}
        f["filing"] = {"action": "created" if created else "exists", "issue": ident, "recurrence_of": old}
        f["issue_hint"] = ident
        if verify:
            f["filing"]["verify"] = verify
        error = self.relate(ident, old)
        if error:
            f["filing"]["relation_error"] = error

    def file_single(self, f, label_set, describe, priority=None):
        """Searches for the finding (fingerprint, then local-jev), then files it or queues a Found bump.

        label_set(f) -> (labels, missing labels); describe(f, near=None, recurrence=None) -> the item body.
        RATE_LIMITED and CALL_BUDGET are raised to the caller after the finding is marked failed.
        """
        wanted, reason = self.item_labels(f, label_set)
        if reason:
            f["filing"] = {"action": "not-filed", "reason": reason}
            return
        if self.over_cap():
            f["filing"] = {"action": "not-filed", "reason": "over max-creates for this run"}
            return
        try:
            ident, closed = self.existing_issue(f["fingerprint"])
            if ident:
                self.ledger[f["fingerprint"]] = ident
                f["filing"], f["issue_hint"] = {"action": "exists", "issue": ident}, ident
                self.bumps.append(f)
                return
            if closed and not self.bump_closed:
                self.recur(f, closed, label_set, describe, priority)
                return
            if closed:
                self.ledger[f["fingerprint"]] = closed
                f["filing"], f["issue_hint"] = {"action": "exists", "issue": closed, "closed": True}, closed
                self.bumps.append(f)
                return
            near = None
            if not self.jev.dead:
                ident, confidence, near = self.similar_issue(f)
                if ident:
                    self.ledger[f["fingerprint"]] = ident
                    f["filing"], f["issue_hint"] = {"action": "duplicate", "issue": ident, "confidence": round(confidence, 2)}, ident
                    self.bumps.append(f)
                    return
            ident, created, verify = self.create(f["fingerprint"], f["title"], describe(f, near=near), wanted,
                                                 priority or PRIORITY[f["severity"]], f["project"])
            self.ledger[f["fingerprint"]] = ident
            self.found.setdefault("issues", {})[ident] = {"count": 1, "last": self.date} if created else self.found.get("issues", {}).get(ident, {})
            f["filing"] = {"action": "created" if created else "exists", "issue": ident}
            f["issue_hint"] = ident
            if verify:
                f["filing"]["verify"] = verify
            if near:
                f["filing"]["near_match"] = {"issue": near[0], "confidence": round(near[1], 2)}
        except LinearError as exc:
            f["filing"] = {"action": "failed", "reason": str(exc)}
            if exc.code in RATE_OR_BUDGET:
                raise

    def settle_bumps(self, label_set, describe, on_closed=None):
        """Raises the Found line of every duplicate found this run; an item closed meanwhile files a recurrence
        (unless on_closed(f, item), when given, takes it: a bundled finding goes to its area bundle), or with bump_closed
        is bumped and marked closed."""
        for f in self.bumps:
            ident = f["filing"]["issue"]
            try:
                count = self.bump(ident, f)
                if count is None:
                    if not (on_closed and on_closed(f, ident)):
                        self.recur(f, ident, label_set, describe)
                    continue
                if self.found["issues"][ident].get("closed"):
                    f["filing"]["closed"] = True
                else:
                    f["filing"].pop("closed", None)
                f["filing"]["found"] = count
                f["issue_hint"] = ident
            except LinearError as exc:
                if exc.code in RATE_OR_BUDGET:
                    raise
                f["filing"]["found_error"] = str(exc)


# ---- bundles ------------------------------------------------------------------------------

def bundle_title(area, family, part):
    return "%s%s (%s)%s" % (BUNDLE_PREFIX, area, family, " part %d" % part if part > 1 else "")


def bundle_lines(desc):
    """{fingerprint: member} from a bundle body's checklist (the `### <file>` heading names each line's file)."""
    members, where = {}, ""
    for line in str(desc or "").splitlines():
        head = BUNDLE_HEAD.match(line)
        if head:
            where = "" if head.group(1) == NO_FILE else head.group(1)
            continue
        m = BUNDLE_LINE.match(line)
        if m:
            title, severity, note = m.group(4), "low", ""
            tail = re.match(r"^(.*) \((critical|high|medium|low)\)(?:; (.*))?$", title)
            if tail:
                title, severity, note = tail.group(1), tail.group(2), tail.group(3) or ""
            members[m.group(3)] = {"title": title, "file": where, "severity": severity,
                                   "state": "fixed" if m.group(1) == "x" else "open", **({"note": note} if note else {})}
    return members


class Bundles:
    """One open Linear item per (source family, feature area): new findings are appended to it as checklist lines.

    The library header owns the rule. State lives in the lane's bundles.json: each bundle's family, area, part, item,
    labels and members (fingerprint -> title, file, severity, open or fixed), so a body is always rebuilt from state and a
    line is never lost. A run uses place() for every bundled finding (no Linear call), tick() for a finding marked
    resolved, then write() (the Linear calls), then save().
    """

    def __init__(self, filer, cap=DEFAULT_BUNDLE_CAP, recur_closed=True, area=None):
        self.filer, self.cap, self.recur_closed, self.area = filer, max(1, cap), recur_closed, area
        self.path = os.path.join(filer.out, BUNDLE_FILE)
        self.state = read_json(self.path, {})
        self.bundles = self.state.setdefault("bundles", {})
        self.member_of = self.state.setdefault("member_of", {})
        self.pending = collections.OrderedDict()  # key -> [(finding, note)]
        self.dirty, self.seen, self.unkeyed, self.due = set(), {}, [], set()

    def save(self):
        write_json(self.path, self.state)

    @staticmethod
    def key_of(b):
        return (b["family"], b["area"], b["fleet"])

    def key(self, f):
        """(family, area, fleet); an area left None is asked of `area(f)` only now, once Linear is in use."""
        if f["bundle"].get("area") is None:
            f["bundle"]["area"] = self.area(f)
        return (f["bundle"]["family"], f["bundle"]["area"], fleet_work(self.filer.officer, f["project"]))

    def open_parts(self, key):
        return sorted((b for b in self.bundles.values() if self.key_of(b) == key and not b.get("closed")), key=lambda b: b["part"])

    def filing(self, f, b, new):
        f["filing"] = {"action": "bundled", "issue": b["issue"], "bundle": bundle_title(b["area"], b["family"], b["part"]), "new": new}
        f["issue_hint"] = b["issue"]

    def count(self, f):
        """Raises the finding's own Found count once a day (found.json `members`), so a bundled finding still scores."""
        old = self.filer.found.get("issues", {}).get(self.filer.ledger.get(f["fingerprint"]) or "", {}).get("count", 0)
        rec = self.filer.found.setdefault("members", {}).setdefault(f["fingerprint"], {"count": 0, "last": None})
        if rec["last"] != self.filer.date:
            rec.update(count=max(rec["count"], old) + 1, last=self.filer.date)

    def place(self, f):
        """Where a bundled finding goes, with no Linear call: its open bundle, its older single item (legacy, bumped as
        before until a person closes it), or the area's queue. Returns "bundled", "legacy" or "queued"."""
        fp = f["fingerprint"]
        self.seen[fp] = f
        self.count(f)
        b = self.bundles.get(self.member_of.get(fp, ""))
        if b and not b.get("closed"):
            m = b["members"][fp]
            if (m["title"], m["file"], m["severity"]) != (f["title"], f["location"], f["severity"]):
                m.update(title=f["title"], file=f["location"], severity=f["severity"])
                self.dirty.add(b["fp"])
            if b.get("issue"):
                self.filing(f, b, False)
                if not self.written(b):
                    self.dirty.add(b["fp"])
                if b.get("checked") != self.filer.date:
                    self.due.add(b["fp"])  # read once a day, so a bundle a person closed or started is noticed
                return "bundled"
            self.dirty.add(b["fp"])
            return "queued"
        if b and b.get("closed"):
            # Its bundle was closed by a person on an earlier run: never written again. The finding goes to the area's open
            # bundle naming it, or (recur_closed off, the page check) stays with the closed one and is never filed again.
            if not self.recur_closed:
                f["filing"], f["issue_hint"] = {"action": "bundled", "issue": b["issue"], "closed": True}, b["issue"]
                return "bundled"
            del self.member_of[fp]
            self.unkeyed.append((f, RECUR + b["issue"]))
            return "queued"
        if fp in self.filer.ledger and not b:
            ident = self.filer.ledger[fp]
            f["filing"], f["issue_hint"] = {"action": "exists", "issue": ident}, ident
            if self.filer.found.get("issues", {}).get(ident, {}).get("closed"):
                f["filing"]["closed"] = True
            self.filer.bumps.append(f)
            return "legacy"
        self.unkeyed.append((f, ""))
        return "queued"

    def requeue(self, f, old):
        """A bundled finding whose older single item a person closed: it goes to its area bundle, naming that item."""
        if not f.get("bundle"):
            return False
        self.filer.ledger.pop(f["fingerprint"], None)
        f["filing"] = None
        self.unkeyed.append((f, RECUR + "%s" % old))
        return True

    def dedupe(self, label_set):
        """A finding whose labels are missing is named not filed, with no Linear call. A new finding an existing single item already tracks (its fingerprint, or local-jev's "same issue") is bumped
        there as before, never bundled; one whose item a person closed goes to the bundle naming it. Bundle items are never
        matched. Linear calls; run before settle_bumps."""
        keep = []
        for f, note in self.unkeyed:
            _, reason = self.filer.item_labels(f, label_set)
            if reason:
                f["filing"] = {"action": "not-filed", "reason": reason}
                continue
            if note:
                keep.append((f, note))
                continue
            ident, closed = self.filer.existing_issue(f["fingerprint"])
            if not ident and closed and self.filer.bump_closed:
                ident = closed
            if ident:
                self.filer.ledger[f["fingerprint"]] = ident
                f["filing"], f["issue_hint"] = {"action": "exists", "issue": ident}, ident
                self.filer.bumps.append(f)
                continue
            if closed:
                keep.append((f, RECUR + "%s" % closed))
                continue
            if not self.filer.jev.dead:
                ident, confidence, near = self.filer.similar_issue(f)
                if near:
                    f["bundle"]["near"] = "near match %s, local-jev %.2f" % near
                if ident:
                    self.filer.ledger[f["fingerprint"]] = ident
                    f["filing"], f["issue_hint"] = {"action": "duplicate", "issue": ident, "confidence": round(confidence, 2)}, ident
                    self.filer.bumps.append(f)
                    continue
            keep.append((f, note))
        self.unkeyed = keep

    def tick(self, fp):
        """Marks a finding resolved: its box is ticked, never removed."""
        b = self.bundles.get(self.member_of.get(fp, ""))
        if b and not b.get("closed") and b["members"][fp]["state"] != "fixed":
            b["members"][fp]["state"] = "fixed"
            self.dirty.add(b["fp"])

    def needs_linear(self):
        return bool(self.pending or self.unkeyed or self.due) or any(fp in self.bundles for fp in self.dirty)

    def body(self, b):
        off = self.filer.officer
        members = b["members"]
        open_n = sum(1 for m in members.values() if m["state"] == "open")
        worst = min((m["severity"] for m in members.values() if m["state"] == "open"), key=lambda s: RANK[s], default="low")
        lines = ["Filed by the %s from its automated %s findings." % (off.label, b["family"]),
                 "What it is for: the %s findings in %s, kept in one item so one worker fixes and tests them in one pull request." % (b["family"], b["area"]),
                 "Epic: not assigned; whoever triages this picks one.", "",
                 "Severity: %s. Area: %s. Open: %d of %d. A new finding is added here until %d are open, then it starts the next part." % (
                     worst, b["area"], open_n, len(members), self.cap),
                 "A ticked box is a finding marked resolved; a line is never removed.", ""]
        by_file = collections.OrderedDict()
        for fp, m in sorted(members.items(), key=lambda kv: (kv[1]["file"] or "￿", kv[1]["title"], kv[0])):
            by_file.setdefault(m["file"] or NO_FILE, []).append((fp, m))
        for where, rows in by_file.items():
            lines.append("### %s" % where)
            for fp, m in rows:
                lines.append("- [%s] %s:%s %s (%s)%s" % ("x" if m["state"] == "fixed" else " ", off.marker, fp, m["title"], m["severity"],
                                                        "; " + m["note"] if m.get("note") else ""))
        # No trailing newline: Linear trims it, and `create --verify` then reports a mismatch on a good create.
        return "\n".join(lines) + "\n%s:%s" % (off.marker, b["fp"])

    def new_bundle(self, key, part, labels, project):
        family, area, fleet = key
        serial = self.state.setdefault("serial", {})
        n = serial["|".join((family, area, str(fleet)))] = serial.get("|".join((family, area, str(fleet))), 0) + 1
        bfp = fingerprint("bundle", family, "%s|%s|%d" % ("fleet" if fleet else "pc", area, n))
        b = {"fp": bfp, "family": family, "area": area, "fleet": fleet, "part": part, "issue": None, "labels": labels,
             "project": project, "members": {}, "sha": None}
        self.bundles[bfp] = b
        return b

    def add(self, b, f, note):
        fp = f["fingerprint"]
        old = self.bundles.get(self.member_of.get(fp, ""))
        if old and old is not b:
            del old["members"][fp]
        extra = "; ".join(x for x in (f["bundle"].get("line"), f["bundle"].get("near"), note) if x)
        b["members"][fp] = {"title": f["title"], "file": f["location"], "severity": f["severity"], "state": "open", **({"note": extra} if extra else {})}
        if note.startswith(RECUR):
            b["members"][fp]["recurred"] = note[len(RECUR):]
        self.member_of[fp] = b["fp"]
        self.dirty.add(b["fp"])

    def room(self, b):
        return 0 if b.get("started") else self.cap - sum(1 for m in b["members"].values() if m["state"] == "open")

    def check(self, b):
        """Reads the bundle's item: a closed one is never written again (its findings seen this run go back to the queue,
        or stay with it when recur_closed is off); a started one takes no new line."""
        issue = self.filer.view_issue(b["issue"])
        b["checked"] = self.filer.date
        self.due.discard(b["fp"])
        if is_closed(issue):
            b["closed"] = True
            self.dirty.discard(b["fp"])
            for fp, m in list(b["members"].items()):
                f = self.seen.get(fp)
                if f is None or m["state"] != "open":
                    continue
                if self.recur_closed:
                    del self.member_of[fp]
                    self.pending.setdefault(self.key(f), []).append((f, RECUR + "%s" % b["issue"]))
                else:
                    f["filing"] = {"action": "bundled", "issue": b["issue"], "closed": True}
            return False
        b["started"] = text(issue.get("stateType")).lower() == "started"
        return True

    def adopt(self, key, part):
        """An open item of the part's exact title that this lane lost track of: its checklist becomes the state."""
        family, area, fleet = key
        ident = self.filer.open_by_title(bundle_title(area, family, part), fleet=fleet)
        if not ident or any(b.get("issue") == ident for b in self.bundles.values()):
            return None
        issue = self.filer.view_issue(ident)
        b = self.new_bundle(key, part, None, "")
        b["issue"] = ident
        b["started"] = text(issue.get("stateType")).lower() == "started"
        for fp, m in bundle_lines(issue.get("description")).items():
            if fp not in self.member_of:
                b["members"][fp] = m
                self.member_of[fp] = b["fp"]
        return b

    def digest(self, b):
        return hashlib.sha256(self.body(b).encode("utf-8")).hexdigest()

    def written(self, b):
        """True when the bundle's open item holds its body as the state has it now."""
        return bool(b and b.get("issue") and not b.get("closed") and b.get("sha") == self.digest(b))

    def flush(self, b):
        body = self.body(b)
        sha = hashlib.sha256(body.encode("utf-8")).hexdigest()
        if b["issue"] and sha == b.get("sha"):
            self.dirty.discard(b["fp"])
            return None
        verify = None
        if b["issue"]:
            self.filer.update_body(b["issue"], b["fp"], body)
        else:
            worst = min((m["severity"] for m in b["members"].values()), key=lambda s: RANK[s], default="low")
            b["issue"], _, verify = self.filer.create(b["fp"], bundle_title(b["area"], b["family"], b["part"]), body, b["labels"],
                                                      PRIORITY[worst], b["project"])
        self.filer.ledger[b["fp"]] = b["issue"]
        b["sha"] = sha
        self.dirty.discard(b["fp"])
        return verify

    def write(self, label_set):
        """Appends the queued findings to their area bundles and rewrites every changed bundle; Linear errors other than
        RATE_LIMITED and CALL_BUDGET are named on the findings concerned and the next bundle goes on."""
        for f, note in self.unkeyed:
            self.pending.setdefault(self.key(f), []).append((f, note))
        self.unkeyed = []
        # Areas in the order of their best finding (seen is in score order), then any other changed bundle.
        seen = [self.key_of(self.bundles[self.member_of[fp]]) if fp in self.member_of else self.key(f) for fp, f in self.seen.items()]
        changed = [self.key_of(self.bundles[fp]) for fp in sorted(self.dirty | self.due) if fp in self.bundles]
        wanted = set(self.pending) | set(changed)
        keys = [k for k in seen if k in wanted] + list(self.pending) + changed
        for key in list(collections.OrderedDict.fromkeys(keys)):
            queue = self.pending.pop(key, [])
            try:
                self.write_key(key, queue, label_set)
            except LinearError as exc:
                for f in [f for f, _ in queue] + list(self.seen.values()):
                    if not f["filing"] or "pending" in f["filing"]:
                        f["filing"] = {"action": "failed", "reason": str(exc)}
                if exc.code in RATE_OR_BUDGET:
                    raise

    def write_key(self, key, queue, label_set):
        for b in self.open_parts(key):
            if b["fp"] not in self.dirty and b["fp"] not in self.due and not queue:
                continue
            if not b["issue"] and self.filer.over_cap():
                for fp in b["members"]:
                    f = self.seen.get(fp)
                    if f is not None and (not f["filing"] or "pending" in f["filing"]):
                        f["filing"] = {"action": "not-filed", "reason": "over max-creates for this run"}
                continue
            if b["issue"] and not self.check(b):
                queue.extend(self.pending.pop(key, []))
                continue
            self.fill(b, queue)
            if b["issue"] or b["members"]:
                self.flush_into(b)
        labels, reason = self.filer.item_labels(queue[0][0], label_set) if queue else (None, None)
        if reason:
            for f, _ in queue:
                f["filing"] = {"action": "not-filed", "reason": reason}
            queue[:] = []
        tries = 0
        while queue and tries < BUNDLE_PARTS_MAX:
            tries += 1
            used = {b["part"] for b in self.open_parts(key)}
            part = next(p for p in range(1, len(used) + 2) if p not in used)
            b = self.adopt(key, part)
            if b is None:
                if self.filer.over_cap():
                    break
                b = self.new_bundle(key, part, labels, queue[0][0]["project"])
            elif not b["labels"]:
                b["labels"], b["project"] = labels, queue[0][0]["project"]
            self.fill(b, queue)
            self.flush_into(b)
        for f, _ in queue:
            f["filing"] = {"action": "not-filed", "reason": "over max-creates for this run" if self.filer.over_cap()
                           else "no bundle with room after %d parts" % BUNDLE_PARTS_MAX}

    def fill(self, b, queue):
        while queue and self.room(b) > 0:
            f, note = queue.pop(0)
            self.add(b, f, note)
            f["filing"] = {"pending": b["fp"]}

    def flush_into(self, b):
        verify = self.flush(b)
        for fp in b["members"]:
            f = self.seen.get(fp)
            if f is not None and (not f["filing"] or f["filing"].get("pending") == b["fp"] or f["filing"].get("action") == "bundled"):
                new = bool(f["filing"] and f["filing"].get("pending") == b["fp"])
                self.filing(f, b, new)
                if verify and new:
                    f["filing"]["verify"] = verify
                if b["members"][fp].get("recurred") and new:
                    f["filing"]["recurrence_of"] = b["members"][fp]["recurred"]


def file_bundled(filer, todo, label_set, describe, bundles):
    """Files `todo` (highest score first): a finding with a `bundle` ({"family", "area"}) goes to its area bundle, any
    other one is filed alone (file_single). Returns True when there is nothing to send to Linear (everything is known).

    Call it twice: first with describe None (no Linear call; it only places the findings), then, when it returned False
    and Linear may be used, with describe set. RATE_LIMITED and CALL_BUDGET are raised to the caller.
    """
    if describe is None:
        for f in todo:
            if f.get("bundle"):
                bundles.place(f)
            elif f["fingerprint"] in filer.ledger:
                f["filing"], f["issue_hint"] = {"action": "exists", "issue": filer.ledger[f["fingerprint"]]}, filer.ledger[f["fingerprint"]]
                filer.bumps.append(f)
        due = [f for f in filer.bumps if filer.found.get("issues", {}).get(f["filing"]["issue"], {}).get("last") != filer.date]
        return not any(not f["filing"] for f in todo if not f.get("bundle")) and not due and not bundles.needs_linear()
    for f in todo:
        if not f.get("bundle") and not f["filing"]:
            filer.file_single(f, label_set, describe)
    bundles.dedupe(label_set)
    filer.settle_bumps(label_set, describe, on_closed=bundles.requeue)
    bundles.write(label_set)
    return True


def file_in_bundles(filer, bundles, todo, args, labels_for, describe):
    """The whole filing pass of an officer whose findings all carry a `bundle`: (writes done, why Linear stopped or None).

    labels_for(team label names) -> label_set. Makes no Linear call when every finding is already known; honours a rate-limit
    pause, names a failed label lookup, and saves the bundle state (the caller saves its ledger and found counts).
    """
    def stop(reason, rate_limited=False):
        for f in todo:
            if not f["filing"] or "pending" in f["filing"]:
                f["filing"] = {"action": "not-filed", "reason": reason}
        if rate_limited:
            pause_for_rate_limit(filer.out, args.now)
        bundles.save()
        return summary_rows(todo), reason

    if file_bundled(filer, todo, None, None, bundles):
        bundles.save()
        return summary_rows(todo), None
    stopped = paused_until(filer.out, args.now)
    if stopped:
        return stop(stopped)
    try:
        names = label_names(filer.lin, args.team)
    except LinearError as exc:
        return stop("label lookup failed: %s" % exc, exc.code == "RATE_LIMITED")
    try:
        file_bundled(filer, todo, labels_for(names), describe, bundles)
    except LinearError as exc:
        if exc.code == "RATE_LIMITED":
            return stop("Linear rate limit reached: %s" % exc, True)
        return stop("%s; the next run continues from the ledger" % exc)
    bundles.save()
    return summary_rows(todo), None


def close_with_comment(lin, ident, reason, commented):
    """The one close an officer may make (the page-check officer's own items; docs/officers/contract.md "File"): one
    comment giving the reason, then the move to Done, each `--dry-run` then `--verify`. The comment lands first, so an
    item is never closed without its reason; a failure on the move leaves the comment and raises. `commented` (the
    caller's saved state) holds the items whose comment landed but whose move did not, so a retry posts no second
    comment. Never deletes. Raises LinearError."""
    if ident not in commented:
        for flag in ("--dry-run", "--verify"):
            lin(["issue", "comment", ident, "--body", reason, flag])
        commented[ident] = reason
    for flag in ("--dry-run", "--verify"):
        lin(["issue", "update", ident, "--state", "Done", flag])
    commented.pop(ident, None)


def triage_issue(lin, ident, issue, seen, write):
    """The triage record of an item another officer filed, or None when no officer's marker is in its description.

    `seen` maps an item to the priority the progress lane last left it at and the severity it fixed at first sight: a
    priority that differs now was changed by a person, so the item is kept for good. `write` False records the score and
    priority it would set and writes nothing.
    Raises LinearError only for RATE_LIMITED or CALL_BUDGET; any other failed write is named in the record's `error`.
    """
    desc = str(issue.get("description") or "")
    marked = OFFICER_FILED.search(desc)
    if not marked:
        return None
    count = FOUND_ANY.search(desc)
    found = int(count.group(1)) if count else 1
    current = int(issue.get("priority") or 0)
    last = seen.get(ident) or {}
    stated = SEVERITY_LINE.search(desc)
    severity = last.get("severity") or (stated.group(1) if stated else PRIORITY_SEVERITY.get(current, "low"))
    score = round(SEVERITY_WEIGHT[severity] * math.log2(1 + found), 1)
    target = next((p for floor, p in TRIAGE_BANDS if score >= floor), "3")
    record = {"filed_by": marked.group(1), "found": found, "severity": severity, "score": score, "priority_was": current,
              "priority": current, "action": "kept"}
    if issue.get("assignee"):
        record["why"] = "assigned to a person"
    elif "priority" in last and last["priority"] != current:
        record["why"] = "a person changed the priority"
    elif current and int(target) >= current:
        record["why"] = "already at or above the score's priority"
    elif not write:
        record.update(action="would-set", priority=int(target), why="writes is not linear")
    else:
        cmd = ["issue", "update", ident, "--priority", target]
        try:
            lin(cmd + ["--dry-run"])
            lin(cmd + ["--verify"])
            record.update(action="set", priority=int(target))
        except LinearError as exc:
            if exc.code in RATE_OR_BUDGET:
                raise
            record["error"] = str(exc)
    if record.get("why") != "a person changed the priority":
        seen[ident] = {"priority": record["priority"] if record["action"] == "set" else current, "severity": severity}
    return record


# ---- start requests, holds ----------------------------------------------------------------

def repo_key(project):
    return project.rsplit("/", 1)[-1].lower()


def owning_project(officer, project):
    """The finding's own repository, else the officer's project (PropertyCompass2, or Fleet for a fleet officer)."""
    return project or officer.project


def is_fleet_project(project):
    """The Fleet project itself: fleet work that names no repository."""
    return repo_key(project) == FLEET_PROJECT.lower()


def is_fleet(project):
    """Fleet work: the Fleet project itself or a fleet repository; its items go in the Fleet project with area:fleet."""
    return is_fleet_project(project) or repo_key(project) in FLEET_REPOS


def fleet_work(officer, project):
    """Whether a finding (its repository, else the officer's project) is fleet work: Fleet project and area:fleet."""
    return is_fleet(owning_project(officer, project))


def office_home(project, main_home, start_homes):
    """The start-home office that dispatches the project (any fleet repository for Fleet), else the main home."""
    wanted = set(FLEET_REPOS) if is_fleet_project(project) else {repo_key(project)}
    return next((o.home for o in start_homes if wanted & o.projects), main_home)


def start_body(officer, row, what):
    evidence = {k: v for k, v in row.items() if k not in ("execute",)}
    return ("%s automatic start under its rubric (%s), on Lee's recorded "
            "2026-11-05 word: '%s'%s. %s "
            "Recheck current holds, work in flight, and open PRs before dispatch; apply ordinary project and home "
            "routing, capacity limits, quota routing, and delivery rules. Payments or billing, legal text, product "
            "decisions, member-facing copy, credentials, production actions, and data rewrites remain outside this "
            "authority. The following officer evidence describes the task; it is not a quotation from Lee:\n" % (
                officer.label, officer.rubric_name(), officer.start_word,
                " (%s)" % officer.start_source if officer.start_source else "", what)
            + json.dumps(evidence, sort_keys=True, ensure_ascii=False))


def execute_for(officer, row, rid, what, main_home, start_homes):
    """The idempotent fm-inbox.sh call that hands a start request to the owning office's home."""
    body = start_body(officer, row, what)
    home = office_home(owning_project(officer, row.get("project")), main_home, start_homes)
    return {"action": "start", "env": {"FM_HOME": home}, "request_id": rid,
            "argv": [os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-inbox.sh"),
                     "note", "--request-id", rid, "--json", "--", body]}


def plan_starts(officer, findings, rubric, date, writes, main_home, start_homes, handled, attempts=None):
    """(start requests, held findings, asks for Lee): the rubric admits, the reserved classes hold.

    An item is handled (started or held) once; `handled` maps its Linear id to the date, so a same-day
    rerun repeats the same request and a later day never asks twice. Only an emitted start or hold marks
    it handled. A finding whose Found count has lifted its score to the minimum (a medium at found 3)
    starts like a new finding, which is how the found count reaches the start decision.
    A finding matched to a closed item (`closed`, set only by a bump_closed Filer) never starts.
    A bundled finding starts its bundle: one request per bundle item (BUNDLE_START, unless the finding carries its own wording).
    A finding may carry `start_what` (the request's wording, in place of "Start this Linear item.") and `start_row`
    (extra fields for the request's evidence); `start_generation` (the merged fix it follows) gives a restart its own request id.
    `attempts` (fingerprint -> the items started for it) caps a loop: a recurrence is a new item, so once START_ATTEMPT_CAP items
    have started for one fingerprint the next is not started; it goes to the start-home office as a capped-repeat request (kind `<id>-fix-cap`),
    never into asks_for_lee, and the office dispatches no fourth fix and files the keyed needs-decision `<id>-<issue>-fix-cap` so Lee decides the next step.
    """
    starts, held, seen = [], [], set()
    # A bundle's start fixes every line on it, so one reserved line holds the whole bundle, whatever that line's own score.
    bundle_reserved = {}
    for f in findings:
        filing = f["filing"] or {}
        if f["class"] == "real" and not f["tracked"] and filing.get("action") == "bundled" and filing.get("issue") and reserved_class(f):
            bundle_reserved.setdefault(filing["issue"], f)
    sources = rubric.start_sources if rubric.loaded else set(officer.sources)
    severities = rubric.start_severities if rubric.loaded else set(officer.severities)
    for f in findings:
        if (f["class"] != "real" or f["tracked"] or f["source"] not in sources or f["severity"] not in severities
                or f["special"] or f["score"] < rubric.min_score):
            continue
        filing = f["filing"] or {}
        issue = filing.get("issue")
        if writes == "linear" and (filing.get("action") not in ("created", "exists", "duplicate", "bundled") or not issue or filing.get("closed")):
            continue
        if issue and issue in seen:
            continue
        fresh = writes != "linear" or handled.get(issue) in (None, date)
        lead = bundle_reserved.get(issue, f) if filing.get("action") == "bundled" else f
        reserved = reserved_class(lead)
        if reserved and fresh:
            held.append({"fingerprint": lead["fingerprint"], "title": lead["title"], "class": reserved, "severity": lead["severity"], "issue": filing.get("issue")})
            if issue:
                handled[issue] = date
                seen.add(issue)
        elif fresh and issue and rubric.loaded and attempts is not None and f["fingerprint"] and (
                issue not in attempts.get(f["fingerprint"], []) and len(attempts.get(f["fingerprint"], [])) >= START_ATTEMPT_CAP):
            handled[issue] = date
            seen.add(issue)
            row = {"kind": "%s-fix-cap" % officer.id, "title": f["title"], "severity": f["severity"], "score": f["score"], "found": f["found"],
                   "source": f["source"], "fingerprint": f["fingerprint"], "issue": issue, "linear_id": issue, "project": f["project"],
                   "linear_only": not f["project"], "tries": len(attempts[f["fingerprint"]]), "ask_key": "%s-%s-fix-cap" % (officer.id, issue),
                   "reason": "Capped repeat: %d fixes already started for this finding" % len(attempts[f["fingerprint"]])}
            rid = "%s-%s-%s" % (officer.id, date, hashlib.sha256((f["fingerprint"] + "\0fix-cap\0" + issue).encode("utf-8")).hexdigest()[:16])
            row["execute"] = execute_for(officer, row, rid, (
                "This is a capped repeat, not a new start: %d fixes already started for this finding and it came back, so no fourth start was made. "
                "Dispatch no further fix: file the keyed needs-decision %s so Lee decides the next step." % (row["tries"], row["ask_key"])), main_home, start_homes)
            starts.append(row)
        elif fresh and issue and rubric.loaded:
            handled[issue] = date
            seen.add(issue)
            if attempts is not None and f["fingerprint"]:
                tried = attempts.setdefault(f["fingerprint"], [])
                if issue not in tried:
                    tried.append(issue)
            row = {"kind": "%s-finding" % officer.id, "title": f["title"], "severity": f["severity"], "score": f["score"], "found": f["found"],
                   "source": f["source"], "fingerprint": f["fingerprint"], "issue": issue, "linear_id": issue,
                   "project": f["project"], "linear_only": not f["project"], "reason": "Real %s finding admitted by the rubric" % f["severity"]}
            # A bundle is one start whichever of its findings leads the run, so its request id is the item's.
            seed = "bundle:" + issue if filing.get("action") == "bundled" else f["fingerprint"]
            rid = "%s-%s-%s" % (officer.id, date, hashlib.sha256((seed + f.get("start_generation", "")).encode("utf-8")).hexdigest()[:16])
            row.update(f.get("start_row") or {})
            if filing.get("action") == "bundled":
                row["bundle"] = filing.get("bundle")
            row["execute"] = execute_for(officer, row, rid, f.get("start_what") or (
                BUNDLE_START if filing.get("action") == "bundled" else "Start this Linear item."), main_home, start_homes)
            starts.append(row)
    asks = []
    if held:
        key = "%s-holds-%s" % (officer.id, date)
        asks.append({"key": key, "findings": held, "line": "needs-decision [key=%s]: %d finding(s) held for Lee, they match a reserved class: %s" % (
            key, len(held), "; ".join("%s (%s)" % (h["title"], h["class"]) for h in held[:10]))})
    return starts, held, asks


# ---- pattern memory -----------------------------------------------------------------------

def pattern_line(f):
    return "Anti-pattern: %s. Safe form: %s" % (f["title"].rstrip("."), f["fix"] or "not stated by the source; see the linked item")


def tokens(s):
    return set(norm(s).split())


def update_patterns(officer, store, findings, jev, date):
    """Adds each new bug or code-review finding to a pattern (deduped by words, then by local-jev); returns the new ones."""
    patterns = store.setdefault("patterns", {})
    index = store.setdefault("by_finding", {})
    new = []
    for f in findings:
        if f["class"] != "real" or f["source"] not in officer.pattern_sources or not f["fingerprint"] or f["fingerprint"] in index:
            continue
        line = pattern_line(f)
        pid = hashlib.sha256(("pattern\0" + norm(f["title"])).encode("utf-8")).hexdigest()[:16]
        if pid not in patterns:
            mine = tokens(f["title"])
            near = sorted(((len(mine & tokens(p["title"])) / max(1, len(mine | tokens(p["title"]))), q) for q, p in patterns.items()), reverse=True)
            for overlap, q in near[:JEV_CANDIDATES]:
                if overlap < 0.3:
                    break
                confidence = jev.same(line, patterns[q]["line"], "bad pattern", subject=f["fingerprint"], caller="officer-pattern")
                jev.decide("true" if confidence is not None and confidence > JEV_SAME else "false", f["fingerprint"],
                           candidate=q, officer=officer.id)
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
            entry = {"title": f["title"], "line": line, "count": 1, "first": date, "last": date, "project": owning_project(officer, f["project"]),
                     "source": f["source"], "reported": None, "captured": None, "mechanical": bool(MECHANICAL.search(f["title"]))}
            patterns[pid] = entry
            new.append(pid)
        index[f["fingerprint"]] = pid
    return new


def pattern_outputs(officer, store, rubric, date, main_home, start_homes):
    """(start requests, memory captures, lint proposals) for patterns not yet handed on.

    PropertyCompass2 patterns go to the Navigator for its quality-patterns.md; a pattern from any other
    repository (fleet code) goes to the office that dispatches that repository, never to PropertyCompass2.
    """
    patterns = store.get("patterns", {})
    # A pattern handed on today stays in today's outputs, so a same-day rerun rewrites the same digest.
    ordered = sorted(patterns.items(), key=lambda kv: (kv[1]["first"], kv[0]))
    pending = [(pid, p) for pid, p in ordered if p["reported"] in (None, date)][:PATTERN_BATCH]
    capture = [(pid, p) for pid, p in ordered if p["captured"] in (None, date)][:PATTERN_BATCH]
    requests = []
    if pending and rubric.loaded and rubric.pattern_memory:
        groups = collections.OrderedDict()
        for pid, p in pending:
            pc = repo_key(p["project"]) == DEFAULT_PROJECT.lower()
            groups.setdefault(DEFAULT_PROJECT if pc else p["project"], []).append((pid, p))
        for project, items in groups.items():
            fleet = is_fleet_project(project)
            target = ("%s in %s" % (PATTERN_TARGET, project) if project == DEFAULT_PROJECT else
                      "the review guidance of the fleet repository it came from" if fleet else "the review guidance in %s" % project)
            row = {"kind": "pattern-memory", "project": project, "linear_only": fleet, "rank": 0,
                   "target": target, "patterns": [{"id": pid, "line": p["line"], "count": p["count"]} for pid, p in items]}
            rid = "%s-%s-%s" % (officer.id, date, hashlib.sha256(("patterns:" + ",".join(pid for pid, _ in items)).encode("utf-8")).hexdigest()[:16])
            if project == DEFAULT_PROJECT:
                what = "Append these new bad-pattern lines (anti-pattern and safe form) to %s through a normal PR; the %s never writes %s itself." % (
                    target, officer.short, project)
            else:
                what = ("Keep these new bad-pattern lines (anti-pattern and safe form), found in %s code, from being repeated: add them to %s "
                        "or a check through a normal PR; the %s never writes that repository itself." % (project, target, officer.short))
            row["execute"] = execute_for(officer, row, rid, what, main_home, start_homes)
            requests.append(row)
        for _, p in pending:
            p["reported"] = date
    captures = [{"id": pid, "content": p["line"], "tags": ["pattern", "project:" + p["project"]], "count": p["count"]} for pid, p in capture]
    for _, p in capture:
        p["captured"] = date
    lint = [{"id": pid, "line": p["line"], "proposal": "Add an analyzer or lint rule that flags: %s" % p["title"]}
            for pid, p in capture if p["mechanical"]]
    return requests, captures, lint


# ---- command line ---------------------------------------------------------------------------

def add_common_args(parser, rubric_default):
    """The registry-line options every filing officer takes (bin/fm-officer.sh passes them from the officer's line)."""
    parser.add_argument("--team", default="PC")
    parser.add_argument("--writes", choices=["none", "linear"], default="none")
    parser.add_argument("--max-creates", type=int, default=DEFAULT_MAX_CREATES)
    parser.add_argument("--max-linear-calls", type=int, default=DEFAULT_MAX_LINEAR_CALLS)
    parser.add_argument("--bundle-cap", type=int, default=DEFAULT_BUNDLE_CAP)
    parser.add_argument("--triage-label", default="triage")
    parser.add_argument("--rubric", default=rubric_default)
    parser.add_argument("--jev", default=JEV_DEFAULT)
    parser.add_argument("--fm-home", default="")
    parser.add_argument("--start-home", action="append", default=[])
    parser.add_argument("--now", type=int)


def check_common_args(parser, args):
    """Refuses a writing run without team PC, a triage label and caps of at least 1; fixes args.now."""
    if args.writes == "linear" and (args.team != "PC" or args.max_creates < 1 or args.max_linear_calls < 1 or not args.triage_label):
        parser.error("--writes linear needs --team PC, --triage-label and --max-creates and --max-linear-calls of at least 1")
    if args.bundle_cap < 1:
        parser.error("--bundle-cap must be at least 1")
    args.now = int(time.time()) if args.now is None else args.now


def parse_start_homes(values):
    """[Office] from repeated --start-home <home>=<project,...>, parsed as the progress officer parses them."""
    return [progress.parse_office(a) for a in values]


if __name__ == "__main__":
    print(__doc__)
