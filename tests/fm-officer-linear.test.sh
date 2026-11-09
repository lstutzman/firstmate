#!/usr/bin/env bash
# Behavior tests for bin/fm-officer-linear.py, the library every officer files through, driven by a fixture
# officer ("fixture") against a fake linear-axi that keeps a small issue store and logs every call, and a fake local-jev.
#
# Covers: an exact fingerprint match and a local-jev near match above 0.85 both becoming duplicates that raise the
# one Found line in place, with one comment a day; a match at or below 0.85 filing a new item that names the near
# match; the score the found count gives (severity weight x log2(1 + found)); the per-run create cap and the Linear
# call budget leaving a named overflow and nothing dropped; a reserved class becoming one keyed needs-decision and
# never a start, whatever the rubric lists; a rubric only narrowing; fleet findings taking the Fleet project and
# area:fleet and their start requests and patterns going to the Quartermaster; --dry-run before --verify on every write; a closed item never edited, reopened or re-prioritised
# (a new item names it), or with bump_closed bumped and never started; and no call that closes or deletes.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-officer-linear)
LIB="$ROOT/bin/fm-officer-linear.py"
DATE=2026-11-05
NOW=1793871000
export TZ=UTC

# fake_linear <fakebin> <dir>: linear-axi over <dir>/issues.json, logging each call's arguments to <dir>/calls.
fake_linear() {
  cat > "$1/linear-axi" <<'PY'
#!/usr/bin/env python3
import json, os, sys
d = os.environ["LDIR"]
args = sys.argv[1:-2]  # the trailing --output json
with open(os.path.join(d, "calls"), "a") as fh:
    fh.write(" ".join(args) + "\n")
path = os.path.join(d, "issues.json")
issues = json.load(open(path))
def out(data): print(json.dumps({"ok": True, "data": data})); sys.exit(0)
def state_type(state):  # as Linear reports it: a duplicate has its own stateType
    return {"Done": "completed", "Canceled": "canceled", "Duplicate": "duplicate", "In Progress": "started"}.get(state, "unstarted")
def flag(name):
    return args[args.index(name) + 1] if name in args else None
def save(): json.dump(issues, open(path, "w"))
mode = os.environ.get("FAKE_VERIFY", "")
def written(n):
    # What --verify prints after the write, per FAKE_VERIFY: "textappend" is the JSON error with plain text lines after it
    # (linear-verify today), "contract" the shared ok:false document naming the item, "nocontract" the same without the item,
    # "rate" a rate limit with no write, "nowrite" a failure with no write, "nojson" no output at all.
    msg = "Write verification did not match intended state"
    if "--verify" not in args or not mode: out({"issue": {"identifier": n}})
    if mode == "nojson": sys.exit(1)
    if mode == "textappend":
        print(json.dumps({"ok": False, "error": {"code": "VERIFY_MISMATCH", "message": msg}}))
        print("linear-verify: description differs (auto-linked lint.sh)"); sys.exit(1)
    if mode == "contract":
        print(json.dumps({"schemaVersion": 1, "ok": False, "command": "issue create", "error": {"code": "VERIFY_MISMATCH", "message": msg},
                          "data": {"issue": {"identifier": n, "url": "u"}, "verification": {"matched": False}}})); sys.exit(1)
    print(json.dumps({"ok": False, "error": {"code": "VERIFY_MISMATCH", "message": msg}})); sys.exit(1)
def failing():
    if "--verify" in args and mode == "rate":
        print(json.dumps({"ok": False, "error": {"code": "RATE_LIMITED", "message": "slow down"}})); sys.exit(1)
    if "--verify" in args and mode == "nowrite":
        print(json.dumps({"ok": False, "error": {"code": "UNKNOWN", "message": "boom"}})); sys.exit(1)
if args[:2] == ["label", "list"]:
    out({"labels": [{"name": n} for n in open(os.path.join(d, "labels")).read().split()]})
if args[:2] == ["issue", "list"]:
    # Linear data, newest first, titles and stateType as the real list prints them (no title filter exists).
    out({"issues": [{"identifier": i, "title": v["title"], "state": v["state"], "team": "PC", "project": v.get("project"),
                     "stateType": state_type(v["state"]),
                     **({"description": v["description"][:200] + ("\n... (truncated, %d chars total - use --full to see complete body)" % len(v["description"])
                                                                  if len(v["description"]) > 200 else "")} if "description" in (flag("--fields") or "") else {})}
                    for i, v in sorted(issues.items(), key=lambda kv: -int(kv[0].split("-")[1]))][:int(flag("--max-items") or 30)]})
if args[:2] == ["issue", "search"]:
    if os.environ.get("FAKE_SEARCH_MISS"): out({"issues": []})  # full-text search that never returns these titles
    q = args[2].lower()
    words = {w for w in q.replace("-", " ").split() if len(w) > 3}
    hits = [i for i, v in issues.items()
            if (q in v["description"].lower() if "-fp:" in q else words & set(v["title"].lower().split()))]
    out({"issues": [{"identifier": i} for i in hits[:int(flag("--limit") or 20)]]})
if args[:2] == ["issue", "view"]:
    v = issues[args[2]]
    out({"issue": {"identifier": args[2], "title": v["title"], "description": v["description"],
                   "state": v["state"], "project": v.get("project"), "stateType": state_type(v["state"])}})
dry = "--dry-run" in args
if args[:2] == ["issue", "create"]:
    if dry: out({"dryRun": True})
    failing()
    n = "PC-%d" % (101 + len(issues))
    issues[n] = {"title": flag("--title"), "description": open(flag("--body-file")).read(), "state": "Todo",
                 "labels": [args[k + 1] for k, a in enumerate(args) if a == "--label"], "project": flag("--project"),
                 "priority": flag("--priority")}
    if "--verify" in args and os.environ.get("FAKE_DOUBLE"):  # linear-axi re-ran the create: two items, one title
        issues["PC-%d" % (102 + len(issues) - 1)] = dict(issues[n])
    save(); written(n)
if args[:2] == ["issue", "update"]:
    if dry: out({"dryRun": True})
    failing()
    if flag("--state"): issues[args[2]]["state"] = flag("--state")
    if flag("--body-file"): issues[args[2]]["description"] = open(flag("--body-file")).read()
    save(); written(args[2])
if args[:2] == ["issue", "comment"]:
    if not dry: open(os.path.join(d, "comments"), "a").write(args[2] + "\n")
    out({"dryRun": True})
if args[:2] == ["issue", "relation"]:
    if not dry: open(os.path.join(d, "relations"), "a").write(" ".join(args[3:]) + "\n")
    out({"dryRun": True})
print(json.dumps({"ok": False, "error": {"code": "UNKNOWN", "message": "unexpected call " + " ".join(args)}}))
sys.exit(1)
PY
  chmod +x "$1/linear-axi"
}

# A local-jev stand-in: 0.91 for the "duplicate-me" finding against the "Older save crash" item, 0.85 for
# "edge-me" (exactly the threshold, which is not above it), 0.6 for "near-me", else 0.1.
fake_jev() {
  cat > "$1" <<'PY'
import json, sys
state = json.loads(sys.argv[sys.argv.index("--state") + 1])
a, b = state["report_a"], state["report_b"]
score = 0.91 if "duplicate-me" in a and "Older save crash" in b else 0.85 if "edge-me" in a else 0.6 if "near-me" in a else 0.1
print(json.dumps({"type": "noul", "noul": score}))
PY
}

# world <name> <issues.json body>: sets W (the dir), FAKEBIN and LDIR with a fresh issue store.
world() {
  W="$TMP_ROOT/$1"
  mkdir -p "$W/linear"
  LDIR="$W/linear"
  FAKEBIN=$(fm_fakebin "$W")
  printf '%s\n' "$2" > "$LDIR/issues.json"
  printf 'Bug\nChore\nscan\narea:fleet\ntriage\n' > "$LDIR/labels"
  : > "$LDIR/calls"
  fake_linear "$FAKEBIN"
  fake_jev "$W/jev.py"
}

