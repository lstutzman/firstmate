"""Write a findings file with PR 5076's own evaluate.review(); the vision model is the only stand-in (no API key)."""
import datetime, importlib.util, json, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("evaluate", sys.argv[1]); ev = importlib.util.module_from_spec(spec); spec.loader.exec_module(ev)
capture, out, state_path, mode, stamp = Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]), sys.argv[5], sys.argv[6]
REPLIES = {
  "/deal-finder|desktop": [{"rubric_item": "contradictory-numbers", "evidence": "Net yield 9% beside net yield 4%", "region": "summary", "severity": "high"}],
  "/deal-finder|mobile": [{"rubric_item": "contradictory-numbers", "evidence": "Net yield 9% beside net yield 4%", "region": "summary", "severity": "medium"}],
  "/portfolio|desktop": [{"rubric_item": "jargon", "evidence": "LTV ICR DSCR", "region": "header", "severity": "high"}],
}
def call(model, image, entry):
    if mode == "fail": raise ev.ReviewError("model call failed: 503")
    k = entry["route"] + "|" + entry["viewport"]
    return ev.ModelReply(json.dumps({"findings": REPLIES.get(k, [])}), 10, 5, 0.0001)
prev = ev.load_state(state_path)
doc, st = ev.review(capture, "https://pc-staging-web.azurewebsites.net", prev, "stub-model", call,
                    now=datetime.datetime.fromisoformat(stamp))
ev.write_json(out, doc); ev.write_json(state_path, {"schema_version": 1, "hashes": st})
print(ev.format_summary(doc))
