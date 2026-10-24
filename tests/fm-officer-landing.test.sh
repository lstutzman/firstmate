#!/usr/bin/env bash
# Behavior tests for the landing (records) officer, driven through
# bin/fm-officer.sh run with a landing-truth facts fixture of the fleet-app
# job's documented shape and a fake linear-axi that records every call.
#
# Covers: A1 (Done, a linked PR never on main or in any release, reopened;
# Done on main awaiting release, reported only; Done with no fact naming it), B1 (in production but not Done; on staging but before In
# Staging), no Linear writes unless the registry turns them on, closing only
# fully landed items with an evidence comment through --dry-run then --verify,
# the sub-issue and changed-state guards, the per-run close cap, no write
# from stale or undated facts, facts read over ssh, and refusal of a facts
# file of another schema or layout.
set -u

# shellcheck source=tests/officer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/officer-helpers.sh"

OFFICER="$ROOT/bin/fm-officer.sh"
TMP_ROOT=$(fm_test_tmproot fm-officer-landing)
DATE=2026-10-23

write_facts() {  # <file>
  cat > "$1" <<'JSON'
{"schema_version": 2, "generated_at": "2026-10-23T23:40:00Z", "staging_sha": "aaaa1111", "production_sha": "bbbb2222",
 "records": {
  "lstutzman/PropertyCompass2#101": {"repo": "lstutzman/PropertyCompass2", "pr": 101, "head_sha": "h101", "merged_sha": "m101", "merged_at": "2026-10-20T10:00:00Z",
   "on_staging": true, "staging_deployed": true, "on_main": true, "main_promoted_at": "2026-10-20T15:00:00Z", "in_production": true, "production_release": "v1.71.0",
   "linear_ids": ["PC-1"], "linear_state": {"PC-1": "In Staging"}, "landed_via": "pile-1020"},
  "lstutzman/PropertyCompass2#102": {"repo": "lstutzman/PropertyCompass2", "pr": 102, "head_sha": "h102", "merged_sha": "m102", "merged_at": "2026-10-21T10:00:00Z",
   "on_staging": true, "staging_deployed": true, "on_main": false, "main_promoted_at": null, "in_production": false, "production_release": null,
   "linear_ids": ["PC-2"], "linear_state": {"PC-2": "Done"}, "landed_via": "lone"},
  "lstutzman/PropertyCompass2#103": {"repo": "lstutzman/PropertyCompass2", "pr": 103, "head_sha": "h103", "merged_sha": "m103", "merged_at": "2026-10-22T10:00:00Z",
   "on_staging": true, "staging_deployed": false, "on_main": false, "main_promoted_at": null, "in_production": false, "production_release": null,
   "linear_ids": ["PC-3"], "linear_state": {"PC-3": "Backlog"}, "landed_via": "lone"},
  "lstutzman/PropertyCompass2#104": {"repo": "lstutzman/PropertyCompass2", "pr": 104, "head_sha": "h104", "merged_sha": "m104", "merged_at": "2026-10-19T10:00:00Z",
   "on_staging": true, "staging_deployed": true, "on_main": true, "main_promoted_at": "2026-10-19T15:00:00Z", "in_production": true, "production_release": "v1.70.2",
   "linear_ids": ["PC-4"], "linear_state": {"PC-4": "Done"}, "landed_via": "lone"},
  "lstutzman/PropertyCompass2#105": {"repo": "lstutzman/PropertyCompass2", "pr": 105, "head_sha": "h105", "merged_sha": "m105", "merged_at": "2026-10-19T11:00:00Z",
   "on_staging": true, "staging_deployed": true, "on_main": true, "main_promoted_at": "2026-10-19T15:00:00Z", "in_production": true, "production_release": "v1.70.2",
   "linear_ids": ["PC-5"], "linear_state": {"PC-5": "In Progress"}, "landed_via": "lone"},
  "lstutzman/PropertyCompass2#106": {"repo": "lstutzman/PropertyCompass2", "pr": 106, "head_sha": "h106", "merged_sha": "m106", "merged_at": "2026-10-23T10:00:00Z",
   "on_staging": true, "staging_deployed": true, "on_main": true, "main_promoted_at": "2026-10-23T15:17:00Z", "in_production": false, "production_release": null,
   "linear_ids": ["PC-7"], "linear_state": {"PC-7": "Done"}, "landed_via": "pile-1023"},
  "lstutzman/PropertyCompass2#107": {"repo": "lstutzman/PropertyCompass2", "pr": 107, "head_sha": "h107", "merged_sha": "m107", "merged_at": "2026-10-18T10:00:00Z",
   "on_staging": true, "staging_deployed": true, "on_main": true, "main_promoted_at": "2026-10-18T15:00:00Z", "in_production": true, "production_release": "v1.70.1",
   "linear_ids": ["PC-10", "PC-11"], "linear_state": {"PC-10": "Done", "PC-11": "In Review"}, "landed_via": "lone"}
 },
 "items": {"PC-1": ["lstutzman/PropertyCompass2#101"], "PC-2": ["lstutzman/PropertyCompass2#102"], "PC-3": ["lstutzman/PropertyCompass2#103"],
  "PC-4": ["lstutzman/PropertyCompass2#104"], "PC-5": ["lstutzman/PropertyCompass2#105"], "PC-7": ["lstutzman/PropertyCompass2#106"],
  "PC-10": ["lstutzman/PropertyCompass2#107"], "PC-11": ["lstutzman/PropertyCompass2#107"]}}
JSON
}

