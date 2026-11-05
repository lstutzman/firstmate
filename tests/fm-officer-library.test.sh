#!/usr/bin/env bash
# Behavior tests for the library officer, driven through bin/fm-officer.sh run
# with librarian-audit run folders of the fleet-app job's documented shape.
#
# Covers: each bucket (needs Lee, safe to ship, code work, on hold) and the
# run's decisions for Lee, the newest dated run chosen and a moved-aside one
# skipped, report-once fingerprints across days, byte-identical re-runs,
# coverage gaps (no run folder, a missing findings file, a partial outcome, an
# old audit) that never fail the run, and lane-only writes.
set -u

# shellcheck source=tests/officer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/officer-helpers.sh"

OFFICER="$ROOT/bin/fm-officer.sh"
TMP_ROOT=$(fm_test_tmproot fm-officer-library)
DATE=2026-11-01
NOW=1793871000 # 2026-11-05T09:30:00Z

finding() {  # <kind> <path> <title> <disposition> [severity]
  printf '{"kind": "%s", "severity": "%s", "title": "%s", "path": "%s", "evidence": "read it", "disposition": "%s"}' \
    "$1" "${5:-low}" "$3" "$2" "$4"
}

write_run() {  # <dir> <outcome> <decisions>
  mkdir -p "$1"
  printf '{"job": "librarian-audit", "run_id": "x", "outcome": "%s", "summary": "s", "counts": {"findings": 7, "high": 1, "shortcut_debt": 0, "unneeded_code": 1, "paths": 10, "gaps": 0, "decisions": %d, "cost_usd": 2.5}, "items": [], "log_ref": "r"}\n' \
    "$2" "$3" > "$1/result.json"
  {
    printf '['
    finding readme README.md "README undercounts the rules" "Propose changing the count to 29."; printf ','
    finding stack-drift package.json "TypeScript aliases" "Make sure tech-stack.md names both compilers."; printf ','
    finding conflict docs/adr/0003.md "ADR points at the retired ledger" "Propose a dated successor note." high; printf ','
    finding misplaced spec/loose.md "Loose spec" "Propose moving it once its owner agrees."; printf ','
    finding readme .claude/skills/x/SKILL.md "Skill README stale" "Propose a fix."; printf ','
    finding cruft scripts/old.sh "Old script" "Check what reads it, then propose deletion."; printf ','
    finding unneeded-code src/A.cs "Duplicate figure" "Merge into one property." medium; printf ','
    finding stack-drift Directory.Packages.props "Mixed patch levels" "Record the versions. Alignment needs its own upgrade brief."; printf ','
    finding misplaced scripts/ops/brief.md "Brief among scripts" "Unresolved. Read both next run; propose docs/runbooks."; printf ','
    finding other . "Partial inventory" "Report the assessment as partial."
    printf ']\n'
  } > "$1/findings.json"
}

make_world() {  # <name>: sets HOME_DIR and RUNS
  HOME_DIR="$TMP_ROOT/$1/home"
  RUNS="$TMP_ROOT/$1/runs"
  officer_home "$HOME_DIR"
  write_run "$RUNS/2026-10-24" ok 2
  write_run "$RUNS/2026-10-31" ok 5
  mkdir -p "$RUNS/2026-11-01.stale-abc"
  printf -- '- library - Judges the weekly librarian audit (role: library; cadence: daily 11:30; audit: %s; model: none; added 2026-11-05)\n' \
    "$RUNS" > "$HOME_DIR/data/officers.md"
}

run_library() {  # [date] [now]
  FM_OFFICER_NOW="${2:-$NOW}" FM_HOME="$HOME_DIR" "$OFFICER" run library --date "${1:-$DATE}"
}

lane() { printf '%s/data/officers/library\n' "$HOME_DIR"; }
bucket_of() { jq -r --arg p "$1" '[.items[] | select(.path == $p) | .bucket] | join(",")' "$(lane)/${2:-$DATE}.json"; }

