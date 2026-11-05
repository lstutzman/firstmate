#!/usr/bin/env bash
# Behavior tests for the corpus officer, driven through bin/fm-officer.sh run
# with fixture result files laid out as each host's home and a fake ssh that
# runs the remote probe locally under that host's home.
#
# Covers: each finding class (a source not collected for two runs, an archive
# gap on two Bosun nights, a failed and a drifting memory harvest, a stale prep
# store, a missed and a failed weekly retrain), host-offline sources left out,
# coverage gaps (an unreachable host, a missing harvest, a Bosun result with no
# archive section) that never fail the run, report-once fingerprints and a
# recurrence after a fix, byte-identical re-runs, counts-only output, lane-only
# writes, and the registry's archive requirement.
set -u

# shellcheck source=tests/officer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/officer-helpers.sh"

OFFICER="$ROOT/bin/fm-officer.sh"
TMP_ROOT=$(fm_test_tmproot fm-officer-corpus)
DATE=2026-11-04
NOW=1793866500 # 2026-11-05T08:15:00Z

# make_world <name>: sets W (the world) and HOME_DIR (the firstmate home), with a healthy corpus.
make_world() {
  W="$TMP_ROOT/$1"
  HOME_DIR="$W/home"
  officer_home "$HOME_DIR"
  local dt="$W/hosts/deepthought" sl="$W/hosts/slartibartfast"
  mkdir -p "$W/corpus/transcript-archive" "$W/corpus/memory-harvest" "$dt/services/bosun-maintenance" \
    "$sl/services/bosun-maintenance" "$sl/Documents/GitHub/local-jev/data/prep" \
    "$dt/Documents/GitHub/local-jev/results/weekly" "$dt/Documents/GitHub/local-jev/results/judge"
  printf '{"outcome": "ok", "summary": "x", "counts": {"archived": 3, "unchanged": 90, "withheld": 1, "errors": 0, "sources_ok": 20, "sources_not_collected": 0, "hosts_offline": 0}}\n' \
    > "$W/corpus/transcript-archive/last-result.json"
  runs_line ok ok > "$W/corpus/transcript-archive/runs.jsonl"
  runs_line ok ok >> "$W/corpus/transcript-archive/runs.jsonl"
  printf '{"outcome": "ok", "counts": {"listed": 100, "total": 100, "written": 4, "withheld": 0, "deleted": 0, "superseded": 2}}\n' \
    > "$W/corpus/memory-harvest/last-result.json"
  bosun "$sl" 2026-11-05 0 0
  bosun "$dt" 2026-11-05 0 0
  printf '{"finished": "2026-11-05T07:28:51+00:00", "version": "1", "rows": 942, "summary": {}}\n' \
    > "$sl/Documents/GitHub/local-jev/data/prep/ready.json"
  printf '{"run": "20261031", "started": "2026-10-31T21:00:09+00:00", "status": "promoted", "rows": {"archive": 5}}\n' \
    > "$dt/Documents/GitHub/local-jev/results/weekly/history.jsonl"
  printf '{}\n' > "$dt/Documents/GitHub/local-jev/results/judge/eval-judge-20261031-r1.json"
  printf -- '- corpus - Checks the agent training corpus (role: corpus; cadence: daily 08:15; archive: deepthought:%s/corpus; hosts: slartibartfast,deepthought; model: none; added 2026-11-05)\n' \
    "$W" > "$HOME_DIR/data/officers.md"
  FAKEBIN=$(fm_fakebin "$W")
  cat > "$FAKEBIN/ssh" <<SH
#!/usr/bin/env bash
while [ "\${1:-}" = -o ]; do shift 2; done
host=\$1; shift
[ -d "$W/hosts/\$host" ] || exit 255
HOME="$W/hosts/\$host" exec bash -c "\$*"
SH
  chmod +x "$FAKEBIN/ssh"
}

