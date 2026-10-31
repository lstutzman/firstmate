#!/usr/bin/env bash
# Behavior tests for the page-check officer, driven through bin/fm-officer.sh
# against fixture fleet-app pages (a fake curl) and fixture home records.
#
# Covers: the registry (an https app is required), each finding kind (a card a
# standing rule settles, stale cards of every sort including a PR the forge
# says is merged, a card shown after its record was settled by a status line
# or by the app's own card record, pages older than their normal cadence,
# unpublished pages and failing jobs, Bosun's results page past its 26-hour
# gap), a rules file with no rule line as a coverage note, JSON of an
# unexpected shape as an unreadable page rather than a crash, the new-finding count that keeps an
# unchanged page set quiet until the reminder window passes, an unreachable
# app as a finding rather than a failed run, the interval slot key the
# scheduler gives a run, and the read-only boundary (GET only, no write
# tool, nothing written outside the lane).
set -u

# shellcheck source=tests/officer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/officer-helpers.sh"

OFFICER="$ROOT/bin/fm-officer.sh"
TMP_ROOT=$(fm_test_tmproot fm-officer-page-check)
KEY=2026-10-31T14
NOW=1793457000          # 2026-10-31T14:30:00Z
E=1793437200            # 2026-10-31T09:00:00Z
export TZ=UTC

write_pages() {  # <dir>: the fleet app's pages, one file per GET path.
  local d=$1 k1 k2
  k1="task-k-k1-$(printf 'task-k\0k1' | sha256sum | cut -c1-10)"
  k2="task-k-k2-$(printf 'task-k\0k2' | sha256sum | cut -c1-10)"
  mkdir -p "$d"
  jq -n --arg k1 "$k1" --arg k2 "$k2" '{at: "2026-10-31T14:00:00Z", value: {updated: "2026-10-31T14:00:00Z", cards: [
    {id: "fine", band: "now", question: "Pick the logo", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "cleanup", band: "now", question: "Approve deleting 475 stale branches?", advice: "yes", replies: ["yes"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "old-ask", band: "now", question: "Which colour?", advice: "a", replies: ["a"], asked: "2026-10-20T12:00:00Z", state: "asked"},
    {id: "snoozed-old", band: "later", question: "Revisit the export", advice: "a", replies: ["a"], asked: "2026-10-20T12:00:00Z", state: "snoozed", until: "2026-10-28T00:00:00Z"},
    {id: "pr-card", band: "now", question: "Merge https://github.com/ex/repo/pull/7 and https://github.com/ex/repo/pull/8?", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "answered-shown", band: "now", question: "Sign off?", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked", answer: {text: "yes", at: "2026-10-31T13:00:00Z"}},
    {id: $k1, band: "now", question: "Which key?", advice: "a", replies: ["a"], asked: "2026-10-31T10:00:00Z", state: "asked"},
    {id: $k2, band: "now", question: "Which mode?", advice: "a", replies: ["a"], asked: "2026-10-31T08:00:00Z", state: "asked"},
    {id: "bosun-ep", band: "now", question: "Bosun asks about an episode", advice: "a", replies: ["a"], asked: "2026-10-31T05:40:00Z", reasked: "2026-10-31T05:40:00Z", state: "asked"},
    {id: "done-card", band: "now", question: "Already answered", advice: "a", replies: ["a"], asked: "2026-10-20T12:00:00Z", state: "answered", answer: {text: "x", at: "2026-10-21T12:00:00Z"}}]}}' > "$d/_api_captains-log"
  jq -n '{source: "bosun", cards: [{id: "bosun-ep", lifecycle: "closed"}, {id: "other", lifecycle: "open"}]}' > "$d/_api_captains-log_facts_source_bosun"
  jq -n '{generated_at: "2026-10-31T12:00:00Z", homes: [{home: "main", node: "n", observed_at: "2026-10-31T13:00:00Z", asks: 1}], rows: []}' > "$d/_api_top-of-mind"
  jq -n '{value: {outcome: "ok", state: {written_at: "2026-10-31T07:00:00Z", stale_after_minutes: 2880}}}' > "$d/_api_progress-officer"
  jq -n '{sources: {workers: {homes: [{observed_at: "2026-10-31T14:10:00Z"}]}, prs: {observed_at: "2026-10-31T14:10:00Z"}, usage: {observed_at: "2026-10-31T14:10:00Z"}}}' > "$d/_api_cost-cycle"
  jq -n '{value: {generated_at: "2026-10-31T06:00:00Z"}}' > "$d/_api_ideation"
  jq -n '{value: {generated_at: "2026-10-29T06:00:00Z"}}' > "$d/_api_business-health"
  jq -n '{jobs: [{id: "ok-job", state: "live", health: "working"}, {id: "bad-job", label: "Bad job", officer: "bosun", state: "live", health: "failing", nextDueAt: "2026-11-01T00:00:00Z"}, {id: "gone", state: "retired", health: "failing"}]}' > "$d/_api_runs"
  jq -n '{status: "ok"}' > "$d/_api_health"
  jq -n '{runs: [{run: {startedAt: "2026-10-29T04:37:00Z"}}, {run: {startedAt: "2026-10-31T04:37:00Z"}}]}' > "$d/_api_runs_bosun-maintenance_results"
  # _api_velocity-audit is absent: the page was never published (404).
}

