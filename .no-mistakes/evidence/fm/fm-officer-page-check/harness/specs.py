import json, sys, os
S = sys.argv[1]
def mk(name, msgs):
    raw = [{"type": "user", "timestamp": t, "message": {"content": c}} for t, c in msgs]
    json.dump({"sessions": [{"machine": "slartibartfast", "id": name, "first_prompt": "hello", "calls": [], "raw": raw}]}, open(os.path.join(S, name + ".json"), "w"))
mk("d22", [("2026-10-22T09:00:00.000Z", "Please keep the captain's log up to date."),
           ("2026-10-22T10:00:00.000Z", "I want you to keep the Bosun page up to date.")])
mk("d30", [("2026-10-30T09:00:00.000Z", "I just want to make sure that the captain's log, uh, keeper agent is looking at all pages and not just certain ones."),
           ("2026-10-30T09:30:00.000Z", "Make sure the captain's log renders on mobile.")])
mk("d31", [("2026-10-31T13:08:00.000Z", "I'm constantly having to come back and say, hey, keep the captain's log up to date."),
           ("2026-10-31T13:20:00.000Z", "I want to make sure the velocity page is current.")])
for d in range(23, 30):
    json.dump({"sessions": []}, open(os.path.join(S, "e%d.json" % d), "w"))
