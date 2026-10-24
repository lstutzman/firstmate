#!/usr/bin/env python3
"""fm-officer-triage.py - the triage officer's deterministic daily pass.

Run only through `bin/fm-officer.sh run <id>`, which owns the officer
contract (registry, write lane, schedule, report line); docs/configuration.md
"Officers" owns the registry schema.

Usage:
  fm-officer-triage.py scan --archive <dir> --date <YYYY-MM-DD>
  fm-officer-triage.py run --archive <dir|host:dir> --date <YYYY-MM-DD>
                           --out <lane-dir> [--home <dir>]... [--hosts a,b]
                           [--model none]

`scan` reads one day of the session archive (by-date/<date>/manifest.json,
each session's index.json and transcript.jsonl.gz) and prints one JSON
document of per-session facts on stdout. It reads only the archive and
writes nothing, so `run` can pipe this same file to `python3 -I - scan ...`
over `ssh -o BatchMode=yes <host>` when the archive lives on another host.

`run` scans (locally, or over ssh for a <host>:<dir> archive), joins each
worker session to its firstmate task and outcome through the read-only
records of every --home, and writes <date>.json and <date>.md into --out.
It prints `DIGEST <date> <n-actionable> <date>.md` as its last stdout line.
It fails, writing nothing, while the archive has no manifest for the day or
its harvester has not run since the day ended, so the officer retries the day.

Join order, recorded per session as join.via:
  launch-brief   the launch brief the worker read in its first tool result
                 names <home>/state/<task>.inbox or .status;
  worktree       the session cwd equals a task meta's worktree=;
  trace-context  a traceparent trace id seen in the transcript equals a task
                 meta's traceparent= trace id.
Outcome order: the home's fleet ledger, then its live state/<task>.status,
then data/<task>/report.md. A task whose home is not a readable --home is
`unresolved`, and counted under coverage.

A session no first-prompt class names is a `mate` when its cwd is a home
root: a --home, or a home a worker's launch brief named that day.

Determinism: output is a pure function of the archive and home records, with
sorted keys and no wall-clock stamps, so re-running a day rewrites identical
bytes. Findings carry normalised signatures only, never transcript text.

Model scoring is a later slice: score_sessions() is the seam, and slice 1
accepts only --model none.
"""

import argparse
import gzip
import json
import os
import re
import subprocess
import sys

SCORER = "deterministic-v1"

CLASSES = [
    ("worker", re.compile(r"^\W*Firstmate operational input waiting")),
    # The Slack desk's job prompt, built in fleet-app src/slack/desk/desk.cjs.
    ("desk", re.compile(r"^Slack message from .+ \(role [\w-]+\) in thread ")),
    ("no-mistakes", re.compile(r"^Workspace boundary")),
    ("classifier", re.compile(r"^You are an? [\w -]*classifier\b", re.I)),
    ("supervision-engine", re.compile(r"MAIN DIALOG MIRROR")),
    ("security-review", re.compile(
        r"^Review this change for security|^You previously flagged these candidate"
        r"|security reviewer|^You check security findings")),
    ("reviewer", re.compile(r"read-only reviewer|^You review ")),
    ("bug-triage", re.compile(r"^You triage .*bug reports")),
]

INBOX_RE = re.compile(r"(/[^\s'`\"]+?)/state/([A-Za-z0-9][A-Za-z0-9._-]*)\.inbox\b")
STATUS_RE = re.compile(r"(/[^\s'`\"]+?)/state/([A-Za-z0-9][A-Za-z0-9._-]*)\.status\b")
TRACE_RE = re.compile(r"\b00-([0-9a-f]{32})-[0-9a-f]{16}-[0-9a-f]{2}\b")