# runs_line <codex-state> <omp-state>: one ingester run line; the MacBook is always offline, and the
# line carries session text in errors and withheld that must never reach the lane.
runs_line() {
  local codex=$1 omp=$2
  [ "$codex" = ok ] || codex="not collected: ssh exited 1"
  [ "$omp" = ok ] || omp="not collected: listing failed"
  printf '{"started": "2026-11-05T07:00:00+00:00", "finished": "2026-11-05T07:08:54+00:00", "status": {}, "findings": {}, "errors": [{"host": "slartibartfast", "session": "s1", "error": "SESSION-TEXT-ERR"}], "withheld": [{"session": "SESSION-TEXT-WITHHELD"}], "offline": {}, "sources": {"slartibartfast/codex": "%s", "deepthought/omp": "%s", "macbook/claude-code": "not collected: host offline", "deepthought/claude-code": "ok"}}\n' "$codex" "$omp"
}

bosun() {  # <host-home> <date> <missing> <mismatched>
  printf '{"date": "%s", "outcome": "ok", "counts": {"unsure": 3}, "unsure": [{"item": "SESSION-TEXT-UNSURE"}], "archive": {"host": "deepthought", "reached": true, "checked": 100, "archived": %d, "pending": 1, "missing": %d, "mismatched": %d, "withheld": 0, "missing_list": [{"path": "SESSION-TEXT-PATH"}], "mismatched_list": []}}\n' \
    "$2" "$((99 - $3 - $4))" "$3" "$4" > "$1/services/bosun-maintenance/last-result.json"
}

run_corpus() {  # [date] [now]
  PATH="$FAKEBIN:$PATH" FM_OFFICER_NOW="${2:-$NOW}" FM_HOME="$HOME_DIR" "$OFFICER" run corpus --date "${1:-$DATE}"
}

lane() { printf '%s/data/officers/corpus\n' "$HOME_DIR"; }
classes() { jq -r '[.findings[] | "\(.class) \(.subject)"] | join(",")' "$(lane)/${1:-$DATE}.json"; }
new_count() { jq -r '.actionable' "$(lane)/${1:-$DATE}.json"; }

test_healthy_corpus_has_no_findings() {
  local out
  make_world healthy
  out=$(run_corpus) || fail "a healthy run must succeed: $out"
  assert_contains "$out" "DIGEST $DATE 0 data/officers/corpus/$DATE.md" "a healthy corpus has nothing new"
  assert_equals "" "$(classes)" "a healthy corpus has no findings"
  assert_grep "Hosts offline in the newest ingester run: macbook" "$(lane)/$DATE.md" "offline hosts are named, not found"
  assert_grep "Judge: 1 evaluation results" "$(lane)/$DATE.md" "the judge results are counted from the listing"
  assert_grep "Weekly retrain: newest run 20261031" "$(lane)/$DATE.md" "the newest retrain is named"
  pass "fm-officer corpus: a healthy corpus reads every source over ssh and reports nothing"
}

test_each_finding_class() {
  local out
  make_world classes
  {
    runs_line ok ok
    runs_line bad ok
    runs_line bad bad
  } > "$W/corpus/transcript-archive/runs.jsonl"
  printf '{"outcome": "failed", "counts": {"listed": 90, "total": 100}}\n' > "$W/corpus/memory-harvest/last-result.json"
  printf '{"finished": "2026-11-03T08:00:00+00:00", "rows": 9}\n' > "$W/hosts/slartibartfast/Documents/GitHub/local-jev/data/prep/ready.json"
  printf '{"run": "20261024", "started": "2026-10-24T20:00:02+00:00", "status": "kept"}\n' \
    > "$W/hosts/deepthought/Documents/GitHub/local-jev/results/weekly/history.jsonl"
  out=$(run_corpus) || fail "a run with findings must succeed: $out"
  assert_equals "harvest-failed memory-harvest,harvest-drift memory-harvest,not-collected slartibartfast/codex,prep-stale local-jev-prep,retrain-missed weekly:20261024:missed" \
    "$(classes)" "each class is found, high first; a source not collected for one run and an offline host are not"
  assert_contains "$out" "DIGEST $DATE 5 " "every finding is new on its first run"
  assert_grep "slartibartfast/codex was not collected in the last 2 runs" "$(lane)/$DATE.md" "the digest names the source and its run count"
  printf '{"run": "20261031", "started": "2026-10-31T21:00:09+00:00", "status": "failed"}\n' \
    > "$W/hosts/deepthought/Documents/GitHub/local-jev/results/weekly/history.jsonl"
  run_corpus >/dev/null || fail "rerun must succeed"
  assert_contains "$(classes)" "retrain-missed weekly:20261031:failed" "a failed retrain counts as one that did not run"
  assert_no_grep "SESSION-TEXT" "$(lane)/$DATE.json" "no session text, error text or list item reaches the lane"
  assert_no_grep "SESSION-TEXT" "$(lane)/$DATE.md" "no session text reaches the digest"
  pass "fm-officer corpus: each finding class is found from counts alone"
}

