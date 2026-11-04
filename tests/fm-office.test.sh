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

seen() { jq -c . "$1/navigator/state/office-status.seen.json"; }

test_status_done_window() {
  local w
  w=$(status_world st-done)
  status "$w"
  assert_equals '{"id":"d-today","title":"Finished today","state":"done","link":"https://github.com/lstutzman/PropertyCompass2/pull/4690","done_at":"2026-11-04T10:05:00Z"}' "$(card "$w" d-today)" "done today, stamped at first sight"
  assert_equals '{"id":"d-yesterday","title":"Finished yesterday","state":"done","link":"","done_at":"2026-11-04T10:05:00Z"}' "$(card "$w" d-yesterday)" "dated yesterday, first seen now"
  assert_equals "" "$(card "$w" d-old)" "dated before yesterday"
  assert_equals '{"d-today":"2026-11-04T10:05:00Z","d-yesterday":"2026-11-04T10:05:00Z"}' "$(seen "$w")" "seen stamps"
  pass 'status stamps done items dated today or yesterday at first sight and never shows older ones'
}

test_status_done_shows_24_hours_from_first_sight() {
  local w first last gone want
  for first in 1793782800 1793835600; do # 2026-11-04T09:00:00Z, 2026-11-04T23:40:00Z
    case $first in
      1793782800) want=2026-11-04T09:00:00Z last=1793869140 gone=1793869260 ;; # 2026-11-05T08:59Z, 09:01Z
      *) want=2026-11-04T23:40:00Z last=1793921940 gone=1793922060 ;;           # 2026-11-05T23:39Z, 23:41Z
    esac
    w=$(status_world "st-24h-$first")
    status "$w" "$first"
    assert_contains "$(card "$w" d-today)" "\"done_at\":\"$want\"" "first sight at $want"
    status "$w" "$last"
    assert_contains "$(card "$w" d-today)" "\"done_at\":\"$want\"" "23h59m after $want"
    status "$w" "$gone"
    assert_equals "" "$(card "$w" d-today)" "24h01m after $want"
    status "$w" $((gone + 600))
    assert_equals "" "$(card "$w" d-today)" "a later run after $want"
    rm "$w/navigator/data/office-status.json"
    status "$w" $((gone + 1200))
    assert_equals "" "$(card "$w" d-today)" "a run after the projection was deleted ($want)"
  done
  pass 'a done card shows for 24 hours from its own first sight and never comes back'
}

test_status_seen_file_loss_keeps_old_items_out() {
  local w
  w=$(status_world st-seen-lost)
  mkdir -p "$w/navigator/state"
  printf 'not json\n' > "$w/navigator/state/office-status.seen.json"
  status "$w"
  assert_equals "" "$(card "$w" d-old)" "corrupt seen file"
  rm "$w/navigator/state/office-status.seen.json"
  status "$w" $((NOW + 60))
  assert_equals "" "$(card "$w" d-old)" "deleted seen file"
  assert_equals "null" "$(jq '."d-old"' "$w/navigator/state/office-status.seen.json")" "old item never stamped"
  pass 'a corrupt or missing seen file does not bring back an item dated before yesterday'
}

