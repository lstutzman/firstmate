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
              Every write is `--dry-run` then `--verify`. A failed verify is never retried; the fingerprint search then
              decides whether the item exists. An item a person closed (completed or canceled) is never reopened,
              edited or re-prioritised: a repeat finding files a new item that names it (`Recurrence of <id>`).
              An item gets exactly one Type, one Source and one area label; fleet work
              (is_fleet: a finding's repository, else its Officer's project) goes in the Fleet project, with the area:fleet label (fleet_labels). The library never creates a label and never closes
              or deletes an item.
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
START_ATTEMPT_CAP = 3  # starts for one fingerprint (a recurrence is a new item) before the owning office decides
PATTERN_BATCH = 40
EXISTING_VIEWS = 3
VERIFY_SEARCH_WAITS = (0, 0.5, 1.0)
CLOSED_STATES = ("Done", "Canceled", "Cancelled", "Duplicate")
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
    """Found count and score per finding; the list ends up highest score first."""
    issues = found.get("issues", {})
    for f in findings:
        item = issues.get(ledger.get(f["fingerprint"]) or "", {})
        f["found"] = max(1, item.get("count", 1))
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
    def __init__(self, code, message):
        super().__init__("%s: %s" % (code, message))
        self.code = code
        self.message = message


class Linear:
    """linear-axi calls, counted against a budget; every call asks for JSON and raises LinearError on a failure."""

    def __init__(self, budget=DEFAULT_MAX_LINEAR_CALLS):
        self.n, self.budget = 0, budget

    def reset(self, budget):
        self.n, self.budget = 0, budget

    def __call__(self, args):
        if self.n >= self.budget:
            raise LinearError("CALL_BUDGET", "Linear call budget of %d reached" % self.budget)
        self.n += 1
        proc = subprocess.run(["linear-axi"] + args + ["--output", "json"], capture_output=True, check=False)
        try:
            doc = json.loads(proc.stdout.decode("utf-8"))
        except ValueError:
            raise LinearError("NO_JSON", "linear-axi %s returned no JSON (exit %d)" % (" ".join(args[0:2]), proc.returncode))
        if not doc.get("ok"):
            error = doc.get("error") or {}
            raise LinearError(error.get("code", "unknown"), str(error.get("message", ""))[:120])
        return doc.get("data") or {}


def issue_id(data):
    issue = data.get("issue") if isinstance(data.get("issue"), dict) else data
    return text(issue.get("identifier"), 20) or "unknown"


