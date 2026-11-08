#!/usr/bin/env bash
# Behavior tests for an office on a remote host: bin/fm-office.sh publish and
# feed-sweep push the office's authority record and the office-feed copy of its
# line and lane digests through the real remote inherit push (over a fake ssh to
# a local "remote" home), and the remote home's gates and source checks read
# only what arrived there. A copy or lane over its size limit is never sent,
# and publish, feed, feed-sweep and ensure say so; an officer run sends its new
# digest to the remote office at once.
set -u

# shellcheck source=tests/officer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/officer-helpers.sh"

OFFICE="$ROOT/bin/fm-office.sh"
TMP_ROOT=$(fm_test_tmproot fm-office-remote)
NOW=1793786700 # 2026-11-04T10:05:00Z
LINE='- nav - Drive progress (role: navigator; runs-on: inherit-host; dispatch: PropertyCompass2; merge: none; merge-via: none; auto-merge-classes: none; wip: 2; tick: every 2h; sources: tick,lane:progress; added 2026-11-04)'

# world <name>: a main home with a remote office "nav" whose home is $w/remote-nav, reached through a fake ssh that
# runs the remote code root's real receiver there.
world() {
  local w="$TMP_ROOT/$1" dest="$TMP_ROOT/$1/remote-nav" fake="$TMP_ROOT/$1/fakebin"
  mkdir -p "$w/data/officers/progress" "$w/config" "$w/state" "$dest/config" "$dest/state" "$dest/data" "$fake"
  printf -- '- nav - office (host: inherit-host; root: %s; home: %s; scope: office; projects: none; added 2026-11-04)\n' "$ROOT" "$dest" > "$w/data/secondmates.md"
  printf -- '- progress - x (role: progress; cadence: daily 07:00; added 2026-10-26)\n' > "$w/data/officers.md"
  printf '# Offices\n\n%s\n' "$LINE" > "$w/data/offices.md"
  printf 'nav\n' > "$dest/.fm-secondmate-home"
  printf 'nav\n' > "$dest/.fm-office"
  printf '# Charter\n\n# Office authority\n' > "$dest/data/charter.md"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=inherit-host\n' > "$dest/.fm-secondmate-parent"
  cat > "$fake/inherit-ssh" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'call\n' >> "$FM_FAKE_SSH_COUNT"  # one appended line per call: parallel item pushes cannot lose a count
[ ! -f "$FM_FAKE_SSH_FAIL" ] || exit 255
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
remote_root=$(printf '%s' "$4" | base64 --decode)
remote_home=$(printf '%s' "$5" | base64 --decode)
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | base64 --decode)
[ "${args[0]}" = fm-remote-inherit.sh ] || exit 92
FM_HOME="$remote_home" FM_STATE_OVERRIDE="$remote_home/state" exec "$remote_root/bin/${args[0]}" "${args[@]:1}"
SH
  chmod +x "$fake/inherit-ssh"
  printf '%s\n' "$w"
}

main_env() {  # <world> <now> <cmd...>
  local w=$1 now=$2
  shift 2
  env FM_HOME="$w" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$w/config" FM_DATA_OVERRIDE="$w/data" FM_STATE_OVERRIDE="$w/state" \
    FM_SSH_BIN="$w/fakebin/inherit-ssh" FM_FAKE_SSH_COUNT="$w/ssh.count" FM_FAKE_SSH_FAIL="$w/ssh.fail" FM_OFFICE_NOW="$now" "$@"
}
ssh_calls() { wc -l < "$1/ssh.count" | tr -d ' '; }
publish() { main_env "$1" "${2:-$NOW}" bash "$OFFICE" publish nav; }
sweep() { main_env "$1" "$2" bash "$OFFICE" feed-sweep; }
remote_office() { env FM_HOME="$1/remote-nav" FM_OFFICE_NOW="$2" bash "$OFFICE" "${@:3}"; }

put_digest() {  # <world> <key> <n>
  local w=$1 d="$1/data/officers/progress"
  printf 'DIGEST %s %s data/officers/progress/%s.md\n' "$2" "$3" "$2" > "$d/digest"
  printf '# progress %s\n' "$2" > "$d/$2.md"
  python3 -I - "$w" "$ROOT" > "$d/$2.json" <<'PY'
import json, sys
w, root = sys.argv[1:3]
def request(rank, home):
    rid = "progress-2026-11-04-%016x" % rank
    return {"rank": rank, "execute": {"action": "start", "request_id": rid, "env": {"FM_HOME": home},
            "argv": [root + "/bin/fm-inbox.sh", "note", "--request-id", rid, "--json", "--", "Start item %d" % rank]}}
print(json.dumps({"source": "progress-officer", "generated_at": "2026-11-04T09:00:00Z",
                  "findings": [{"severity": "high"}, {"severity": "low"}],
                  "start_requests": [request(1, w + "/remote-nav"), request(2, "/somewhere/else")]}))
PY
}