# drive <scenario>: runs the python driver below against the world; prints the result json.
drive() {
  PATH="$FAKEBIN:$PATH" LDIR="$LDIR" W="$W" LIB="$LIB" DATE="$DATE" NOW="$NOW" python3 -I - "$1" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("lib", os.environ["LIB"])
lib = importlib.util.module_from_spec(spec)
sys.modules["lib"] = lib
spec.loader.exec_module(lib)
scenario, W, date, now = sys.argv[1], os.environ["W"], os.environ["DATE"], int(os.environ["NOW"])
rubric_file = os.path.join(W, "fixture-rubric.md")
officer = lib.Officer("fixture", "Fixture Officer", "Fixture", rubric_file, sources=("scan",), pattern_sources=("scan",))

def find(key, title, severity="medium", location="", cause="", project="", found=1):
    f = lib.make_finding("scan", "job", key, title, title + " summary", "real", severity, None, {"cause": cause},
                         location=location, project=project)
    f["found"] = found
    return f

def labels(f):
    return ["Bug", "scan", "triage"], []

def describe(f, near=None, recurrence=None):
    lines = ["Filed by the Fixture Officer.", officer.found_line(1, date, date)]
    if recurrence: lines.append(recurrence)
    if near: lines.append("Near match (not treated as the same issue): %s, local-jev %.2f." % near)
    return "\n".join(lines) + "\nfixture-fp:%s" % f["fingerprint"]

def filer(max_creates=100, budget=450, bump_closed=False):
    lin = lib.Linear(budget)
    ledger, found = {}, {}
    return lib.Filer(officer, lin, "PC", date, W, ledger, found, lib.Jev(os.path.join(W, "jev.py")), max_creates, bump_closed), lin

def run(fl, findings):
    for f in findings:
        fl.file_single(f, labels, describe)
    fl.settle_bumps(labels, describe)

res = {}
if scenario == "dedupe":
    exact = find("a", "Exact one")
    dup = find("b", "Save crashes duplicate-me")
    edge = find("c", "Edge total edge-me")
    near = find("d", "Odd total near-me")
    other = find("e", "Something else entirely")
    fl, lin = filer()
    run(fl, [exact, dup, edge, near, other])
    res = {"filings": {f["key"]: f["filing"] for f in (exact, dup, edge, near, other)}, "calls": lin.n}
elif scenario == "rerun":
    fl, lin = filer()
    # same day, state carried over: the Found line was bumped by the first pass
    exact = find("a", "Exact one")
    fl.found = json.load(open(os.path.join(W, "found.json")))
    run(fl, [exact])
    res = {"filing": exact["filing"]}
elif scenario == "cap":
    items = [find(str(i), "Distinct problem number %s" % ["alpha", "bravo", "charlie", "delta"][i], "high" if i < 2 else "medium") for i in range(4)]
    fl, lin = filer(max_creates=2)
    run(fl, items)
    res = {"filings": [f["filing"]["action"] + ":" + f["filing"].get("reason", "") for f in items], "lines": lib.not_filed_lines(items)}
elif scenario == "budget":
    items = [find(str(i), "Another distinct problem %s" % ["alpha", "bravo", "charlie"][i]) for i in range(3)]
    fl, lin = filer(budget=4)
    try:
        run(fl, items)
        res = {"raised": None}
    except lib.LinearError as exc:
        res = {"raised": exc.code, "filings": [(f["filing"] or {}).get("action") for f in items]}
elif scenario == "fleet":
    officer = lib.Officer("fixture", "Fixture Officer", "Fixture", rubric_file, sources=("scan",), project="Fleet")
    f = find("fleet-1", "Bosun backup stale")
    fl, lin = filer()
    run(fl, [f])
    officer = lib.Officer("fixture", "Fixture Officer", "Fixture", rubric_file, sources=("scan",))
    g = find("fleet-2", "Skill manifest sync loses entries", project="skills")
    fl, lin = filer()
    run(fl, [g])
    h = find("fleet-3", "Calculator total wrong", project="PropertyCompass2")
    fl.file_single(h, lambda f: (["Bug", "scan", "area:fleet"], []), describe)
    res = {"filing": f["filing"], "repo_filing": g["filing"], "pc_filing": h["filing"]}
elif scenario == "fleet-labels":
    res = [lib.fleet_labels("scan", {"bug", "scan", "area:fleet"})[0], lib.fleet_labels("scan", {"bug", "scan", "area:fleet"})[1]]
elif scenario == "closed":
    f = find("old", "Previously closed finding")
    fl, lin = filer()
    run(fl, [f])
    res = {"filing": f["filing"]}
elif scenario == "closed-bump":
    f = find("old", "Previously closed finding", severity="high")
    fl, lin = filer(bump_closed=True)
    run(fl, [f])
    f["score"] = lib.score_of(f)
    rub = lib.load_rubric(rubric_file, officer)
    reopened = dict(f, filing={k: v for k, v in f["filing"].items() if k != "closed"})
    res = {"filing": f["filing"], "starts": lib.plan_starts(officer, [f], rub, date, "linear", "/home/main", [], {})[0],
           "open_starts": lib.plan_starts(officer, [reopened], rub, date, "linear", "/home/main", [], {})[0]}
elif scenario == "score":
    fs = [find("a", "Low one"), find("b", "High one"), find("c", "Medium found three")]
    fs[0]["severity"], fs[1]["severity"], fs[2]["found"] = "low", "high", 3
    ledger = {}
    found = {"issues": {"PC-7": {"count": 3, "last": date}}}
    ledger[fs[2]["fingerprint"]] = "PC-7"
    lib.apply_found(fs, found, ledger)
    res = {"order": ["%s:%d:%.1f" % (f["key"], f["found"], f["score"]) for f in fs]}
elif scenario == "starts":
    fs = [find("a", "Rotate SendGrid API key", "high"), find("b", "Null reference when saving", "high"),
          find("c", "Update the payment refund flow", "critical"), find("d", "Reset token not invalidated", "high")]
    for f in fs:
        f["filing"] = {"action": "created", "issue": "PC-%d" % (200 + ord(f["key"]))}
        f["score"] = lib.score_of(f)
    rub = lib.load_rubric(os.path.join(W, "fixture-rubric.md"), officer)
    handled = {}
    starts, held, asks = lib.plan_starts(officer, fs, rub, date, "linear", "/home/main", [lib.progress.parse_office("/home/nav=propertycompass2")], handled)
    again = lib.plan_starts(officer, fs, rub, "2026-11-06", "linear", "/home/main", [], handled)
    res = {"starts": [s["title"] for s in starts], "homes": [s["execute"]["env"]["FM_HOME"] for s in starts],
           "held": [(h["title"], h["class"]) for h in held], "asks": asks, "gaps": rub.gaps,
           "sev": sorted(rub.start_severities), "min": str(rub.min_score),
           "next_day": [[s["title"] for s in again[0]], again[1], again[2]],
           "body": starts[0]["execute"]["argv"][-1] if starts else None}
elif scenario == "surgeon-clusters":
    import argparse, hashlib
    sspec = importlib.util.spec_from_file_location("surgeon", os.path.join(os.path.dirname(os.environ["LIB"]), "fm-officer-surgeon.py"))
    surgeon = importlib.util.module_from_spec(sspec)
    sspec.loader.exec_module(surgeon)
    def low(key, location, project=""):
        return surgeon.lib.make_finding("review", "nightly-review", key, "Review note " + key, "summary " + key, "real", "low", None, {},
                                        location=location, project=project)
    fs = [low("p%d" % i, "infra/bicep/main%d.bicep" % i) for i in range(3)]
    fs += [low("f%d" % i, "infra/bicep/main%d.bicep" % i, "lstutzman/firstmate") for i in range(3)]
    state = {}
    args = argparse.Namespace(now=now, team="PC", triage_label="triage", max_creates=100, bundle_cap=15, visual_captures="")
    surgeon.file_findings(fs, args, date, W, state, {}, surgeon.lib.Jev(os.path.join(W, "jev.py")), [])
    issues = json.load(open(os.path.join(os.environ["LDIR"], "issues.json")))
    def marker(job, key):
        return hashlib.sha256(("review\0%s\0%s" % (job, key)).encode("utf-8")).hexdigest()
    res = {"filings": {f["key"]: [f["filing"]["action"], f["filing"].get("issue"), f["filing"].get("reason")] for f in fs},
           "items": {i: {"title": v["title"], "labels": v["labels"], "project": v["project"], "tail": v["description"].rsplit("\n", 1)[-1]}
                     for i, v in issues.items()},
           "bundles": {b["issue"]: [b["area"], b["fleet"], b["part"]] for b in json.load(open(os.path.join(W, "bundles.json")))["bundles"].values()}}
elif scenario == "verify-fail":
    mode = os.environ["FAKE_VERIFY"]
    f = find("vf", "Lint script crashes on lint.sh")
    fl, lin = filer()
    err = None
    try:
        run(fl, [f])
    except lib.LinearError as exc:
        err = exc.code
    res = {"filing": f["filing"], "ledger": fl.ledger, "err": err}
elif scenario == "retry-failed":
    f = find("rf", "Retried finding")
    fl, lin = filer()
    os.environ["FAKE_VERIFY"] = "nowrite"
    run(fl, [f])
    first = dict(f["filing"])
    os.environ.pop("FAKE_VERIFY")
    g = find("rf", "Retried finding")
    fl2, _ = filer()
    run(fl2, [g])
    res = {"first": first, "second": g["filing"], "ledger": fl2.ledger}
elif scenario == "cluster-reuse":
    import argparse
    sspec = importlib.util.spec_from_file_location("surgeon", os.path.join(os.path.dirname(os.environ["LIB"]), "fm-officer-surgeon.py"))
    surgeon = importlib.util.module_from_spec(sspec)
    sspec.loader.exec_module(surgeon)
    fs = [surgeon.lib.make_finding("review", "nightly-review", "p%d" % i, "Review note p%d" % i, "summary", "real", "low", None, {},
                                   location="infra/bicep/main%d.bicep" % i) for i in range(3)]
    state = {}
    args = argparse.Namespace(now=now, team="PC", triage_label="triage", max_creates=100, bundle_cap=15, visual_captures="")
    surgeon.file_findings(fs, args, date, W, state, {}, surgeon.lib.Jev(os.path.join(W, "jev.py")), [])
    issues = json.load(open(os.path.join(os.environ["LDIR"], "issues.json")))
    res = {"filings": [[f["filing"]["action"], f["filing"].get("issue")] for f in fs], "verify": [f["filing"].get("verify") for f in fs], "ids": sorted(issues),
           "body": {i: v["description"].count("Review note") for i, v in issues.items()}}
elif scenario in ("fleet-start", "fleet-nowrite"):
    offices = [lib.progress.parse_office("/home/nav=propertycompass2=navigator"), lib.progress.parse_office("/home/qm=firstmate,skills=quartermaster")]
    officer = lib.Officer("fixture", "Fixture Officer", "Fixture", rubric_file, sources=("scan",), pattern_sources=("scan",), project="Fleet")
    fleet = find("f", "Bosun backup check crashes", "high")
    skills = find("s", "Skill sync drops manifest entries", "high", project="skills")
    pc = find("p", "Null reference when saving", "high", project="PropertyCompass2")
    fs = [fleet, skills, pc]
    if scenario == "fleet-start":
        fl, lin = filer()
        run(fl, fs)
    for f in fs:
        f["score"] = lib.score_of(f)
    rub = lib.load_rubric(rubric_file, officer)
    starts, held, asks = lib.plan_starts(officer, fs, rub, date, "linear" if scenario == "fleet-start" else "none", "/home/main", offices, {})
    store = {}
    lib.update_patterns(officer, store, fs, lib.Jev(os.path.join(W, "jev.py")), date)
    pats, captures, lint = lib.pattern_outputs(officer, store, rub, date, "/home/main", offices)
    res = {"starts": {s["title"]: [s["execute"]["env"]["FM_HOME"], s["project"], s["linear_only"]] for s in starts},
           "body": starts[0]["execute"]["argv"][-1] if starts else None,
           "patterns": [{"home": r["execute"]["env"]["FM_HOME"], "project": r["project"], "target": r["target"], "body": r["execute"]["argv"][-1],
                         "lines": [p["line"] for p in r["patterns"]]} for r in pats],
           "captures": sorted(c["tags"][1] for c in captures),
           "filed": {v["title"]: v["project"] for v in json.load(open(os.path.join(os.environ["LDIR"], "issues.json"))).values()}}
elif scenario == "bundle-hold":
    # Three findings on one bundle: a high one that would start, a low one that asks to rotate a key (reserved, under the
    # start score), and one more on a second bundle. The reserved line holds its whole bundle; the other bundle starts once.
    fs = [find("a", "Null reference when saving", "high"), find("b", "Rotate SendGrid API key", "low"),
          find("c", "Crash on login", "high"), find("d", "Crash on logout", "high")]
    for f, issue in zip(fs, ("PC-301", "PC-301", "PC-302", "PC-302")):
        f["filing"] = {"action": "bundled", "issue": issue, "bundle": "Automated findings: x (code review)", "new": True}
        f["score"] = lib.score_of(f)
    rub = lib.load_rubric(os.path.join(W, "fixture-rubric.md"), officer)
    starts, held, asks = lib.plan_starts(officer, fs, rub, date, "linear", "/home/main", [], {})
    res = {"starts": [[s["issue"], s["title"]] for s in starts], "held": [[h["issue"], h["title"], h["class"]] for h in held],
           "asks": [a["key"] for a in asks], "what": starts[0]["execute"]["argv"][-1] if starts else None,
           "rid": starts[0]["execute"]["request_id"] if starts else None}
elif scenario == "bundle":
    # One officer run of the shared bundle path. FINDINGS: [[key, title, severity, location, area, single?], ...];
    # TICK: keys marked resolved; CAP: bundle-cap. The lane's ledger, found and bundle state persist in W between runs.
    rows = json.loads(os.environ["FINDINGS"])
    ledger = lib.read_json(os.path.join(W, "ledger.json"), {})
    found = lib.read_json(os.path.join(W, "found.json"), {})
    fl = lib.Filer(officer, lib.Linear(450), "PC", os.environ.get("RUN_DATE", date), W, ledger, found,
                   lib.Jev(os.path.join(W, "jev.py")), int(os.environ.get("MAX_CREATES", "100")))
    bundles = lib.Bundles(fl, int(os.environ.get("CAP", "15")), recur_closed=os.environ.get("RECUR_CLOSED", "1") == "1")
    fs = []
    for key, title, severity, location, area, *single in rows:
        f = find(key, title, severity, location)
        if not single:
            f["bundle"] = {"family": "code review", "area": area}
        fs.append(f)
    quiet = lib.file_bundled(fl, fs, labels, None, bundles)
    for k in json.loads(os.environ.get("TICK", "[]")):
        bundles.tick(lib.fingerprint("scan", "job", k))
    if not quiet or bundles.needs_linear():
        lib.file_bundled(fl, fs, labels, describe, bundles)
    bundles.save()
    lib.write_json(os.path.join(W, "ledger.json"), ledger)
    lib.write_json(os.path.join(W, "found.json"), found)
    lib.apply_found(fs, found, ledger)
    res = {"filings": {f["key"]: f["filing"] for f in fs}, "found": {f["key"]: f["found"] for f in fs}, "calls": fl.lin.n}
print(json.dumps(res))
PY
}

