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
                     "stateType": "completed" if v["state"] == "Done" else "unstarted"}
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
                   "state": v["state"], "project": v.get("project"), "stateType": "completed" if v["state"] == "Done" else "unstarted"}})
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
    issues[args[2]]["description"] = open(flag("--body-file")).read()
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
    args = argparse.Namespace(now=now, team="PC", triage_label="triage", max_creates=100)
    surgeon.file_findings(fs, args, date, W, state, {}, surgeon.lib.Jev(os.path.join(W, "jev.py")), [])
    issues = json.load(open(os.path.join(os.environ["LDIR"], "issues.json")))
    def marker(job, key):
        return hashlib.sha256(("review\0%s\0%s" % (job, key)).encode("utf-8")).hexdigest()
    res = {"filings": {f["key"]: [f["filing"]["action"], f["filing"].get("issue"), f["filing"].get("reason")] for f in fs},
           "items": {i: {"title": v["title"], "labels": v["labels"], "project": v["project"], "tail": v["description"].rsplit("\n", 1)[-1]}
                     for i, v in issues.items()},
           "clusters": {c["key"] + "|" + c.get("project", ""): sorted(c) for c in state["clusters"].values()},
           "markers": {k: marker(j, k) for k, j in (("infra/bicep", "cluster"),)}}
    res["markers"]["fleet"] = marker("cluster-fleet", "infra/bicep")
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
    args = argparse.Namespace(now=now, team="PC", triage_label="triage", max_creates=100)
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

test_surgeon_clusters_split_fleet_from_propertycompass2() {
  local out pc fleet
  world surgeon-clusters '{}'
  printf 'scheduled-review\n' >> "$LDIR/labels"
  out=$(drive surgeon-clusters) || fail "driver must succeed"
  pc=$(jq -r '.filings.p0[1]' <<<"$out"); fleet=$(jq -r '.filings.f0[1]' <<<"$out")
  assert_equals "clustered clustered clustered" "$(jq -r '[.filings.p0, .filings.p1, .filings.p2] | map(.[0]) | join(" ")' <<<"$out")" "PropertyCompass2 low review findings are clustered"
  assert_equals 1 "$(jq -r --arg i "$pc" '[.filings | to_entries[] | select(.value[1] == $i)] | length / 3' <<<"$out")" "all three PropertyCompass2 findings share one item"
  assert_equals "clustered clustered clustered" "$(jq -r '[.filings.f0, .filings.f1, .filings.f2] | map(.[0]) | join(" ")' <<<"$out")" "fleet-repository low findings are clustered too, not filed singly"
  assert_not_contains "$pc" "$fleet" "a fleet finding in the same path never joins the PropertyCompass2 cluster"
  assert_equals 2 "$(jq '.items | length' <<<"$out")" "two cluster items, one per side"
  assert_equals '{"title":"Code review findings: infra bicep (infra/bicep)","labels":["Bug","scheduled-review","triage"],"project":null}' \
    "$(jq -c --arg i "$pc" '.items[$i] | {title, labels, project}' <<<"$out")" "the PropertyCompass2 cluster keeps its title, its own area label and no Linear project"
  assert_equals "surgeon-fp:$(jq -r '.markers["infra/bicep"]' <<<"$out")" "$(jq -r --arg i "$pc" '.items[$i].tail' <<<"$out")" "and its fingerprint is sha256(review, cluster, key), as before"
  assert_equals '["key","members","recurrence","sha"]' "$(jq -c '.clusters["infra/bicep|"]' <<<"$out")" "its saved state has no project field"
  assert_equals '{"labels":["Bug","scheduled-review","area:fleet"],"project":"Fleet"}' \
    "$(jq -c --arg i "$fleet" '.items[$i] | {labels, project}' <<<"$out")" "the fleet cluster is in the Fleet project with area:fleet"
  assert_equals "surgeon-fp:$(jq -r '.markers.fleet' <<<"$out")" "$(jq -r --arg i "$fleet" '.items[$i].tail' <<<"$out")" "with its own fingerprint"
  pass "fm-officer-linear: the Surgeon clusters fleet low findings apart, in the Fleet project with area:fleet; PropertyCompass2 clusters are unchanged"
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
  printf 'scheduled-review\n' >> "$LDIR/labels"
  out=$(FAKE_VERIFY=nocontract FAKE_SEARCH_MISS=1 drive cluster-reuse) || fail "driver must succeed"
  assert_equals "clustered:PC-101 clustered:PC-101 clustered:PC-101" "$(jq -r '.filings | map(.[0] + ":" + .[1]) | join(" ")' <<<"$out")" "a mismatched cluster create is adopted"
  out=$(FAKE_SEARCH_MISS=1 drive cluster-reuse) || fail "driver must succeed"
  assert_equals "clustered:PC-101 clustered:PC-101 clustered:PC-101" "$(jq -r '.filings | map(.[0] + ":" + .[1]) | join(" ")' <<<"$out")" "the next run (ledger lost) updates that item"
  assert_equals '["PC-101"]' "$(jq -c '.ids' <<<"$out")" "and creates nothing new"
  assert_equals 1 "$(grep -c '^issue create.*--verify' "$LDIR/calls")" "so only the first run ever created"
  pass "fm-officer-linear: a create that mismatches and whose title full-text search misses is adopted, then updated, never recreated"
}

