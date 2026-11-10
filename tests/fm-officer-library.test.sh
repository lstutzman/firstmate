#!/usr/bin/env bash
# Behavior tests for the library officer, driven through bin/fm-officer.sh run
# with librarian-audit run folders of the fleet-app job's documented shape.
#
# Covers: each bucket (needs Lee, safe to ship, code work, on hold) and the
# run's decisions for Lee, the newest dated run chosen and a moved-aside one
# skipped, report-once fingerprints across days, byte-identical re-runs,
# coverage gaps (no run folder, a missing findings file, a partial outcome, an
# old audit) that never fail the run, and lane-only writes.
#
# With writes: linear (a fake linear-axi that logs every call): findings filed as Chore
# items under the librarian-fp marker, the create cap of 3 per audit run (not per day) with
# the overflow named and filed by the next audit, kept across a rate-limit stop and above a
# larger registry max-creates, the Found line raised once per audit run,
# a safe high finding started, a reserved-class one held, needs-Lee items one keyed
# needs-decision per run, and hold items and the decisions item never filed.
set -u

# shellcheck source=tests/officer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/officer-helpers.sh"

OFFICER="$ROOT/bin/fm-officer.sh"
TMP_ROOT=$(fm_test_tmproot fm-officer-library)
DATE=2026-11-01
NOW=1793871000 # 2026-11-05T09:30:00Z

# fake_linear <bindir>: linear-axi driven by $FAKE_LINEAR_DIR (labels.txt, and rate-limit-at, the PC number whose
# create --verify answers RATE_LIMITED instead); it logs every call to
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
  "issue list") echo '{"ok":true,"data":{"issues":[]}}' ;;  # no open bundle of an exact title yet
  "issue view")
    echo '{"ok":true,"data":{"issue":{"identifier":"'"$3"'","state":"Todo","stateType":"unstarted","description":"Found: 1 times (first 2026-10-24, last 2026-10-24, by library)"}}}' ;;
  "issue create")
    case " $* " in
      *" --verify "*)
        n=$(( $(cat "$d/created" 2>/dev/null || echo 100) + 1 ))
        if [ "$n" = "$(cat "$d/rate-limit-at" 2>/dev/null)" ]; then
          echo '{"ok":false,"error":{"code":"RATE_LIMITED","message":"slow down"}}'; exit 1
        fi
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
LINEAR_BIN="$TMP_ROOT/linear-bin"
mkdir -p "$LINEAR_BIN"
fake_linear "$LINEAR_BIN"
export PATH="$LINEAR_BIN:$PATH"

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
    finding cruft docs/old-plan.md "Superseded plan" "Archive it under docs/archive in the docs PR (git-status: tracked)."; printf ','
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
  assert_equals safe "$(bucket_of docs/old-plan.md)" "an archive inside a PR that keeps the source is safe"
  assert_equals code "$(bucket_of src/A.cs)" "unneeded code is code work"
  assert_equals code "$(bucket_of Directory.Packages.props)" "a finding that needs its own brief is code work"
  assert_equals hold "$(bucket_of scripts/ops/brief.md)" "an unresolved finding is on hold, whatever its kind"
  assert_equals hold "$(bucket_of .)" "a report-only finding is on hold"
  assert_equals needs-lee "$(bucket_of "$RUNS/2026-10-31/report.md")" "the run's decisions are one item for Lee"
  assert_contains "$(jq -r '.items[] | select(.kind == "decisions") | .title' "$json")" "5 decision(s) for Lee" "it counts the run's decisions"
  assert_contains "$out" "DIGEST $DATE 10 data/officers/library/$DATE.md" "new items in every bucket but hold count"
  assert_grep "## Safe to ship (3)" "$(lane)/$DATE.md" "the digest groups items by bucket"
  pass "fm-officer library: each audit finding lands in one bucket"
}