calls() { cat "$LDIR/calls"; }
issue() { jq -r --arg i "$1" ".[\$i] | $2" "$LDIR/issues.json"; }

EXISTING_FP=$(printf '%s\0%s\0%s' scan job a | sha256sum | cut -d' ' -f1)

dedupe_world() {
  world "$1" "$(jq -n --arg fp "$EXISTING_FP" '{
    "PC-50": {title: "Exact one", state: "Todo", description: ("Filed earlier.\nFound: 1 times (first 2026-10-01, last 2026-10-01, by fixture)\nTail evidence kept\nfixture-fp:" + $fp)},
    "PC-51": {title: "Older save crash", state: "Todo", description: "Older report.\nFound: 1 times (first 2026-10-02, last 2026-10-02, by fixture)"},
    "PC-52": {title: "Older odd total", state: "Todo", description: "A different report."},
    "PC-53": {title: "Edge total report", state: "Todo", description: "Edge report."}}')"
}

test_dedupe_exact_and_near_match() {
  local out
  dedupe_world dedupe
  out=$(drive dedupe) || fail "driver must succeed"
  assert_equals "exists PC-50" "$(jq -r '.filings.a | [.action, .issue] | join(" ")' <<<"$out")" "the fingerprint finds the item whatever the title search says"
  assert_equals "duplicate PC-51 0.91" "$(jq -r '.filings.b | [.action, .issue, (.confidence | tostring)] | join(" ")' <<<"$out")" "local-jev above 0.85 is a duplicate"
  assert_equals created "$(jq -r '.filings.c.action' <<<"$out")" "exactly 0.85 is not above 0.85, so it is filed new"
  assert_equals "PC-52" "$(jq -r '.filings.c.near_match.issue' <<<"$out")" "and the first best near match is named"
  assert_equals "PC-52 0.6" "$(jq -r '.filings.d.near_match | [.issue, (.confidence | tostring)] | join(" ")' <<<"$out")" "a 0.6 match is recorded as near"
  assert_equals created "$(jq -r '.filings.e.action' <<<"$out")" "an unrelated finding is created"
  assert_contains "$(issue PC-106 .description)" "Near match (not treated as the same issue): PC-52, local-jev 0.60" "the near match is in the new item"
  assert_equals 3 "$(grep -c '^issue create .*--verify' "$LDIR/calls")" "only the three that are not duplicates are created"
  assert_not_contains "$(calls)" "--project" "a PropertyCompass2 officer files into no Linear project"
  pass "fm-officer-linear: an exact fingerprint and a local-jev match above 0.85 are duplicates, a lower near match is filed new and noted"
}

test_found_count_is_raised_in_place_once_a_day() {
  local out
  dedupe_world found
  drive dedupe >/dev/null || fail "driver must succeed"
  assert_contains "$(issue PC-50 .description)" "Found: 2 times (first 2026-10-01, last $DATE, by fixture)" "the Found line is raised in place, first date kept"
  assert_contains "$(issue PC-50 .description)" "Tail evidence kept" "the rest of the description survives the edit"
  assert_equals 1 "$(grep -c '^Found: ' <<<"$(issue PC-50 .description)")" "there is still one Found line"
  assert_contains "$(issue PC-51 .description)" "Found: 2 times (first 2026-10-02, last $DATE, by fixture)" "a local-jev duplicate is raised too"
  assert_equals 2 "$(wc -l < "$LDIR/comments" | tr -d ' ')" "one comment per bumped item"
  assert_contains "$(calls)" "issue update PC-50 --body-file" "the edit goes through issue update"
  # A second pass on the same day, with the first pass's found.json carried over, adds nothing.
  jq -n --arg d "$DATE" '{issues: {"PC-50": {count: 2, last: $d}, "PC-51": {count: 2, last: $d}}}' > "$W/found.json"
  : > "$LDIR/calls"
  out=$(drive rerun) || fail "rerun must succeed"
  assert_equals 0 "$(grep -c '^issue update\|^issue comment\|^issue create' "$LDIR/calls")" "the same day never edits or comments twice"
  assert_equals 2 "$(wc -l < "$LDIR/comments" | tr -d ' ')" "still two comments"
  assert_equals 2 "$(jq -r '.filing.found' <<<"$out")" "the count reported is the one already raised"
  pass "fm-officer-linear: a duplicate raises the one Found line in place and comments once a day"
}

test_score_is_the_found_count_lever() {
  local out
  world score '{}'
  out=$(drive score) || fail "driver must succeed"
  assert_equals "b:1:4.0 c:3:4.0 a:1:1.0" "$(jq -r '.order | join(" ")' <<<"$out")" "weight x log2(1 + found): high 4 x 1 = 4, medium 2 x log2(4) = 4, low 1; ties by severity, highest first"
  pass "fm-officer-linear: severity weight x log2(1 + found) orders findings"
}

test_cap_overflow_is_listed_and_budget_stops_the_run() {
  local out
  world cap '{}'
  out=$(drive cap) || fail "driver must succeed"
  assert_equals "created: created: not-filed:over max-creates for this run not-filed:over max-creates for this run" "$(jq -r '.filings | join(" ")' <<<"$out")" "creates stop at the cap and the rest say why"
  assert_contains "$(jq -r '.lines[0]' <<<"$out")" "Not filed (over max-creates for this run): 2, highest score first: Distinct problem number charlie" "the digest line names the overflow"
  assert_equals 2 "$(grep -c '^issue create .*--verify' "$LDIR/calls")" "only two items were created"
  world budget '{}'
  out=$(drive budget) || fail "driver must succeed"
  assert_equals CALL_BUDGET "$(jq -r '.raised' <<<"$out")" "the call budget is raised to the caller"
  assert_equals "created failed null" "$(jq -r '.filings | map(tostring) | join(" ")' <<<"$out")" "the finding it stopped on is marked failed, not dropped"
  assert_equals 4 "$(wc -l < "$LDIR/calls" | tr -d ' ')" "and no call was made past the budget"
  pass "fm-officer-linear: the create cap and the call budget leave a named overflow"
}