# fake_linear <fakebin> <log>: a linear-axi that answers from fixed data and
# logs every call; PC-5 has a sub-issue, PC-1 is still In Staging.
fake_linear() {
  cat > "$1/linear-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$2"
case "\$1 \$2" in
  "issue list") echo '{"ok":true,"data":{"issues":[{"identifier":"PC-2"},{"identifier":"PC-4"},{"identifier":"PC-9"}]}}' ;;
  "issue view")
    case "\$3" in
      PC-2) echo '{"ok":true,"data":{"issue":{"identifier":"PC-2","state":"Done"},"subIssues":[]}}' ;;
      PC-1) echo '{"ok":true,"data":{"issue":{"identifier":"PC-1","state":"In Staging"},"subIssues":[]}}' ;;
      PC-5) echo '{"ok":true,"data":{"issue":{"identifier":"PC-5","state":"In Progress"},"subIssues":[{"identifier":"PC-6"}]}}' ;;
      *) echo '{"ok":true,"data":{"issue":{"identifier":"'"\$3"'","state":"Todo"},"subIssues":[]}}' ;;
    esac ;;
  *) echo '{"ok":true,"data":{}}' ;;
esac
SH
  chmod +x "$1/linear-axi"
}

landing_registry() {  # <home> <facts> [writes]: no writes argument leaves the field out.
  local writes=''
  [ -z "${3:-}" ] || writes="writes: $3; "
  printf -- '- landing - Reconciles Linear against landing evidence (role: landing; cadence: daily 06:30; facts: %s; team: PC; %smodel: none; added 2026-10-24)\n' \
    "$2" "$writes" > "$1/data/officers.md"
}

# make_world <name> [writes]: sets WORLD_HOME, FAKEBIN, and LINEAR_LOG.
make_world() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  officer_home "$home"
  write_facts "$TMP_ROOT/$name/facts.json"
  landing_registry "$home" "$TMP_ROOT/$name/facts.json" "${2:-}"
  FAKEBIN=$(fm_fakebin "$TMP_ROOT/$name")
  LINEAR_LOG="$TMP_ROOT/$name/linear.calls"
  fake_linear "$FAKEBIN" "$LINEAR_LOG"
  WORLD_HOME=$home
}

# The facts were generated at 23:40Z; the run is at 06:30Z the next day.
NOW=1792823400

run_landing() {  # <home> [now]
  PATH="$FAKEBIN:$PATH" FM_OFFICER_NOW="${2:-$NOW}" FM_HOME="$1" "$OFFICER" run landing --date "$DATE"
}

finding() {  # <json> <item> -> class
  jq -r --arg i "$2" '[.findings[] | select(.item == $i) | .class] | join(",")' "$1"
}

