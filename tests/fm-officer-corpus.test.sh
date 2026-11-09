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
#
# With writes: linear (a fake linear-axi that logs every call): findings filed as Chore items
# under the corpus-fp marker in the Fleet project with area:fleet, nothing but counts, names
# and timestamps in an item body, the create cap with the overflow named, the Found line
# raised once a night, a high finding started on first sight and a medium one on its third
# night, a start request addressed to the office that dispatches the repository (else this
# home), the scan-gate route named on a request whose fix may touch the scan gate, a
# reserved class held as one keyed needs-decision, and writes: none making no Linear call.
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
  printf '{"backend": "memory-service", "listed": 100, "written": 4, "withheld": 0, "deleted": 0, "superseded": 2, "tier_total": 100, "superseded_listable": true, "scrubber_version": "1", "started_at": "2026-11-05T03:00:00Z", "finished_at": "2026-11-05T03:00:09Z", "result": "ok"}\n' \
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
  printf '{"backend": "memory-service", "listed": 90, "written": 4, "withheld": 0, "deleted": 0, "superseded": 2, "tier_total": 100, "superseded_listable": true, "scrubber_version": "1", "started_at": "2026-11-05T03:00:00Z", "finished_at": "2026-11-05T03:00:09Z", "result": "failed"}\n' > "$W/corpus/memory-harvest/last-result.json"
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

test_harvest_reads_the_writers_schema() {
  local out hf
  make_world schema
  hf="$W/corpus/memory-harvest/last-result.json"
  out=$(run_corpus) || fail "a good harvest must run: $out"
  assert_not_contains "$out" "outcome None" "a good harvest never reads as outcome None"
  assert_grep "Memory harvest: outcome ok; listed 100, tier_total 100, written 4" "$(lane)/$DATE.md" "the digest reads the writer's flat fields"
  assert_not_contains "$(classes)" "harvest" "a good harvest raises no finding"
  sed -i 's/"result": "ok"/"result": "partial"/; s/"listed": 100/"listed": 60/' "$hf"
  run_corpus >/dev/null || fail "a partial harvest must run"
  assert_contains "$(classes)" "harvest-drift memory-harvest" "a partial harvest that lists short is the drift finding"
  assert_not_contains "$(classes)" "harvest-failed" "a partial harvest is not a failed one"
  sed -i 's/"result": "partial"/"result": "failed"/' "$hf"
  run_corpus >/dev/null || fail "a failed harvest must run"
  assert_contains "$(classes)" "harvest-failed memory-harvest" "a failed harvest is the harvest finding"
  sed -i 's/"tier_total": [0-9]*/"tier_total": null/' "$hf"
  out=$(run_corpus) || fail "a harvest with a null tier_total must run: $out"
  assert_contains "$out" "the memory harvest's result names no tier_total count" "a null tier_total is named alone"
  assert_not_contains "$out" "names no listed" "listed is present and not reported missing"
  sed -i 's/, "result": "failed"//' "$hf"
  out=$(run_corpus) || fail "a harvest with no result must run: $out"
  assert_not_contains "$(classes)" "harvest-failed" "a file with no result field is not guessed"
  assert_contains "$out" "memory harvest's last result" "it is reported as unreadable"
  pass "fm-officer corpus: the harvest is read from the fields memory_harvest.py writes"
}

test_harvest_zero_total_is_not_missing_counts() {
  local out
  make_world zero
  printf '{"backend": "memory-service", "listed": 0, "written": 4, "withheld": 0, "deleted": 0, "superseded": 2, "tier_total": 0, "superseded_listable": true, "scrubber_version": "1", "started_at": "2026-11-05T03:00:00Z", "finished_at": "2026-11-05T03:00:09Z", "result": "ok"}\n' > "$W/corpus/memory-harvest/last-result.json"
  out=$(run_corpus) || fail "a run with an empty tier must succeed: $out"
  assert_not_contains "$out" "names no tier_total count" "a total of 0 is a count, not a missing one"
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

# fake_linear <bindir>: linear-axi driven by $FAKE_LINEAR_DIR (labels.txt); it logs every call to
# $FAKE_LINEAR_DIR/log and refuses to run without that variable, so no test can reach the real Linear.
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
  "issue search") echo '{"ok":true,"data":{"issues":[]}}' ;;
  "issue view")
    echo '{"ok":true,"data":{"issue":{"identifier":"'"$3"'","state":"Todo","stateType":"unstarted","description":"Found: '"$(cat "$d/found-count" 2>/dev/null || echo 1)"' times (first 2026-11-03, last 2026-11-03, by corpus)"}}}' ;;
  "issue create")
    case " $* " in
      *" --verify "*)
        n=$(( $(cat "$d/created" 2>/dev/null || echo 100) + 1 ))
        echo "$n" > "$d/created"
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