resolve() {
  bash -c '. "$1"; rc=0; fm_office_resolve "$2" "$2/data" "$2/config" || rc=$?; printf "%s|%s|%s\n" "$rc" "$FM_OFFICE_ID" "$FM_OFFICE_ERROR"' \
    _ "$ROOT/bin/fm-office-authority-lib.sh" "$1"
}

test_publish_reaches_the_remote_home() {
  local w out
  w=$(world publish)
  out=$(publish "$w") || fail "publish to a remote office failed: $out"
  assert_equals "office nav: pushed" "$out" "publish line"
  assert_present "$w/remote-nav/config/office-authority" "the authority record reached the remote home"
  assert_present "$w/remote-nav/config/.fm-inherit-office-authority.generation" "the receipt reached the remote home"
  assert_present "$w/remote-nav/config/office-feed" "the feed reached the remote home"
  assert_equals "0|nav|" "$(resolve "$w/remote-nav")" "the remote home's gate accepts the published record"
  assert_equals "office nav: unchanged" "$(publish "$w")" "a repeat publish changes nothing"
  assert_equals "" "$(main_env "$w" "$NOW" bash "$OFFICE" ensure | grep 'office nav:' || true)" "ensure is clean once published and the feed check is armed"
  rm -f "$w/state/office-feed.check.sh" "$w/state/office-feed.check-trust"
  assert_contains "$(main_env "$w" "$NOW" bash "$OFFICE" ensure)" "office-feed is not registered" "ensure reports a remote office whose feed check is gone"
  rm -f "$w/remote-nav/config/.fm-inherit-office-authority.generation"
  assert_not_contains "$(resolve "$w/remote-nav")" "0|nav|" "a record without its receipt is refused"
  pass 'publish delivers the authority record, its receipt and the feed to a remote office, and its gate accepts them'
}

test_remote_checks_read_the_carried_copy() {
  local w out
  w=$(world checks)
  publish "$w" >/dev/null || fail "publish failed"
  remote_office "$w" "$NOW" register-sources >/dev/null || fail "register-sources must read the office line from the feed"
  assert_present "$w/remote-nav/state/office-tick.check.sh" "the tick source registered from the carried line"
  assert_present "$w/remote-nav/state/office-lane-progress.check.sh" "the lane source registered from the carried line"
  printf '## In flight\n\n## Queued\n- [ ] one - a queued item (repo: x) (kind: ship)\n\n## Done\n' > "$w/remote-nav/data/backlog.md"
  assert_equals "office nav: tick 2026-11-04T10: 2 of 2 places free, 1 queued" "$(remote_office "$w" "$NOW" check tick)" "tick, wip and cadence come through the feed"
  put_digest "$w" 2026-11-04 3
  sweep "$w" "$((NOW + 100))"
  out=$(remote_office "$w" "$((NOW + 100))" check lane:progress)
  assert_equals "office nav: progress digest 2026-11-04: 3 finding(s) in $w/remote-nav/data/office/feed/progress.md; 1 start request(s) delivered to this office's inbox" "$out" "a new digest wakes the remote lane check and delivers the request addressed to it"
  assert_contains "$(cat "$w"/remote-nav/state/inbox/*.note)" "Start item 1" "the start request reached the remote home's inbox"
  assert_equals "" "$(remote_office "$w" "$((NOW + 100))" check lane:progress)" "and only once"
  assert_contains "$(cat "$w/remote-nav/data/office/feed/progress.json")" "\"FM_HOME\":\"$w/remote-nav\"" "the start request addressed to the office is carried"
  assert_not_contains "$(cat "$w/remote-nav/data/office/feed/progress.json")" '/somewhere/else' "another home's start request is not"
  pass 'the remote checks read the line and the lane digest from the carried copy, once per digest'
}

test_sweep_pushes_only_what_changed() {
  local w before
  w=$(world sweep)
  publish "$w" >/dev/null || fail "publish failed"
  before=$(cat "$w/remote-nav/config/office-feed")
  sweep "$w" "$((NOW + 100))"
  assert_equals "$before" "$(cat "$w/remote-nav/config/office-feed")" "an unchanged copy is not pushed again"
  put_digest "$w" 2026-11-04 3
  sweep "$w" "$((NOW + 200))"
  assert_contains "$(cat "$w/remote-nav/config/office-feed")" "generated=$((NOW + 200))" "a new digest is pushed by the next sweep"
  assert_contains "$(cat "$w/remote-nav/config/office-feed")" "lane=progress " "with its lane"
  sweep "$w" "$((NOW + 90000))"
  assert_contains "$(cat "$w/remote-nav/config/office-feed")" "generated=$((NOW + 90000))" "an unchanged copy is refreshed once the last push is old"
  pass 'the feed sweep pushes a changed copy at once, an unchanged one only to refresh it, and prints nothing'
}

