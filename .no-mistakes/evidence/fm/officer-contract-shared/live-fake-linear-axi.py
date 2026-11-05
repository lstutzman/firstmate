#!/usr/bin/env python3
# Disposable stand-in for linear-axi: a JSON issue store, every call logged.
import json, os, sys
d = os.environ["LDIR"]; args = sys.argv[1:]
if args[-2:] == ["--output", "json"]: args = args[:-2]
open(os.path.join(d, "calls"), "a").write(" ".join(args) + "\n")
p = os.path.join(d, "issues.json"); issues = json.load(open(p))
def out(x): print(json.dumps({"ok": True, "data": x})); sys.exit(0)
def flag(n): return args[args.index(n) + 1] if n in args else None
dry = "--dry-run" in args
if args[:2] == ["label", "list"]: out({"labels": [{"name": n} for n in ["Bug", "scan", "area:fleet", "triage", "area:infra"]]})
if args[:2] == ["issue", "search"]:
    q = args[2].lower(); w = {x for x in q.replace("-", " ").split() if len(x) > 3}
    out({"issues": [{"identifier": i} for i, v in issues.items() if (q in v["description"].lower() if ":" in q else w & set(v["title"].lower().split()))]})
if args[:2] == ["issue", "view"]:
    v = issues[args[2]]; out({"issue": dict(identifier=args[2], title=v["title"], description=v["description"], state=v["state"], stateType="unstarted")})
if args[:2] == ["issue", "create"]:
    if dry: out({"dryRun": True})
    n = "PC-%d" % (900 + len(issues))
    issues[n] = dict(title=flag("--title"), description=open(flag("--body-file")).read(), state="Todo", priority=flag("--priority"),
                     labels=[args[k + 1] for k, a in enumerate(args) if a == "--label"], project=flag("--project"))
    json.dump(issues, open(p, "w")); out({"issue": {"identifier": n}})
if args[:2] == ["issue", "update"]:
    if dry: out({"dryRun": True})
    issues[args[2]]["description"] = open(flag("--body-file")).read(); json.dump(issues, open(p, "w")); out({"issue": {"identifier": args[2]}})
if args[:2] == ["issue", "comment"]: out({"dryRun": True})
if args[:2] == ["issue", "relation"]: out({"dryRun": True})
print(json.dumps({"ok": False, "error": {"code": "UNKNOWN", "message": " ".join(args)}})); sys.exit(1)