test_classes_from_facts() {
  local home json
  make_world classes none; home=$WORLD_HOME
  run_landing "$home" >/dev/null || fail "landing run must succeed"
  json="$home/data/officers/landing/$DATE.json"
  assert_equals B1 "$(finding "$json" PC-1)" "in production but In Staging is false not-done"
  assert_equals A1 "$(finding "$json" PC-2)" "Done but never on main or in any release is false done"
  assert_equals A1 "$(finding "$json" PC-7)" "Done but on main and not yet in production is reported"
  assert_equals low "$(jq -r '.findings[] | select(.item == "PC-7") | .severity' "$json")" "release lag is not actionable"
  assert_equals null "$(jq -r '.items[] | select(.item == "PC-7") | .correction' "$json")" "release lag proposes no correction"
  assert_equals B1 "$(finding "$json" PC-3)" "on staging while Backlog is status lag"
  assert_equals "" "$(finding "$json" PC-4)" "Done and in production is consistent"
  assert_equals "" "$(finding "$json" PC-10)" "a PR's state for one of its ids is read for that id"
  assert_equals B1 "$(finding "$json" PC-11)" "the same PR's other id keeps its own state"
  assert_equals A1 "$(finding "$json" PC-9)" "Done with no landing fact is raised for a person"
  assert_equals "In Progress" "$(jq -r '.items[] | select(.item == "PC-2") | .proposed_state' "$json")" "A1 proposes reopening to In Progress"
  assert_equals Done "$(jq -r '.items[] | select(.item == "PC-1") | .proposed_state' "$json")" "B1 in production proposes Done"
  pass "fm-officer landing: A1 and B1 follow the audit definitions from the facts"
}

test_no_linear_writes_by_default() {
  local home
  make_world readonly none; home=$WORLD_HOME
  run_landing "$home" >/dev/null || fail "landing run must succeed"
  assert_no_grep "issue comment" "$LINEAR_LOG" "writes: none writes no comment"
  assert_no_grep "issue update" "$LINEAR_LOG" "writes: none writes no state"
  assert_grep "issue list --team PC --state Done" "$LINEAR_LOG" "Done items are read as one paged list"
  pass "fm-officer landing: the writes: none switch turns every Linear write off"
}

test_closes_only_fully_landed_items_with_evidence() {
  local home json
  make_world closing; home=$WORLD_HOME
  run_landing "$home" >/dev/null || fail "landing run must succeed"
  json="$home/data/officers/landing/$DATE.json"
  assert_grep "issue comment PC-1 --body-file" "$LINEAR_LOG" "the evidence is recorded on the item"
  assert_equals 4 "$(grep -c '^issue \(comment\|update\) PC-1 ' "$LINEAR_LOG")" "comment and state each run --dry-run then --verify"
  assert_equals "issue comment PC-1" "$(grep '^issue \(comment\|update\) PC-1 ' "$LINEAR_LOG" | sed -n 1p | cut -d' ' -f1-3)" "the comment precedes the state change"
  assert_contains "$(grep '^issue update PC-1 ' "$LINEAR_LOG" | tail -n 1)" "--state Done --verify" "the close is verified"
  assert_no_grep "PC-5 --body-file" "$LINEAR_LOG" "an item with sub-issues is never closed"
  assert_equals skipped "$(jq -r '.writes_done[] | select(.item == "PC-5") | .action' "$json")" "the sub-issue skip is recorded"
  assert_grep "issue update PC-2 --state In Progress --verify" "$LINEAR_LOG" "a Done item whose PR never reached main or any release is reopened"
  assert_no_grep "PC-7" "$LINEAR_LOG" "a Done item on main awaiting its release is never written"
  assert_grep "issue comment PC-2 --body-file" "$LINEAR_LOG" "the reopen is recorded on the item"
  assert_equals reopened "$(jq -r '.writes_done[] | select(.item == "PC-2") | .action' "$json")" "the reopen is logged"
  assert_equals 102 "$(jq -r '.writes_done[] | select(.item == "PC-2") | .record.prs[0].pr' "$json")" "the log names the landing-truth record used"
  assert_equals 2026-10-23T23:40:00Z "$(jq -r '.writes_done[] | select(.item == "PC-1") | .record.facts_generated_at' "$json")" "the close log names the facts run"
  assert_no_grep "update PC-3" "$LINEAR_LOG" "In Staging is never written"
  assert_no_grep "In Staging --" "$LINEAR_LOG" "no update ever sets In Staging"
  assert_no_grep "update PC-9" "$LINEAR_LOG" "a Done item no fact names is left to a person"
  assert_no_grep "update PC-4" "$LINEAR_LOG" "a consistent item is left alone"
  pass "fm-officer landing: corrections are on by default: close what the workflow missed, reopen false done, never In Staging"
}

