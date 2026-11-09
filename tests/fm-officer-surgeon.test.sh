#!/usr/bin/env bash
# Behavior tests for the Ship's Surgeon, driven through bin/fm-officer.sh
# against an empty fixture archive, fixture fleet-app pages (a fake curl) and a
# fake linear-axi that logs every call.
#
# Covers: the registry (app, writes, max-creates, and for writes: linear the
# team and area, and a non-empty staging-repo), the classification and
# severity tables for nightly E2E (high only on the staging tip), nightly
# review and sweeper findings, key-less findings fingerprinted from title and location, tracked findings never filed again,
# high severity in the digest json, no Linear call at all with writes: none,
# the fingerprint search and the lane ledger skipping a create, the
# max-creates cap, --dry-run before --verify with exactly one Type, Source and
# area label, a failed verify logged and not retried, a failed or incomplete
# label lookup reporting instead of filing, one rate limit stopping every
# Linear call and pausing later runs, only label list, issue search and issue
# create ever being called, an unreachable app as a coverage gap, and register
# surgeon / retire triage keeping triage's findings, and the visual review source: its findings file (version 2 only)
# filed once per fingerprint and bumped on a repeat, wording or product findings held for Lee as one keyed decision with no
# item, a missing, unreadable, version 1, unchanged or incomplete file as a named gap, a run without writes: linear touching nothing in Linear,
# and screenshot attaches: counted against the call budget, a failed one retried on later runs and abandoned after 7 days.
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
# search.down.after.verify (searches fail once a verify has failed),
# labels.txt (one label per line), exists.txt (fingerprints that search finds),
# search.lag (how many searches miss an existing item first, as Linear's index lags a write).
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
    [ -f "\$d/search.down" ] && { err UNKNOWN "search down"; exit 1; }
    # Linear's search is fuzzy: it always returns an unrelated issue, and the real one only when it exists.
    lag=\$(cat "\$d/search.lag" 2>/dev/null || echo 0)
    # A title query (the filer's recovery after a verify mismatch) finds the item the mismatching create made, by its exact title.
    case "\$3" in surgeon-fp:*) q=\${3#surgeon-fp:} ;; *) [ -s "\$d/exists.txt" ] && [ "\$3" = "\$(cat "\$d/created.title" 2>/dev/null)" ] && q=\$(tr -d '\n' < "\$d/exists.txt") || q=no-match ;; esac
    if grep -qF -- "\$q" "\$d/exists.txt" 2>/dev/null && [ "\$lag" -gt 0 ]; then
      echo \$((lag - 1)) > "\$d/search.lag"
      echo '{"ok":true,"data":{"issues":[{"identifier":"PC-9"}]}}'
    elif grep -qF -- "\$q" "\$d/exists.txt" 2>/dev/null; then
      echo '{"ok":true,"data":{"issues":[{"identifier":"PC-9"},{"identifier":"PC-55"}]}}'
    else echo '{"ok":true,"data":{"issues":[{"identifier":"PC-9"}]}}'; fi ;;
  "issue update")
    case " \$* " in
      *" --verify "*)
        [ -f "\$d/ratelimit.update" ] && { err RATE_LIMITED "wait"; exit 1; }
        for a in "\$@"; do
          [ "\$prev" = "--body-file" ] && { echo "UPDATE \$3" >> "\$d/updates"; cat "\$a" >> "\$d/updates"; echo >> "\$d/updates"; }
          prev=\$a
        done
        echo '{"ok":true,"data":{"issue":{"identifier":"'"\$3"'"}}}' ;;
      *) echo '{"ok":true,"data":{"dryRun":true}}' ;;
    esac ;;
  "issue comment")
    case " \$* " in *" --verify "*) echo "COMMENT \$3" >> "\$d/comments" ;; esac
    echo '{"ok":true,"data":{"dryRun":true}}' ;;
  "issue view")
    # The real view: state and stateType, and a description cut to 500 characters unless --full.
    st=\$(cat "\$d/state.\$3" 2>/dev/null || echo Todo)
    case "\$st" in Done) ty=completed ;; Canceled) ty=canceled ;; *) ty=unstarted ;; esac
    meta='"state":"'"\$st"'","stateType":"'"\$ty"'"'
    if [ "\$3" = PC-9 ] && [ -f "\$d/pc9.desc" ]; then
      title='"title":"Older report",'; desc=\$(cat "\$d/pc9.desc")
    elif [ "\$3" = PC-55 ]; then
      title='"title":"'"\$(cat "\$d/created.title" 2>/dev/null)"'",'; desc="Filed earlier. surgeon-fp:\$(tr -d '\n' < "\$d/exists.txt")"
    else title=''; desc=unrelated; fi
    case " \$* " in *" --full "*) ;; *) [ \${#desc} -gt 500 ] && { desc=\${desc:0:500}; desc="\${desc%\\\\}\\\\n... (truncated, use --full)"; } ;; esac
    echo '{"ok":true,"data":{"issue":{"identifier":"'"\$3"'",'"\$meta"','"\$title"'"description":"'"\$desc"'"}}}' ;;
  "issue relation")
    case " \$* " in *" --verify "*) echo "RELATION \$4 \$5 \$6" >> "\$d/relations" ;; esac
    echo '{"ok":true,"data":{"dryRun":true}}' ;;
  "issue create")
    case " \$* " in
      *" --verify "*)
        [ -f "\$d/ratelimit.verify" ] && { err RATE_LIMITED "wait"; exit 1; }
        [ -f "\$d/verify.fail" ] && { [ -f "\$d/search.down.after.verify" ] && touch "\$d/search.down"; err VERIFY_FAILED "not readable back"; exit 1; }
        n=\$(( \$(cat "\$d/created" 2>/dev/null || echo 100) + 1 )); echo "\$n" > "\$d/created"
        for a in "\$@"; do
          [ "\$prev" = "--title" ] && printf '%s' "\$a" > "\$d/created.title"
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
  local extra=${3:-}
  case "$extra" in *"jev:"*) ;; *) extra="${extra}jev: $TMP_ROOT/no-jev.py; " ;; esac
  printf -- '- surgeon - Triage plus intake (role: surgeon; cadence: daily 06:00; archive: %s; hosts: alpha; app: https://app.test; %smodel: none; added 2026-11-04)\n' \
    "$2" "$extra" > "$1/data/officers.md"
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
  printf 'Bug\nChore\nscheduled-review\nbug-sweep\ntesting\ncalculators\ninfrastructure\ntriage\n' > "$LDIR/labels.txt"
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

DATE2=2026-10-24
DATE3=2026-10-25
run_surgeon_next_day() {  # <home> <world> [date days-later]: a run on DATE2 (or the given day) against the same lane.
  local day=${3:-$DATE2} later=${4:-1}
  officer_archive "$TMP_ROOT/$2/archive" "$day" "$TMP_ROOT/$2/spec.json"
  PATH="$FAKEBIN:$PATH" FM_OFFICER_NOW=$((NOW + 86400 * later)) FM_HOME="$1" "$OFFICER" run surgeon --date "$day"
}

fp() { printf '%s\0%s\0%s' "$1" "$2" "$3" | sha256sum | cut -d' ' -f1; }

LINEAR_ON="writes: linear; team: PC; "

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
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$OFFICER" run surgeon --date "$DATE" >/dev/null 2>&1 || fail "writes: linear needs no registry area, the area comes from each finding"
  surgeon_registry "$home" "$TMP_ROOT/registry/archive" "max-linear-calls: 0; "
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$OFFICER" run surgeon --date "$DATE" 2>&1) && fail "max-linear-calls 0 must be refused"
  assert_contains "$out" "max-linear-calls must be a whole number" "max-linear-calls is at least 1"
  surgeon_registry "$home" "$TMP_ROOT/registry/archive" "writes: linear; team: ENG; "
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
  assert_equals 7 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "the six real untracked findings and the one cluster are created"
  assert_equals 7 "$(grep -c '^issue create .*--dry-run' "$LINEAR_LOG")" "each create is dry-run first"
  assert_equals 1 "$(grep -c '^label list --team PC' "$LINEAR_LOG")" "labels are looked up once, in team PC"
  assert_equals created "$(row "$json" nightly fp-a .filing.action)" "the failure is filed"
  assert_equals "" "$(row "$json" nightly fp-a '.filing.verify // ""')" "a correct create verifies clean, with no trailing-newline mismatch"
  assert_equals "" "$(row "$json" nightly fp-c '.filing // "" | tostring | select(. != "")')" "a tracked failure is not filed"
  assert_equals "" "$(row "$json" sweeper b6 '.filing // "" | tostring | select(. != "")')" "a bug the sweeper filed is not filed again"
  assert_equals "" "$(row "$json" nightly fp-d '.filing // "" | tostring | select(. != "")')" "a finding needing a decision is not filed"
  assert_equals "" "$(row "$json" sweeper b2 '.filing // "" | tostring | select(. != "")')" "a won't-fix finding is not filed"
  assert_contains "$(grep '^issue create .*--verify' "$LINEAR_LOG" | head -1)" "--label Bug --label scheduled-review --label testing" "one Type, one Source and the area label from the finding's path"
  assert_contains "$(grep -- '--label bug-sweep' "$LINEAR_LOG" | head -1)" "--label Bug --label bug-sweep --label triage" "the sweeper's Source is bug-sweep and a finding with no fit gets the triage label"
  assert_contains "$(grep '^issue create .*--verify' "$LINEAR_LOG" | head -1)" "--team PC" "items go to team PC only"
  bodies=$(cat "$LDIR/bodies")
  assert_contains "$bodies" "surgeon-fp:$(fp nightly nightly-e2e fp-a)" "the description carries the fingerprint"
  assert_contains "$bodies" "Epic:" "the description names its epic"
  assert_contains "$bodies" "What it is for" "the description says what it is for"
  assert_equals created "$(row "$json" sweeper "" .filing.action)" "a key-less sweeper bug is fingerprinted from its title and filed"
  assert_equals created "$(row "$json" review "" .filing.action)" "a key-less review finding is fingerprinted from its title and location and filed"
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
  assert_equals 6 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "the other six are created, so an unrelated fuzzy hit never counts"
  assert_equals 1 "$(grep -c '^issue update PC-55 .*--verify' "$LINEAR_LOG")" "a fingerprint seen again bumps the Found line once"
  assert_contains "$(cat "$LDIR/updates")" "Found: 2 times (first $DATE, last $DATE, by surgeon)" "the Found line says how many times"
  assert_equals 1 "$(wc -l < "$LDIR/comments" | tr -d ' ')" "and one comment is added on that first sighting"
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
  assert_equals "created created" "$(row "$json" nightly fp-a .filing.action) $(row "$json" review "" .filing.action)" "the highest scores go first, ties by source then key"
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