count_lines() {  # <pattern> <file>: how many lines match; 0 when the file does not exist
  local n
  n=$(grep -c -- "$1" "$2" 2>/dev/null || true)
  echo "${n:-0}"
}

# linear_world <name> [extra registry fields]: a world with one finding of every class (a source not collected
# for two runs, a failed and a drifting harvest, a stale prep store, a missed retrain, an archive gap on two
# nights) whose corpus line writes Linear items through the fake. Call it directly, not in $(...): it sets
# W, HOME_DIR, FAKEBIN and FAKE_LINEAR_DIR.
linear_world() {
  make_world "$1"
  {
    runs_line ok ok
    runs_line bad ok
    runs_line bad ok
  } > "$W/corpus/transcript-archive/runs.jsonl"
  printf '{"backend": "memory-service", "listed": 90, "written": 4, "withheld": 0, "deleted": 0, "superseded": 2, "tier_total": 100, "superseded_listable": true, "scrubber_version": "1", "started_at": "2026-11-05T03:00:00Z", "finished_at": "2026-11-05T03:00:09Z", "result": "failed"}\n' > "$W/corpus/memory-harvest/last-result.json"
  printf '{"finished": "2026-11-03T08:00:00+00:00", "rows": 9}\n' > "$W/hosts/slartibartfast/Documents/GitHub/local-jev/data/prep/ready.json"
  printf '{"run": "20261024", "started": "2026-10-24T20:00:02+00:00", "status": "kept"}\n' \
    > "$W/hosts/deepthought/Documents/GitHub/local-jev/results/weekly/history.jsonl"
  bosun "$W/hosts/slartibartfast" 2026-11-04 2 1
  run_corpus 2026-11-04 $((NOW - 86400)) >/dev/null || fail "the first night must succeed"
  bosun "$W/hosts/slartibartfast" 2026-11-05 2 1
  sed -i.bak "s|; model: none;|; writes: linear; jev: /nonexistent/jev.py${2:-}; model: none;|" "$HOME_DIR/data/officers.md"
  fake_linear "$FAKEBIN"
  export FAKE_LINEAR_DIR="$W/linear"
  mkdir -p "$FAKE_LINEAR_DIR"
  printf '%s\n' Bug Chore agent area:fleet triage > "$FAKE_LINEAR_DIR/labels.txt"
}

request_of() {  # <class> [date]: the start request of a finding class from the digest
  jq -c --arg c "$1" '.start_requests[] | select(.class == $c)' "$(lane)/${2:-$DATE}.json"
}

