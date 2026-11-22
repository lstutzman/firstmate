#!/usr/bin/env python3
"""fm-officer-improvement.py - the improvement officer's daily pass.

Run only through `bin/fm-officer.sh run <id>`, which owns the officer
contract; docs/configuration/officers.md "Officers" owns the registry schema
and docs/officers/improvement-rubric.md owns the design answers.

Usage:
  fm-officer-improvement.py run --date <YYYY-MM-DD> --out <lane-dir> --now <epoch>
                                --repos <owner/repo,...> [--facts <src>] [--gate <src>]
                                [--archive <dir|host:dir>] [--home <dir>]...
                                [--window-days 7] [--max-pr-lookups 200] [--max-facts-age 36]
  fm-officer-improvement.py costs --archive <dir> --from <YYYY-MM-DD> --to <YYYY-MM-DD>

The metric (Lee, 22 Oct 2026): per PR, the time and cost from "work started"
to "running in production", split into 11 stages: work, pr_ready, review,
gate_queue, gate_run, pile_wait, merge, staging_deploy, staging_checks,
release_cut, production. Every record names every stage as measured or
unmeasured, and an unmeasured stage names the source it lacks; a stage time is
never guessed. The pass is read-only, calls no model (model: none) and writes
only its own lane: <date>.json, <date>.md and prs.json.

Cohort. A PR belongs to the run whose date first saw it in production:
  production  fresh landing-truth facts (the fleet-app job, schema 2, read with
              the landing officer's own loader and staleness rule) list the PR
              as in_production; it is dated to the run that first saw that;
  merged      the facts are absent, unreadable or stale, so the PR is a GitHub
              merge in the last --window-days (one list call per repo), its
              ancestry against main is read from the compare API, and
              production stays unconfirmed. A later run with fresh facts
              upgrades the record to production.
The first run that reads fresh facts limits the facts cohort to PRs merged in
the last --window-days and records the in-production PRs it left out as the
lane's baseline in prs.json; no later run counts a baseline PR, so the history
never enters a cohort.
A record is computed when it is first seen (and again on a rerun of that date)
and then kept in prs.json, so a source that arrives later does not rewrite it.

Sources, all read-only; a missing one leaves its stages unmeasured:
  facts     landing-truth facts: merged_at, head_sha, main_promoted_at;
  github    `gh-axi api GET` only: the PR (created_at, head, merge sha) and its
            timeline (a review, or a comment carrying `pc-review-evidence`),
            at most --max-pr-lookups calls a run, then the rest of the PRs are
            named as left unread;
  ledger    each --home's state/fleet-ledger.jsonl (task.dispatched,
            task.pr_ready), then its state/*.status and data/*/status*.log
            (the first [at=] stamp, and the first done line in the ready-signal
            shape `PR <url>`); a PR belongs to a task only through that task's
            own ready signal, a ledger record first, so a pile, restack, merger
            or review log that mentions the PR is ignored;
  gate      the gate-usage records (gate: a path or host:path): mode gate runs
            whose sha is the PR's head or merge sha, so a run on an earlier head
            or a pile candidate is not counted (a lower bound);
  archive   the session archive manifests' pr_urls, cost_usd and tokens only,
            never a transcript; a session's cost and tokens are split evenly
            across the PRs it names (split_across); an archive with no by-date
            folder is unreadable.
Lee minutes and per-PR account usage have no source and are reported as such.

Stage rules:
  work          task dispatch to PR open;       pr_ready  PR open to the ready record;
  review        ready record to the first review or pc-review-evidence comment;
  gate_run      sum of the head sha's gate wall seconds;
  merge         last gate end to the merge;
  release_cut   merge to main_promoted_at (it holds the staging deploy and the
                staging checks, which the facts do not time apart);
  gate_queue, pile_wait, staging_deploy, staging_checks, production: no source yet.
  end_to_end    task dispatch to the end event, which is promotion to main when
                the facts give it, else the merge (production has no timestamp);
  open_to_end   PR open to the same end event; ready_to_merge is a subtotal.

Weekly. On a Sunday run date the digest adds the week Monday to Sunday against
the week before: the median and worst five end to end, each stage's median and
change, and the stage that grew most, all over PRs promoted to main only; merged
only records are listed apart as not yet measurable to production. That run reports one actionable finding;
a daily run reports none, so a consumer wakes once a week.

Outputs <date>.json and <date>.md in --out and prints
`DIGEST <date> <n-actionable> <date>.md` as its last stdout line. Output is a
pure function of the sources, the lane state and --now, so a rerun of a date
rewrites the same bytes.
"""

import argparse
import datetime
import importlib.util
import json
import os
import re
import statistics
import subprocess
import sys

STAGES = ["work", "pr_ready", "review", "gate_queue", "gate_run", "pile_wait", "merge",
          "staging_deploy", "staging_checks", "release_cut", "production"]
