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
# surgeon / retire triage keeping triage's findings.
set -u

# shellcheck source=tests/officer-helpers.sh
. "{run-worktree}/tests/officer-helpers.sh"

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
    {id: "f3", severity: "medium", file: "C.cs", summary: "naming"},
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
    if grep -qF -- "\${3#surgeon-fp:}" "\$d/exists.txt" 2>/dev/null && [ "\$lag" -gt 0 ]; then
      echo \$((lag - 1)) > "\$d/search.lag"
      echo '{"ok":true,"data":{"issues":[{"identifier":"PC-9"}]}}'
    elif grep -qF -- "\${3#surgeon-fp:}" "\$d/exists.txt" 2>/dev/null; then
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
      title=''; desc="Filed earlier. surgeon-fp:\$(tr -d '\n' < "\$d/exists.txt")"
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

EV=~/.no-mistakes/evidence/01M6PFSRN3R5JE2483Q05860JE
make_world vol "${LINEAR_ON}jev: $TMP_ROOT/vol/jev.py; "; home=$WORLD_HOME
fake_jev "$TMP_ROOT/vol/jev.py"
printf "ci-cd\nbilling\nauthentication\napi\nui-ux\nmaps\nnotifications\ningestion\nperformance\n" >> "$LDIR/labels.txt"
comps=(Api/Controllers Api/Services Web/src/pages Web/src/components infra/bicep Calc/Engine Data/Migrations Auth/Handlers Billing/Stripe Jobs/Workers Shared/Utils Reports/Pdf Search/Index Mail/Templates Geo/Lookup Admin/Ui Tests/Helpers Api/Dto Web/src/hooks Data/Repos)
review=$(jq -n --argjson c "$(printf '%s\n' "${comps[@]}" | jq -R . | jq -s .)" '
  [range(0;454) | {id: "L\(.)", severity: "medium", file: "\($c[. % 20])/f\(. % 7).cs", summary: "low finding number \(.)"}]
  + [range(0;19) | {id: "M\(.)", severity: "high", file: "\($c[. % 20])/m\(.).cs", summary: "medium finding \(.)"}]
  + [{id: "H1", severity: "critical", file: "Api/Services/Order.cs", summary: "SQL built from user input in order search"}]')
bugs='[
 {"fp":"s1","title":"Crash on save","disposition":"new","severity":"P1"},
 {"fp":"s2","title":"Stripe payment fails for annual plan","disposition":"new","severity":"P1"},
 {"fp":"s3","title":"Checkout total wrong","disposition":"new","severity":"P3","environment":"production"},
 {"title":"Map tile 404 at 51.2,0.1 (run 8812)","where":"Web/src/map.ts","disposition":"new","severity":"P2"}]'
set_pages vol "$review" "$bugs" '{"status":"invalid","reason":"Playwright account reached its limit","findings":[]}'
out=$(run_surgeon "$home"); rc=$?
echo "rc=$rc"
J="$home/data/officers/surgeon/$DATE.json"; M="$home/data/officers/surgeon/$DATE.md"
cp "$J" "$EV/volume-run2-digest.json"; cp "$M" "$EV/volume-run2-digest.md"; cp "$LINEAR_LOG" "$EV/volume-run2-linear-calls.log"
printf '%s\n' "$out" > "$EV/volume-run2-stdout.txt"
echo "creates verified: $(grep -c '^issue create .*--verify' "$LINEAR_LOG")"
echo "total linear calls logged: $(wc -l < "$LINEAR_LOG")"; jq '{linear_calls, linear_call_budget, burn_down}' "$J"
echo "review filing actions:"; jq -r '[.findings[] | select(.source=="review") | .filing.action // "NONE"] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' "$J"
echo "unfiled real findings:"; jq '[.findings[] | select(.class=="real" and (.filing.action // "") == "" )] | length' "$J"
echo "area labels used:"; grep '^issue create .*--verify' "$LINEAR_LOG" | grep -o -- '--label [^ ]*' | sort | uniq -c
echo "invalid e2e:"; jq -c '.findings[] | select(.key=="e2e-invalid") | {class,severity,filing}' "$J"; grep '^issue create .*promotion blocked.*--verify' "$LINEAR_LOG" | grep -o -- '--priority [0-9]'
echo "production bump:"; jq -c '.findings[] | select(.key=="s3") | {severity, title}' "$J"
echo "keyless:"; jq -c '.findings[] | select(.source=="sweeper" and (.title|test("Map tile"))) | {key, fingerprint, filing}' "$J"
echo "starts:"; jq -c '.start_requests[] | {kind,title}' "$J"
echo "held:"; jq -c '.held[] | {class,title}' "$J"; jq -c '.asks_for_lee' "$J"
# day 2: rerun keyless with different digits (should dedupe), plus jev duplicate
: > "$LINEAR_LOG"
bugs2='[{"title":"Map tile 404 at 52.9,1.4 (run 9001)","where":"Web/src/map.ts","disposition":"new","severity":"P2"},
 {"fp":"s9","title":"duplicate-me crash on save","disposition":"new","severity":"P2"}]'
set_pages vol "$review" "$bugs2" '{"status":"invalid","reason":"Playwright account reached its limit","findings":[]}'
out2=$(run_surgeon_next_day "$home" vol); echo "day2 rc=$?"
J2="$home/data/officers/surgeon/$DATE2.json"
cp "$J2" "$EV/day2b-digest.json"; cp "$home/data/officers/surgeon/$DATE2.md" "$EV/day2b-digest.md"; cp "$LINEAR_LOG" "$EV/day2b-linear-calls.log"
echo "day2 creates: $(grep -c '^issue create .*--verify' "$LINEAR_LOG")  updates: $(grep -c '^issue update .*--verify' "$LINEAR_LOG")"
jq -c '.findings[] | select(.source=="sweeper") | {title, filing}' "$J2"
grep -h 'Found:' "$LDIR/updates" | sort | uniq -c | head
echo "--- Found lines in day-1 bodies:"; grep -o 'Found: [^)]*)' "$LDIR/bodies" | sort | uniq -c
echo "--- day-2 update sample:"; grep -m3 -B1 'Found: 2' "$LDIR/updates"
echo "--- found.json sample:"; jq -c 'to_entries[:2]' "$home/data/officers/surgeon/found.json"
echo "--- comments:"; cat "$LDIR/comments" 2>/dev/null | sort | uniq -c | sort -rn | head -3