test_archive_gap_needs_two_nights() {
  make_world nights
  bosun "$W/hosts/slartibartfast" 2026-11-04 2 1
  run_corpus 2026-11-03 >/dev/null || fail "night one must succeed"
  assert_equals "" "$(classes 2026-11-03)" "one night with a gap is not a finding yet"
  bosun "$W/hosts/slartibartfast" 2026-11-05 0 1
  run_corpus 2026-11-04 >/dev/null || fail "night two must succeed"
  assert_equals "archive-gap slartibartfast" "$(classes 2026-11-04)" "a gap on two nights is a finding"
  assert_grep "1 session logs on 2026-11-05, and of 3 on 2026-11-04" "$(lane)/2026-11-04.md" "it names both nights' counts"
  bosun "$W/hosts/slartibartfast" 2026-11-06 0 0
  run_corpus 2026-11-05 >/dev/null || fail "night three must succeed"
  assert_equals "" "$(classes 2026-11-05)" "a clean night clears it"
  assert_equals '{"2026-11-04":3,"2026-11-05":1,"2026-11-06":0}' "$(jq -c .slartibartfast "$(lane)/nights.json")" "nights.json keeps each Bosun night's count"
  pass "fm-officer corpus: an archive gap is a finding only after two Bosun nights"
}

test_reported_once_rerun_identical_and_recurrence() {
  local first second
  make_world once
  printf '{"finished": "2026-11-03T08:00:00+00:00", "rows": 9}\n' > "$W/hosts/slartibartfast/Documents/GitHub/local-jev/data/prep/ready.json"
  run_corpus >/dev/null || fail "first run must succeed"
  first=$(cd "$(lane)" && cksum "$DATE.json" "$DATE.md" reported.json nights.json)
  run_corpus >/dev/null || fail "rerun must succeed"
  second=$(cd "$(lane)" && cksum "$DATE.json" "$DATE.md" reported.json nights.json)
  assert_equals "$first" "$second" "a rerun of the same key on unchanged inputs writes identical bytes"
  assert_equals 1 "$(new_count)" "a rerun keeps the finding new at the key that first reported it"
  run_corpus 2026-11-05 $((NOW + 3600)) >/dev/null || fail "next day must succeed"
  assert_equals "prep-stale local-jev-prep" "$(classes 2026-11-05)" "an unfixed finding stays listed"
  assert_equals 0 "$(new_count 2026-11-05)" "it is not reported again"
  printf '{"finished": "2026-11-05T07:00:00+00:00", "rows": 9}\n' > "$W/hosts/slartibartfast/Documents/GitHub/local-jev/data/prep/ready.json"
  run_corpus 2026-11-06 >/dev/null || fail "fixed run must succeed"
  assert_equals "{}" "$(jq -c . "$(lane)/reported.json")" "a cleared fingerprint is dropped"
  printf '{"finished": "2026-11-03T08:00:00+00:00", "rows": 9}\n' > "$W/hosts/slartibartfast/Documents/GitHub/local-jev/data/prep/ready.json"
  run_corpus 2026-11-07 >/dev/null || fail "recurrence run must succeed"
  assert_equals 1 "$(new_count 2026-11-07)" "a recurrence after a fix is new again"
  pass "fm-officer corpus: a finding is reported once, reruns are identical, and a recurrence is new"
}

