#!/usr/bin/env python3
"""Deterministic progress officer. Run through fm-officer.sh.

Usage: fm-officer-progress.py run --date YYYY-MM-DD --out <lane>
         --home <dir|host:/dir> [--home ...] [--team PC]
         [--repos owner/repo,...] [--requested PC-1,...] [--now <epoch>]
       fm-officer-progress.py scan --home <dir>

Reads backlog rows and task status without changing them. Only this officer's
lane receives dated JSON, Markdown, and the latest progress-state.json.
The registry and state schema are documented in docs/configuration.md.
No model calls, dispatch, steering, Linear writes, or GitHub writes.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
import urllib.parse

LINEAR_ID = re.compile(r"\b[A-Z][A-Z0-9]*-\d+\b")
ROW = re.compile(r"^- \[([ xX])\] ([\w.-]+)\s*(?: - |: )(.+)$")
TAG = re.compile(r"\(([^():]+):\s*([^()]*)\)")
CLASS_ORDER = {"security": 0, "cve": 0, "code-review": 1, "bug": 1,
               "requested-feature": 2, "requested-fleet": 2}
CHOICES = re.compile(r"\b(business|product|wording|legal|payments?|billing|pricing)\b", re.I)
RESTRICTED = re.compile(r"\b(merg(?:e|ing)|production|credentials?|rotat(?:e|ing|ion)|data[- ]rewrit\w*"
                        r"|destructive|delet(?:e|ing|ion)|drop(?:ping)?|force[- ]push|spend(?:ing)?|purchas\w*)\b", re.I)
UNSTARTED = {"backlog", "todo", "to do", "queued", "unstarted"}
FINISHED = {"done", "completed", "canceled", "cancelled", "duplicate"}
EVENT = re.compile(r"^([a-z-]+)\b([^:]*):\s*(.*)$")
KEY = re.compile(r"\bkey=([^\]\s]+)")


def read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""


def item(identifier, title, home, text, tags=None):
    tags = tags or {}
    ids = sorted(set(LINEAR_ID.findall(text)))
    return {"id": identifier, "title": title, "owner_home": home,
            "linear_id": ids[0] if len(ids) == 1 else None,
            "linear_ids": ids, "authorising_class": None, "reason": "",
            "evidence": [], "priority": 0, "rank": None, "execute": None, "tags": tags}


def scan_home(home):
    rows = []
    section = ""
    for line in read(os.path.join(home, "data", "backlog.md")).splitlines():
        if line.startswith("## "):
            section = line[3:].strip().lower()
        match = ROW.match(line)
        if not match or section not in ("queued", "in flight", "done"):
            continue
        tags = {m[1].strip(): m[2].strip() for m in TAG.finditer(match[3])}
        row = item(match[2], TAG.sub("", match[3]).strip(), home, match[3], tags)
        row["section"] = "done" if match[1].lower() == "x" else section
        row["evidence"] = [home + "/data/backlog.md: " + row["id"]]
        row["project"] = tags.get("repo", "")
        row["link"] = tags.get("pr", "")
        if tags.get("hold-kind") == "captain" and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", row["id"]):
            row["captains_log_key"] = row["id"]
        severity = tags.get("severity", tags.get("priority", "")).lower()
        row["priority"] = {"critical": 1, "urgent": 1, "high": 2, "medium": 3, "low": 4,
                           "1": 1, "2": 2, "3": 3, "4": 4}.get(severity, 0)
        rows.append(row)
    by_id = {r["id"]: r for r in rows}
    state = os.path.join(home, "state")
    names = sorted(os.listdir(state))
    for name in names:
        if not name.endswith((".meta", ".status")) or name.startswith("."):
            continue
        identifier = name.rsplit(".", 1)[0]
        row = by_id.get(identifier)
        meta_path = os.path.join(state, identifier + ".meta")
        meta = {}
        for line in read(meta_path).splitlines():
            key, sep, value = line.partition("=")
            if sep:
                meta[key] = value
        if row is None and meta and meta.get("kind") not in ("secondmate", "officer"):
            row = item(identifier, meta.get("title") or identifier, home,
                       " ".join(meta.values()))
            row["section"] = "in flight"
            row["evidence"] = [meta_path]
            rows.append(row)
            by_id[identifier] = row
        if row is None:
            continue
        row["has_meta"] = bool(meta)
        row["project"] = meta.get("repo") or row.get("project", "")
        row["link"] = meta.get("pr") or row.get("link", "")
        status = read(os.path.join(state, identifier + ".status"))
        opened = {}
        latest = None
        for line in status.splitlines():
            match = EVENT.match(line)
            if not match:
                continue
            verb = match[1]
            key = KEY.search(match[2]) or re.match(r"\[key=([^\]\s]+)\]", match[3])
            key = key[1] if key else "unkeyed"
            if verb in ("needs-decision", "blocked"):
                opened[key] = verb
            elif verb == "resolved":
                opened.pop(key, None)
            if verb in ("working", "paused", "done", "failed", "blocked", "needs-decision"):
                latest = verb
        row["open_calls"] = sorted(opened.values())
        row["latest"] = latest
        row["linear_ids"] = sorted(set(row["linear_ids"] + LINEAR_ID.findall(status)
                                        + LINEAR_ID.findall(" ".join(meta.values()))))
        row["linear_id"] = row["linear_ids"][0] if len(row["linear_ids"]) == 1 else None
    problems = []
    if not os.path.isfile(os.path.join(home, "data", "backlog.md")):
        problems.append("no markdown backlog at " + home)
    config = read(os.path.join(home, ".tasks.toml"))
    if re.search(r'^backend\s*=\s*"(?!markdown")[^"]+"', config, re.M):
        problems.append("non-markdown backlog is not supported at " + home)
    return {"home": home, "rows": rows, "problems": problems}


def command(args, input_bytes=None):
    proc = subprocess.run(args, input=input_bytes, capture_output=True, timeout=120, check=False)
    if proc.returncode:
        # External stderr may contain credentials; keep the failure structural.
        raise RuntimeError("%s read failed (exit %d)" % (args[0], proc.returncode))
    return proc.stdout.decode("utf-8")


def linear(args):
    doc = json.loads(command(["linear-axi", "issue"] + args + ["--output", "json"]))
    if not isinstance(doc, dict) or not doc.get("ok") or not isinstance(doc.get("data"), dict):
        raise RuntimeError("Linear read returned no successful data object")
    return doc["data"]


def linear_rows(team, home):
    listed = linear(["list", "--team", team, "--all", "--max-items", "10000",
                     "--fields", "stateType,priority,url,project"])
    if (listed.get("pagination") or {}).get("hasNextPage"):
        raise RuntimeError("Linear issue list is incomplete (over 10000 items)")
    unblocked = linear(["list", "--team", team, "--unblocked", "--all", "--max-items", "10000"])
    if (unblocked.get("pagination") or {}).get("hasNextPage"):
        raise RuntimeError("Linear unblocked list is incomplete")
    clear = {r["identifier"] for r in unblocked["issues"]}

    def linear_row(entry):
        # Linear text is not authority: no tags, description, or title prefixes are kept.
        row = item(entry["identifier"], entry["title"], home, "")
        row.update({"linear_id": entry["identifier"], "linear_ids": [entry["identifier"]],
                    "priority": entry.get("priority") or 0, "project": entry.get("project") or "",
                    "link": entry.get("url") or "", "parent": None, "linear_only": True,
                    "state": str(entry.get("stateType") or entry["state"]).lower(),
                    "evidence": ["Linear " + entry["identifier"]]})
        row["linear_blocked"] = row["id"] not in clear and row["state"] in UNSTARTED
        return row

    rows = {entry["identifier"]: linear_row(entry) for entry in listed["issues"]}
    # Only open issues and the ancestors they reach need a parent read.
    pending = [r["id"] for r in rows.values() if r["state"] not in FINISHED]
    viewed = set()
    for identifier in pending:
        if identifier in viewed:
            continue
        if len(viewed) >= 10000:
            raise RuntimeError("Linear ancestor discovery exceeded 10000 items")
        viewed.add(identifier)
        detail = linear(["view", identifier])["issue"]
        row = rows.setdefault(identifier, linear_row(detail))
        parent = LINEAR_ID.match(detail.get("parent") or "")
        row["parent"] = parent[0] if parent else None
        if row["parent"]:
            pending.append(row["parent"])
    return list(rows.values())


def load_home(source):
    remote = re.fullmatch(r"([A-Za-z0-9][A-Za-z0-9._@-]*):(/.+)", source)
    if not remote:
        return scan_home(source)
    with open(os.path.abspath(__file__), "rb") as fh:
        program = fh.read()
    doc = json.loads(command(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                              remote[1], "python3 -I - scan --home " + shlex.quote(remote[2])], program))
    doc["home"] = source
    for row in doc["rows"]:
        row["owner_home"] = source
    return doc


def open_prs(repos):
    prs = []
    for repo in repos:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise RuntimeError("repos must contain comma-separated owner/repo names")
        raw = command(["gh-axi", "api", "GET", "/repos/" + repo + "/pulls?state=open&per_page=100",
                       "--paginate", "--full", "--jq", '.[] | "PRJSON " + tojson'])
        for line in raw.splitlines():
            if not line.startswith("PRJSON "):
                raise RuntimeError("GitHub read returned an unexpected PR format")
            prs.append(json.loads(line[7:]))
    return prs


def classify(row):
    if row.get("linear_only"):
        return None
    kind = row["tags"].get("kind", "").lower()
    text = row["title"].lower()
    if kind in ("security", "cve", "code-review", "bug"):
        return kind
    if re.search(r"\bcve-\d{4}-\d+\b", text):
        return "cve"
    if re.match(r"security\b", text):
        return "security"
    if re.match(r"code[- ]review (?:finding|fix)\b", text):
        return "code-review"
    if re.match(r"bug(?: report)?\b", text):
        return "bug"
    if kind in ("feature", "fleet") and row["tags"].get("requested-by", "").lower() == "lee":
        return "requested-" + kind
    return None


def judge(snapshots, issues, requested, prs, problems, team):
    doc = {"schema_version": 1, "source": "progress-officer", "doing": [], "done": [],
           "start_requests": [], "asks_for_lee": [], "excluded": [], "unclassified": 0,
           "filler": None, "coverage": problems}
    team_id = re.compile(r"\b%s-\d+\b" % re.escape(team))
    rows = [row for snapshot in snapshots for row in snapshot["rows"]]
    linked = {}
    for row in rows:
        row["linear_ids"] = [i for i in row["linear_ids"] if team_id.fullmatch(i)]
        row["linear_id"] = row["linear_ids"][0] if len(row["linear_ids"]) == 1 else None
        for identifier in row["linear_ids"]:
            linked.setdefault(identifier, []).append(row)
            if row["tags"].get("requested-by", "").lower() == "lee":
                requested.add(identifier)
    by_linear = {r["linear_id"]: r for r in issues}
    for row in issues:
        copies = linked.get(row["linear_id"], [])
        if copies:
            # Local task records determine home and status; Linear supplies class,
            # parentage, and severity. Multiple homes are reconciled below.
            for copy in copies:
                copy.update({k: v for k, v in row.items() if k in ("state", "parent", "priority", "linear_blocked")})
                copy["evidence"] += row["evidence"]
                copy["link"] = copy.get("link") or row["link"]
            by_linear[row["linear_id"]] = copies[0]
        elif row["state"] not in FINISHED:
            rows.append(row)
    pr_ids = set()
    pr_branches = set()
    for pr in prs:
        pr_ids.update(team_id.findall((pr.get("title") or "") + "\n" + (pr.get("body") or "")))
        if (pr.get("head") or {}).get("ref"):
            pr_branches.add(pr["head"]["ref"])
    # Evaluate ancestors iteratively: completed parents still carry the original
    # request; a held parent stops inheritance.
    def ancestry(row):
        chain, seen = [], set()
        while row and row["id"] not in seen:
            chain.append(row)
            seen.add(row["id"])
            row = by_linear.get(row.get("parent"))
        return chain

    for row in rows:
        chain = ancestry(row)
        authorised = classify(row)
        root = next((r for r in chain if r.get("linear_id") in requested), None)
        if root and not authorised:
            authorised = "requested-feature"
            row["evidence"].append("Lee-requested root " + root["linear_id"])
            row["owner_home"] = root["owner_home"]
        row["authorising_class"] = authorised
        choice = CHOICES.search(row["title"])
        restricted = RESTRICTED.search(row["title"])
        held = any(any(k in r["tags"] for k in ("hold", "hold-kind", "blocked-by", "blocked", "deps"))
                   or r.get("open_calls") or r.get("linear_blocked") for r in chain)
        copies = [copy for ident in row["linear_ids"] for copy in linked.get(ident, [])]
        other_busy = any(r is not row and (r["section"] in ("in flight", "done") or r.get("has_meta")
                         or r.get("open_calls") or any(k in r["tags"] for k in ("hold", "hold-kind", "blocked-by")))
                         for r in copies)
        state = row.get("state", "")
        finished = row.get("section") == "done" or state in FINISHED or row.get("latest") in ("done", "failed")
        if not authorised and not choice and not row.get("captains_log_key"):
            doc["unclassified"] += not finished
        elif held:
            row["reason"] = "Already held, blocked, or carded; firstmate must reconcile it"
            doc["excluded"].append(row)
        elif row.get("section") == "in flight" or row.get("has_meta") or state == "started" or row.get("latest") in ("working", "paused"):
            row["reason"] = "Already in flight"
            doc["doing"].append(row)
        elif row.get("section") == "done" or state in FINISHED:
            row["reason"] = "Recorded completed or canceled"
            row["outcome"] = "skipped" if state in ("canceled", "cancelled", "duplicate") else "ok"
            doc["done"].append(row)
        elif (other_busy or pr_ids.intersection(row["linear_ids"])
              or any(branch == row["id"] or branch.endswith("/" + row["id"]) for branch in pr_branches)):
            row["reason"] = "Already held, blocked, carded, in flight, or covered by an open PR"
            doc["excluded"].append(row)
        elif row.get("latest") in ("done", "failed"):
            row["reason"] = "Recorded worker outcome; firstmate owns landing or retry"
            row["outcome"] = "failed" if row["latest"] == "failed" else "ok"
            doc["done"].append(row)
        elif choice or restricted:
            row["reason"] = ("Lee decides the " + choice[1].lower() + " choice" if choice
                             else "Outside automatic-start authority: " + restricted[1].lower())
            doc["asks_for_lee"].append(row)
        elif state and state not in UNSTARTED:
            row["reason"] = "Linear state is not unstarted: " + state
            doc["excluded"].append(row)
        elif row["linear_ids"] and not any(i in by_linear for i in row["linear_ids"]):
            row["reason"] = "Linked Linear item was not found; firstmate must reconcile it"
            doc["excluded"].append(row)
        else:
            row["reason"] = "Unstarted work authorised by " + row["authorising_class"]
            doc["start_requests"].append(row)
    doc["start_requests"].sort(key=lambda r: (CLASS_ORDER[r["authorising_class"]],
                                             r["priority"] or 5, r["id"], r["owner_home"]))
    seen = set()
    unique = []
    for row in doc["start_requests"]:
        key = row["linear_id"] or (row["owner_home"], row["id"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(row)
    doc["start_requests"] = unique
    if problems:
        for row in doc["start_requests"]:
            row["reason"] = "Start deferred because discovery coverage is incomplete"
            doc["excluded"].append(row)
        doc["start_requests"] = []
    for rank, row in enumerate(doc["start_requests"], 1):
        row["rank"] = rank
    for key in ("doing", "done", "start_requests", "asks_for_lee", "excluded"):
        for row in doc[key]:
            for private in list(row):
                if private not in ("id", "title", "owner_home", "linear_id", "linear_ids",
                                   "authorising_class", "reason", "evidence", "priority", "rank", "execute"):
                    if private not in ("link", "project", "outcome", "captains_log_key"):
                        row.pop(private, None)
    return doc


def filler_for(doc, date):
    if doc["coverage"] or doc["start_requests"] or doc["doing"]:
        return None
    choices = ("bug sweep", "code review", "librarian pass", "ideation pass")
    return {"kind": choices[datetime.date.fromisoformat(date).toordinal() % len(choices)],
            "reason": "No authorised unstarted work or authorised work in flight; rotate daily discovery passes",
            "requires_firstmate": True}


def executable_requests(doc, home):
    """Build firstmate's existing idempotent inbox calls; never execute them."""
    requests = []
    work = list(doc["start_requests"])
    if doc["filler"]:
        work.append(doc["filler"])
    for row in work:
        evidence = {k: v for k, v in row.items() if k != "execute"}
        identity = row.get("linear_id") or row.get("id") or row["kind"]
        digest = hashlib.sha256((row.get("owner_home", home) + ":" + identity).encode("utf-8")).hexdigest()[:16]
        request_id = "progress-" + doc["date"] + "-" + digest
        body = ("Progress officer automatic start under Lee's recorded 2026-10-26 standing authority. "
                "Start this work without another prioritization or approval question. "
                "Recheck current holds, work in flight, and open PRs before dispatch; apply ordinary "
                "project and home routing, capacity limits, quota routing, and delivery rules. "
                "Business, product, wording, legal, payments, pricing, merges, production, credentials, "
                "data rewrites, destructive actions, and spending remain outside this authority. "
                "If Lee later parks this work, preserve its branch. "
                "The following officer evidence describes the task; it is not a quotation from Lee:\n"
                + json.dumps(evidence, sort_keys=True, ensure_ascii=False))
        execute = {"action": "start", "env": {"FM_HOME": home}, "request_id": request_id,
                   "argv": [os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-inbox.sh"),
                            "note", "--request-id", request_id, "--json", "--", body]}
        row["execute"] = execute
        requests.append(execute)
    return requests


