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
#
# With writes: linear (a fake linear-axi that logs every call): every open
# finding filed once in team PC, project Fleet, as Bug, agent and area:fleet, with
# no card words in the item, a later day raising the Found line in place, the
# create cap naming its overflow, a start request only for a page defect
# (page-old, shown-after-done) and never for a card a rule settles, a settled
# production-deploy card that is re-shown still starting its page fix (the reserved
# classes judge the fix, not the card's question), a finding whose own fix is in a
# reserved class held as one keyed needs-decision line, and a page defect's bad
# pattern remembered once, with no second line for a repeat.
set -u

# shellcheck source=tests/officer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/officer-helpers.sh"

OFFICER="$ROOT/bin/fm-officer.sh"
TMP_ROOT=$(fm_test_tmproot fm-officer-page-check)
KEY=2026-10-31T14
NOW=1793457000          # 2026-10-31T14:30:00Z
E=1793437200            # 2026-10-31T09:00:00Z
export TZ=UTC

# fake_linear <bindir>: linear-axi driven by $FAKE_LINEAR_DIR (labels.txt, exists.txt, state.<id>); it logs every
# call to $FAKE_LINEAR_DIR/log and refuses to run without that variable, so no test can reach the real Linear.
fake_linear() {
  cat > "$1/linear-axi" <<'SH'
#!/usr/bin/env bash
d=${FAKE_LINEAR_DIR:-}
[ -n "$d" ] || { echo '{"ok":false,"error":{"code":"UNKNOWN","message":"no fake linear dir"}}'; exit 1; }
printf '%s\n' "$*" >> "$d/log"
case "$1 $2" in
  "label list")
    printf '{"ok":true,"data":{"labels":['
    sep=''; while IFS= read -r l; do printf '%s{"name":"%s"}' "$sep" "$l"; sep=','; done < "$d/labels.txt"
    echo ']}}' ;;
  "issue search")
    q=${3#page-check-fp:}
    if [ -n "$q" ] && grep -qF -- "$q" "$d/exists.txt" 2>/dev/null; then
      echo '{"ok":true,"data":{"issues":[{"identifier":"PC-55"}]}}'
    else echo '{"ok":true,"data":{"issues":[]}}'; fi ;;
  "issue view")
    st=$(cat "$d/state.$3" 2>/dev/null || echo Todo)
    case "$st" in Done) ty=completed ;; *) ty=unstarted ;; esac
    desc="Found: $(cat "$d/count.$3" 2>/dev/null || echo 1) times (first 2026-10-20, last 2026-10-20, by page-check)"
    [ "$3" = PC-55 ] && desc="$desc\\npage-check-fp:$(tr -d '\n' < "$d/exists.txt")"
    echo '{"ok":true,"data":{"issue":{"identifier":"'"$3"'","state":"'"$st"'","stateType":"'"$ty"'","description":"'"$desc"'"}}}' ;;
  "issue create")
    case " $* " in
      *" --verify "*)
        n=$(( $(cat "$d/created" 2>/dev/null || echo 100) + 1 )); echo "$n" > "$d/created"
        for a in "$@"; do [ "${prev:-}" = "--body-file" ] && cat "$a" >> "$d/bodies" && echo >> "$d/bodies"; prev=$a; done
        echo '{"ok":true,"data":{"issue":{"identifier":"PC-'"$n"'"}}}' ;;
      *) echo '{"ok":true,"data":{"dryRun":true}}' ;;
    esac ;;
  "issue update")
    case " $* " in *" --verify "*) echo "UPDATE $3" >> "$d/updates" ;; esac
    echo '{"ok":true,"data":{"issue":{"identifier":"'"$3"'"}}}' ;;
  "issue comment")
    case " $* " in *" --verify "*) echo "COMMENT $3" >> "$d/comments" ;; esac
    echo '{"ok":true,"data":{"dryRun":true}}' ;;
  "issue relation") echo '{"ok":true,"data":{"dryRun":true}}' ;;
  *) echo '{"ok":false,"error":{"code":"UNKNOWN","message":"unexpected call"}}'; exit 1 ;;
esac
SH
  chmod +x "$1/linear-axi"
}
LINEAR_BIN="$TMP_ROOT/linear-bin"
mkdir -p "$LINEAR_BIN"
fake_linear "$LINEAR_BIN"
export PATH="$LINEAR_BIN:$PATH"