test_reserved_class_becomes_one_keyed_needs_decision() {
  local out
  world reserved '{}'
  cat > "$W/fixture-rubric.md" <<'EOF'
# Fixture rubric

## Settings the code reads

- start-severities: medium, high, critical, urgent
- start-min-score: 1
- hold-classes: legal
EOF
  out=$(drive starts) || fail "driver must succeed"
  assert_equals '["Null reference when saving","Reset token not invalidated"]' "$(jq -c '.starts' <<<"$out")" "a code fix starts, whatever the title words"
  assert_equals '[["Rotate SendGrid API key","credentials"],["Update the payment refund flow","payments-billing"]]' "$(jq -c '.held' <<<"$out")" "reserved classes hold even when the rubric lists only legal"
  assert_equals 1 "$(jq '.asks | length' <<<"$out")" "one needs-decision for the run"
  assert_contains "$(jq -r '.asks[0].line' <<<"$out")" "needs-decision [key=fixture-holds-$DATE]: 2 finding(s) held for Lee" "keyed by officer and date"
  assert_contains "$(jq -r '.gaps | join("|")' <<<"$out")" "hold-classes omits payments-billing" "the omission is named and ignored"
  assert_contains "$(jq -r '.gaps | join("|")' <<<"$out")" "start-severities names urgent, which the code does not admit" "a rubric cannot widen what starts"
  assert_equals 4.0 "$(jq -r '.min' <<<"$out")" "a rubric cannot lower the start minimum"
  assert_equals '[[],[],[]]' "$(jq -c '.next_day' <<<"$out")" "an item started or held is not asked for again the next day"
  assert_contains "$(jq -r '.body' <<<"$out")" "Fixture Officer automatic start under its rubric (docs/officers/fixture-rubric.md)" "the start request names the officer and its rubric"
  assert_equals '["/home/nav","/home/nav"]' "$(jq -c '.homes' <<<"$out")" "a finding naming no repository is the officer's default project, PropertyCompass2, and goes to the Navigator"
  pass "fm-officer-linear: a reserved class is one keyed needs-decision and never starts; a rubric only narrows"
}

test_fleet_findings_take_the_fleet_project_and_label() {
  local out
  world fleet '{}'
  out=$(drive fleet) || fail "driver must succeed"
  assert_equals created "$(jq -r '.filing.action' <<<"$out")" "the fleet finding is filed"
  assert_equals '["Bug","scan","area:fleet"]' "$(issue PC-101 '.labels' | jq -c .)" "one Type, one Source, area:fleet"
  assert_equals Fleet "$(issue PC-101 .project)" "a Fleet officer's item is in the Fleet project with no Filer argument"
  assert_equals Fleet "$(issue "$(jq -r '.repo_filing.issue' <<<"$out")" .project)" "a PropertyCompass2 officer's finding naming a fleet repository is filed in the Fleet project too"
  assert_equals '["Bug","scan","area:fleet"]' "$(issue "$(jq -r '.repo_filing.issue' <<<"$out")" '.labels' | jq -c .)" "with area:fleet in place of the label_set's own area"
  assert_equals "not-filed area:fleet is only for fleet work" "$(jq -r '.pc_filing | [.action, .reason] | join(" ")' <<<"$out")" "a PropertyCompass2 finding labelled area:fleet is not filed"
  assert_equals '[["Bug","scan","area:fleet"],[]]' "$(drive fleet-labels | jq -c .)" "fleet_labels names one Type, one Source and area:fleet, and any missing label"
  assert_equals 3 "$(issue PC-101 .priority)" "medium is Linear priority 3"
  assert_contains "$(grep '^issue create' "$LDIR/calls" | sed -n 1p)" "--dry-run" "the dry run comes first"
  assert_contains "$(grep '^issue create' "$LDIR/calls" | sed -n 2p)" "--verify" "then the verify"
  pass "fm-officer-linear: a fleet finding goes to the Fleet project with area:fleet, dry-run then verify"
}

fleet_rubric() {
  cat > "$W/fixture-rubric.md" <<'EOF'
# Fixture rubric

## Settings the code reads

- start-severities: high, critical
EOF
}

test_fleet_finding_starts_and_patterns_go_to_the_quartermaster() {
  local out
  world fleet-start '{}'
  fleet_rubric
  out=$(drive fleet-start) || fail "driver must succeed"
  assert_equals '["/home/qm","",true]' "$(jq -c '.starts["Bosun backup check crashes"]' <<<"$out")" "a Fleet item naming no repository keeps no repository, is Linear-only, and starts with the Quartermaster"
  assert_equals '["/home/qm","skills",false]' "$(jq -c '.starts["Skill sync drops manifest entries"]' <<<"$out")" "a finding naming a fleet repository keeps it and starts with the Quartermaster"
  assert_equals '["/home/nav","PropertyCompass2",false]' "$(jq -c '.starts["Null reference when saving"]' <<<"$out")" "a PropertyCompass2 finding still goes to the Navigator"
  assert_equals '{"Bosun backup check crashes":"Fleet","Skill sync drops manifest entries":"Fleet","Null reference when saving":null}' "$(jq -c '.filed' <<<"$out")" "fleet work is filed in the Fleet project; a PropertyCompass2 finding under a Fleet officer is not"
  assert_contains "$(jq -r '.body' <<<"$out")" "word: 'Each officer should have a different rubric for what they find as work and decide to start' (Lee, main chat 2026-11-05T17:59:01Z)." "only Lee's words are inside the quotation marks"
  assert_equals '[["/home/qm","Fleet"],["/home/nav","PropertyCompass2"],["/home/qm","skills"]]' "$(jq -c '.patterns | sort_by(.project) | map([.home, .project])' <<<"$out")" "fleet patterns go to the Quartermaster, a PropertyCompass2 one to the Navigator"
  assert_equals "Anti-pattern: Bosun backup check crashes. Safe form: not stated by the source; see the linked item" "$(jq -r '.patterns[] | select(.project == "Fleet") | .lines | join("|")' <<<"$out")" "the Fleet request carries only the Fleet pattern"
  assert_not_contains "$(jq -r '.patterns | map(select(.project != "PropertyCompass2") | .target + .body) | join(" ")' <<<"$out")" "quality-patterns.md" "a fleet pattern never goes to PropertyCompass2's quality-patterns.md"
  assert_not_contains "$(jq -r '.patterns[] | select(.project == "Fleet") | .body' <<<"$out")" "firstmate" "no repository is invented for a Fleet item"
  assert_contains "$(jq -r '.patterns[] | select(.project == "PropertyCompass2") | .target' <<<"$out")" ".agents/skills/sdlc-review/references/quality-patterns.md in PropertyCompass2" "a PropertyCompass2 pattern still targets quality-patterns.md"
  assert_equals '["project:Fleet","project:PropertyCompass2","project:skills"]' "$(jq -c '.captures' <<<"$out")" "each pattern goes to the memory tier tagged with its own project"
  pass "fm-officer-linear: Fleet and fleet-repository findings and their patterns go to the Quartermaster; PropertyCompass2 work keeps the Navigator"
}

test_fleet_patterns_route_without_linear_writes() {
  local out
  world fleet-nowrite '{}'
  fleet_rubric
  out=$(drive fleet-nowrite) || fail "driver must succeed"
  assert_equals 0 "$(wc -l < "$LDIR/calls" | tr -d ' ')" "no Linear call is made"
  assert_equals '[["/home/qm","Fleet"],["/home/nav","PropertyCompass2"],["/home/qm","skills"]]' "$(jq -c '.patterns | sort_by(.project) | map([.home, .project])' <<<"$out")" "without filing, a fleet pattern still goes to the Quartermaster"
  assert_not_contains "$(jq -r '.patterns | map(select(.project != "PropertyCompass2") | .target + .body) | join(" ")' <<<"$out")" "quality-patterns.md" "and never to PropertyCompass2's quality-patterns.md"
  pass "fm-officer-linear: with --writes none a fleet officer's patterns still go to the Quartermaster"
}

test_surgeon_bundles_split_fleet_from_propertycompass2() {
  local out pc fleet
  world surgeon-clusters '{}'
  printf 'scheduled-review\ninfrastructure\n' >> "$LDIR/labels"
  out=$(drive surgeon-clusters) || fail "driver must succeed"
  pc=$(jq -r '.filings.p0[1]' <<<"$out"); fleet=$(jq -r '.filings.f0[1]' <<<"$out")
  assert_equals "bundled bundled bundled" "$(jq -r '[.filings.p0, .filings.p1, .filings.p2] | map(.[0]) | join(" ")' <<<"$out")" "PropertyCompass2 review findings are bundled"
  assert_equals 1 "$(jq -r --arg i "$pc" '[.filings | to_entries[] | select(.value[1] == $i)] | length / 3' <<<"$out")" "all three PropertyCompass2 findings share one item"
  assert_equals "bundled bundled bundled" "$(jq -r '[.filings.f0, .filings.f1, .filings.f2] | map(.[0]) | join(" ")' <<<"$out")" "fleet-repository findings are bundled too, not filed singly"
  assert_not_contains "$pc" "$fleet" "a fleet finding in the same area never joins the PropertyCompass2 bundle"
  assert_equals 2 "$(jq '.items | length' <<<"$out")" "two bundle items, one per side"
  assert_equals '{"title":"Automated findings: infrastructure (code review)","labels":["Bug","scheduled-review","infrastructure"],"project":null}' \
    "$(jq -c --arg i "$pc" '.items[$i] | {title, labels, project}' <<<"$out")" "the PropertyCompass2 bundle is titled by its feature area, with that area label and no Linear project"
  assert_equals '["infrastructure",false,1]' "$(jq -c --arg i "$pc" '.bundles[$i]' <<<"$out")" "its saved state names the area, side and part"
  assert_equals '{"labels":["Bug","scheduled-review","area:fleet"],"project":"Fleet"}' \
    "$(jq -c --arg i "$fleet" '.items[$i] | {labels, project}' <<<"$out")" "the fleet bundle is in the Fleet project with area:fleet"
  assert_not_contains "$(jq -r --arg i "$pc" '.items[$i].tail' <<<"$out")" "$(jq -r --arg i "$fleet" '.items[$i].tail' <<<"$out" | cut -d: -f2)" "with its own fingerprint"
  pass "fm-officer-linear: the Surgeon bundles fleet findings apart, in the Fleet project with area:fleet"
}