test_status_prunes_old_stamps() {
  local w
  w=$(status_world st-prune)
  status "$w"
  status "$w" 1794305100 # 2026-11-10T10:05:00Z, six days later
  assert_equals '{"d-today":"2026-11-04T10:05:00Z","d-yesterday":"2026-11-04T10:05:00Z"}' "$(seen "$w")" "stamps within 7 days kept"
  status "$w" 1794391560 # 2026-11-11T10:06:00Z, seven days and a minute later
  assert_equals '{}' "$(seen "$w")" "stamps older than 7 days pruned"
  assert_equals "" "$(card "$w" d-today)" "pruned item not shown again"
  pass 'status prunes seen stamps older than 7 days'
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
  before=$(find "$w" -type f ! -name office-status.json ! -name office-status.seen.json -exec cksum {} + | sort)
  status "$w"
  after=$(find "$w" -type f ! -name office-status.json ! -name office-status.seen.json -exec cksum {} + | sort)
  assert_equals "$before" "$after" "files other than office-status.json and office-status.seen.json"
  [ -f "$w/navigator/state/office-status.seen.json" ] || fail "seen file not written"
  assert_equals "" "$(find "$w/navigator" -name '.office-status.*')" "temp files left behind"
  pass 'status writes only data/office-status.json and state/office-status.seen.json'
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

# ---- wake sources: register-sources and check ----

SRC_NOW=1793700000   # a fixed instant; TZ=UTC below
export TZ=UTC
SLOT=$(date -u -d "@$SRC_NOW" +%Y-%m-%dT%H 2>/dev/null || date -u -r "$SRC_NOW" +%Y-%m-%dT%H)

# source_world <name>: make_world plus the parent binding every office home carries.
source_world() {
  local w
  w=$(make_world "$1")
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$w" > "$w/navigator/.fm-secondmate-parent"
  mkdir -p "$w/navigator/state" "$w/data/officers/progress" "$w/data/officers/surgeon"
  sed -i.bak 's/sources: tick,lane:progress;/sources: tick,lane:progress,lane:surgeon:high;/' "$w/data/offices.md" && rm -f "$w/data/offices.md.bak"
  printf -- '- surgeon - z (role: triage; cadence: daily 06:00; added 2026-10-24)\n' >> "$w/data/officers.md"
  printf '%s\n' "$w"
}

# nav_check <world> <source>: the office's check, run as its shim would.
nav_check() { FM_OFFICE_NOW=$SRC_NOW FM_HOME="$1/navigator" bash "$OFFICE" check "$2"; }

put_backlog() {  # <world> <queued lines...>
  local w=$1
  shift
  { printf '## In flight\n\n## Queued\n'; printf '%s\n' "$@"; printf '\n## Done\n'; } > "$w/navigator/data/backlog.md"
}

put_digest() {  # <world> <officer> <key> <n>
  printf 'DIGEST %s %s data/officers/%s/%s.md\n' "$3" "$4" "$2" "$3" > "$1/data/officers/$2/digest"
}

test_register_sources_installs_trusted_shims() {
  local w out
  w=$(source_world reg)
  out=$(FM_HOME="$w/navigator" bash "$OFFICE" register-sources) || fail "register-sources must succeed: $out"
  assert_contains "$out" "registered: office source tick (state/office-tick.check.sh)" "tick registered"
  assert_contains "$out" "state/office-lane-progress.check.sh" "lane registered"
  assert_contains "$out" "state/office-lane-surgeon-high.check.sh" "high lane registered"
  assert_present "$w/navigator/state/office-tick.check-trust" "the shim is trusted"
  assert_contains "$(cat "$w/navigator/state/office-lane-progress.check.sh")" "fm-office.sh check lane:progress" "the shim runs the lane check"
  assert_contains "$(cat "$w/navigator/state/office-lane-surgeon-high.check.sh")" "fm-office.sh check lane:surgeon:high" "the shim runs the high check"
  assert_contains "$(cat "$w/navigator/state/office-tick.check.sh")" "FM_HOME=$(cd "$w/navigator" && pwd -P)" "the shim points at the office's own home"
  assert_absent "$w/state/office-tick.check.sh" "nothing is registered in the parent"
  before=$(find "$w/navigator/state" -type f -exec cksum {} + | sort)
  FM_HOME="$w/navigator" bash "$OFFICE" register-sources >/dev/null || fail "second register-sources must succeed"
  assert_equals "$before" "$(find "$w/navigator/state" -type f -exec cksum {} + | sort)" "re-registering is idempotent"
  # a source dropped from the registry line is unregistered
  sed -i.bak 's/sources: tick,lane:progress,lane:surgeon:high;/sources: tick;/' "$w/data/offices.md" && rm -f "$w/data/offices.md.bak"
  out=$(FM_HOME="$w/navigator" bash "$OFFICE" register-sources) || fail "register-sources after edit must succeed"
  assert_contains "$out" "unregistered: state/office-lane-progress.check.sh" "a dropped source is unregistered"
  assert_absent "$w/navigator/state/office-lane-progress.check.sh" "its shim is gone"
  assert_absent "$w/navigator/state/office-lane-progress.check-trust" "its trust is gone"
  assert_present "$w/navigator/state/office-tick.check.sh" "listed sources stay"
  out=$(FM_HOME="$w" FM_DATA_OVERRIDE="$w/data" bash "$OFFICE" register-sources 2>&1) && fail "register-sources must refuse a non-office home"
  assert_contains "$out" "only in an office home" "the refusal says why"
  pass 'register-sources installs trusted per-source shims, idempotently, and drops unlisted ones'
}

test_register_sources_keeps_the_status_check() {
  local w
  w=$(source_world keepstatus)
  arm "$w" || fail "arm-status must succeed"
  FM_HOME="$w/navigator" bash "$OFFICE" register-sources >/dev/null || fail "register-sources must succeed"
  check_registered "$w" || fail "register-sources unregistered the status check"
  assert_present "$w/navigator/state/office-status.check.sh" "the status check stays"
  pass 'register-sources leaves the armed status check registered'
}

test_shim_runs_through_the_watcher_trust_path() {
  local w out
  w=$(source_world shim)
  FM_HOME="$w/navigator" bash "$OFFICE" register-sources >/dev/null || fail "register-sources must succeed"
  put_backlog "$w" '- [ ] job-a - Do a thing (repo: PropertyCompass2) (kind: ship)'
  out=$(FM_OFFICE_NOW=$SRC_NOW bash "$w/navigator/state/office-tick.check.sh") || fail "shim must exit 0"
  assert_contains "$out" "office navigator: tick $SLOT: 2 of 2 places free, 1 queued" "the shim prints the tick line"
  pass 'a registered shim runs the check with the office home'
}

test_tick_prints_once_per_slot_and_only_when_work_could_start() {
  local w out
  w=$(source_world tick)
  assert_equals "" "$(nav_check "$w" tick)" "nothing queued and no digest: silent"
  put_backlog "$w" '- [ ] held-1 - Held (repo: x) (kind: captain) (hold: captain choice) (hold-kind: captain)' '- [ ] blocked-1 - Blocked blocked-by: other - why (repo: x)'
  assert_equals "" "$(nav_check "$w" tick)" "held and blocked items do not count as queued"
  put_backlog "$w" '- [ ] job-a - A (repo: x) (kind: ship)' '- [ ] job-b - B (repo: x) (kind: ship)' '- [ ] held-1 - Held (repo: x) (hold: c)'
  out=$(nav_check "$w" tick)
  assert_equals "office navigator: tick $SLOT: 2 of 2 places free, 2 queued" "$out" "tick line"
  assert_equals "" "$(nav_check "$w" tick)" "the slot was already reported"
  out=$(FM_OFFICE_NOW=$((SRC_NOW + 7200)) FM_HOME="$w/navigator" bash "$OFFICE" check tick)
  assert_contains "$out" "tick " "the next slot reports again"
  assert_contains "$out" "2 queued" "next slot count"
  pass 'tick prints once per slot, counts only unheld unblocked queued items, and is silent with nothing to start'
}

test_tick_is_silent_when_places_are_full() {
  local w
  w=$(source_world full)
  put_backlog "$w" '- [ ] job-a - A (repo: x) (kind: ship)'
  printf 'kind=ship\nproject=x\n' > "$w/navigator/state/t1.meta"
  printf 'kind=scout\nproject=x\n' > "$w/navigator/state/t2.meta"
  assert_equals "" "$(nav_check "$w" tick)" "both places taken: silent"
  rm "$w/navigator/state/t2.meta"
  assert_contains "$(nav_check "$w" tick)" "1 of 2 places free, 1 queued" "one place free"
  printf 'kind=secondmate\n' > "$w/navigator/state/m1.meta"
  rm -f "$w/navigator/data/office/tick.seen"
  assert_contains "$(nav_check "$w" tick)" "1 of 2 places free" "a second mate record holds no place"
  pass 'tick counts live ship and scout records against wip and is silent when none is free'
}

test_tick_counts_unread_lane_digests() {
  local w out
  w=$(source_world tickdigest)
  put_digest "$w" progress 2026-11-04 3
  out=$(nav_check "$w" tick)
  assert_equals "office navigator: tick $SLOT: 2 of 2 places free, 0 queued, 1 unread digest(s)" "$out" "an unread digest lets the tick fire"
  nav_check "$w" lane:progress >/dev/null
  rm -f "$w/navigator/data/office/tick.seen"
  assert_equals "" "$(nav_check "$w" tick)" "a reported digest no longer counts as unread"
  pass 'tick fires for an unread lane digest even with nothing queued'
}

test_lane_check_reports_each_new_digest_once() {
  local w out
  w=$(source_world lane)
  assert_equals "" "$(nav_check "$w" lane:progress)" "no digest file: silent"
  put_digest "$w" progress 2026-11-04 0
  assert_equals "" "$(nav_check "$w" lane:progress)" "an empty digest: silent"
  put_digest "$w" progress 2026-11-04 4
  out=$(nav_check "$w" lane:progress)
  assert_equals "office navigator: progress digest 2026-11-04: 4 finding(s) in $w/data/officers/progress/2026-11-04.md" "$out" "lane line"
  assert_equals "" "$(nav_check "$w" lane:progress)" "a repeat: silent"
  put_digest "$w" progress 2026-11-05 1
  assert_contains "$(nav_check "$w" lane:progress)" "digest 2026-11-05: 1 finding(s)" "a new digest reports"
  pass 'a lane check prints once per new digest and ignores repeats and empty digests'
}

test_lane_check_reads_a_spaced_sources_list() {
  local w
  w=$(source_world spaced)
  sed -i.bak 's/sources: tick,lane:progress,/sources: tick, lane:progress, /' "$w/data/offices.md" && rm -f "$w/data/offices.md.bak"
  put_digest "$w" progress 2026-11-04 2
  assert_contains "$(nav_check "$w" lane:progress)" "progress digest 2026-11-04: 2 finding(s)" "a source listed after a comma and space still reports"
  pass 'a lane check finds its source in a sources list with spaces after the commas'
}

test_lane_check_is_silent_when_it_cannot_read() {
  local w
  w=$(source_world unreadable)
  put_digest "$w" progress 2026-11-04 4
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=elsewhere\n' > "$w/navigator/.fm-secondmate-parent"
  assert_equals "" "$(nav_check "$w" lane:progress)" "a remote parent: silent"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$w" > "$w/navigator/.fm-secondmate-parent"
  chmod 000 "$w/data/officers/progress/digest"
  [ -r "$w/data/officers/progress/digest" ] || assert_equals "" "$(nav_check "$w" lane:progress)" "an unreadable file: silent"
  chmod 644 "$w/data/officers/progress/digest"
  assert_equals "" "$(nav_check "$w" lane:nope)" "an unregistered source: silent"
  rm "$w/navigator/.fm-secondmate-parent"
  assert_equals "" "$(nav_check "$w" lane:progress)" "no parent binding: silent"
  assert_equals "" "$(FM_OFFICE_NOW=$SRC_NOW FM_HOME="$w" bash "$OFFICE" check lane:progress)" "a non-office home: silent"
  pass 'checks are silent for a remote parent, an unreadable file, an unregistered source and a non-office home'
}

test_high_lane_counts_only_high_severity() {
  local w out
  w=$(source_world high)
  put_digest "$w" surgeon 2026-11-04 3
  printf '{"findings": [{"severity": "low"}, {"severity": 2}, {"severity": 3}]}\n' > "$w/data/officers/surgeon/2026-11-04.json"
  assert_equals "" "$(nav_check "$w" lane:surgeon:high)" "no high finding: silent"
  printf '{"findings": [{"severity": "high"}, {"severity": 5}, {"severity": "low"}]}\n' > "$w/data/officers/surgeon/2026-11-04.json"
  out=$(nav_check "$w" lane:surgeon:high)
  assert_equals "office navigator: surgeon digest 2026-11-04: 2 high-severity finding(s) in $w/data/officers/surgeon/2026-11-04.md" "$out" "high line"
  assert_equals "" "$(nav_check "$w" lane:surgeon:high)" "no new high finding: silent"
  printf '{"findings": [{"severity": "critical"}, {"severity": 4}, {"severity": "high"}]}\n' > "$w/data/officers/surgeon/2026-11-04.json"
  assert_contains "$(nav_check "$w" lane:surgeon:high)" "3 high-severity finding(s)" "a larger count reports again"
  printf 'not json\n' > "$w/data/officers/surgeon/2026-11-04.json"
  assert_equals "" "$(nav_check "$w" lane:surgeon:high)" "an unparseable json: silent"
  pass 'the high lane counts only high or critical findings and reports a new count once'
}

test_sources_changes_nothing_in_the_parent() {
  local w before after
  w=$(source_world parentro)
  put_digest "$w" progress 2026-11-04 4
  before=$(find "$w" -path "$w/navigator" -prune -o -type f -exec cksum {} + | sort)
  nav_check "$w" lane:progress >/dev/null
  nav_check "$w" tick >/dev/null
  after=$(find "$w" -path "$w/navigator" -prune -o -type f -exec cksum {} + | sort)
  assert_equals "$before" "$after" "parent files after the checks"
  pass 'source checks read the parent and write only in the office home'
}

test_healthy_registry_prints_nothing
test_absent_registry_means_no_offices
test_gaps
test_list_counts_gaps
test_ensure_changes_nothing
test_status_working_lane
test_status_next_lane
test_status_done_window
test_status_done_shows_24_hours_from_first_sight
test_status_seen_file_loss_keeps_old_items_out
test_status_prunes_old_stamps
test_status_skips_unchanged_write
test_status_writes_only_its_file
test_status_outside_an_office_does_nothing
test_status_without_a_backlog_is_empty
test_arm_status_registers_a_silent_check
test_disarm_status_retires_the_check
test_arm_status_refuses_outside_an_office
test_register_sources_installs_trusted_shims
test_register_sources_keeps_the_status_check
test_shim_runs_through_the_watcher_trust_path
test_tick_prints_once_per_slot_and_only_when_work_could_start
test_tick_is_silent_when_places_are_full
test_tick_counts_unread_lane_digests
test_lane_check_reports_each_new_digest_once
test_lane_check_reads_a_spaced_sources_list
test_lane_check_is_silent_when_it_cannot_read
test_high_lane_counts_only_high_severity
test_sources_changes_nothing_in_the_parent