test_failed_fallback_search_keeps_the_verify_error() {
  local home json
  make_world searchdown "${LINEAR_ON}max-creates: 1; "; home=$WORLD_HOME
  touch "$LDIR/verify.fail" "$LDIR/search.down.after.verify"
  run_surgeon "$home" >/dev/null || fail "a failed fallback search must not fail the run"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals failed "$(row "$json" nightly fp-a .filing.action)" "the finding is reported failed"
  assert_contains "$(row "$json" nightly fp-a .filing.reason)" "VERIFY_FAILED: not readable back" "the verify error stays the reason"
  assert_contains "$(row "$json" nightly fp-a .filing.reason)" "search down" "and the search error follows it"
  pass "fm-officer surgeon: a failed fallback search keeps the verify error as the reason"
}

test_created_item_with_verify_mismatch_is_ledgered() {
  local home json
  make_world mismatch "${LINEAR_ON}max-creates: 1; "; home=$WORLD_HOME
  touch "$LDIR/verify.mismatch"
  run_surgeon "$home" >/dev/null || fail "a verify mismatch must not fail the run"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "created PC-55" "$(row "$json" nightly fp-a '[.filing.action,.filing.issue]|join(" ")')" "a created item is not reported failed"
  assert_contains "$(row "$json" nightly fp-a .filing.verify)" "did not match" "the mismatch is kept"
  assert_contains "$(cat "$home/data/officers/surgeon/$DATE.md")" "[created PC-55, verify mismatch]" "the digest shows the mismatch"
  assert_equals "PC-55" "$(jq -r --arg fp "$(fp nightly nightly-e2e fp-a)" '.[$fp]' "$home/data/officers/surgeon/filed-fingerprints.json")" "its fingerprint is in the ledger"
  pass "fm-officer surgeon: a created item whose verify mismatches is still ledgered"
}

test_verify_mismatch_waits_for_search_to_catch_up() {
  local home json
  make_world lag "${LINEAR_ON}max-creates: 1; "; home=$WORLD_HOME
  touch "$LDIR/verify.mismatch"
  echo 2 > "$LDIR/search.lag"
  run_surgeon "$home" >/dev/null || fail "a lagging search must not fail the run"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "created PC-55" "$(row "$json" nightly fp-a '[.filing.action,.filing.issue]|join(" ")')" "an item the search finds late is reported created"
  assert_equals "PC-55" "$(jq -r --arg fp "$(fp nightly nightly-e2e fp-a)" '.[$fp]' "$home/data/officers/surgeon/filed-fingerprints.json")" "and ledgered"
  assert_equals 1 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "the create is not retried"
  pass "fm-officer surgeon: a verify mismatch waits briefly for the search to find the item"
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
  assert_contains "$(row "$json" nightly fp-a .filing.reason)" "label(s) not found in team PC: triage" "naming the missing label (the fallback, as no area label fits)"
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
  assert_equals 7 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "after the pause it files again"
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


# --- the contract tests: area, clusters, duplicates, found count, production, invalid E2E, starts, patterns ---

set_pages() {  # <world> <review findings json> <sweeper bugs json> [e2e shared json]: replaces the fixture pages.
  local d="$TMP_ROOT/$1/pages"
  jq -n --argjson f "$2" '{run: {}, summary: {}, shared: null, result: {findings: $f, filings: {filed: [], digested: [], commented: []}}}' > "$d/_api_runs_nightly-review_results_R2"
  jq -n --argjson b "$3" '{runs: [], latestPlan: null, latest: {run: {run_id: "sweep-1", intake: {bugs: $b, linear: {filed: [], updated: [], cancelled: [], dismissed: []}}}}}' > "$d/_api_sweeper-results"
  jq -n --argjson s "${4:-null}" '{run: {}, result: {sha: "x", status: "RED"}, shared: $s}' > "$d/_api_runs_nightly-e2e_results_R1"
}

fake_jev() {  # <path>: reports 0.91 for "duplicate-me", 0.6 for "near-me", else 0.1; exit 3 when told it is down.
  cat > "$1" <<'PY'
import json, sys
state = json.loads(sys.argv[sys.argv.index("--state") + 1])["report_a"]
print(json.dumps({"type": "noul", "noul": 0.91 if "duplicate-me" in state else 0.6 if "near-me" in state else 0.1}))
PY
}

test_area_label_comes_from_the_finding() {
  local home
  make_world area "$LINEAR_ON"; home=$WORLD_HOME
  set_pages area '[
    {"id":"a1","severity":"critical","file":"src/PropertyCompass.Web/client/src/pages/calculators/Yield.tsx","summary":"yield rounds twice"},
    {"id":"a2","severity":"critical","file":"infra/bicep/main.bicep","summary":"app plan has no alert"},
    {"id":"a3","severity":"critical","file":"Odd.cs","summary":"mystery"},
    {"id":"a4","severity":"critical","file":"src/Thing/Unlabelled.cs","summary":"no label for authentication here"}]' '[]'
  rm -f "$LDIR/labels.txt"; printf 'Bug\nscheduled-review\ntriage\ncalculators\ninfrastructure\n' > "$LDIR/labels.txt"
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  assert_contains "$(grep '^issue create .*yield rounds twice.*--verify' "$LINEAR_LOG")" "--label calculators" "a calculators path gets the calculators label"
  assert_contains "$(grep '^issue create .*app plan has no alert.*--verify' "$LINEAR_LOG")" "--label infrastructure" "a bicep path gets infrastructure"
  assert_contains "$(grep '^issue create .*mystery.*--verify' "$LINEAR_LOG")" "--label triage" "a finding that fits nothing gets the triage label"
  assert_contains "$(grep '^issue create .*no label for authentication.*--verify' "$LINEAR_LOG")" "--label triage" "a rule whose label is not in team PC is skipped, never invented"
  assert_not_contains "$(cat "$LINEAR_LOG")" "ci-cd" "no hard-wired area label"
  assert_equals 4 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "every finding is filed"
  pass "fm-officer surgeon: the area label is derived from each finding, with triage as the fallback"
}

test_low_review_findings_are_clustered_and_ticked_off() {
  local home json bodies
  make_world clusters "$LINEAR_ON"; home=$WORLD_HOME
  set_pages clusters '[
    {"id":"c1","severity":"medium","file":"infra/bicep/a.bicep","summary":"unpinned api version one"},
    {"id":"c2","severity":"medium","file":"infra/bicep/b.bicep","summary":"unpinned api version two"},
    {"id":"c3","severity":"medium","file":"infra/bicep/c.bicep","summary":"unpinned api version three"},
    {"id":"c4","severity":"medium","file":"x/y/z.cs","summary":"lone finding"},
    {"id":"c5","severity":"medium","file":"x/w/q.cs","summary":"another lone finding"},
    {"id":"m1","severity":"high","file":"infra/bicep/d.bicep","summary":"medium finding keeps its own item"}]' '[]'
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals 3 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "a medium finding and two clusters, not one item per finding"
  bodies=$(cat "$LDIR/bodies")
  for id in c1 c2 c3; do
    assert_contains "$bodies" "surgeon-fp:$(fp review nightly-review $id)" "the cluster lists $id's fingerprint"
  done
  assert_contains "$(grep '^issue create .*Code review findings: infra bicep' "$LINEAR_LOG")" "--label infrastructure" "the cluster's area comes from its path"
  assert_contains "$(grep '^issue create .*Code review findings: x' "$LINEAR_LOG")" "x (misc)" "groups under three findings fold into the first part's misc cluster"
  assert_equals clustered "$(row "$json" review c1 .filing.action)" "a clustered finding is reported as clustered"
  assert_equals "6 6 0" "$(jq -r '.burn_down | [.open,.new,.fixed] | map(tostring) | join(" ")' "$json")" "the first night: six open, six new, none fixed"
  # Same day, a new finding joins its cluster and a resolved one is ticked off.
  : > "$LINEAR_LOG"
  jq '.result.resolved = ["c2"] | .result.findings += [{"id":"c6","severity":"medium","file":"infra/bicep/e.bicep","summary":"unpinned api version six"}]' \
    "$TMP_ROOT/clusters/pages/_api_runs_nightly-review_results_R2" > "$TMP_ROOT/clusters/r2.json"
  mv "$TMP_ROOT/clusters/r2.json" "$TMP_ROOT/clusters/pages/_api_runs_nightly-review_results_R2"
  run_surgeon "$home" >/dev/null || fail "second run must succeed"
  assert_equals 0 "$(grep -c '^issue create' "$LINEAR_LOG")" "no new item for a new finding in a known cluster"
  assert_equals 1 "$(grep -c '^issue update .*--dry-run' "$LINEAR_LOG")" "the cluster item is updated, dry-run first"
  assert_equals 1 "$(grep -c '^issue update .*--verify' "$LINEAR_LOG")" "and verified"
  assert_contains "$(cat "$LDIR/updates")" "- [x] surgeon-fp:$(fp review nightly-review c2)" "the reviewer's resolved finding is ticked off"
  assert_contains "$(cat "$LDIR/updates")" "- [ ] surgeon-fp:$(fp review nightly-review c6)" "the new finding is listed open"
  assert_contains "$(cat "$home/data/officers/surgeon/$DATE.md")" "Burn-down (reviewer findings, ISO week 2026-W43): 6 open, 7 new, 1 fixed." "the digest carries the burn-down line"
  # Counts now say split (over 25 in infra/bicep), but a file already listed keeps its cluster.
  jq '.result.findings += [range(0;27) | {id: ("n\(.)"), severity: "medium", file: "infra/bicep/m/f\(.).bicep", summary: "new finding \(.)"}]
      | .result.findings += [{"id":"c7","severity":"medium","file":"infra/bicep/a.bicep","summary":"second finding in a.bicep"}]' \
    "$TMP_ROOT/clusters/pages/_api_runs_nightly-review_results_R2" > "$TMP_ROOT/clusters/r2.json"
  mv "$TMP_ROOT/clusters/r2.json" "$TMP_ROOT/clusters/pages/_api_runs_nightly-review_results_R2"
  run_surgeon "$home" >/dev/null || fail "third run must succeed"
  assert_equals "infra/bicep" "$(jq -r --arg fp "$(fp review nightly-review c7)" '.clusters | to_entries[] | select(.value.members[$fp]) | .value.key' "$home/data/officers/surgeon/review-state.json")" "a new finding in an already-listed file joins that file's cluster even when the counts now split the group"
  assert_equals "infra/bicep/m" "$(jq -r --arg fp "$(fp review nightly-review n0)" '.clusters | to_entries[] | select(.value.members[$fp]) | .value.key' "$home/data/officers/surgeon/review-state.json")" "while files new to the group follow the split"
  # A person closes the infra/bicep item: it is never updated again; a new finding files a new item naming it.
  local cfp old
  cfp=$(fp review cluster infra/bicep)
  old=$(jq -r --arg fp "$cfp" '.[$fp]' "$home/data/officers/surgeon/filed-fingerprints.json")
  echo Done > "$LDIR/state.$old"
  : > "$LINEAR_LOG"; : > "$LDIR/bodies"
  jq '.result.findings += [{"id":"c8","severity":"medium","file":"infra/bicep/a.bicep","summary":"third finding in a.bicep"}]' \
    "$TMP_ROOT/clusters/pages/_api_runs_nightly-review_results_R2" > "$TMP_ROOT/clusters/r2.json"
  mv "$TMP_ROOT/clusters/r2.json" "$TMP_ROOT/clusters/pages/_api_runs_nightly-review_results_R2"
  run_surgeon "$home" >/dev/null || fail "run after the cluster item was closed"
  assert_equals 0 "$(grep -c "^issue update $old" "$LINEAR_LOG")" "a closed cluster item is never updated"
  assert_contains "$(grep '^issue create .*--verify' "$LINEAR_LOG")" "Code review findings: infra bicep" "a new cluster item is filed"
  assert_contains "$(cat "$LDIR/bodies")" "Recurrence of $old (closed as Done)." "naming the closed one"
  assert_equals "$old" "$(row "$json" review c8 .filing.recurrence_of)" "and the finding says so"
  assert_not_contains "$(jq -r --arg fp "$cfp" '.[$fp]' "$home/data/officers/surgeon/filed-fingerprints.json")" "$old" "the ledger points at the new item"
  : > "$LDIR/updates"
  jq '.result.findings += [{"id":"c9","severity":"medium","file":"infra/bicep/b.bicep","summary":"fourth finding in bicep"}]' \
    "$TMP_ROOT/clusters/pages/_api_runs_nightly-review_results_R2" > "$TMP_ROOT/clusters/r2.json"
  mv "$TMP_ROOT/clusters/r2.json" "$TMP_ROOT/clusters/pages/_api_runs_nightly-review_results_R2"
  run_surgeon "$home" >/dev/null || fail "run after the recurrence"
  assert_contains "$(cat "$LDIR/updates")" "surgeon-fp:$(fp review nightly-review c9)" "the next change updates the new cluster item"
  assert_contains "$(cat "$LDIR/updates")" "Recurrence of $old (closed as Done)." "and keeps the line naming the closed one"
  pass "fm-officer surgeon: low review findings are clustered by component, updated in place and ticked off"
}

