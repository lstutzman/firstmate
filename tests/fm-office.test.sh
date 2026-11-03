#!/usr/bin/env bash
# Behavior tests for bin/fm-office.sh: list and ensure over data/offices.md,
# checked against a fixture primary home and a local office home.
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
  gap_case macbook 'host not allowed: macbook' "sed -i 's/runs-on: slartibartfast; dispatch: Property/runs-on: macbook; dispatch: Property/' data/offices.md"
  gap_case role 'unknown role "wizard"' "sed -i 's/role: navigator/role: wizard/' data/offices.md"
  gap_case wip 'wip must be' "sed -i 's/wip: 2; tick: every 2h/wip: 0; tick: every 2h/' data/offices.md"
  gap_case tick 'tick must be' "sed -i 's/tick: every 2h/tick: hourly/' data/offices.md"
  gap_case auto 'auto-merge-classes must be none' "sed -i '0,/auto-merge-classes: none/s//auto-merge-classes: docs/' data/offices.md"
  gap_case lane 'lane:nope is not a registered officer' "sed -i 's/lane:progress/lane:nope/' data/offices.md"
  gap_case notmate 'not a registered second mate' ": > data/secondmates.md"
  gap_case hostmismatch 'does not include the second mate host' "sed -i 's/(home:/(host: deepthought; root: \\/r; home:/' data/secondmates.md"
  gap_case marker '.fm-office marker missing' "rm navigator/.fm-office"
  gap_case charter 'lacks the "# Office authority" heading' "printf '# Charter\n' > navigator/data/charter.md"
  gap_case project 'dispatch project PropertyCompass2 is not in' ": > navigator/data/projects.md"
  gap_case admission 'merge project firstmate has no admission=' "sed -i 's/ admission=fm//' quartermaster/data/projects.md"
  gap_case merger 'merge-via project PropertyCompass2 lacks merger=slarti' "sed -i 's/ merger=slarti//' navigator/data/projects.md"
  gap_case subset 'merge project skills is not in dispatch' "sed -i 's/dispatch: firstmate,skills/dispatch: firstmate/' data/offices.md"
  gap_case overlap 'merge-via project firstmate overlaps merge' "sed -i 's/merge-via: none/merge-via: firstmate=slarti/' data/offices.md"
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

test_healthy_registry_prints_nothing
test_absent_registry_means_no_offices
test_gaps
test_list_counts_gaps
test_ensure_changes_nothing