test_archive_is_safe_but_delete_retire_and_outside_pr_need_lee() {
  make_world precedence
  write_run "$RUNS/2026-11-07" ok 0
  printf '[%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s]\n' \
    "$(finding misplaced docs/a.md "Two stale plans" "Archive docs/a.md and delete docs/b.md.")" \
    "$(finding misplaced scripts/ops/old-runbook.md "Old runbook" "Retire scripts/ops/old-runbook.md.")" \
    "$(finding cruft .vs/cache.tmp "Untracked editor cache" "Move it out of the checkout.")" \
    "$(finding cruft docs/old-plan.md "Superseded plan" "Archive it under docs/archive in the docs PR (git-status: tracked).")" \
    "$(finding cruft docs/notes.md "Stray notes" "Record it in the inventory.")" \
    "$(printf '{"kind": "cruft", "severity": "low", "title": "Old build plan", "path": "artifacts/old-plan.md", "evidence": "Status: ignored; matched by .gitignore", "disposition": "Archive it under docs/archive."}')" \
    "$(printf '{"kind": "cruft", "severity": "low", "title": "Old notes", "path": ".vs/old-notes.md", "evidence": "no consumers; superseded by docs/plan.md", "disposition": "Archive it under docs/archive."}')" \
    "$(printf '{"kind": "cruft", "severity": "low", "title": "Old notes", "path": "docs/old-notes.md", "evidence": "git-status: tracked; no consumers", "disposition": "Archive it under docs/archive."}')" \
    "$(printf '{"kind": "cruft", "severity": "low", "title": "Scratch plan", "path": "tmp/plan.md", "evidence": "untracked file, no consumers", "disposition": "Archive it under docs/archive."}')" \
    "$(printf '{"kind": "cruft", "severity": "low", "title": "Scratch notes", "path": "tmp/notes.md", "evidence": "isn'"'"'t tracked, no consumers", "disposition": "Archive it under docs/archive."}')" \
    "$(printf '{"kind": "cruft", "severity": "low", "title": "Notes", "path": ".vs/notes.md", "evidence": "Superseded; tracked in PC-4100", "disposition": "Archive it under docs/archive."}')" \
    "$(finding misplaced docs/loose-plan.md "Loose plan" "Move it into docs/plans.")" \
    "$(finding misplaced plan.md "Plan at the root" "Move the plan out of the repo root into docs/plans (git-status: tracked).")" \
    "$(finding readme README.md "README undercounts the rules" "Correct the count to 29.")" \
    > "$RUNS/2026-11-07/findings.json"
  run_library 2026-11-07 $((NOW + 7 * 86400)) >/dev/null || fail "the audit run must succeed"
  assert_equals needs-lee "$(bucket_of docs/a.md 2026-11-07)" "a delete beside an archive still needs Lee"
  assert_equals needs-lee "$(bucket_of scripts/ops/old-runbook.md 2026-11-07)" "a retirement needs Lee"
  assert_equals needs-lee "$(bucket_of .vs/cache.tmp 2026-11-07)" "a move of an untracked file out of the checkout needs Lee"
  assert_equals safe "$(bucket_of docs/old-plan.md 2026-11-07)" "a cruft archive of a tracked file inside a PR is safe"
  assert_equals needs-lee "$(bucket_of artifacts/old-plan.md 2026-11-07)" "an archive of an ignored file cannot happen inside a PR, so it needs Lee"
  assert_equals needs-lee "$(bucket_of .vs/old-notes.md 2026-11-07)" "an archive of a file the finding does not show is tracked needs Lee"
  assert_equals safe "$(bucket_of docs/old-notes.md 2026-11-07)" "an archive of a file the finding marks git-status: tracked is safe"
  assert_equals needs-lee "$(bucket_of tmp/plan.md 2026-11-07)" "an archive of an untracked file needs Lee"
  assert_equals needs-lee "$(bucket_of tmp/notes.md 2026-11-07)" "an archive of a file that isn't tracked needs Lee"
  assert_equals needs-lee "$(bucket_of .vs/notes.md 2026-11-07)" "tracked in an issue is not a Git status, so the archive needs Lee"
  assert_equals needs-lee "$(bucket_of docs/loose-plan.md 2026-11-07)" "a misplaced move with no tracked signal needs Lee"
  assert_equals safe "$(bucket_of plan.md 2026-11-07)" "a tracked move out of the repo root into docs stays inside the PR"
  assert_equals safe "$(bucket_of README.md 2026-11-07)" "a README correction is safe as before"
  assert_equals hold "$(bucket_of docs/notes.md 2026-11-07)" "a cruft finding that neither archives nor moves never ships by itself"
  pass "fm-officer library: only an archive or move inside a PR is safe; a delete, retirement or move outside a PR needs Lee"
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

test_hold_item_counts_once_it_can_ship() {
  local out
  make_world promote
  run_library >/dev/null || fail "first run must succeed"
  write_run "$RUNS/2026-11-07" ok 0
  printf '[%s]\n' "$(finding misplaced scripts/ops/brief.md "Brief among scripts" "Propose moving it to docs/runbooks (git-status: tracked).")" > "$RUNS/2026-11-07/findings.json"
  out=$(run_library 2026-11-07 $((NOW + 7 * 86400))) || fail "next audit must succeed"
  assert_equals safe "$(bucket_of scripts/ops/brief.md 2026-11-07)" "the finding is now safe to ship"
  assert_contains "$out" "DIGEST 2026-11-07 1 " "an item on hold last week is new once it can ship"
  pass "fm-officer library: an on-hold item is reported when it moves to a counted bucket"
}

