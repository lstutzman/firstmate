#!/usr/bin/env python3
"""fm-officer-library.py - the library officer's daily judgement of the weekly librarian audit.

Run only through `bin/fm-officer.sh run <id>`, which owns the officer
contract; docs/configuration.md "Library officer" owns the registry fields.

Usage:
  fm-officer-library.py run --audit <runs-dir> --date <YYYY-MM-DD> --out <lane-dir> [--now <epoch>]
                            [--writes none|linear] [--team PC] [--max-creates <n>]
                            [--max-linear-calls <n>] [--rubric <file>] [--jev <jev.py>]
                            [--fm-home <dir>] [--start-home <home>=<projects>[=<role>[=<mandate>]]]...

The fleet-app librarian-audit job collects (deploy/README.md section 21 in
fleet-app); this officer only judges. It reads the newest
<runs-dir>/<YYYY-MM-DD>/ folder (a moved-aside folder such as
`2026-10-31.stale-<id>` is skipped): result.json for its outcome and counts,
and findings.json, the audit's list of findings (kind, severity, title, path,
evidence, disposition). It never reads the report or any audited file, and
never edits the audit job or its inbox note.

Each finding goes to one bucket, from its kind, path and proposed disposition
alone, in this order:
  code       kind unneeded-code, or a disposition that needs an implementation,
             upgrade or own brief or scope: code work, not a docs PR;
  needs-lee  kind conflict (the librarian never rewrites requirements to settle
             one), an instruction or hook file (AGENTS.md, CLAUDE.md, SKILL.md,
             .claude/, .agents/, .codex/), or a disposition naming Lee, an
             owner, an approval or a decision;
  hold       a disposition that starts unresolved, keep, leave, report only or
             no action;
  needs-lee  a disposition naming a delete, removal, retirement or archive
             (fleet rules section 6);
  safe       kind readme, stack-drift or misplaced with a disposition that
             proposes, records, adds, corrects, moves, links or regenerates: one
             docs PR per repository can ship it;
  hold       everything else: unresolved, keep, report only, or a check still
             to make.
The run's `counts.decisions`, Lee's calls in the report, is one needs-lee
item naming the report beside the run's result.

A finding is reported once (fm-officer-corpus.py's reported.json rule): its
fingerprint hashes kind, path and title. The digest line counts new code,
needs-lee and safe items; hold items are listed, never counted and never
recorded, so one that later moves to a counted bucket is new then. When the
audit folder, result or findings file cannot be read, the ledger entries
from that input are kept, so an outage does not re-report them. A missing
run, result or findings file is a coverage gap, a failed or partial outcome or
a run older than AUDIT_DAYS days is a coverage note, and none of them fails the
run. Re-running a key on unchanged inputs writes identical bytes.

Linear. The officer follows the shared officer contract (docs/officers/contract.md;
bin/fm-officer-linear.py owns the mechanics) with its rubric docs/officers/library-rubric.md,
which owns what counts as work, how a finding is scored and what starts. With
--writes linear (the registry's `writes: linear`, with max-creates, max-linear-calls and
jev) every new code, needs-lee and safe finding is filed in team PC as a Chore, label
scheduled-review, with the documentation area label (else the triage label), searched for
first by its `librarian-fp:<sha256>` marker and then by title with local-jev. Hold items and
the run's decisions item are never filed. The Filer runs on the audit run's date, so the
Found line rises once per audit run and not once a day; the create cap (fleet rules
section 8: 3, and a larger --max-creates is held to 3) is per audit run, not per day, and what it leaves unfiled is named in the
digest and filed by the next audit run. A safe finding is filed as medium at least, so it
reaches the start score once the audit finds it three times (a high one at once). A safe
finding whose item exists and whose score reaches the rubric minimum gets a start request in
`start_requests` (and, for this home, a <date>.start-requests.sh handoff). The weekly audit
covers PropertyCompass2 only, so every finding is PropertyCompass2 work: it is filed without the
Fleet project, and its start request goes to the --start-home office whose dispatch list names
PropertyCompass2, else to --fm-home. Code and needs-lee findings are filed and
never start. A safe finding that matches a reserved class is held, and the audit's
needs-lee items become one keyed needs-decision `library-needs-lee-<run>` in `asks_for_lee`.
The lane keeps filed-fingerprints.json, found.json and review-state.json only when it writes.

Outputs <date>.json and <date>.md in --out, prints one `Coverage gap:` line
per gap and `DIGEST <date> <n-new> <date>.md` last.
"""