test_duplicates_bump_the_found_count_through_local_jev() {
  local home json
  make_world dup "${LINEAR_ON}jev: $TMP_ROOT/dup/jev.py; "; home=$WORLD_HOME
  fake_jev "$TMP_ROOT/dup/jev.py"
  printf 'Older report.\\n%s\\nFound: 1 times (first 2026-10-01, last 2026-10-01, by surgeon)\\nTail evidence kept' "$(printf 'evidence %.0s' $(seq 1 70))" > "$LDIR/pc9.desc"
  set_pages dup '[]' '[
    {"fp":"d1","title":"Save crashes duplicate-me","disposition":"new","severity":"P2"},
    {"fp":"d2","title":"Odd total near-me","disposition":"new","severity":"P2"},
    {"fp":"d3","title":"Something else entirely","disposition":"new","severity":"P2"}]'
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "duplicate PC-9 0.91" "$(row "$json" sweeper d1 '[.filing.action,.filing.issue,(.filing.confidence|tostring)]|join(" ")')" "above 0.85 it is the same issue"
  assert_equals created "$(row "$json" sweeper d2 .filing.action)" "a near match below 0.85 is filed new"
  assert_equals PC-9 "$(row "$json" sweeper d2 .filing.near_match.issue)" "and names the near match"
  assert_contains "$(cat "$LDIR/bodies")" "Near match (not treated as the same issue): PC-9" "in its description"
  assert_equals 2 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "only the two that are not duplicates are created"
  assert_contains "$(cat "$LDIR/updates")" "Found: 2 times (first 2026-10-01, last $DATE, by surgeon)" "the duplicate bumps the one Found line in place"
  assert_contains "$(cat "$LDIR/updates")" "Tail evidence kept" "a description over 500 characters is read in full, so the rest of it survives the bump"
  assert_not_contains "$(cat "$LDIR/updates")" "truncated" "and no truncation hint is written back"
  assert_contains "$(grep '^issue update PC-9' "$LINEAR_LOG" | head -1)" "--dry-run" "dry-run first"
  assert_equals 1 "$(wc -l < "$LDIR/comments" | tr -d ' ')" "one comment on that day's first sighting"
  assert_equals 2 "$(row "$json" sweeper d1 .found)" "the finding carries its found count"
  assert_equals 3.17 "$(row "$json" sweeper d1 .score)" "and the score is weight (medium 2) x log2(1 + found 2)"
  assert_equals 0 "$(jq '[.start_requests[] | select(.kind == "surgeon-finding")] | length' "$json")" "a medium finding found twice is under the start minimum of 4"
  : > "$LINEAR_LOG"
  run_surgeon "$home" >/dev/null || fail "same-day rerun"
  assert_equals 0 "$(grep -c '^issue update\|^issue comment' "$LINEAR_LOG")" "the same day never bumps twice and adds no second comment"
  pass "fm-officer surgeon: a local-jev duplicate bumps the Found line once a day"
}

test_found_count_lifts_a_duplicate_into_the_start_decision() {
  local home json
  make_world foundstart "${LINEAR_ON}jev: $TMP_ROOT/foundstart/jev.py; "; home=$WORLD_HOME
  fake_jev "$TMP_ROOT/foundstart/jev.py"
  printf 'Older report, never started.\\nFound: 2 times (first 2026-10-01, last 2026-10-20, by surgeon)' > "$LDIR/pc9.desc"
  set_pages foundstart '[]' '[{"fp":"f1","title":"Crash on save duplicate-me","disposition":"new","severity":"P2"}]'
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "duplicate 3 medium" "$(row "$json" sweeper f1 '[.filing.action,(.found|tostring),.severity]|join(" ")')" "a medium duplicate seen on a third day has found count 3"
  assert_equals true "$(row "$json" sweeper f1 ".score == 4")" "so its score is 2 x log2(4)"
  assert_equals PC-9 "$(jq -r '[.start_requests[] | select(.kind == "surgeon-finding")][0].issue' "$json")" "its score reaches the minimum, so the existing item starts"
  assert_equals 1 "$(jq '[.start_requests[] | select(.kind == "surgeon-finding")] | length' "$json")" "once"
  assert_equals "$DATE" "$(jq -r '.handled["PC-9"]' "$home/data/officers/surgeon/review-state.json")" "and the item is recorded as handled"
  run_surgeon "$home" >/dev/null || fail "same-day rerun"
  assert_equals PC-9 "$(jq -r '[.start_requests[] | select(.kind == "surgeon-finding")][0].issue' "$json")" "a same-day rerun repeats the same request"
  jq '.handled["PC-9"] = "2026-10-22"' "$home/data/officers/surgeon/review-state.json" > "$TMP_ROOT/foundstart/s.json" && mv "$TMP_ROOT/foundstart/s.json" "$home/data/officers/surgeon/review-state.json"
  run_surgeon "$home" >/dev/null || fail "next-day rerun"
  assert_equals 0 "$(jq '[.start_requests[] | select(.kind == "surgeon-finding")] | length' "$json")" "an item handled on an earlier day is never asked for twice"
  pass "fm-officer surgeon: the found count reaches the start decision, once per item"
}

test_a_finding_that_keeps_coming_back_stops_at_three_starts() {
  local home json state fp
  make_world capstart "${LINEAR_ON}jev: $TMP_ROOT/capstart/jev.py; "; home=$WORLD_HOME
  fake_jev "$TMP_ROOT/capstart/jev.py"
  printf 'Older report.\\nFound: 2 times (first 2026-10-01, last 2026-10-20, by surgeon)' > "$LDIR/pc9.desc"
  set_pages capstart '[]' '[{"fp":"f1","title":"Crash on save duplicate-me","disposition":"new","severity":"P2"}]'
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"; state="$home/data/officers/surgeon/review-state.json"
  fp=$(jq -r '[.start_requests[] | select(.kind == "surgeon-finding")][0].fingerprint' "$json")
  assert_equals '["PC-9"]' "$(jq -c --arg fp "$fp" '.starts_by_fp[$fp]' "$state")" "a start is recorded against its fingerprint"
  jq --arg fp "$fp" 'del(.handled["PC-9"]) | .starts_by_fp[$fp] = ["PC-1","PC-2"]' "$state" > "$TMP_ROOT/capstart/s.json" && mv "$TMP_ROOT/capstart/s.json" "$state"
  run_surgeon "$home" >/dev/null || fail "third-start rerun"
  assert_equals 1 "$(jq '[.start_requests[] | select(.kind == "surgeon-finding")] | length' "$json")" "a third item for one fingerprint still starts"
  assert_equals '["PC-1","PC-2","PC-9"]' "$(jq -c --arg fp "$fp" '.starts_by_fp[$fp]' "$state")" "the third start is recorded"
  jq --arg fp "$fp" 'del(.handled["PC-9"]) | .starts_by_fp[$fp] = ["PC-1","PC-2","PC-3"]' "$state" > "$TMP_ROOT/capstart/s.json" && mv "$TMP_ROOT/capstart/s.json" "$state"
  run_surgeon "$home" >/dev/null || fail "capped rerun"
  assert_equals 0 "$(jq '[.start_requests[] | select(.kind == "surgeon-finding")] | length' "$json")" "a fourth item for one fingerprint does not start"
  assert_equals 1 "$(jq '[.start_requests[] | select(.kind == "surgeon-fix-cap")] | length' "$json")" "it goes to the office lane as one capped-repeat request"
  assert_equals 0 "$(jq '[.asks_for_lee[] | select(.key == "surgeon-PC-9-fix-cap")] | length' "$json")" "and is not added to asks_for_lee"
  assert_contains "$(jq -r '[.start_requests[] | select(.kind == "surgeon-fix-cap")][0].execute.argv | last' "$json")" "surgeon-PC-9-fix-cap" "the request names its escalation key for the office"
  pass "fm-officer surgeon: a finding that keeps coming back stops at 3 starts"
}

test_start_home_reaches_the_surgeon_through_the_registry() {
  local home nav json
  make_world wiring "${LINEAR_ON}start-home: navigator; "; home=$WORLD_HOME
  nav="$TMP_ROOT/wiring/navigator"
  officer_home "$nav"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$nav/data/backlog.md"
  printf 'navigator\n' > "$nav/.fm-office"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home" > "$nav/.fm-secondmate-parent"
  printf -- '- navigator - nav (home: %s; scope: office; projects: PropertyCompass2; added 2026-11-04)\n' "$nav" > "$home/data/secondmates.md"
  printf -- '- navigator - nav (role: navigator; dispatch: PropertyCompass2; sources: tick,lane:surgeon:high; added 2026-11-04)\n' > "$home/data/offices.md"
  FM_HOME="$nav" "$ROOT/bin/fm-office.sh" register-sources >/dev/null || fail "register-sources must succeed in the navigator home"
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "$nav" "$(jq -r '[.start_requests[] | select(.kind == "surgeon-finding")][0].execute.env.FM_HOME' "$json")" "a PropertyCompass2 start is addressed to the navigator"
  assert_contains "$(FM_OFFICE_NOW=$NOW FM_HOME="$nav" bash "$ROOT/bin/fm-office.sh" check lane:surgeon:high)" "start request(s) delivered to this office's inbox" "the navigator's lane check delivers it"
  pass "fm-officer surgeon: start-home in the registry sends starts to the owning office"
}

