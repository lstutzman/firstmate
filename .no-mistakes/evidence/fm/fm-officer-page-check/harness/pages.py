import json, os, sys, time
d, now = sys.argv[1], int(sys.argv[2])
os.makedirs(d, exist_ok=True)
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
H = 3600
def w(name, doc): json.dump(doc, open(os.path.join(d, name), "w"))
w("_api_captains-log", {"at": iso(now - H), "value": {"updated": iso(now - H), "cards": [
  {"id": "fresh-ask", "band": "now", "question": "Pick the logo colour", "advice": "a", "replies": ["a"], "asked": iso(now - 2*H), "state": "asked"},
  {"id": "bosun-cleanup", "band": "now", "question": "Bosun: approve deleting 475 stale branches and worktrees?", "advice": "yes", "replies": ["yes"], "asked": iso(now - 3*H), "state": "asked"},
  {"id": "staging-flag", "band": "now", "question": "Turn the export feature flag on in staging?", "advice": "yes", "replies": ["yes"], "asked": iso(now - 3*H), "state": "asked"},
  {"id": "ten-days-old", "band": "now", "question": "Which font for invoices?", "advice": "a", "replies": ["a"], "asked": iso(now - 10*86400), "state": "asked"},
  {"id": "snooze-over", "band": "later", "question": "Revisit the mobile export", "advice": "a", "replies": ["a"], "asked": iso(now - 9*86400), "state": "snoozed", "until": iso(now - 3*86400)},
  {"id": "merged-pr", "band": "now", "question": "Merge https://github.com/lstutzman/firstmate/pull/49 ?", "advice": "a", "replies": ["a"], "asked": iso(now - 2*H), "state": "asked"},
  {"id": "answered-still-shown", "band": "now", "question": "Sign off on the banner?", "advice": "a", "replies": ["a"], "asked": iso(now - 2*H), "state": "asked", "answer": {"text": "yes", "at": iso(now - H)}},
  {"id": "bosun-ep", "band": "now", "question": "Bosun asks about an episode", "advice": "a", "replies": ["a"], "asked": iso(now - 5*H), "state": "asked"}]}})
w("_api_captains-log_facts_source_bosun", {"source": "bosun", "cards": [{"id": "bosun-ep", "lifecycle": "closed"}]})
w("_api_top-of-mind", {"homes": [{"home": "main", "observed_at": iso(now - H)}]})
w("_api_progress-officer", {"value": {"state": {"written_at": iso(now - 10*H), "stale_after_minutes": 2880}}})
w("_api_cost-cycle", {"sources": {"workers": {"homes": [{"observed_at": iso(now - 7*H)}]}, "prs": {"observed_at": iso(now - 7*H)}, "usage": {"observed_at": iso(now - 7*H)}}})
w("_api_ideation", {"value": {"generated_at": iso(now - 5*H)}})
w("_api_velocity-audit", {"value": {"generated_at": iso(now - 5*H)}})
w("_api_business-health", {"value": {"generated_at": iso(now - 3*86400)}})
w("_api_runs", {"jobs": [{"id": "ok-job", "state": "live", "health": "working"}, {"id": "bosun-maintenance", "label": "Bosun maintenance", "officer": "bosun", "state": "live", "health": "failing", "nextDueAt": iso(now + 86400)}]})
w("_api_runs_bosun-maintenance_results", {"runs": [{"run": {"startedAt": iso(now - 40*H)}}]})
w("_api_health", {"status": "ok"})