test_stale_or_undated_facts_make_no_write() {
  local home json
  make_world stale; home=$WORLD_HOME
  run_landing "$home" $((NOW + 36 * 3600)) >/dev/null || fail "a stale-facts run must still finish"
  json="$home/data/officers/landing/$DATE.json"
  assert_no_grep "issue comment" "$LINEAR_LOG" "facts older than 36 hours write no comment"
  assert_no_grep "issue update" "$LINEAR_LOG" "facts older than 36 hours write no state"
  assert_equals high "$(jq -r '.findings[] | select(.class == "stale-facts") | .severity' "$json")" "stale facts are an actionable finding"
  assert_equals A1 "$(finding "$json" PC-2)" "stale facts are still judged and reported"
  make_world fresh-limit; home=$WORLD_HOME
  sed -i.bak 's/; model: none/; max-facts-age: 48; model: none/' "$home/data/officers.md"
  run_landing "$home" $((NOW + 36 * 3600)) >/dev/null || fail "landing run must succeed"
  assert_grep "issue update PC-2 --state In Progress --verify" "$LINEAR_LOG" "max-facts-age widens the limit"
  make_world undated; home=$WORLD_HOME
  jq '.generated_at = null' "$TMP_ROOT/undated/facts.json" > "$TMP_ROOT/undated/f" && mv "$TMP_ROOT/undated/f" "$TMP_ROOT/undated/facts.json"
  run_landing "$home" >/dev/null || fail "an undated-facts run must still finish"
  assert_no_grep "issue update" "$LINEAR_LOG" "facts with no generated_at write nothing"
  assert_contains "$(cat "$home/data/officers/landing/$DATE.md")" "generated_at is missing" "the digest names why nothing was written"
  pass "fm-officer landing: facts that are stale or undated make no Linear write and raise a finding"
}

test_changed_state_and_cap_stop_a_close() {
  local home
  make_world cap; home=$WORLD_HOME
  sed -i.bak 's/"state":"In Staging"/"state":"Done"/' "$FAKEBIN/linear-axi"
  run_landing "$home" >/dev/null || fail "landing run must succeed"
  assert_no_grep "comment PC-1" "$LINEAR_LOG" "an item whose Linear state moved since the facts is skipped"
  make_world cap0; home=$WORLD_HOME
  sed -i.bak 's/; model: none/; max-corrections: 0; model: none/' "$home/data/officers.md"
  run_landing "$home" >/dev/null || fail "landing run must succeed"
  assert_no_grep "issue view" "$LINEAR_LOG" "max-corrections 0 corrects nothing"
  pass "fm-officer landing: a moved Linear state or the close cap stops a close"
}

test_facts_over_ssh_and_schema_guard() {
  local home out
  make_world remote none; home=$WORLD_HOME
  cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; *) break ;; esac; done