test_local_jev_unreachable_files_by_fingerprint_only() {
  local home out
  make_world nojev "${LINEAR_ON}jev: $TMP_ROOT/nojev/jev.py; "; home=$WORLD_HOME
  printf 'import sys\nsys.exit(3)\n' > "$TMP_ROOT/nojev/jev.py"
  out=$(run_surgeon "$home") || fail "an unreachable local-jev must not fail the run"
  assert_contains "$out" "Coverage gap: local-jev unreachable" "the gap is named"
  assert_equals 7 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "findings are still filed"
  pass "fm-officer surgeon: without local-jev only the fingerprint decides"
}

test_production_environment_bumps_severity_one_step() {
  local home json
  make_world prod "$LINEAR_ON"; home=$WORLD_HOME
  set_pages prod '[]' '[
    {"fp":"p1","title":"low bug in prod","disposition":"new","severity":"P3","environment":"production"},
    {"fp":"p2","title":"medium bug in prod","disposition":"new","severity":"P2","environment":"production"},
    {"fp":"p3","title":"high bug in prod","disposition":"new","severity":"P1","environment":"production"},
    {"fp":"p4","title":"medium bug in staging","disposition":"new","severity":"P2","environment":"staging"},
    {"fp":"p5","title":"medium bug in production by text only, production","disposition":"new","severity":"P2"},
    {"fp":"p6","title":"duplicate in prod","disposition":"duplicate","severity":"P1","environment":"production"}]'
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "medium high critical" "$(row "$json" sweeper p1 .severity) $(row "$json" sweeper p2 .severity) $(row "$json" sweeper p3 .severity)" "production moves a finding up one step"
  assert_equals "medium medium" "$(row "$json" sweeper p4 .severity) $(row "$json" sweeper p5 .severity)" "staging, and a payload with no environment field, get no bump"
  assert_equals low "$(row "$json" sweeper p6 .severity)" "a won't-fix finding stays low"
  assert_contains "$(grep '^issue create .*high bug in prod.*--verify' "$LINEAR_LOG")" "--priority 1" "critical is Urgent in Linear"
  pass "fm-officer surgeon: an environment of production bumps severity, and text alone never does"
}

test_invalid_nightly_e2e_is_a_top_severity_promotion_blocker() {
  local home json
  make_world invalid "$LINEAR_ON"; home=$WORLD_HOME
  set_pages invalid '[]' '[]' '{"status":"invalid","reason":"account reached its limit","findings":[]}'
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "real critical" "$(row "$json" nightly e2e-invalid '[.class,.severity]|join(" ")')" "an invalid run is a real, critical finding"
  assert_equals 1 "$(grep -c '^issue create .*promotion blocked.*--verify' "$LINEAR_LOG")" "one Linear item"
  assert_contains "$(grep '^issue create' "$LINEAR_LOG" | head -1)" "--priority 1" "at the top priority"
  assert_contains "$(cat "$LDIR/bodies")" "Promotion-blocking: yes" "marked promotion-blocking"
  assert_contains "$(cat "$LDIR/bodies")" "account reached its limit" "with the reason"
  assert_equals 0 "$(jq '[.start_requests[] | select(.kind == "surgeon-finding")] | length' "$json")" "it never starts by itself"
  : > "$LINEAR_LOG"
  run_surgeon "$home" >/dev/null || fail "rerun"
  assert_equals 0 "$(grep -c '^issue create\|^issue update\|^issue comment' "$LINEAR_LOG")" "a same-day rerun adds nothing"
  run_surgeon_next_day "$home" invalid >/dev/null || fail "next-day run"
  assert_equals 0 "$(grep -c '^issue create' "$LINEAR_LOG")" "a second invalid day files no new item"
  assert_contains "$(sed -n '/^UPDATE PC-101$/,$p' "$LDIR/updates")" "Found: 2 times" "it bumps the Found line on the same item, recording the outage length"
  echo Done > "$LDIR/state.PC-101"
  : > "$LINEAR_LOG"; : > "$LDIR/bodies"
  run_surgeon_next_day "$home" invalid "$DATE3" 2 >/dev/null || fail "run after the item was closed"
  json="$home/data/officers/surgeon/$DATE3.json"
  assert_equals 0 "$(grep -c '^issue update PC-101' "$LINEAR_LOG")" "a closed item is never bumped or reopened"
  assert_equals "created PC-102 PC-101" "$(row "$json" nightly e2e-invalid '[.filing.action,.filing.issue,.filing.recurrence_of]|join(" ")')" "a recurrence files a new item"
  assert_contains "$(cat "$LDIR/bodies")" "Recurrence of PC-101 (closed as Done)." "that names the closed one"
  assert_contains "$(cat "$LDIR/bodies")" "Found: 1 times (first $DATE3, last $DATE3, by surgeon)" "with its own Found line"
  assert_contains "$(grep '^issue create .*--verify' "$LINEAR_LOG")" "--priority 1" "still urgent and promotion-blocking"
  assert_equals "RELATION PC-102 --related PC-101" "$(cat "$LDIR/relations")" "and is linked to it as related"
  assert_equals PC-102 "$(jq -r --arg fp "$(row "$json" nightly e2e-invalid .fingerprint)" '.[$fp]' "$home/data/officers/surgeon/filed-fingerprints.json")" "the old ledger entry is retired"
  set_pages invalid '[]' '[]' 'null'
  jq -n '{run: {}, result: null, shared: null}' > "$TMP_ROOT/invalid/pages/_api_runs_nightly-e2e_results_R1"
  assert_contains "$(run_surgeon "$home")" "Coverage gap: no E2E input" "an empty E2E result is a named gap, never a silent absence"
  pass "fm-officer surgeon: an invalid nightly E2E run is filed as a top-severity promotion blocker"
}

test_start_requests_follow_the_rubric_and_hold_reserved_classes() {
  local home json out
  make_world starts "$LINEAR_ON"; home=$WORLD_HOME
  set_pages starts '[]' '[
    {"fp":"s1","title":"Crash on save","disposition":"new","severity":"P1"},
    {"fp":"s2","title":"Stripe payment fails for annual plan","disposition":"new","severity":"P1"},
    {"fp":"s3","title":"Wrong total","disposition":"new","severity":"P2"}]'
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "Crash on save" "$(jq -r '[.start_requests[] | select(.kind == "surgeon-finding") | .title] | join("|")' "$json")" "only the real high finding starts"
  assert_equals "$home" "$(jq -r '.start_requests[0].execute.env.FM_HOME' "$json")" "on the progress officer's start path"
  assert_contains "$(jq -r '.start_requests[0].execute.argv | join(" ")' "$json")" "fm-inbox.sh note --request-id surgeon-$DATE-" "through the inbox note intake"
  assert_equals "surgeon-holds-$DATE" "$(jq -r '.asks_for_lee[0].key' "$json")" "a reserved class becomes one keyed needs-decision"
  assert_equals "payments-billing" "$(jq -r '.held[0].class' "$json")" "naming its class"
  assert_contains "$(cat "$home/data/officers/surgeon/$DATE.md")" "needs-decision [key=surgeon-holds-$DATE]" "in the digest"
  assert_equals 2 "$(grep -c 'fm-inbox.sh' "$home/data/officers/surgeon/$DATE.start-requests.sh")" "and the hand-off script carries this home's requests (the start and the pattern batch)"
  assert_equals 0 "$(jq '[.start_requests[] | select(.title == "Wrong total")] | length' "$json")" "a medium finding only files"
  # A rubric can only narrow: asking for more is ignored and named.
  printf '## Settings the code reads\n- start-severities: low, high\n- start-sources: sweeper, invented\n- hold-classes: legal\n' > "$TMP_ROOT/starts/rubric.md"
  surgeon_registry "$home" "$TMP_ROOT/starts/archive" "${LINEAR_ON}rubric: $TMP_ROOT/starts/rubric.md; "
  rm -f "$home/data/officers/surgeon/"*.json "$home/data/officers/surgeon/"*.md
  out=$(run_surgeon "$home") || fail "narrow rubric run"
  assert_contains "$out" "names low, which the code does not admit" "a rubric cannot admit low"
  assert_contains "$out" "names invented" "or an unknown source"
  assert_contains "$out" "omits payments-billing" "and cannot drop a reserved class"
  assert_equals "payments-billing" "$(jq -r '.held[0].class' "$home/data/officers/surgeon/$DATE.json")" "which is held anyway"
  surgeon_registry "$home" "$TMP_ROOT/starts/archive" "${LINEAR_ON}rubric: $TMP_ROOT/starts/missing.md; "
  rm -f "$home/data/officers/surgeon/"*.json "$home/data/officers/surgeon/filed-fingerprints.json" "$home/data/officers/surgeon/review-state.json" "$home/data/officers/surgeon/found.json"
  out=$(run_surgeon "$home") || fail "missing rubric run"
  assert_contains "$out" "nothing starts by itself" "a missing rubric starts nothing and says so"
  assert_equals 0 "$(jq '[.start_requests[] | select(.kind == "surgeon-finding")] | length' "$home/data/officers/surgeon/$DATE.json")" "no start request"
  pass "fm-officer surgeon: starts follow the rubric, which can only narrow, and reserved classes hold"
}

test_call_budget_stops_the_run_and_the_next_run_continues() {
  local home json out
  make_world budget "${LINEAR_ON}max-linear-calls: 6; "; home=$WORLD_HOME
  out=$(run_surgeon "$home") || fail "a spent budget must not fail the run"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals 6 "$(wc -l < "$LINEAR_LOG" | tr -d ' ')" "Linear calls stop at the budget"
  assert_contains "$out" "Linear call budget of 6 reached" "the run names it"
  assert_equals 6 "$(jq .linear_calls "$json")" "the digest counts the calls"
  [ ! -f "$home/data/officers/surgeon/linear-resume-after.json" ] || fail "a spent budget is not a rate-limit pause"
  assert_contains "$(row "$json" sweeper b1 .filing.reason)" "Linear call budget" "unfiled findings say why"
  pass "fm-officer surgeon: the Linear call budget stops the run without a pause"
}