import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import re
import sys
import time

AUDIT_DAYS = 8
RUN_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
INSTRUCTION_RE = re.compile(r"(^|/)(AGENTS\.md|CLAUDE\.md|SKILL\.md)$|(^|/)\.(claude|agents|codex)/")
CODE_RE = re.compile(r"\b(implementation|upgrade|own) (brief|scope)\b|\bits own brief\b", re.I)
LEE_RE = re.compile(r"\b(lee|owner|approv\w*|decides?|decision)\b", re.I)
HOLD_RE = re.compile(r"^\s*(unresolved|keep|leave|report only|no action)\b", re.I)
DESTRUCTIVE_RE = re.compile(r"\b(delet|remov|retir|archiv|trash)\w*", re.I)
SAFE_RE = re.compile(r"\b(propose|record|add|correct|move|link|point|regenerate|make sure)\w*", re.I)
SAFE_KINDS = ("readme", "stack-drift", "misplaced")
COUNTED = ("code", "needs-lee", "safe")


def _corpus():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-officer-corpus.py")
    spec = importlib.util.spec_from_file_location("fm_officer_corpus", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


corpus = _corpus()


def bucket(f):
    kind, path, disposition = f["kind"], f["path"], f["disposition"]
    if kind == "unneeded-code" or CODE_RE.search(disposition):
        return "code", "code work, not a docs change"
    if kind == "conflict":
        return "needs-lee", "a conflict is never settled by rewriting requirements"
    if INSTRUCTION_RE.search(path):
        return "needs-lee", "an instruction or hook file"
    m = LEE_RE.search(disposition)
    if m:
        return "needs-lee", "the disposition says %s" % m.group(0).lower()
    if HOLD_RE.search(disposition):
        return "hold", "nothing to ship yet"
    m = DESTRUCTIVE_RE.search(disposition)
    if m:
        return "needs-lee", "the disposition says %s" % m.group(0).lower()
    if kind in SAFE_KINDS and SAFE_RE.search(disposition):
        return "safe", "a docs change one PR can ship"
    return "hold", "nothing to ship yet"


RUBRIC_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "officers", "library-rubric.md")
SOURCE = "audit"
TYPE_LABEL = "Chore"
SOURCE_LABEL = "scheduled-review"
AREA_LABEL = "documentation"
MARKER = "librarian-fp"
MAX_CREATES = 3