test_sweep_backs_off_after_a_failed_push() {
  local w calls
  w=$(world backoff)
  publish "$w" >/dev/null || fail "publish failed"
  put_digest "$w" 2026-11-04 3
  : > "$w/ssh.fail"
  sweep "$w" "$((NOW + 200))"
  calls=$(ssh_calls "$w")
  sweep "$w" "$((NOW + 250))"
  assert_equals "$calls" "$(ssh_calls "$w")" "a failed push is not retried inside the retry window"
  sweep "$w" "$((NOW + 400))"
  [ "$(ssh_calls "$w")" -gt "$calls" ] || fail "a failed push must be retried after the window"
  assert_contains "$(cat "$w/remote-nav/config/office-feed")" "generated=$NOW" "a failed push leaves the old copy"
  pass 'a failed feed push is retried after its window, not on every sweep'
}

test_stale_or_absent_copy_is_silent() {
  local w
  w=$(world stale)
  publish "$w" >/dev/null || fail "publish failed"
  remote_office "$w" "$NOW" register-sources >/dev/null || fail "register-sources failed"
  printf '## In flight\n\n## Queued\n- [ ] one - a queued item (repo: x) (kind: ship)\n\n## Done\n' > "$w/remote-nav/data/backlog.md"
  put_digest "$w" 2026-11-04 3
  sweep "$w" "$((NOW + 100))"
  assert_contains "$(remote_office "$w" "$((NOW + 100))" check tick)" "places free" "a fresh copy speaks"
  assert_equals "" "$(remote_office "$w" "$((NOW + 100 + 129601))" check tick)" "a copy older than 36 hours is silent for the tick"
  assert_equals "" "$(remote_office "$w" "$((NOW + 100 + 129601))" check lane:progress)" "and for a lane"
  if remote_office "$w" "$((NOW + 100 + 129601))" register-sources >/dev/null 2>&1; then fail "register-sources must refuse a stale copy"; fi
  sed 's/^id=nav$/id=other/' "$w/remote-nav/config/office-feed" > "$w/feed.other"
  cp "$w/feed.other" "$w/remote-nav/config/office-feed"
  assert_equals "" "$(remote_office "$w" "$((NOW + 100))" check tick)" "a copy for another office is silent"
  rm -f "$w/remote-nav/config/office-feed"
  assert_equals "" "$(remote_office "$w" "$((NOW + 100))" check tick)" "an absent copy is silent"
  assert_equals "" "$(remote_office "$w" "$((NOW + 100))" check lane:progress)" "an absent copy is silent for a lane"
  pass 'a stale, mismatched or absent feed leaves every remote check silent'
}