write_pages() {  # <dir>: the fleet app's pages, one file per GET path.
  local d=$1 k1 k2 k3
  k1="task-k-k1-$(printf 'task-k\0k1' | sha256sum | cut -c1-10)"
  k2="task-k-k2-$(printf 'task-k\0k2' | sha256sum | cut -c1-10)"
  k3="task-k-k3-$(printf 'task-k\0k3' | sha256sum | cut -c1-10)"
  mkdir -p "$d"
  jq -n --arg k1 "$k1" --arg k2 "$k2" --arg k3 "$k3" '{at: "2026-10-31T14:00:00Z", value: {updated: "2026-10-31T14:00:00Z", cards: [
    {id: "fine", band: "now", question: "Pick the logo", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "cleanup", band: "now", question: "Approve deleting 475 stale branches?", advice: "yes", replies: ["yes"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "old-ask", band: "now", question: "Which colour?", advice: "a", replies: ["a"], asked: "2026-10-20T12:00:00Z", state: "asked"},
    {id: "snoozed-old", band: "later", question: "Revisit the export", advice: "a", replies: ["a"], asked: "2026-10-20T12:00:00Z", state: "snoozed", until: "2026-10-28T00:00:00Z"},
    {id: "pr-card", band: "now", question: "Merge https://github.com/ex/repo/pull/7 and https://github.com/ex/repo/pull/8?", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "answered-shown", band: "now", question: "Sign off?", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked", answer: {text: "yes", at: "2026-10-31T13:00:00Z"}},
    {id: $k1, band: "now", question: "Which key?", advice: "a", replies: ["a"], asked: "2026-10-31T10:00:00Z", state: "asked"},
    {id: $k2, band: "now", question: "Which mode?", advice: "a", replies: ["a"], asked: "2026-10-31T08:00:00Z", state: "asked"},
    {id: $k3, band: "now", question: "Which size?", advice: "a", replies: ["a"], asked: "2026-10-31T10:00:00Z", state: "asked"},
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
resolved [key=k1] [at=$((E + 60))]: answered: Lee chose
needs-decision [at=$((E - 600))] [key=k2]: pick a mode
resolved [key=k2] [at=$((E + 60))]: answered: Lee chose
needs-decision [at=$((E - 600))] [key=k3]: pick a size
resolved [key=k3] [at=$((E + 60))]: decision-sweep
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
  "GET /repos/ex/repo/pulls/9") echo 'PRSTATE {"state":"closed","merged":true}' ;;
  "GET /repos/ex/repo/pulls/10") echo 'PRSTATE {"state":"closed","merged":false}' ;;
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
    "$(ids "$json" shown-after-done)" "a card re-raised after an answered status line, and one the app records closed; a routing-only resolve (k3) is not flagged"
  assert_equals "page-old:Business health:business-health page-old:Runs:bad-job page-old:Velocity audit:velocity-audit" \
    "$(ids "$json" page-old)" "an old page, a failing live job (not the retired one), and a page never published"
  assert_equals "$(jq '.findings | length' "$json")" "$(jq '.new | length' "$json")" "every first-seen finding is new"
  pass "fm-officer page-check: each finding kind is raised for the right object"
}

