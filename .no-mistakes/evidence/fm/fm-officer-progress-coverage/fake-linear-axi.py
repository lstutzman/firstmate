#!/usr/bin/env python3
# Disposable Linear CLI stand-in: 541 open PC issues, cursor pages, default 30-item page.
import json, os, sys
a = sys.argv[1:]
w = os.environ["LAB"]
open(w + "/calls", "a").write(" ".join(a) + "\n")
def opt(f, d=None): return a[a.index(f) + 1] if f in a else d
mode = open(w + "/mode").read().strip() if os.path.exists(w + "/mode") else "ok"
types = ["triage", "backlog", "unstarted", "started"]
issues = []
for n in range(1000, 1700 if mode == "manybugs" else 1541):
    t = types[n % 4]
    title = ("Bug: crash %d" % n) if (n % 7 == 0 or mode == "manybugs") else ("Tidy %d" % n)
    issues.append({"identifier": "PC-%d" % n, "title": title, "state": t.title(), "stateType": t,
                   "priority": n % 4, "url": "https://linear.app/x/PC-%d" % n, "project": "",
                   "description": "plain"})
if a[:2] == ["issue", "list"]:
    if mode == "secret-fail":
        sys.stderr.write("Authorization: lin_api_SECRETTOKEN123\n")
        print(json.dumps({"ok": False, "error": {"code": "UNKNOWN", "message": "Too Many Requests key=lin_api_SECRETTOKEN123"}})); sys.exit(1)
    state = opt("--state"); unb = "--unblocked" in a
    pool = [i for i in issues if i["stateType"] == state]
    if unb and mode != "manybugs": pool = [i for i in pool if int(i["identifier"][3:]) % 5]
    limit = int(opt("--limit", "30")); start = int(opt("--after", "0"))
    if mode == "ratelimit" and start >= 100:
        print(json.dumps({"ok": False, "error": {"code": "RATE_LIMITED", "message": "slow down"}})); sys.exit(1)
    page = pool[start:start + limit]
    print(json.dumps({"ok": True, "data": {"issues": page, "pagination": {
        "hasNextPage": start + limit < len(pool), "endCursor": str(start + limit)}}}))
elif a[:2] == ["issue", "view"]:
    ident = a[2]
    found = [i for i in issues if i["identifier"] == ident]
    e = dict(found[0]) if found else {"identifier": ident, "title": "Requested root", "state": "Done", "stateType": "completed"}
    e["parent"] = None
    print(json.dumps({"ok": True, "data": {"issue": e, "subIssues": []}}))
else:
    sys.exit(99)