test_keyless_fingerprint_ignores_run_to_run_digits() {
  local home first second
  make_world keyless "$LINEAR_ON"; home=$WORLD_HOME
  set_pages keyless '[{"severity":"critical","file":"src/Foo.cs:41","summary":"Timeout after 30 s on page 4"}]' '[]'
  run_surgeon "$home" >/dev/null || fail "first run"
  first=$(jq -r '.findings[] | select(.keyless) | .fingerprint' "$home/data/officers/surgeon/$DATE.json")
  set_pages keyless '[{"severity":"critical","file":"src/Foo.cs:97","summary":"Timeout after 31 s on page 12"}]' '[]'
  run_surgeon "$home" >/dev/null || fail "second run"
  second=$(jq -r '.findings[] | select(.keyless) | .fingerprint' "$home/data/officers/surgeon/$DATE.json")
  assert_equals "$first" "$second" "a key-less finding keeps its fingerprint when only digits change"
  assert_equals 1 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "so it is filed once"
  pass "fm-officer surgeon: a key-less finding is fingerprinted from its normalised title and location"
}

test_patterns_are_deduped_handed_on_and_proposed_as_rules() {
  local home json
  make_world patterns "$LINEAR_ON"; home=$WORLD_HOME
  set_pages patterns '[
    {"id":"q1","severity":"critical","file":"A.cs","summary":"SQL built from user input","fix":"use parameterised queries"},
    {"id":"q2","severity":"critical","file":"B.cs","summary":"SQL built from user input"},
    {"id":"q3","severity":"high","file":"C.cs","summary":"Dialog loses focus on close"}]' '[]'
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "3 2 2" "$(jq -r '[(.findings|length), .patterns.total, (.patterns.new|length)] | map(tostring) | join(" ")' "$json")" "equal titles are one pattern"
  assert_equals 2 "$(jq -r '.patterns.new[] | select(.line | startswith("Anti-pattern: SQL built")) | .count' "$json")" "whose count goes up"
  assert_contains "$(jq -r '.patterns.new[].line' "$json")" "Safe form: use parameterised queries" "a line carries the anti-pattern and the safe form"
  assert_equals pattern-memory "$(jq -r '[.start_requests[] | select(.kind == "pattern-memory")][0].kind' "$json")" "new patterns go to the Navigator in one batched start request"
  assert_contains "$(jq -r '[.start_requests[] | select(.kind == "pattern-memory")][0].execute.argv | join(" ")' "$json")" "quality-patterns.md" "naming the target file"
  assert_equals "pattern project:PropertyCompass2" "$(jq -r '.patterns.captures[0].tags | join(" ")' "$json")" "captures are tagged pattern plus project"
  assert_contains "$(cat "$home/data/officers/surgeon/$DATE.md")" "no scriptable path to the memory tier" "and the digest says why the office must capture them"
  assert_contains "$(jq -r '.patterns.lint[].proposal' "$json")" "SQL built from user input" "a mechanical pattern gets a proposed lint rule"
  assert_not_contains "$(jq -r '.patterns.lint[].proposal' "$json")" "Dialog loses focus" "and a non-mechanical one does not"
  pass "fm-officer surgeon: bad patterns are deduped, handed to the Navigator, captured and proposed as rules"
}

test_cluster_split_and_fold_constants() {
  local home findings
  make_world split "$LINEAR_ON"; home=$WORLD_HOME
  findings=$(jq -n '[range(0;12) | {id: ("c\(.)"), severity: "medium", file: "a/b/c/f\(.).cs", summary: "c finding \(.)"}]
    + [range(0;12) | {id: ("d\(.)"), severity: "medium", file: "a/b/d/f\(.).cs", summary: "d finding \(.)"}]
    + [range(0;6) | {id: ("e\(.)"), severity: "medium", file: "a/b/e/f\(.).cs", summary: "e finding \(.)"}]')
  set_pages split "$findings" '[]'
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  assert_equals 3 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "30 findings in one 2-part group (over 25) split into three items"
  assert_contains "$(cat "$LINEAR_LOG")" "Code review findings: a b c (a/b/c)" "a subgroup of 10 or more keeps its own item"
  assert_contains "$(cat "$LINEAR_LOG")" "(a/b (other))" "a subgroup under 10 folds back into the parent's (other) item"
  pass "fm-officer surgeon: a cluster over 25 splits one level deeper and small subgroups fold back"
}

test_start_requests_route_by_project_to_the_owning_office() {
  local home json
  make_world route "$LINEAR_ON"; home=$WORLD_HOME
  set_pages route '[
    {"id":"r1","severity":"critical","file":"A.cs","summary":"PC finding"},
    {"id":"r2","severity":"critical","file":"bin/x.sh","summary":"Fleet finding","repo":"firstmate"}]' '[]'
  mkdir -p "$TMP_ROOT/route/out"
  PATH="$FAKEBIN:$PATH" python3 -I "$ROOT/bin/fm-officer-surgeon.py" run --archive "$TMP_ROOT/route/archive" --date "$DATE" \
    --out "$TMP_ROOT/route/out" --app https://app.test --home "$home" --hosts alpha --writes linear --jev none \
    --fm-home "$home" --start-home /offices/nav=propertycompass2 --start-home /offices/qm=firstmate --now "$NOW" >/dev/null \
    || fail "direct surgeon run must succeed"
  json="$TMP_ROOT/route/out/$DATE.json"
  assert_equals /offices/nav "$(jq -r '.start_requests[] | select(.title == "PC finding") | .execute.env.FM_HOME' "$json")" "a PropertyCompass2 finding goes to the Navigator"
  assert_equals /offices/qm "$(jq -r '.start_requests[] | select(.title == "Fleet finding") | .execute.env.FM_HOME' "$json")" "a fleet-repo finding goes to the Quartermaster"
  assert_equals 0 "$(grep -c 'fm-inbox.sh' "$TMP_ROOT/route/out/$DATE.start-requests.sh")" "and this home's hand-off holds neither"
  pass "fm-officer surgeon: start requests go to the office whose dispatch list holds the project"
}

test_nightly_area_tries_feature_labels_before_testing() {
  local home
  make_world e2earea "$LINEAR_ON"; home=$WORLD_HOME
  set_pages e2earea '[]' '[]' '{"status":"failed","findings":[
    {"key":"n1","title":"stamp duty total wrong","cause":"expected 1200","where":"tests/e2e/calculators/stamp-duty.spec.ts","classification":"regression"},
    {"key":"n2","title":"home page loads","cause":"timed out","where":"tests/e2e/smoke.spec.ts","classification":"regression"}]}'
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  assert_contains "$(grep '^issue create .*stamp duty total wrong.*--verify' "$LINEAR_LOG")" "--label calculators" "a calculators spec gets the calculators label, not testing"
  assert_contains "$(grep '^issue create .*home page loads.*--verify' "$LINEAR_LOG")" "--label testing" "a plain spec with no feature word falls back to testing"
  pass "fm-officer surgeon: a nightly E2E failure tries the feature labels before testing"
}

test_unreadable_rubric_leaves_items_to_start_later() {
  local home json
  make_world laterstart "${LINEAR_ON}rubric: $TMP_ROOT/laterstart/missing.md; "; home=$WORLD_HOME
  set_pages laterstart '[]' '[{"fp":"l1","title":"Crash on save","disposition":"new","severity":"P1"}]'
  run_surgeon "$home" >/dev/null || fail "missing rubric run"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals created "$(row "$json" sweeper l1 .filing.action)" "the high finding is filed"
  assert_equals 0 "$(jq '[.start_requests[] | select(.kind == "surgeon-finding")] | length' "$json")" "but nothing starts without a rubric"
  surgeon_registry "$home" "$TMP_ROOT/laterstart/archive" "$LINEAR_ON"
  run_surgeon_next_day "$home" laterstart >/dev/null || fail "next-day run with the rubric back"
  assert_equals PC-101 "$(jq -r '[.start_requests[] | select(.kind == "surgeon-finding")][0].issue' "$home/data/officers/surgeon/$DATE2.json")" "a later run with a good rubric starts the item"
  pass "fm-officer surgeon: an unreadable rubric marks nothing handled, so the item starts later"
}

test_reserved_classes_match_the_action_not_the_word() {
  local home json
  make_world reserved "$LINEAR_ON"; home=$WORLD_HOME
  set_pages reserved '[]' '[
    {"fp":"r1","title":"shallow copy of list mutates cache","disposition":"new","severity":"P1"},
    {"fp":"r2","title":"password hash compared with ==","disposition":"new","severity":"P1"},
    {"fp":"r3","title":"API key logged in plaintext","disposition":"new","severity":"P1"},
    {"fp":"r4","title":"Reword the wording shown to members on the pricing page","disposition":"new","severity":"P1"},
    {"fp":"r5","title":"Rotate the staging API key used by the mailer","disposition":"new","severity":"P1"},
    {"fp":"r12","title":"Rotate SendGrid API key","disposition":"new","severity":"P1"},
    {"fp":"r16","title":"SendGrid API key exposed in logs","cause":"Rotate the SendGrid API key and scrub the logs.","disposition":"new","severity":"P1"},
    {"fp":"r17","title":"[P1] Rotate the API key","disposition":"new","severity":"P1"},
    {"fp":"r6","title":"Password reset token never expires","disposition":"new","severity":"P1"},
    {"fp":"r7","title":"Reset token not invalidated after use","disposition":"new","severity":"P1"},
    {"fp":"r8","title":"Creates API key with predictable RNG","disposition":"new","severity":"P1"},
    {"fp":"r9","title":"Endpoint deletes records belonging to other users","disposition":"new","severity":"P1"},
    {"fp":"r10","title":"UpdateAsync updates rows without tenant filter","disposition":"new","severity":"P1"},
    {"fp":"r11","title":"User-facing text not HTML-encoded (XSS)","disposition":"new","severity":"P1"},
    {"fp":"r13","title":"Session revoke does not clear the token cache","disposition":"new","severity":"P1"},
    {"fp":"r14","title":"Revoke endpoint skips the token owner check","disposition":"new","severity":"P1"},
    {"fp":"r15","title":"Token revoke leaves refresh tokens valid","disposition":"new","severity":"P1"}]'
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "API key logged in plaintext|Creates API key with predictable RNG|Endpoint deletes records belonging to other users|Password reset token never expires|Reset token not invalidated after use|Revoke endpoint skips the token owner check|Session revoke does not clear the token cache|Token revoke leaves refresh tokens valid|UpdateAsync updates rows without tenant filter|User-facing text not HTML-encoded (XSS)|password hash compared with ==|shallow copy of list mutates cache" \
    "$(jq -r '[.start_requests[] | select(.kind == "surgeon-finding") | .title] | sort | join("|")' "$json")" "security and code bugs that only mention a key, a token, rows or text start"
  assert_equals "credentials credentials credentials credentials member-copy" "$(jq -r '[.held[] | .class] | sort | join(" ")' "$json")" "a member wording change and key rotations, with or without an article, are held"
  assert_equals 1 "$(jq '.asks_for_lee | length' "$json")" "with one keyed needs-decision"
  pass "fm-officer surgeon: reserved classes match the action they ask for, so real security bugs start"
}

