#!/usr/bin/env python3
"""fm-velocity-taps.py - firstmate's side of the fleet app's velocity-audit card taps (PC-4212).

A library, not a command: the friction officer's run (bin/fm-officer-friction.py) loads it by path and calls `run`
with the Captain's Log replies it already read, so main no longer relays a tap by hand. The fleet app's contract is
deploy/README.md "Velocity audit" in the fleet-app repository: a tap is one captain reply
{"requestId": "cl-<uuid>", "card": "velocity-<suggestion id>", "text": "<choice words>: <title>"} with a suggestion id
vs-<yyyymmdd>-<n>. The pass is deterministic and model-free; it never talks to a model.

What each reply does, chosen by the words it starts with (case-insensitive):

  Create item for later   files the Linear issue (Improvement, Source agent, area:fleet, project Fleet) and leaves it
  (older: Accept)         in the backlog; answers the reply "Filed as PC-n" (or "Already filed as PC-n").
  Create and fix now      the same, then adds one start note for the owning office (the card's `owner`: an office
                          named by a --start-home office role, else main) to the digest's start_requests, where
                          bin/fm-office.sh delivers it like any officer start request. An owner of main, slarti,
                          deepthought, gilligan, Lee or anything not recognised sends the note to main, which names
                          the owner. A suggestion that matches a reserved class (docs/officers/contract.md) is filed
                          and held: the note goes to main, never to an office, because the tap is not Lee's word for
                          that class.
  Let's discuss           one note for main; files nothing; the reply is not answered (the app keeps the card under
                          "To discuss" until main answers after the conversation).
  Not for us              files nothing and sends nothing (older: Reject).
  Object                  files nothing; sends the owning office one keyed note naming the card so it stops its work.
  Defer, or any other     ignored; the app no longer offers Defer and the reply is left as it is.

Idempotence. A fingerprint of the suggestion id keys the Linear item (`velocity-taps-fp:<sha256>` in its description,
and this pass's ledger), so a second tap on a card, or a rerun, never files a second item. A reply is handled once:
the lane's velocity-taps.json records each handled requestId, and a reply that already carries an answer, or an
acknowledgement from someone else (main relaying by hand before this ran), is left alone. Effects run before the
reply is acknowledged, so a crash is retried; every effect is itself idempotent (Linear search, fm-inbox.sh note
--request-id, an answer only when none exists).

Sources and the answer mechanism are the ones main already uses: replies are the Captain's Log feed the friction
officer reads (GET <captains-log>/replies), the card's full text is GET <app>/api/velocity-audit (value.suggestions
by id), and the page learns of progress through `fleet-axi captains-log ack` then `answer` (FM_FLEET_AXI names another
binary for tests). Notes for an office are start_requests rows in the friction digest; main's go into the digest's
<date>.start-requests.sh handoff, as friction start requests do. An office delivers only within 36 hours of the
digest, so a digest row is emitted for the run's own date only and a rerun of that date is byte-identical.
"""

import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import importlib.util

REPLY_WINDOW_DAYS = 3   # the app's own reply window; older taps are never replayed when this first runs
LEDGER_FILE = "velocity-taps.json"
OFFICER_ID = "velocity-taps"
AGENT_AS = "friction-officer"
SOURCE_LABEL = "agent"
TYPE_LABEL = "Improvement"
MAIN_OWNERS = ("main", "slarti", "deepthought", "gilligan")
SUGGESTION = re.compile(r"^velocity-(vs-\d{8}-\d+)$")
CHOICES = (("create item for later", "later"), ("accept", "later"), ("create and fix now", "fix"),
           ("let's discuss", "discuss"), ("let’s discuss", "discuss"), ("not for us", "not-for-us"),
           ("reject", "not-for-us"), ("object", "object"))
REQUEST_ID = re.compile(r"^cl-[0-9a-f-]{36}$")
LIMITS = {"title": 120, "tldr": 300, "improvement": 600, "impact": 300, "evidence": 400, "owner": 60, "time_saved": 120}