test_unreachable_source_is_not_reported_again() {
  local prep
  make_world outage
  prep="$W/hosts/slartibartfast/Documents/GitHub/local-jev/data/prep/ready.json"
  bosun "$W/hosts/deepthought" 2026-11-04 2 0
  run_corpus 2026-11-03 >/dev/null || fail "night one must succeed"
  printf '{"finished": "2026-11-03T08:00:00+00:00", "rows": 9}\n' > "$prep"
  bosun "$W/hosts/deepthought" 2026-11-05 2 0
  run_corpus >/dev/null || fail "night two must succeed"
  assert_equals "archive-gap deepthought,prep-stale local-jev-prep" "$(classes)" "both findings are open"
  assert_equals 2 "$(new_count)" "both are new on their first run"
  mv "$prep" "$W/prep.moved"
  mv "$W/hosts/deepthought" "$W/deepthought.away"
  run_corpus 2026-11-05 $((NOW + 3600)) >/dev/null || fail "a run with the sources away must succeed"
  assert_equals "" "$(classes 2026-11-05)" "nothing is judged from a source that could not be read"
  mv "$W/prep.moved" "$prep"
  mv "$W/deepthought.away" "$W/hosts/deepthought"
  run_corpus 2026-11-06 $((NOW + 7200)) >/dev/null || fail "a run with the sources back must succeed"
  assert_equals "archive-gap deepthought,prep-stale local-jev-prep" "$(classes 2026-11-06)" "the unfixed findings are open again"
  assert_equals 0 "$(new_count 2026-11-06)" "a finding is not reported again after a run that could not read its source"
  pass "fm-officer corpus: an unreachable or missing source keeps its findings reported"
}

test_harvest_zero_total_is_not_missing_counts() {
  local out
  make_world zero
  printf '{"outcome": "ok", "counts": {"listed": 0, "total": 0}}\n' > "$W/corpus/memory-harvest/last-result.json"
  out=$(run_corpus) || fail "a run with an empty tier must succeed: $out"
  assert_not_contains "$out" "names no listed and total counts" "a total of 0 is a count, not a missing one"
  assert_contains "$out" "DIGEST $DATE 0 " "an empty tier is not a drift finding"
  pass "fm-officer corpus: a harvest total of 0 is not reported as missing counts"
}

test_coverage_gaps_never_fail_the_run() {
  local out
  make_world gaps
  sed -i.bak 's/hosts: slartibartfast,deepthought/hosts: slartibartfast,deepthought,ghost/' "$HOME_DIR/data/officers.md"
  mv "$W/corpus/memory-harvest/last-result.json" "$W/harvest.moved"
  printf '{"date": "2026-11-05", "counts": {}}\n' > "$W/hosts/deepthought/services/bosun-maintenance/last-result.json"
  out=$(run_corpus) || fail "a run with gaps must succeed: $out"
  assert_contains "$out" "Coverage gap: corpus: the Bosun result on ghost is on a host that could not be reached" "an unreachable host is a gap"
  assert_contains "$out" "Coverage gap: corpus: the memory harvest has no result yet" "a missing harvest is a note, not a finding"
  assert_contains "$out" "the Bosun result on deepthought (2026-11-05) has no archive section" "a Bosun result with no archive section is a gap"
  assert_contains "$out" "DIGEST $DATE 0 " "gaps are not findings"
  pass "fm-officer corpus: unreachable hosts and missing files are coverage gaps"
}

test_run_writes_only_its_lane() {
  local before after
  make_world lane
  before=$(cd "$W" && find . -path ./home/data/officers/corpus -prune -o -type f -print | LC_ALL=C sort | xargs cksum)
  run_corpus >/dev/null || fail "run must succeed"
  after=$(cd "$W" && find . -path ./home/data/officers/corpus -prune -o -type f -print | LC_ALL=C sort | xargs cksum)
  assert_equals "$before" "$after" "a corpus run changes nothing outside its lane, on any host"
  pass "fm-officer corpus: a run writes only its lane"
}

test_registry_needs_archive() {
  make_world registry
  sed -i.bak 's/archive: [^;]*; //' "$HOME_DIR/data/officers.md"
  assert_contains "$(FM_HOME="$HOME_DIR" "$OFFICER" ensure)" "OFFICER: officer corpus: a corpus officer needs archive:" "ensure reports a corpus line with no archive"
  pass "fm-officer corpus: the registry line needs archive:"
}

test_healthy_corpus_has_no_findings
test_each_finding_class
test_archive_gap_needs_two_nights
test_reported_once_rerun_identical_and_recurrence
test_unreachable_source_is_not_reported_again
test_harvest_zero_total_is_not_missing_counts
test_coverage_gaps_never_fail_the_run
test_run_writes_only_its_lane
test_registry_needs_archive