shift
exec bash -c "$*"
SH
  chmod +x "$FAKEBIN/ssh"
  landing_registry "$home" "slarti:$TMP_ROOT/remote/facts.json" none
  run_landing "$home" >/dev/null || fail "facts read over ssh must succeed"
  assert_equals A1 "$(finding "$home/data/officers/landing/$DATE.json" PC-2)" "remote facts are judged the same"
  cp "$TMP_ROOT/remote/facts.json" "$TMP_ROOT/remote/good.json"
  printf '{"schema_version": 1, "records": {}, "items": {}}\n' > "$TMP_ROOT/remote/facts.json"
  out=$(run_landing "$home" 2>&1) && fail "another facts schema must fail the run"
  assert_contains "$out" "schema_version is not 2" "the refusal names the schema"
  jq '.records = []' "$TMP_ROOT/remote/good.json" > "$TMP_ROOT/remote/facts.json"
  out=$(run_landing "$home" 2>&1) && fail "records that are not keyed must fail the run"
  assert_contains "$out" "records is not an object" "the refusal names the layout"
  jq 'del(.items) | .prs = {}' "$TMP_ROOT/remote/good.json" > "$TMP_ROOT/remote/facts.json"
  out=$(run_landing "$home" 2>&1) && fail "another container must fail the run"
  assert_contains "$out" "top-level keys are not exactly" "the refusal names the top-level keys"
  jq '.records = {"PC2#1": .records["lstutzman/PropertyCompass2#101"]}' "$TMP_ROOT/remote/good.json" > "$TMP_ROOT/remote/facts.json"
  out=$(run_landing "$home" 2>&1) && fail "a record under another key must fail the run"
  assert_contains "$out" "not keyed by its <repo>#<pr>" "the refusal names the key"
  jq '.records["lstutzman/PropertyCompass2#101"].linear_state = "In Staging"' "$TMP_ROOT/remote/good.json" > "$TMP_ROOT/remote/facts.json"
  out=$(run_landing "$home" 2>&1) && fail "a v1 linear_state string must fail the run"
  assert_contains "$out" "linear_state is not an object" "the refusal names linear_state"
  jq '.items["PC-8"] = ["lstutzman/PropertyCompass2#999"]' "$TMP_ROOT/remote/good.json" > "$TMP_ROOT/remote/facts.json"
  out=$(run_landing "$home" 2>&1) && fail "an item pointing at no record must fail the run"
  assert_contains "$out" "item PC-8 does not list record keys" "the refusal names the item"
  pass "fm-officer landing: facts over ssh are judged alike; another schema or layout is refused"
}

test_run_writes_only_its_lane() {
  local home before after
  make_world lane; home=$WORLD_HOME
  printf 'working [at=1]: busy\n' > "$home/state/other-task.status"
  printf '1\tcheck\tsomething\n' > "$home/state/.wake-queue"
  before=$(cd "$home" && find . -path ./data/officers/landing -prune -o -type f -print | LC_ALL=C sort | xargs cksum)
  run_landing "$home" >/dev/null || fail "landing run must succeed"
  after=$(cd "$home" && find . -path ./data/officers/landing -prune -o -type f -print | LC_ALL=C sort | xargs cksum)
  assert_equals "$before" "$after" "a landing run changes nothing in the home outside data/officers/landing/"
  assert_equals "" "$(find "$home/data/officers/landing" -name '.evidence-*')" "no evidence scratch file is left behind"
  pass "fm-officer landing: a run writes only its lane; Linear is its one outside write"
}

test_linear_failure_fails_the_run_with_its_reason() {
  local home out
  make_world ratelimit none; home=$WORLD_HOME
  printf '#!/usr/bin/env bash\necho %s\n' "'{\"ok\":false,\"error\":{\"code\":\"UNKNOWN\",\"message\":\"Rate limit exceeded\"}}'" > "$FAKEBIN/linear-axi"
  out=$(run_landing "$home" 2>&1) && fail "a failed Linear read must fail the run"
  assert_contains "$out" "Rate limit exceeded" "the run names Linear's reason"
  assert_grep "$DATE failed" "$home/data/officers/landing/runs.log" "the failure goes through the attempts path"
  assert_absent "$home/data/officers/landing/$DATE.json" "no digest is written from a partial read"
  pass "fm-officer landing: a Linear failure fails the run with Linear's reason"
}

test_registry_refuses_in_staging_as_reopen_state() {
  local home out
  make_world staging; home=$WORLD_HOME
  sed -i.bak "s/; model: none/; reopen-state: In Staging; model: none/" "$home/data/officers.md"
  out=$(run_landing "$home" 2>&1) && fail "a reopen-state of In Staging must be refused"
  assert_contains "$out" "may not be In Staging" "the refusal names the rule"
  assert_contains "$(FM_HOME="$home" "$OFFICER" ensure)" "OFFICER: officer landing: reopen-state may not be In Staging" "ensure reports it"
  assert_absent "$LINEAR_LOG" "nothing reaches Linear"
  pass "fm-officer landing: In Staging is refused as a reopen state before any Linear call"
}

test_classes_from_facts
test_registry_refuses_in_staging_as_reopen_state
test_linear_failure_fails_the_run_with_its_reason
test_run_writes_only_its_lane
test_no_linear_writes_by_default
test_closes_only_fully_landed_items_with_evidence
test_changed_state_and_cap_stop_a_close
test_stale_or_undated_facts_make_no_write
test_facts_over_ssh_and_schema_guard
