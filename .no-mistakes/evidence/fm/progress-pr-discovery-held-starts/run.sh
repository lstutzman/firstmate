. "$(dirname "$0")/driver.sh"
show() {  # <label>
  local f="$WORLD_HOME/data/officers/progress/$DATE.json" lane="$WORLD_HOME/data/officers/progress"
  echo "=== $1"
  echo "real PR listing calls: $(grep -c '^REAL' "$WORLD/calls")"
  echo "start_requests: $(jq -c '[.start_requests[] | .issue // .id // .key // .]' "$f" | head -c 300)"
  echo "coverage (Starts/PR lines):"; jq -r '.coverage[] | select(test("Starts held|PR discovery|open PR"))' "$f"
  echo "run log PR lines:"; grep 'open PR listing' "$lane/.run.err" || echo "(none)"
  echo "token leaked? $(grep -rl 'ghp_FAKE' "$lane" "$f" 2>/dev/null | wc -l) files"
}
live_world live-clean; run_progress >/dev/null 2>&1; echo "exit=$?"; show 'A clean live listing of lstutzman/firstmate'
live_world live-transient; echo 1 > "$WORLD/fail-count"; run_progress >/dev/null 2>&1; echo "exit=$?"; show 'B one transient failure then real listing'
live_world live-persistent; echo 2 > "$WORLD/fail-count"; run_progress >/dev/null 2>&1; echo "exit=$?"; show 'C two failures (persistent)'
live_world live-ids; run_progress >/dev/null 2>&1; echo "exit=$?"
p="$WORLD_HOME/data/officers/progress/progress-state.json"
echo "=== D page ids, run 1"; jq -c '{doing:[.doing[]|{id,started_at,link}],done:[.done[]|{id,at}]}' "$p"
before=$(jq -c '[.doing[].id,.done[].id]|sort' "$p"); NOW=$((NOW+300)); run_progress >/dev/null 2>&1; echo "exit=$?"
echo "=== D page ids, run 2 (5 min later)"; jq -c '{doing:[.doing[]|{id,started_at}],done:[.done[]|{id,at}]}' "$p"
echo "ids unique doing/done: $(jq '[.doing[].id]|unique|length' "$p")/$(jq '.doing|length' "$p") $(jq '[.done[].id]|unique|length' "$p")/$(jq '.done|length' "$p")"
echo "ids stable across runs: $([ "$before" = "$(jq -c '[.doing[].id,.done[].id]|sort' "$p")" ] && echo yes || echo NO)"
cp "$p" "$(dirname "$0")/progress-state.json"