test_findings_are_filed_in_the_fleet_project_with_counts_only() {
  local dir log json
  linear_world filed
  dir=$FAKE_LINEAR_DIR
  log=$dir/log
  json="$(lane)/$DATE.json"
  run_corpus >/dev/null || fail "a writing run must succeed"
  assert_equals 6 "$(count_lines '^issue create .*--verify' "$log")" "each of the six open findings is filed once"
  assert_equals 6 "$(count_lines '^issue create .*--dry-run' "$log")" "every create is a dry run first"
  assert_equals 6 "$(count_lines '^issue create .*--label Chore --label agent --label area:fleet --project Fleet --dry-run' "$log")" \
    "each item is a Chore with the agent Source and area:fleet, in the Fleet project, in team PC"
  assert_equals 6 "$(count_lines '^corpus-fp:' "$dir/bodies")" "every body carries the corpus-fp marker alone on its line"
  assert_equals 6 "$(count_lines '^Found: 1 times (first 2026-11-04, last 2026-11-04, by corpus)$' "$dir/bodies")" "and its one Found line"
  assert_no_grep "SESSION-TEXT" "$dir/bodies" "no session text, error text or list item reaches a Linear item"
  assert_grep "Scan gate: the fix may touch the scan gate files" "$dir/bodies" "an item whose fix may touch the scan gate says so"
  assert_equals 0 "$(jq '.asks_for_lee | length' "$json")" "nothing is held for Lee"

  run_corpus >/dev/null || fail "a same-day re-run must succeed"
  assert_equals 6 "$(count_lines '^issue create .*--verify' "$log")" "a re-run files nothing more"
  assert_equals 0 "$(count_lines '^UPDATE' "$dir/updates")" "and raises no Found line"
  run_corpus 2026-11-05 $((NOW + 86400)) >/dev/null || fail "the next night must succeed"
  assert_equals 6 "$(count_lines '^issue create .*--verify' "$log")" "the next night creates nothing: the findings already have items"
  assert_equals 6 "$(count_lines '^UPDATE' "$dir/updates")" "and raises each item's Found line in place"
  assert_equals 6 "$(count_lines '^COMMENT' "$dir/comments")" "with one comment on the night's first sighting"
  assert_equals 6 "$(jq '[.findings[] | select(.linear.found == 2)] | length' "$(lane)/2026-11-05.json")" "the digest shows the found count"
  pass "fm-officer corpus: findings are filed as Fleet Chore items from counts only, and the Found line rises once a night"
}

test_create_cap_names_the_overflow() {
  linear_world cap "; max-creates: 2"
  run_corpus >/dev/null || fail "a capped run must succeed"
  assert_equals 2 "$(count_lines '^issue create .*--verify' "$FAKE_LINEAR_DIR/log")" "no more than max-creates items are created"
  assert_contains "$(<"$(lane)/$DATE.md")" "Not filed (over max-creates for this run)" "the overflow is named in the digest"
  pass "fm-officer corpus: the registry create cap holds and names what it leaves"
}

test_start_requests_follow_the_rubric_and_the_repository() {
  local json
  linear_world starts
  json="$(lane)/$DATE.json"
  run_corpus >/dev/null || fail "a writing run must succeed"
  assert_equals "archive-gap,harvest-failed" "$(jq -r '[.start_requests[].class] | sort | join(",")' "$json")" \
    "only the high findings start on first sight; a medium one has not reached the start score"
  assert_equals "$HOME_DIR" "$(jq -r '.start_requests[0].execute.env.FM_HOME' "$json")" "with no start-home office a request goes to this home"
  assert_equals corpus-officer "$(jq -r .source "$json")" "the digest names its source so an office delivers its requests"
  assert_contains "$(jq -r '.start_requests[0].execute.request_id' "$json")" "corpus-$DATE-" "the request id names the corpus officer"
  assert_equals 2 "$(count_lines 'fm-inbox.sh' "$(lane)/$DATE.start-requests.sh")" "this home's requests are in the shell handoff"
  assert_equals true "$(request_of harvest-failed | jq .scan_gate)" "a failed harvest may touch the scan gate"
  assert_contains "$(request_of harvest-failed | jq -r '.execute.argv | last')" "never merges it: it goes to Slarti" "and its request names the scan-gate route"
  assert_equals transcript-archive "$(request_of harvest-failed | jq -r .project)" "and the repository it lands in"
  run_corpus >/dev/null || fail "a same-day re-run must succeed"
  assert_equals 2 "$(jq '.start_requests | length' "$json")" "a re-run repeats the same requests"
  run_corpus 2026-11-05 $((NOW + 86400)) >/dev/null || fail "the next night must succeed"
  assert_equals 0 "$(jq '.start_requests | length' "$(lane)/2026-11-05.json")" "a later night never asks for an item again"
  pass "fm-officer corpus: a high finding starts on first sight, a repeat is not asked twice, and the scan-gate route is named"
}

