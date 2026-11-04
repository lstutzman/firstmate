#!/usr/bin/env bash
# Behavior tests for the Ship's Surgeon, driven through bin/fm-officer.sh
# against an empty fixture archive, fixture fleet-app pages (a fake curl) and a
# fake linear-axi that logs every call.
#
# Covers: the registry (app, writes, max-creates, and for writes: linear the
# team and area, and a non-empty staging-repo), the classification and
# severity tables for nightly E2E (high only on the staging tip), nightly
# review and sweeper findings, key-less findings never filed, tracked findings never filed again,
# high severity in the digest json, no Linear call at all with writes: none,
# the fingerprint search and the lane ledger skipping a create, the
# max-creates cap, --dry-run before --verify with exactly one Type, Source and
# area label, a failed verify logged and not retried, a failed or incomplete
# label lookup reporting instead of filing, one rate limit stopping every
# Linear call and pausing later runs, only label list, issue search and issue
# create ever being called, an unreachable app as a coverage gap, and register
# surgeon / retire triage keeping triage's findings.
set -u

# shellcheck source=tests/officer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/officer-helpers.sh"

OFFICER="$ROOT/bin/fm-officer.sh"
TMP_ROOT=$(fm_test_tmproot fm-officer-surgeon)
DATE=2026-10-23
NOW=1792823400
TIP=0123456789abcdef0123456789abcdef01234567
REAL_GIT=$(command -v git)
export TZ=UTC

write_pages() {  # <dir>: the fleet app's pages, one file per GET path.
  local d=$1
  mkdir -p "$d"
  jq -n '{jobs: [
    {id: "nightly-e2e", state: "live", results: {kind: "e2e"}, lastDone: {runId: "R1"}, latest: {runId: "R1"}},
    {id: "nightly-review", state: "live", results: {kind: "review"}, latest: {runId: "R2"}},
    {id: "bosun", state: "live", results: {kind: "maintenance"}, lastDone: {runId: "R9"}},
    {id: "plain", state: "live", latest: {runId: "R8"}}]}' > "$d/_api_runs"
  jq -n --arg sha "${TIP^^}" '{run: {}, result: {sha: $sha, status: "RED"}, shared: {status: "failed", findings: [
    {key: "fp-a", title: "checkout pays", cause: "timed out", severity: "high", where: "a.spec.ts", issue: null,
     classification: "regression", rerun: "failed (3 s)", release_blocking: true},
    {key: "fp-b", title: "flaky one", cause: "slow", severity: "high", issue: null, classification: "flaky", rerun: "passed (4 s)"},
    {key: "fp-c", title: "tracked failure", cause: "x", severity: "high", issue: "PC-77", classification: null},
    {key: "fp-d", title: "copy changed", cause: "text differs", severity: "medium", issue: null, classification: "intended change"},
    {key: "fp-e", title: "load failure", cause: "x", severity: "high", issue: null, classification: null, rerun: "passed (1 s)"}]}}' \
    > "$d/_api_runs_nightly-e2e_results_R1"
  jq -n '{run: {}, summary: {}, shared: null, result: {findings: [
    {id: "f1", severity: "critical", file: "A.cs", summary: "SQL built from input"},
    {id: "f2", severity: "high", file: "B.cs", summary: "unchecked null"},
    {id: "f3", severity: "low", file: "C.cs", summary: "naming"},
    {id: "f4", severity: "medium", file: "D.cs", summary: "dead branch"},
    {severity: "critical", file: "E.cs", summary: "no id given"}],
    filings: {filed: [{finding: "f2", issue: "PC-80"}, {finding: "", issue: "PC-81"}], digested: [], commented: [], failed: null, filing_error: false}}}' \
    > "$d/_api_runs_nightly-review_results_R2"
  jq -n '{runs: [], latestPlan: null, latest: {run: {run_id: "sweep-20261023T0417Z", intake: {bugs: [
    {fp: "b1", title: "Crash on save", disposition: "new", severity: "P1", occurrences: 4, cause: "null ref"},
    {fp: "b2", title: "Same crash again", disposition: "duplicate", severity: "P1"},
    {fp: "b3", title: "Odd screen", disposition: "unclear", severity: "P2"},
    {fp: "b4", title: "Old regression", disposition: "regressed", severity: "P3", duplicate_of: "PC-5"},
    {fp: "b5", title: "Wrong total", disposition: "new", severity: "P2"},
    {fp: "b6", title: "Filed already", disposition: "new", severity: "P1"},
    {fp: "b7", title: "production checkout error", notes: "seen in production logs", disposition: "unclear", severity: "low"},
    {fp: "b8", title: "Fixed on staging", disposition: "fixed-staging-only", severity: "medium"},
    {title: "No fingerprint", disposition: "new", severity: "low"}],
    linear: {filed: [{id: "PC-90", fp: "b6"}], updated: [], cancelled: [], dismissed: [], failures: []}}}}}' \
    > "$d/_api_sweeper-results"
}