test_oversized_feed_is_held_and_reported() {
  local w before out rc
  w=$(world oversize)
  publish "$w" >/dev/null || fail "publish failed"
  before=$(cat "$w/remote-nav/config/office-feed")
  put_digest "$w" 2026-11-04 3

  rc=0; out=$(main_env "$w" "$((NOW + 100))" env FM_OFFICE_FEED_MAX=1000 bash "$OFFICE" feed nav) || rc=$?
  [ "$rc" -ne 0 ] || fail "feed must exit non-zero for an oversized copy"
  assert_contains "$out" "office nav: feed not pushed: " "feed names the held copy"
  assert_contains "$out" " bytes over FM_OFFICE_FEED_MAX (1000)" "feed names the limit"
  assert_equals "$before" "$(cat "$w/remote-nav/config/office-feed")" "feed leaves the remote copy untouched"

  rc=0; out=$(main_env "$w" "$((NOW + 100))" env FM_OFFICE_FEED_MAX=1000 bash "$OFFICE" publish nav) || rc=$?
  [ "$rc" -ne 0 ] || fail "publish must exit non-zero for an oversized copy"
  assert_contains "$out" "office nav: feed not pushed: " "publish names the held copy"
  assert_equals "$before" "$(cat "$w/remote-nav/config/office-feed")" "publish leaves the remote copy untouched"
  assert_equals "0|nav|" "$(resolve "$w/remote-nav")" "publish still sends the authority record"

  rc=0; out=$(main_env "$w" "$((NOW + 100))" env FM_OFFICE_FEED_MAX=1000 FM_INHERITABLE_CONFIG="office-authority office-feed" \
    bash "$ROOT/bin/fm-remote-inherit-push.sh" nav 900 2>&1) || rc=$?
  assert_equals 0 "$rc" "a convergence push still succeeds with an oversized copy: $out"
  assert_equals "$before" "$(cat "$w/remote-nav/config/office-feed")" "a convergence push never sends an absence for it"
  assert_equals "0|nav|" "$(resolve "$w/remote-nav")" "and still delivers the authority record"

  assert_contains "$(main_env "$w" "$((NOW + 100))" env FM_OFFICE_FEED_MAX=1000 bash "$OFFICE" ensure)" \
    "OFFICE: office nav: feed not pushed: " "ensure reports the held copy"

  out=$(main_env "$w" "$((NOW + 200))" env FM_OFFICE_FEED_MAX=1000 bash "$OFFICE" feed-sweep)
  assert_contains "$out" "OFFICE: office nav: feed not pushed: " "the sweep reports the held copy"
  assert_equals "" "$(main_env "$w" "$((NOW + 300))" env FM_OFFICE_FEED_MAX=1000 bash "$OFFICE" feed-sweep)" "and only once"
  assert_equals "$before" "$(cat "$w/remote-nav/config/office-feed")" "the sweep leaves the remote copy untouched"

  rc=0; out=$(main_env "$w" "$((NOW + 400))" env FM_OFFICE_FEED_LANE_MAX=10 bash "$OFFICE" feed nav) || rc=$?
  [ "$rc" -ne 0 ] || fail "feed must exit non-zero for an oversized lane"
  assert_contains "$out" "office nav: feed not pushed: lane progress digest $w/data/officers/progress/2026-11-04.md is " "feed names the oversized lane"
  assert_contains "$out" "over FM_OFFICE_FEED_LANE_MAX (10)" "and its limit"
  assert_contains "$(main_env "$w" "$((NOW + 400))" env FM_OFFICE_FEED_LANE_MAX=10 bash "$OFFICE" ensure)" \
    "OFFICE: office nav: feed not pushed: lane progress" "ensure reports the oversized lane"
  out=$(main_env "$w" "$((NOW + 500))" env FM_OFFICE_FEED_LANE_MAX=10 bash "$OFFICE" feed-sweep)
  assert_contains "$out" "OFFICE: office nav: feed not pushed: lane progress" "the sweep reports a newly oversized lane"
  assert_equals "$before" "$(cat "$w/remote-nav/config/office-feed")" "an oversized lane leaves the remote copy untouched"

  assert_equals "" "$(sweep "$w" "$((NOW + 600))")" "a copy that fits again is sent silently"
  assert_contains "$(cat "$w/remote-nav/config/office-feed")" "lane=progress " "with its lane"
  assert_absent "$w/state/office-feed.nav.over" "and the held record is cleared"
  pass 'an oversized feed or lane is never sent, and publish, feed, the sweep and ensure report it'
}

test_officer_run_sends_its_digest_to_a_remote_office() {
  local w spec
  w=$(world officer)
  spec="$TMP_ROOT/officer/spec.json"
  printf '{"sessions": [{"machine": "alpha", "id": "s1", "first_prompt": "hello", "calls": [["Bash", {"command": "rm -f /tmp/x"}, "", false]]}]}\n' > "$spec"
  officer_archive "$TMP_ROOT/officer/archive" 2026-11-03 "$spec"
  officer_registry "$w" "$TMP_ROOT/officer/archive" alpha
  sed 's/lane:progress/lane:triage/' "$w/data/offices.md" > "$w/offices.tmp" && mv "$w/offices.tmp" "$w/data/offices.md"
  publish "$w" >/dev/null || fail "publish failed"
  assert_not_contains "$(cat "$w/remote-nav/config/office-feed")" "lane=triage " "no digest is carried before the officer runs"
  main_env "$w" "$NOW" env FM_OFFICER_NOW="$NOW" TZ=UTC bash "$ROOT/bin/fm-officer.sh" run triage --date 2026-11-03 >/dev/null \
    || fail "the officer run failed"
  assert_contains "$(cat "$w/remote-nav/config/office-feed")" "lane=triage " "the officer run sends its new digest to the remote office"
  pass 'an officer run sends its new digest to a remote office at once'
}

test_publish_reaches_the_remote_home
test_remote_checks_read_the_carried_copy
test_sweep_pushes_only_what_changed
test_sweep_backs_off_after_a_failed_push
test_stale_or_absent_copy_is_silent
test_oversized_feed_is_held_and_reported
test_officer_run_sends_its_digest_to_a_remote_office