test_live_decisions_are_not_stale() {
  local home json k3 k4 k5 k6 pages
  home=$(make_world live)
  pages="$TMP_ROOT/live/pages"
  k3="task-k-k3-$(printf 'task-k\0k3' | sha256sum | cut -c1-10)"
  k4="task-k-k4-$(printf 'task-k\0k4' | sha256sum | cut -c1-10)"
  k5="task-k-k5-$(printf 'task-k\0k5' | sha256sum | cut -c1-10)"
  k6="task-k-k6-$(printf 'task-k\0k6' | sha256sum | cut -c1-10)"
  cat >> "$home/state/task-k.status" <<STATUS
needs-decision [at=$((E - 600))] [key=k3]: category word
resolved [key=k3] [at=$((E + 60))]: decision-sweep: PR landed
needs-decision [at=$((E - 600))] [key=k4]: category word
resolved [key=k4] [at=$((E + 60))]: captain hold k4: answered
needs-decision [at=$((E - 600))] [key=k5]: category word
resolved [key=k5] [at=$((E + 60))]: captain hold k5: released
needs-decision [at=$((E - 600))] [key=k6]: category word
resolved [key=k6] [at=$((E + 60))]: captain hold k6: reconciled
STATUS
  jq --arg k3 "$k3" --arg k4 "$k4" --arg k5 "$k5" --arg k6 "$k6" '.value.cards += [
    {id: "deploy-index", band: "now", question: "Deploy the index to production? https://github.com/ex/repo/pull/9", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "mentions-merge", band: "now", question: "Deploy the index to production now that the merge landed? https://github.com/ex/repo/pull/9", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "deploy-index-pc-1", band: "now", question: "Go for the index? https://github.com/ex/repo/pull/9", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "approve-fix", band: "now", question: "Approve https://github.com/ex/repo/pull/9? It will apply the fix", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "hold-ask", band: "now", question: "Release the hold for https://github.com/ex/repo/pull/9?", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "merge-word", band: "now", question: "Merge word for https://github.com/ex/repo/pull/9 to production?", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "approve-ci-run", band: "now", question: "Approve https://github.com/ex/repo/pull/9? Its CI run is green", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "hold-enables", band: "now", question: "Release the hold for https://github.com/ex/repo/pull/9? It enables the cache", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "mem-infra-v4-install", band: "now", question: "Go for v4? https://github.com/ex/repo/pull/9", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "skills-118-token-scope-probe-golive", band: "now", question: "Go for the probe? https://github.com/ex/repo/pull/9", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "run-these", band: "now", question: "Run these steps for https://github.com/ex/repo/pull/9?", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "closed-install", band: "now", question: "Install https://github.com/ex/repo/pull/10?", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "closed-deploy", band: "now", question: "Deploy https://github.com/ex/repo/pull/10 to production?", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: $k3, band: "now", question: "Which category word?", advice: "a", replies: ["a"], asked: "2026-10-31T08:00:00Z", state: "asked"},
    {id: $k4, band: "now", question: "Which category word?", advice: "a", replies: ["a"], asked: "2026-10-31T08:00:00Z", state: "asked"},
    {id: $k5, band: "now", question: "Which category word?", advice: "a", replies: ["a"], asked: "2026-10-31T08:00:00Z", state: "asked"},
    {id: $k6, band: "now", question: "Which category word?", advice: "a", replies: ["a"], asked: "2026-10-31T08:00:00Z", state: "asked"}]' \
    "$pages/_api_captains-log" > "$pages/log.tmp" && mv "$pages/log.tmp" "$pages/_api_captains-log"
  officer live run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  json="$home/data/officers/page-check/$KEY.json"
  assert_equals "approve-ci-run:ex/repo#9 approve-fix:ex/repo#9 closed-deploy:ex/repo#10 closed-install:ex/repo#10 hold-ask:ex/repo#9 hold-enables:ex/repo#9 merge-word:ex/repo#9" \
    "$(jq -r '[.findings[] | select(.kind == "stale-card" and (.id | test(":ex/repo#(9|10)$"))) | .id | sub("^stale-card:Captain.s Log:"; "")] | sort | join(" ")' "$json")" \
    "a merged PR stales a merge-word, approve or hold card even when it mentions a run or what the PR enables, but not a production card or a card that asks to run, install or go live; a closed-unmerged PR still flags"
  assert_equals "$(printf '%s\n' "$k4:resolved" "$k5:resolved" | sort | paste -sd' ')" \
    "$(jq -r --arg a "$k3" --arg b "$k4" --arg c "$k5" --arg d "$k6" '[.findings[] | select(.kind == "stale-card" and (.id | test("(" + $a + "|" + $b + "|" + $c + "|" + $d + "):resolved$"))) | .id | sub("^stale-card:Captain.s Log:"; "")] | sort | join(" ")' "$json")" \
    "a captain answer or release stales a card, not a routing sweep or a reconcile"
  pass "fm-officer page-check: an open production action and an unanswered decision are not stale"
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


count_lines() {  # <pattern> <file>: how many lines match; 0 when the file does not exist
  local n
  n=$(grep -c -- "$1" "$2" 2>/dev/null || true)
  echo "${n:-0}"
}

creates() {  # <log>: the number of verified creates in a fake Linear log
  count_lines "^issue create .*--verify" "$1"
}

