#!/usr/bin/env bash
# tests/officer-helpers.sh - fixture builders shared by the officer suites.
#
# officer_archive <dir> <date> <spec.json>
#   Builds a session archive in the transcript-archive layout the triage
#   officer reads: by-date/<date>/manifest.json, one claude-code session folder
#   per spec entry (index.json plus transcript.jsonl.gz), and runs.jsonl.
#   The spec is a JSON object {"sessions": [...], "harvested": "<iso>",
#   "records": [...]} where each session has machine, id, first_prompt, cwd and
#   calls: a list of [tool, input, result_text, is_error].
#
# officer_home <dir>: a primary home with private data/ and state/.
# officer_registry <home> <archive> [hosts] [cadence]: one triage officer line.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

officer_archive() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import gzip, json, os, sys
root, date, spec_path = sys.argv[1:4]
spec = json.load(open(spec_path))
manifest = {"date": date, "timezone": "Europe/London", "not_collected": spec.get("not_collected", {}), "sessions": []}
for s in spec.get("sessions", []):
    folder = "claude-code/fixture/%s/%s" % (date[:7], s["id"])
    path = os.path.join(root, folder)
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, "index.json"), "w") as fh:
        json.dump({"session_id": s["id"], "first_prompt": s["first_prompt"], "outcome": None}, fh)
    recs = [{"type": "user", "message": {"content": s["first_prompt"]}}]
    for n, (tool, args, result, is_error) in enumerate(s.get("calls", [])):
        tid = "toolu_%s_%d" % (s["id"], n)
        recs.append({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": tid, "name": tool, "input": args}]}})
        recs.append({"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": tid, "content": result, "is_error": is_error}]}})
    with gzip.open(os.path.join(path, "transcript.jsonl.gz"), "wt") as fh:
        for r in recs:
            fh.write(json.dumps(r) + "\n")
    manifest["sessions"].append({
        "machine": s["machine"], "harness": "claude-code", "name": s["id"], "folder": folder,
        "session_id": s["id"], "project": "fixture", "cwd": s.get("cwd", "/tmp/fixture"),
        "started": date + "T10:00:00Z", "duration_s": 60, "cost_usd": 0.5,
        "tokens": {"input": 10, "output": 20}, "pr_urls": []})
for r in spec.get("records", []):
    manifest["sessions"].append(r)
day = os.path.join(root, "by-date", date)
os.makedirs(day, exist_ok=True)
with open(os.path.join(day, "manifest.json"), "w") as fh:
    json.dump(manifest, fh)
with open(os.path.join(root, "runs.jsonl"), "w") as fh:
    fh.write(json.dumps({"started": spec.get("harvested", date + "T23:59:00+00:00")}) + "\n")
PY
}

officer_home() {
  mkdir -p "$1/data" "$1/state"
  chmod 700 "$1/state"
}

officer_registry() {  # <home> <archive> [hosts] [cadence]
  printf -- '- triage - Joins archived sessions to firstmate tasks and outcomes (role: triage; cadence: %s; archive: %s; hosts: %s; model: none; added 2026-10-24)\n' \
    "${4:-daily 06:00}" "$2" "${3:-alpha}" > "$1/data/officers.md"
}

# officer_worker_brief <home> <task>: the first tool result a worker reads.
officer_worker_brief() {
  # shellcheck disable=SC2016 # the backticks are literal brief text.
  printf 'FIRSTMATE_OP: v1 launch-brief: # Current worker role contract\nYour steering inbox is `%s/state/%s.inbox`; read it.\n' "$1" "$2"
}