# make_world <name>: a home with a status log, standing rules and fake curl and gh.
make_world() {
  local name=$1 home dir fakebin
  home="$TMP_ROOT/$name/home"
  dir="$TMP_ROOT/$name/pages"
  officer_home "$home"
  home=$(cd "$home" && pwd -P)
  write_pages "$dir"
  cat > "$home/state/task-k.status" <<EOF
needs-decision [at=$((E - 600))] [key=k1]: pick a key
resolved [key=k1] [at=$((E + 60))]: Lee chose
needs-decision [at=$((E - 600))] [key=k2]: pick a mode
resolved [key=k2] [at=$((E + 60))]: Lee chose
EOF
  cat > "$home/data/captain-shared.md" <<'EOF'
# Shared
- standing-rule routine-cleanup /(delet|clean-?up|prune)/ - routine clean-up needs no approval (Lee, 2026-10-31)
- standing-rule broken /(unclosed/ - an invalid pattern
Free text that is not a rule.
EOF
  printf -- '- page-check - Checks the fleet app pages (role: pagecheck; cadence: every 2h; app: https://app.test; model: none; added 2026-10-31)\n' \
    > "$home/data/officers.md"
  fakebin=$(fm_fakebin "$TMP_ROOT/$name")
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fakebin/curl.calls"
[ -f "$TMP_ROOT/$name/unreachable" ] && exit 7
url=\${@: -1}
f="$dir/\$(printf '%s' "\${url#https://app.test}" | tr '/?=' '___')"
if [ -f "\$f" ]; then cat "\$f"; printf '\n200'; else printf '\n404'; fi
SH
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fakebin/gh.calls"
case "\$2 \$3" in
  "GET /repos/ex/repo/pulls/7") echo 'PRSTATE {"state":"closed","merged":true}' ;;
  "GET /repos/ex/repo/pulls/8") echo 'PRSTATE {"state":"open","merged":false}' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/curl" "$fakebin/gh-axi"
  printf '%s\n' "$home"
}

officer() {  # <name> <args...>
  local name=$1 fakebin
  shift
  fakebin="$TMP_ROOT/$name/fakebin"
  PATH="$fakebin:$PATH" FM_OFFICER_NOW=$NOW FM_HOME="$TMP_ROOT/$name/home" "$OFFICER" "$@"
}

ids() {  # <json> <kind>
  jq -r --arg k "$2" '[.findings[] | select(.kind == $k) | .id] | sort | join(" ")' "$1"
}

test_registry_needs_an_https_app() {
  local home out
  home=$(make_world registry)
  printf -- '- page-check - Checks pages (role: pagecheck; cadence: every 2h; model: none; added 2026-10-31)\n' > "$home/data/officers.md"
  out=$(officer registry run page-check 2>&1) && fail "a pagecheck line without an app must be refused"
  assert_contains "$out" "a pagecheck officer needs app" "the refusal names the missing field"
  printf -- '- page-check - Checks pages (role: pagecheck; cadence: every 2h; app: http://app.test; model: none; added 2026-10-31)\n' > "$home/data/officers.md"
  out=$(officer registry run page-check 2>&1) && fail "a plain-http app must be refused"
  printf -- '- page-check - Checks pages (role: pagecheck; cadence: every 25h; app: https://app.test; model: none; added 2026-10-31)\n' > "$home/data/officers.md"
  assert_contains "$(officer registry run page-check 2>&1)" 'cadence must be "daily HH:MM" or "every Nh"' "an interval over 24 hours is refused"
  pass "fm-officer page-check: the registry needs an https app and a valid cadence"
}