# linear_world <name> [extra registry fields]: a world whose page-check line writes Linear items through the fake.
# Call it directly, not in $(...): it sets LW_HOME and FAKE_LINEAR_DIR for the test.
linear_world() {
  local name=$1 home
  home=$(make_world "$name")
  LW_HOME=$home
  printf -- '- page-check - Checks the fleet app pages (role: pagecheck; cadence: every 2h; app: https://app.test; writes: linear; jev: /nonexistent/jev.py%s; model: none; added 2026-10-31)\n' \
    "${2:-}" > "$home/data/officers.md"
  export FAKE_LINEAR_DIR="$TMP_ROOT/$name/linear"
  mkdir -p "$FAKE_LINEAR_DIR"
  printf '%s\n' Bug agent area:fleet > "$FAKE_LINEAR_DIR/labels.txt"
}

later_day() {  # <name> <key>: a run one day after the first
  local name=$1
  FM_OFFICER_NOW=$((NOW + 86400)) PATH="$TMP_ROOT/$name/fakebin:$PATH" FM_HOME="$TMP_ROOT/$name/home" "$OFFICER" run page-check --date "$2"
}

test_findings_are_filed_in_linear_under_the_contract() {
  local home json dir log n
  linear_world filing
  home=$LW_HOME
  dir=$FAKE_LINEAR_DIR
  log=$dir/log
  json="$home/data/officers/page-check/$KEY.json"
  officer filing run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  n=$(jq '.findings | length' "$json")
  assert_equals "$n" "$(creates "$log")" "every open finding is filed once"
  assert_equals "$n" "$(grep -c '^issue create .*--dry-run' "$log")" "every create is a dry run first, then a verified write"
  assert_equals "$n" "$(count_lines '^issue create .*--label Bug --label agent --label area:fleet --project Fleet --verify' "$log")" \
    "each item has one Type, the agent Source and area:fleet, in the Fleet project"
  assert_equals "$n" "$(count_lines '^page-check-fp:' "$dir/bodies")" "every body carries its fingerprint marker alone on its line"
  assert_equals "$n" "$(count_lines '^Found: 1 times (first 2026-10-31, last 2026-10-31, by page-check)$' "$dir/bodies")" "every body starts its one Found line"
  assert_no_grep "Approve deleting 475" "$dir/bodies" "no card question reaches Linear"
  assert_no_grep "Which key" "$dir/bodies" "no card question reaches Linear"
  assert_no_grep "Approve deleting 475" "$log" "nor a title or search"
  assert_contains "$(<"${json%.json}.md")" "- Linear: writes linear;" "the digest has a Linear line"
  assert_equals "true" "$(jq '[.findings[] | select(.linear.issue != null)] | all(.linear.found >= 1 and .linear.score > 0)' "$json")" \
    "the digest shows each filed finding's found count and score"

  officer filing run page-check --date "$KEY" >/dev/null || fail "a same-day re-run must succeed"
  assert_equals "$n" "$(creates "$log")" "a re-run the same day files nothing again"
  assert_equals "0" "$(count_lines '^UPDATE' "$dir/updates")" "and raises no Found line"

  later_day filing 2026-11-01T14 >/dev/null || fail "a later-day run must succeed"
  json="$home/data/officers/page-check/2026-11-01T14.json"
  assert_equals "" "$(grep '^page-check-fp:' "$dir/bodies" | sort | uniq -d)" "a later day files nothing twice, though pages that aged overnight add new findings"
  assert_equals "$n" "$(count_lines '^UPDATE' "$dir/updates")" "each item filed the first day has its Found line raised once, in place"
  assert_equals "$n" "$(count_lines '^COMMENT' "$dir/comments")" "with one comment on the day's first sighting"
  assert_equals "true" "$(jq '[.findings[] | select(.id == "page-old:Velocity audit:velocity-audit")][0].linear | .found == 2 and .score == 6.34' "$json")" \
    "the found count of 2 lifts a high finding's score from 4 to 6.34"
  pass "fm-officer page-check: every finding is filed once in Linear, the Found line rises in place, and no card words are sent"
}

