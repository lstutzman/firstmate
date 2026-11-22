#!/usr/bin/env bash
# The watcher's remote-summary refresh: remote_summary_tick runs
# `fm-fleet-snapshot.sh --remote-summary-refresh` on a cadence well inside
# FM_REMOTE_SHIP_MAX_AGE, so the CI-slot and landing-lag counts never read an
# expired copy of a remote home's ships. The gating cases use a fake snapshot
# script that logs its arguments; the end-to-end case drives the real snapshot
# against a fake ssh and a stale cached copy.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-remote-summary)
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/home/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE" "$FM_HOME/data" "$FM_HOME/projects"
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

REAL_SCRIPT_DIR=$SCRIPT_DIR
FAKE_DIR="$TMP_ROOT/fake-scripts"
CALLS="$TMP_ROOT/calls"
mkdir -p "$FAKE_DIR"
cat > "$FAKE_DIR/fm-fleet-snapshot.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
echo "fresh=1 cached=0 failed=0"
SH
chmod +x "$FAKE_DIR/fm-fleet-snapshot.sh"

REMOTE='- far - a remote mate (host: far.example; root: /srv/fm; home: /srv/home; scope: other; projects: project; added 2026-09-01)'
LOCAL='- near - a local mate (home: /srv/near; scope: other; projects: project; added 2026-09-01)'

reset_case() {
  rm -rf -- "$STATE"/* "$STATE"/.[!.]* "$CALLS" "$FM_HOME/data/secondmates.md"
  SCRIPT_DIR=$FAKE_DIR
  unset FM_REMOTE_SUMMARY_INTERVAL_SECS
}

calls() { if [ -f "$CALLS" ]; then wc -l < "$CALLS" | tr -d ' '; else printf 0; fi; }

wait_for_calls() {  # <count>
  local want=$1 i=0
  while [ "$(calls)" != "$want" ]; do
    i=$((i + 1))
    [ "$i" -lt 200 ] || fail "the refresh was not started $want time(s): $(calls)"
    sleep 0.1
  done
}

test_a_remote_home_starts_one_refresh_per_interval() {
  reset_case
  printf '# Secondmates\n\n%s\n%s\n' "$LOCAL" "$REMOTE" > "$FM_HOME/data/secondmates.md"
  remote_summary_tick
  wait_for_calls 1
  assert_equals "--remote-summary-refresh" "$(cat "$CALLS")" "the tick did not run the remote-summary mode"
  remote_summary_tick
  remote_summary_tick
  sleep 0.5
  [ "$(calls)" = 1 ] || fail "the refresh ran again inside its interval: $(calls)"
  fm_touch_epoch "$(( $(date +%s) - 1900 ))" "$STATE/.remote-summary-last-run"
  remote_summary_tick
  wait_for_calls 2
  pass 'a home with a remote secondmate refreshes its summary cache once per interval (default 1800 seconds)'
}

test_the_default_interval_is_well_inside_the_ship_max_age() {
  reset_case
  printf '%s\n' "$REMOTE" > "$FM_HOME/data/secondmates.md"
  fm_touch_epoch "$(( $(date +%s) - 1700 ))" "$STATE/.remote-summary-last-run"
  remote_summary_tick
  sleep 0.5
  [ "$(calls)" = 0 ] || fail "the refresh ran before 1800 seconds"
  [ "${FM_REMOTE_SHIP_MAX_AGE:-7200}" -ge $((1800 * 3)) ] || fail "the cadence leaves under three attempts per max age"
  pass 'the default cadence leaves at least three refresh attempts inside the ship-summary max age'
}

test_a_home_without_a_remote_secondmate_is_left_alone() {
  reset_case
  remote_summary_tick
  printf '# Secondmates\n\n%s\n' "$LOCAL" > "$FM_HOME/data/secondmates.md"
  remote_summary_tick
  sleep 0.5
  [ "$(calls)" = 0 ] || fail "a home with no remote secondmate started a refresh"
  [ ! -e "$STATE/.remote-summary-last-run" ] || fail "a quiet check spent the interval"
  pass 'a home with no registry, or only local secondmates, never starts a refresh'
}

test_the_interval_is_configurable_and_zero_turns_it_off() {
  reset_case
  printf '%s\n' "$REMOTE" > "$FM_HOME/data/secondmates.md"
  FM_REMOTE_SUMMARY_INTERVAL_SECS=0 remote_summary_tick
  sleep 0.5
  [ "$(calls)" = 0 ] || fail "interval 0 did not turn the refresh off"
  fm_touch_epoch "$(( $(date +%s) - 70 ))" "$STATE/.remote-summary-last-run"
  FM_REMOTE_SUMMARY_INTERVAL_SECS=60 remote_summary_tick
  wait_for_calls 1
  pass 'FM_REMOTE_SUMMARY_INTERVAL_SECS sets the cadence and 0 turns the refresh off'
}

test_a_stale_cache_is_refreshed_by_the_periodic_path() {
  local fb key cache file remote_home="$TMP_ROOT/remote-home" now
  reset_case
  SCRIPT_DIR=$REAL_SCRIPT_DIR
  now=$(date +%s)
  mkdir -p "$remote_home/state"
  printf -- '- far - a remote mate (host: far.example; root: /srv/fm; home: %s; scope: other; projects: project; added 2026-09-01)\n' \
    "$remote_home" > "$FM_HOME/data/secondmates.md"
  jq -n --arg home "$remote_home" --argjson at "$now" '{
    schema:"fm-secondmate-home-summary.v1",hold_classifier_schema:"fm-captain-hold-buckets.v1",
    generated:"x",generated_epoch:$at,home:$home,valid:true,reason:null,state:"no_active_work",
    invalidity:{kind:null,ids:[]},active_children:[],decisions_open:[],holds:[],queued:[],landed:[],
    endpoints:[],counts:{},omitted:[],ships:[]}' > "$remote_home/state/home-summary.json"
  fb="$TMP_ROOT/ssh"
  mkdir -p "$fb"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
remote_home=$(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$3")
cat "$remote_home/state/home-summary.json"
SH
  chmod +x "$fb/fake-ssh"
  key=$(printf '%s\n%s\n%s\n' far far.example "$remote_home" | sha256sum | awk '{print $1}')
  cache="$STATE/secondmate-summary-cache"
  mkdir -p "$cache" && chmod 700 "$cache"
  file="$cache/$key.json"
  jq --argjson at "$((now - 9000))" '.generated_epoch = $at' "$remote_home/state/home-summary.json" > "$file"
  chmod 600 "$file"
  FM_SSH_BIN="$fb/fake-ssh" remote_summary_tick
  timeout 60 bash -c "until [ \"\$(jq -r .generated_epoch '$file')\" = '$now' ]; do sleep 0.2; done" \
    || fail "the stale cached copy was not refreshed: $(jq -c .generated_epoch "$file")"
  pass 'the periodic path replaces a cached remote summary that is past the ship max age'
}

fm_test_run \
  test_a_remote_home_starts_one_refresh_per_interval \
  test_the_default_interval_is_well_inside_the_ship_max_age \
  test_a_home_without_a_remote_secondmate_is_left_alone \
  test_the_interval_is_configurable_and_zero_turns_it_off \
  test_a_stale_cache_is_refreshed_by_the_periodic_path