test_one_item_gets_one_start_request_a_run() {
  local home json
  make_world samestart "${LINEAR_ON}jev: $TMP_ROOT/samestart/jev.py; "; home=$WORLD_HOME
  fake_jev "$TMP_ROOT/samestart/jev.py"
  printf 'Older report.\\nFound: 1 times (first 2026-10-01, last 2026-10-01, by surgeon)' > "$LDIR/pc9.desc"
  set_pages samestart '[]' '[
    {"fp":"m1","title":"Save crashes duplicate-me","disposition":"new","severity":"P1"},
    {"fp":"m2","title":"Save fails duplicate-me again","disposition":"new","severity":"P1"}]'
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "PC-9 PC-9" "$(row "$json" sweeper m1 .filing.issue) $(row "$json" sweeper m2 .filing.issue)" "both findings are duplicates of PC-9"
  assert_equals 1 "$(jq '[.start_requests[] | select(.kind == "surgeon-finding" and .issue == "PC-9")] | length' "$json")" "and PC-9 gets one start request"
  run_surgeon "$home" >/dev/null || fail "same-day rerun"
  assert_equals 1 "$(jq '[.start_requests[] | select(.kind == "surgeon-finding" and .issue == "PC-9")] | length' "$json")" "which a same-day rerun repeats"
  pass "fm-officer surgeon: an item gets one start request a run, however many findings map to it"
}

test_closed_search_hit_files_a_recurrence() {
  local home json
  make_world closedhit "$LINEAR_ON"; home=$WORLD_HOME
  set_pages closedhit '[]' '[{"fp":"h1","title":"Crash on save","disposition":"new","severity":"P1"}]'
  fp sweeper pc-sweeper-intake h1 > "$LDIR/exists.txt"
  echo Done > "$LDIR/state.PC-55"
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals "created PC-55" "$(row "$json" sweeper h1 '[.filing.action,.filing.recurrence_of]|join(" ")')" "with no ledger entry, a closed search hit still makes a recurrence"
  assert_equals 0 "$(grep -c '^issue update PC-55' "$LINEAR_LOG")" "the closed item is not edited"
  assert_contains "$(cat "$LDIR/bodies")" "Recurrence of PC-55 (closed as Done)." "the new item names it"
  assert_equals "RELATION PC-101 --related PC-55" "$(cat "$LDIR/relations")" "and links it as related"
  pass "fm-officer surgeon: a closed item found by fingerprint search gets a recurrence, not a plain new item"
}

# --- the visual review source: the nightly findings file, filed as defects or held for Lee ---

VSTAMP1=2026-10-23T02:10:00+00:00
VSTAMP2=2026-10-24T02:10:00+00:00

vfp() {  # <route> <rubric item>: the findings file's fingerprint, sha256 of prefix, route and item joined by newlines.
  printf '%s\n%s\n%s' visual-review-fp-v1 "$1" "$2" | sha256sum | cut -d' ' -f1
}

# write_visual <path> <stamp>: a version 2 file with a deal-finder defect seen on two viewports (one screenshot on disk,
# one not) and a jargon finding on /portfolio.
write_visual() {
  local fpa fpb
  fpa=$(vfp /deal-finder contradictory-numbers); fpb=$(vfp /portfolio jargon)
  jq -n --arg stamp "$2" --arg fpa "$fpa" --arg fpb "$fpb" '
    def f($route; $vp; $item; $sev; $file; $fp; $class):
      {key: ($route + "|" + $vp + "|default"), route: $route, viewport: $vp, state: "default", test: "t", file: $file, reason: "new",
       rubric_item: $item, evidence: "Net yield 9% and 4%", region: "summary", severity: $sev,
       screenshot: $file, fingerprint: $fp, class: $class};
    {schema_version: 2, run: {date: $stamp, origin: "https://pc-staging-web.azurewebsites.net", images_reviewed: 3}, errors: [],
     findings: [f("/deal-finder"; "desktop"; "contradictory-numbers"; "high"; "shots/a-desktop.png"; $fpa; "defect"),
                f("/deal-finder"; "mobile"; "contradictory-numbers"; "medium"; "shots/a-mobile.png"; $fpa; "defect"),
                f("/portfolio"; "desktop"; "jargon"; "high"; "shots/b-desktop.png"; $fpb; "held-for-lee")]}' > "$1"
}

# make_visual_world <name> [registry extras]: a world whose app pages hold nothing, so the visual file is the only intake.
make_visual_world() {
  local name=$1 dir
  dir="$TMP_ROOT/$name-visual"
  mkdir -p "$dir/captures/shots"
  : > "$dir/captures/shots/a-desktop.png"
  write_visual "$dir/findings.json" "$VSTAMP1"
  make_world "$name" "${LINEAR_ON}visual-findings: $dir/findings.json; visual-captures: $dir/captures; ${2:-}"
  printf 'Bug\nscheduled-review\ndeal-finder\nui-ux\ntriage\n' > "$LDIR/labels.txt"
  set_pages "$name" '[]' '[]'
  VISUAL_DIR=$dir
  # A fake linear-attach: logs its arguments to $LDIR/attach.log and exits with the code in $LDIR/attach.exit (default 0).
  cat > "$FAKEBIN/linear-attach" <<SH
#!/bin/sh
echo "\$*" >> "$LDIR/attach.log"
exit \$(cat "$LDIR/attach.exit" 2>/dev/null || echo 0)
SH
  chmod +x "$FAKEBIN/linear-attach"
  : > "$LDIR/attach.log"
}

test_visual_defects_are_filed_once_and_wording_is_held() {
  local home json bodies out hex
  make_visual_world vis; home=$WORLD_HOME
  out=$(run_surgeon "$home") || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  hex=$(vfp /deal-finder contradictory-numbers)
  assert_equals 1 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "two viewports of one defect are one item, and the held finding is no item"
  assert_contains "$(grep '^issue create .*--verify' "$LINEAR_LOG")" "--label Bug --label scheduled-review --label deal-finder" "one Type, the Source and the route's area label"
  assert_contains "$(grep '^issue create .*--verify' "$LINEAR_LOG")" "--priority 2" "the file's severity high is Linear priority High"
  bodies=$(cat "$LDIR/bodies")
  assert_contains "$bodies" "visual-review-fp:$hex" "the item carries the visual review's own marker"
  assert_contains "$bodies" "surgeon-fp:$(fp visual visual-review "$hex")" "and the Surgeon's fingerprint, built from it"
  assert_contains "$bodies" "Screenshot: $VISUAL_DIR/captures/shots/a-desktop.png" "a screenshot that is on disk is named by its real path"
  assert_contains "$bodies" "Screenshot: shots/a-mobile.png (not found under $VISUAL_DIR/captures)" "one that is not is named with what was looked for"
  assert_not_contains "$bodies" "/portfolio" "the held finding is in no item"
  assert_equals "PC-101 $VISUAL_DIR/captures/shots/a-desktop.png --verify" "$(cat "$LDIR/attach.log")" "the screenshot on disk is attached to the new item, once"
  assert_contains "$out" "Coverage gap: screenshot not attached to PC-101: shots/a-mobile.png (not found under $VISUAL_DIR/captures)" "a screenshot file that is missing is a named gap"
  assert_not_contains "$out" "linear-attach" "a clean attach names no linear-attach gap"
  assert_equals "surgeon-visual-held-$DATE" "$(jq -r '.asks_for_lee[0].key' "$json")" "the held finding is one keyed needs-decision"
  assert_equals 1 "$(jq '.asks_for_lee | length' "$json")" "and only one"
  assert_contains "$(jq -r '.asks_for_lee[0].line' "$json")" "/portfolio (jargon)" "the line names the route and the rubric item"
  assert_contains "$(cat "$home/data/officers/surgeon/$DATE.md")" "needs-decision [key=surgeon-visual-held-$DATE]" "and the digest carries it"
  assert_equals "needs-decision low" "$(row "$json" visual "$(vfp /portfolio jargon)" '[.class,.severity]|join(" ")')" "a held finding is low, so it never raises the high-severity wake"
  assert_equals "" "$(row "$json" visual "$(vfp /portfolio jargon)" '.filing // "" | tostring | select(. != "")')" "and has no filing"
  assert_equals 0 "$(jq '[.start_requests[] | select(.source == "visual")] | length' "$json")" "a visual defect is filed and never started"
  : > "$LINEAR_LOG"
  run_surgeon "$home" >/dev/null || fail "same-day rerun"
  assert_equals 0 "$(grep -c '^issue create\|^issue update\|^issue comment' "$LINEAR_LOG")" "a same-day rerun writes nothing"
  assert_equals 1 "$(wc -l < "$LDIR/attach.log")" "and attaches nothing again"
  assert_equals "surgeon-visual-held-$DATE" "$(jq -r '.asks_for_lee[0].key' "$json")" "and asks the same thing"
  pass "fm-officer surgeon: a visual defect is one item, wording is held for Lee and nothing starts"
}

test_visual_repeat_bumps_the_found_line_and_an_unchanged_file_adds_nothing() {
  local home json out
  make_visual_world visrep; home=$WORLD_HOME
  run_surgeon "$home" >/dev/null || fail "first run"
  : > "$LINEAR_LOG"
  write_visual "$VISUAL_DIR/findings.json" "$VSTAMP2"
  run_surgeon_next_day "$home" visrep >/dev/null || fail "next night's run"
  json="$home/data/officers/surgeon/$DATE2.json"
  assert_equals 0 "$(grep -c '^issue create' "$LINEAR_LOG")" "the same fingerprint is not created twice"
  assert_equals 1 "$(grep -c '^issue update PC-101 .*--verify' "$LINEAR_LOG")" "it bumps the existing item once"
  assert_equals 1 "$(wc -l < "$LDIR/attach.log")" "a nightly re-find attaches no new screenshot"
  assert_contains "$(cat "$LDIR/updates")" "Found: 2 times (first $DATE2, last $DATE2, by surgeon)" "the one Found line says it was seen again"
  assert_equals 0 "$(jq '.asks_for_lee | length' "$json")" "a held finding already put to Lee is not asked again"
  : > "$LINEAR_LOG"
  out=$(run_surgeon_next_day "$home" visrep "$DATE3" 2) || fail "a night with no new visual review"
  assert_contains "$out" "Coverage gap: visual findings file $VISUAL_DIR/findings.json is unchanged since the review run of $VSTAMP2" "the same file again is a named gap"
  assert_equals 0 "$(grep -c '^issue update\|^issue comment\|^issue create' "$LINEAR_LOG")" "and counts as no new sighting"
  pass "fm-officer surgeon: a repeat bumps the Found line, an unchanged file adds nothing"
}