test_findings_of_every_kind() {
  local home out json
  home=$(make_world kinds)
  out=$(officer kinds run page-check --date "$KEY") || fail "run must succeed: $out"
  json="$home/data/officers/page-check/$KEY.json"
  assert_contains "$out" "DIGEST $KEY " "the run prints a digest for the slot key"
  assert_equals "standing-rule:Captain's Log:cleanup:routine-cleanup" "$(ids "$json" standing-rule)" \
    "only the card the standing rule matches is flagged, and the invalid rule does not abort the pass"
  assert_contains "$(cat "$home/data/officers/page-check/$KEY.md")" "standing rule(s) broken have an invalid regex" \
    "an invalid rule is reported as a coverage note"
  assert_equals "stale-card:Captain's Log:answered-shown:answered stale-card:Captain's Log:old-ask:unanswered stale-card:Captain's Log:pr-card:ex/repo#7 stale-card:Captain's Log:snoozed-old:snooze stale-card:Captain's Log:task-k-k2-$(printf 'task-k\0k2' | sha256sum | cut -c1-10):resolved" \
    "$(ids "$json" stale-card)" "stale cards: answered, unanswered for days, a merged PR (not the open one), snooze ended, resolved elsewhere"
  assert_equals "shown-after-done:Captain's Log:bosun-ep shown-after-done:Captain's Log:task-k-k1-$(printf 'task-k\0k1' | sha256sum | cut -c1-10)" \
    "$(ids "$json" shown-after-done)" "a card re-raised after its status line resolved, and one the app records closed"
  assert_equals "page-old:Business health:business-health page-old:Runs:bad-job page-old:Velocity audit:velocity-audit" \
    "$(ids "$json" page-old)" "an old page, a failing live job (not the retired one), and a page never published"
  assert_equals "$(jq '.findings | length' "$json")" "$(jq '.new | length' "$json")" "every first-seen finding is new"
  pass "fm-officer page-check: each finding kind is raised for the right object"
}

test_bosun_rules_and_unexpected_shapes() {
  local home d out json md
  home=$(make_world shapes)
  d="$TMP_ROOT/shapes/pages"
  jq -n '{runs: [{run: {startedAt: "2026-10-30T12:00:00Z"}}, {run: {startedAt: "2026-10-29T04:37:00Z"}}]}' > "$d/_api_runs_bosun-maintenance_results"
  jq -n '[]' > "$d/_api_runs"
  jq -n '{value: {state: {written_at: "2026-10-31T14:00:00Z", stale_after_minutes: "soon"}}}' > "$d/_api_progress-officer"
  jq -n '{source: "bosun", cards: ["bosun-ep", 3, {id: "bosun-ep", lifecycle: "closed"}]}' > "$d/_api_captains-log_facts_source_bosun"
  jq '.value.suggestions = "none" | .value.choice = [1, "x"]' "$d/_api_captains-log" > "$d/log.tmp" && mv "$d/log.tmp" "$d/_api_captains-log"
  printf '# Shared\nRoutine clean-up needs no approval (Lee, 2026-10-31).\n' > "$home/data/captain-shared.md"
  out=$(officer shapes run page-check --date "$KEY") || fail "unexpected JSON shapes must not fail the run: $out"
  json="$home/data/officers/page-check/$KEY.json"
  md="$home/data/officers/page-check/$KEY.md"
  assert_equals "page-old:Bosun:results page-old:Business health:business-health page-old:Progress officer:progress-officer page-old:Runs:runs page-old:Velocity audit:velocity-audit" \
    "$(ids "$json" page-old)" "Bosun's newest result is 26.5 hours old, a list for Runs and a word for the gap are unreadable pages"
  assert_contains "$(cat "$md")" "Runs: unreadable" "the Runs page that answered a list is named unreadable"
  assert_contains "$(cat "$md")" "shown-after-done] Captain's Log - bosun-ep" "a closed card record among malformed entries is still read"
  assert_contains "$(cat "$md")" "Coverage: no standing-rule lines in $home/data/captain-shared.md" \
    "a rules file with only prose is a coverage note, not a silent empty check"
  assert_equals "" "$(ids "$json" standing-rule)" "no rule line means no standing-rule finding"
  pass "fm-officer page-check: Bosun's page gap, an empty rules file and unexpected JSON shapes are findings or notes, not crashes"
}