test_a_medium_finding_starts_on_its_third_night() {
  local dir
  linear_world third
  dir=$FAKE_LINEAR_DIR
  run_corpus >/dev/null || fail "the first writing night must succeed"
  echo 2 > "$dir/found-count" # the items now read Found: 2 times, so the next night's raise makes it 3
  jq '.handled = {}' "$(lane)/review-state.json" > "$dir/state.json" && cp "$dir/state.json" "$(lane)/review-state.json"
  run_corpus 2026-11-05 $((NOW + 86400)) >/dev/null || fail "a later night must succeed"
  assert_equals "archive-gap,harvest-drift,harvest-failed,not-collected,prep-stale,retrain-missed" \
    "$(jq -r '[.start_requests[].class] | sort | join(",")' "$(lane)/2026-11-05.json")" "a medium finding found three times reaches the start score"
  assert_equals local-jev "$(request_of prep-stale 2026-11-05 | jq -r .project)" "a prep store request names local-jev"
  assert_equals false "$(request_of prep-stale 2026-11-05 | jq .scan_gate)" "and no scan-gate route, since its fix is not in the scan gate"
  pass "fm-officer corpus: the found count lifts a medium finding to a start"
}

test_start_requests_reach_the_owning_office() {
  local alc
  linear_world office "; start-home: alchemist"
  alc="$W/alchemist"
  officer_home "$alc"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$alc/data/backlog.md"
  printf 'alchemist\n' > "$alc/.fm-office"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$HOME_DIR" > "$alc/.fm-secondmate-parent"
  printf -- '- alchemist - corpus (home: %s; scope: office; projects: transcript-archive; added 2026-11-06)\n' "$alc" > "$HOME_DIR/data/secondmates.md"
  printf -- '- alchemist - corpus (role: alchemist; dispatch: transcript-archive; sources: tick,lane:corpus; added 2026-11-06)\n' > "$HOME_DIR/data/offices.md"
  FM_HOME="$alc" "$ROOT/bin/fm-office.sh" register-sources >/dev/null || fail "register-sources must succeed in the alchemist home"
  run_corpus >/dev/null || fail "a run with an office must succeed"
  assert_equals "$alc" "$(request_of harvest-failed | jq -r '.execute.env.FM_HOME')" "a transcript-archive finding goes to the office named in start-home:"
  assert_equals "$alc" "$(request_of archive-gap | jq -r '.execute.env.FM_HOME')" "as does an archive gap"
  assert_equals 0 "$(count_lines 'fm-inbox.sh' "$(lane)/$DATE.start-requests.sh")" "and neither goes into this home's handoff"
  pass "fm-officer corpus: start-home in the registry sends a start request to the office that owns the repository"
}

test_registry_checks_the_linear_fields() {
  make_world badwrites
  sed -i.bak 's/; model: none;/; writes: bogus; model: none;/' "$HOME_DIR/data/officers.md"
  assert_contains "$(FM_HOME="$HOME_DIR" "$OFFICER" ensure)" "OFFICER: officer corpus: writes must be linear or none" "ensure reports a bad writes: on a corpus line"
  make_world badcap
  sed -i.bak 's/; model: none;/; max-creates: 0; model: none;/' "$HOME_DIR/data/officers.md"
  assert_contains "$(FM_HOME="$HOME_DIR" "$OFFICER" ensure)" "OFFICER: officer corpus: max-creates must be a whole number" "ensure reports a bad max-creates: on a corpus line"
  pass "fm-officer corpus: the registry checks the corpus line's Linear fields"
}

test_a_reserved_class_is_held() {
  local json line
  linear_world reserved
  line='{"started": "2026-11-05T07:00:00+00:00", "finished": "2026-11-05T07:08:54+00:00", "sources": {"deploy to production/codex": "not collected: ssh exited 1", "deepthought/claude-code": "ok"}}'
  printf '%s\n%s\n' "$line" "$line" > "$W/corpus/transcript-archive/runs.jsonl"
  run_corpus >/dev/null || fail "the first writing night must succeed"
  echo 2 > "$FAKE_LINEAR_DIR/found-count" # the item reaches the start score on its third night
  json="$(lane)/2026-11-05.json"
  run_corpus 2026-11-05 $((NOW + 86400)) >/dev/null || fail "a later night must succeed"
  assert_equals "corpus-holds-2026-11-05" "$(jq -r '.asks_for_lee[0].key' "$json")" "a finding matching a reserved class is one keyed needs-decision"
  assert_equals production-actions "$(jq -r '.held[0].class' "$json")" "with its class"
  assert_equals false "$(jq '[.start_requests[].class] | index("not-collected") != null' "$json")" "and never starts"
  pass "fm-officer corpus: a reserved class is held for Lee and never starts"
}