# Standing fleet rules a transcript can break visibly, checked per command
# segment of a Bash call. Each entry: rule id, severity, matcher.
SEGMENT_RULES = [
    ("rm-not-trash", "medium", re.compile(r"^(sudo\s+)?rm\s")),
    ("pkill-f", "medium", re.compile(r"^(sudo\s+)?(pkill\s+(-\w+\s+)*-f\b|killall\b)")),
    ("no-verify", "medium", re.compile(r"^git\b.*\s--no-verify\b")),
    ("bare-git-stash", "medium", re.compile(r"^git\s+stash(\s+pop)?\s*$")),
    ("env-dump", "high", re.compile(r"^(env|printenv)\s*$|^cat\s+(\S*/)?\.env\s*$")),
    ("startup-file-print", "medium", re.compile(
        r"^(cat|head|tail|less|more)\s+(\S*/)?\.(zshrc|bashrc|profile|zprofile|bash_profile|zshenv)\s*$")),
]
PR_CREATE_RE = re.compile(r"\b(gh|gh-axi)\s+pr\s+create\b")
PR_HEADINGS = ("Testing", "Risk", "How to revert")
SEGMENT_SPLIT = re.compile(r"\s*(?:&&|\|\||;|\||\n)\s*")
HEREDOC_RE = re.compile(r"(?<!<)<<(?!<)(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
QUOTED_RE = re.compile(r"'[^']*'|\"(?:\\.|[^\"\\])*\"")
NETWORKIDLE_RE = re.compile(
    r"wait_?until['\"]?\s*[:=]\s*\\?['\"]networkidle|--wait-until[=\s]+['\"]?networkidle"
    r"|wait_?for_?load_?state\(\s*\\?['\"]networkidle", re.I)
TOKEN_RE = re.compile(
    r"(?<![A-Za-z0-9_+/=.-])(?:(?:ghp_|gho_|ghs_|ghu_|github_pat_|sk-|xox[abprs]-|AKIA)[A-Za-z0-9_+/=.-]*"
    r"|(?=[A-Za-z_+/=.-]*\d)[A-Za-z0-9_+/=.-]{20,})(?![A-Za-z0-9_+/=.-])")
SLEEP_RE = re.compile(r"^sleep\s+\d")


def normalise(text, limit=100):
    """A signature safe to report: no paths, ids, numbers or quoted text."""
    lines = [l for l in (text or "").strip().splitlines()
             if l.strip() and not re.fullmatch(r"\s*Exit code \d+\s*", l)]
    first = lines[0] if lines else (text or "").strip()
    s = TOKEN_RE.sub("<token>", first)
    s = re.sub(r"\"[^\"]*\"|'[^']*'", "<str>", s)
    s = re.sub(r"(?:~|\.{0,2})?/[^\s:,)]+", "<path>", s)
    s = re.sub(r"\b[0-9a-f]{7,}\b", "<hex>", s)
    s = re.sub(r"\d+", "N", s)
    s = re.sub(r"\S+@\S+", "<email>", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s[:limit]


def command_head(segment):
    """The command word and its leading flags, never its arguments."""
    words = TOKEN_RE.sub("<token>", segment).split()
    head = []
    for word in words:
        if head and not word.startswith("-"):
            break
        head.append(word)
    return " ".join(head) + (" ..." if len(words) > len(head) else "")


def command_segments(command):
    """Shell command segments, skipping heredoc bodies and quoted text."""
    kept = []
    end = None
    for line in command.split("\n"):
        if end is not None:
            if (line.lstrip("\t") if end[0] else line) == end[1]:
                end = None
            continue
        kept.append(line)
        m = HEREDOC_RE.search(line)
        if m:
            end = (m.group(1) == "-", m.group(3))
    flat = QUOTED_RE.sub("''", "\n".join(kept))
    return [s for s in SEGMENT_SPLIT.split(flat.strip()) if s]


def classify(first_prompt):
    for name, pattern in CLASSES:
        if pattern.search(first_prompt or ""):
            return name
    return "other"


def result_text(block):
    content = block.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(c.get("text", "") for c in content if isinstance(c, dict))
    return ""


def error_category(text):
    low = text.lower()
    if ("hook" in low or "guard" in low or "BLOCKED" in text) \
            and ("error" in low or "block" in low or "deny" in low):
        return "hook-refusal"
    if "permission" in low and ("denied" in low or "not allowed" in low or "rejected" in low):
        return "permission-denied"
    if "timed out" in low or "timeout" in low:
        return "timeout"
    return "tool-error"


def analyse_transcript(path):
    """Tool-use facts from a Claude Code transcript; None if unreadable."""
    try:
        with gzip.open(path, "rt", encoding="utf-8", errors="replace") as fh:
            records = [json.loads(line) for line in fh if line.strip()]
    except (OSError, ValueError, EOFError):
        return None
    turns = 0
    calls = []      # (id, name, canonical input)
    results = {}    # tool_use_id -> (is_error, text)
    first_results = []
    traces = set()
    for rec in records:
        kind = rec.get("type")
        content = (rec.get("message") or {}).get("content")
        if kind == "assistant":
            turns += 1
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use":
                calls.append((block.get("id"), block.get("name") or "",
                              json.dumps(block.get("input") or {}, sort_keys=True)))
            elif block.get("type") == "tool_result":
                text = result_text(block)
                results[block.get("tool_use_id")] = (bool(block.get("is_error")), text)
                if len(first_results) < 3:
                    first_results.append(text)
                traces.update(TRACE_RE.findall(text))
    join = None
    ordered = sorted(first_results, key=lambda t: "FIRSTMATE_OP: v1 launch-brief" not in t)
    for text in ordered:
        m = INBOX_RE.search(text) or STATUS_RE.search(text)
        if m:
            join = {"home": m.group(1), "task": m.group(2), "via": "launch-brief"}
            break
    errors = {}
    wasted = {}
    violations = []
    refused = set()
    read_paths = {}
    previous = None

    def bump(table, key):
        table[key] = table.get(key, 0) + 1

    for call_id, name, canon in calls:
        args = json.loads(canon)
        is_error, text = results.get(call_id, (False, ""))
        if canon == previous:
            bump(wasted, "repeated-call")
        if (name, canon) in refused:
            bump(wasted, "retry-after-refusal")
        previous = canon
        blocked = False
        if is_error:
            category = error_category(text)
            bump(errors, category + ": " + normalise(text))
            if category == "hook-refusal":
                refused.add((name, canon))
                blocked = True
        found = []
        if name == "Read":
            key = (args.get("file_path"), args.get("offset"), args.get("limit"))
            if read_paths.get(key):
                bump(wasted, "re-read")
            read_paths[key] = True
        elif name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
            target = args.get("file_path") or args.get("notebook_path")
            for key in [k for k in read_paths if k[0] == target]:
                read_paths[key] = False
            body = json.dumps(args)
            if NETWORKIDLE_RE.search(body):
                found.append(("networkidle", "medium",
                              name + " content sets waitUntil networkidle"))
        elif name == "Bash":
            command = args.get("command") or ""
            segments = command_segments(command)
            for i, segment in enumerate(segments):
                if SLEEP_RE.match(segment) and (i + 1 < len(segments) or len(segments) == 1):
                    bump(wasted, "sleep-then-check")
                for rule, severity, pattern in SEGMENT_RULES:
                    if pattern.search(segment):
                        found.append((rule, severity, normalise(command_head(segment), 80)))
            if NETWORKIDLE_RE.search(command):
                found.append(("networkidle", "medium", "Bash command sets waitUntil networkidle"))
            if PR_CREATE_RE.search(command) and "--body " in command \
                    and "--body-file" not in command:
                missing = [h for h in PR_HEADINGS if h not in command]
                if missing:
                    found.append(("pr-body-headings", "medium",
                                  "PR body lacks " + ", ".join(missing)))
        for rule, severity, evidence in found:
            violations.append({"rule": rule, "severity": "low" if blocked else severity,
                               "blocked": blocked, "evidence": evidence})
    return {
        "turns": turns,
        "tool_calls": len(calls),
        "join": join,
        "traces": sorted(traces),
        "errors": errors,
        "wasted": wasted,
        "violations": sorted(violations, key=lambda v: (v["rule"], v["blocked"], v["evidence"])),
    }


def load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def harvester_last_run(archive):
    """The archive harvester's latest start time from runs.jsonl, or None."""
    runs = []
    try:
        with open(os.path.join(archive, "runs.jsonl"), encoding="utf-8") as fh:
            for line in fh:
                try:
                    runs.append(json.loads(line).get("started"))
                except ValueError:
                    continue
    except OSError:
        pass
    return max([r for r in runs if isinstance(r, str)], default=None)


def scan(archive, date):
    """Per-session facts for one archive day; reads only the archive."""
    manifest = load_json(os.path.join(archive, "by-date", date, "manifest.json"))
    out = {"date": date, "manifest": manifest is not None, "sessions": [],
           "task_records": [], "pipeline_runs": [], "not_collected": {},
           "harvester_last_run": harvester_last_run(archive)}
    if manifest is None:
        return out
    out["not_collected"] = manifest.get("not_collected") or {}
    for entry in manifest.get("sessions") or []:
        harness = entry.get("harness")
        machine = entry.get("machine")
        if harness == "firstmate":
            folder = entry.get("folder") or ""
            parts = folder.split("/")
            out["task_records"].append({
                "machine": machine, "home": parts[2] if len(parts) > 3 else None,
                "task": parts[-1] if parts else None,
                "report": any(f.endswith("/report.md") for f in entry.get("files") or [])})
            continue
        if harness == "no-mistakes":
            out["pipeline_runs"].append({
                "machine": machine, "branch": entry.get("branch"),
                "status": entry.get("status"), "pr_url": entry.get("pr_url")})
            continue
        folder = os.path.join(archive, entry.get("folder") or "")
        index = load_json(os.path.join(folder, "index.json")) or {}
        tokens = entry.get("tokens") or {}
        fact = {
            "session": "%s:%s" % (machine, entry.get("session_id") or entry.get("name")),
            "machine": machine,
            "harness": harness,
            "project": entry.get("project"),
            "cwd": entry.get("cwd"),
            "started": entry.get("started"),
            "duration_s": entry.get("duration_s"),
            "cost_usd": round(float(entry.get("cost_usd") or 0), 4),
            "tokens": sum(v for v in tokens.values() if isinstance(v, (int, float))),
            "pr_urls": sorted(entry.get("pr_urls") or []),
            "class": classify(index.get("first_prompt") or ""),
            "analysed": False,
        }
        transcript = os.path.join(folder, "transcript.jsonl.gz")
        if harness == "claude-code" and os.path.exists(transcript):
            facts = analyse_transcript(transcript)
            if facts is not None:
                fact.update(facts)
                fact["analysed"] = True
        out["sessions"].append(fact)
    out["sessions"].sort(key=lambda s: s["session"])
    out["task_records"].sort(key=lambda r: json.dumps(r, sort_keys=True))
    out["pipeline_runs"].sort(key=lambda r: json.dumps(r, sort_keys=True))
    return out


def remote_scan(host, archive, date):
    with open(os.path.abspath(__file__), "rb") as fh:
        program = fh.read()
    proc = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host,
         "python3 -I - scan --archive %s --date %s" % (shell_quote(archive), date)],
        input=program, capture_output=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError("archive host %s unreachable or scan failed (ssh exit %d)"
                           % (host, proc.returncode))
    return json.loads(proc.stdout.decode("utf-8"))


def shell_quote(text):
    return "'" + text.replace("'", "'\\''") + "'"


class Home:
    """Read-only view of one firstmate home's task records."""

    def __init__(self, path):
        self.path = path.rstrip("/")
        self.ledger = {}
        try:
            with open(os.path.join(self.path, "state", "fleet-ledger.jsonl"),
                      encoding="utf-8") as fh:
                for line in fh:
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(rec, dict) and isinstance(rec.get("task"), str):
                        self.ledger.setdefault(rec["task"], []).append(rec)
        except OSError:
            pass
        self.metas = {}
        state = os.path.join(self.path, "state")
        try:
            names = sorted(os.listdir(state))
        except OSError:
            names = []
        for name in names:
            if name.endswith(".meta") and not name.startswith("."):
                self.metas[name[:-5]] = read_meta(os.path.join(state, name))

    def outcome(self, task):
        events = self.ledger.get(task) or []
        names = [e.get("event") for e in events]
        if "task.merged" in names:
            return "merged", "ledger"
        states = [e.get("state") for e in events if e.get("event") == "task.status"]
        terminal = [s for s in states if s in ("done", "failed")]
        if "task.pr_ready" in names:
            return "pr-ready", "ledger"
        if terminal:
            return terminal[-1], "ledger"
        if "task.cleaned_up" in names:
            return "cleaned-up", "ledger"
        status = last_status_state(os.path.join(self.path, "state", task + ".status"))
        if status:
            return status, "status"
        if os.path.exists(os.path.join(self.path, "data", task, "report.md")):
            return "reported", "report"
        if states:
            return states[-1], "ledger"
        return "unknown", None


def read_meta(path):
    meta = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                key, sep, value = line.rstrip("\n").partition("=")
                if sep:
                    meta[key] = value
    except OSError:
        pass
    return meta


def last_status_state(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = [l.strip() for l in fh if l.strip()]
    except OSError:
        return None
    for line in reversed(lines):
        word = re.match(r"([a-z-]+)", line)
        if word and word.group(1) in ("done", "failed", "blocked", "needs-decision",
                                      "paused", "working"):
            return word.group(1)
    return None


def join_sessions(scanned, homes):
    by_path = {h.path: h for h in homes}
    by_worktree = {}
    by_trace = {}
    for home in homes:
        for task, meta in sorted(home.metas.items()):
            if meta.get("worktree"):
                by_worktree[meta["worktree"].rstrip("/")] = (home, task)
            m = TRACE_RE.search(meta.get("traceparent") or "")
            if m:
                by_trace[m.group(1)] = (home, task)
    for s in scanned["sessions"]:
        join = s.get("join")
        if not join and s.get("cwd") and s["cwd"].rstrip("/") in by_worktree:
            home, task = by_worktree[s["cwd"].rstrip("/")]
            join = {"home": home.path, "task": task, "via": "worktree"}
        if not join:
            for trace in s.get("traces") or []:
                if trace in by_trace:
                    home, task = by_trace[trace]
                    join = {"home": home.path, "task": task, "via": "trace-context"}
                    break
        if join:
            home = by_path.get(join["home"].rstrip("/"))
            if home is None:
                join["outcome"], join["outcome_source"] = "unresolved", "home not readable here"
            else:
                join["outcome"], join["outcome_source"] = home.outcome(join["task"])
                m = TRACE_RE.search((home.metas.get(join["task"]) or {}).get("traceparent") or "")
                if m:
                    join["trace_id"] = m.group(1)
        s["join"] = join
        s["scores"] = {}


def classify_mates(scanned, homes):
    roots = {h.path for h in homes}
    roots.update(s["join"]["home"].rstrip("/") for s in scanned["sessions"]
                 if s["class"] == "worker" and (s.get("join") or {}).get("via") == "launch-brief")
    for s in scanned["sessions"]:
        if s["class"] == "other" and (s.get("cwd") or "").rstrip("/") in roots:
            s["class"] = "mate"


def require_harvested(scanned):
    """Refuse a day the archive has not finished harvesting."""
    date = scanned["date"]
    if not scanned["manifest"]:
        raise RuntimeError("no archive manifest for %s" % date)
    last = scanned.get("harvester_last_run")
    if last is None or last[:10] <= date:
        raise RuntimeError("archive harvester has not run since %s ended" % date)


def score_sessions(sessions, model):
    """Slice-2 seam: attach model scores to sessions. Slice 1 scores nothing."""
    if model != "none":
        raise RuntimeError("model scoring is not available in slice 1 (model: %s)" % model)
    return sessions


def findings_for(scanned, expected_hosts):
    findings = []
    present = sorted({s["machine"] for s in scanned["sessions"] if s.get("machine")})
    for host in expected_hosts:
        if host not in present:
            findings.append({"kind": "coverage", "severity": "high",
                             "summary": "no archived sessions from expected host %s" % host})
    for host in sorted(scanned.get("not_collected") or {}):
        findings.append({"kind": "coverage", "severity": "medium",
                         "summary": "archive did not collect host %s" % host})
    rank = {"high": 0, "medium": 1, "low": 2}
    for s in scanned["sessions"]:
        grouped = {}
        for v in s.get("violations") or []:
            grouped.setdefault((v["rule"], v["blocked"]), []).append(v)
        for (rule, blocked), hits in sorted(grouped.items()):
            severity = min((v["severity"] for v in hits), key=rank.get)
            findings.append({"kind": "rule-violation", "severity": severity,
                             "session": s["session"], "rule": rule, "count": len(hits),
                             "summary": "%s%s: %d call(s), e.g. %s" % (
                                 rule, " (blocked by a guard)" if blocked else "",
                                 len(hits), hits[0]["evidence"])})
        join = s.get("join") or {}
        if join.get("outcome") == "failed":
            findings.append({"kind": "outcome", "severity": "medium",
                             "session": s["session"], "task": join.get("task"),
                             "summary": "worker task %s ended failed" % join.get("task")})
    spread = {}
    for s in scanned["sessions"]:
        for sig in s.get("errors") or {}:
            spread.setdefault(sig, set()).add(s["session"])
    for sig, sessions in sorted(spread.items()):
        if len(sessions) >= 3:
            findings.append({"kind": "error-signature", "severity": "low",
                             "sessions": len(sessions), "summary": sig})
    findings.sort(key=lambda f: (rank[f["severity"]], f["kind"], f["summary"],
                                 f.get("session") or ""))
    return findings


def summarise(scanned, homes, expected_hosts, model):
    sessions = scanned["sessions"]
    mix = {}
    for s in sessions:
        mix[s["class"]] = mix.get(s["class"], 0) + 1
    workers = [s for s in sessions if s["class"] == "worker"]
    outcomes = {}
    via = {}
    for s in workers:
        join = s.get("join") or {}
        outcomes[join.get("outcome", "not-joined")] = outcomes.get(join.get("outcome", "not-joined"), 0) + 1
        via[join.get("via", "none")] = via.get(join.get("via", "none"), 0) + 1
    wasted = {}
    errors = {}
    for s in sessions:
        for k, n in (s.get("wasted") or {}).items():
            wasted[k] = wasted.get(k, 0) + n
        for k, n in (s.get("errors") or {}).items():
            errors[k] = errors.get(k, 0) + n
    top_errors = sorted(errors.items(), key=lambda kv: (-kv[1], kv[0]))[:10]
    findings = findings_for(scanned, expected_hosts)
    return {
        "officer_role": "triage",
        "scorer": SCORER,
        "model": model,
        "date": scanned["date"],
        "coverage": {
            "hosts_expected": expected_hosts,
            "hosts_present": sorted({s["machine"] for s in sessions if s.get("machine")}),
            "harvester_last_run": scanned.get("harvester_last_run"),
            "not_collected": scanned.get("not_collected") or {},
            "sessions": len(sessions),
            "sessions_analysed": sum(1 for s in sessions if s.get("analysed")),
            "homes_read": sorted(h.path for h in homes),
            "workers_unresolved": outcomes.get("unresolved", 0),
        },
        "session_mix": dict(sorted(mix.items())),
        "workers": {"count": len(workers), "outcomes": dict(sorted(outcomes.items())),
                    "join_via": dict(sorted(via.items())),
                    "cost_usd": round(sum(s["cost_usd"] for s in workers), 2)},
        "wasted_turns": dict(sorted(wasted.items())),
        "top_errors": [{"signature": k, "count": n} for k, n in top_errors],
        "task_records": scanned.get("task_records") or [],
        "pipeline_runs": scanned.get("pipeline_runs") or [],
        "findings": findings,
        "actionable": sum(1 for f in findings if f["severity"] in ("high", "medium")),
        "sessions": sessions,
    }


def render_md(doc):
    lines = ["# Triage officer digest for %s" % doc["date"], ""]
    cov = doc["coverage"]
    lines.append("%d actionable finding(s); scorer %s." % (doc["actionable"], doc["scorer"]))
    lines += ["", "## Coverage", ""]
    lines.append("- Hosts present: %s (expected: %s)." % (
        ", ".join(cov["hosts_present"]) or "none", ", ".join(cov["hosts_expected"]) or "not set"))
    lines.append("- Sessions: %d, of which %d analysed." % (cov["sessions"], cov["sessions_analysed"]))
    lines.append("- Archive harvester last ran: %s." % (cov["harvester_last_run"] or "never"))
    lines.append("- Worker sessions whose home is not readable here: %d." % cov["workers_unresolved"])
    lines.append("- Desk sessions are not archived: the Slack desk runs with"
                 " --no-session-persistence, so 0 desk sessions is expected.")
    lines += ["", "## Session mix", ""]
    for k, n in doc["session_mix"].items():
        lines.append("- %s: %d" % (k, n))
    w = doc["workers"]
    lines += ["", "## Worker outcomes", ""]
    lines.append("- %d worker session(s), $%.2f." % (w["count"], w["cost_usd"]))
    for k, n in w["outcomes"].items():
        lines.append("- %s: %d" % (k, n))
    lines.append("- Joined via: %s." % ", ".join("%s %d" % kv for kv in w["join_via"].items()))
    lines += ["", "## Wasted-turn patterns", ""]
    for k, n in doc["wasted_turns"].items():
        lines.append("- %s: %d" % (k, n))
    lines += ["", "## Top error signatures", ""]
    for e in doc["top_errors"]:
        lines.append("- %d x `%s`" % (e["count"], e["signature"].replace("`", "'")))
    lines += ["", "## Findings", ""]
    for f in doc["findings"]:
        where = " (%s)" % f["session"] if f.get("session") else ""
        lines.append("- [%s] %s: %s%s" % (f["severity"], f["kind"],
                                          f["summary"].replace("`", "'"), where))
    if not doc["findings"]:
        lines.append("- None.")
    return "\n".join(lines) + "\n"


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


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-officer-triage.py")
    parser.add_argument("action", choices=["scan", "run"])
    parser.add_argument("--archive", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--out")
    parser.add_argument("--home", action="append", default=[])
    parser.add_argument("--hosts", default="")
    parser.add_argument("--model", default="none")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.date):
        parser.error("--date must be YYYY-MM-DD")
    if args.action == "scan":
        json.dump(scan(args.archive, args.date), sys.stdout, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    if not args.out:
        parser.error("run needs --out")
    remote = re.match(r"^([A-Za-z0-9][A-Za-z0-9._@-]*):(/.*)$", args.archive)
    try:
        if remote:
            scanned = remote_scan(remote.group(1), remote.group(2), args.date)
        else:
            scanned = scan(args.archive, args.date)
        require_harvested(scanned)
        homes = [Home(h) for h in args.home]
        join_sessions(scanned, homes)
        classify_mates(scanned, homes)
        score_sessions(scanned["sessions"], args.model)
    except (RuntimeError, ValueError) as exc:
        print("fm-officer-triage: %s" % exc, file=sys.stderr)
        return 1
    hosts = [h for h in (x.strip() for x in args.hosts.split(",")) if h]
    doc = summarise(scanned, homes, hosts, args.model)
    write_if_changed(os.path.join(args.out, args.date + ".json"),
                     json.dumps(doc, sort_keys=True, indent=1, ensure_ascii=False) + "\n")
    write_if_changed(os.path.join(args.out, args.date + ".md"), render_md(doc))
    print("DIGEST %s %d %s.md" % (args.date, doc["actionable"], args.date))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