# fake_linear <fakebin> <dir> <log>: linear-axi from files in <dir>:
# labels.fail / ratelimit.labels (label list), ratelimit.search, verify.fail, ratelimit.verify,
# labels.txt (one label per line), exists.txt (fingerprints that search finds).
fake_linear() {
  cat > "$1/linear-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$3"
d="$2"
err() { echo '{"ok":false,"error":{"code":"'"\$1"'","message":"'"\$2"'"}}'; }
case "\$1 \$2" in
  "label list")
    [ -f "\$d/ratelimit.labels" ] && { err RATE_LIMITED "wait"; exit 1; }
    [ -f "\$d/labels.fail" ] && { err VALIDATION_ERROR "no labels"; exit 1; }
    printf '{"ok":true,"data":{"labels":['
    sep=''; while IFS= read -r l; do printf '%s{"name":"%s"}' "\$sep" "\$l"; sep=','; done < "\$d/labels.txt"
    echo ']}}' ;;
  "issue search")
    [ -f "\$d/ratelimit.search" ] && { err RATE_LIMITED "wait"; exit 1; }
    # Linear's search is fuzzy: it always returns an unrelated issue, and the real one only when it exists.
    if grep -qF -- "\${3#surgeon-fp:}" "\$d/exists.txt" 2>/dev/null; then
      echo '{"ok":true,"data":{"issues":[{"identifier":"PC-9"},{"identifier":"PC-55"}]}}'
    else echo '{"ok":true,"data":{"issues":[{"identifier":"PC-9"}]}}'; fi ;;
  "issue view")
    if [ "\$3" = PC-55 ]; then
      echo '{"ok":true,"data":{"issue":{"identifier":"PC-55","description":"Filed earlier. surgeon-fp:'"\$(tr -d '\n' < "\$d/exists.txt")"'"}}}'
    else echo '{"ok":true,"data":{"issue":{"identifier":"'"\$3"'","description":"unrelated"}}}'; fi ;;
  "issue create")
    case " \$* " in
      *" --verify "*)
        [ -f "\$d/ratelimit.verify" ] && { err RATE_LIMITED "wait"; exit 1; }
        [ -f "\$d/verify.fail" ] && { err VERIFY_FAILED "not readable back"; exit 1; }
        n=\$(( \$(cat "\$d/created" 2>/dev/null || echo 100) + 1 )); echo "\$n" > "\$d/created"
        for a in "\$@"; do
          if [ "\$prev" = "--body-file" ]; then
            cat "\$a" >> "\$d/bodies"
            # Linear trims a trailing newline, so verify then mismatches, as on the real PC-4041..4045 creates.
            [ -n "\$(tail -c1 "\$a")" ] || mismatch=1
            [ -f "\$d/verify.mismatch" ] && mismatch=1
            [ -n "\${mismatch:-}" ] && grep -o 'surgeon-fp:[0-9a-f]*' "\$a" | cut -d: -f2 | tr -d '\n' >> "\$d/exists.txt"
          fi
          prev=\$a
        done
        [ -n "\${mismatch:-}" ] && { err UNKNOWN "Write verification did not match intended state"; exit 1; }
        echo '{"ok":true,"data":{"issue":{"identifier":"PC-'"\$n"'"}}}' ;;
      *) echo '{"ok":true,"data":{"dryRun":true}}' ;;
    esac ;;
  *) err UNKNOWN "unexpected call"; exit 1 ;;
