#!/usr/bin/env bash
# Behavior tests for bin/fm-office.sh: list and ensure over data/offices.md,
# status over an office home's backlog, and arm-status / disarm-status for its
# silent watcher check, against a fixture primary home and local office homes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OFFICE="$ROOT/bin/fm-office.sh"
TMP_ROOT=$(fm_test_tmproot fm-office)
export FM_OFFICE_HOST=slartibartfast

NAV='- navigator - Drive progress (role: navigator; runs-on: slartibartfast; dispatch: PropertyCompass2; merge: none; merge-via: PropertyCompass2=slarti; auto-merge-classes: none; wip: 2; tick: every 2h; sources: tick,lane:progress; added 2026-11-04)'
QM='- quartermaster - Drive fleet self-improvement (role: quartermaster; runs-on: slartibartfast; dispatch: firstmate,skills; merge: firstmate,skills; merge-via: none; auto-merge-classes: none; wip: 2; tick: every 4h; sources: tick,lane:friction; added 2026-11-04)'

# make_world <name>: a primary home with both offices registered and healthy.
make_world() {
  local w="$TMP_ROOT/$1" id
  mkdir -p "$w/data"
  for id in navigator quartermaster; do
    mkdir -p "$w/$id/data"
    printf '%s\n' "$id" > "$w/$id/.fm-office"
    printf '# Charter\n\n# Office authority\n' > "$w/$id/data/charter.md"
    printf -- '- %s - office (home: %s/%s; scope: office; projects: none; added 2026-11-04)\n' "$id" "$w" "$id" >> "$w/data/secondmates.md"
  done
  printf -- '- PropertyCompass2 [direct-PR merger=slarti] - app (added 2026-10-02)\n' > "$w/navigator/data/projects.md"
  printf -- '- firstmate [no-mistakes admission=fm] - fm (added 2026-10-02)\n- skills [no-mistakes admission=sk] - skills (added 2026-10-02)\n' > "$w/quartermaster/data/projects.md"
  printf -- '- progress - x (role: progress; cadence: daily 07:00; added 2026-10-26)\n- friction - y (role: friction; cadence: daily 06:15; added 2026-10-24)\n' > "$w/data/officers.md"
  printf '# Offices\n\n%s\n%s\n' "$NAV" "$QM" > "$w/data/offices.md"
  printf '%s\n' "$w"
}

ensure() { FM_HOME="$1" FM_DATA_OVERRIDE="$1/data" bash "$OFFICE" ensure; }

test_healthy_registry_prints_nothing() {
  local w out
  w=$(make_world healthy)
  out=$(ensure "$w")
  assert_equals "" "$out" "ensure output"
  out=$(FM_HOME="$w" FM_DATA_OVERRIDE="$w/data" bash "$OFFICE" list)
  assert_equals "navigator navigator ok
quartermaster quartermaster ok" "$out" "list output"
  pass 'a healthy registry prints nothing from ensure and ok from list'
}

test_absent_registry_means_no_offices() {
  local w
  w=$(make_world absent)
  rm "$w/data/offices.md"
  assert_equals "" "$(ensure "$w")" "ensure output"
  assert_equals "" "$(FM_HOME="$w" FM_DATA_OVERRIDE="$w/data" bash "$OFFICE" list)" "list output"
  pass 'an absent data/offices.md means no offices'
}

# edit_file <file> <cmd...>: rewrite <file> through <cmd>, portable across GNU and BSD.
edit_file() {
  local f=$1
  shift
  "$@" "$f" > "$f.new" && mv "$f.new" "$f"
}

# gap_case <name> <expected substring> <mutation command run in $w>
gap_case() {
  local name=$1 expect=$2 w out
  w=$(make_world "$name")
  (cd "$w" && eval "$3")
  out=$(ensure "$w")
  assert_contains "$out" "OFFICE: office " "$name prefix"
  assert_contains "$out" "$expect" "$name gap"
  pass "ensure reports: $expect"
}