test_no_writes_and_a_missing_label_file_nothing() {
  local dir
  make_world nowrites
  fake_linear "$FAKEBIN"
  export FAKE_LINEAR_DIR="$W/linear"
  mkdir -p "$FAKE_LINEAR_DIR"
  printf '{"backend": "memory-service", "listed": 100, "written": 4, "withheld": 0, "deleted": 0, "superseded": 2, "tier_total": 100, "superseded_listable": true, "scrubber_version": "1", "started_at": "2026-11-05T03:00:00Z", "finished_at": "2026-11-05T03:00:09Z", "result": "failed"}\n' > "$W/corpus/memory-harvest/last-result.json"
  run_corpus >/dev/null || fail "a writes: none run must succeed"
  assert_equals gone "$([ -e "$FAKE_LINEAR_DIR/log" ] && echo called || echo gone)" "writes: none makes no Linear call at all"
  assert_equals 0 "$(jq '.start_requests | length' "$(lane)/$DATE.json")" "and starts nothing"

  linear_world nolabel
  dir=$FAKE_LINEAR_DIR
  printf '%s\n' Bug Chore area:fleet > "$dir/labels.txt"
  run_corpus >/dev/null || fail "a run with a missing label must succeed"
  assert_equals 0 "$(count_lines '^issue create' "$dir/log")" "with the Source label missing nothing is created"
  assert_contains "$(jq -r '[.findings[].linear.reason // empty] | join(" ")' "$(lane)/$DATE.json")" "label(s) not found in team PC: agent" "each finding is reported with the label named"
  pass "fm-officer corpus: writes: none and a missing label file nothing"
}

# run_host_world <name> <registry fields>: a corpus world whose officer line also carries <fields>
# (run-host: ...); the host's firstmate checkout is this one, so the code check passes.
run_host_world() {
  make_world "$1"
  add_fields "$2"
}

add_fields() { sed -i "s|model: none; added|model: none; $1added|" "$HOME_DIR/data/officers.md"; }

test_run_host_lane_matches_a_local_run() {
  local out
  make_world same
  run_corpus >/dev/null || fail "the local run must succeed"
  mv "$(lane)" "$W/lane.local"
  add_fields "run-host: deepthought; run-host-code: $ROOT; "
  out=$(run_corpus 2>&1) || fail "a run through the run host must succeed: $out"
  assert_contains "$out" "DIGEST $DATE 0 data/officers/corpus/$DATE.md" "the digest line is the local one"
  diff -r --exclude=.run.err "$W/lane.local" "$(lane)" >/dev/null \
    || fail "the lane must be byte-identical to a local run's: $(diff -r --exclude=.run.err "$W/lane.local" "$(lane)" | head -5)"
  assert_equals "" "$(find "$(lane)" -maxdepth 1 -name '.host-stage.*')" "no staging folder is left in the lane"
  assert_present "$W/hosts/deepthought/fm-scratch" "the pass really ran on the host"
  assert_equals "" "$(ls -A "$W/hosts/deepthought/fm-scratch" 2>/dev/null)" "no scratch folder is left on the host"
  pass "fm-officer corpus: a pass run through the run host leaves the same lane as a local run"
}

test_run_host_failures_never_run_locally() {
  local out
  run_host_world down "run-host: nohost; run-host-code: $ROOT; "
  out=$(run_corpus 2>&1) && fail "an unreachable run host must fail the attempt"
  assert_contains "$out" "run host unreachable" "the failure names the unreachable host"
  assert_contains "$(cat "$(lane)/runs.log")" "failed run host unreachable" "runs.log records the failed attempt"
  assert_absent "$(lane)/$DATE.json" "an unreachable host never falls back to a local run"
  run_host_world stale "run-host: deepthought; run-host-code: $TMP_ROOT/older; "
  mkdir -p "$TMP_ROOT/older" && git -C "$TMP_ROOT/older" init -q && git -C "$TMP_ROOT/older" -c user.name=t -c user.email=t@t commit -q --allow-empty -m old
  out=$(run_corpus 2>&1) && fail "a host at another commit must fail the attempt"
  assert_contains "$(cat "$(lane)/runs.log")" "failed host code mismatch" "runs.log records the code mismatch"
  assert_absent "$(lane)/$DATE.json" "a code mismatch never runs the pass anywhere"
  pass "fm-officer corpus: an unreachable run host or a host at another commit fails the attempt and runs nothing"
}