test_visual_held_only_run_makes_no_linear_call() {
  local home json
  make_visual_world visheld; home=$WORLD_HOME
  jq '.findings |= map(select(.rubric_item == "jargon"))' "$VISUAL_DIR/findings.json" > "$VISUAL_DIR/f.json" && mv "$VISUAL_DIR/f.json" "$VISUAL_DIR/findings.json"
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  [ ! -s "$LINEAR_LOG" ] || fail "a held finding is never a Linear item, so there is no Linear call at all: $(cat "$LINEAR_LOG")"
  assert_contains "$(jq -r '.asks_for_lee[0].line' "$json")" "1 visual-review finding(s) on wording or product held for Lee, not filed and never started" "it goes up as the decision"
  pass "fm-officer surgeon: a held-only visual run is one decision and no Linear call"
}

test_visual_file_problems_are_named_gaps() {
  local home out
  make_visual_world visbad; home=$WORLD_HOME
  rm "$VISUAL_DIR/findings.json"
  out=$(run_surgeon "$home") || fail "a missing file must not fail the run"
  assert_contains "$out" "Coverage gap: visual findings file $VISUAL_DIR/findings.json not found" "a missing file is a gap"
  printf '%s\n' '{not json' > "$VISUAL_DIR/findings.json"
  out=$(run_surgeon "$home") || fail "an unreadable file must not fail the run"
  assert_contains "$out" "Coverage gap: visual findings file $VISUAL_DIR/findings.json unreadable" "an unreadable file is a gap"
  printf '%s\n' '{"schema_version": 3, "findings": []}' > "$VISUAL_DIR/findings.json"
  out=$(run_surgeon "$home") || fail "another schema must not fail the run"
  assert_contains "$out" "has schema_version 3" "a schema this code does not read is a gap"
  write_visual "$VISUAL_DIR/findings.json" "$VSTAMP1"
  jq '.schema_version = 1' "$VISUAL_DIR/findings.json" > "$VISUAL_DIR/f.json" && mv "$VISUAL_DIR/f.json" "$VISUAL_DIR/findings.json"
  out=$(run_surgeon "$home") || fail "a version 1 file must not fail the run"
  assert_contains "$out" "has schema_version 1 and a list of findings; only a version 2 file with a findings list is read" "a version 1 file is a gap, not read"
  [ ! -s "$LINEAR_LOG" ] || fail "no Linear call comes from a file that could not be read"
  pass "fm-officer surgeon: a missing, unreadable, foreign or version 1 visual findings file is a named coverage gap"
}

test_visual_incomplete_review_is_a_named_gap() {
  local home out
  make_visual_world visinc; home=$WORLD_HOME
  jq '.findings = [] | .errors = [{image: "shots/a-desktop.png", error: "model call failed"}, {image: "shots/a-mobile.png", error: "timeout"}]
      | .run.images_failed = 2 | .run.images_deferred = 1 | .run.malformed_findings_dropped = 0' \
    "$VISUAL_DIR/findings.json" > "$VISUAL_DIR/f.json" && mv "$VISUAL_DIR/f.json" "$VISUAL_DIR/findings.json"
  out=$(run_surgeon "$home") || fail "a review with errors must not fail the run"
  assert_contains "$out" "Coverage gap: visual findings file $VISUAL_DIR/findings.json reports 2 review error(s), so its findings are incomplete" "a failed review is not a clean night"
  assert_contains "$out" "Coverage gap: visual findings file $VISUAL_DIR/findings.json: run.images_failed is 2" "failed images are named"
  assert_contains "$out" "Coverage gap: visual findings file $VISUAL_DIR/findings.json: run.images_deferred is 1" "deferred images are named"
  assert_not_contains "$out" "malformed_findings_dropped" "a zero count is no gap"
  jq '.errors = [] | .run.images_failed = 0 | .run.images_deferred = 0
      | .findings = [{route: "/deal-finder", rubric_item: "contradictory-numbers", class: "defect", severity: "high", screenshot: "shots/a-desktop.png"}]' \
    "$VISUAL_DIR/findings.json" > "$VISUAL_DIR/f.json" && mv "$VISUAL_DIR/f.json" "$VISUAL_DIR/findings.json"
  out=$(run_surgeon "$home") || fail "a row without a fingerprint must not fail the run"
  assert_contains "$out" "1 finding(s) without a route, rubric item and 64-hex fingerprint skipped" "a row with no fingerprint is skipped and named"
  assert_not_contains "$out" "review error" "an empty errors list is no gap"
  [ ! -s "$LINEAR_LOG" ] || fail "nothing is filed from an incomplete review or a row without a fingerprint: $(cat "$LINEAR_LOG")"
  pass "fm-officer surgeon: an incomplete visual review and a row with no fingerprint are named coverage gaps"
}

test_visual_dry_run_writes_nothing_to_linear() {
  local home json
  make_visual_world visdry; home=$WORLD_HOME
  sed -i 's/writes: linear; //' "$home/data/officers.md"
  run_surgeon "$home" >/dev/null || fail "surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  [ ! -s "$LINEAR_LOG" ] || fail "writes: none makes no Linear call: $(cat "$LINEAR_LOG")"
  [ ! -s "$LDIR/attach.log" ] || fail "writes: none uploads nothing: $(cat "$LDIR/attach.log")"
  assert_equals "real" "$(row "$json" visual "$(vfp /deal-finder contradictory-numbers)" .class)" "the defect is still read and shown in the digest"
  assert_equals "surgeon-visual-held-$DATE" "$(jq -r '.asks_for_lee[0].key' "$json")" "and the held finding still goes up"
  pass "fm-officer surgeon: without writes: linear the visual review reaches the digest and nothing reaches Linear"
}

test_visual_attach_failures_are_named_gaps() {
  local home out
  make_visual_world visatt; home=$WORLD_HOME
  echo 75 > "$LDIR/attach.exit"
  out=$(run_surgeon "$home") || fail "a rate limited attach must not fail the run"
  assert_contains "$out" "Coverage gap: screenshots not attached: linear-attach was rate limited at PC-101" "exit 75 is a named gap"
  assert_equals 1 "$(wc -l < "$LDIR/attach.log")" "and stops attaching for the run"
  make_visual_world visatt3; home=$WORLD_HOME
  echo 3 > "$LDIR/attach.exit"
  out=$(run_surgeon "$home") || fail "an attach refused for upload rights must not fail the run"
  assert_contains "$out" "Coverage gap: screenshots not attached: the Linear app token lacks upload rights (linear-attach exit 3); Lee's call" "exit 3 is named and left to Lee"
  make_visual_world visatt1; home=$WORLD_HOME
  echo 1 > "$LDIR/attach.exit"
  out=$(run_surgeon "$home") || fail "a refused attach must not fail the run"
  assert_contains "$out" "Coverage gap: screenshot not attached to PC-101: linear-attach exit 1 for $VISUAL_DIR/captures/shots/a-desktop.png" "any other failure names the item and file"
  make_visual_world vismiss; home=$WORLD_HOME
  rm "$FAKEBIN/linear-attach"
  out=$(PATH="$FAKEBIN:/usr/bin:/bin" FM_OFFICER_NOW="$NOW" FM_HOME="$home" "$OFFICER" run surgeon --date "$DATE") || fail "a missing linear-attach must not fail the run"
  assert_contains "$out" "Coverage gap: screenshots not attached: linear-attach is not available" "a missing linear-attach is a named gap"
  assert_contains "$(cat "$LDIR/bodies")" "Screenshot: $VISUAL_DIR/captures/shots/a-desktop.png" "and the item still names the screenshot"
  pass "fm-officer surgeon: each screenshot attach failure is its own named coverage gap"
}

test_visual_attach_left_pending_is_retried_next_run_and_cleared() {
  local home out state
  make_visual_world visretry; home=$WORLD_HOME
  state="$home/data/officers/surgeon/review-state.json"
  echo 75 > "$LDIR/attach.exit"
  out=$(run_surgeon "$home") || fail "a rate limited attach must not fail the run"
  assert_contains "$out" "Coverage gap: 1 screenshot(s) not attached yet; the next run retries them" "the unattached screenshot is counted and said to be retried"
  assert_equals "PC-101 $VISUAL_DIR/captures/shots/a-desktop.png $DATE" "$(jq -r '.pending_attach[] | [.issue, .file, .first] | join(" ")' "$state")" "and kept pending in the lane's state"
  echo 0 > "$LDIR/attach.exit"
  write_visual "$VISUAL_DIR/findings.json" "$VSTAMP2"
  out=$(run_surgeon_next_day "$home" visretry) || fail "next night's run"
  assert_equals 2 "$(wc -l < "$LDIR/attach.log")" "the next run retries the pending screenshot"
  assert_equals "PC-101 $VISUAL_DIR/captures/shots/a-desktop.png --verify" "$(tail -n 1 "$LDIR/attach.log")" "on the item it was filed as"
  assert_not_contains "$out" "not attached yet" "a successful retry leaves nothing pending"
  assert_equals null "$(jq .pending_attach "$state")" "and clears the state"
  run_surgeon_next_day "$home" visretry "$DATE3" 2 >/dev/null || fail "a third night"
  assert_equals 2 "$(wc -l < "$LDIR/attach.log")" "an attached screenshot is never attached again"
  pass "fm-officer surgeon: a screenshot left unattached is retried next run and cleared once attached"
}

test_visual_upload_rights_refusal_is_reported_every_run() {
  local home out
  make_visual_world visrights; home=$WORLD_HOME
  echo 3 > "$LDIR/attach.exit"
  run_surgeon "$home" >/dev/null || fail "first run"
  out=$(run_surgeon_next_day "$home" visrights) || fail "next night's run"
  assert_equals 2 "$(wc -l < "$LDIR/attach.log")" "exit 3 stays pending and is tried again"
  assert_contains "$out" "Coverage gap: screenshots not attached: the Linear app token lacks upload rights (linear-attach exit 3); Lee's call" "and is reported again until Lee changes the token"
  pass "fm-officer surgeon: an upload-rights refusal stays pending and is reported every run"
}

test_visual_pending_attach_is_abandoned_after_seven_days() {
  local home out state
  make_visual_world visold; home=$WORLD_HOME
  state="$home/data/officers/surgeon/review-state.json"
  echo 75 > "$LDIR/attach.exit"
  run_surgeon "$home" >/dev/null || fail "first run"
  out=$(run_surgeon_next_day "$home" visold 2026-10-29 6) || fail "six days on"
  assert_equals 2 "$(wc -l < "$LDIR/attach.log")" "six days on it is still retried"
  assert_not_contains "$out" "abandoned" "and not yet abandoned"
  out=$(run_surgeon_next_day "$home" visold 2026-10-30 7) || fail "seven days on"
  assert_equals 2 "$(wc -l < "$LDIR/attach.log")" "seven days on it is not tried again"
  assert_contains "$out" "Coverage gap: screenshot abandoned for PC-101 after 7 days unattached: $VISUAL_DIR/captures/shots/a-desktop.png" "it is dropped with a named gap"
  assert_equals null "$(jq .pending_attach "$state")" "and leaves the state"
  pass "fm-officer surgeon: a screenshot still unattached after 7 days is abandoned with a named gap"
}