test_closed_item_is_never_touched() {
  local out before
  world closed "$(jq -n --arg fp "$(printf '%s\0%s\0%s' scan job old | sha256sum | cut -d' ' -f1)" \
    '{"PC-60": {title: "Previously closed finding", state: "Done", description: ("Closed by a person.\nfixture-fp:" + $fp)}}')"
  before=$(issue PC-60 .description)
  out=$(drive closed) || fail "driver must succeed"
  assert_equals "created PC-102 PC-60" "$(jq -r '.filing | [.action, .issue, .recurrence_of] | join(" ")' <<<"$out")" "a repeat of a closed item is a recurrence in a new item"
  assert_contains "$(issue PC-102 .description)" "Recurrence of PC-60 (closed as Done)." "which names the old one"
  assert_equals "$before" "$(issue PC-60 .description)" "the closed item is not edited"
  assert_equals 0 "$(grep -c '^issue update PC-60\|^issue comment PC-60' "$LDIR/calls")" "no update or comment reaches it"
  assert_equals "PC-102 --related PC-60 --verify" "$(cat "$LDIR/relations")" "it is linked as related"
  pass "fm-officer-linear: a closed item is never reopened or edited; a recurrence names it"
}

test_closed_item_is_bumped_not_replaced() {
  local out
  world closedbump "$(jq -n --arg fp "$(printf '%s\0%s\0%s' scan job old | sha256sum | cut -d' ' -f1)" \
    '{"PC-60": {title: "Previously closed finding", state: "Done", description: ("Closed by a person.\nfixture-fp:" + $fp)}}')"
  printf '# Fixture rubric\n\n## Settings the code reads\n\n- start-severities: high\n- start-min-score: 1\n' > "$W/fixture-rubric.md"
  out=$(drive closed-bump) || fail "driver must succeed"
  assert_equals "exists PC-60" "$(jq -r '.filing | [.action, .issue] | join(" ")' <<<"$out")" "a repeat of a closed item matches it and files nothing new"
  assert_equals 0 "$(grep -c '^issue create' "$LDIR/calls")" "no new item is created"
  assert_contains "$(issue PC-60 .description)" "Found: 2 times" "the closed item's Found line goes up"
  assert_equals 1 "$(grep '^issue comment PC-60' "$LDIR/calls" | grep -c -- '--verify')" "with one comment"
  assert_equals 0 "$(grep -c -- '--state\|--priority' "$LDIR/calls")" "it is not reopened or re-prioritised"
  assert_equals "true 0" "$(jq -r '[.filing.closed, (.starts | length)] | join(" ")' <<<"$out")" "and a closed match never starts"
  assert_equals 1 "$(jq '.open_starts | length' <<<"$out")" "though the same finding on an open item would"
  pass "fm-officer-linear: with bump_closed a closed item is bumped, never reopened, replaced or started"
}

test_failed_verify_is_taken_as_written() {
  local mode out
  for mode in textappend contract; do
    world "verify-$mode" '{}'
    out=$(FAKE_VERIFY=$mode drive verify-fail) || fail "driver must succeed"
    assert_equals "created PC-101" "$(jq -r '.filing | [.action, .issue] | join(" ")' <<<"$out")" "$mode: a mismatching --verify write is recorded as created"
    assert_equals "PC-101" "$(jq -r '.ledger | to_entries[0].value' <<<"$out")" "$mode: and ledgered"
    assert_equals 1 "$(grep -c '^issue create.*--verify' "$LDIR/calls")" "$mode: and never retried"
  done
  assert_equals 0 "$(sed -n '/^issue create.*--verify/,$p' "$LDIR/calls" | grep -c -- '-fp:')" "after the mismatch the title, not the fingerprint, is what is searched after the mismatch"
  assert_contains "$(grep '^issue search' "$LDIR/calls" | tail -1)" "Lint script crashes on lint.sh" "textappend: the exact-title search ran"
  world verify-nocontract '{}'
  out=$(FAKE_VERIFY=nocontract drive verify-fail) || fail "driver must succeed"
  assert_equals "created PC-101" "$(jq -r '.filing | [.action, .issue] | join(" ")' <<<"$out")" "ok:false without an identifier: the single exact-title hit is used"
  pass "fm-officer-linear: a failed --verify write is found again by data.issue.identifier or exact title, never recorded failed"
}

test_mismatched_create_is_adopted_when_title_search_misses() {
  local out mode
  for mode in nocontract textappend; do
    world "adopt-$mode" '{}'
    out=$(FAKE_VERIFY=$mode FAKE_SEARCH_MISS=1 drive verify-fail) || fail "driver must succeed"
    assert_equals "created PC-101" "$(jq -r '.filing | [.action, .issue] | join(" ")' <<<"$out")" "$mode: full-text search misses the title, the item is still adopted and not recorded failed"
    assert_equals "PC-101" "$(jq -r '.ledger | to_entries[0].value' <<<"$out")" "$mode: and ledgered with its identifier"
    assert_equals 1 "$(grep -c '^issue create.*--verify' "$LDIR/calls")" "$mode: created once"
    assert_equals 0 "$(sed -n '/^issue create.*--verify/,$p' "$LDIR/calls" | grep -c '^issue search')" "$mode: no title lookup goes through issue search"
  done
  world adopt-cluster '{}'
  printf 'scheduled-review\ninfrastructure\n' >> "$LDIR/labels"
  out=$(FAKE_VERIFY=nocontract FAKE_SEARCH_MISS=1 drive cluster-reuse) || fail "driver must succeed"
  assert_equals "bundled:PC-101 bundled:PC-101 bundled:PC-101" "$(jq -r '.filings | map(.[0] + ":" + .[1]) | join(" ")' <<<"$out")" "a mismatched bundle create is adopted"
  out=$(FAKE_SEARCH_MISS=1 drive cluster-reuse) || fail "driver must succeed"
  assert_equals "bundled:PC-101 bundled:PC-101 bundled:PC-101" "$(jq -r '.filings | map(.[0] + ":" + .[1]) | join(" ")' <<<"$out")" "the next run (ledger lost) updates that item"
  assert_equals '["PC-101"]' "$(jq -c '.ids' <<<"$out")" "and creates nothing new"
  assert_equals 1 "$(grep -c '^issue create.*--verify' "$LDIR/calls")" "so only the first run ever created"
  pass "fm-officer-linear: a create that mismatches and whose title full-text search misses is adopted, then updated, never recreated"
}

test_a_create_the_tool_wrote_twice_is_adopted_once() {
  local out
  world double '{}'
  printf 'scheduled-review\ninfrastructure\n' >> "$LDIR/labels"
  out=$(FAKE_VERIFY=nocontract FAKE_SEARCH_MISS=1 FAKE_DOUBLE=1 drive cluster-reuse) || fail "driver must succeed"
  assert_equals "bundled:PC-101 bundled:PC-101 bundled:PC-101" "$(jq -r '.filings | map(.[0] + ":" + .[1]) | join(" ")' <<<"$out")" "two same-title items from one create: the lowest is adopted, nothing is failed"
  assert_equals 1 "$(grep -c '^issue create.*--verify' "$LDIR/calls")" "and the officer sent one create"
  assert_equals 3 "$(jq '[.verify[] | select(test("1 more item\\(s\\) of this title: PC-102$"))] | length' <<<"$out")" "and every finding's filing names the extra item for a person to close"
  pass "fm-officer-linear: a create the tool wrote twice is adopted once and not recorded failed"
}

test_mismatched_creates_count_against_the_cap() {
  local out
  world cap-mismatch '{}'
  out=$(FAKE_VERIFY=nocontract FAKE_SEARCH_MISS=1 drive cap) || fail "driver must succeed"
  assert_equals "created: created: not-filed:over max-creates for this run not-filed:over max-creates for this run" "$(jq -r '.filings | join(" ")' <<<"$out")" "mismatched creates are created and count, the rest say why"
  assert_equals 2 "$(grep -c '^issue create .*--verify' "$LDIR/calls")" "so max-creates still bounds them"
  pass "fm-officer-linear: mismatched creates count against max-creates"
}

test_failed_write_is_failed_and_retried_next_run() {
  local out
  world retry '{}'
  out=$(drive retry-failed) || fail "driver must succeed"
  assert_equals "failed" "$(jq -r '.first.action' <<<"$out")" "a write that did not happen is recorded failed"
  assert_equals "created" "$(jq -r '.second.action' <<<"$out")" "and is filed on the next run, not skipped"
  assert_equals 1 "$(jq '.ledger | length' <<<"$out")" "after which it is ledgered"
  world rate '{}'
  out=$(FAKE_VERIFY=rate drive verify-fail) || fail "driver must succeed"
  assert_equals "RATE_LIMITED" "$(jq -r '.err' <<<"$out")" "a rate limit still stops the run"
  assert_equals 0 "$(sed -n '/^issue create.*--verify/,$p' "$LDIR/calls" | grep -c '^issue search')" "without any search for the item"
  assert_equals "failed" "$(jq -r '.filing.action' <<<"$out")" "and the finding is failed"
  pass "fm-officer-linear: a failed write is retried next run; the rate-limit path is unchanged"
}

test_cluster_reuses_the_oldest_open_item_of_its_title() {
  local out t='Automated findings: infrastructure (code review)'
  world cluster-reuse "$(jq -n --arg t "$t" '{"PC-70": {title: $t, state: "Todo", description: "x"}, "PC-50": {title: $t, state: "Todo", description: "x"},
    "PC-40": {title: $t, state: "Done", description: "x"}}')"
  printf 'scheduled-review\ninfrastructure\n' >> "$LDIR/labels"
  out=$(drive cluster-reuse) || fail "driver must succeed"
  assert_equals "bundled:PC-50 bundled:PC-50 bundled:PC-50" "$(jq -r '.filings | map(.[0] + ":" + .[1]) | join(" ")' <<<"$out")" "the oldest open item is reused"
  assert_equals '["PC-40","PC-50","PC-70"]' "$(jq -c '.ids' <<<"$out")" "no new bundle item is created"
  assert_equals 3 "$(jq -r '.body["PC-50"]' <<<"$out")" "the reused item carries the bundle's findings"
  assert_equals 0 "$(jq -r '.body["PC-70"] + .body["PC-40"]' <<<"$out")" "the other open item and the closed one are untouched"
  pass "fm-officer-linear: a cluster reuses the oldest open item of exactly its title"
}