test_unchanged_pages_stay_quiet_until_the_reminder() {
  local home first later
  home=$(make_world quiet)
  first=$(officer quiet run page-check --date "$KEY") || fail "first run must succeed"
  assert_not_contains "$first" "DIGEST $KEY 0 " "the first run reports its findings as new"
  assert_contains "$(officer quiet run page-check --date "$KEY")" "DIGEST $KEY 0 " "an unchanged page set reports nothing new"
  assert_no_grep "NEW" "$home/data/officers/page-check/$KEY.md" "nothing is marked new on the repeat"
  later=$(FM_OFFICER_NOW=$((NOW + 25 * 3600)) PATH="$TMP_ROOT/quiet/fakebin:$PATH" FM_HOME="$home" "$OFFICER" run page-check --date "$KEY") \
    || fail "a later run must succeed"
  assert_not_contains "$later" "DIGEST $KEY 0 " "a finding nobody fixed is reported again after the reminder window"
  rm -f "$TMP_ROOT/quiet/pages/_api_runs"
  assert_contains "$(FM_OFFICER_NOW=$((NOW + 25 * 3600)) PATH="$TMP_ROOT/quiet/fakebin:$PATH" FM_HOME="$home" "$OFFICER" run page-check --date "$KEY")" \
    "DIGEST $KEY 1 " "only the finding that appeared is new"
  pass "fm-officer page-check: an unchanged page set is quiet until the reminder window passes"
}

test_unreachable_app_is_a_finding_not_a_failed_run() {
  local home out
  home=$(make_world down)
  : > "$TMP_ROOT/down/unreachable"
  out=$(officer down run page-check --date "$KEY") || fail "an unreachable app must not fail the run: $out"
  assert_contains "$(cat "$home/data/officers/page-check/$KEY.md")" "Home: app unreachable" "the md names the unreachable app"
  assert_contains "$out" "DIGEST $KEY " "the run still produces its digest"
  pass "fm-officer page-check: an unreachable app is a finding, not a failed run"
}

test_scheduled_slot_and_read_only_boundary() {
  local home calls
  home=$(make_world slot)
  officer slot run page-check >/dev/null || fail "run with no date must succeed"
  assert_present "$home/data/officers/page-check/$KEY.json" "a run with no date takes the interval slot key"
  assert_equals "$KEY" "$(awk '{print $2}' "$home/data/officers/page-check/runs.log" | tail -1)" "runs.log is keyed by the slot"
  calls=$(cat "$TMP_ROOT/slot/fakebin/curl.calls")
  assert_not_contains "$calls" "-X" "no request carries a method override"
  assert_not_contains "$calls" "--data" "no request carries a body"
  assert_not_contains "$calls" "PUT" "no request writes"
  assert_equals 1 "$(grep -c '/api/captains-log$' "$TMP_ROOT/slot/fakebin/curl.calls")" "the Captain's Log is fetched once a run"
  assert_equals "" "$(grep -v '^api GET ' "$TMP_ROOT/slot/fakebin/gh.calls" || true)" "the forge is only read with GET requests"
  assert_equals "" "$(cd "$home" && find . -path ./data/officers/page-check -prune -o -newer "$home/data/officers.md" -type f -print | grep -v '^./state/' || true)" \
    "nothing outside the lane is written"
  pass "fm-officer page-check: a scheduled run takes the slot key and only reads"
}

test_registry_needs_an_https_app
test_findings_of_every_kind
test_bosun_rules_and_unexpected_shapes
test_unchanged_pages_stay_quiet_until_the_reminder
test_unreachable_app_is_a_finding_not_a_failed_run
test_scheduled_slot_and_read_only_boundary
