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
# finding filed once in team FLEET, as Bug alone, with
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
  "issue list") echo '{"ok":true,"data":{"issues":[]}}' ;;  # no open bundle of an exact title yet
  "issue view")
    if [ -f "$d/view.$3" ]; then echo '{"ok":true,"data":{"issue":'"$(cat "$d/view.$3")"'}}'; exit 0; fi
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
    if [ -f "$d/fail-update.$3" ]; then echo '{"ok":false,"error":{"code":"UNKNOWN","message":"move refused"}}'; exit 1; fi
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
    {id: "parked-later", band: "later", question: "Free sign-up for test packs?", advice: "a", replies: ["a"], asked: "2026-10-20T12:00:00Z", state: "asked"},
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
  jq -n '{jobs: [{id: "ok-job", state: "live", health: "working", latest: {status: "finished", summary: "ok", finishedAt: "2026-10-31T04:00:00Z"}}, {id: "mute-job", label: "Mute job", officer: "bosun", state: "live", health: "working", latest: {status: "finished", summary: "", finishedAt: "2026-10-31T04:00:00Z"}}, {id: "busy-job", state: "live", health: "working", latest: {status: "running", summary: null}}, {id: "busy-mute-job", label: "Busy mute job", officer: "navigator", state: "live", health: "working", latest: {status: "running", summary: null}, lastDone: {status: "finished", summary: null, finishedAt: "2026-10-31T03:00:00Z"}}, {id: "idle-job", state: "live", health: "working", latest: null}, {id: "bad-job", label: "Bad job", officer: "bosun", state: "live", health: "failing", nextDueAt: "2026-11-01T00:00:00Z"}, {id: "gone", state: "retired", health: "failing"}]}' > "$d/_api_runs"
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
  assert_equals "page-old:Business health:business-health page-old:Runs:bad-job page-old:Runs:busy-mute-job page-old:Runs:mute-job page-old:Velocity audit:velocity-audit" \
    "$(ids "$json" page-old)" "an old page, a failing live job (not the retired one), a finished run with no summary, including the last finished run of a job now running (not one with a summary, a running one with no finished run, or a never-run job), and a page never published"
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
    {id: "linear-status-released", band: "now", question: "Add a Linear status named Released? https://github.com/ex/repo/pull/9", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "approve-prod-deploy", band: "now", question: "Approve the production deploy of https://github.com/ex/repo/pull/9?", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "hold-rollout", band: "now", question: "Lift the hold and roll out https://github.com/ex/repo/pull/9?", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "pc-123-review-golive", band: "now", question: "Go for the probe? https://github.com/ex/repo/pull/9", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "linear-status-was-held", band: "now", question: "Add a Linear status? https://github.com/ex/repo/pull/9 was on hold for review", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "review-ask", band: "now", question: "Review https://github.com/ex/repo/pull/9 before it ships?", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "closed-install", band: "now", question: "Install https://github.com/ex/repo/pull/10?", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: "closed-deploy", band: "now", question: "Deploy https://github.com/ex/repo/pull/10 to production?", advice: "a", replies: ["a"], asked: "2026-10-31T12:00:00Z", state: "asked"},
    {id: $k3, band: "now", question: "Which category word?", advice: "a", replies: ["a"], asked: "2026-10-31T08:00:00Z", state: "asked"},
    {id: $k4, band: "now", question: "Which category word?", advice: "a", replies: ["a"], asked: "2026-10-31T08:00:00Z", state: "asked"},
    {id: $k5, band: "now", question: "Which category word?", advice: "a", replies: ["a"], asked: "2026-10-31T08:00:00Z", state: "asked"},
    {id: $k6, band: "now", question: "Which category word?", advice: "a", replies: ["a"], asked: "2026-10-31T08:00:00Z", state: "asked"}]' \
    "$pages/_api_captains-log" > "$pages/log.tmp" && mv "$pages/log.tmp" "$pages/_api_captains-log"
  officer live run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  json="$home/data/officers/page-check/$KEY.json"
  assert_equals "approve-ci-run:ex/repo#9 approve-fix:ex/repo#9 closed-deploy:ex/repo#10 closed-install:ex/repo#10 hold-ask:ex/repo#9 hold-enables:ex/repo#9 merge-word:ex/repo#9 review-ask:ex/repo#9" \
    "$(jq -r '[.findings[] | select(.kind == "stale-card" and (.id | test(":ex/repo#(9|10)$"))) | .id | sub("^stale-card:Captain.s Log:"; "")] | sort | join(" ")' "$json")" \
    "a merged PR stales a merge-word, approve or hold card even when it mentions a run or what the PR enables, a review ask too, but not a production card (even one worded approve or hold), a card that asks to run, install or go live, or one that asks for a Linear status, even when a hold or review word describes the PR; a closed-unmerged PR still flags"
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
  local home json dir log n b
  linear_world filing
  home=$LW_HOME
  dir=$FAKE_LINEAR_DIR
  log=$dir/log
  json="$home/data/officers/page-check/$KEY.json"
  officer filing run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  n=$(jq '.findings | length' "$json")
  b=$(jq '[.findings[].linear.issue] | unique | length' "$json")
  assert_equals "$b" "$(jq '[.findings[] | .page] | unique | length' "$json")" "the open findings go to one bundle per page"
  assert_equals "$b" "$(creates "$log")" "one item per bundle, not one per finding"
  assert_equals "$b" "$(grep -c '^issue create .*--dry-run' "$log")" "every create is a dry run first, then a verified write"
  assert_equals "$b" "$(count_lines '^issue create --team FLEET --title Automated findings: .* (page check) .*--label Bug --verify' "$log")" \
    "each item is titled by its page, with one Type, in team FLEET"
  assert_equals "0" "$(count_lines '^issue create .*\(--label agent\|--label area:fleet\|--project\)' "$log")" "with no Source label, no area label and no project"
  assert_equals "$n" "$(count_lines '^- \[ \] page-check-fp:' "$dir/bodies")" "every finding is one checklist line carrying its fingerprint"
  assert_equals "$b" "$(count_lines '^page-check-fp:' "$dir/bodies")" "and each bundle's own marker is alone on its line"
  assert_no_grep "Approve deleting 475" "$dir/bodies" "no card question reaches Linear"
  assert_no_grep "Which key" "$dir/bodies" "no card question reaches Linear"
  assert_no_grep "Approve deleting 475" "$log" "nor a title or search"
  assert_contains "$(<"${json%.json}.md")" "- Linear: writes linear;" "the digest has a Linear line"
  assert_equals "true" "$(jq '[.findings[] | select(.linear.issue != null)] | all(.linear.found >= 1 and .linear.score > 0)' "$json")" \
    "the digest shows each filed finding's found count and score"

  officer filing run page-check --date "$KEY" >/dev/null || fail "a same-day re-run must succeed"
  assert_equals "$b" "$(creates "$log")" "a re-run the same day files nothing again"
  assert_equals "0" "$(count_lines '^UPDATE' "$dir/updates")" "and rewrites no bundle"

  later_day filing 2026-11-01T14 >/dev/null || fail "a later-day run must succeed"
  json="$home/data/officers/page-check/2026-11-01T14.json"
  assert_equals "" "$(grep '^issue create .*--verify' "$log" | sed 's/.*--title \(.*\) --body-file.*/\1/' | sort | uniq -d)" \
    "a later day opens no second bundle for a page, though pages that aged overnight add new findings"
  assert_equals "0" "$(count_lines '^COMMENT' "$dir/comments")" "a bundle gets no per-finding comment"
  assert_equals "true" "$(jq '[.findings[] | select(.id == "page-old:Velocity audit:velocity-audit")][0].linear | .found == 2 and .score == 6.34' "$json")" \
    "the finding's own found count of 2 lifts a high finding's score from 4 to 6.34"
  pass "fm-officer page-check: every finding is filed once in its page's bundle, its found count rises, and no card words are sent"
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
  printf '%s\n' agent area:fleet > "$dir/labels.txt"
  officer nolabel run page-check --date "$KEY" >/dev/null || fail "a run with a missing label must succeed"
  assert_equals "0" "$(creates "$dir/log")" "a Type label team FLEET lacks means nothing is filed"
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