test_cluster_update_mismatch_is_written_and_no_json_is_failed() {
  local out t='Automated findings: infrastructure (code review)'
  world cluster-update-mismatch "$(jq -n --arg t "$t" '{"PC-50": {title: $t, state: "Todo", description: "x"}}')"
  printf 'scheduled-review\ninfrastructure\n' >> "$LDIR/labels"
  out=$(FAKE_VERIFY=textappend drive cluster-reuse) || fail "driver must succeed"
  assert_equals "bundled:PC-50 bundled:PC-50 bundled:PC-50" "$(jq -r '.filings | map(.[0] + ":" + .[1]) | join(" ")' <<<"$out")" "a mismatching update --verify is recorded bundled"
  assert_equals 3 "$(jq -r '.body["PC-50"]' <<<"$out")" "with the bundle body written"
  assert_equals 1 "$(grep -c '^issue update PC-50.*--verify' "$LDIR/calls")" "and never retried"
  world cluster-update-nojson "$(jq -n --arg t "$t" '{"PC-50": {title: $t, state: "Todo", description: "x"}}')"
  printf 'scheduled-review\ninfrastructure\n' >> "$LDIR/labels"
  out=$(FAKE_VERIFY=nojson drive cluster-reuse) || fail "driver must succeed"
  assert_equals "failed failed failed" "$(jq -r '.filings | map(.[0]) | join(" ")' <<<"$out")" "an update that printed no JSON is failed, not taken as written"
  pass "fm-officer-linear: a mismatching bundle update counts as written; one with no JSON is failed"
}

test_cluster_never_reuses_a_same_title_item_of_the_other_project() {
  local out t='Automated findings: infrastructure (code review)'
  world cluster-cross-project "$(jq -n --arg t "$t" '{"PC-50": {title: $t, state: "Todo", project: "Fleet", description: "x"}}')"
  printf 'scheduled-review\ninfrastructure\n' >> "$LDIR/labels"
  out=$(FAKE_VERIFY=nocontract drive cluster-reuse) || fail "driver must succeed"
  assert_equals "bundled:PC-102 bundled:PC-102 bundled:PC-102" "$(jq -r '.filings | map(.[0] + ":" + .[1]) | join(" ")' <<<"$out")" "a PC bundle creates its own item, even when the create mismatches"
  assert_equals 3 "$(jq -r '.body["PC-102"]' <<<"$out")" "which carries the bundle's findings"
  assert_equals 0 "$(jq -r '.body["PC-50"]' <<<"$out")" "and the same-title Fleet item is untouched"
  assert_equals 0 "$(grep -c '^issue update PC-50' "$LDIR/calls")" "with no update sent to it"
  pass "fm-officer-linear: a PropertyCompass2 bundle never reuses a same-title Fleet item"
}

test_no_call_closes_or_deletes() {
  local all
  dedupe_world audit
  drive dedupe >/dev/null || fail "driver must succeed"
  all=$(calls)
  assert_not_contains "$all" "issue close" "nothing is closed"
  assert_not_contains "$all" "delete" "nothing is deleted"
  assert_equals 0 "$(grep '^issue update' "$LDIR/calls" | grep -c -- '--state\|--priority\|label')" "an update never changes state, priority or labels"
  pass "fm-officer-linear: only search, view, create, update (the Found line), comment and relation are ever called"
}