test_visual_attach_stops_at_the_call_budget() {
  local home out
  make_visual_world visbudget "max-linear-calls: 5; "; home=$WORLD_HOME
  out=$(run_surgeon "$home") || fail "a spent budget must not fail the run"
  assert_equals 1 "$(grep -c '^issue create .*--verify' "$LINEAR_LOG")" "the item is still filed within the budget"
  [ ! -s "$LDIR/attach.log" ] || fail "an attach past the budget is not made: $(cat "$LDIR/attach.log")"
  assert_contains "$out" "Coverage gap: screenshots not attached: Linear call budget of 5 reached" "the budget stop is named"
  assert_contains "$out" "Coverage gap: 1 screenshot(s) not attached yet; the next run retries them" "and the screenshot is left for the next run"
  pass "fm-officer surgeon: each attach counts against the Linear call budget"
}

test_visual_recurrence_of_a_closed_item_gets_its_screenshot() {
  local home json
  make_visual_world visrecur; home=$WORLD_HOME
  run_surgeon "$home" >/dev/null || fail "first run"
  echo Done > "$LDIR/state.PC-101"
  write_visual "$VISUAL_DIR/findings.json" "$VSTAMP2"
  run_surgeon_next_day "$home" visrecur >/dev/null || fail "next night's run after the item was closed"
  json="$home/data/officers/surgeon/$DATE2.json"
  assert_equals "created PC-102 PC-101" "$(row "$json" visual "$(vfp /deal-finder contradictory-numbers)" '[.filing.action,.filing.issue,.filing.recurrence_of]|join(" ")')" "a closed item's defect files a recurrence"
  assert_equals "PC-102 $VISUAL_DIR/captures/shots/a-desktop.png --verify" "$(tail -n 1 "$LDIR/attach.log")" "and the recurrence gets the screenshot attached"
  assert_equals 2 "$(wc -l < "$LDIR/attach.log")" "once"
  pass "fm-officer surgeon: a recurrence of a closed visual item gets its screenshot attached"
}

test_visual_registry_fields_are_validated() {
  local home out
  make_world visreg; home=$WORLD_HOME
  surgeon_registry "$home" "$TMP_ROOT/visreg/archive" "visual-findings: relative/findings.json; "
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$OFFICER" run surgeon --date "$DATE" 2>&1) && fail "a relative visual-findings must be refused"
  assert_contains "$out" "visual-findings must be an absolute path" "the refusal names the field"
  surgeon_registry "$home" "$TMP_ROOT/visreg/archive" "visual-captures: /srv/captures; "
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$OFFICER" run surgeon --date "$DATE" 2>&1) && fail "captures without findings must be refused"
  assert_contains "$out" "visual-captures needs visual-findings" "the captures need a findings file"
  pass "fm-officer surgeon: the visual registry fields are validated"
}

test_run_host_joins_sessions_through_the_home_mirror() {
  local home json w=$TMP_ROOT/runhost
  make_world runhost; home=$WORLD_HOME
  python3 -I - "$w/spec.json" "$home" <<'PY'
import json, sys
path, home = sys.argv[1:3]
brief = lambda t: "FIRSTMATE_OP: v1 launch-brief\nYour steering inbox is `%s/state/%s.inbox`." % (home, t)
msg = {"file_path": home + "/state/operational-inbox/1.msg"}
json.dump({"sessions": [{"machine": "alpha", "id": "s-" + t, "first_prompt": ": Firstmate operational input waiting: read 'x'",
                         "calls": [["Read", msg, brief(t), False]]} for t in ("t-merged", "t-status", "t-report")]}, open(path, "w"))
PY
  officer_archive "$w/archive" "$DATE" "$w/spec.json"
  printf 'kind=ship\nworktree=/work/t-merged\n' > "$home/state/t-merged.meta"
  printf 'kind=ship\nworktree=/work/t-status\n' > "$home/state/t-status.meta"
  printf 'kind=scout\nworktree=/work/t-report\n' > "$home/state/t-report.meta"
  printf '%s\n' '{"v":1,"ts":5,"event":"task.merged","task":"t-merged","via":"local"}' > "$home/state/fleet-ledger.jsonl"
  printf 'working [at=1]: started\nfailed [at=2]: broke\n' > "$home/state/t-status.status"
  mkdir -p "$home/data/t-report" && printf 'report\n' > "$home/data/t-report/report.md"
  cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
while [ "${1:-}" = -o ]; do shift 2; done
shift
HOME="$FAKE_HOST_HOME" exec bash -c "$*"
SH
  chmod +x "$FAKEBIN/ssh"
  mkdir -p "$w/hosthome"
  run_surgeon "$home" >/dev/null || fail "the local surgeon run must succeed"
  json="$home/data/officers/surgeon/$DATE.json"
  assert_equals '{"failed":1,"merged":1,"reported":1}' "$(jq -c '.. | .outcomes? // empty' "$json" | head -n 1)" "the local run resolves all three outcomes"
  mv "$home/data/officers/surgeon" "$w/lane.local"
  sed -i "s|model: none; added|run-host: somehost; run-host-code: $ROOT; model: none; added|" "$home/data/officers.md"
  # The pass reads the mirror only, never the home's own files, so equal bytes show the mirror holds what the join needs.
  FAKE_HOST_HOME="$w/hosthome" run_surgeon "$home" >/dev/null || fail "the run-host surgeon run must succeed"
  diff -r --exclude=.run.err "$w/lane.local" "$home/data/officers/surgeon" >/dev/null \
    || fail "the lane must be byte-identical to a local run's: $(diff -r --exclude=.run.err "$w/lane.local" "$home/data/officers/surgeon" | head -5)"
  pass "fm-officer surgeon: a run-host pass joins sessions through the mirrored home records and leaves the local lane's bytes"
}

test_preflight_checks_what_the_surgeon_needs_on_the_run_host() {
  local out w=$TMP_ROOT/preflight
  mkdir -p "$w/hosthome"
  make_world preflight "${LINEAR_ON}jev: $w/jev.py; run-host: somehost; run-host-code: $ROOT; "
  cat > "$FAKEBIN/ssh" <<SH
#!/usr/bin/env bash
while [ "\${1:-}" = -o ]; do shift 2; done
shift
HOME="$w/hosthome" exec bash -c "\$*"
SH
  chmod +x "$FAKEBIN/ssh"
  : > "$w/jev.py"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$WORLD_HOME" "$OFFICER" preflight surgeon 2>&1) || fail "every check passes on a ready host: $out"
  assert_contains "$out" "ok code: somehost:$ROOT is at this home's commit" "the host checkout is at this home's commit"
  assert_contains "$out" "ok linear: linear-axi reads team PC" "linear-axi works on the host"
  assert_contains "$out" "ok jev: $w/jev.py" "a jev: field is checked as written"
  assert_contains "$out" "ok app: the fleet app answers /api/runs" "the host reaches the fleet app"
  assert_contains "$out" "ok repo: git ls-remote reads staging from" "the host reads the staging repo"
  assert_not_contains "$(cat "$w/curl.calls")" "-X" "the app is read with GET only"
  assert_equals "label list --team PC --limit 1 --output json" "$(cat "$LINEAR_LOG")" "the only Linear call is a read"
  assert_absent "$WORLD_HOME/data/officers/surgeon" "preflight writes no lane"
  assert_absent "$w/hosthome/fm-scratch" "preflight writes no scratch on the host"
  touch "$LDIR/labels.fail" "$w/unreachable"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$WORLD_HOME" "$OFFICER" preflight surgeon 2>&1) && fail "a failing check must exit non-zero: $out"
  assert_contains "$out" "FAIL linear: linear-axi cannot read team PC" "a linear-axi that cannot read fails"
  assert_contains "$out" "FAIL app: the fleet app's /api/runs gave HTTP" "an unreachable fleet app fails"
  assert_contains "$out" "ok repo:" "the other checks still run"
  pass "fm-officer surgeon: preflight checks the run host's Linear, jev, fleet app and staging repo and fails on any failed check"
}

test_registry_rules
test_classification_and_severity
test_staging_tip_rates_the_night
test_rerun_is_byte_identical
test_files_real_untracked_findings
test_fingerprint_search_skips_create
test_max_creates_cap
test_failed_verify_is_not_retried
test_failed_fallback_search_keeps_the_verify_error
test_created_item_with_verify_mismatch_is_ledgered
test_verify_mismatch_waits_for_search_to_catch_up
test_label_lookup_failure_reports_instead_of_filing
test_rate_limit_stops_linear_for_the_run_and_later_runs
test_unreachable_app_is_a_coverage_gap
test_register_surgeon_and_retire_triage_keeps_findings
test_area_label_comes_from_the_finding
test_low_review_findings_are_clustered_and_ticked_off
test_duplicates_bump_the_found_count_through_local_jev
test_local_jev_unreachable_files_by_fingerprint_only
test_production_environment_bumps_severity_one_step
test_invalid_nightly_e2e_is_a_top_severity_promotion_blocker
test_start_requests_follow_the_rubric_and_hold_reserved_classes
test_call_budget_stops_the_run_and_the_next_run_continues
test_keyless_fingerprint_ignores_run_to_run_digits
test_patterns_are_deduped_handed_on_and_proposed_as_rules
test_cluster_split_and_fold_constants
test_start_requests_route_by_project_to_the_owning_office
test_found_count_lifts_a_duplicate_into_the_start_decision
test_a_finding_that_keeps_coming_back_stops_at_three_starts
test_start_home_reaches_the_surgeon_through_the_registry
test_nightly_area_tries_feature_labels_before_testing
test_unreadable_rubric_leaves_items_to_start_later
test_reserved_classes_match_the_action_not_the_word
test_one_item_gets_one_start_request_a_run
test_closed_search_hit_files_a_recurrence
test_visual_defects_are_filed_once_and_wording_is_held
test_visual_repeat_bumps_the_found_line_and_an_unchanged_file_adds_nothing
test_visual_held_only_run_makes_no_linear_call
test_visual_file_problems_are_named_gaps
test_visual_incomplete_review_is_a_named_gap
test_visual_dry_run_writes_nothing_to_linear
test_visual_attach_failures_are_named_gaps
test_visual_attach_left_pending_is_retried_next_run_and_cleared
test_visual_upload_rights_refusal_is_reported_every_run
test_visual_pending_attach_is_abandoned_after_seven_days
test_visual_attach_stops_at_the_call_budget
test_visual_recurrence_of_a_closed_item_gets_its_screenshot
test_visual_registry_fields_are_validated
test_run_host_joins_sessions_through_the_home_mirror
test_preflight_checks_what_the_surgeon_needs_on_the_run_host