# raise_to_start <name> <finding id>: files the world's findings, then makes the given finding's found count 2, so the
# next day raises it to 3, which lifts a medium finding to the start minimum of 4. Prints the next day's digest path.
raise_to_start() {
  local name=$1 id=$2 json issue fp day2=2026-11-01T14
  officer "$name" run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  json="$LW_HOME/data/officers/page-check/$KEY.json"
  issue=$(jq -r --arg i "$id" '[.findings[] | select(.id == $i)][0].linear.issue' "$json")
  assert_not_contains "$issue" "null" "the finding $id is filed"
  printf 2 > "$FAKE_LINEAR_DIR/count.$issue"
  # A bundled finding keeps its own found count: the later day makes it 3, enough to start.
  fp=$(printf '%s\0%s\0%s' "${id%%:*}" "$(cut -d: -f2 <<<"$id")" "$id" | sha256sum | cut -d' ' -f1)
  jq --arg fp "$fp" '.members[$fp].count = 2' "$LW_HOME/data/officers/page-check/found.json" > "$LW_HOME/data/officers/page-check/found.tmp" \
    && mv "$LW_HOME/data/officers/page-check/found.tmp" "$LW_HOME/data/officers/page-check/found.json"
  later_day "$name" "$day2" >/dev/null || fail "a later-day run must succeed"
  printf '%s\n' "$LW_HOME/data/officers/page-check/$day2.json"
}