NO_SOURCE = {
    "gate_queue": "gate request time (gate-usage records start at the run, not at the request)",
    "pile_wait": "pile order files and merge metadata (not read in slice 1)",
    "staging_deploy": "staging deploy timestamp (landing-truth v2 has only staging_deployed; Azure deploy runs are not read)",
    "staging_checks": "staging verification receipt time (not read in slice 1)",
    "production": "production deploy timestamp (landing-truth v2 has in_production and production_release, no deploy time)",
}
PR_URL = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/(\d+)")
STATUS_LINE = re.compile(r"^([a-z][a-z-]*)\s+\[at=(\d+)\]")
READY_LINE = re.compile(r"^done\s+\[at=(\d+)\][^:]*:\s*PR (\S+)(?: checks green| published for review)?\s*$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
GH_PULL_JQ = ('"PRJSON " + ({number, created_at, merged_at, head: .head.sha, merge_sha: .merge_commit_sha, '
              'base: .base.ref, draft} | tojson)')
GH_LIST_JQ = ('(.[] | select(.merged_at != null) | "PRJSON " + ({number, created_at, merged_at, head: .head.sha, '
              'merge_sha: .merge_commit_sha, base: .base.ref, draft} | tojson)), ("PRPAGE " + (length | tojson))')
LIST_PAGE = 100
GH_TIMELINE_JQ = ('.[] | select(.event == "reviewed" or (.event == "commented" and ((.body // "") | contains("pc-review-evidence")))) '
                  '| "EVJSON " + ({kind: (if .event == "reviewed" then "reviewed" else "marker" end), at: (.submitted_at // .created_at)} | tojson)')
ARCHIVE_PAD_DAYS = 2
ARCHIVE_MAX_DAYS = 45


def to_epoch(text):
    try:
        return int(datetime.datetime.fromisoformat(str(text).replace("Z", "+00:00")).timestamp())
    except (TypeError, ValueError):
        return None


def day_of(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%d")


def shell_quote(text):
    return "'" + text.replace("'", "'\\''") + "'"


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


def read_text(source):
    """A local file, or <host>:</abs/path> over ssh; None when it cannot be read."""
    remote = re.match(r"^([A-Za-z0-9][A-Za-z0-9._@-]*):(/.*)$", source)
    if remote:
        proc = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", remote.group(1),
                               "cat " + shell_quote(remote.group(2))], capture_output=True, check=False)
        return proc.stdout.decode("utf-8", "replace") if proc.returncode == 0 else None
    try:
        with open(source, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def _landing():
    mod = sys.modules.get("fm_officer_landing")
    if mod is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-officer-landing.py")
        spec = importlib.util.spec_from_file_location("fm_officer_landing", path)
        if spec is None or spec.loader is None:
            raise RuntimeError("fm-officer-landing.py cannot be loaded")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        sys.modules["fm_officer_landing"] = mod
    return mod


def read_facts(source, now, max_hours):
    if not source:
        return None, {"state": "absent", "note": "no facts: field on the registry line"}
    landing = _landing()
    try:
        doc = landing.load_facts(source)
    except RuntimeError as exc:
        return None, {"state": "unreadable", "note": str(exc)}
    problem = landing.facts_age_problem(doc, max_hours, now)
    if problem:
        return None, {"state": "stale", "note": problem}
    return doc, {"state": "used", "note": "facts generated %s" % doc.get("generated_at")}


def read_tasks(homes):
    """{pr url: {task, start, ready}} of each readable home. A PR belongs to a task only through that task's own
    ready signal: a task.pr_ready ledger record, or, for a PR no ledger record names, a status-log done line in
    the ready-signal shape (`PR <url>`, optionally `checks green` or `published for review`)."""
    tasks = {}

    def task(home, name):
        return tasks.setdefault((home, name), {"start": None, "ledger": {}, "status": {}})

    for home in homes:
        text = read_text(os.path.join(home, "state", "fleet-ledger.jsonl")) or ""
        for line in text.splitlines():
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict) or not isinstance(rec.get("ts"), int) or not rec.get("task"):
                continue
            t = task(home, rec["task"])
            if rec.get("event") == "task.dispatched":
                t["start"] = rec["ts"] if t["start"] is None else min(t["start"], rec["ts"])
            elif rec.get("event") == "task.pr_ready" and PR_URL.fullmatch(str(rec.get("pr"))):
                t["ledger"][rec["pr"]] = min(rec["ts"], t["ledger"].get(rec["pr"], rec["ts"]))
        logs = []
        state = os.path.join(home, "state")
        if os.path.isdir(state):
            logs += [(f[:-len(".status")], os.path.join(state, f)) for f in sorted(os.listdir(state)) if f.endswith(".status")]
        data = os.path.join(home, "data")
        if os.path.isdir(data):
            for d in sorted(os.listdir(data)):
                folder = os.path.join(data, d)
                if os.path.isdir(folder) and not os.path.islink(folder):
                    logs += [(d, os.path.join(folder, f)) for f in sorted(os.listdir(folder))
                             if re.fullmatch(r"status(\.\d+)?\.log", f)]
        for name, path in logs:
            first = None
            seen = {}
            for line in (read_text(path) or "").splitlines():
                m = STATUS_LINE.match(line)
                if not m:
                    continue
                at = int(m.group(2))
                first = at if first is None else min(first, at)
                ready = READY_LINE.match(line)
                if ready and PR_URL.fullmatch(ready.group(2)):
                    seen.setdefault(ready.group(2), at)
            if first is None:
                continue
            t = task(home, name)
            if t["start"] is None:
                t["start"] = first
            for url, at in seen.items():
                t["status"].setdefault(url, at)
    index = {}
    for source in ("ledger", "status"):
        found = {}
        for (home, name), t in sorted(tasks.items()):
            for url, ready in t[source].items():
                old = found.get(url)
                if url not in index and (old is None or (ready, name) < (old["ready"], old["task"])):
                    found[url] = {"task": name, "start": t["start"], "ready": ready}
        index.update(found)
    return index