test_run_host_registry_rules() {
  local out
  run_host_world rules "run-host: deepthought; rubric: /x.md; "
  out=$(run_corpus 2>&1) && fail "a rubric file in this home cannot be read on the run host"
  assert_contains "$out" "rubric names a file in this home" "the refusal names the field"
  make_world roles
  sed -i 's/role: corpus;/role: friction;/; s/model: none; added/run-host: deepthought; model: none; added/' "$HOME_DIR/data/officers.md"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$OFFICER" run corpus --date "$DATE" 2>&1) && fail "friction cannot use a run host"
  assert_contains "$out" "run-host is supported on corpus and surgeon officers only" "other roles are refused"
  pass "fm-officer corpus: run-host is refused where the pass reads files in this home"
}

test_run_host_failed_pass_keeps_its_lane_writes() {
  local out
  make_world failed
  cat > "$FAKEBIN/python3" <<SH
#!/usr/bin/env bash
/usr/bin/python3 "\$@"
rc=\$?
case "\$*" in *fm-officer-corpus.py*) [ "\$rc" -ne 0 ] || exit 3 ;; esac
exit \$rc
SH
  chmod +x "$FAKEBIN/python3"
  run_corpus >/dev/null 2>&1 && fail "a pass that exits non-zero must fail the run"
  assert_present "$(lane)/nights.json" "a failed local pass leaves the lane files it wrote"
  mv "$(lane)" "$W/lane.local"
  add_fields "run-host: deepthought; run-host-code: $ROOT; "
  out=$(run_corpus 2>&1) && fail "a failed pass on the run host must fail the run"
  diff -r --exclude=.run.err "$W/lane.local" "$(lane)" >/dev/null \
    || fail "a failed run-host pass must leave the lane a local failed pass leaves: $(diff -r --exclude=.run.err "$W/lane.local" "$(lane)" | head -5)"
  assert_contains "$(cat "$(lane)/runs.log")" "failed" "the failure is logged"
  pass "fm-officer corpus: a pass that fails after writing leaves the same lane through the run host"
}

test_run_host_pass_is_bounded_on_the_host() {
  local out
  run_host_world bound "run-host: deepthought; run-host-code: $ROOT; "
  cat > "$FAKEBIN/python3" <<SH
#!/usr/bin/env bash
case "\$*" in *fm-officer-corpus.py*) exec sleep 3007 ;; esac
exec /usr/bin/python3 "\$@"
SH
  chmod +x "$FAKEBIN/python3"
  out=$(FM_OFFICER_RUN_TIMEOUT=4 run_corpus 2>&1) && fail "a pass past the bound must fail the run"
  assert_contains "$out" "run host timed out" "the host ends the pass at its bound and the run says so"
  # The host ends the pass at its bound; give the process a moment to go.
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "[s]leep 300[7]" >/dev/null || break; sleep 1; done
  assert_equals "" "$(pgrep -f "[s]leep 300[7]" || true)" "no pass is left running"
  pass "fm-officer corpus: a run-host pass past FM_OFFICER_RUN_TIMEOUT is ended on the host"
}

test_healthy_corpus_has_no_findings
test_each_finding_class
test_archive_gap_needs_two_nights
test_reported_once_rerun_identical_and_recurrence
test_unreachable_source_is_not_reported_again
test_harvest_reads_the_writers_schema
test_harvest_zero_total_is_not_missing_counts
test_coverage_gaps_never_fail_the_run
test_run_writes_only_its_lane
test_registry_needs_archive
test_findings_are_filed_in_the_fleet_project_with_counts_only
test_create_cap_names_the_overflow
test_start_requests_follow_the_rubric_and_the_repository
test_a_medium_finding_starts_on_its_third_night
test_start_requests_reach_the_owning_office
test_registry_checks_the_linear_fields
test_a_reserved_class_is_held
test_no_writes_and_a_missing_label_file_nothing
test_run_host_lane_matches_a_local_run
test_run_host_failures_never_run_locally
test_run_host_registry_rules
test_run_host_failed_pass_keeps_its_lane_writes
test_run_host_pass_is_bounded_on_the_host