test_unreadable_audit_keeps_the_ledger() {
  local out
  make_world outage
  run_library >/dev/null || fail "first run must succeed"
  mv "$RUNS/2026-10-31/findings.json" "$RUNS/2026-10-31/findings.moved"
  run_library 2026-11-02 >/dev/null || fail "a run with no findings file must succeed"
  sed -i.bak "s|audit: [^;]*;|audit: $TMP_ROOT/outage/none;|" "$HOME_DIR/data/officers.md"
  run_library 2026-11-03 >/dev/null || fail "a run with no audit folder must succeed"
  sed -i.bak "s|audit: [^;]*;|audit: $RUNS;|" "$HOME_DIR/data/officers.md"
  mv "$RUNS/2026-10-31/findings.moved" "$RUNS/2026-10-31/findings.json"
  out=$(run_library 2026-11-04) || fail "a run with the audit back must succeed"
  assert_contains "$out" "DIGEST 2026-11-04 0 " "findings are not reported again after runs that could not read them"
  pass "fm-officer library: an unreadable audit leaves the reported-once ledger alone"
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

count_lines() {  # <pattern> <file>: how many lines match; 0 when the file does not exist
  local n
  n=$(grep -c -- "$1" "$2" 2>/dev/null || true)
  echo "${n:-0}"
}

# linear_world <name> [extra registry fields]: a world whose library line writes Linear items through the fake.
# Call it directly, not in $(...): it sets HOME_DIR, RUNS and FAKE_LINEAR_DIR.
linear_world() {
  make_world "$1"
  sed -i.bak "s|; model: none;|; writes: linear; jev: /nonexistent/jev.py${2:-}; model: none;|" "$HOME_DIR/data/officers.md"
  export FAKE_LINEAR_DIR="$TMP_ROOT/$1/linear"
  mkdir -p "$FAKE_LINEAR_DIR"
  printf '%s\n' Bug Chore scheduled-review documentation triage > "$FAKE_LINEAR_DIR/labels.txt"
}

test_findings_are_filed_capped_per_audit_run_and_found_raised() {
  local json dir log
  linear_world filed
  dir=$FAKE_LINEAR_DIR
  log=$dir/log
  json="$(lane)/$DATE.json"
  run_library >/dev/null || fail "a writing run must succeed"
  assert_equals 3 "$(count_lines '^issue create .*--verify' "$log")" "at most 3 new bundle items are created for one audit run"
  assert_equals 3 "$(count_lines '^issue create .*--dry-run' "$log")" "every create is a dry run first"
  assert_equals 3 "$(count_lines '^issue create .*--label Chore --label scheduled-review --label documentation --verify' "$log")" \
    "each item is a Chore with the scheduled-review Source and an area label, in no Linear project"
  assert_no_grep "--project" "$log" "PropertyCompass2 work goes in no Fleet project"
  assert_equals 3 "$(count_lines '^librarian-fp:' "$dir/bodies")" "every body carries its bundle's librarian-fp marker alone on its line"
  assert_equals 5 "$(count_lines '^- \[ \] librarian-fp:' "$dir/bodies")" "and one checklist line per finding, the findings of one audit kind sharing a bundle"
  assert_no_grep "Brief among scripts" "$dir/bodies" "an on-hold finding is never filed"
  assert_no_grep "decision(s) for Lee" "$dir/bodies" "and neither is the run's decisions item"
  assert_contains "$(grep -m1 '^issue create .*--verify' "$log")" "--title Automated findings: conflict (librarian audit)" "the highest-scored finding's bundle (the high conflict) is filed first"
  assert_contains "$(<"$(lane)/$DATE.md")" "Not filed (over max-creates for this run)" "the overflow is named in the digest"
  assert_equals 1 "$(jq '[.asks_for_lee[] | select(.key == "library-needs-lee-2026-10-31")] | length' "$json")" "needs-Lee items are one keyed needs-decision for the run"
  assert_equals 1 "$(jq '.asks_for_lee | length' "$json")" "and only that one"

  run_library >/dev/null || fail "a same-day re-run must succeed"
  assert_equals 3 "$(count_lines '^issue create .*--verify' "$log")" "a re-run files nothing more"
  assert_equals 0 "$(count_lines '^UPDATE' "$dir/updates")" "and rewrites no bundle"
  run_library 2026-11-02 $((NOW + 86400)) >/dev/null || fail "a next-day run must succeed"
  assert_equals 3 "$(count_lines '^issue create .*--verify' "$log")" "the cap is per audit run, so the next day creates nothing"
  assert_equals 0 "$(count_lines '^UPDATE' "$dir/updates")" "and nothing is rewritten for the same audit run"
  assert_equals 0 "$(jq '.asks_for_lee | length' "$(lane)/2026-11-02.json")" "the needs-decision is not repeated for the same audit run"

  # A newer audit run raises the filed items and files the next three.
  write_run "$RUNS/2026-11-07" ok 5
  run_library 2026-11-07 $((NOW + 7 * 86400)) >/dev/null || fail "the next audit's run must succeed"
  assert_equals 6 "$(count_lines '^issue create .*--verify' "$log")" "the next audit run files the findings the cap left"
  assert_equals 0 "$(count_lines '^COMMENT' "$dir/comments")" "a bundle gets no per-finding comment"
  assert_equals true "$(jq '[.items[] | select(.linear.found == 2)] | length > 0' "$(lane)/2026-11-07.json")" "each finding's own found count rises once per audit run, and the digest shows it"
  pass "fm-officer library: findings are filed in Chore bundles, capped per audit run, and each finding's found count rises once per audit run"
}

test_rate_limit_after_a_create_keeps_the_cap() {
  local dir log
  linear_world ratelimit
  dir=$FAKE_LINEAR_DIR
  log=$dir/log
  echo 102 > "$dir/rate-limit-at"
  run_library >/dev/null || fail "a rate-limited run must succeed"
  assert_equals 101 "$(cat "$dir/created")" "one item was created before Linear answered RATE_LIMITED"
  assert_equals 2 "$(count_lines '^issue create .*--verify' "$log")" "the run stops at the rate-limited create"
  rm "$dir/rate-limit-at"
  run_library 2026-11-02 $((NOW + 86400)) >/dev/null || fail "a next-day run must succeed"
  assert_equals 3 "$(count_lines '^issue create .*--verify' "$log")" \
    "the next day attempts only what is left of the audit run's cap of 3, counting the creates before the stop"
  pass "fm-officer library: a rate limit after a create still counts that create against the per-audit-run cap"
}

test_registry_max_creates_is_held_to_three() {
  linear_world bigcap "; max-creates: 10"
  run_library >/dev/null || fail "a run with max-creates 10 must succeed"
  assert_equals 3 "$(count_lines '^issue create .*--verify' "$FAKE_LINEAR_DIR/log")" \
    "a registry max-creates above 3 still creates at most 3 items per audit run (fleet rules section 8)"
  pass "fm-officer library: max-creates above 3 is held to the fleet rules cap"
}

test_safe_findings_start_and_reserved_ones_hold() {
  local json dir
  # bundle-cap 1 gives each finding its own bundle, so each is judged alone (a reserved line holds its whole bundle).
  linear_world starts "; bundle-cap: 1"
  dir=$FAKE_LINEAR_DIR
  json="$(lane)/$DATE.json"
  printf '[%s,%s,%s,%s]\n' \
    "$(finding readme README.md "README undercounts the rules" "Propose changing the count to 29." high)" \
    "$(finding readme docs/terms.md "Terms text is stale" "Propose rewording the terms of service text." high)" \
    "$(finding readme docs/low.md "Low readme note" "Propose a one-line fix.")" \
    "$(finding conflict docs/adr/0003.md "ADR conflict" "Propose a dated successor note." high)" > "$RUNS/2026-10-31/findings.json"
  run_library >/dev/null || fail "a writing run must succeed"
  assert_equals "README undercounts the rules" "$(jq -r '[.start_requests[].title] | join(",")' "$json")" \
    "only the high safe finding with an item starts: a low one has not reached the start score, a needs-Lee one never starts"
  assert_equals "$HOME_DIR" "$(jq -r '.start_requests[0].execute.env.FM_HOME' "$json")" "with no start-home office the request goes to this home"
  assert_contains "$(jq -r '.start_requests[0].execute.request_id' "$json")" "library-$DATE-" "the request id names the library officer"
  assert_contains "$(jq -r '.start_requests[0].execute.argv | join(" ")' "$json")" "fm-inbox.sh note --request-id" "it is the progress officer's fm-inbox.sh note call"
  assert_equals 1 "$(count_lines 'fm-inbox.sh' "$(lane)/$DATE.start-requests.sh")" "this home's request is in the shell handoff"
  assert_equals library-officer "$(jq -r .source "$json")" "the digest names its source so an office delivers its requests"
  assert_equals "Terms text is stale" "$(jq -r '.held[0].title' "$json")" "a safe finding that asks for legal text is held"
  assert_equals "legal" "$(jq -r '.held[0].class' "$json")" "with its reserved class"
  assert_equals "library-holds-$DATE library-needs-lee-2026-10-31" "$(jq -r '[.asks_for_lee[].key] | join(" ")' "$json")" "held and needs-Lee items are each one keyed needs-decision"
  assert_equals 3 "$(count_lines '^issue create .*--verify' "$dir/log")" "the three highest-scored findings are filed under the cap, held ones included"
  run_library >/dev/null || fail "a same-day re-run must succeed"
  assert_equals 1 "$(jq '.start_requests | length' "$json")" "a re-run repeats the same request"
  run_library 2026-11-02 $((NOW + 86400)) >/dev/null || fail "a next-day run must succeed"
  assert_equals 0 "$(jq '.start_requests | length' "$(lane)/2026-11-02.json")" "a later day never asks for the item again"
  pass "fm-officer library: a safe finding starts, a reserved class holds, and needs-Lee items hold"
}

test_start_requests_reach_the_owning_office() {
  local json
  linear_world office
  json="$(lane)/$DATE.json"
  mkdir -p "$TMP_ROOT/office/navhome"
  printf '[%s]\n' "$(finding readme README.md "README undercounts the rules" "Propose changing the count to 29." high)" > "$RUNS/2026-10-31/findings.json"
  FM_OFFICER_NOW="$NOW" FM_HOME="$HOME_DIR" python3 -I "$ROOT/bin/fm-officer-library.py" run --audit "$RUNS" --date "$DATE" \
    --out "$(lane)" --now "$NOW" --writes linear --jev /nonexistent/jev.py --fm-home "$HOME_DIR" \
    --start-home "$TMP_ROOT/office/navhome=PropertyCompass2=navigator=work" >/dev/null || fail "a run with an office must succeed"
  assert_equals "$TMP_ROOT/office/navhome" "$(jq -r '.start_requests[0].execute.env.FM_HOME' "$json")" "a PropertyCompass2 finding goes to the office that dispatches it"
  assert_equals 0 "$(count_lines 'fm-inbox.sh' "$(lane)/$DATE.start-requests.sh")" "and not into this home's handoff"
  pass "fm-officer library: a start request is addressed to the office that owns the repository"
}

test_no_writes_and_a_missing_label_file_nothing() {
  local dir
  make_world nowrites
  export FAKE_LINEAR_DIR="$TMP_ROOT/nowrites/linear"
  mkdir -p "$FAKE_LINEAR_DIR"
  run_library >/dev/null || fail "a writes: none run must succeed"
  assert_equals gone "$([ -e "$FAKE_LINEAR_DIR/log" ] && echo called || echo gone)" "writes: none makes no Linear call at all"
  assert_equals 0 "$(jq '.start_requests | length' "$(lane)/$DATE.json")" "and starts nothing"

  linear_world nolabel
  dir=$FAKE_LINEAR_DIR
  printf '%s\n' Bug Chore documentation > "$dir/labels.txt"
  run_library >/dev/null || fail "a run with a missing label must succeed"
  assert_equals 0 "$(count_lines '^issue create' "$dir/log")" "with the Source label missing nothing is created"
  assert_contains "$(jq -r '[.items[].linear.reason // empty] | join(" ")' "$(lane)/$DATE.json")" "label(s) not found in team PC: scheduled-review" "the finding is reported with the label named"
  pass "fm-officer library: writes: none and a missing label file and start nothing"
}

test_buckets
test_archive_is_safe_but_delete_retire_and_outside_pr_need_lee
test_reported_once_and_identical_rerun
test_hold_item_counts_once_it_can_ship
test_unreadable_audit_keeps_the_ledger
test_coverage_gaps_never_fail_the_run
test_run_writes_only_its_lane
test_findings_are_filed_capped_per_audit_run_and_found_raised
test_rate_limit_after_a_create_keeps_the_cap
test_registry_max_creates_is_held_to_three
test_safe_findings_start_and_reserved_ones_hold
test_start_requests_reach_the_owning_office
test_no_writes_and_a_missing_label_file_nothing