test_page_defects_start_and_settled_cards_do_not() {
  local home json office
  linear_world starts
  home=$LW_HOME
  json="$home/data/officers/page-check/$KEY.json"
  officer starts run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  assert_equals "page-old:Velocity audit:velocity-audit" "$(jq -r '[.start_requests[] | select(.kind == "page-check-finding") | .id] | join(",")' "$json")" \
    "only the high page defect starts at found 1; a medium one needs a higher found count"
  assert_equals "0" "$(jq '[.start_requests[] | select(.id // "" | startswith("standing-rule") or startswith("stale-card"))] | length' "$json")" \
    "a card a standing rule settles, or a stale card, is filed and never started"
  assert_equals "true" "$(jq --arg h "$home" '[.start_requests[] | .execute |
      (.action == "start" and .env.FM_HOME == $h and (.request_id | test("^page-check-2026-10-31-[0-9a-f]{16}$")) and (.argv | length) == 7
       and (.argv[0] | endswith("/fm-inbox.sh")) and .argv[1:6] == ["note", "--request-id", .request_id, "--json", "--"])] | all' "$json")" \
    "the request is the inbox note call an office delivers, addressed to this home without a start-home"
  assert_equals "page-check-officer" "$(jq -r .source "$json")" "the digest names its source so an office delivers its start requests"
  assert_equals "$(jq '.start_requests | length' "$json")" "$(grep -c 'fm-inbox.sh' "$home/data/officers/page-check/$KEY.start-requests.sh")" \
    "this home's requests are also written as a shell handoff"
  officer starts run page-check --date "$KEY" >/dev/null || fail "a same-day re-run must succeed"
  assert_equals "1" "$(jq '[.start_requests[] | select(.kind == "page-check-finding")] | length' "$json")" "the request repeats on every run of the same day"
  later_day starts 2026-11-01T14 >/dev/null || fail "a later-day run must succeed"
  assert_equals "0" "$(jq '[.start_requests[] | select(.kind == "page-check-finding" and .id == "page-old:Velocity audit:velocity-audit")] | length' \
    "$home/data/officers/page-check/2026-11-01T14.json")" "a later day never asks twice"

  office="$TMP_ROOT/starts/office"
  mkdir -p "$office/state/inbox"
  PATH="$TMP_ROOT/starts/fakebin:$PATH" python3 -I "$ROOT/bin/fm-officer-page-check.py" run --key "$KEY" --out "$TMP_ROOT/starts/direct" \
    --app https://app.test --now "$NOW" --fm-home "$home" --start-home "$office=firstmate,skills,fleet-app=quartermaster=the fleet" \
    --writes linear --jev /nonexistent/jev.py >/dev/null || fail "a run with a start-home must succeed"
  assert_equals "$office" "$(jq -r '[.start_requests[].execute.env.FM_HOME] | unique | join(",")' "$TMP_ROOT/starts/direct/$KEY.json")" \
    "a page defect goes to the office that dispatches the fleet repositories"
  pass "fm-officer page-check: a page defect starts through the Quartermaster, a settled card never does"
}

test_no_writes_a_missing_label_and_the_cap() {
  local home json dir
  linear_world nowrites
  home=$LW_HOME
  printf -- '- page-check - Checks pages (role: pagecheck; cadence: every 2h; app: https://app.test; model: none; added 2026-10-31)\n' > "$home/data/officers.md"
  officer nowrites run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  assert_absent "$FAKE_LINEAR_DIR/log" "without writes: linear no Linear call is made"
  assert_equals "0" "$(jq '.start_requests | length' "$home/data/officers/page-check/$KEY.json")" "and nothing starts"

  linear_world nolabel
  home=$LW_HOME
  dir=$FAKE_LINEAR_DIR
  printf '%s\n' Bug area:fleet > "$dir/labels.txt"
  officer nolabel run page-check --date "$KEY" >/dev/null || fail "a run with a missing label must succeed"
  assert_equals "0" "$(creates "$dir/log")" "a label team PC lacks means nothing is filed"
  assert_contains "$(<"$home/data/officers/page-check/$KEY.md")" "Not filed" "and the digest says so"
  assert_equals "0" "$(jq '.start_requests | length' "$home/data/officers/page-check/$KEY.json")" "an unfiled finding is not started"

  linear_world capped "; max-creates: 2"
  home=$LW_HOME
  dir=$FAKE_LINEAR_DIR
  json="$home/data/officers/page-check/$KEY.json"
  officer capped run page-check --date "$KEY" >/dev/null || fail "a capped run must succeed"
  assert_equals "2" "$(creates "$dir/log")" "max-creates bounds the items one run creates"
  assert_contains "$(<"${json%.json}.md")" "Not filed (over max-creates for this run)" "the overflow is named in the digest"
  assert_equals "true" "$(jq '. as $d | [.start_requests[] | select(.kind == "page-check-finding") | .id] | all(. as $i | [$d.findings[] | select(.id == $i)][0].linear.issue != null)' "$json")" \
    "only a finding whose item exists is started"
  pass "fm-officer page-check: no writes, a missing label and the create cap bound what is filed and started"
}