def read_gate(source):
    """({sha: [run]}, state note): mode gate runs only."""
    if not source:
        return None, {"state": "absent", "note": "no gate: field on the registry line"}
    text = read_text(source)
    if text is None:
        return None, {"state": "unreadable", "note": "gate-usage records unreadable at %s" % source}
    runs = {}
    for line in text.splitlines():
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if not isinstance(rec, dict) or rec.get("mode") != "gate" or not rec.get("sha"):
            continue
        end = to_epoch(rec.get("guest_ended_at") or rec.get("run_finished_at"))
        wall, guest = rec.get("run_seconds"), rec.get("guest_seconds")
        if end is None or not isinstance(wall, (int, float)) or not isinstance(guest, (int, float)):
            continue
        runs.setdefault(rec["sha"], []).append({"end": end, "wall": wall, "guest": guest})
    return runs, {"state": "used", "note": "gate-usage records read"}


def archive_costs(archive, first, last):
    """{pr url: {usd, sessions, tokens, split_across}} from by-date manifests first..last; counts only, never a
    transcript. A session's cost and tokens are split evenly across the PRs it names, so the shares add up to what
    it spent; split_across lists, per session, how many PRs shared it."""
    out, seen = {}, set()
    day = datetime.date.fromisoformat(first)
    end = datetime.date.fromisoformat(last)
    while day <= end:
        try:
            with open(os.path.join(archive, "by-date", day.isoformat(), "manifest.json"), encoding="utf-8") as fh:
                manifest = json.load(fh)
        except (OSError, ValueError):
            manifest = {}
        for s in manifest.get("sessions") or []:
            if not isinstance(s, dict):
                continue
            ident = (s.get("machine"), s.get("session_id") or s.get("name"))
            if ident in seen:
                continue
            seen.add(ident)
            usd = s.get("cost_usd") if isinstance(s.get("cost_usd"), (int, float)) else 0
            raw_tokens = s.get("tokens")
            tokens = raw_tokens if isinstance(raw_tokens, dict) else {}
            urls = sorted({str(u) for u in s.get("pr_urls") or [] if PR_URL.fullmatch(str(u))})
            for url in urls:
                e = out.setdefault(url, {"usd": 0, "sessions": 0, "split_across": []})
                e["usd"] = round(e["usd"] + usd / len(urls), 6)
                e["sessions"] += 1
                e["split_across"].append(len(urls))
                counts = e.setdefault("tokens", {})
                for k, v in tokens.items():
                    if isinstance(v, int):
                        counts[k] = round(counts.get(k, 0) + v / len(urls), 6)
        day += datetime.timedelta(days=1)
    return out


def read_archive(archive, first, last):
    """(costs, state note)."""
    if not archive:
        return None, {"state": "absent", "note": "no archive: field on the registry line"}
    remote = re.match(r"^([A-Za-z0-9][A-Za-z0-9._@-]*):(.+)$", archive)
    if not remote:
        if not os.path.isdir(os.path.join(archive, "by-date")):
            return None, {"state": "unreadable", "note": "session archive has no by-date folder at %s" % archive}
        return archive_costs(archive, first, last), {"state": "used", "note": "archive manifests %s to %s" % (first, last)}
    with open(os.path.abspath(__file__), "rb") as fh:
        script = fh.read()
    proc = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", remote.group(1), "python3 -I - costs --archive "
                           + shell_quote(remote.group(2)) + " --from " + first + " --to " + last],
                          input=script, capture_output=True, check=False)
    if proc.returncode != 0:
        return None, {"state": "unreadable", "note": "session archive on %s unreachable or has no by-date folder (exit %d)"
                      % (remote.group(1), proc.returncode)}
    try:
        return json.loads(proc.stdout.decode("utf-8")), {"state": "used", "note": "archive manifests %s to %s on %s" % (first, last, remote.group(1))}
    except ValueError:
        return None, {"state": "unreadable", "note": "session archive host %s unreachable or unreadable" % remote.group(1)}


