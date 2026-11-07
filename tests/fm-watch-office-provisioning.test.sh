#!/usr/bin/env bash
# The watcher's heartbeat alarm for an approved office that was never
# provisioned: office_unprovisioned_tick runs the real bin/fm-office.sh against
# a scratch primary home and wakes through the real queue interface.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-office-provisioning)
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/home/config"
export FM_OFFICE_TODAY=2026-11-07
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE" "$FM_HOME/data"
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

WAKES="$TMP_ROOT/wakes"
wake() { printf '%s\n' "$1" >> "$WAKES"; }

NAV='- navigator - Drive progress (role: navigator; runs-on: h; added 2026-11-04)'
QM='- quartermaster - Drive the fleet (role: quartermaster; runs-on: h; added 2026-11-04)'
LIB='- librarian - Keep the documents (role: librarian; runs-on: h; added 2026-11-06)'

reset_case() {
  rm -f -- "$STATE"/* "$STATE"/.[!.]* "$WAKES" "$FM_HOME/.fm-secondmate-home" "$FM_HOME/.fm-office" \
    "$FM_HOME/data/office-deferrals.md"
  printf '# Offices\n\n%s\n%s\n%s\n' "$NAV" "$QM" "$LIB" > "$FM_HOME/data/offices.md"
}

count_wakes() {
  if [ -f "$WAKES" ]; then wc -l < "$WAKES" | tr -d ' '; else printf 0; fi
}

ago() {  # <seconds> <path>
  local now
  fm_epoch_seconds_to now
  fm_touch_epoch "$((now - $1))" "$2"
}

test_missing_role_wakes_once_a_day() {
  reset_case
  office_unprovisioned_tick
  [ "$(count_wakes)" = 1 ] || fail "a home missing the alchemist did not wake exactly once"
  assert_equals 'check: office-provisioning: approved office alchemist not provisioned (no '"$FM_HOME"'/data/offices.md line for it, and no valid deferral in '"$FM_HOME"'/data/office-deferrals.md)' \
    "$(cat "$WAKES")" "wake reason"
  assert_contains "$(cat "$FM_WAKE_QUEUE")" "approved office alchemist not provisioned" "queued wake"
  office_unprovisioned_tick
  ago 7200 "$STATE/.office-unprovisioned-run"
  ago 82800 "$STATE/.office-unprovisioned-last"
  office_unprovisioned_tick
  [ "$(count_wakes)" = 1 ] || fail "the alarm woke again within 24 hours"
  ago 90000 "$STATE/.office-unprovisioned-last"
  office_unprovisioned_tick
  [ "$(count_wakes)" = 2 ] || fail "the alarm did not return after 24 hours"
  pass 'a missing approved office wakes once, stays quiet for a day, then wakes again'
}

test_several_gaps_join_into_one_wake() {
  reset_case
  printf '# Offices\n\n%s\n' "$NAV" > "$FM_HOME/data/offices.md"
  office_unprovisioned_tick
  [ "$(count_wakes)" = 1 ] || fail "several gaps did not make exactly one wake"
  assert_contains "$(cat "$WAKES")" "check: office-provisioning: approved office quartermaster not provisioned (" "first gap"
  assert_contains "$(cat "$WAKES")" ") | approved office alchemist not provisioned (" "joined gap"
  assert_contains "$(cat "$WAKES")" ") | approved office librarian not provisioned (" "last gap"
  pass 'several missing offices are joined into one wake'
}

test_provisioned_or_deferred_home_is_quiet() {
  reset_case
  printf -- '- alchemist - "Not yet." (said: main chat, 2026-11-05; added 2026-11-05)\n' > "$FM_HOME/data/office-deferrals.md"
  office_unprovisioned_tick
  [ "$(count_wakes)" = 0 ] || fail "a validly deferred home woke"
  [ ! -e "$STATE/.office-unprovisioned-last" ] || fail "a quiet check spent the daily wake"
  rm "$FM_HOME/data/office-deferrals.md"
  office_unprovisioned_tick
  [ "$(count_wakes)" = 0 ] || fail "the check reran within the hour"
  ago 3700 "$STATE/.office-unprovisioned-run"
  office_unprovisioned_tick
  [ "$(count_wakes)" = 1 ] || fail "the check did not rerun after an hour"
  pass 'a provisioned or deferred home is quiet, and the check runs at most once an hour'
}

test_non_primary_home_skips_the_check() {
  local marker
  for marker in .fm-secondmate-home .fm-office; do
    reset_case
    printf 'x\n' > "$FM_HOME/$marker"
    office_unprovisioned_tick
    [ "$(count_wakes)" = 0 ] || fail "a home with $marker woke"
    [ ! -e "$STATE/.office-unprovisioned-run" ] || fail "a home with $marker ran the check"
  done
  reset_case
  rm "$FM_HOME/data/offices.md"
  office_unprovisioned_tick
  [ "$(count_wakes)" = 0 ] || fail "a home with no data/offices.md woke"
  [ ! -e "$STATE/.office-unprovisioned-run" ] || fail "a home with no data/offices.md ran the check"
  pass 'a second-mate, office or registry-less home skips the check'
}

test_missing_role_wakes_once_a_day
test_several_gaps_join_into_one_wake
test_provisioned_or_deferred_home_is_quiet
test_non_primary_home_skips_the_check