test_gaps() {
  gap_case macbook 'host not allowed: macbook' "edit_file data/offices.md sed 's/runs-on: slartibartfast; dispatch: Property/runs-on: macbook; dispatch: Property/'"
  gap_case role 'unknown role "wizard"' "edit_file data/offices.md sed 's/role: navigator/role: wizard/'"
  gap_case wip 'wip must be' "edit_file data/offices.md sed 's/wip: 2; tick: every 2h/wip: 0; tick: every 2h/'"
  gap_case tick 'tick must be' "edit_file data/offices.md sed 's/tick: every 2h/tick: hourly/'"
  gap_case auto 'auto-merge-classes must be none' "edit_file data/offices.md awk '!d && sub(/auto-merge-classes: none/, \"auto-merge-classes: docs\") { d = 1 } 1'"
  gap_case lane 'lane:nope is not a registered officer' "edit_file data/offices.md sed 's/lane:progress/lane:nope/'"
  gap_case notmate 'not a registered second mate' ": > data/secondmates.md"
  gap_case hostmismatch 'does not include the second mate host' "edit_file data/secondmates.md sed 's/(home:/(host: deepthought; root: \\/r; home:/'"
  gap_case marker '.fm-office marker missing' "rm navigator/.fm-office"
  gap_case charter 'lacks the "# Office authority" heading' "printf '# Charter\n' > navigator/data/charter.md"
  gap_case project 'dispatch project PropertyCompass2 is not in' ": > navigator/data/projects.md"
  gap_case admission 'merge project firstmate has no admission=' "edit_file quartermaster/data/projects.md sed 's/ admission=fm//'"
  gap_case merger 'merge-via project PropertyCompass2 lacks merger=slarti' "edit_file navigator/data/projects.md sed 's/ merger=slarti//'"
  gap_case subset 'merge project skills is not in dispatch' "edit_file data/offices.md sed 's/dispatch: firstmate,skills/dispatch: firstmate/'"
  gap_case overlap 'merge-via project firstmate overlaps merge' "edit_file data/offices.md sed 's/merge-via: none/merge-via: firstmate=slarti/'"
  gap_case malformed 'malformed registry line' "printf -- '- broken line\n' >> data/offices.md"
}

test_list_counts_gaps() {
  local w out
  w=$(make_world listgaps)
  rm "$w/navigator/.fm-office"
  out=$(FM_HOME="$w" FM_DATA_OVERRIDE="$w/data" bash "$OFFICE" list)
  assert_contains "$out" "navigator navigator gaps:1" "navigator gaps"
  assert_contains "$out" "quartermaster quartermaster ok" "quartermaster ok"
  pass 'list shows the gap count per office'
}

test_ensure_changes_nothing() {
  local w before after
  w=$(make_world readonly)
  rm "$w/navigator/.fm-office"
  before=$(find "$w" -type f -exec cksum {} + | sort)
  ensure "$w" >/dev/null
  after=$(find "$w" -type f -exec cksum {} + | sort)
  assert_equals "$before" "$after" "files after ensure"
  pass 'ensure is read-only'
}

# --- status: the office-status.json projection --------------------------------
NOW=1793786700 # 2026-11-04T10:05:00Z

status() { FM_HOME="$1/navigator" FM_OFFICE_NOW="${2:-$NOW}" bash "$OFFICE" status; }
card() { jq -c --arg id "$2" '.cards[] | select(.id == $id)' "$1/navigator/data/office-status.json"; }

# status_world <name>: the healthy world plus a navigator backlog with two in-flight,
# twelve queued (one held for Lee) and three done items.
status_world() {
  local w i
  w=$(make_world "$1")
  mkdir -p "$w/navigator/state"
  {
    printf '## In flight\n'
    printf -- '- [ ] pc-4701-fix - Fix the thing (repo: PropertyCompass2) (kind: ship) (since 2026-11-03)\n  Main corr abc.\n'
    printf -- '- [ ] pc-4702-body - Body link (repo: PropertyCompass2) (kind: ship) (since 2026-11-04)\n  PR https://github.com/lstutzman/PropertyCompass2/pull/4702 is open.\n'
    printf '\n## Queued\n'
    printf -- '- [ ] q-held - Needs Lee (repo: PropertyCompass2) (kind: task) (since 2026-11-01) (hold: fm-hold-v1:abc) (hold-kind: captain)\n'
    for i in 1 2 3 4 5 6 7 8 9 10 11; do
      printf -- '- [ ] q-%s - Queued item %s https://linear.app/x/issue/PC-47%s (repo: PropertyCompass2) (kind: task) (since 2026-11-01)\n' "$i" "$i" "$i"
    done
    printf '\n## Done\n'
    printf -- '- [x] d-today - Finished today https://github.com/lstutzman/PropertyCompass2/pull/4690 (repo: PropertyCompass2) (kind: ship) (merged 2026-11-04)\n'
    printf -- '- [x] d-old - Finished long ago (repo: PropertyCompass2) (kind: ship) (merged 2026-11-01)\n'
    printf -- '- [x] d-yesterday - Finished yesterday (repo: PropertyCompass2) (kind: ship) (done 2026-11-03)\n'
  } > "$w/navigator/data/backlog.md"
  printf 'pr=https://github.com/lstutzman/PropertyCompass2/pull/4701\nkind=ship\n' > "$w/navigator/state/pc-4701-fix.meta"
  printf '%s\n' "$w"
}

