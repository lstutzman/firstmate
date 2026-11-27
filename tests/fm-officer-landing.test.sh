#!/usr/bin/env bash
# Behavior tests for the landing (records) officer, driven through
# bin/fm-officer.sh run with a landing-truth facts fixture of the fleet-app
# job's documented shape and a fake linear-axi that records every call.
#
# Covers: B1 held by an open sub-issue or an unmerged PR, and unchecked when its
# sub-issues cannot be read (the 2026-11-26 digest's 15 false alarms as fixtures), A1 (Done, a linked PR never on main or in any release, reopened;
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
   "linear_ids": ["PC-10", "PC-11"], "linear_state": {"PC-10": "Done", "PC-11": "In Review"}, "landed_via": "lone"},
  "lstutzman/PropertyCompass2#108": {"repo": "lstutzman/PropertyCompass2", "pr": 108, "head_sha": "h108", "merged_sha": null, "merged_at": null,
   "on_staging": false, "staging_deployed": false, "on_main": false, "main_promoted_at": null, "in_production": false, "production_release": null,
   "linear_ids": ["PC-12"], "linear_state": {"PC-12": "Done"}, "landed_via": "lone"},
  "lstutzman/PropertyCompass2#109": {"repo": "lstutzman/PropertyCompass2", "pr": 109, "head_sha": "h109", "merged_sha": "m109", "merged_at": "2026-10-23T11:00:00Z",
   "on_staging": true, "staging_deployed": true, "on_main": null, "main_promoted_at": null, "in_production": null, "production_release": null,
   "linear_ids": ["PC-13"], "linear_state": {"PC-13": "Done"}, "landed_via": "lone"},
  "lstutzman/PropertyCompass2#110": {"repo": "lstutzman/PropertyCompass2", "pr": 110, "head_sha": "h110", "merged_sha": "m110", "merged_at": "2026-10-18T11:00:00Z",
   "on_staging": true, "staging_deployed": true, "on_main": true, "main_promoted_at": "2026-10-18T15:00:00Z", "in_production": true, "production_release": "v1.70.1",
   "linear_ids": ["PC-14"], "linear_state": {}, "landed_via": "lone"},
  "lstutzman/PropertyCompass2#111": {"repo": "lstutzman/PropertyCompass2", "pr": 111, "head_sha": "h111", "merged_sha": "m111", "merged_at": "2026-10-22T11:00:00Z",
   "on_staging": true, "staging_deployed": true, "on_main": false, "main_promoted_at": null, "in_production": false, "production_release": null,
   "linear_ids": ["PC-15"], "linear_state": {"PC-15": "Released"}, "landed_via": "lone"}
 },
 "items": {"PC-1": ["lstutzman/PropertyCompass2#101"], "PC-2": ["lstutzman/PropertyCompass2#102"], "PC-3": ["lstutzman/PropertyCompass2#103"],
  "PC-4": ["lstutzman/PropertyCompass2#104"], "PC-5": ["lstutzman/PropertyCompass2#105"], "PC-7": ["lstutzman/PropertyCompass2#106"],
  "PC-10": ["lstutzman/PropertyCompass2#107"], "PC-11": ["lstutzman/PropertyCompass2#107"],
  "PC-12": ["lstutzman/PropertyCompass2#108"], "PC-13": ["lstutzman/PropertyCompass2#109"], "PC-14": ["lstutzman/PropertyCompass2#110"],
  "PC-15": ["lstutzman/PropertyCompass2#111"]}}
JSON
}

# fake_linear <fakebin> <log>: a linear-axi that answers from fixed data and
# logs every call; PC-5 has a sub-issue, PC-1 is still In Staging.
fake_linear() {
  cat > "$1/linear-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$2"
printf '%s\n' "\${LINEAR_JOB-}" >> "$2.jobs"
[ "\$1 \$2 \$6" != "issue comment --verify" ] || cat "\$5" >> "$2.bodies"
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
  assert_equals "" "$(finding "$json" PC-15)" "a Released item is finished: no finding even with a PR facts show off main"
  assert_equals null "$(jq -r '.items[] | select(.item == "PC-15") | .correction' "$json")" "a Released item is never reopened or closed"
  assert_equals A1 "$(finding "$json" PC-12)" "Done with no linked PR merged is false done"
  assert_equals null "$(jq -r '.items[] | select(.item == "PC-12") | .correction' "$json")" "an unmerged Done item is left to a person"
  assert_equals A1 "$(finding "$json" PC-13)" "Done with unknown production status is reported"
  assert_contains "$(jq -r '.findings[] | select(.item == "PC-13") | .summary' "$json")" "production status unknown" "unknown is never read as not in production"
  assert_equals null "$(jq -r '.items[] | select(.item == "PC-13") | .correction' "$json")" "unknown on_main is never reopened"
  assert_equals "" "$(finding "$json" PC-14)" "an item with no recorded state is not status lag"
  assert_equals A1 "$(finding "$json" PC-9)" "Done with no landing fact is raised for a person"
  assert_equals "In Progress" "$(jq -r '.items[] | select(.item == "PC-2") | .proposed_state' "$json")" "A1 proposes reopening to In Progress"
  assert_equals null "$(jq -r '.items[] | select(.item == "PC-1") | .proposed_state' "$json")" "B1 in production proposes no state: it is reported as a release-path miss"
  pass "fm-officer landing: A1 and B1 follow the audit definitions from the facts"
}