test_buckets() {
  local out json
  make_world buckets
  out=$(run_library) || fail "a library run must succeed: $out"
  json="$(lane)/$DATE.json"
  assert_equals 2026-10-31 "$(jq -r .run "$json")" "the newest dated run is judged and a moved-aside folder is skipped"
  assert_equals safe "$(bucket_of README.md)" "a README count fix is safe to ship"
  assert_equals safe "$(bucket_of package.json)" "a tech-stack record is safe to ship"
  assert_equals needs-lee "$(bucket_of docs/adr/0003.md)" "a conflict needs Lee"
  assert_equals needs-lee "$(bucket_of spec/loose.md)" "a move waiting on an owner needs Lee"
  assert_equals needs-lee "$(bucket_of .claude/skills/x/SKILL.md)" "an instruction file needs Lee"
  assert_equals needs-lee "$(bucket_of scripts/old.sh)" "a deletion needs Lee"
  assert_equals code "$(bucket_of src/A.cs)" "unneeded code is code work"
  assert_equals code "$(bucket_of Directory.Packages.props)" "a finding that needs its own brief is code work"
  assert_equals hold "$(bucket_of scripts/ops/brief.md)" "an unresolved finding is on hold, whatever its kind"
  assert_equals hold "$(bucket_of .)" "a report-only finding is on hold"
  assert_equals needs-lee "$(bucket_of "$RUNS/2026-10-31/report.md")" "the run's decisions are one item for Lee"
  assert_contains "$(jq -r '.items[] | select(.kind == "decisions") | .title' "$json")" "5 decision(s) for Lee" "it counts the run's decisions"
  assert_contains "$out" "DIGEST $DATE 9 data/officers/library/$DATE.md" "new items in every bucket but hold count"
  assert_grep "## Safe to ship (2)" "$(lane)/$DATE.md" "the digest groups items by bucket"
  pass "fm-officer library: each audit finding lands in one bucket"
}

test_reported_once_and_identical_rerun() {
  local first second out
  make_world once
  run_library >/dev/null || fail "first run must succeed"
  first=$(cd "$(lane)" && cksum "$DATE.json" "$DATE.md" reported.json)
  run_library >/dev/null || fail "rerun must succeed"
  second=$(cd "$(lane)" && cksum "$DATE.json" "$DATE.md" reported.json)
  assert_equals "$first" "$second" "a rerun of the same key on unchanged inputs writes identical bytes"
  out=$(run_library 2026-11-02) || fail "next day must succeed"
  assert_contains "$out" "DIGEST 2026-11-02 0 " "the same audit run is not reported again"
  write_run "$RUNS/2026-11-07" ok 5
  printf '[%s]\n' "$(finding readme README.md "README undercounts the rules" "Propose changing the count to 29.")" > "$RUNS/2026-11-07/findings.json"
  out=$(run_library 2026-11-07 $((NOW + 7 * 86400))) || fail "next audit must succeed"
  assert_contains "$out" "DIGEST 2026-11-07 1 " "a finding the last audit already raised is not new; the new run's decisions are"
  pass "fm-officer library: a finding is reported once and reruns are identical"
}

test_coverage_gaps_never_fail_the_run() {
  local out
  make_world gaps
  sed -i.bak 's/"outcome": "ok"/"outcome": "partial"/' "$RUNS/2026-10-31/result.json"
  mv "$RUNS/2026-10-31/findings.json" "$RUNS/2026-10-31/findings.moved"
  out=$(run_library 2026-11-10 $((NOW + 10 * 86400))) || fail "a run with gaps must succeed: $out"
  assert_contains "$out" "Coverage gap: library: audit run 2026-10-31 has no readable findings.json" "a missing findings file is a gap"
  assert_contains "$out" "Coverage gap: library: audit run 2026-10-31 outcome is partial" "a partial audit is noted"
  assert_contains "$out" "Coverage gap: library: the newest audit run, 2026-10-31, is more than 8 days old" "an old audit is noted"
  sed -i.bak "s|audit: [^;]*;|audit: $TMP_ROOT/gaps/none;|" "$HOME_DIR/data/officers.md"
  out=$(run_library 2026-11-11) || fail "a run with no audit folder must succeed: $out"
  assert_contains "$out" "Coverage gap: library: no audit run folder under $TMP_ROOT/gaps/none" "no run folder is a gap"
  assert_contains "$out" "DIGEST 2026-11-11 0 " "a gap is not a finding"
  pass "fm-officer library: missing and old audit runs are coverage gaps"
}

test_run_writes_only_its_lane() {
  local before after
  make_world lane
  before=$(cd "$TMP_ROOT/lane" && find . -path ./home/data/officers/library -prune -o -type f -print | LC_ALL=C sort | xargs cksum)
  run_library >/dev/null || fail "run must succeed"
  after=$(cd "$TMP_ROOT/lane" && find . -path ./home/data/officers/library -prune -o -type f -print | LC_ALL=C sort | xargs cksum)
  assert_equals "$before" "$after" "a library run changes nothing outside its lane, the audit folders included"
  pass "fm-officer library: a run writes only its lane"
}

test_buckets
test_reported_once_and_identical_rerun
test_coverage_gaps_never_fail_the_run
test_run_writes_only_its_lane