test_a_create_the_tool_wrote_twice_is_adopted_once() {
  local out
  world double '{}'
  printf 'scheduled-review\n' >> "$LDIR/labels"
  out=$(FAKE_VERIFY=nocontract FAKE_SEARCH_MISS=1 FAKE_DOUBLE=1 drive cluster-reuse) || fail "driver must succeed"
  assert_equals "clustered:PC-101 clustered:PC-101 clustered:PC-101" "$(jq -r '.filings | map(.[0] + ":" + .[1]) | join(" ")' <<<"$out")" "two same-title items from one create: the lowest is adopted, nothing is failed"
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
  local out t='Code review findings: infra bicep (infra/bicep)'
  world cluster-reuse "$(jq -n --arg t "$t" '{"PC-70": {title: $t, state: "Todo", description: "x"}, "PC-50": {title: $t, state: "Todo", description: "x"},
    "PC-40": {title: $t, state: "Done", description: "x"}}')"
  printf 'scheduled-review\n' >> "$LDIR/labels"
  out=$(drive cluster-reuse) || fail "driver must succeed"
  assert_equals "clustered:PC-50 clustered:PC-50 clustered:PC-50" "$(jq -r '.filings | map(.[0] + ":" + .[1]) | join(" ")' <<<"$out")" "the oldest open item is reused"
  assert_equals '["PC-40","PC-50","PC-70"]' "$(jq -c '.ids' <<<"$out")" "no new cluster item is created"
  assert_equals 3 "$(jq -r '.body["PC-50"]' <<<"$out")" "the reused item carries the cluster's findings"
  assert_equals 0 "$(jq -r '.body["PC-70"] + .body["PC-40"]' <<<"$out")" "the other open item and the closed one are untouched"
  pass "fm-officer-linear: a cluster reuses the oldest open item of exactly its title"
}

test_cluster_update_mismatch_is_written_and_no_json_is_failed() {
  local out t='Code review findings: infra bicep (infra/bicep)'
  world cluster-update-mismatch "$(jq -n --arg t "$t" '{"PC-50": {title: $t, state: "Todo", description: "x"}}')"
  printf 'scheduled-review\n' >> "$LDIR/labels"
  out=$(FAKE_VERIFY=textappend drive cluster-reuse) || fail "driver must succeed"
  assert_equals "clustered:PC-50 clustered:PC-50 clustered:PC-50" "$(jq -r '.filings | map(.[0] + ":" + .[1]) | join(" ")' <<<"$out")" "a mismatching update --verify is recorded clustered"
  assert_equals 3 "$(jq -r '.body["PC-50"]' <<<"$out")" "with the cluster body written"
  assert_equals 1 "$(grep -c '^issue update PC-50.*--verify' "$LDIR/calls")" "and never retried"
  world cluster-update-nojson "$(jq -n --arg t "$t" '{"PC-50": {title: $t, state: "Todo", description: "x"}}')"
  printf 'scheduled-review\n' >> "$LDIR/labels"
  out=$(FAKE_VERIFY=nojson drive cluster-reuse) || fail "driver must succeed"
  assert_equals "failed failed failed" "$(jq -r '.filings | map(.[0]) | join(" ")' <<<"$out")" "an update that printed no JSON is failed, not taken as written"
  pass "fm-officer-linear: a mismatching cluster update counts as written; one with no JSON is failed"
}

test_cluster_never_reuses_a_same_title_item_of_the_other_project() {
  local out t='Code review findings: infra bicep (infra/bicep)'
  world cluster-cross-project "$(jq -n --arg t "$t" '{"PC-50": {title: $t, state: "Todo", project: "Fleet", description: "x"}}')"
  printf 'scheduled-review\n' >> "$LDIR/labels"
  out=$(FAKE_VERIFY=nocontract drive cluster-reuse) || fail "driver must succeed"
  assert_equals "clustered:PC-102 clustered:PC-102 clustered:PC-102" "$(jq -r '.filings | map(.[0] + ":" + .[1]) | join(" ")' <<<"$out")" "a PC cluster creates its own item, even when the create mismatches"
  assert_equals 3 "$(jq -r '.body["PC-102"]' <<<"$out")" "which carries the cluster's findings"
  assert_equals 0 "$(jq -r '.body["PC-50"]' <<<"$out")" "and the same-title Fleet item is untouched"
  assert_equals 0 "$(grep -c '^issue update PC-50' "$LDIR/calls")" "with no update sent to it"
  pass "fm-officer-linear: a PropertyCompass2 cluster never reuses a same-title Fleet item"
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

test_dedupe_exact_and_near_match
test_found_count_is_raised_in_place_once_a_day
test_score_is_the_found_count_lever
test_cap_overflow_is_listed_and_budget_stops_the_run
test_reserved_class_becomes_one_keyed_needs_decision
test_fleet_findings_take_the_fleet_project_and_label
test_fleet_finding_starts_and_patterns_go_to_the_quartermaster
test_fleet_patterns_route_without_linear_writes
test_surgeon_clusters_split_fleet_from_propertycompass2
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
