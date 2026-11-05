import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("lib", sys.argv[1]); lib = importlib.util.module_from_spec(spec); sys.modules["lib"] = lib; spec.loader.exec_module(lib)
D = sys.argv[2]; date = "2026-11-05"
officer = lib.Officer("live", "Live Officer", "Live", os.path.join(D, "rubric.md"), sources=("scan",), pattern_sources=("scan",), project="Fleet")
def find(k, t, sev="medium", project=""):
    f = lib.make_finding("scan", "job", k, t, t + " summary", "real", sev, None, {}, location="bin/fm-bosun.sh", project=project); f["found"] = 1; return f
labels = lambda f: (["Bug", "scan", "area:infra"], [])   # deliberately NOT area:fleet
def describe(f, near=None, recurrence=None):
    s = ["Filed by Live.", officer.found_line(1, date, date)] + ([recurrence] if recurrence else []) + (["Near: %s %.2f" % near] if near else [])
    return "\n".join(s) + "\nlive-fp:%s" % f["fingerprint"]
lin = lib.Linear(450); jev = lib.Jev(os.path.expanduser("~/.claude/skills/local-jev/jev.py"))
fl = lib.Filer(officer, lin, "PC", date, os.path.join(D, "out"), {}, {}, jev, 5)
dup = find("dup", "Bosun crashes checking backups if backup dir does not exist", "high")
pay = find("pay", "Update the payment refund flow for direct debit", "critical")
newf = find("new", "Ghostty pane title drops unicode", "high")
pc = find("pc", "Null reference when saving deal notes", "high", project="PropertyCompass2")
bulk = [find("b%02d" % i, "Distinct volume finding %s" % w) for i, w in enumerate("alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima".split())]
allf = [dup, pay, newf, pc] + bulk
for f in allf: fl.file_single(f, labels, describe)
fl.settle_bumps(labels, describe)
for f in allf: f["score"] = lib.score_of(f)
rub = lib.load_rubric(officer.rubric_file, officer)
offices = [lib.progress.parse_office("~"), lib.progress.parse_office("~,skills=quartermaster")]
starts, held, asks = lib.plan_starts(officer, allf, rub, date, "linear", "~", offices, {})
print(json.dumps({"filings": {f["key"]: f["filing"] for f in allf}, "not_filed": lib.not_filed_lines(allf), "jev_gap": jev.gap, "jev_calls": jev.calls,
  "starts": [[s["title"], s["execute"]["env"]["FM_HOME"], s["project"], s["linear_only"]] for s in starts],
  "held": [[h["title"], h["class"]] for h in held], "asks": asks, "rubric_gaps": rub.gaps,
  "issues": json.load(open(os.path.join(D, "l", "issues.json")))}, indent=1, default=str))
