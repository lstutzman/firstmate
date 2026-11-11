#!/usr/bin/env bash
# Behavior tests for fm-nm-daemon-env.sh: the systemd drop-in that puts the
# no-mistakes daemon's claude -p agents on a 5m prompt-cache TTL. A fake unit
# directory and a fake systemctl stand in for the host; nothing real is touched.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-daemon-env-tests)
SCRIPT=$ROOT/bin/fm-nm-daemon-env.sh

# make_case <name>: a unit dir with one unit for the case's root and one for another root.
make_case() {
  local d=$TMP_ROOT/$1
  mkdir -p "$d/units" "$d/fakebin"
  cat > "$d/units/no-mistakes-daemon-aaaa1111.service" <<UNIT
[Service]
ExecStart=/x/no-mistakes daemon run --root $d/nmroot
Environment="HOME=/home/x"
UNIT
  cat > "$d/units/no-mistakes-daemon-bbbb2222.service" <<UNIT
[Service]
ExecStart=/x/no-mistakes daemon run --root $d/other-root
UNIT
  cat > "$d/fakebin/systemctl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/systemctl.log"
case "\$*" in *"show -p MainPID --value"*) [ -f "$d/mainpid" ] && cat "$d/mainpid" ;; esac
exit 0
SH
  chmod +x "$d/fakebin/systemctl"
  printf '%s\n' "$d"
}

run() {  # <case dir> <verb>
  PATH="$1/fakebin:$PATH" FM_NM_DAEMON_UNIT_DIR="$1/units" NM_HOME="$1/nmroot" bash "$SCRIPT" "$2" 2>&1
}

DROPIN() { printf '%s/units/no-mistakes-daemon-aaaa1111.service.d/firstmate-cache-ttl.conf' "$1"; }