def is_closed(issue):
    kind = text(issue.get("stateType")).lower()
    return kind in ("completed", "canceled") if kind else text(issue.get("state")) in CLOSED_STATES


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

    def __init__(self, officer, lin, team, date, out, ledger, found, jev, max_creates):
        self.officer, self.lin, self.team, self.date, self.out = officer, lin, team, date, out
        self.ledger, self.found, self.jev, self.max_creates = ledger, found, jev, max_creates
        self.cache, self.creates, self.bumps = {}, 0, []

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

    def existing_issue(self, fp):
        """(open, closed): the open Linear item whose description carries the fingerprint, and the first closed one.

        A closed item is never reused; it only lets the caller file a recurrence that names it.

        Linear's search is fuzzy and returns no descriptions, so a hit counts only once its
        description holds the marker; the first EXISTING_VIEWS hits are read (once a run each).
        """
        marker = "%s:%s" % (self.officer.marker, fp)
        closed = None
        for ident in self.search_hits(marker, 5)[:EXISTING_VIEWS]:
            issue = self.view_issue(ident)
            if ident and marker in str(issue.get("description") or ""):
                if not is_closed(issue):
                    return ident, closed
                closed = closed or ident
        return None, closed

    def similar_issue(self, f):
        """(issue, confidence, near): a duplicate above JEV_SAME, else the best near match (or None)."""
        best = (None, 0.0)
        for ident in self.search_hits(f["title"], 5)[:JEV_CANDIDATES]:
            issue = self.view_issue(ident)
            confidence = self.jev.same(finding_text(f), "%s\n%s" % (issue.get("title") or "", str(issue.get("description") or "")[:600]))
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
            try:
                return issue_id(self.lin(cmd + ["--verify"])), True, None
            except LinearError as exc:
                if exc.code in RATE_OR_BUDGET:
                    raise
                # --verify writes before it reads back, so the item may exist; a created item is never
                # reported failed or left out of the ledger.
                found = None
                try:
                    for wait in VERIFY_SEARCH_WAITS:
                        time.sleep(wait)
                        found = self.existing_issue(fp)[0]
                        if found:
                            break
                except LinearError as search_exc:
                    if search_exc.code in RATE_OR_BUDGET:
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
            self.lin(["issue", "update", ident, "--body-file", path, "--dry-run"])
            self.lin(["issue", "update", ident, "--body-file", path, "--verify"])
        finally:
            if os.path.exists(path):
                os.remove(path)
        self.cache.pop(ident, None)

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
        """The first sighting of the day: the Found line up by one, plus one comment; None when the item is closed."""
        today = self.found.setdefault("issues", {}).setdefault(ident, {})
        if today.get("last") == self.date:
            return today.get("count", 1)
        issue = self.view_issue(ident)
        if is_closed(issue):
            return None
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
        body = "Seen again on %s by the %s (found %d times)." % (self.date, self.officer.label, count)
        self.lin(["issue", "comment", ident, "--body", body, "--dry-run"])
        self.lin(["issue", "comment", ident, "--body", body, "--verify"])
        today.update(count=count, last=self.date)
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
            if closed:
                self.recur(f, closed, label_set, describe, priority)
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

    def settle_bumps(self, label_set, describe):
        """Raises the Found line of every duplicate found this run; an item closed meanwhile files a recurrence."""
        for f in self.bumps:
            ident = f["filing"]["issue"]
            try:
                count = self.bump(ident, f)
                if count is None:
                    self.recur(f, ident, label_set, describe)
                    continue
                f["filing"]["found"] = count
                f["issue_hint"] = ident
            except LinearError as exc:
                if exc.code in RATE_OR_BUDGET:
                    raise
                f["filing"]["found_error"] = str(exc)


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
    A finding may carry `start_what` (the request's wording, in place of "Start this Linear item.") and `start_row`
    (extra fields for the request's evidence); `start_generation` (the merged fix it follows) gives a restart its own request id.
    `attempts` (fingerprint -> the items started for it) caps a loop: a recurrence is a new item, so once START_ATTEMPT_CAP items
    have started for one fingerprint the next is not started but asked for as one keyed needs-decision (`<id>-<issue>-fix-cap`).
    """
    starts, held, seen, capped = [], [], set(), []
    sources = rubric.start_sources if rubric.loaded else set(officer.sources)
    severities = rubric.start_severities if rubric.loaded else set(officer.severities)
    for f in findings:
        if (f["class"] != "real" or f["tracked"] or f["source"] not in sources or f["severity"] not in severities
                or f["special"] or f["score"] < rubric.min_score):
            continue
        filing = f["filing"] or {}
        issue = filing.get("issue")
        if writes == "linear" and (filing.get("action") not in ("created", "exists", "duplicate") or not issue):
            continue
        if issue and issue in seen:
            continue
        fresh = writes != "linear" or handled.get(issue) in (None, date)
        reserved = reserved_class(f)
        if reserved and fresh:
            held.append({"fingerprint": f["fingerprint"], "title": f["title"], "class": reserved, "severity": f["severity"], "issue": filing.get("issue")})
            if issue:
                handled[issue] = date
                seen.add(issue)
        elif fresh and issue and rubric.loaded and attempts is not None and f["fingerprint"] and (
                issue not in attempts.get(f["fingerprint"], []) and len(attempts.get(f["fingerprint"], [])) >= START_ATTEMPT_CAP):
            handled[issue] = date
            seen.add(issue)
            capped.append({"fingerprint": f["fingerprint"], "title": f["title"], "issue": issue, "tries": len(attempts[f["fingerprint"]])})
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
            rid = "%s-%s-%s" % (officer.id, date, hashlib.sha256((f["fingerprint"] + f.get("start_generation", "")).encode("utf-8")).hexdigest()[:16])
            row.update(f.get("start_row") or {})
            row["execute"] = execute_for(officer, row, rid, f.get("start_what") or "Start this Linear item.", main_home, start_homes)
            starts.append(row)
    asks = []
    for c in capped:
        key = "%s-%s-fix-cap" % (officer.id, c["issue"])
        asks.append({"key": key, "findings": [c], "line": "needs-decision [key=%s]: %s has failed again after %d started fixes, so no fourth start; the owning office decides" % (
            key, c["title"], c["tries"])})
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
    args.now = int(time.time()) if args.now is None else args.now


def parse_start_homes(values):
    """[Office] from repeated --start-home <home>=<project,...>, parsed as the progress officer parses them."""
    return [progress.parse_office(a) for a in values]


if __name__ == "__main__":
    print(__doc__)