class GitHub:
    """Read-only GitHub: only `gh-axi api GET`, bounded by a per-run call budget."""

    def __init__(self, budget):
        self.left = budget
        self.gaps = []

    def get(self, path, jq, prefix, paginate=False):
        """Parsed JSON for each prefixed output line, or None when the budget is spent or the call fails."""
        lines = self.lines(path, jq, paginate)
        if lines is None:
            return None
        rows = []
        for line in lines:
            if line.startswith(prefix + " "):
                try:
                    rows.append(json.loads(line[len(prefix) + 1:]))
                except ValueError:
                    pass
        return rows

    def lines(self, path, jq, paginate=False):
        """The output lines of one read-only call, or None when the budget is spent or the call fails."""
        if self.left <= 0:
            return None
        self.left -= 1
        cmd = ["gh-axi", "api", "GET", path] + (["--paginate"] if paginate else []) + ["--full", "--jq", jq]
        try:
            proc = subprocess.run(cmd, capture_output=True, timeout=120, check=False)
        except (OSError, subprocess.TimeoutExpired):
            self.gaps.append("GitHub read failed for %s" % path.split("?")[0])
            return None
        if proc.returncode != 0:
            self.gaps.append("GitHub read failed (exit %d) for %s" % (proc.returncode, path.split("?")[0]))
            return None
        return proc.stdout.decode("utf-8", "replace").splitlines()


def fetch_pull(gh, repo, number):
    rows = gh.get("/repos/%s/pulls/%d" % (repo, number), GH_PULL_JQ, "PRJSON")
    return rows[0] if rows else None


def fetch_events(gh, repo, number):
    rows = gh.get("/repos/%s/issues/%d/timeline?per_page=100" % (repo, number), GH_TIMELINE_JQ, "EVJSON", paginate=True)
    if rows is None:
        return None
    return sorted((to_epoch(r.get("at")), r.get("kind")) for r in rows if to_epoch(r.get("at")) is not None)


def fetch_on_main(gh, repo, merge_sha):
    rows = gh.get("/repos/%s/compare/%s...main?per_page=1" % (repo, merge_sha), '"CMP " + (.status | tojson)', "CMP")
    return None if not rows else rows[0] in ("ahead", "identical")


def interval(a, b, a_missing, b_missing, what):
    """A stage entry for b - a: measured, or unmeasured naming the source of each missing end."""
    if a is None or b is None:
        return {"seconds": None, "unmeasured": "; ".join(m for v, m in ((a, a_missing), (b, b_missing)) if v is None)}
    if b < a:
        return {"seconds": None, "unmeasured": "%s runs backwards in the sources" % what}
    return {"seconds": b - a, "unmeasured": None}