# unit_settings <file>: the file read as systemd.syntax(7) does, one Section.Key=Value
# per assignment, comments and blank lines skipped, one pair of surrounding quotes removed.
unit_settings() {
  awk '
    /^[ \t]*([#;]|$)/ { next }
    /^\[.*\]$/ { sec = substr($0, 2, length($0) - 2); next }
    {
      i = index($0, "="); if (i == 0) { print "UNPARSED:" $0; next }
      k = substr($0, 1, i - 1); v = substr($0, i + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
      print (sec == "" ? "NOSECTION" : sec) "." k "=" v
    }' "$1"
}

test_check_reports_a_missing_drop_in_and_writes_nothing() {
  local d out rc
  d=$(make_case missing)
  out=$(run "$d" check); rc=$?
  [ "$rc" -eq 0 ] || fail "check must exit 0, got $rc"
  assert_contains "$out" "NM_DAEMON_ENV: the cache-TTL drop-in for no-mistakes-daemon-aaaa1111.service is missing" "missing drop-in line"
  assert_contains "$out" "fm-nm-daemon-env.sh\" install" "line names the install command"
  assert_not_contains "$out" "bbbb2222" "a unit for another root was reported"
  assert_absent "$(DROPIN "$d")" "check wrote the drop-in"
  [ ! -e "$d/systemctl.log" ] || fail "check called systemctl"
  pass "check reports a missing drop-in as one actionable line and writes nothing"
}

test_install_writes_the_exact_drop_in_and_never_restarts() {
  local d out
  d=$(make_case install)
  out=$(run "$d" install) || fail "install failed: $out"
  assert_equals "$(unit_settings "$(DROPIN "$d")")" "Service.Environment=CLAUDE_CODE_PROMPT_CACHE_TTL=5m" "drop-in must set only Service.Environment to the 5m TTL"
  assert_absent "$d/units/no-mistakes-daemon-bbbb2222.service.d" "install touched another root's unit"
  assert_equals "$(cat "$d/systemctl.log")" "--user daemon-reload" "install may only reload systemd"
  assert_contains "$out" "the running daemon was not touched" "install must say it did not restart"
  [ -z "$(run "$d" check)" ] || fail "check is not silent after install"
  pass "install writes the exact drop-in, reloads systemd only, and leaves other roots alone"
}

test_install_is_idempotent() {
  local d out before after
  d=$(make_case idem)
  run "$d" install >/dev/null
  before=$(cat "$(DROPIN "$d")")
  out=$(run "$d" install)
  after=$(cat "$(DROPIN "$d")")
  assert_equals "$after" "$before" "second install changed the drop-in"
  assert_contains "$out" "already current" "second install should report current"
  pass "install is idempotent"
}

test_check_reports_a_different_drop_in_and_install_repairs_it() {
  local d out
  d=$(make_case different)
  mkdir -p "$(dirname "$(DROPIN "$d")")"
  printf '[Service]\nEnvironment="CLAUDE_CODE_PROMPT_CACHE_TTL=1h"\n' > "$(DROPIN "$d")"
  out=$(run "$d" check)
  assert_contains "$out" "drop-in for no-mistakes-daemon-aaaa1111.service is different" "different drop-in line"
  run "$d" install >/dev/null
  [ -z "$(run "$d" check)" ] || fail "install did not repair the different drop-in"
  pass "check reports a different drop-in and install repairs it"
}

test_no_matching_unit_is_silent() {
  local d out
  d=$(make_case none)
  out=$(PATH="$d/fakebin:$PATH" FM_NM_DAEMON_UNIT_DIR="$d/units" NM_HOME="$d/no-such-root" bash "$SCRIPT" check 2>&1)
  [ -z "$out" ] || fail "a root with no unit must be silent, got: $out"
  out=$(PATH="$d/fakebin:$PATH" FM_NM_DAEMON_UNIT_DIR="$d/missing-dir" NM_HOME="$d/nmroot" bash "$SCRIPT" check 2>&1)
  [ -z "$out" ] || fail "a missing unit directory (launchd host) must be silent, got: $out"
  pass "check is silent when no systemd unit matches the root"
}

test_status_and_usage() {
  local d out rc
  d=$(make_case status)
  out=$(run "$d" status)
  assert_contains "$out" "no-mistakes-daemon-aaaa1111.service: drop-in missing" "status before install"
  run "$d" install >/dev/null
  assert_contains "$(run "$d" status)" "drop-in current" "status after install"
  out=$(bash "$SCRIPT" bogus 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "unknown verb must exit 2, got $rc"
  pass "status reports the drop-in state and an unknown verb is a usage error"
}

test_status_reads_the_running_daemon_environment() {
  local d with without
  if [ ! -r /proc/self/environ ]; then
    pass "status running-daemon check skipped: no /proc on this host"
    return
  fi
  d=$(make_case running)
  env CLAUDE_CODE_PROMPT_CACHE_TTL=5m sleep 30 </dev/null >/dev/null 2>&1 & with=$!
  env -u CLAUDE_CODE_PROMPT_CACHE_TTL CLAUDE_CODE_PROMPT_CACHE_TTL_X=5m sleep 30 </dev/null >/dev/null 2>&1 & without=$!
  local pid tries
  for pid in "$with" "$without"; do
    tries=0
    while [ "$(cat "/proc/$pid/comm" 2>/dev/null)" != sleep ] && [ "$tries" -lt 100 ]; do
      sleep 0.05; tries=$((tries + 1))
    done
  done
  local out_with out_without out_stopped
  echo "$with" > "$d/mainpid"; out_with=$(run "$d" status)
  echo "$without" > "$d/mainpid"; out_without=$(run "$d" status)
  echo 0 > "$d/mainpid"; out_stopped=$(run "$d" status)
  kill "$with" "$without" 2>/dev/null
  wait "$with" "$without" 2>/dev/null
  assert_contains "$out_with" "carries CLAUDE_CODE_PROMPT_CACHE_TTL=5m: yes" "daemon started with the variable"
  assert_contains "$out_without" "carries CLAUDE_CODE_PROMPT_CACHE_TTL=5m: no" "daemon started without the variable"
  assert_contains "$out_stopped" "carries CLAUDE_CODE_PROMPT_CACHE_TTL=5m: unknown" "a stopped daemon (MainPID 0)"
  pass "status reports yes, no and unknown from the running daemon's own environment"
}

fm_test_run test_check_reports_a_missing_drop_in_and_writes_nothing \
  test_install_writes_the_exact_drop_in_and_never_restarts \
  test_install_is_idempotent \
  test_check_reports_a_different_drop_in_and_install_repairs_it \
  test_no_matching_unit_is_silent \
  test_status_and_usage \
  test_status_reads_the_running_daemon_environment