esac
SH
  chmod +x "$1/linear-axi"
}

surgeon_registry() {  # <home> <archive> [extra fields, each ending in "; "]
  printf -- '- surgeon - Triage plus intake (role: surgeon; cadence: daily 06:00; archive: %s; hosts: alpha; app: https://app.test; %smodel: none; added 2026-11-04)\n' \
    "$2" "${3:-}" > "$1/data/officers.md"
}

# make_world <name> [registry extras]: sets WORLD_HOME, FAKEBIN, LDIR (linear fixture dir), LINEAR_LOG.
make_world() {
  local name=$1 home archive
  home="$TMP_ROOT/$name/home"
  archive="$TMP_ROOT/$name/archive"
  officer_home "$home"
  home=$(cd "$home" && pwd -P)
  printf '%s\n' '{"sessions": []}' > "$TMP_ROOT/$name/spec.json"
  officer_archive "$archive" "$DATE" "$TMP_ROOT/$name/spec.json"
  write_pages "$TMP_ROOT/$name/pages"
  surgeon_registry "$home" "$archive" "${2:-}"
  FAKEBIN=$(fm_fakebin "$TMP_ROOT/$name")
  LDIR="$TMP_ROOT/$name/linear"
  mkdir -p "$LDIR"
  printf 'Bug\nscheduled-review\nbug-sweep\nRuntime\n' > "$LDIR/labels.txt"
  LINEAR_LOG="$TMP_ROOT/$name/linear.calls"
  fake_linear "$FAKEBIN" "$LDIR" "$LINEAR_LOG"
  cat > "$FAKEBIN/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/$name/curl.calls"
[ -f "$TMP_ROOT/$name/unreachable" ] && exit 7
url=\${@: -1}
f="$TMP_ROOT/$name/pages/\$(printf '%s' "\${url#https://app.test}" | tr '/?=' '___')"
if [ -f "\$f" ]; then cat "\$f"; printf '\n200'; else printf '\n404'; fi
SH
  chmod +x "$FAKEBIN/curl"
  printf '%s\n' "$TIP" > "$TMP_ROOT/$name/staging-tip"
  cat > "$FAKEBIN/git" <<SH
#!/usr/bin/env bash
[ "\$1" = ls-remote ] || exec "$REAL_GIT" "\$@"
printf '%s\n' "\$*" >> "$TMP_ROOT/$name/git.calls"
[ -f "$TMP_ROOT/$name/staging-tip" ] || exit 128
printf '%s\trefs/heads/staging\n' "\$(cat "$TMP_ROOT/$name/staging-tip")"
SH
  chmod +x "$FAKEBIN/git"
  WORLD_HOME=$home
}

run_surgeon() {  # <home> [now]
  PATH="$FAKEBIN:$PATH" FM_OFFICER_NOW="${2:-$NOW}" FM_HOME="$1" "$OFFICER" run surgeon --date "$DATE"
}

fp() { printf '%s\0%s\0%s' "$1" "$2" "$3" | sha256sum | cut -d' ' -f1; }

LINEAR_ON="writes: linear; team: PC; area: Runtime; "

row() {  # <json> <source> <key> <jq field>
  jq -r --arg s "$2" --arg k "$3" ".findings[] | select(.source == \$s and .key == \$k) | $4" "$1"
}

test_registry_rules() {
  local home out
  make_world registry; home=$WORLD_HOME
  surgeon_registry "$home" "$TMP_ROOT/registry/archive" ""
  sed -i 's/ app: https:\/\/app.test;//' "$home/data/officers.md"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$OFFICER" run surgeon --date "$DATE" 2>&1) && fail "a surgeon without an app must be refused"
  assert_contains "$out" "a surgeon officer needs app" "the refusal names the app"
  surgeon_registry "$home" "$TMP_ROOT/registry/archive" "writes: all; "
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$OFFICER" run surgeon --date "$DATE" 2>&1) && fail "an unknown writes value must be refused"
  assert_contains "$out" "writes must be linear or none" "writes is linear or none"
  surgeon_registry "$home" "$TMP_ROOT/registry/archive" "writes: linear; "
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$OFFICER" run surgeon --date "$DATE" 2>&1) && fail "writes: linear without an area must be refused"
  assert_contains "$out" "needs area" "linear writes name their one area label"
  surgeon_registry "$home" "$TMP_ROOT/registry/archive" "writes: linear; area: Runtime; team: ENG; "
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$OFFICER" run surgeon --date "$DATE" 2>&1) && fail "another team must be refused"
  assert_contains "$out" "team PC only" "the Surgeon files into team PC only"
  surgeon_registry "$home" "$TMP_ROOT/registry/archive" "max-creates: 0; "
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$OFFICER" run surgeon --date "$DATE" 2>&1) && fail "max-creates 0 must be refused"
  assert_contains "$out" "max-creates must be a whole number" "max-creates is at least 1"
  surgeon_registry "$home" "$TMP_ROOT/registry/archive" "staging-repo: ; "
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$OFFICER" run surgeon --date "$DATE" 2>&1) && fail "an empty staging-repo must be refused"
  assert_contains "$out" "staging-repo must name" "staging-repo is not empty"
  pass "fm-officer surgeon: the registry line is validated"
}

test_classification_and_severity() {
  local home json
  make_world classes; home=$WORLD_HOME
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "real high" "$(row "$json" nightly fp-a '[.class,.severity]|join(" ")')" "a red night's failure on the staging tip is real and high"
  assert_equals "$TIP $TIP" "$(row "$json" nightly fp-a '[.evidence.sha,.evidence.staging_tip]|join(" ")')" "the run sha and the tip are evidence"
  assert_equals "ls-remote git@github.com:lstutzman/PropertyCompass2.git refs/heads/staging" "$(cat "$TMP_ROOT/classes/git.calls")" "the tip is read once from the default staging repo"
  assert_equals "wont-fix low" "$(row "$json" nightly fp-b '[.class,.severity]|join(" ")')" "a flaky class is won't fix and low"
  assert_equals "wont-fix low" "$(row "$json" nightly fp-e '[.class,.severity]|join(" ")')" "a rerun that passed alone is won't fix"
  assert_equals "needs-decision high" "$(row "$json" nightly fp-d '[.class,.severity]|join(" ")')" "an intended change needs a decision"
  assert_equals PC-77 "$(row "$json" nightly fp-c .tracked)" "a failure the filer put in Linear is tracked"
  assert_equals "real high" "$(row "$json" review f1 '[.class,.severity]|join(" ")')" "a critical review finding is high"
  assert_equals PC-80 "$(row "$json" review f2 .tracked)" "a review finding with a filing is tracked"
  assert_equals "wont-fix low" "$(row "$json" review f3 '[.class,.severity]|join(" ")')" "a low review finding is won't fix"
  assert_equals "real low" "$(row "$json" review f4 '[.class,.severity]|join(" ")')" "a medium review finding is low"
  assert_equals "real high" "$(row "$json" sweeper b1 '[.class,.severity]|join(" ")')" "a P1 new sweeper bug is real and high"
  assert_equals "wont-fix low" "$(row "$json" sweeper b2 '[.class,.severity]|join(" ")')" "a duplicate is won't fix"
  assert_equals "needs-decision medium" "$(row "$json" sweeper b3 '[.class,.severity]|join(" ")')" "an unclear bug needs a decision"
  assert_equals PC-5 "$(row "$json" sweeper b4 .tracked)" "a duplicate_of bug is tracked"
  assert_equals PC-90 "$(row "$json" sweeper b6 .tracked)" "a bug the sweeper filed is tracked"
  # b7's title and notes say production, but a finding is not rated high from its text
  # alone: the production-class rule waits for the sweeper to send an environment field.
  assert_equals "needs-decision low" "$(row "$json" sweeper b7 '[.class,.severity]|join(" ")')" "a finding is not rated high from its text alone"
  assert_equals "needs-decision medium" "$(row "$json" sweeper b8 '[.class,.severity]|join(" ")')" "fixed-staging-only needs a decision"
  assert_equals "real high null" "$(row "$json" review "" '[.class,.severity,(.tracked|tostring)]|join(" ")')" "an empty filing key never marks a key-less finding tracked"
  assert_equals "" "$(jq -r '[.findings[] | select(.source == "review" and .key == "x")] | join("")' "$json")" "no stray findings"
  assert_equals true "$(jq -r '[.findings[] | select(.severity == "high")] | length > 0' "$json")" "high severity is in the digest json"
  assert_equals sha "$(row "$json" nightly fp-a '.fingerprint|if (.|length)==64 then "sha" else "bad" end')" "each finding carries a sha256 fingerprint"
  assert_equals "$(fp nightly nightly-e2e fp-a)" "$(row "$json" nightly fp-a .fingerprint)" "the fingerprint is the source, job and key"
  assert_contains "$(cat "$home/data/officers/surgeon/digest")" "DIGEST $DATE " "the digest marker is written"
  [ ! -s "$LINEAR_LOG" ] || fail "writes none must make no Linear call: $(cat "$LINEAR_LOG")"
  assert_not_contains "$(cat "$TMP_ROOT/classes/curl.calls")" "-X" "the app is read with GET only"
  pass "fm-officer surgeon: findings are classified and rated from the app's results with no Linear call"
}

test_staging_tip_rates_the_night() {
  local home json out
  make_world tip; home=$WORLD_HOME
  printf 'fedcba9876543210fedcba9876543210fedcba98\n' > "$TMP_ROOT/tip/staging-tip"
  out=$(run_surgeon "$home") || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "real medium" "$(row "$json" nightly fp-a '[.class,.severity]|join(" ")')" "a red night on an older sha is medium"
  assert_equals "wont-fix low" "$(row "$json" nightly fp-b '[.class,.severity]|join(" ")')" "won't fix stays low"
  assert_not_contains "$out" "staging tip unreadable" "a readable tip is no coverage gap"
  rm -f "$TMP_ROOT/tip/staging-tip"
  out=$(run_surgeon "$home") || fail "an unreadable tip must not fail the run"
  assert_equals "real medium" "$(row "$json" nightly fp-a '[.class,.severity]|join(" ")')" "an unreadable tip rates the night medium"
  assert_contains "$out" "Coverage gap: staging tip unreadable" "and is reported as a coverage gap"
  pass "fm-officer surgeon: a red night is high only on the staging tip"
}

test_rerun_is_byte_identical() {
  local home before
  make_world rerun; home=$WORLD_HOME
  run_surgeon "$home" >/dev/null || fail "first run"
  before=$(cat "$home/data/officers/surgeon/$DATE.json" "$home/data/officers/surgeon/$DATE.md")
  run_surgeon "$home" >/dev/null || fail "second run"
  assert_equals "$before" "$(cat "$home/data/officers/surgeon/$DATE.json" "$home/data/officers/surgeon/$DATE.md")" "an unchanged day rewrites identical bytes"
  pass "fm-officer surgeon: a rerun is byte-identical"
}

test_files_real_untracked_findings() {
  local home json bodies first second
  make_world files "$LINEAR_ON"; home=$WORLD_HOME
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals 5 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "the five real untracked findings are created"
  assert_equals 5 "$(grep -c '^issue create .*--dry-run' "$LINEAR_LOG")" "each create is dry-run first"
  assert_equals 1 "$(grep -c '^label list --team PC' "$LINEAR_LOG")" "labels are looked up once, in team PC"
  assert_equals created "$(row "$json" nightly fp-a .filing.action)" "the failure is filed"
  assert_equals "" "$(row "$json" nightly fp-a '.filing.verify // ""')" "a correct create verifies clean, with no trailing-newline mismatch"
  assert_equals "" "$(row "$json" nightly fp-c '.filing // "" | tostring | select(. != "")')" "a tracked failure is not filed"
  assert_equals "" "$(row "$json" sweeper b6 '.filing // "" | tostring | select(. != "")')" "a bug the sweeper filed is not filed again"
  assert_equals "" "$(row "$json" nightly fp-d '.filing // "" | tostring | select(. != "")')" "a finding needing a decision is not filed"
  assert_equals "" "$(row "$json" sweeper b2 '.filing // "" | tostring | select(. != "")')" "a won't-fix finding is not filed"
  assert_contains "$(grep '^issue create .*--verify' "$LINEAR_LOG" | head -1)" "--label Bug --label scheduled-review --label Runtime" "one Type, one Source and one area label"
  assert_contains "$(grep -- '--label bug-sweep' "$LINEAR_LOG" | head -1)" "--label Bug --label bug-sweep --label Runtime" "the sweeper's Source is bug-sweep"
  assert_contains "$(grep '^issue create .*--verify' "$LINEAR_LOG" | head -1)" "--team PC" "items go to team PC only"
  bodies=$(cat "$LDIR/bodies")
  assert_contains "$bodies" "surgeon-fp:$(fp nightly nightly-e2e fp-a)" "the description carries the fingerprint"
  assert_contains "$bodies" "Epic:" "the description names its epic"
  assert_contains "$bodies" "What it is for" "the description says what it is for"
  assert_equals "not-filed source gave no stable key" "$(row "$json" sweeper "" '[.filing.action,.filing.reason]|join(" ")')" "a key-less sweeper bug is reported, not filed"
  assert_equals "not-filed source gave no stable key" "$(row "$json" review "" '[.filing.action,.filing.reason]|join(" ")')" "a key-less review finding is reported, not filed"
  assert_not_contains "$(cat "$LINEAR_LOG")" "issue update" "nothing is edited"
  assert_not_contains "$(cat "$LINEAR_LOG")" "issue close" "nothing is closed"
  assert_not_contains "$(cat "$LINEAR_LOG")" "comment" "nothing is commented"
  assert_not_contains "$(cat "$LINEAR_LOG")" "delete" "nothing is deleted"
  first=$(grep -n '^issue create .*--dry-run' "$LINEAR_LOG" | head -1 | cut -d: -f1)
  second=$(grep -n '^issue create .*--verify' "$LINEAR_LOG" | head -1 | cut -d: -f1)
  [ "$first" -lt "$second" ] || fail "--dry-run must come before --verify"
  pass "fm-officer surgeon: real untracked findings are filed with one Type, Source and area label"
}

test_fingerprint_search_skips_create() {
  local home json
  make_world exists "$LINEAR_ON"; home=$WORLD_HOME
  fp nightly nightly-e2e fp-a > "$LDIR/exists.txt"
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "exists PC-55" "$(row "$json" nightly fp-a '[.filing.action,.filing.issue]|join(" ")')" "a fingerprint already in Linear skips the create"
  assert_equals 4 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "the other four are created, so an unrelated fuzzy hit never counts"
  assert_equals 1 "$(grep -c '^issue view PC-55' "$LINEAR_LOG")" "a hit is read before it is believed"
  : > "$LINEAR_LOG"
  run_surgeon "$home" >/dev/null || fail "rerun must succeed"
  assert_equals 0 "$(grep -c '^issue create' "$LINEAR_LOG")" "the lane ledger stops a rerun creating again, even if search lags"
  assert_equals 0 "$(grep -c '^issue search' "$LINEAR_LOG")" "and spends no search on a fingerprint it already filed"
  pass "fm-officer surgeon: a fingerprint already filed is never created again"
}

test_max_creates_cap() {
  local home json
  make_world cap "${LINEAR_ON}max-creates: 2; "; home=$WORLD_HOME
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals 2 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "at most max-creates items are created"
  assert_equals 2 "$(grep -c '^issue search' "$LINEAR_LOG")" "and searched, no more"
  assert_equals 0 "$(grep -c 'issue view PC-55' "$LINEAR_LOG")" "nothing else is read"
  assert_equals "created created" "$(row "$json" nightly fp-a .filing.action) $(row "$json" review f1 .filing.action)" "the highest severities go first"
  assert_equals "not-filed" "$(row "$json" sweeper b1 .filing.action)" "the extra finding is reported, not filed"
  assert_contains "$(row "$json" sweeper b1 .filing.reason)" "max-creates" "and says why"
  pass "fm-officer surgeon: the max-creates cap holds and the rest are reported"
}

test_failed_verify_is_not_retried() {
  local home json
  make_world verify "${LINEAR_ON}max-creates: 5; "; home=$WORLD_HOME
  touch "$LDIR/verify.fail"
  run_surgeon "$home" >/dev/null || fail "a failed verify must not fail the run"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals 5 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "each finding is verified once"
  assert_equals failed "$(row "$json" nightly fp-a .filing.action)" "a failed verify is logged on the finding"
  assert_contains "$(row "$json" nightly fp-a .filing.reason)" "VERIFY_FAILED" "with its cause"
  assert_equals "[]" "$(jq -c '[.writes_done[] | select(.action == "created")]' "$json")" "nothing is recorded as created"
  pass "fm-officer surgeon: a failed verify is logged and not retried"
}

test_created_item_with_verify_mismatch_is_ledgered() {
  local home json
  make_world mismatch "${LINEAR_ON}max-creates: 1; "; home=$WORLD_HOME
  touch "$LDIR/verify.mismatch"
  run_surgeon "$home" >/dev/null || fail "a verify mismatch must not fail the run"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "created PC-55" "$(row "$json" nightly fp-a '[.filing.action,.filing.issue]|join(" ")')" "a created item is not reported failed"
  assert_contains "$(row "$json" nightly fp-a .filing.verify)" "did not match" "the mismatch is kept"
  assert_equals "PC-55" "$(jq -r --arg fp "$(fp nightly nightly-e2e fp-a)" '.[$fp]' "$home/data/officers/surgeon/filed-fingerprints.json")" "its fingerprint is in the ledger"
  pass "fm-officer surgeon: a created item whose verify mismatches is still ledgered"
}

test_label_lookup_failure_reports_instead_of_filing() {
  local home json
  make_world labels "$LINEAR_ON"; home=$WORLD_HOME
  touch "$LDIR/labels.fail"
  run_surgeon "$home" >/dev/null || fail "a failed label lookup must not fail the run"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals 0 "$(grep -c '^issue ' "$LINEAR_LOG")" "no search or create after a failed lookup"
  assert_equals 1 "$(grep -c '^label list' "$LINEAR_LOG")" "and the lookup is not retried"
  assert_contains "$(row "$json" nightly fp-a .filing.reason)" "label lookup failed" "the finding is reported with the reason"
  rm -f "$LDIR/labels.fail"
  printf 'Bug\nscheduled-review\nbug-sweep\n' > "$LDIR/labels.txt"
  : > "$LINEAR_LOG"
  rm -f "$home/data/officers/surgeon/filed-fingerprints.json"
  run_surgeon "$home" >/dev/null || fail "a missing area label must not fail the run"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals 0 "$(grep -c '^issue ' "$LINEAR_LOG")" "a missing area label files nothing"
  assert_contains "$(row "$json" nightly fp-a .filing.reason)" "label(s) not found in team PC: Runtime" "naming the missing label"
  pass "fm-officer surgeon: a failed or incomplete label lookup reports the finding instead of filing"
}

test_rate_limit_stops_linear_for_the_run_and_later_runs() {
  local home json out
  make_world rate "$LINEAR_ON"; home=$WORLD_HOME
  touch "$LDIR/ratelimit.search"
  out=$(run_surgeon "$home") || fail "a rate limit must not fail the run"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals 1 "$(grep -c '^issue search' "$LINEAR_LOG")" "one RATE_LIMITED answer stops every later Linear call"
  assert_contains "$out" "Coverage gap: Linear rate limit reached" "the run reports it"
  assert_equals "not-filed" "$(row "$json" review f1 .filing.action)" "the rest are not filed"
  assert_equals $((NOW + 3600)) "$(jq -r .resume_after "$home/data/officers/surgeon/linear-resume-after.json")" "the lane records when Linear may be used again"
  rm -f "$LDIR/ratelimit.search"
  : > "$LINEAR_LOG"
  out=$(run_surgeon "$home" $((NOW + 60))) || fail "a paused run must still succeed"
  assert_equals 0 "$(wc -c < "$LINEAR_LOG" | tr -d ' ')" "a later run before the resume time makes no Linear call"
  assert_contains "$out" "Linear paused" "and says so"
  run_surgeon "$home" $((NOW + 3700)) >/dev/null || fail "run after the pause"
  assert_equals 5 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "after the pause it files again"
  pass "fm-officer surgeon: a rate limit stops Linear for the run and pauses later runs"
}

test_unreachable_app_is_a_coverage_gap() {
  local home out
  make_world down "$LINEAR_ON"; home=$WORLD_HOME
  touch "$TMP_ROOT/down/unreachable"
  out=$(run_surgeon "$home") || fail "an unreachable app must not fail the run"
  assert_contains "$out" "Coverage gap: fleet app /api/runs unreachable" "the gap is reported"
  [ ! -s "$LINEAR_LOG" ] || fail "nothing is filed from nothing"
  pass "fm-officer surgeon: an unreachable app is a coverage gap, not a failed run"
}

test_register_surgeon_and_retire_triage_keeps_findings() {
  local home archive out
  home="$TMP_ROOT/swap/home"
  archive="$TMP_ROOT/swap/archive"
  officer_home "$home"
  printf '%s\n' '{"sessions": []}' > "$TMP_ROOT/swap-spec.json"
  officer_archive "$archive" "$DATE" "$TMP_ROOT/swap-spec.json"
  officer_registry "$home" "$archive" alpha
  FM_HOME="$home" "$OFFICER" register triage >/dev/null || fail "register triage"
  FM_HOME="$home" "$OFFICER" run triage --date "$DATE" >/dev/null || fail "triage run"
  surgeon_registry "$home" "$archive" ""
  printf -- '- triage - Joins archived sessions (role: triage; cadence: daily 06:00; archive: %s; hosts: alpha; model: none; added 2026-10-24)\n' "$archive" >> "$home/data/officers.md"
  out=$(FM_HOME="$home" "$OFFICER" register surgeon) || fail "register surgeon: $out"
  assert_contains "$out" "registered: officer surgeon" "the surgeon registers"
  FM_HOME="$home" "$OFFICER" retire triage >/dev/null || fail "retire triage"
  [ -f "$home/data/officers/triage/$DATE.json" ] || fail "triage's findings are kept"
  assert_equals surgeon "$(FM_HOME="$home" "$OFFICER" list | awk '{print $1}')" "only the surgeon remains registered"
  FM_HOME="$home" PATH="$FAKEBIN:$PATH" "$OFFICER" ensure >/dev/null
  pass "fm-officer surgeon: register surgeon, then retire triage, keeps triage's findings"
}

test_registry_rules
test_classification_and_severity
test_staging_tip_rates_the_night
test_rerun_is_byte_identical
test_files_real_untracked_findings
test_fingerprint_search_skips_create
test_max_creates_cap
test_failed_verify_is_not_retried
test_created_item_with_verify_mismatch_is_ledgered
test_label_lookup_failure_reports_instead_of_filing
test_rate_limit_stops_linear_for_the_run_and_later_runs
test_unreachable_app_is_a_coverage_gap
test_register_surgeon_and_retire_triage_keeps_findings