def measure(pr, ctx):
    """One PR's record from its gathered facts. pr: repo, number, cohort, created, merged, head, merge_sha, promoted,
    task, events (None when unread), pull_reason and events_reason (why the PR record or its timeline is unread,
    or None), on_main."""
    repo, number = pr["repo"], pr["number"]
    url = "https://github.com/%s/pull/%d" % (repo, number)
    task = ctx["tasks"].get(url)
    start, ready = (task["start"], task["ready"]) if task else (None, None)
    created, merged, promoted = pr["created"], pr["merged"], pr["promoted"]
    no_ready = ("task ready signal naming this PR (a task.pr_ready ledger record or a status-log done line "
                "`PR <url>` in a readable home)")
    no_start = "task record has no dispatch time" if task else no_ready
    no_open = pr["pull_reason"] or "PR open time missing from the GitHub PR record"
    stages = {}
    stages["work"] = interval(start, created, no_start, no_open, "the dispatch record")
    stages["pr_ready"] = interval(created, ready, no_open, no_ready, "the ready record")
    if ready is None:
        review = {"seconds": None, "unmeasured": no_ready}
    elif pr["events"] is None:
        review = {"seconds": None, "unmeasured": "PR timeline unread (%s)" % (pr["events_reason"] or pr["pull_reason"] or "GitHub read failed")}
    else:
        hits = [at for at, _ in pr["events"] if at >= ready]
        review = ({"seconds": hits[0] - ready, "unmeasured": None} if hits else
                  {"seconds": None, "unmeasured": "no review event or pc-review-evidence comment on the PR timeline after the ready record"})
    stages["review"] = review
    runs = []
    gate_note = None
    if ctx["gate"] is None:
        gate_missing = "gate-usage records (%s)" % ctx["gate_state"]["note"]
        stages["gate_run"] = {"seconds": None, "unmeasured": gate_missing}
        stages["merge"] = {"seconds": None, "unmeasured": gate_missing}
    else:
        for sha in sorted({s for s in (pr["head"], pr["merge_sha"]) if s}):
            runs += ctx["gate"].get(sha, [])
        if runs:
            stages["gate_run"] = {"seconds": sum(r["wall"] for r in runs), "unmeasured": None}
            gate_note = "gate runs on the final head and merge sha only (a lower bound)"
            stages["gate_run"]["note"] = gate_note
            stages["merge"] = interval(max(r["end"] for r in runs), merged, "last gate end", "merge time", "the last gate end")
        else:
            none = "no gate-usage record for this PR's head or merge sha"
            stages["gate_run"] = {"seconds": None, "unmeasured": none}
            stages["merge"] = {"seconds": None, "unmeasured": none}
    for name, why in NO_SOURCE.items():
        stages[name] = {"seconds": None, "unmeasured": why}
    if promoted is not None:
        stages["release_cut"] = interval(merged, promoted, "merge time", "promotion time", "the merge")
        stages["release_cut"]["note"] = "includes the staging deploy and staging checks, which the facts do not time apart"
    else:
        stages["release_cut"] = {"seconds": None, "unmeasured": ctx["release_cut_missing"]}
    end, end_event = (promoted, "promoted_to_main") if promoted is not None else (merged, "merged")
    record = {"key": "%s#%d" % (repo, number), "repo": repo, "pr": number, "url": url, "cohort": pr["cohort"],
              "end_event": end_event, "head_sha": pr["head"], "task": task["task"] if task else None,
              "on_main": pr["on_main"],
              "stages": {name: stages[name] for name in STAGES},
              "end_to_end": interval(start, end, no_start, "end event time", "the dispatch record"),
              "open_to_end": interval(created, end, no_open, "end event time", "the PR open"),
              "ready_to_merge": interval(ready, merged, no_ready, "merge time", "the ready record")}
    record["end_to_end"]["end_event"] = end_event
    costs = ctx["costs"]
    if costs is None:
        usd = {"value": None, "sessions": 0, "unmeasured": "session archive (%s)" % ctx["archive_state"]["note"]}
    elif url in costs:
        usd = {"value": costs[url]["usd"], "sessions": costs[url]["sessions"], "tokens": costs[url]["tokens"],
               "split_across": costs[url]["split_across"], "unmeasured": None}
    else:
        usd = {"value": None, "sessions": 0, "unmeasured": "no archived session lists this PR in pr_urls"}
    record["cost"] = {
        "model_usd": usd,
        "gate_minutes": ({"value": round(sum(r["guest"] for r in runs) / 60.0, 2), "unmeasured": None, "note": gate_note} if runs else
                         {"value": None, "unmeasured": stages["gate_run"]["unmeasured"]}),
        "lee_minutes": {"value": None, "unmeasured": "no record of Lee's minutes (the time a decision stayed open is not his time)"},
        "account_usage": {"value": None, "unmeasured": "cpa-usage reports per account, not per PR"},
    }
    return record


def median(values):
    if not values:
        return None
    m = statistics.median(values)
    return int(m) if m == int(m) else m