fold_world() {  # the open items an earlier Surgeon filed one by one, a component cluster, and items it must leave alone
  sfp() { printf 'review\0nightly-review\0%s' "$1" | sha256sum | cut -d' ' -f1; }
  world fold "$(jq -n --arg a "$(sfp a)" --arg b "$(sfp b)" --arg c "$(sfp c)" --arg d "$(sfp d)" --arg e "$(sfp e)" --arg f "$(sfp f)" --arg g "$(sfp g)" --arg h "$(sfp h)" '
    def surgeon($src; $sev; $loc; $fp): "Filed by the Ship'"'"'s Surgeon from the 2026-11-01 \($src) results.\nWhat it is for: a finding no Linear item tracked yet, so it is not lost.\nEpic: not assigned; whoever triages this picks one.\n\nSeverity: \($sev). Source job: job.\nFound: 1 times (first 2026-11-01, last 2026-11-01, by surgeon)\nLocation: \($loc)\nsurgeon-fp:\($fp)";
    {"PC-1": {title: "Null check missing", state: "Todo", project: null, description: surgeon("nightly code review"; "medium"; "src/api/controllers/Foo.cs"; $a)},
     "PC-2": {title: "stamp duty total wrong", state: "Todo", project: null, description: surgeon("nightly E2E"; "high"; "tests/e2e/calculators/stamp.spec.ts"; $b)},
     "PC-3": {title: "Code review findings: infra bicep (infra/bicep)", state: "Todo", project: null,
              description: ("Filed by the Ship'"'"'s Surgeon from the nightly code review results.\nWhat it is for: the lower-severity code-review findings.\n\n- [ ] surgeon-fp:\($c) unpinned one (infra/bicep/a.bicep)\n- [x] surgeon-fp:\($d) fixed one (infra/bicep/b.bicep)\n- [ ] surgeon-fp:\($e) unpinned two (infra/bicep/c.bicep)\nsurgeon-fp:\($h)")},
     "PC-4": {title: "Nightly E2E run invalid: promotion blocked", state: "Todo", project: null,
              description: ("Filed by the Ship'"'"'s Surgeon from the 2026-11-01 nightly E2E results.\n\nSeverity: critical. Source job: nightly-e2e.\nPromotion-blocking: yes. No nightly E2E result can be read until this run is valid again.\nsurgeon-fp:\($f)")},
     "PC-5": {title: "Closed one", state: "Done", project: null, description: surgeon("nightly code review"; "medium"; "src/api/X.cs"; $g)},
     "PC-6": {title: "Duplicate one", state: "Duplicate", project: null, description: surgeon("nightly code review"; "medium"; "src/api/Y.cs"; $g)},
     "PC-7": {title: "Friction: waits on Lee", state: "Todo", project: "Fleet", description: "Filed by the friction officer from the 2026-11-01 friction events.\nfriction-fp:\($g)"},
     "PC-8": {title: "Members cannot log in", state: "Todo", project: null, description: "Reported by a member through support."},
     "PC-10": {title: "Nightly E2E: smoke.spec.ts › home page loads", state: "Todo", project: null, description: "The full E2E run found this test failing."},
     "PC-9": {title: "Unused variable", state: "Todo", project: null, description: surgeon("nightly code review"; "low"; "src/api/controllers/Bar.cs"; $g)}}')"
  printf 'scheduled-review\nbug-sweep\napi\ncalculators\ninfrastructure\ntesting\n' >> "$LDIR/labels"
}

test_fold_dry_run_plans_area_bundles_and_writes_nothing() {
  local out
  fold_world
  out=$(PATH="$FAKEBIN:$PATH" LDIR="$LDIR" python3 -I "$ROOT/bin/fm-officer-surgeon.py" fold --out "$W" --now "$NOW") || fail "fold dry run must succeed: $out"
  assert_contains "$out" "Fold plan (dry run, nothing written): 4 open item(s) the Surgeon made fold into 3 area bundle(s); 5 finding(s), cap 15 a bundle." "the plan counts the items, bundles and findings"
  assert_contains "$out" "- Automated findings: api (code review): 2 finding(s) from 2 item(s) (PC-1, PC-9); 1 new bundle(s)" "single code review items fold into their area bundle"
  assert_contains "$out" "- Automated findings: infrastructure (code review): 2 finding(s) from 1 item(s) (PC-3); 1 new bundle(s)" "a component cluster's open lines fold too, its ticked line left out"
  assert_contains "$out" "- Automated findings: calculators (nightly E2E): 1 finding(s) from 1 item(s) (PC-2); 1 new bundle(s)" "a nightly E2E item folds by the feature in its spec path"
  assert_contains "$out" "- kept: PC-4 (promotion-blocking, kept single)" "an invalid nightly E2E run stays single"
  assert_contains "$out" "- not folded yet: 1 open item(s) filed by the friction officer; this command folds only the Surgeon's" "another officer's items are named and left alone"
  assert_contains "$out" "- not folded yet: 1 open item(s) fleet-app's \"Nightly E2E\" items; this command folds only the Surgeon's" "and so are fleet-app's own families"
  assert_not_contains "$out" "PC-5" "a closed item is never folded"
  assert_not_contains "$out" "PC-6" "nor a Duplicate one"
  assert_not_contains "$out" "PC-8" "nor an item a person filed"
  assert_equals "" "$(grep -v '^label list\|^issue list\|^issue view' "$LDIR/calls")" "a dry run only reads"
  assert_equals 5 "$(grep -c '^issue view' "$LDIR/calls")" "and reads in full only the open items the Surgeon filed"
  [ ! -e "$W/bundles.json" ] || fail "a dry run writes no bundle state"
  pass "fm-officer-surgeon fold: a dry run lists each area bundle's findings and items, keeps the promotion blocker single and writes nothing"
}

fold_apply() {  # [fold args...]: fold --apply in the current world; prints its output.
  PATH="$FAKEBIN:$PATH" LDIR="$LDIR" python3 -I "$ROOT/bin/fm-officer-surgeon.py" fold --out "$W" --now "$NOW" --apply "$@"
}

test_fold_apply_marks_each_item_a_duplicate_of_its_bundle() {
  local out api
  fold_world
  out=$(fold_apply) || fail "fold --apply must succeed: $out"
  api=$(jq -r 'to_entries[] | select(.value.title == "Automated findings: api (code review)") | .key' "$LDIR/issues.json")
  [ -n "$api" ] || fail "the api bundle is created"
  assert_equals "Duplicate Duplicate Duplicate Duplicate" "$(jq -r '[."PC-1", ."PC-9", ."PC-2", ."PC-3"] | map(.state) | join(" ")' "$LDIR/issues.json")" \
    "every folded item is marked Duplicate"
  assert_contains "$(cat "$LDIR/relations")" "PC-1 --duplicate-of $api --verify" "and related as a duplicate of its area bundle"
  assert_contains "$out" "- folded: PC-9 is a duplicate of $api" "the run names each fold"
  assert_equals "Todo Todo Todo" "$(jq -r '[."PC-4", ."PC-7", ."PC-10"] | map(.state) | join(" ")' "$LDIR/issues.json")" \
    "the promotion blocker and other officers' items stay open"
  assert_equals 5 "$(jq -r '.[] | select(.title | startswith("Automated findings")) | .description' "$LDIR/issues.json" | grep -c '^- \[ \]')" \
    "every open line of the folded items is on a bundle"
  assert_not_contains "$(calls)" "delete" "nothing is deleted"
  pass "fm-officer-surgeon fold --apply: each original is related as a duplicate of its area bundle and marked Duplicate"
}

test_fold_apply_keeps_an_item_whose_findings_are_not_all_written() {
  local out
  cfp() { printf 'review\0nightly-review\0%s' "$1" | sha256sum | cut -d' ' -f1; }
  world fold-partial "$(jq -n --arg a "$(cfp a)" --arg b "$(cfp b)" '
    {"PC-1": {title: "Code review findings: mixed (src)", state: "Todo", project: null,
              description: ("Filed by the Ship'"'"'s Surgeon from the nightly code review results.\nWhat it is for: the lower-severity code-review findings.\n\n- [ ] surgeon-fp:\($a) api one (src/api/controllers/Foo.cs)\n- [ ] surgeon-fp:\($b) infra one (infra/bicep/a.bicep)")}}')"
  printf 'scheduled-review\nbug-sweep\napi\ninfrastructure\n' >> "$LDIR/labels"
  out=$(fold_apply --max-creates 1) && fail "a partial fold must exit non-zero: $out"
  assert_equals 1 "$(jq -r '[.[] | select(.title | startswith("Automated findings"))] | length' "$LDIR/issues.json")" "only one bundle fits the create cap"
  assert_contains "$out" "- not folded: PC-1 (not every finding of it is on a written bundle)" "an item with a line on no written bundle is not folded"
  assert_equals "Todo" "$(issue PC-1 .state)" "and stays open, so its unwritten line is not lost"
  [ ! -e "$LDIR/relations" ] || fail "no duplicate relation is written for it"
  pass "fm-officer-surgeon fold --apply: an item is folded only when every one of its findings is on a written bundle"
}

test_a_folded_finding_keeps_raising_its_found_count() {
  local out a
  world bundle-folded '{"PC-50": {"title": "Alpha", "description": "x", "state": "Duplicate", "labels": [], "project": null}}'
  bundle '[["a","Alpha","low","api/a.cs","api"]]' >/dev/null || fail "first run must succeed"
  a=$(printf 'scan\0job\0a' | sha256sum | cut -d' ' -f1)
  jq --arg a "$a" '.[$a] = "PC-50"' "$W/ledger.json" > "$W/l" && mv "$W/l" "$W/ledger.json"
  jq '.issues["PC-50"] = {count: 5, last: "2026-11-01"}' "$W/found.json" > "$W/f" && mv "$W/f" "$W/found.json"
  out=$(bundle '[["a","Alpha","low","api/a.cs","api"]]' RUN_DATE=2026-11-06) || fail "second run must succeed"
  assert_equals 6 "$(jq -r .found.a <<<"$out")" "a finding folded from an item found 5 times is found 6 times on its next day"
  out=$(bundle '[["a","Alpha","low","api/a.cs","api"]]' RUN_DATE=2026-11-07) || fail "third run must succeed"
  assert_equals 7 "$(jq -r .found.a <<<"$out")" "and keeps rising on the bundle"
  pass "fm-officer-linear: a finding folded off its old item keeps that item's found count and keeps raising it"
}

test_a_failed_bundle_update_is_retried_the_same_day() {
  local out
  world bundle-retry '{}'
  bundle '[["a","Alpha","low","api/a.cs","api"]]' >/dev/null || fail "first run must succeed"
  out=$(bundle '[["a","Alpha","low","api/a.cs","api"],["b","Beta","low","api/b.cs","api"]]' RUN_DATE=2026-11-06 FAKE_VERIFY=nowrite) || fail "second run must succeed"
  assert_equals failed "$(jq -r .filings.b.action <<<"$out")" "the failed update is named on the finding"
  assert_not_contains "$(body_of PC-101)" "Beta" "and the line is not on Linear yet"
  out=$(bundle '[["a","Alpha","low","api/a.cs","api"],["b","Beta","low","api/b.cs","api"]]' RUN_DATE=2026-11-06) || fail "rerun must succeed"
  assert_contains "$(body_of PC-101)" "Beta (low)" "a rerun the same day writes the line it reports as bundled"
  assert_equals "bundled PC-101" "$(jq -r '.filings.b | [.action, .issue] | join(" ")' <<<"$out")" "on the same bundle"
  pass "fm-officer-linear: a bundle whose update failed is rewritten by a rerun the same day"
}

bundle() {  # <findings json> [env...]: one bundle run in the current world; prints the result json.
  env FINDINGS="$1" "${@:2}" bash -c "$(declare -f drive); $(declare -p FAKEBIN LDIR W LIB DATE NOW); drive bundle"
}

body_of() { jq -r --arg i "$1" '.[$i].description' "$LDIR/issues.json"; }

test_a_bundle_starts_once_and_a_reserved_line_holds_it() {
  local out
  world bundle-hold '{}'
  printf '## Settings the code reads\n- start-severities: high, critical\n' > "$W/fixture-rubric.md"
  out=$(drive bundle-hold) || fail "driver must succeed"
  assert_equals '[["PC-302","Crash on login"]]' "$(jq -c .starts <<<"$out")" "a bundle starts once, however many of its findings qualify"
  assert_contains "$(jq -r .what <<<"$out")" "fix every open line of its checklist in one pull request" "and asks for the whole checklist in one pull request"
  assert_equals '[["PC-301","Rotate SendGrid API key","credentials"]]' "$(jq -c .held <<<"$out")" \
    "one reserved line holds its whole bundle, though that line is under the start score"
  assert_equals '["fixture-holds-2026-11-05"]' "$(jq -c .asks <<<"$out")" "as one keyed needs-decision"
  pass "fm-officer-linear: a bundle starts once, and a reserved line on it holds the whole bundle for Lee"
}

test_bundle_appends_to_the_open_bundle_and_starts_part_2_at_the_cap() {
  local out
  world bundle-cap '{}'
  out=$(bundle '[["a","Null check missing","medium","api/b.cs","api"],["b","Unused variable","low","api/a.cs","api"],["c","Dead branch","low","api/a.cs","api"]]' CAP=4) \
    || fail "bundle run must succeed"
  assert_equals "bundled PC-101 bundled PC-101 bundled PC-101" "$(jq -r '[.filings.a, .filings.b, .filings.c] | map(.action + " " + .issue) | join(" ")' <<<"$out")" \
    "three findings of one area go to one item"
  assert_equals "Automated findings: api (code review)" "$(issue PC-101 .title)" "the item is titled by area and source family"
  assert_equals "Bug scan triage" "$(issue PC-101 '.labels | join(" ")')" "with one Type, one Source and one area label"
  out=$(bundle '[["a","Null check missing","medium","api/b.cs","api"],["b","Unused variable","low","api/a.cs","api"],["c","Dead branch","low","api/a.cs","api"],["d","Magic number","low","api/c.cs","api"],["e","Long method","low","api/c.cs","api"]]' CAP=4 RUN_DATE=2026-11-06) \
    || fail "second bundle run must succeed"
  assert_equals "PC-101 PC-102" "$(jq -r '[.filings.d.issue, .filings.e.issue] | join(" ")' <<<"$out")" "a new finding is appended to the open bundle, and at the cap the next one opens part 2"
  assert_equals "true true false" "$(jq -r '[.filings.d.new, .filings.e.new, .filings.a.new] | map(tostring) | join(" ")' <<<"$out")" "only the appended findings are new"
  assert_equals "Automated findings: api (code review) part 2" "$(issue PC-102 .title)" "the second part names itself"
  assert_equals 2 "$(grep -c '^issue create .*--verify' "$LDIR/calls")" "two items in all, not one per finding"
  assert_contains "$(body_of PC-101)" "Open: 4 of 4" "the first part holds the cap"
  assert_equals "2 2 1" "$(jq -r '[.found.a, .found.b, .found.d] | map(tostring) | join(" ")' <<<"$out")" "each bundled finding keeps its own found count"
  out=$(bundle '[["a","Null check missing","medium","api/b.cs","api"]]' CAP=4 RUN_DATE=2026-11-07 TICK='["b"]') || fail "tick run must succeed"
  assert_contains "$(body_of PC-101)" "- [x] fixture-fp:$(printf 'scan\0job\0b' | sha256sum | cut -d' ' -f1) Unused variable (low)" "a resolved finding is ticked, not removed"
  assert_contains "$(body_of PC-101)" "Open: 3 of 4" "and frees a place"
  pass "fm-officer-linear: a new finding is appended to its area's open bundle, the cap opens part 2, and a resolved one is ticked"
}

test_bundle_groups_by_area_then_by_file() {
  local out b
  world bundle-order '{}'
  out=$(bundle '[["z","Zeta","low","ui/z.tsx","ui-ux"],["m","Mu","medium","api/m.cs","api"],["a","Alpha","low","ui/a.tsx","ui-ux"],["n","No file","low","","ui-ux"],["k","Kappa","low","api/b.cs","api"]]') \
    || fail "bundle run must succeed"
  assert_equals 2 "$(jq 'keys | length' "$LDIR/issues.json")" "one item per area"
  b=$(jq -r 'to_entries[] | select(.value.title | test("ui-ux")) | .value.description' "$LDIR/issues.json")
  assert_equals "### ui/a.tsx|### ui/z.tsx|### (no file)" "$(grep '^### ' <<<"$b" | paste -sd'|')" "within an area the lines are grouped by file, sorted, the no-file group last"
  assert_contains "$b" "Severity: low. Area: ui-ux." "the severity line names the worst open finding"
  assert_contains "$(jq -r 'to_entries[] | select(.value.title | test("api")) | .value.description' "$LDIR/issues.json")" "Severity: medium. Area: api." "per bundle"
  pass "fm-officer-linear: findings are grouped by feature area first, then by file within the area"
}

test_bundle_keeps_single_items_single() {
  local out
  world bundle-single '{}'
  out=$(bundle '[["s","Run invalid: promotion blocked","critical","e2e","testing",1],["a","Alpha","low","api/a.cs","api"]]') || fail "bundle run must succeed"
  assert_equals "created bundled" "$(jq -r '[.filings.s.action, .filings.a.action] | join(" ")' <<<"$out")" "a single finding gets its own item, a bundled one goes to the area bundle"
  assert_equals "Run invalid: promotion blocked" "$(issue "$(jq -r .filings.s.issue <<<"$out")" .title)" "titled by the finding itself"
  pass "fm-officer-linear: a finding the officer keeps single is filed alone, never bundled"
}

test_bundle_never_writes_a_closed_or_started_bundle() {
  local out
  world bundle-closed '{}'
  bundle '[["a","Alpha","low","api/a.cs","api"]]' >/dev/null || fail "first run must succeed"
  jq '."PC-101".state = "Done"' "$LDIR/issues.json" > "$LDIR/i" && mv "$LDIR/i" "$LDIR/issues.json"
  out=$(bundle '[["a","Alpha","low","api/a.cs","api"],["b","Beta","low","api/b.cs","api"]]' RUN_DATE=2026-11-06) || fail "second run must succeed"
  assert_equals "PC-102 PC-102" "$(jq -r '[.filings.a.issue, .filings.b.issue] | join(" ")' <<<"$out")" "a closed bundle is never reopened: its finding goes to a new open bundle"
  assert_equals "PC-101" "$(jq -r .filings.a.recurrence_of <<<"$out")" "naming the closed one"
  assert_contains "$(body_of PC-102)" "Alpha (low); recurred, was in PC-101" "and the line says so"
  assert_equals 0 "$(grep -c '^issue update PC-101' "$LDIR/calls")" "the closed item is never written"
  jq '."PC-102".state = "In Progress"' "$LDIR/issues.json" > "$LDIR/i" && mv "$LDIR/i" "$LDIR/issues.json"
  out=$(bundle '[["a","Alpha","low","api/a.cs","api"],["b","Beta","low","api/b.cs","api"],["c","Gamma","low","api/c.cs","api"]]' RUN_DATE=2026-11-07) || fail "third run must succeed"
  assert_equals "PC-103" "$(jq -r .filings.c.issue <<<"$out")" "a bundle a worker has started takes no new line: the next part does"
  assert_equals "Automated findings: api (code review) part 2" "$(issue PC-103 .title)" "as part 2"
  pass "fm-officer-linear: a closed bundle is never reopened and a started one takes no new line"
}

test_a_finding_back_after_its_bundle_closed() {
  local out
  world bundle-back '{}'
  bundle '[["a","Alpha","low","api/a.cs","api"],["b","Beta","low","api/b.cs","api"]]' >/dev/null || fail "first run must succeed"
  jq '."PC-101".state = "Done"' "$LDIR/issues.json" > "$LDIR/i" && mv "$LDIR/i" "$LDIR/issues.json"
  bundle '[["b","Beta","low","api/b.cs","api"]]' RUN_DATE=2026-11-06 >/dev/null || fail "second run must succeed"
  out=$(bundle '[["a","Alpha","low","api/a.cs","api"],["b","Beta","low","api/b.cs","api"]]' RUN_DATE=2026-11-07) || fail "third run must succeed"
  assert_equals "PC-102 PC-101" "$(jq -r '.filings.a | [.issue, .recurrence_of] | join(" ")' <<<"$out")" \
    "a finding back on a later run, after its bundle closed, goes to the area's open bundle naming the closed one"
  assert_contains "$(body_of PC-102)" "Alpha (low); recurred, was in PC-101" "and its line says so"
  assert_equals 0 "$(grep -c '^issue update PC-101' "$LDIR/calls")" "the closed bundle is never written"
  world bundle-keep '{}'
  bundle '[["a","Alpha","low","api/a.cs","api"]]' RECUR_CLOSED=0 >/dev/null || fail "first run must succeed"
  jq '."PC-101".state = "Done"' "$LDIR/issues.json" > "$LDIR/i" && mv "$LDIR/i" "$LDIR/issues.json"
  out=$(bundle '[["a","Alpha","low","api/a.cs","api"]]' RECUR_CLOSED=0 RUN_DATE=2026-11-06) || fail "second run must succeed"
  assert_equals "PC-101 true" "$(jq -r '.filings.a | [.issue, .closed] | map(tostring) | join(" ")' <<<"$out")" "with recurrence off, a finding of a closed bundle stays with it"
  out=$(bundle '[["a","Alpha","low","api/a.cs","api"]]' RECUR_CLOSED=0 RUN_DATE=2026-11-07) || fail "third run must succeed"
  assert_equals "PC-101 true" "$(jq -r '.filings.a | [.issue, .closed] | map(tostring) | join(" ")' <<<"$out")" "on every later run too"
  assert_equals 1 "$(grep -c '^issue create .*--verify' "$LDIR/calls")" "and is never filed again"
  pass "fm-officer-linear: a finding back after its bundle closed recurs into the open bundle, or with recurrence off stays closed"
}

test_bundle_lost_state_adopts_the_open_item_by_title() {
  local out
  world bundle-lost '{}'
  bundle '[["a","Alpha","low","api/a.cs","api"],["b","Beta","low","api/b.cs","api"]]' >/dev/null || fail "first run must succeed"
  /usr/bin/trash "$W/bundles.json" "$W/ledger.json"
  out=$(bundle '[["c","Gamma","low","api/c.cs","api"]]' RUN_DATE=2026-11-06) || fail "second run must succeed"
  assert_equals "PC-101" "$(jq -r .filings.c.issue <<<"$out")" "the lane found its open bundle again by exact title"
  assert_equals 1 "$(grep -c '^issue create .*--verify' "$LDIR/calls")" "and created nothing new"
  assert_equals 3 "$(body_of PC-101 | grep -c '^- \[ \]')" "and kept the lines it no longer had in state"
  pass "fm-officer-linear: a lane that lost its bundle state adopts the open item by exact title and keeps its lines"
}

test_duplicate_items_are_closed() {
  local out
  world bundle-legacy '{"PC-7": {"title": "Alpha", "description": "x", "state": "Duplicate", "labels": [], "project": null}}'
  printf '{"%s": "PC-7"}\n' "$(printf 'scan\0job\0a' | sha256sum | cut -d' ' -f1)" > "$W/ledger.json"
  out=$(bundle '[["a","Alpha","low","api/a.cs","api"]]') || fail "bundle run must succeed"
  assert_equals "bundled PC-102 PC-7" "$(jq -r '.filings.a | [.action, .issue, .recurrence_of] | join(" ")' <<<"$out")" \
    "an older single item marked Duplicate counts as closed: the finding goes to its area bundle, naming it"
  assert_equals 0 "$(grep -c '^issue update PC-7' "$LDIR/calls")" "the duplicate is never written"
  world dup-title '{"PC-7": {"title": "Automated findings: api (code review)", "description": "x", "state": "Duplicate", "labels": [], "project": null}}'
  out=$(bundle '[["a","Alpha","low","api/a.cs","api"]]') || fail "bundle run must succeed"
  assert_equals "PC-102" "$(jq -r .filings.a.issue <<<"$out")" "an exact-title lookup never adopts a Duplicate item"
  pass "fm-officer-linear: a Duplicate item is closed for every lookup and ledger check"
}

test_fold_dry_run_plans_area_bundles_and_writes_nothing
test_fold_apply_marks_each_item_a_duplicate_of_its_bundle
test_fold_apply_keeps_an_item_whose_findings_are_not_all_written
test_a_folded_finding_keeps_raising_its_found_count
test_a_failed_bundle_update_is_retried_the_same_day
test_a_bundle_starts_once_and_a_reserved_line_holds_it
test_bundle_appends_to_the_open_bundle_and_starts_part_2_at_the_cap
test_bundle_groups_by_area_then_by_file
test_bundle_keeps_single_items_single
test_bundle_never_writes_a_closed_or_started_bundle
test_a_finding_back_after_its_bundle_closed
test_bundle_lost_state_adopts_the_open_item_by_title
test_duplicate_items_are_closed
test_dedupe_exact_and_near_match
test_found_count_is_raised_in_place_once_a_day
test_score_is_the_found_count_lever
test_cap_overflow_is_listed_and_budget_stops_the_run
test_reserved_class_becomes_one_keyed_needs_decision
test_fleet_findings_take_the_fleet_project_and_label
test_fleet_finding_starts_and_patterns_go_to_the_quartermaster
test_fleet_patterns_route_without_linear_writes
test_surgeon_bundles_split_fleet_from_propertycompass2
test_closed_item_is_never_touched
test_closed_item_is_bumped_not_replaced
test_failed_verify_is_taken_as_written
test_mismatched_create_is_adopted_when_title_search_misses
test_a_create_the_tool_wrote_twice_is_adopted_once
test_mismatched_creates_count_against_the_cap
test_failed_write_is_failed_and_retried_next_run
test_cluster_reuses_the_oldest_open_item_of_its_title
test_cluster_update_mismatch_is_written_and_no_json_is_failed
test_cluster_never_reuses_a_same_title_item_of_the_other_project
test_no_call_closes_or_deletes