test_no_linear_writes_by_default() {
  local home
  make_world readonly none; home=$WORLD_HOME
  run_landing "$home" >/dev/null || fail "landing run must succeed"
  assert_no_grep "issue comment" "$LINEAR_LOG" "writes: none writes no comment"
  assert_no_grep "issue update" "$LINEAR_LOG" "writes: none writes no state"
  assert_grep "issue list --team PC --state Done" "$LINEAR_LOG" "Done items are read as one paged list"
  assert_equals officer:landing "$(sort -u "$LINEAR_LOG.jobs")" "every linear-axi call is attributed to the landing officer"
  : > "$LINEAR_LOG.jobs"
  LINEAR_JOB=fleet:caller run_landing "$home" >/dev/null || fail "landing run must succeed under a caller's LINEAR_JOB"
  assert_equals fleet:caller "$(sort -u "$LINEAR_LOG.jobs")" "a LINEAR_JOB the caller set is kept"
  pass "fm-officer landing: the writes: none switch turns every Linear write off"
}

test_closes_only_fully_landed_items_with_evidence() {
  local home json
  make_world closing; home=$WORLD_HOME
  run_landing "$home" >/dev/null || fail "landing run must succeed"
  json="$home/data/officers/landing/$DATE.json"
  assert_no_grep "update PC-1 " "$LINEAR_LOG" "an item in production is never moved to Done"
  assert_no_grep "issue comment PC-1 " "$LINEAR_LOG" "the miss is not commented on the item itself"
  assert_equals 2 "$(grep -c '^issue comment PC-4688 --body-file' "$LINEAR_LOG")" "the miss is commented on the release-path issue, --dry-run then --verify"
  assert_contains "$(sed -n 1p "$LINEAR_LOG.bodies")" "PC-1 has every linked PR merged and in production" "the comment names the item"
  assert_contains "$(cat "$LINEAR_LOG.bodies")" "https://github.com/lstutzman/PropertyCompass2/pull/101, production release v1.71.0" "and its PR URL and production version"
  assert_equals reported "$(jq -r '.writes_done[] | select(.item == "PC-1") | .action' "$json")" "the miss is listed in the digest"
  assert_contains "$(cat "$home/data/officers/landing/$DATE.md")" "PC-1: reported" "the markdown digest lists it"
  assert_equals "" "$(jq -r '.writes_done[] | select(.item == "PC-5") | .action' "$json")" "an item with an open sub-issue is not raised, so nothing is reported or skipped"
  assert_equals "" "$(finding "$json" PC-5)" "an item with an open sub-issue raises no B1"
  assert_equals PC-6 "$(jq -r '.items[] | select(.item == "PC-5") | .b1_held[0]' "$json")" "the held item names the open sub-issue"
  assert_equals 2026-10-23T23:40:00Z "$(jq -r '.writes_done[] | select(.item == "PC-1") | .record.facts_generated_at' "$json")" "the miss report names the facts run"
  : > "$LINEAR_LOG"
  run_landing "$home" >/dev/null || fail "a second landing run must succeed"
  assert_no_grep "PC-4688" "$LINEAR_LOG" "the same miss is not reported again on the next run"
  assert_no_grep "issue view PC-1 " "$LINEAR_LOG" "a miss already reported is not re-read, so it takes no re-check slot"
  assert_grep "issue update PC-2 --state In Progress --verify" "$LINEAR_LOG" "a Done item whose PR never reached main or any release is reopened"
  assert_no_grep "PC-7" "$LINEAR_LOG" "a Done item on main awaiting its release is never written"
  assert_grep "issue comment PC-2 --body-file" "$LINEAR_LOG" "the reopen is recorded on the item"
  assert_equals reopened "$(jq -r '.writes_done[] | select(.item == "PC-2") | .action' "$json")" "the reopen is logged"
  assert_equals 102 "$(jq -r '.writes_done[] | select(.item == "PC-2") | .record.prs[0].pr' "$json")" "the log names the landing-truth record used"
  assert_no_grep "update PC-3" "$LINEAR_LOG" "In Staging is never written"
  assert_no_grep "In Staging --" "$LINEAR_LOG" "no update ever sets In Staging"
  assert_no_grep "PC-15" "$LINEAR_LOG" "a Released item is never read or written in Linear"
  assert_no_grep "update PC-9" "$LINEAR_LOG" "a Done item no fact names is left to a person"
  assert_no_grep "update PC-4" "$LINEAR_LOG" "a consistent item is left alone"
  assert_no_grep "update PC-13" "$LINEAR_LOG" "an item with unknown production status is never written"
  assert_no_grep "PC-14" "$LINEAR_LOG" "an item with no recorded state is never written"
  assert_contains "$(grep -h 'Landing officer correction' "$LINEAR_LOG.bodies")" "moving to In Progress" "the reopen comment states the move it is about to make"
  pass "fm-officer landing: corrections are on by default: report what the release path missed, reopen false done, never In Staging"
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
  make_world noprod; home=$WORLD_HOME
  jq '.production_sha = null' "$TMP_ROOT/noprod/facts.json" > "$TMP_ROOT/noprod/f" && mv "$TMP_ROOT/noprod/f" "$TMP_ROOT/noprod/facts.json"
  run_landing "$home" >/dev/null || fail "a run with no production_sha must still finish"
  assert_no_grep "issue update" "$LINEAR_LOG" "facts with no production_sha write nothing"
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
  make_world cap1; home=$WORLD_HOME
  sed -i.bak 's/"state":"In Staging"/"state":"Done"/' "$FAKEBIN/linear-axi"
  sed -i.bak 's/; model: none/; max-corrections: 1; model: none/' "$home/data/officers.md"
  run_landing "$home" >/dev/null || fail "landing run must succeed"
  assert_grep "issue update PC-2 --state In Progress --verify" "$LINEAR_LOG" "skipped items do not use up the cap"
  assert_no_grep "update PC-5" "$LINEAR_LOG" "the cap still stops after one write"
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
  assert_contains "$out" "may not be In Staging, Done or Released" "the refusal names the rule"
  assert_contains "$(FM_HOME="$home" "$OFFICER" ensure)" "OFFICER: officer landing: reopen-state may not be In Staging, Done or Released" "ensure reports it"
  assert_absent "$LINEAR_LOG" "nothing reaches Linear"
  pass "fm-officer landing: In Staging is refused as a reopen state before any Linear call"
}