def _load(name, filename):
    mod = sys.modules.get(name)
    if mod is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), filename)
        spec = importlib.util.spec_from_file_location(name, path)
        assert spec is not None and spec.loader is not None
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        sys.modules[name] = mod
    return mod


def choice_of(text):
    """The action a reply's opening words name, or None (Defer and anything else are not ours)."""
    said = " ".join(str(text or "").lower().split())
    for words, action in CHOICES:
        if said == words or said.startswith(words + ":") or said.startswith(words + " "):
            return action
    return None


def suggestion_of(reply):
    """The suggestion id a velocity card names, or None for any other card."""
    match = SUGGESTION.match(str(reply.get("card") or ""))
    return match.group(1) if match else None


def title_of(reply):
    """The title after the choice words in the reply text (what the app sent), for a card the document no longer holds."""
    return " ".join(str(reply.get("text") or "").split(":", 1)[-1].split())[:LIMITS["title"]]


def clip(value, key):
    return " ".join(str(value if value is not None else "").split())[:LIMITS[key]]


def load_suggestions(app):
    """{suggestion id: record} from GET <app>/api/velocity-audit (value.suggestions); read-only. RuntimeError when unreadable."""
    proc = subprocess.run(["curl", "-fsS", "--max-time", "30", "%s/api/velocity-audit" % app.rstrip("/")],
                          capture_output=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError("unreachable (curl exit %d)" % proc.returncode)
    try:
        body = json.loads(proc.stdout.decode("utf-8"))
    except ValueError:
        raise RuntimeError("unreadable (not JSON)")
    value = body.get("value", body) if isinstance(body, dict) else {}
    rows = value.get("suggestions") if isinstance(value, dict) else None
    if not isinstance(rows, list):
        raise RuntimeError("unreadable (no suggestions)")
    return {r["id"]: r for r in rows if isinstance(r, dict) and isinstance(r.get("id"), str)}


def owner_home(owner, offices, main_home, started_by=None):
    """(home, office role or None): the start-home office whose role is the card's owner, else main (named in the note).

    `started_by` is the office the app records on a card it started (its `office`); an Object stop note goes there first.
    """
    word = clip(started_by or owner, "owner").lower()
    if word not in MAIN_OWNERS:
        for office in offices:
            if office.role and office.role.lower() == word:
                return office.home, office.role.lower()
    return main_home, None


def severity_of(record):
    try:
        level = int(record.get("severity"))
    except (TypeError, ValueError):
        return "medium"
    return "high" if level >= 5 else "medium" if level >= 3 else "low"


def description(sug, card_id, choice, found_line, known, marker, recurrence=None):
    """The Linear item body: the card's own words, which the nightly audit already scrubbed, and who and what it is for."""
    lines = ["Filed by firstmate from Lee's Captain's Log tap on velocity card %s (%s)." % (card_id, choice),
             "What it is for: a velocity bottleneck the nightly audit found, fixed once so agents stop losing that time.",
             "Epic: not assigned; whoever triages this picks one.", ""]
    if known:
        lines.append("Severity: %s (audit severity %s, confidence %s, effort %s)." % (
            severity_of(sug), sug.get("severity"), sug.get("confidence"), sug.get("effort") or "not stated"))
    else:
        lines.append("Severity: medium (the card's full text was not available when this was filed; find it by id in the velocity audit).")
    lines.append(found_line)
    lines.append("")
    if known:
        lines += ["TL;DR: %s" % clip(sug.get("tldr"), "tldr"), "", "What to change: %s" % clip(sug.get("improvement"), "improvement"),
                  "", "Impact: %s" % clip(sug.get("impact"), "impact"),
                  "Owner: %s. Time saved: %s." % (clip(sug.get("owner"), "owner") or "not stated", clip(sug.get("time_saved"), "time_saved") or "not stated")]
        for item in [e for e in (sug.get("evidence") or []) if isinstance(e, dict)][:6]:
            lines.append("- Evidence (%s): %s" % (clip(item.get("machine"), "owner"), clip(item.get("text"), "evidence")))
    if recurrence:
        lines += ["", recurrence]
    lines += ["", "Card: velocity audit page, suggestion %s." % sug.get("id", card_id)]
    # No trailing newline: Linear trims it, and `create --verify` then reports a mismatch on a good create.
    return "\n".join(lines) + "\n" + marker


def note_body(kind, card, request_id, title, owner, issue, office, extra=""):
    """The text of one note; it states where it came from and that it is a routed tap, never a quotation of Lee beyond the tap."""
    head = {"fix": "Velocity tap, Create and fix now",
            "discuss": "Velocity tap, Let's discuss",
            "object": "Velocity tap, Object",
            "held": "Velocity tap, Create and fix now, held"}[kind]
    lines = ["%s: Captain's Log reply [%s] (request %s): %s." % (head, card, request_id, title or "no title")]
    if issue:
        lines.append("Linear %s was filed for it." % issue)
    lines.append("Owner named on the card: %s%s." % (owner or "not stated", "" if office else " (not an office this officer addresses, so this note is for main)"))
    lines.append({
        "fix": "Lee tapped Create and fix now on this card, which asks for the card's work to start. Start it under the usual routing, "
               "capacity and delivery rules; name %s in the branch or backlog line. Answer nothing: firstmate already answered the reply." % (issue or "the card"),
        "discuss": "Lee tapped Let's discuss: talk it through with the captain in chat. Nothing is filed. Answer the reply "
                   "(fleet-axi captains-log answer %s \"<words>\") once the conversation is done." % request_id,
        "object": "Lee tapped Object on this started card: stop the work started for it and preserve the branch; start nothing new for the card.",
        "held": "The card's own words match a reserved class (%s), which a tap does not authorise: nothing was handed to an office. "
                "Ask Lee for his word on that class before any work starts." % extra}[kind])
    return " ".join(lines)


def request_for(date, home, kind, key, body):
    """One digest start_requests row; its id has the shape bin/fm-office.sh delivers and repeats the same note on a replay."""
    rid = "friction-%s-%s" % (date, hashlib.sha256(("velocity-tap\0%s\0%s" % (kind, key)).encode("utf-8")).hexdigest()[:16])
    return {"kind": "velocity-tap-%s" % kind, "key": key, "owner_home": home,
            "execute": {"action": "start", "env": {"FM_HOME": home}, "request_id": rid,
                        "argv": [os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-inbox.sh"),
                                 "note", "--request-id", rid, "--json", "--", body]}}


def fleet_axi(args, cmd=None):
    """(ok, output) of one `fleet-axi --as friction-officer captains-log ...` call; never raises."""
    binary = cmd or os.environ.get("FM_FLEET_AXI") or "fleet-axi"
    try:
        proc = subprocess.run([binary, "--as", AGENT_AS, "captains-log"] + args, capture_output=True, check=False, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, str(exc)[:120]
    return proc.returncode == 0, (proc.stderr or proc.stdout).decode("utf-8", "replace").strip()[:160]


def recent(reply, now):
    stamp = str(reply.get("at") or "")
    try:
        at = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return False
    return now - at <= REPLY_WINDOW_DAYS * 86400


def digest_rows(ledger, date):
    """The start_requests rows of the replies finished on this digest's date (see the header: a rerun is byte-identical)."""
    done = [e for e in ledger["replies"].values() if e.get("done") and e.get("date") == date]
    return [request_for(date, n["home"], n["kind"], n["key"], n["body"])
            for e in sorted(done, key=lambda e: e.get("seq", 0)) for n in e.get("notes", [])]


def file_card(lib, filer, ctx, reply_ctx, ledger):
    """(issue, status): the Linear item for one card; (None, reason) when it could not be filed this run."""
    card_id, sug, known, title, action = (reply_ctx[k] for k in ("card_id", "sug", "known", "title", "action"))
    f = lib.make_finding("velocity", "tap", card_id, title or card_id,
                         "%s %s" % (clip(sug.get("tldr"), "tldr"), clip(sug.get("improvement"), "improvement")),
                         "real", severity_of(sug), False, {}, project=lib.FLEET_PROJECT)
    fp = f["fingerprint"]
    if fp in ledger["filed"]:
        return ledger["filed"][fp], "exists", f
    choice = "Create and fix now" if action == "fix" else "Create item for later"
    marker = "%s:%s" % (filer.officer.marker, fp)
    found = filer.officer.found_line(1, ctx["date"], ctx["date"])
    def label_set(_f):
        return lib.fleet_labels(SOURCE_LABEL, reply_ctx["names"], TYPE_LABEL)

    def describe(_f, near=None, recurrence=None):
        return description(sug, card_id, choice, found, known, marker, recurrence)

    try:
        if reply_ctx["names"] is None:
            reply_ctx["names"] = lib.label_names(filer.lin, ctx["team"])
        filer.file_single(f, label_set, describe)
        filer.settle_bumps(label_set, describe)
    except lib.LinearError as exc:
        bumped = (f["filing"] or {}).get("issue")
        if bumped and filer.found.get("issues", {}).get(bumped, {}).get("last") == ctx["date"]:
            f["filing"]["found_error"] = str(exc)
        else:
            ledger["filed"].pop(fp, None)
            f["filing"] = {"action": "failed", "reason": str(exc)}
        if exc.code == "RATE_LIMITED":
            lib.pause_for_rate_limit(ctx["out"], ctx["now"])
    del filer.bumps[:]
    filing = f["filing"] or {}
    if filing.get("issue"):
        ledger["filed"][fp] = filing["issue"]
        return filing["issue"], filing.get("action"), f
    return None, filing.get("reason") or "no reason given", f


def run(replies, ctx):
    """Handles every new velocity tap in `replies`; returns (report dict, start_requests rows).

    ctx: out (the officer's lane), date (the digest's), now, app (the fleet app's origin), fm_home, offices, writes,
    team, max_creates, max_calls, jev, and optionally fleet_axi. max_creates and max_calls are what is left of the
    officer's registry-line budget after its own Linear pass; the report's linear_calls names the calls this pass made.
    With writes other than linear nothing is filed or answered and the taps wait.
    """
    lib = _load("fm_officer_linear", "fm-officer-linear.py")
    report = {"read": 0, "handled": [], "waiting": [], "ignored": 0, "gaps": [], "linear_calls": 0}
    ledger_path = os.path.join(ctx["out"], LEDGER_FILE)
    ledger = lib.read_json(ledger_path, {})
    for key in ("replies", "filed", "found"):
        ledger.setdefault(key, {})
    pending = []
    for reply in sorted((r for r in replies if isinstance(r, dict) and suggestion_of(r) and REQUEST_ID.match(str(r.get("requestId") or ""))),
                        key=lambda r: (str(r.get("at")), str(r["requestId"]))):
        entry = ledger["replies"].get(reply["requestId"])
        if (entry and entry.get("done")) or (not entry and not recent(reply, ctx["now"])):
            continue
        report["read"] += 1
        action = choice_of(reply.get("text"))
        if action is None:
            report["ignored"] += 1
        elif entry or not (reply.get("answer") or reply.get("acknowledged")):
            pending.append((reply, action))
    if not pending:
        return report, digest_rows(ledger, ctx["date"])
    if ctx["writes"] != "linear":
        report["gaps"].append("%d velocity tap(s) wait: the run writes no Linear items (set writes: linear), so main relays them." % len(pending))
        report["waiting"] = [r["requestId"] for r, _ in pending]
        return report, digest_rows(ledger, ctx["date"])
    suggestions = None
    try:
        suggestions = load_suggestions(ctx["app"])
    except RuntimeError as exc:
        if any(a in ("later", "fix") for _, a in pending):
            report["gaps"].append("The velocity audit is %s, so create taps wait for the next run." % exc)
    lin = lib.Linear(ctx["max_calls"])
    off = lib.Officer(OFFICER_ID, "firstmate's velocity tap handler", "Velocity taps", "docs/officers/friction-rubric.md", ("velocity",),
                      project=lib.FLEET_PROJECT)
    filer = lib.Filer(off, lin, ctx["team"], ctx["date"], ctx["out"], ledger["filed"], ledger["found"], lib.Jev(ctx["jev"]), ctx["max_creates"])
    paused = lib.paused_until(ctx["out"], ctx["now"])
    names = {"names": None}
    seq = max([e.get("seq", 0) for e in ledger["replies"].values()] or [0])
    for reply, action in pending:
        rid, card_id = reply["requestId"], suggestion_of(reply) or ""
        sug = (suggestions or {}).get(card_id)
        known = isinstance(sug, dict)
        sug = sug if isinstance(sug, dict) else {"id": card_id}
        title = clip(sug.get("title"), "title") if known else title_of(reply)
        owner = clip(sug.get("owner"), "owner") if known else ""
        card = "velocity-" + card_id
        entry = ledger["replies"].get(rid) or {"date": ctx["date"], "choice": action, "card": card, "notes": []}
        office_home, role = owner_home(owner, ctx["offices"], ctx["fm_home"])
        issue, status = entry.get("issue"), "exists"
        if action in ("later", "fix"):
            if suggestions is None or paused:
                report["waiting"].append(rid)
                continue
            issue, status, f = file_card(lib, filer, ctx, dict(card_id=card_id, sug=sug, known=known, title=title, action=action, **names), ledger)
            if not issue:
                report["gaps"].append("%s: not filed (%s); it waits for the next run." % (card, status))
                report["waiting"].append(rid)
                continue
            entry["issue"] = issue
            if action == "fix" and not entry["notes"]:
                reserved = lib.reserved_class(f)
                kind, home = ("held", ctx["fm_home"]) if reserved else ("fix", office_home)
                entry["notes"] = [{"kind": kind, "key": rid, "home": home,
                                   "body": note_body(kind, card, rid, title, owner, issue, None if reserved else role, reserved or "")}]
        elif action == "discuss" and not entry["notes"]:
            entry["notes"] = [{"kind": "discuss", "key": rid, "home": ctx["fm_home"], "body": note_body("discuss", card, rid, title, owner, None, None)}]
        elif action == "object" and not entry["notes"]:
            # The stop goes to the office the app recorded as having started the card, else the owner's office.
            office_home, role = owner_home(owner, ctx["offices"], ctx["fm_home"], sug.get("office") if known else None)
            if role is None:
                office_home, role = owner_home(owner, ctx["offices"], ctx["fm_home"])
            entry["notes"] = [{"kind": "object", "key": "object:" + card_id, "home": office_home,
                               "body": note_body("object", card, rid, title, owner, None, role)}]
        if any(not n["home"] for n in entry["notes"]):
            report["gaps"].append("%s: no home to address the note to (the officer has no --fm-home); it waits." % card)
            report["waiting"].append(rid)
            continue
        seq += 1
        entry["seq"] = entry.get("seq") or seq
        ledger["replies"][rid] = entry
        lib.write_json(ledger_path, ledger)
        # The page shows each step: ack first ("firstmate has it"), then the answer with the Linear id on a create.
        ok, said = (True, "") if reply.get("acknowledged") else fleet_axi(["ack", rid], ctx.get("fleet_axi"))
        if ok and action in ("later", "fix") and not reply.get("answer"):
            ok, said = fleet_axi(["answer", rid, ("Already filed as %s" if status in ("exists", "duplicate") else "Filed as %s") % issue],
                                 ctx.get("fleet_axi"))
        if not ok:
            report["gaps"].append("%s: the reply could not be answered on the page (%s); the next run retries." % (card, said or "no output"))
            report["waiting"].append(rid)
            continue
        entry.update(done=True, date=ctx["date"])
        lib.write_json(ledger_path, ledger)
        report["handled"].append({"request": rid, "card": card, "choice": action, "issue": issue})
    report["linear_calls"] = lin.n
    lib.write_json(ledger_path, ledger)
    return report, digest_rows(ledger, ctx["date"])


if __name__ == "__main__":
    print(__doc__)