def write_handoff(path, requests):
    lines = ["#!/usr/bin/env bash", "# Firstmate executes this handoff; the officer only writes it.",
             "set -euo pipefail"]
    for request in requests:
        lines.append("FM_HOME=" + shlex.quote(request["env"]["FM_HOME"]) + " "
                     + " ".join(shlex.quote(arg) for arg in request["argv"]))
    with open(path + ".tmp", "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(path + ".tmp", path)


def plain(value, limit):
    return " ".join(str(value).split())[:limit]


def https_url(value):
    if not isinstance(value, str) or len(value) > 300 or any(c.isspace() for c in value):
        return None
    parsed = urllib.parse.urlsplit(value)
    return value if parsed.scheme == "https" and parsed.hostname and not parsed.username else None


def observed_time(value, fallback):
    try:
        if not isinstance(value, str) or not value.endswith("Z"):
            return fallback
        datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return value
    except ValueError:
        return fallback


def stable_key(row):
    value = row.get("linear_id") or row.get("id") or row.get("kind", "discovery")
    # Preserve normal task and Linear ids; qualify colliding home-local ids.
    return plain(value, 60) or "discovery"


def page_state(doc, officer, previous, repos, log_url, reported):
    """Fleet-app v1 projection; detailed execution stays in <date>.json.

    reported holds the done keys of the previous dated run, or None on a first run;
    outcomes already reported there and no longer on the page are not re-added."""
    now = doc["generated_at"]
    default_link = "https://github.com/" + repos.split(",")[0].strip()
    previous = previous if isinstance(previous, dict) and previous.get("officer") == officer else {}
    old_doing = {r["id"]: r for r in previous.get("doing", []) or [] if isinstance(r, dict) and isinstance(r.get("id"), str)}
    old_done = {r["id"]: r for r in previous.get("done", []) or [] if isinstance(r, dict) and isinstance(r.get("id"), str)}
    old_asking = {r["key"]: r for r in previous.get("asking", []) or [] if isinstance(r, dict) and isinstance(r.get("key"), str)}
    page = {"schema_version": 1, "officer": officer, "written_at": now,
            "stale_after_minutes": 2880, "doing": [], "done": [], "asking": []}
    used = {"doing": set(), "done": set(), "asking": set()}
    sources = {"security": "cve", "cve": "cve", "code-review": "review", "bug": "bug",
               "requested-feature": "feature", "requested-fleet": "fleet", "filler": "filler"}

    def unique(key, group, row):
        if key in used[group]:
            key += "-" + hashlib.sha256(row.get("owner_home", "").encode()).hexdigest()[:12]
        used[group].add(key)
        return key

    def instruction(row, question):
        key = unique(stable_key(row), "asking", row)
        return {"key": key, "kind": "instruction", "question": plain(question, 300),
                "waiting_on": "firstmate", "link": https_url(row.get("link")) or default_link,
                "asked_at": observed_time(old_asking.get(key, {}).get("asked_at"), now)}

    for row in doc["doing"][:30]:
        key = unique(stable_key(row), "doing", row)
        entry = {"id": key, "description": plain("Watching work: " + row["title"], 200),
                 "started_at": observed_time(old_doing.get(key, {}).get("started_at"), now)}
        if sources.get(row["authorising_class"]):
            entry["source"] = sources[row["authorising_class"]]
        link = https_url(row.get("link"))
        if link:
            entry["link"] = link
        elif row.get("project"):
            entry["project"] = plain(row["project"], 60)
        page["doing"].append(entry)
    for row in doc["done"]:
        if reported is not None and stable_key(row) in reported and stable_key(row) not in old_done:
            continue
        key = unique(stable_key(row), "done", row)
        entry = {"id": key, "description": plain("Recorded work outcome: " + row["title"], 200),
                 "at": observed_time(old_done.get(key, {}).get("at"), now), "outcome": row.get("outcome", "ok"),
                 "detail": plain(row["reason"], 300)}
        if sources.get(row["authorising_class"]):
            entry["source"] = sources[row["authorising_class"]]
        if https_url(row.get("link")):
            entry["link"] = row["link"]
        page["done"].append(entry)
    page["done"].sort(key=lambda r: (r["at"], r["id"]), reverse=True)
    page["done"] = page["done"][:50]
    for row in doc["start_requests"]:
        page["asking"].append(instruction(row, "Start authorised work: " + row["title"]))
    if doc["filler"]:
        page["asking"].append(instruction(doc["filler"], "Start an extra " + doc["filler"]["kind"]))
    for row in doc["asks_for_lee"]:
        page["asking"].append(instruction(row, "File a Captain's Log card: " + row["title"] + "; " + row["reason"]))
    log_base = https_url(log_url)
    if log_base:
        log_base = log_base.removesuffix("/api/captains-log").rstrip("/") + "/captains-log"
        for row in doc["excluded"]:
            key = row.get("captains_log_key")
            if key and key not in used["asking"]:
                used["asking"].add(key)
                page["asking"].append({"key": key, "kind": "captains_log", "link": log_base + "#" + key})
    for n, problem in enumerate(doc["coverage"]):
        page["asking"].append(instruction({"id": "coverage-" + str(n)}, "Restore discovery coverage: " + problem))
    total_asks = len(page["asking"])
    page["asking"] = page["asking"][:30]
    page["summary"] = plain("Watching %d work items; %d outcomes recorded; %d requests waiting on firstmate or Lee; "
                            "%d items outside the start classes; %d coverage gaps. "
                            "Showing up to 30 current items, 50 outcomes, and 30 requests."
                            % (len(doc["doing"]), len(doc["done"]), total_asks, doc["unclassified"],
                               len(doc["coverage"])), 300)
    return page


def render_md(doc):
    lines = ["# Progress officer digest for " + doc["date"], ""]
    for key, title in (("start_requests", "Ranked start requests"), ("doing", "Doing"),
                       ("done", "Done"), ("asks_for_lee", "Ask Lee"), ("excluded", "Excluded")):
        lines.extend(["## " + title, ""])
        for row in doc[key]:
            lines.append("- %s%s - %s (Linear: %s; home: %s; class: %s): %s" % (
                str(row["rank"]) + ". " if row["rank"] is not None else "", row["id"], row["title"],
                row["linear_id"] or "none", row["owner_home"],
                row["authorising_class"] or "unclassified", row["reason"]))
        if not doc[key]:
            lines.append("- None.")
        lines.append("")
    if doc["filler"]:
        lines.extend(["## Filler proposal", "", "- " + doc["filler"]["kind"] + ": " + doc["filler"]["reason"], ""])
    lines.extend(["## Unclassified", "", "- %d open items have no recorded start class and are not listed."
                  % doc["unclassified"], ""])
    lines.extend(["## Coverage", ""] + ["- " + p for p in doc["coverage"]])
    if not doc["coverage"]:
        lines.append("- All configured sources read.")
    return "\n".join(lines) + "\n"


def write(path, value):
    text = json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
    if read(path) == text:
        return
    with open(path + ".tmp", "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(path + ".tmp", path)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["run", "scan"])
    parser.add_argument("--home", action="append", default=[])
    parser.add_argument("--out")
    parser.add_argument("--date")
    parser.add_argument("--team", default="PC")
    parser.add_argument("--repos", default="")
    parser.add_argument("--requested", default="")
    parser.add_argument("--officer", default="progress")
    parser.add_argument("--captains-log", default="")
    parser.add_argument("--now", type=int, default=None)
    args = parser.parse_args(argv)
    if args.action == "scan":
        print(json.dumps(scan_home(args.home[0]), sort_keys=True))
        return 0
    if not args.home or not args.out or not args.date:
        parser.error("run requires --home, --out, and --date")
    datetime.date.fromisoformat(args.date)
    snapshots, issues, prs, problems = [], [], [], []
    for home in args.home:
        try:
            snapshot = load_home(home)
            snapshots.append(snapshot)
            problems.extend(snapshot["problems"])
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
            problems.append("home records unavailable: " + home)
    try:
        issues = linear_rows(args.team, args.home[0])
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired):
        problems.append("Linear discovery unavailable or incomplete")
    try:
        prs = open_prs([r.strip() for r in args.repos.split(",") if r.strip()])
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
        problems.append("open PR discovery unavailable or incomplete")
    doc = judge(snapshots, issues, set(filter(None, args.requested.split(","))), prs, problems, args.team)
    doc["date"] = args.date
    doc["filler"] = filler_for(doc, args.date)
    doc["generated_at"] = datetime.datetime.fromtimestamp(
        args.now if args.now is not None else time.time(), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    requests = executable_requests(doc, args.home[0])
    write_handoff(os.path.join(args.out, args.date + ".start-requests.sh"), requests)
    reported = None
    runs = sorted(n for n in os.listdir(args.out) if re.fullmatch(r"\d{4}-\d{2}-\d{2}\.json", n))
    if runs:
        try:
            reported = {stable_key(r) for r in json.loads(read(os.path.join(args.out, runs[-1])))["done"]}
        except (ValueError, KeyError, TypeError, AttributeError):
            reported = None
    write(os.path.join(args.out, args.date + ".json"), doc)
    page_path = os.path.join(args.out, "progress-state.json")
    try:
        previous = json.loads(read(page_path))
    except ValueError:
        previous = {}
    write(page_path, page_state(doc, args.officer, previous, args.repos, args.captains_log, reported))
    with open(os.path.join(args.out, args.date + ".md"), "w", encoding="utf-8") as fh:
        fh.write(render_md(doc))
    print("DIGEST %s %d %s.md" % (
        args.date, len(doc["start_requests"]) + len(doc["asks_for_lee"]) + len(doc["coverage"])
        + int(doc["filler"] is not None), args.date))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