# raise_to_start <name> <finding id>: files the world's findings, then makes the given finding's item read Found: 2, so the
# next day raises it to 3, which lifts a medium finding to the start minimum of 4. Prints the next day's digest path.
raise_to_start() {
  local name=$1 id=$2 json issue day2=2026-11-01T14
  officer "$name" run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  json="$LW_HOME/data/officers/page-check/$KEY.json"
  issue=$(jq -r --arg i "$id" '[.findings[] | select(.id == $i)][0].linear.issue' "$json")
  assert_not_contains "$issue" "null" "the finding $id is filed"
  printf 2 > "$FAKE_LINEAR_DIR/count.$issue"
  later_day "$name" "$day2" >/dev/null || fail "a later-day run must succeed"
  printf '%s\n' "$LW_HOME/data/officers/page-check/$day2.json"
}

test_a_settled_production_card_shown_again_starts_its_page_fix() {
  local json
  linear_world prodcard
  jq '.value.cards += [{id: "payments-legal-merge-asks-2026-11-07", band: "now", question: "Go for production deploy of 1.2.3?", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"}]' \
    "$TMP_ROOT/prodcard/pages/_api_captains-log" > "$TMP_ROOT/prodcard/captains-log.json"
  cp "$TMP_ROOT/prodcard/captains-log.json" "$TMP_ROOT/prodcard/pages/_api_captains-log"
  jq '.cards += [{id: "payments-legal-merge-asks-2026-11-07", lifecycle: "closed"}]' "$TMP_ROOT/prodcard/pages/_api_captains-log_facts_source_bosun" > "$TMP_ROOT/prodcard/facts.json"
  cp "$TMP_ROOT/prodcard/facts.json" "$TMP_ROOT/prodcard/pages/_api_captains-log_facts_source_bosun"
  json=$(raise_to_start prodcard "shown-after-done:Captain's Log:payments-legal-merge-asks-2026-11-07" | tail -n 1)
  assert_no_grep "production deploy" "$FAKE_LINEAR_DIR/bodies" "the card's words never reach Linear"
  assert_equals "1" "$(jq '[.start_requests[] | select(.kind == "page-check-finding" and .id == "shown-after-done:Captain'"'"'s Log:payments-legal-merge-asks-2026-11-07")] | length' "$json")" \
    "the re-shown card's page fix starts at the start minimum, though the card asks for a production deploy"
  assert_equals "0" "$(jq '[.held[] | select(.title | contains("payments-legal-merge-asks-2026-11-07"))] | length' "$json")" "and it is not held for Lee"
  pass "fm-officer page-check: a settled production-deploy card whose id names payments starts its fleet-app page fix when shown again"
}

test_a_fix_in_a_reserved_class_is_held_for_lee() {
  local json
  linear_world held
  jq '.jobs += [{id: "stripe-billing-sync", label: "Billing sync", officer: "bosun", state: "live", health: "failing", nextDueAt: "2026-11-01T00:00:00Z"}]' \
    "$TMP_ROOT/held/pages/_api_runs" > "$TMP_ROOT/held/runs.json"
  cp "$TMP_ROOT/held/runs.json" "$TMP_ROOT/held/pages/_api_runs"
  json=$(raise_to_start held "page-old:Runs:stripe-billing-sync" | tail -n 1)
  assert_equals "0" "$(jq '[.start_requests[] | select(.id == "page-old:Runs:stripe-billing-sync")] | length' "$json")" "a fix to a billing job is never started"
  assert_equals "1" "$(jq '.asks_for_lee | length' "$json")" "the run carries one needs-decision line"
  assert_equals "page-check-holds-2026-11-01" "$(jq -r '.asks_for_lee[0].key' "$json")" "it is keyed for the day"
  assert_contains "$(jq -r '.asks_for_lee[0].line' "$json")" "Runs job stripe-billing-sync: page-old (payments-billing)" "the line names the finding and its reserved class"
  pass "fm-officer page-check: a finding whose own fix is in a reserved class is filed and held for Lee, never started"
}