test_registry_refuses_released_as_reopen_state() {
  local home out
  make_world released; home=$WORLD_HOME
  sed -i.bak "s/; model: none/; reopen-state: Released; model: none/" "$home/data/officers.md"
  out=$(run_landing "$home" 2>&1) && fail "a reopen-state of Released must be refused"
  assert_contains "$out" "may not be In Staging, Done or Released" "the refusal names the rule"
  assert_absent "$LINEAR_LOG" "nothing reaches Linear"
  pass "fm-officer landing: Released is refused as a reopen state before any Linear call"
}

test_pass_refuses_released_as_reopen_state() {
  local home out
  make_world released-direct; home=$WORLD_HOME
  out=$(PATH="$FAKEBIN:$PATH" python3 "$ROOT/bin/fm-officer-landing.py" run --facts "$TMP_ROOT/released-direct/facts.json" \
    --date "$DATE" --out "$TMP_ROOT/released-direct/out" --reopen-state Released --now "$NOW" 2>&1) \
    && fail "the landing pass itself must refuse a reopen-state of Released"
  assert_contains "$out" "may not be In Staging, Done or Released" "the pass's refusal names the rule"
  assert_absent "$LINEAR_LOG" "nothing reaches Linear"
  assert_absent "$TMP_ROOT/released-direct/out/$DATE.json" "no digest is written"
  pass "fm-officer-landing.py: Released is refused as a reopen state by the pass itself"
}