test_status_working_lane() {
  local w out
  w=$(status_world st-working)
  out=$(status "$w" 2>&1)
  assert_equals "" "$out" "status output"
  assert_equals "navigator Navigator 1" "$(jq -r '[.office, .title, .schema_version] | join(" ")' "$w/navigator/data/office-status.json")" "header"
  assert_equals "2026-11-04T10:05:00Z" "$(jq -r .written_at "$w/navigator/data/office-status.json")" "written_at"
  assert_equals '{"id":"pc-4701-fix","title":"Fix the thing","state":"working","link":"https://github.com/lstutzman/PropertyCompass2/pull/4701","since":"2026-11-03T00:00:00Z"}' "$(card "$w" pc-4701-fix)" "meta pr= link wins"
  assert_contains "$(card "$w" pc-4702-body)" '"link":"https://github.com/lstutzman/PropertyCompass2/pull/4702"' "body link"
  pass 'status lists every in-flight item as working, linking the task pr= or the row URL'
}

test_status_next_lane() {
  local w
  w=$(status_world st-next)
  status "$w"
  assert_equals "10" "$(jq '[.cards[] | select(.state == "next")] | length' "$w/navigator/data/office-status.json")" "next cap"
  assert_equals "q-held q-1 q-2" "$(jq -r '[.cards[] | select(.state == "next") | .id][:3] | join(" ")' "$w/navigator/data/office-status.json")" "next order"
  assert_equals '{"id":"q-held","title":"Needs Lee","state":"next","link":"","waiting":"Lee"}' "$(card "$w" q-held)" "held for Lee"
  assert_equals '{"id":"q-1","title":"Queued item 1","state":"next","link":"https://linear.app/x/issue/PC-471","waiting":""}' "$(card "$w" q-1)" "url stripped from title and kept as link"
  assert_equals "" "$(card "$w" q-10)" "eleventh queued item left out"
  pass 'status lists the first 10 queued items in order and marks a captain hold as waiting on Lee'
}

test_status_done_window() {
  local w
  w=$(status_world st-done)
  status "$w"
  assert_equals '{"id":"d-today","title":"Finished today","state":"done","link":"https://github.com/lstutzman/PropertyCompass2/pull/4690","done_at":"2026-11-04T00:00:00Z"}' "$(card "$w" d-today)" "done today"
  assert_equals "" "$(card "$w" d-yesterday)" "item closed yesterday dropped"
  assert_equals "" "$(card "$w" d-old)" "item closed days ago dropped"
  pass 'status shows a done item closed today (UTC) and drops ones closed on an earlier day'
}

test_status_done_close_day_boundary() {
  local w
  w=$(status_world st-boundary)
  status "$w" 1793833200 # 2026-11-04T23:00:00Z
  assert_contains "$(card "$w" d-today)" '"done_at":"2026-11-04T00:00:00Z"' "23:00 on the close day"
  status "$w" 1793836799 # 2026-11-04T23:59:59Z
  assert_contains "$(card "$w" d-today)" '"state":"done"' "last second of the close day"
  status "$w" 1793836800 # 2026-11-05T00:00:00Z
  assert_equals "" "$(card "$w" d-today)" "00:00 the next day"
  pass 'a done card shows through its close day and is gone from 00:00 UTC the next day'
}

test_status_done_cards_survive_reruns() {
  local w first
  w=$(status_world st-rerun)
  done_cards() { jq -c '[.cards[] | select(.state == "done")]' "$w/navigator/data/office-status.json"; }
  status "$w"
  first=$(done_cards)
  assert_contains "$first" '"id":"d-today"' "first run"
  status "$w" $((NOW + 3600))
  assert_equals "$first" "$(done_cards)" "second run"
  rm "$w/navigator/data/office-status.json"
  status "$w" $((NOW + 7200))
  assert_equals "$first" "$(done_cards)" "run after the previous file was deleted"
  printf 'not json\n' > "$w/navigator/data/office-status.json"
  status "$w" $((NOW + 7300))
  assert_equals "$first" "$(done_cards)" "run after the previous file was corrupted"
  pass 'done cards are the same on a rerun and after the previous file is deleted or corrupt'
}