test_a_page_defect_pattern_is_remembered_once() {
  local home json day2
  linear_world patterns
  home=$LW_HOME
  json="$home/data/officers/page-check/$KEY.json"
  officer patterns run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  assert_equals "1" "$(jq '[.patterns.new[] | select(.line | startswith("Anti-pattern: page-old on Velocity audit "))] | length' "$json")" \
    "a new page-old finding yields one pattern line"
  assert_contains "$(jq -r '[.patterns.new[] | select(.line | contains("Velocity audit"))][0].line' "$json")" "Safe form: page owner: restore the page's feed" \
    "its safe form is the finding's route"
  assert_equals "true" "$(jq '[.patterns.new[].line] | all(startswith("Anti-pattern: page-old on ") or startswith("Anti-pattern: shown-after-done on "))' "$json")" \
    "a card a rule settles, or a stale card, is not a bug pattern"
  assert_equals "0" "$(jq '[.patterns.new[].line | select(contains("Bosun asks about an episode") or contains("bosun-ep"))] | length' "$json")" \
    "a pattern never carries a card's words or id"
  assert_equals "0" "$(jq '[.patterns.new[].line | select(test("[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]+ hour"))] | length' "$json")" "a pattern carries no timestamp or age"
  assert_equals "1 2" "$(jq -r '[.patterns.new[] | select(.line | startswith("Anti-pattern: shown-after-done on "))] | "\(length) \(.[0].count)"' "$json")" \
    "two cards re-shown on the same page are one pattern, counted twice"
  assert_equals "$(jq '.patterns.total' "$json")" "$(jq '[.start_requests[] | select(.kind == "pattern-memory") | .patterns[]] | length' "$json")" \
    "the new patterns go on in one pattern-memory start request"
  officer patterns run page-check --date "$KEY" >/dev/null || fail "a same-day re-run must succeed"
  assert_equals "1" "$(jq '[.patterns.new[] | select(.line | contains("Velocity audit"))] | length' "$json")" "a same-day re-run adds no second line"
  day2=2026-11-01T14
  later_day patterns "$day2" >/dev/null || fail "a later-day run must succeed"
  assert_equals "1" "$(jq '[.patterns[] | select(.title | contains("Velocity audit"))] | length' "$home/data/officers/page-check/patterns.json")" \
    "a repeat of the finding on a later day does not duplicate its pattern"
  assert_equals "1" "$(jq '[.patterns[] | select(.title | contains("Velocity audit"))][0].count' "$home/data/officers/page-check/patterns.json")" \
    "nor counts it again"
  assert_not_equals "$(jq -r '[.findings[] | select(.id | startswith("page-old:Business health"))][0].title' "$json")" \
    "$(jq -r '[.findings[] | select(.id | startswith("page-old:Business health"))][0].title' "$home/data/officers/page-check/$day2.json")" \
    "the Business health page is seen old on both days with a different age"
  assert_equals "1" "$(jq '[.patterns[] | select(.title | contains("Business health"))] | length' "$home/data/officers/page-check/patterns.json")" \
    "two sightings of the same old page with different timestamps give one pattern"
  assert_equals "0" "$(jq '[.patterns.new[] | select(.line | contains("Velocity audit"))] | length' "$home/data/officers/page-check/$day2.json")" \
    "and the later day lists it as known, not new"
  pass "fm-officer page-check: a page defect's bad pattern is remembered once, with its route as the safe form"
}

test_registry_needs_an_https_app
test_findings_of_every_kind
test_live_decisions_are_not_stale
test_bosun_rules_and_unexpected_shapes
test_unchanged_pages_stay_quiet_until_the_reminder
test_unreachable_app_is_a_finding_not_a_failed_run
test_scheduled_slot_and_read_only_boundary
test_findings_are_filed_in_linear_under_the_contract
test_page_defects_start_and_settled_cards_do_not
test_no_writes_a_missing_label_and_the_cap
test_a_settled_production_card_shown_again_starts_its_page_fix
test_a_fix_in_a_reserved_class_is_held_for_lee
test_a_page_defect_pattern_is_remembered_once