# The 2026-11-26 digest's 15 B1 findings (Navigator triage, FLEET-241). Row:
# item|Linear state|PR numbers (all merged and in production)|open sub-issues (id:state,...)|unmerged PR number
TRIAGE_ROWS='PC-1902|In Progress|4327,4476,4479,4481|PC-5876:In Staging,PC-5834:In Staging|
PC-2356|In Staging|6238,6239,6276|PC-4088:Backlog|
PC-2686|In Staging|3946,6211,6256|PC-5630:In Staging|
PC-3287|Backlog|4771||
PC-3479|Backlog|3927||
PC-3553|Backlog|4305||
PC-4280|In Progress|4955,4957||6733
PC-4310|Backlog|4724||
PC-4652|In Staging|6515||
PC-4678|In Staging|6540,6629|PC-5792:In Staging|
PC-4719|Backlog|5326||
PC-4725|Backlog|5267,5292||
PC-4835|Backlog|5443,5452,5854,5877||
PC-4952|In Progress|5665,5720,5679,6080|PC-4955:Backlog,PC-4956:Backlog|
PC-5329|In Progress|6154|PC-5333:Backlog,PC-5332:Released|'

make_triage_world() {  # <name>: facts and Linear views from TRIAGE_ROWS; sets WORLD_HOME, FAKEBIN, LINEAR_LOG.
  local name=$1 dir home item state prs kids open pr
  dir="$TMP_ROOT/$name"; home="$dir/home"
  officer_home "$home"
  mkdir -p "$dir/views"
  printf '{"schema_version": 2, "generated_at": "2026-10-23T23:40:00Z", "staging_sha": "a", "production_sha": "b", "records": {}, "items": {}}\n' > "$dir/facts.json"
  while IFS='|' read -r item state prs kids open; do
    for pr in ${prs//,/ }; do
      jq --arg i "$item" --arg s "$state" --argjson n "$pr" '
        .records["lstutzman/PropertyCompass2#\($n)"] = {repo: "lstutzman/PropertyCompass2", pr: $n, head_sha: "h", merged_sha: "m", merged_at: "2026-10-20T10:00:00Z",
          on_staging: true, staging_deployed: true, on_main: true, main_promoted_at: "2026-10-20T15:00:00Z", in_production: true, production_release: "v1.73.0",
          linear_ids: [$i], linear_state: {($i): $s}, landed_via: "lone"}
        | .items[$i] += ["lstutzman/PropertyCompass2#\($n)"]' "$dir/facts.json" > "$dir/f" && mv "$dir/f" "$dir/facts.json"
    done
    if [ -n "$open" ]; then
      jq --arg i "$item" --arg s "$state" --argjson n "$open" '
        .records["lstutzman/PropertyCompass2#\($n)"] = {repo: "lstutzman/PropertyCompass2", pr: $n, head_sha: "h", merged_sha: null, merged_at: null,
          on_staging: false, staging_deployed: false, on_main: false, main_promoted_at: null, in_production: false, production_release: null,
          linear_ids: [$i], linear_state: {($i): $s}, landed_via: "lone"}
        | .items[$i] += ["lstutzman/PropertyCompass2#\($n)"]' "$dir/facts.json" > "$dir/f" && mv "$dir/f" "$dir/facts.json"
    fi
    jq -n --arg i "$item" --arg s "$state" --arg kids "$kids" '
      {ok: true, data: {issue: {identifier: $i, state: $s},
        subIssues: [($kids | split(",") | map(select(. != "")) | .[] | split(":") | {identifier: .[0], state: .[1]})]}}' > "$dir/views/$item.json"
  done <<< "$TRIAGE_ROWS"
  landing_registry "$home" "$dir/facts.json"
  FAKEBIN=$(fm_fakebin "$dir")
  LINEAR_LOG="$dir/linear.calls"
  cat > "$FAKEBIN/linear-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LINEAR_LOG"
case "\$1 \$2" in
  "issue list") echo '{"ok":true,"data":{"issues":[]}}' ;;
  "issue view") if [ -f "$dir/views/\$3.json" ]; then cat "$dir/views/\$3.json"; else echo '{"ok":false,"error":{"code":"NOT_FOUND","message":"no such item"}}'; fi ;;
  *) echo '{"ok":true,"data":{}}' ;;
esac
SH
  chmod +x "$FAKEBIN/linear-axi"
  WORLD_HOME=$home
}