test_status_skips_unchanged_write() {
  local w ino
  w=$(status_world st-same)
  status "$w"
  ino=$(ls -i "$w/navigator/data/office-status.json")
  status "$w" $((NOW + 300))
  assert_equals "$ino" "$(ls -i "$w/navigator/data/office-status.json")" "file replaced although nothing changed"
  assert_equals "2026-11-04T10:05:00Z" "$(jq -r .written_at "$w/navigator/data/office-status.json")" "written_at untouched"
  status "$w" $((NOW + 1000))
  assert_equals "2026-11-04T10:21:40Z" "$(jq -r .written_at "$w/navigator/data/office-status.json")" "heartbeat refresh"
  printf -- '- [ ] q-new - New item (repo: PropertyCompass2) (kind: task) (since 2026-11-04)\n' >> "$w/navigator/data/backlog.md"
  status "$w" $((NOW + 1060))
  assert_equals "2026-11-04T10:22:40Z" "$(jq -r .written_at "$w/navigator/data/office-status.json")" "rewrite on change"
  pass 'status rewrites only on a change or after the refresh interval'
}

test_status_writes_only_its_file() {
  local w before after
  w=$(status_world st-only)
  before=$(find "$w" -type f ! -name office-status.json -exec cksum {} + | sort)
  status "$w"
  after=$(find "$w" -type f ! -name office-status.json -exec cksum {} + | sort)
  assert_equals "$before" "$after" "files other than office-status.json"
  assert_equals "" "$(find "$w/navigator/data" -name '.office-status.*')" "temp files left behind"
  pass 'status writes only data/office-status.json'
}

test_status_outside_an_office_does_nothing() {
  local w
  w=$(status_world st-plain)
  rm "$w/navigator/.fm-office"
  assert_equals "" "$(status "$w" 2>&1)" "output"
  assert_absent "$w/navigator/data/office-status.json"
  pass 'status does nothing in a home with no .fm-office marker'
}

test_status_without_a_backlog_is_empty() {
  local w
  w=$(make_world st-empty)
  status "$w"
  assert_equals "[]" "$(jq -c .cards "$w/navigator/data/office-status.json")" "cards"
  pass 'status writes an empty card list when the office has no backlog'
}

# --- arm-status / disarm-status: the silent status check -----------------------
arm() { FM_HOME="$1/navigator" bash "$OFFICE" "${2:-arm-status}"; }
check_registered() {
  (. "$ROOT/bin/fm-pr-lib.sh" && . "$ROOT/bin/fm-check-lib.sh" && fm_custom_check_registered "$1/navigator/state" office-status)
}

test_arm_status_registers_a_silent_check() {
  local w shim out before
  w=$(status_world arm)
  out=$(arm "$w" 2>&1)
  assert_equals "" "$out" "arm output"
  shim="$w/navigator/state/office-status.check.sh"
  [ -x "$shim" ] || fail "check is not executable"
  assert_equals "700" "$(stat -c %a "$shim" 2>/dev/null || stat -f %Lp "$shim")" "check mode"
  check_registered "$w" || fail "check is not bound by its trust file"
  before=$(cksum "$shim" "$w/navigator/state/office-status.check-trust")
  arm "$w"
  assert_equals "$before" "$(cksum "$shim" "$w/navigator/state/office-status.check-trust")" "second arm"
  out=$(cd / && env -u FM_HOME "$shim" 2>&1)
  assert_equals "" "$out" "check output"
  assert_equals "navigator" "$(jq -r .office "$w/navigator/data/office-status.json")" "check wrote the projection"
  pass 'arm-status writes and binds a check that runs status silently, and arming twice changes nothing'
}

test_disarm_status_retires_the_check() {
  local w
  w=$(status_world disarm)
  arm "$w"
  arm "$w" disarm-status
  assert_absent "$w/navigator/state/office-status.check.sh"
  assert_absent "$w/navigator/state/office-status.check-trust"
  arm "$w" disarm-status || fail "disarming an unarmed office failed"
  pass 'disarm-status removes the check and its trust file'
}

test_arm_status_refuses_outside_an_office() {
  local w err cmd
  w=$(status_world arm-plain)
  rm "$w/navigator/.fm-office"
  for cmd in arm-status disarm-status; do
    if err=$(arm "$w" "$cmd" 2>&1 >/dev/null); then fail "$cmd succeeded outside an office home"; fi
    assert_contains "$err" "no .fm-office marker" "$cmd stderr"
  done
  assert_absent "$w/navigator/state/office-status.check.sh"
  pass 'arm-status and disarm-status refuse in a home with no .fm-office marker'
}

test_healthy_registry_prints_nothing
test_absent_registry_means_no_offices
test_gaps
test_list_counts_gaps
test_ensure_changes_nothing
test_status_working_lane
test_status_next_lane
test_status_done_window
test_status_done_close_day_boundary
test_status_done_cards_survive_reruns
test_status_skips_unchanged_write
test_status_writes_only_its_file
test_status_outside_an_office_does_nothing
test_status_without_a_backlog_is_empty
test_arm_status_registers_a_silent_check
test_disarm_status_retires_the_check
test_arm_status_refuses_outside_an_office