def text(value, limit):
    return " ".join(str(value).split())[:limit] if isinstance(value, str) else ""


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def judge(run_dir, date, now):
    """(items, coverage, notes, unread) for one audit run folder."""
    coverage, notes, items, unread = [], [], [], set()
    result = load(os.path.join(run_dir, "result.json"))
    raw = load(os.path.join(run_dir, "findings.json"))
    if not isinstance(result, dict):
        unread.add("result")
        coverage.append("audit run %s has no readable result.json" % date)
        result = {}
    if not isinstance(raw, list):
        unread.add("findings")
        coverage.append("audit run %s has no readable findings.json" % date)
        raw = []
    counts = result.get("counts") if isinstance(result.get("counts"), dict) else {}
    outcome = result.get("outcome")
    if result and outcome != "ok":
        coverage.append("audit run %s outcome is %s, so its findings may be incomplete" % (date, outcome))
    made = datetime.datetime.strptime(date, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp()
    if now - made > AUDIT_DAYS * 86400:
        coverage.append("the newest audit run, %s, is more than %d days old" % (date, AUDIT_DAYS))
    if result:
        notes.append("Audit run %s: outcome %s; %s." % (date, outcome, ", ".join(
            "%s %s" % (k, counts[k]) for k in sorted(counts))))
    for f in raw:
        if not isinstance(f, dict):
            continue
        f = {k: text(f.get(k), 300) for k in ("kind", "severity", "title", "path", "evidence", "disposition")}
        b, why = bucket(f)
        items.append(dict(f, bucket=b, why=why, source="findings", fingerprint=hashlib.sha256(
            "\0".join(("library", f["kind"], f["path"], f["title"])).encode("utf-8")).hexdigest()))
    decisions = counts.get("decisions")
    if isinstance(decisions, int) and decisions > 0:
        items.append({"kind": "decisions", "severity": "high", "title": "%d decision(s) for Lee" % decisions,
                      "path": os.path.join(run_dir, "report.md"), "evidence": "", "disposition": "one Captain's Log card for the run",
                      "bucket": "needs-lee", "why": "the audit's decisions for Lee", "source": "result",
                      "fingerprint": hashlib.sha256(("library\0decisions\0" + date).encode("utf-8")).hexdigest()})
    order = {b: n for n, b in enumerate(COUNTED + ("hold",))}
    rank = {"high": 0, "medium": 1, "low": 2}
    items.sort(key=lambda i: (order[i["bucket"]], rank.get(i["severity"], 3), i["path"], i["title"]))
    return items, coverage, notes, unread


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
    off = lib.Officer("library", "Library officer", "Library officer", RUBRIC_FILE, (SOURCE,))
    off.marker = MARKER  # fleet rules section 8 names the fingerprint librarian-fp
    return off


def lib_findings(lib, items):
    """One shared-library finding per audit finding that is code, needs-lee or safe; the decisions item and holds are not filed."""
    out = []
    for i in items:
        if i["source"] != "findings" or i["bucket"] not in COUNTED:
            continue
        severity = i["severity"] if i["severity"] in lib.SEVERITIES else "low"
        if i["bucket"] == "safe" and lib.RANK[severity] > lib.RANK["medium"]:
            severity = "medium"
        lf = lib.make_finding(SOURCE, i["kind"], i["path"] + "\0" + i["title"], i["title"], i["disposition"], "real",
                              severity, False, {}, location=i["path"], fix=i["disposition"])
        lf["item"] = i
        out.append(lf)
    return out


def description(lf, run, off, near=None, recurrence=None):
    """The Linear item body: the audit's own words about the path and the proposed change, no report text."""
    i = lf["item"]
    lines = ["Filed by the library officer from the %s librarian audit." % run,
             "What it is for: keep the repository's documents placed, current and readable.", "Epic: not assigned; whoever triages this picks one.", "",
             "Severity: %s. Kind: %s. Path: %s. Bucket: %s (%s)." % (lf["severity"], i["kind"], i["path"], i["bucket"], i["why"]),
             off.found_line(1, run, run)]
    if recurrence:
        lines.append(recurrence)
    if near:
        lines.append("Near match (not treated as the same issue): %s, local-jev %.2f." % near)
    lines += ["Finding: %s" % i["title"], "Proposed: %s" % i["disposition"]]
    # No trailing newline: Linear trims it, and `create --verify` then reports a mismatch on a good create.
    return "\n".join(lines) + "\n%s:%s" % (off.marker, lf["fingerprint"])


def file_findings(lib, off, todo, args, run, out, ledger, found, jev, lin, allowed):
    """Files the findings highest score first, in one bundle per audit kind (lib.Bundles), at most `allowed` new bundle
    items; returns (writes done, why Linear stopped or None, items created)."""
    filer = lib.Filer(off, lin, args.team, run, out, ledger, found, jev, allowed)
    bundles = lib.Bundles(filer, args.bundle_cap, area=lambda f: f["item"]["kind"])
    for f in todo:
        f["bundle"] = {"family": "librarian audit", "area": None}

    def labels_for(names):
        def label_set(f):
            wanted = [TYPE_LABEL, SOURCE_LABEL, AREA_LABEL if AREA_LABEL in names else args.triage_label]
            return wanted, [w for w in wanted if w.lower() not in names]
        return label_set

    def describe(f, near=None, recurrence=None):
        return description(f, run, off, near, recurrence)

    rows, reason = lib.file_in_bundles(filer, bundles, todo, args, labels_for, describe)
    return rows, reason, filer.creates


def linear_pass(args, run, items, unread, offices, main_home):
    """Files the audit's findings (writes: linear) and hands the safe ones to the owning office; returns digest fields."""
    lib = _lib()
    off = officer(lib)
    out, linear = args.out, args.writes == "linear" and run and not unread
    lin = lib.Linear(args.max_linear_calls)
    state = lib.read_json(os.path.join(out, lib.STATE_FILE), {})
    found = lib.read_json(os.path.join(out, lib.FOUND_FILE), {})
    ledger = lib.read_json(os.path.join(out, lib.LEDGER_FILE), {})
    findings = lib_findings(lib, items)
    rubric = lib.load_rubric(args.rubric, off)
    jev = lib.Jev(args.jev)
    lib.apply_found(findings, found, ledger)
    created = state.setdefault("created", {})
    writes, blocked = [], None
    if linear:
        writes, blocked, n = file_findings(lib, off, findings, args, run, out, ledger, found, jev, lin,
                                           max(0, min(args.max_creates, MAX_CREATES) - created.get(run, 0)))
        created[run] = created.get(run, 0) + n
        lib.apply_found(findings, found, ledger)
    safe = [f for f in findings if f["item"]["bucket"] == "safe"]
    for f in safe:
        f.update(start_what="Ship this audit finding in the next docs pull request for its repository (at most one per repository per run): %s." % f["title"],
                 start_row={"path": f["item"]["path"], "kind": f["item"]["kind"], "proposed": f["item"]["disposition"]})
    handled = state.setdefault("handled", {})
    starts, held, asks = lib.plan_starts(off, safe, rubric, args.date, args.writes if linear else "none", main_home, offices, handled)
    for rank, row in enumerate(starts, 1):
        row["rank"] = rank
    lee = [i for i in items if i["bucket"] == "needs-lee"]
    # Asked once per audit run: a later day's digest does not repeat it, a same-day rerun does.
    if lee and run and state.setdefault("asked", {}).setdefault(run, args.date) == args.date:
        key = "library-needs-lee-%s" % run
        asks.append({"key": key, "findings": [{"title": i["title"], "path": i["path"]} for i in lee],
                     "line": "needs-decision [key=%s]: %d audit item(s) need Lee, listed in the %s digest: %s" % (
                         key, len(lee), run, "; ".join(i["title"] for i in lee[:10]))})
    gaps = rubric.gaps + ([jev.gap] if jev.gap and linear else [])
    if linear:
        for name, doc in ((lib.LEDGER_FILE, ledger), (lib.STATE_FILE, state), (lib.FOUND_FILE, found)):
            lib.write_json(os.path.join(out, name), doc)
    for f in findings:
        f["item"]["linear"] = {"severity": f["severity"], "found": f["found"], "score": f["score"],
                               **{k: v for k, v in (f["filing"] or {}).items() if k in ("action", "issue", "reason", "found", "recurrence_of")}}
    return {"writes": args.writes, "writes_done": writes, "writes_blocked": blocked, "linear_calls": lin.n,
            "linear_call_budget": lin.budget, "linear_gaps": gaps, "not_filed": lib.not_filed_lines(findings),
            "start_requests": starts, "held": held, "asks_for_lee": asks}


def render_md(doc):
    lines = ["# Library officer digest for %s" % doc["date"], "",
             "%d new item(s) to act on. Audit run: %s." % (doc["actionable"], doc["run"] or "none"), ""]
    lines += ["- " + n for n in doc["notes"]]
    heads = {"needs-lee": "Needs Lee", "safe": "Safe to ship", "code": "Code work", "hold": "On hold"}
    for b in ("needs-lee", "safe", "code", "hold"):
        found = [i for i in doc["items"] if i["bucket"] == b]
        lines += ["", "## %s (%d)" % (heads[b], len(found)), ""]
        for i in found:
            lines.append("- %s[%s] %s %s: %s (%s). Proposed: %s" % (
                "NEW " if i["new"] else "", i["severity"], i["kind"], i["path"], i["title"], i["why"], i["disposition"]))
        if not found:
            lines.append("- None.")
    if doc["coverage"]:
        lines += ["", "## Coverage gaps", ""] + ["- " + c for c in doc["coverage"]]
    lines += ["", "## Linear", "",
              "Writes: %s; %d linear-axi call(s) of %d%s." % (
                  doc["writes"], doc["linear_calls"], doc["linear_call_budget"],
                  "; stopped: " + doc["writes_blocked"] if doc["writes_blocked"] else "")]
    lines += ["- " + n for n in doc["not_filed"] + doc["linear_gaps"]]
    lines += ["- Start request: %s (%s, score %.1f)." % (r["title"], r["issue"], r["score"]) for r in doc["start_requests"]]
    lines += ["- " + a["line"] for a in doc["asks_for_lee"]]
    return "\n".join(lines) + "\n"


def run(args):
    now = args.now if args.now is not None else int(time.time())
    try:
        runs = sorted(n for n in os.listdir(args.audit) if RUN_RE.match(n) and os.path.isdir(os.path.join(args.audit, n)))
    except OSError:
        runs = []
    latest = runs[-1] if runs else None
    if latest:
        items, coverage, notes, unread = judge(os.path.join(args.audit, latest), latest, now)
    else:
        items, coverage, notes, unread = [], ["no audit run folder under %s" % args.audit], [], {"findings", "result"}
    os.makedirs(args.out, exist_ok=True)
    for i in items:
        i["new"] = False
    new = corpus.mark_new(args.out, args.date, [i for i in items if i["bucket"] in COUNTED], unread)
    lib = _lib()
    args.now = now
    lib.check_common_args(argparse.ArgumentParser(prog="fm-officer-library.py"), args)
    offices = lib.parse_start_homes(args.start_home)
    linear = linear_pass(args, latest, items, unread, offices, args.fm_home)
    doc = {"officer_role": "library", "source": "library-officer", "generated_at": lib.iso(now), "date": args.date, "run": latest, "actionable": new,
           "counts": {b: sum(1 for i in items if i["bucket"] == b) for b in COUNTED + ("hold",)},
           "items": items, "findings": [i for i in items if i["bucket"] in COUNTED],
           "coverage": coverage + linear["linear_gaps"], "notes": notes, **linear}
    if args.fm_home:
        lib.progress.write_handoff(os.path.join(args.out, args.date + ".start-requests.sh"),
                                   [r["execute"] for r in linear["start_requests"] if r["execute"]["env"]["FM_HOME"] == args.fm_home])
    corpus.write_if_changed(os.path.join(args.out, args.date + ".json"),
                            json.dumps(doc, sort_keys=True, indent=1, ensure_ascii=False) + "\n")
    corpus.write_if_changed(os.path.join(args.out, args.date + ".md"), render_md(doc))
    for c in coverage:
        print("Coverage gap: library: %s" % c)
    print("DIGEST %s %d %s.md" % (args.date, new, args.date))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-officer-library.py")
    parser.add_argument("action", choices=["run"])
    parser.add_argument("--audit", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--out", required=True)
    _lib().add_common_args(parser, RUBRIC_FILE)
    parser.set_defaults(max_creates=MAX_CREATES)
    args = parser.parse_args(argv)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}(T\d{2})?", args.date):
        parser.error("--date must be YYYY-MM-DD or YYYY-MM-DDTHH")
    args.audit = os.path.expanduser(args.audit)
    return run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