test_b1_triage_rows() {
  local home json item
  make_triage_world triage; home=$WORLD_HOME
  run_landing "$home" >/dev/null || fail "landing run must succeed"
  json="$home/data/officers/landing/$DATE.json"
  for item in PC-1902 PC-2356 PC-2686 PC-4678 PC-4952 PC-5329; do
    assert_equals "" "$(finding "$json" "$item")" "$item has open sub-issues: no B1"
    assert_not_equals "" "$(jq -r --arg i "$item" '.items[] | select(.item == $i) | .b1_held[0]' "$json")" "$item is held with its open sub-issue named"
  done
  assert_equals "" "$(jq -r '.findings[] | select(.item == "PC-4280" and .severity == "medium") | .class' "$json")" "PC-4280 has an unmerged linked PR: no release-path B1"
  assert_equals low "$(jq -r '.findings[] | select(.item == "PC-4280") | .severity' "$json")" "the low B1 (proposed In Staging) is unchanged"
  # The facts carry no mark that tells a mere id mention from a delivering PR
  # (landed_via is "pile-<date>" or "lone"), and the open-children signal is
  # absent for these rows, so they still raise: the mislink is the landing-truth
  # job's to fix. Documented expected cases, not a claim that they are right.
  for item in PC-3287 PC-4310 PC-4725 PC-3479 PC-3553 PC-4652 PC-4719 PC-4835; do
    assert_equals B1 "$(finding "$json" "$item")" "$item has no open sub-issue or open PR in the facts: still raised (documented)"
  done
  assert_equals 8 "$(jq '[.findings[] | select(.class == "B1" and .severity == "medium")] | length' "$json")" "7 of the 15 false alarms are held, 8 remain"
  assert_equals 8 "$(grep -c '^issue comment PC-4688 --body-file.*--verify' "$LINEAR_LOG")" "only the 8 raised items are reported"
  assert_no_grep "PC-1902 --body" "$LINEAR_LOG" "a held epic is never reported"
  assert_equals 1 "$(grep -c '^issue view PC-3287 ' "$LINEAR_LOG")" "the vetting read is the only read: the report reuses it"
  assert_no_grep "issue view PC-4280" "$LINEAR_LOG" "an item with an unmerged PR is not read at all"
  pass "fm-officer landing: B1 skips items with open sub-issues or an unmerged PR (the 2026-11-26 triage rows)"
}

test_b1_unchecked_when_sub_issues_unreadable() {
  local home json
  make_triage_world unreadable; home=$WORLD_HOME
  rm "$TMP_ROOT/unreadable/views/PC-3287.json"
  run_landing "$home" >/dev/null || fail "an unreadable item must not fail the run"
  json="$home/data/officers/landing/$DATE.json"
  assert_equals low "$(jq -r '.findings[] | select(.item == "PC-3287") | .severity' "$json")" "an unreadable item is named, not raised as a miss"
  assert_contains "$(jq -r '.findings[] | select(.item == "PC-3287") | .summary' "$json")" "sub-issues were not checked" "the digest says it is unchecked"
  assert_no_grep "comment PC-4688 --body-file $TMP_ROOT/unreadable/home/data/officers/landing/.miss-$DATE-PC-3287" "$LINEAR_LOG" "no report for it"
  assert_equals 7 "$(jq '[.findings[] | select(.class == "B1" and .severity == "medium")] | length' "$json")" "the other raised items are unaffected"
  make_triage_world budget; home=$WORLD_HOME
  sed -i.bak 's/; model: none/; max-corrections: 0; model: none/' "$home/data/officers.md"
  run_landing "$home" >/dev/null || fail "landing run must succeed"
  assert_no_grep "issue view" "$LINEAR_LOG" "max-corrections 0 reads nothing"
  assert_equals 0 "$(jq '[.findings[] | select(.class == "B1" and .severity == "medium")] | length' "$home/data/officers/landing/$DATE.json")" "unread candidates are unchecked, never raised"
  pass "fm-officer landing: a B1 whose sub-issues cannot be read is named unchecked, not raised"
}


test_classes_from_facts
test_b1_triage_rows
test_b1_unchecked_when_sub_issues_unreadable
test_registry_refuses_in_staging_as_reopen_state
test_registry_refuses_released_as_reopen_state
test_pass_refuses_released_as_reopen_state
test_linear_failure_fails_the_run_with_its_reason
test_run_writes_only_its_lane
test_no_linear_writes_by_default
test_closes_only_fully_landed_items_with_evidence
test_changed_state_and_cap_stop_a_close
test_stale_or_undated_facts_make_no_write
test_facts_over_ssh_and_schema_guard