test_a_closed_item_is_bumped_and_never_started() {
  local home json dir fp n
  linear_world closedprobe
  officer closedprobe run page-check --date "$KEY" >/dev/null || fail "probe run must succeed"
  fp=$(sed -n 's/^- \[ \] page-check-fp:\([0-9a-f]*\) Velocity audit: page-old velocity-audit .*/\1/p' "$FAKE_LINEAR_DIR/bodies" | head -1)
  n=$(creates "$FAKE_LINEAR_DIR/log")
  assert_not_contains "$fp" " " "the probe finds the velocity-audit fingerprint"
  linear_world closedhit
  home=$LW_HOME
  dir=$FAKE_LINEAR_DIR
  printf '%s\n' "$fp" > "$dir/exists.txt"
  echo Done > "$dir/state.PC-55"
  json="$home/data/officers/page-check/$KEY.json"
  officer closedhit run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  assert_equals "PC-55" "$(jq -r '[.findings[] | select(.id == "page-old:Velocity audit:velocity-audit")][0].linear.issue' "$json")" \
    "the repeat of a closed item matches it by fingerprint"
  assert_equals "$((n - 1))" "$(creates "$dir/log")" "and files no new item for it"
  assert_equals "UPDATE PC-55" "$(cat "$dir/updates")" "its Found line is raised"
  assert_equals "COMMENT PC-55" "$(cat "$dir/comments")" "with the day's one comment"
  assert_equals 0 "$(grep '^issue update' "$dir/log" | grep -c -- '--state\|--priority')" "it is never reopened or re-prioritised"
  assert_equals "0" "$(jq '[.start_requests[] | select(.linear_id == "PC-55" or .id == "page-old:Velocity audit:velocity-audit")] | length' "$json")" \
    "a closed item is never started"
  officer closedhit run page-check --date 2026-10-31T16 >/dev/null || fail "a same-day second slot must succeed"
  assert_equals "0" "$(jq '[.start_requests[] | select(.linear_id == "PC-55")] | length' "$home/data/officers/page-check/2026-10-31T16.json")" \
    "nor in a second slot the same day"
  later_day closedhit 2026-11-01T14 >/dev/null || fail "a later-day run must succeed"
  assert_equals "0" "$(jq '[.start_requests[] | select(.linear_id == "PC-55")] | length' "$home/data/officers/page-check/2026-11-01T14.json")" \
    "nor on a later day, from the ledger"
  echo Todo > "$dir/state.PC-55"
  FM_OFFICER_NOW=$((NOW + 2 * 86400)) PATH="$TMP_ROOT/closedhit/fakebin:$PATH" FM_HOME="$home" "$OFFICER" run page-check --date 2026-11-02T14 >/dev/null \
    || fail "a run after a person reopens the item must succeed"
  assert_equals "1" "$(jq '[.start_requests[] | select(.linear_id == "PC-55")] | length' "$home/data/officers/page-check/2026-11-02T14.json")" \
    "once a person reopens it, the item starts like any open item"
  assert_equals 0 "$(grep -cF -- "page-check-fp:$fp" "$dir/bodies")" "and no run re-files it"
  pass "fm-officer page-check: a closed item that recurs is bumped, never re-filed or started"
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
  assert_equals "1" "$(jq '[.findings[] | select(.id == "page-old:Runs:bad-job" and .linear.issue != null)] | length' "$json")" \
    "the failing-job finding (route: page owner: fix the job) is still filed for its owner"
  assert_equals "0" "$(jq '[.patterns.new[].line | select(contains("bad-job") or contains("Safe form: page owner: fix the job."))] | length' "$json")" \
    "a failing-job finding is a stale run, not a code anti-pattern, so it yields no pattern line"
  assert_contains "$(jq -r '[.patterns.new[] | select(.line | contains("Velocity audit"))][0].line' "$json")" "Safe form: page owner: restore the page's feed" \
    "its safe form is the finding's route"
  assert_equals "true" "$(jq '[.patterns.new[].line] | all(startswith("Anti-pattern: page-old on ") or startswith("Anti-pattern: shown-after-done on "))' "$json")" \
    "a card a rule settles, or a stale card, is not a bug pattern"
  assert_equals "0" "$(jq '[.patterns.new[].line | select(contains("Bosun asks about an episode") or contains("bosun-ep"))] | length' "$json")" \
    "a pattern never carries a card's words or id"
  assert_equals "0" "$(jq '[.patterns.new[].line | select(test("[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]+ hour"))] | length' "$json")" "a pattern carries no timestamp or age"
  assert_equals "1 2" "$(jq -r '[.patterns.new[] | select(.line | startswith("Anti-pattern: shown-after-done on "))] | "\(length) \(.[0].count)"' "$json")" \
    "two cards re-shown on the same page are one pattern, counted twice"
  assert_equals "1 true" "$(jq -r '[.start_requests[] | select(.kind == "pattern-memory") | .patterns[]] | "\(length) \(all(.line | startswith("Anti-pattern: shown-after-done on ") and contains(". Safe form: ")))"' "$json")" \
    "only the twice-seen shown-after-done pattern (not the one-off page-old ones) goes on in the pattern-memory start request, with its route as the safe form"
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


# seed_own_item <id> <kind> <page> <ref> [opening] [extra issue json fields] [evidence]: a single item the officer
# filed on an earlier day, as its ledger and the fake Linear hold it. Sets SEED_FP; the lane state is the world's.
seed_own_item() {
  local id=$1 kind=$2 page=$3 ref=$4 opening=${5:-Filed by the page-check officer from the 2026-11-07T10 page check.} extra=${6:-\{\}} evidence=${7:-the card was open}
  local lane="$LW_HOME/data/officers/page-check" desc
  SEED_FP=$(printf '%s\0%s\0%s' "$kind" "$page" "$kind:$page:$ref" | sha256sum | cut -c1-64)
  desc="$opening
What it is for: a fleet-app page that shows a card a rule already settles, a stale card, a card shown after it was settled, or an old page.
Epic: not assigned; whoever triages this picks one.

Severity: low. Kind: $kind. Page: $page. Object: $ref.
Found: 1 times (first 2026-11-07, last 2026-11-07, by page-check)
Evidence: $evidence.
Route: cl-keeper: close.
page-check-fp:$SEED_FP"
  mkdir -p "$lane"
  jq -n --arg id "$id" --arg d "$desc" --argjson x "$extra" '{identifier: $id, title: "Captain'"'"'s Log: seeded", state: "Todo", stateType: "unstarted", description: $d} + $x' \
    > "$FAKE_LINEAR_DIR/view.$id"
  [ -f "$lane/filed-fingerprints.json" ] || echo '{}' > "$lane/filed-fingerprints.json"
  jq --arg fp "$SEED_FP" --arg id "$id" '.[$fp] = $id' "$lane/filed-fingerprints.json" > "$lane/l.tmp" && mv "$lane/l.tmp" "$lane/filed-fingerprints.json"
}

closes_of() {  # <id>: the verified close moves of an item in the fake Linear log
  count_lines "^issue update $1 --state Done --verify" "$FAKE_LINEAR_DIR/log"
}

test_the_officer_closes_its_own_items_when_the_finding_is_over() {
  local dir log lc ln
  linear_world autoclose
  dir=$FAKE_LINEAR_DIR
  log=$dir/log
  seed_own_item PC-71 stale-card "Captain's Log" "gone-card:unanswered"
  seed_own_item PC-72 page-old "Business health" "business-health-old"
  seed_own_item PC-73 stale-card "Captain's Log" "fine:unanswered"
  officer autoclose run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  assert_equals "1" "$(closes_of PC-71)" "an item whose card is gone from the Captain's Log closes at once"
  lc=$(grep -n '^issue comment PC-71 .*--verify' "$log" | head -1 | cut -d: -f1)
  ln=$(grep -n '^issue update PC-71 --state Done --verify' "$log" | cut -d: -f1)
  assert_equals "true" "$([ -n "$lc" ] && [ -n "$ln" ] && [ "$lc" -lt "$ln" ] && echo true || echo false)" "the reason comment is posted before the move to Done"
  assert_contains "$(grep '^issue comment PC-71 .*--dry-run' "$log" | head -1)" "card gone-card settled at" "the comment says the card settled, and when"
  assert_equals "0" "$(closes_of PC-72)" "a page-old item does not close on its first absent check"
  assert_equals "0" "$(closes_of PC-73)" "a stale-card item whose card is still shown does not close on rule (a)"
  assert_contains "$(<"$LW_HOME/data/officers/page-check/$KEY.md")" "Closed own item PC-71: card gone-card settled" "the digest names the close"
  officer autoclose run page-check --date "$KEY" >/dev/null || fail "a same-key re-run must succeed"
  assert_equals "0" "$(closes_of PC-72)" "a re-run of the same check is not a second check"
  assert_equals "1" "$(closes_of PC-71)" "and a closed item is not closed again"
  later_day autoclose 2026-11-01T14 >/dev/null || fail "a later check must succeed"
  assert_equals "1" "$(closes_of PC-72)" "an item closes once its finding is absent from two checks"
  assert_equals "1" "$(closes_of PC-73)" "and so does a card item whose card is still shown"
  assert_contains "$(grep '^issue comment PC-72 .*--dry-run' "$log" | head -1)" "not recurred in two checks: $KEY, 2026-11-01T14" "the comment names the two checks"
  assert_equals "0" "$(count_lines 'delete' "$log")" "nothing is ever deleted"
  pass "fm-officer page-check: an own item closes when its card settles or its finding is absent from two checks, comment first"
}

test_the_officer_leaves_items_it_may_not_close() {
  local dir fp id
  linear_world keepopen
  dir=$FAKE_LINEAR_DIR
  seed_own_item PC-81 stale-card "Captain's Log" "gone-card:a" "A person wrote this item."
  seed_own_item PC-82 stale-card "Captain's Log" "gone-card:b" "" '{"stateType":"started","state":"In Progress"}'
  seed_own_item PC-83 stale-card "Captain's Log" "gone-card:c" "" '{"assignee":"lee"}'
  seed_own_item PC-84 stale-card "Captain's Log" "gone-card:d" "" '{}' "rotate the signing keys"
  seed_own_item PC-85 stale-card "Captain's Log" "gone-card:e" "" '{"stateType":"completed","state":"Done"}'
  # An item whose finding is still in the check: the Business health page is old, so its finding recurs.
  id="page-old:Business health:business-health"
  seed_own_item PC-86 page-old "Business health" "business-health"
  fp=$(printf '%s\0%s\0%s' page-old "Business health" "$id" | sha256sum | cut -c1-64)
  jq --arg fp "$fp" '.[$fp] = "PC-86"' "$LW_HOME/data/officers/page-check/filed-fingerprints.json" > "$dir/l.tmp" && mv "$dir/l.tmp" "$LW_HOME/data/officers/page-check/filed-fingerprints.json"
  jq --arg fp "$fp" '.description |= sub("page-check-fp:.*$"; "page-check-fp:" + $fp)' "$dir/view.PC-86" > "$dir/v.tmp" && mv "$dir/v.tmp" "$dir/view.PC-86"
  officer keepopen run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  later_day keepopen 2026-11-01T14 >/dev/null || fail "a later check must succeed"
  for id in PC-81 PC-82 PC-83 PC-84 PC-85 PC-86; do
    assert_equals "0" "$(closes_of "$id")" "$id is not closed"
  done
  assert_equals "0" "$(count_lines '^issue comment PC-8[1-6] --body Closed by' "$dir/log")" "and gets no close comment"
  assert_contains "$(<"$LW_HOME/data/officers/page-check/2026-11-01T14.md")" "PC-82 is started" "a started item is named, not closed"
  assert_contains "$(<"$LW_HOME/data/officers/page-check/2026-11-01T14.md")" "PC-84 is in a reserved class" "a reserved-class item is named, not closed"
  pass "fm-officer page-check: a person's, started, assigned, reserved-class, person-closed or still-recurring item is never closed"
}

test_closing_needs_writes_linear_and_budget() {
  local home dir
  linear_world nowriteclose
  home=$LW_HOME
  dir=$FAKE_LINEAR_DIR
  seed_own_item PC-91 stale-card "Captain's Log" "gone-card:a"
  printf -- '- page-check - Checks pages (role: pagecheck; cadence: every 2h; app: https://app.test; model: none; added 2026-10-31)\n' > "$home/data/officers.md"
  officer nowriteclose run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  later_day nowriteclose 2026-11-01T14 >/dev/null || fail "a later run must succeed"
  assert_absent "$dir/log" "without writes: linear no Linear call is made, so nothing is closed"

  linear_world budgetclose "; max-linear-calls: 3"
  dir=$FAKE_LINEAR_DIR
  seed_own_item PC-92 stale-card "Captain's Log" "gone-card:a"
  officer budgetclose run page-check --date "$KEY" >/dev/null || fail "a run that exhausts its budget must succeed"
  assert_equals "0" "$(closes_of PC-92)" "an exhausted call budget closes nothing"
  assert_equals "true" "$([ "$(wc -l < "$dir/log" | tr -d ' ')" -le 3 ] && echo true || echo false)" "and no call goes past the budget"
  pass "fm-officer page-check: no close without writes: linear, and none past the call budget"
}

test_a_check_that_could_not_see_the_finding_does_not_count() {
  local dir pages fakebin
  linear_world unreadclose
  dir=$FAKE_LINEAR_DIR
  pages="$TMP_ROOT/unreadclose/pages"
  fakebin="$TMP_ROOT/unreadclose/fakebin"
  seed_own_item PC-93 page-old "Business health" "business-health-old"
  seed_own_item PC-94 stale-card "Captain's Log" "pr-card:ex/repo#7" "" '{}' "names ex/repo#7, which is merged"
  mv "$pages/_api_business-health" "$pages/business-health.saved"
  cp "$fakebin/gh-axi" "$fakebin/gh-axi.saved"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/gh-axi"
  officer unreadclose run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  later_day unreadclose 2026-11-01T14 >/dev/null || fail "a later check must succeed"
  assert_equals "0" "$(closes_of PC-93)" "two checks that could not read the item's page do not close it"
  assert_equals "0" "$(closes_of PC-94)" "two checks that could not read the PR a stale-card item names do not close it"
  assert_equals "0" "$(count_lines '^issue comment PC-9[34] ' "$dir/log")" "and neither item gets a close comment"
  mv "$pages/business-health.saved" "$pages/_api_business-health"
  mv "$fakebin/gh-axi.saved" "$fakebin/gh-axi"
  later_day unreadclose 2026-11-01T16 >/dev/null || fail "a readable check must succeed"
  assert_equals "0" "$(closes_of PC-93)" "the first check that read the page is only one check"
  later_day unreadclose 2026-11-01T18 >/dev/null || fail "a second readable check must succeed"
  assert_equals "1" "$(closes_of PC-93)" "the second check that read the page closes the item"
  assert_equals "0" "$(closes_of PC-94)" "a stale-card item whose PR finding recurs once the PR is read stays open"
  pass "fm-officer page-check: a check that could not read a finding's page or PR does not count toward closing it"
}

test_an_unread_rules_file_or_card_record_does_not_count() {
  local dir home pages
  linear_world unreadinputs
  dir=$FAKE_LINEAR_DIR
  home=$LW_HOME
  pages="$TMP_ROOT/unreadinputs/pages"
  seed_own_item PC-96 standing-rule "Captain's Log" "cleanup:routine-cleanup"
  seed_own_item PC-97 shown-after-done "Captain's Log" "bosun-ep"
  mv "$home/data/captain-shared.md" "$home/data/captain-shared.saved"
  mv "$pages/_api_captains-log_facts_source_bosun" "$pages/facts.saved"
  officer unreadinputs run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  later_day unreadinputs 2026-11-01T14 >/dev/null || fail "a later check must succeed"
  assert_equals "0" "$(closes_of PC-96)" "two checks that could not read the standing rules do not close a standing-rule item"
  assert_equals "0" "$(closes_of PC-97)" "two checks that could not read the card record do not close a shown-after-done item"
  assert_equals "0" "$(count_lines '^issue comment PC-9[67] ' "$dir/log")" "and neither item gets a close comment"
  pass "fm-officer page-check: an unread rules file or card record does not count toward closing a card item"
}

test_a_log_without_cards_does_not_count() {
  local dir pages
  linear_world nocards
  dir=$FAKE_LINEAR_DIR
  pages="$TMP_ROOT/nocards/pages"
  seed_own_item PC-99 stale-card "Captain's Log" "old-ask:unanswered"
  jq '.value = null' "$pages/_api_captains-log" > "$pages/log.tmp" && mv "$pages/log.tmp" "$pages/_api_captains-log"
  officer nocards run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  later_day nocards 2026-11-01T14 >/dev/null || fail "a later check must succeed"
  assert_equals "0" "$(closes_of PC-99)" "two checks of a Captain's Log with no card list do not close a card item"
  assert_equals "0" "$(count_lines '^issue comment PC-99 ' "$dir/log")" "and it gets no close comment"
  pass "fm-officer page-check: a Captain's Log read without a card list does not count toward closing a card item"
}

test_a_recurrence_in_a_blocked_check_resets_the_count() {
  local dir home pages reg
  linear_world blockedreset
  dir=$FAKE_LINEAR_DIR
  home=$LW_HOME
  pages="$TMP_ROOT/blockedreset/pages"
  reg=$(<"$home/data/officers.md")
  seed_own_item PC-98 page-old "Business health" "business-health"
  jq -n '{value: {generated_at: "2026-10-31T14:00:00Z"}}' > "$pages/_api_business-health"
  officer blockedreset run page-check --date "$KEY" >/dev/null || fail "a check without the finding must succeed"
  jq -n '{value: {generated_at: "2026-10-29T06:00:00Z"}}' > "$pages/_api_business-health"
  printf '%s\n' "${reg/; model:/; max-linear-calls: 1; model:}" > "$home/data/officers.md"
  later_day blockedreset 2026-11-01T14 >/dev/null || fail "a check whose filing stops must succeed"
  assert_contains "$(<"$home/data/officers/page-check/2026-11-01T14.md")" "stopped:" "the check with the finding back stops on its call budget"
  printf '%s\n' "$reg" > "$home/data/officers.md"
  jq -n '{value: {generated_at: "2026-11-01T14:00:00Z"}}' > "$pages/_api_business-health"
  later_day blockedreset 2026-11-01T16 >/dev/null || fail "a third check must succeed"
  assert_equals "0" "$(closes_of PC-98)" "a finding absent, back in a stopped check, then absent again has one absent check, not two"
  pass "fm-officer page-check: a finding present in a check whose filing stopped still resets its absent count"
}

test_a_failed_move_is_retried_without_a_second_comment() {
  local dir
  linear_world retryclose
  dir=$FAKE_LINEAR_DIR
  seed_own_item PC-95 stale-card "Captain's Log" "gone-card:a"
  touch "$dir/fail-update.PC-95"
  officer retryclose run page-check --date "$KEY" >/dev/null || fail "a run whose move fails must succeed"
  assert_equals "1" "$(count_lines '^issue comment PC-95 .*--verify' "$dir/log")" "the reason comment lands before the failed move"
  assert_equals "0" "$(closes_of PC-95)" "the move did not land"
  mv "$dir/fail-update.PC-95" "$dir/fail-update.off"
  later_day retryclose 2026-11-01T14 >/dev/null || fail "a later check must succeed"
  assert_equals "1" "$(closes_of PC-95)" "the next check retries the move"
  assert_equals "1" "$(count_lines '^issue comment PC-95 .*--verify' "$dir/log")" "and posts no second close comment"
  pass "fm-officer page-check: a close whose move failed is retried without a second comment"
}

# commit_world <name>: a world whose home carries a register covering every spec type, green and red, and a second
# local home (navigator, through data/secondmates.md) with a status log. Prints the home.
commit_world() {
  local name=$1 home nav t="$TMP_ROOT/$1" hook logs
  home=$(make_world "$name")
  nav="$t/navigator"
  mkdir -p "$nav/state" "$nav/data" "$t/proof"
  nav=$(cd "$nav" && pwd -P)
  printf -- '- navigator - nav (home: %s; scope: office; projects: none; added 2026-11-04)\n' "$nav" > "$home/data/secondmates.md"
  hook="$t/proof/landing-hook.sh"
  printf '#!/bin/sh\nexec gate-ledger.py "$@"\n' > "$hook"
  logs="$t/proof/logs"
  mkdir -p "$logs"
  printf '%s\n' '==> dotnet build ok' '==> dotnet build skipped (cached)' > "$logs/admission-one.log"
  printf '%s\n' '==> dotnet build ok' '==> dotnet build again' > "$logs/admission-two.log"
  printf '%s\n' '==> dotnet build skipped' > "$logs/admission-three.log"
  printf '[at=%d] gate-ledger recorded\n' "$((NOW - 3600))" > "$logs/ledger-fresh.log"
  printf '[at=%d] gate-ledger recorded\n' "$((NOW - 30 * 3600))" > "$logs/ledger-old.log"
  : > "$t/proof/receipt-fresh.json"
  : > "$t/proof/receipt-old.json"
  touch -d "@$((NOW - 2 * 3600))" "$t/proof/receipt-fresh.json"
  touch -d "@$((NOW - 40 * 3600))" "$t/proof/receipt-old.json"
  printf 'working [at=%d]: ledger attributed\n' "$((NOW - 7200))" > "$nav/state/task-n.status"
  row() {  # <id> <enforcement> <verify> [add args]
    local id=$1 enf=$2 ver=$3
    shift 3
    FM_HOME="$home" bash "$ROOT/bin/fm-commitment.sh" add --id "$id" --commitment "The $id commitment" \
      --lee-words 'Lee, main chat, 2026-11-25: "from now on"' --enforcement "$enf" --verify "$ver" "$@" >/dev/null \
      || fail "could not record row $id"
  }
  row g-file "file:$hook#contains=gate-ledger.py" "file:$t/proof/receipt-*.json;max-age=26h" --owner navigator
  row r-file-stale "file:$hook" "file:$t/proof/receipt-old.json;max-age=26h"
  row r-file-none "file:$hook" "file:$t/proof/no-such-*.json"
  row g-log "file:$hook" "log:$logs/ledger-*.log;regex=gate-ledger recorded;max-age=6h"
  row r-log-old "file:$hook" "log:$logs/ledger-old.log;regex=gate-ledger recorded;max-age=6h"
  row r-log-nomatch "file:$hook" "log:$logs/ledger-fresh.log;regex=attributed"
  row g-count "file:$hook" "log:$logs/admission-one.log;regex=^==> dotnet build(?!.*skipped);max-count=1"
  row r-count "file:$hook" "log:$logs/admission-*.log;regex=^==> dotnet build(?!.*skipped);max-count=1"
  row g-status "file:$hook" "status:navigator;regex=ledger attributed;max-age=12h"
  row r-status-old "file:$hook" "status:navigator;regex=ledger attributed;max-age=1h"
  row r-status-home "file:$hook" "status:nowhere;regex=x"
  row r-memory memory none --owner slarti
  row r-none-both none none --owner navigator
  printf '#!/bin/sh\nexec gate-ledger.py "$@"\n' > "$t/proof/removed-hook.sh"
  row r-hook-gone "file:$t/proof/removed-hook.sh#contains=gate-ledger.py" "file:$t/proof/receipt-fresh.json"
  /usr/bin/trash "$t/proof/removed-hook.sh" || fail "could not trash the fixture hook"
  row retired-red none none
  FM_HOME="$home" bash "$ROOT/bin/fm-commitment.sh" retire --id retired-red --reason 'superseded' >/dev/null || fail "could not retire"
  # A hand-edited row whose enforcement spec is malformed.
  jq '.rows += [{id: "r-malformed", commitment: "bad", lee_words: "w", owner: "x", enforcement: "bogus", verify: "none", recorded_at: "2026-11-25T00:00:00Z", retired: null}]' \
    "$home/data/standing-commitments.json" > "$t/reg.tmp" && mv "$t/reg.tmp" "$home/data/standing-commitments.json"
  printf '%s\n' "$home"
}

commit_ids() {  # <json> <kind>
  jq -r --arg k "$2" '[.findings[] | select(.kind == $k) | .id | sub("^[^:]*:Standing commitments:"; "")] | sort | join(" ")' "$1"
}

test_every_spec_type_is_green_or_red_in_the_digest() {
  local home json md
  home=$(commit_world commits)
  officer commits run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  json="$home/data/officers/page-check/$KEY.json"
  md=$(<"$home/data/officers/page-check/$KEY.md")
  assert_equals "$(basename "$home"):r-count $(basename "$home"):r-file-none $(basename "$home"):r-file-stale $(basename "$home"):r-hook-gone $(basename "$home"):r-log-nomatch $(basename "$home"):r-log-old $(basename "$home"):r-malformed $(basename "$home"):r-memory $(basename "$home"):r-none-both $(basename "$home"):r-status-home $(basename "$home"):r-status-old" \
    "$(commit_ids "$json" commitment-unproven)" "every red row is one commitment-unproven finding; green rows and the retired row raise none"
  assert_equals "high" "$(jq -r '[.findings[] | select(.kind == "commitment-unproven") | .severity] | unique | join(",")' "$json")" "commitment-unproven is high"
  assert_equals "owner home: enforce or retire the commitment" "$(jq -r '[.findings[] | select(.kind == "commitment-unproven") | .route] | unique | join(",")' "$json")" "the route names the owner home"
  assert_contains "$md" "## Standing commitments" "the digest has a Standing commitments section"
  assert_contains "$md" "15 row(s): 4 green, 11 red. 1 retired row(s) not checked." "the section counts every unretired row and the retired one"
  assert_contains "$md" "GREEN $(basename "$home")/g-file" "a green row is listed"
  assert_contains "$md" "GREEN $(basename "$home")/g-status" "a status row with a fresh matching line is green"
  assert_contains "$md" "enforcement: enforcement is a memory note only, which is not enforcement" "a memory row is red and says so"
  assert_contains "$md" "enforcement: no enforcement point is named; verification: no verification is named" "a none/none row names both parts"
  assert_contains "$md" "enforcement: enforcement file" "a vanished enforcement file is named as the failed part"
  assert_contains "$md" "enforcement spec is malformed" "a malformed stored spec is red, not a crash"
  assert_contains "$md" "admission-two.log has 2 line(s) matching" "a count breach names the file and its count"
  assert_not_contains "$md" "admission-one.log has" "a file within the count is not named as a breach"
  assert_contains "$md" "home nowhere is not read by this officer" "a status row naming an unread home is red"
  assert_contains "$md" "no file matches" "a file glob with no match is red"
  assert_contains "$md" "is 40.0h old; the limit is 26h" "a stale file is red with its age"
  assert_contains "$md" "newest match in" "a stamped log match is judged by its newest stamp"
  assert_not_contains "$md" "retired-red" "a retired row is skipped, in the digest and in the findings"
  assert_equals "15" "$(jq '.commitments | length' "$json")" "the json digest lists every unretired row"
  assert_equals "false" "$(jq '[.findings[].id] | any(contains("retired-red"))' "$json")" "a retired row raises no finding"
  assert_equals "" "$(jq -r '[.start_requests[] | select(.id | startswith("commitment-"))] | map(.id) | join(" ")' "$json")" "a commitment finding never starts work"
  pass "fm-officer page-check: every spec type is green or red, memory and none are red, a retired row is skipped, and the digest lists the whole register"
}

# status_line <home> <task> <at> <text>
status_line() {
  printf 'working [at=%d]: %s\n' "$3" "$4" >> "$1/state/$2.status"
}

test_unrecorded_commitments_match_tightly() {
  local home json md recent=$((NOW - 3600)) old=$((NOW - 60 * 3600)) ids
  home=$(make_world unrecorded)
  FM_HOME="$home" bash "$ROOT/bin/fm-commitment.sh" add --id known-row --commitment c --lee-words w --enforcement none --verify none >/dev/null \
    || fail "could not record the known row"
  # Positives: each is its own task, so its finding id names it.
  status_line "$home" pos-from "$recent" 'From now on every landing runs gate-ledger.py on a red pile'
  status_line "$home" pos-clause "$recent" 'Every time a pile goes red, landing runs attribute-failure.py'
  status_line "$home" pos-modal "$recent" 'we will run the ledger every time a gate fails'
  status_line "$home" pos-standing "$recent" 'recorded a new standing rule: gate first'
  printf 'working [at=%d] [commitment=no-such-row]: from now on the mark names nothing\n' "$recent" > "$home/state/pos-badmark.status"
  # Negatives.
  status_line "$home" neg-outstanding "$recent" 'outstanding items remain: 3 standing by for review'
  status_line "$home" neg-label "$recent" 'filed under the Linear Standing label, nothing else'
  status_line "$home" neg-quoted "$recent" 'Lee said "from now on turn it on" and I read it; no change made'
  status_line "$home" neg-title "$recent" 'matched standing-rule routine-cleanup on the card'
  status_line "$home" neg-result "$recent" 'the test fails every time on the old branch'
  status_line "$home" neg-existing "$recent" 'the standing rule settles it, so no card was raised'
  status_line "$home" neg-old "$old" 'from now on this is old news'
  printf 'working [at=%d] [commitment=known-row]: from now on landing runs the ledger\n' "$recent" > "$home/state/neg-marked.status"
  officer unrecorded run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  json="$home/data/officers/page-check/$KEY.json"
  ids=$(jq -r '[.findings[] | select(.kind == "commitment-unrecorded") | .id | split(":")[3]] | sort | join(" ")' "$json")
  assert_equals "pos-badmark pos-clause pos-from pos-modal pos-standing" "$ids" \
    "only first-person or clause-opening commitments, unquoted, from the last 48 hours and with no recorded mark are flagged"
  assert_equals "medium" "$(jq -r '[.findings[] | select(.kind == "commitment-unrecorded") | .severity] | unique | join(",")' "$json")" "commitment-unrecorded is medium"
  assert_equals "false" "$(jq '[.findings[] | select(.kind == "commitment-unrecorded") | .evidence] | any(contains("gate-ledger") or contains("attribute-failure"))' "$json")" \
    "the finding never carries the status line's own words"
  assert_equals "owner home: enforce or retire the commitment" "$(jq -r '[.findings[] | select(.kind == "commitment-unrecorded") | .route] | unique | join(",")' "$json")" "the route is the owner's"
  md=$(<"$home/data/officers/page-check/$KEY.md")
  assert_contains "$md" "1 row(s): 0 green, 1 red." "the section counts the one unretired row, which has no proof"
  pass "fm-officer page-check: an unrecorded commitment is matched tightly (outstanding, the Linear label, quotes, a rule id and results are not)"
}

test_an_unreadable_register_is_a_coverage_note_not_a_close() {  # also: no register at all is an empty section
  local home json
  home=$(make_world badreg)
  officer badreg run page-check --date "$KEY" >/dev/null || fail "run must succeed with no register"
  assert_contains "$(<"$home/data/officers/page-check/$KEY.md")" "No standing commitment is recorded in any home read." "no register still gets its section"
  printf 'not json' > "$home/data/standing-commitments.json"
  officer badreg run page-check --date "$KEY" >/dev/null || fail "an unreadable register must not fail the run"
  json="$home/data/officers/page-check/$KEY.json"
  assert_contains "$(jq -r '.coverage | join("\n")' "$json")" "standing-commitments.json is unreadable" "the digest names the unreadable register"
  assert_equals "" "$(commit_ids "$json" commitment-unproven)" "an unreadable register raises no unproven finding"
  printf 'working [at=%d] [commitment=lost-row]: from now on landing runs the ledger\n' "$((NOW - 3600))" > "$home/state/marked.status"
  printf 'working [at=%d]: from now on landing runs the ledger\n' "$((NOW - 3600))" > "$home/state/unmarked.status"
  officer badreg run page-check --date "$KEY" >/dev/null || fail "an unreadable register must not fail the run"
  assert_equals "unmarked" "$(jq -r '[.findings[] | select(.kind == "commitment-unrecorded") | .id | split(":")[3]] | join(" ")' "$json")" \
    "a marked line is not called unrecorded while a register is unreadable; an unmarked one still is"
  pass "fm-officer page-check: an unreadable register is a coverage note"
}

test_commitment_findings_are_filed_and_never_started() {
  local dir home json issue
  linear_world commitfile
  dir=$FAKE_LINEAR_DIR
  home=$LW_HOME
  FM_HOME="$home" bash "$ROOT/bin/fm-commitment.sh" add --id c1 --commitment c --lee-words w --enforcement memory --verify none >/dev/null \
    || fail "could not record the row"
  officer commitfile run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  json="$home/data/officers/page-check/$KEY.json"
  issue=$(jq -r '[.findings[] | select(.kind == "commitment-unproven")][0].linear.issue' "$json")
  assert_contains "$issue" "PC-" "a red commitment is filed in Linear through the shared path"
  assert_equals "0" "$(jq '[.start_requests[] | select((.id // "") | startswith("commitment-"))] | length' "$json")" "and no start request is made for it"
  assert_equals "0" "$(jq '.asks_for_lee | length' "$json")" "and nothing is held for Lee"
  assert_not_contains "$(cat "$dir/bodies")" "The c1 commitment" "the item names the row by id and never carries its text"
  pass "fm-officer page-check: a red commitment is filed in Linear and never started"
}

test_a_commitment_item_closes_once_its_row_is_retired_but_not_while_unread() {
  local home
  linear_world commitclose
  home=$LW_HOME
  seed_own_item PC-61 commitment-unproven "Standing commitments" "home:gone-row" "Filed by the page-check officer from the 2026-11-07T10 page check." '{}' "owner home; enforcement: no enforcement point is named"
  seed_own_item PC-62 commitment-unproven "Standing commitments" "home:also-gone" "Filed by the page-check officer from the 2026-11-07T10 page check." '{}' "owner home; enforcement: no enforcement point is named"
  printf 'not json' > "$home/data/standing-commitments.json"
  officer commitclose run page-check --date "$KEY" >/dev/null || fail "run must succeed"
  later_day commitclose 2026-11-01T14 >/dev/null || fail "a later check must succeed"
  assert_equals "0" "$(closes_of PC-61)" "two checks that could not read the register do not close a commitment item"
  rm -f "$home/data/standing-commitments.json"
  later_day commitclose 2026-11-01T16 >/dev/null || fail "a readable check must succeed"
  assert_equals "0" "$(closes_of PC-61)" "the first check that read the register is only one check"
  later_day commitclose 2026-11-01T18 >/dev/null || fail "a second readable check must succeed"
  assert_equals "1" "$(closes_of PC-61)" "an item whose row is gone from two readable checks closes"
  assert_contains "$(grep '^issue comment PC-61 .*--dry-run' "$FAKE_LINEAR_DIR/log" | head -1)" "not recurred in two checks" "with the usual reason comment"
  pass "fm-officer page-check: a commitment item closes after two readable checks without its finding, never on an unread register"
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
test_a_closed_item_is_bumped_and_never_started
test_a_settled_production_card_shown_again_starts_its_page_fix
test_a_fix_in_a_reserved_class_is_held_for_lee
test_a_page_defect_pattern_is_remembered_once
test_the_officer_closes_its_own_items_when_the_finding_is_over
test_the_officer_leaves_items_it_may_not_close
test_closing_needs_writes_linear_and_budget
test_a_check_that_could_not_see_the_finding_does_not_count
test_a_failed_move_is_retried_without_a_second_comment
test_an_unread_rules_file_or_card_record_does_not_count
test_a_recurrence_in_a_blocked_check_resets_the_count
test_a_log_without_cards_does_not_count
test_every_spec_type_is_green_or_red_in_the_digest
test_unrecorded_commitments_match_tightly
test_an_unreadable_register_is_a_coverage_note_not_a_close
test_commitment_findings_are_filed_and_never_started
test_a_commitment_item_closes_once_its_row_is_retired_but_not_while_unread