def fmt(seconds):
    if seconds is None:
        return "unmeasured"
    seconds = int(round(seconds))
    sign = "-" if seconds < 0 else ""
    seconds = abs(seconds)
    if seconds < 60:
        return "%s%ds" % (sign, seconds)
    if seconds < 3600:
        return "%s%dm" % (sign, seconds // 60)
    return "%s%dh%02dm" % (sign, seconds // 3600, seconds % 3600 // 60)


def weekly(state_prs, date):
    day = datetime.date.fromisoformat(date)
    if day.weekday() != 6:
        return None
    this_lo, prior_hi = day - datetime.timedelta(days=6), day - datetime.timedelta(days=7)
    prior_lo = day - datetime.timedelta(days=13)

    def between(lo, hi):
        return [r for r in state_prs.values() if lo.isoformat() <= r["cohort_date"] <= hi.isoformat()]

    def promoted(recs):
        return [r for r in recs if r["end_event"] == "promoted_to_main"]

    week_all = between(this_lo, day)
    now, before = promoted(week_all), promoted(between(prior_lo, prior_hi))
    merged_only = sorted(r["key"] for r in week_all if r["end_event"] != "promoted_to_main")

    def values(recs, stage):
        return [r["stages"][stage]["seconds"] for r in recs if r["stages"][stage]["seconds"] is not None]

    def e2e(recs):
        return [r["end_to_end"]["seconds"] for r in recs if r["end_to_end"]["seconds"] is not None]

    stages, grew, grew_delta = {}, None, 0
    for name in STAGES:
        cur, prev = values(now, name), values(before, name)
        m, p = median(cur), median(prev)
        delta = (m - p) if m is not None and p is not None else None
        stages[name] = {"median": m, "measured": len(cur), "prior_median": p, "prior_measured": len(prev), "delta": delta}
        if delta is not None and delta > grew_delta:
            grew, grew_delta = name, delta
    ranked = sorted(((r["end_to_end"]["seconds"], r["key"], r["url"]) for r in now if r["end_to_end"]["seconds"] is not None),
                    key=lambda t: (-t[0], t[1]))
    return {"week_start": this_lo.isoformat(), "week_end": day.isoformat(), "prior_start": prior_lo.isoformat(),
            "prior_end": prior_hi.isoformat(), "prs": len(now), "prior_prs": len(before),
            "median_end_to_end": {"seconds": median(e2e(now)), "measured": len(e2e(now)), "of": len(now)},
            "prior_median_end_to_end": {"seconds": median(e2e(before)), "measured": len(e2e(before)), "of": len(before)},
            "worst_five": [{"key": k, "url": u, "seconds": s} for s, k, u in ranked[:5]],
            "stages": stages, "grew_most": grew,
            "not_measurable_to_production": {"count": len(merged_only), "keys": merged_only},
            "unmeasured_stages": [n for n in STAGES if not values(now, n)]}


def render_md(doc):
    lines = ["# Improvement officer digest for %s" % doc["date"], ""]
    lines.append("%d PR(s) first seen this run (%s); %d actionable finding(s); no Linear writes." % (
        len(doc["prs"]), doc["cohort_basis"], doc["actionable"]))
    lines += ["", "## Sources", ""]
    for name in sorted(doc["sources"]):
        s = doc["sources"][name]
        lines.append("- %s: %s (%s)" % (name, s["state"], s["note"]))
    lines += ["", "## PRs", ""]
    for r in doc["prs"]:
        parts = ["%s %s" % (n, fmt(r["stages"][n]["seconds"])) for n in STAGES if r["stages"][n]["seconds"] is not None]
        missing = [n for n in STAGES if r["stages"][n]["seconds"] is None]
        cost = r["cost"]["model_usd"]
        lines.append("- %s (%s): end to end %s, open to end %s; %s; unmeasured: %s; model cost %s" % (
            r["key"], r["end_event"], fmt(r["end_to_end"]["seconds"]), fmt(r["open_to_end"]["seconds"]),
            ", ".join(parts) or "no stage measured", ", ".join(missing) or "none",
            "$%s" % cost["value"] if cost["value"] is not None else "unmeasured"))
    if not doc["prs"]:
        lines.append("- None.")
    w = doc["weekly"]
    if w:
        lines += ["", "## Week %s to %s against %s to %s" % (w["week_start"], w["week_end"], w["prior_start"], w["prior_end"]), ""]
        m, p = w["median_end_to_end"], w["prior_median_end_to_end"]
        lines.append("%d PR(s) promoted to main this week (%d the week before). Median end to end %s (%d of %d measured), the week before %s." % (
            w["prs"], w["prior_prs"], fmt(m["seconds"]), m["measured"], m["of"], fmt(p["seconds"])))
        nm = w["not_measurable_to_production"]
        lines.append("Merged only, not yet measurable to production (left out of every median): %d%s" % (
            nm["count"], " (%s)" % ", ".join(nm["keys"]) if nm["keys"] else ""))
        lines.append("Worst five end to end:")
        for x in w["worst_five"] or []:
            lines.append("- %s %s" % (x["key"], fmt(x["seconds"])))
        if not w["worst_five"]:
            lines.append("- None measured.")
        lines += ["", "Stage medians, this week against the week before:"]
        for n in STAGES:
            s = w["stages"][n]
            lines.append("- %s: %s (%d measured), before %s (%d measured), change %s" % (
                n, fmt(s["median"]), s["measured"], fmt(s["prior_median"]), s["prior_measured"], fmt(s["delta"])))
        grew = w["grew_most"]
        lines += ["", "Stage that grew most: %s" % (
            "%s (+%s)" % (grew, fmt(w["stages"][grew]["delta"])) if grew else "none (no stage was measured in both weeks and longer)"),
            "Stages with no measurement this week: %s" % (", ".join(w["unmeasured_stages"]) or "none")]
    lines += ["", "## Findings", ""]
    for f in doc["findings"]:
        lines.append("- [%s] %s: %s" % (f["severity"], f["class"], f["summary"]))
    if not doc["findings"]:
        lines.append("- None.")
    return "\n".join(lines) + "\n"


def run(args):
    repos = [r for r in args.repos.split(",") if r]
    if not repos or not all(REPO_RE.match(r) for r in repos):
        print("fm-officer-improvement: repos must be comma-separated owner/repo names", file=sys.stderr)
        return 1
    date = args.date
    state_path = os.path.join(args.out, "prs.json")
    try:
        with open(state_path, encoding="utf-8") as fh:
            lane = json.load(fh)
        state, baseline = lane.get("prs", {}), lane.get("baseline")
    except (OSError, ValueError, AttributeError):
        state, baseline = {}, None
    seeding = baseline is None or baseline["date"] == date
    run_day = datetime.date.fromisoformat(date)
    window_lo = (run_day - datetime.timedelta(days=args.window_days - 1)).isoformat()
    facts, facts_state = read_facts(args.facts, args.now, args.max_facts_age)
    gh = GitHub(args.max_pr_lookups)
    page_gaps = []

    # Candidates: (repo, number) -> what the source already gives.
    candidates = {}
    if facts is not None:
        skipped = []
        for key, rec in sorted(facts["records"].items()):
            if rec.get("repo") not in repos or rec.get("in_production") is not True:
                continue
            old = state.get(key)
            if old and old["cohort"] == "production" and old["first_seen"] != date:
                continue
            if not old and not seeding and key in baseline["keys"]:
                continue
            if not old and seeding and (not rec.get("merged_at") or day_of(to_epoch(rec["merged_at"]) or 0) < window_lo):
                skipped.append(key)
                continue
            candidates[(rec["repo"], rec["pr"])] = {"cohort": "production", "head": rec.get("head_sha"), "merge_sha": rec.get("merged_sha"),
                                                    "merged": to_epoch(rec.get("merged_at")), "promoted": to_epoch(rec.get("main_promoted_at")),
                                                    "cohort_date": date, "pull": None, "on_main": rec.get("on_main")}
        if seeding:
            baseline = {"date": date, "keys": skipped}
        cohort_basis = "in production, first seen on this run"
    else:
        for repo in repos:
            lines = gh.lines("/repos/%s/pulls?state=closed&sort=updated&direction=desc&per_page=%d" % (repo, LIST_PAGE), GH_LIST_JQ)
            if lines is None:
                continue
            rows = []
            for line in lines:
                if line.startswith("PRJSON "):
                    try:
                        rows.append(json.loads(line[7:]))
                    except ValueError:
                        pass
                elif line.strip() == "PRPAGE %d" % LIST_PAGE:
                    page_gaps.append("%s: the closed-PR page is full (%d), so PRs merged earlier in the window may be missing" % (repo, LIST_PAGE))
            for row in rows:
                merged = to_epoch(row.get("merged_at"))
                key = "%s#%d" % (repo, row["number"])
                old = state.get(key)
                if merged is None or day_of(merged) > date or day_of(merged) < window_lo:
                    continue
                if old and old["first_seen"] != date:
                    continue
                candidates[(repo, row["number"])] = {"cohort": "merged", "head": row.get("head"), "merge_sha": row.get("merge_sha"),
                                                     "merged": merged, "promoted": None, "cohort_date": day_of(merged), "pull": row,
                                                     "on_main": None}
        cohort_basis = "merged (production unconfirmed)"

    tasks = read_tasks(args.home)
    gate, gate_state = read_gate(args.gate)
    ordered = sorted(candidates)
    spans = []
    for repo, number in ordered:
        c = candidates[(repo, number)]
        url = "https://github.com/%s/pull/%d" % (repo, number)
        spans.append(((tasks.get(url) or {}).get("start") or c["merged"] or 0))
    costs, archive_state = None, {"state": "absent", "note": "no archive: field on the registry line"}
    if args.archive and ordered:
        first = max(day_of(min(spans) - ARCHIVE_PAD_DAYS * 86400), (run_day - datetime.timedelta(days=ARCHIVE_MAX_DAYS)).isoformat())
        costs, archive_state = read_archive(args.archive, first, date)

    ctx = {"tasks": tasks, "gate": gate, "gate_state": gate_state, "costs": costs, "archive_state": archive_state,
           "release_cut_missing": "landing-truth facts (%s: %s)" % (facts_state["state"], facts_state["note"])}
    records = {}
    for repo, number in ordered:
        c = candidates[(repo, number)]
        pull = c["pull"]
        pull_reason = events_reason = None
        if pull is None:
            pull = fetch_pull(gh, repo, number)
            if pull is None:
                pull_reason = ("GitHub lookup cap (max-pr-lookups) left this PR unread" if gh.left <= 0 else "GitHub PR record unreadable")
        events = None
        if pull is not None:
            events = fetch_events(gh, repo, number)
            if events is None and gh.left <= 0:
                events_reason = "GitHub lookup cap (max-pr-lookups) left this PR's timeline unread"
            if c["cohort"] == "merged" and c["on_main"] is None and c["merge_sha"] and pull.get("base") != "main":
                c["on_main"] = fetch_on_main(gh, repo, c["merge_sha"])
            elif c["cohort"] == "merged" and pull.get("base") == "main":
                c["on_main"] = True
        created = to_epoch(pull.get("created_at")) if pull else None
        merged = c["merged"] if c["merged"] is not None else (to_epoch(pull.get("merged_at")) if pull else None)
        info = {"repo": repo, "number": number, "cohort": c["cohort"], "created": created, "merged": merged,
                "head": c["head"] or (pull or {}).get("head"), "merge_sha": c["merge_sha"], "promoted": c["promoted"],
                "events": events, "pull_reason": pull_reason, "events_reason": events_reason, "on_main": c["on_main"]}
        rec = measure(info, ctx)
        rec["cohort_date"] = c["cohort_date"]
        rec["first_seen"] = date
        records[rec["key"]] = rec
    state.update(records)
    mine = [state[k] for k in sorted(state) if state[k]["first_seen"] == date]
    week = weekly(state, date)
    findings = []
    if week and (week["prs"] or week["not_measurable_to_production"]["count"]):
        grew = week["grew_most"]
        findings.append({"class": "weekly", "severity": "medium",
                         "summary": "week %s to %s: %d PR(s) promoted to main, median end to end %s; %s; %d merged only, not yet measurable to production" % (
            week["week_start"], week["week_end"], week["prs"], fmt(week["median_end_to_end"]["seconds"]),
            "stage that grew most: %s" % grew if grew else "no stage grew", week["not_measurable_to_production"]["count"])})
    sources = {"facts": facts_state, "gate": gate_state, "archive": archive_state,
               "github": {"state": "used" if not gh.gaps else "partial",
                          "note": "; ".join(sorted(set(gh.gaps))) or "read-only gh-axi api GET, %d call(s) left of %d" % (gh.left, args.max_pr_lookups)},
               "ledger": {"state": "used" if tasks else "absent", "note": "%d PR(s) named by task records in %d home(s)" % (len(tasks), len(args.home))}}
    for name, s in sorted(sources.items()):
        if s["state"] != "used":
            findings.append({"class": "coverage", "severity": "low", "summary": "%s %s: %s" % (name, s["state"], s["note"])})
    for gap in page_gaps:
        findings.append({"class": "coverage", "severity": "low", "summary": "GitHub list page cap: " + gap})
    if gh.left <= 0:
        findings.append({"class": "coverage", "severity": "low",
                         "summary": "GitHub lookup cap reached; PRs left unread have unmeasured stages naming the cap"})
    doc = {"officer_role": "improvement", "date": date, "cohort_basis": cohort_basis, "window_days": args.window_days,
           "sources": sources, "prs": mine, "weekly": week, "findings": findings,
           "actionable": sum(1 for f in findings if f["severity"] in ("high", "medium"))}
    os.makedirs(args.out, exist_ok=True)
    lane = {"schema": 1, "prs": state}
    if baseline is not None:
        lane["baseline"] = baseline
    write_if_changed(state_path, json.dumps(lane, sort_keys=True, indent=1) + "\n")
    write_if_changed(os.path.join(args.out, date + ".json"), json.dumps(doc, sort_keys=True, indent=1, ensure_ascii=False) + "\n")
    write_if_changed(os.path.join(args.out, date + ".md"), render_md(doc))
    print("DIGEST %s %d %s.md" % (date, doc["actionable"], date))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-officer-improvement.py")
    sub = parser.add_subparsers(dest="action", required=True)
    r = sub.add_parser("run")
    r.add_argument("--date", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--now", type=int, required=True)
    r.add_argument("--repos", required=True)
    r.add_argument("--facts", default="")
    r.add_argument("--gate", default="")
    r.add_argument("--archive", default="")
    r.add_argument("--home", action="append", default=[])
    r.add_argument("--window-days", type=int, default=7)
    r.add_argument("--max-pr-lookups", type=int, default=200)
    r.add_argument("--max-facts-age", type=int, default=36)
    c = sub.add_parser("costs")
    c.add_argument("--archive", required=True)
    c.add_argument("--from", dest="first", required=True)
    c.add_argument("--to", dest="last", required=True)
    args = parser.parse_args(argv)
    if args.action == "costs":
        if not os.path.isdir(os.path.join(args.archive, "by-date")):
            print("fm-officer-improvement: no by-date folder in %s" % args.archive, file=sys.stderr)
            return 1
        print(json.dumps(archive_costs(args.archive, args.first, args.last), sort_keys=True))
        return 0
    return run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
