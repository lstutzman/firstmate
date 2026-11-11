#!/usr/bin/env bash
# Behavior tests for fm-nm-daemon-env.sh: the systemd drop-in (Linux) and the
# agent_path_override wrapper (macOS launchd) that put the no-mistakes daemon's
# claude -p agents on a 5m prompt-cache TTL. Fake unit and LaunchAgents
# directories and fake systemctl, launchctl and claude stand in for the host;
# nothing real is touched.
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

# ---- macOS launchd route: a fake LaunchAgents directory, a fake launchctl and a fake claude ----

# make_mac_case <name>: a LaunchAgents dir with a plist for the case's root and one for another root.
make_mac_case() {
  local d=$TMP_ROOT/$1
  mkdir -p "$d/agents" "$d/fakebin" "$d/nmroot"
  for pair in "aaaa1111:$d/nmroot" "bbbb2222:$d/other-root"; do
    cat > "$d/agents/com.kunchenguid.no-mistakes.daemon.${pair%%:*}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>ProgramArguments</key>
  <array>
    <string>/x/no-mistakes</string>
    <string>daemon</string>
    <string>run</string>
    <string>--root</string>
    <string>${pair#*:}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>HTTP_PROXY</key><string>http://p:1</string></dict>
</dict>
</plist>
PLIST
  done
  cat > "$d/fakebin/claude" <<'SH'
#!/bin/sh
printf 'claude-ran ttl=%s args=%s\n' "${CLAUDE_CODE_PROMPT_CACHE_TTL:-unset}" "$*"
SH
  cat > "$d/fakebin/launchctl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/launchctl.log"
exit 0
SH
  chmod +x "$d/fakebin/claude" "$d/fakebin/launchctl"
  printf '%s\n' "$d"
}

mac_run() {  # <case dir> <verb>
  PATH="$1/fakebin:$PATH" FM_NM_DAEMON_UNIT_DIR="$1/no-systemd" FM_NM_DAEMON_LAUNCHD_DIR="$1/agents" NM_HOME="$1/nmroot" bash "$SCRIPT" "$2" 2>&1
}

PLIST_SUM() { cat "$1"/agents/*.plist | cksum; }

test_mac_check_reports_a_missing_override_and_writes_nothing() {
  local d out rc before
  d=$(make_mac_case mac-missing)
  printf 'agent: auto\n' > "$d/nmroot/config.yaml"
  before=$(PLIST_SUM "$d")
  out=$(mac_run "$d" check); rc=$?
  [ "$rc" -eq 0 ] || fail "check must exit 0, got $rc"
  assert_contains "$out" "NM_DAEMON_ENV: the cache-TTL override for com.kunchenguid.no-mistakes.daemon.aaaa1111.plist (launchd) is missing" "missing override line"
  assert_not_contains "$out" "bbbb2222" "a plist for another root was reported"
  assert_equals "$(cat "$d/nmroot/config.yaml")" "agent: auto" "check changed the config"
  assert_absent "$d/nmroot/firstmate" "check wrote the wrapper"
  assert_equals "$(PLIST_SUM "$d")" "$before" "check changed a plist"
  pass "launchd check reports a missing override as one actionable line and writes nothing"
}

test_mac_install_sets_only_the_claude_override_and_never_touches_launchd() {
  local d out wrapper before
  d=$(make_mac_case mac-install)
  printf '# my config\nagent: auto\nmax_concurrent_runs: 2\n' > "$d/nmroot/config.yaml"
  chmod 0600 "$d/nmroot/config.yaml"
  before=$(PLIST_SUM "$d")
  out=$(mac_run "$d" install) || fail "install failed: $out"
  wrapper=$d/nmroot/firstmate/claude-cache-ttl
  assert_equals "$(PLIST_SUM "$d")" "$before" "install edited a plist"
  [ ! -e "$d/launchctl.log" ] || fail "install ran launchctl: $(cat "$d/launchctl.log")"
  assert_equals "$(sed -n '1,3p' "$d/nmroot/config.yaml")" "# my config
agent: auto
max_concurrent_runs: 2" "install rewrote existing config lines"
  assert_equals "$(tail -n 2 "$d/nmroot/config.yaml")" "agent_path_override:
  claude: \"$wrapper\"" "the override block"
  assert_equals "$(stat -c %a "$d/nmroot/config.yaml" 2>/dev/null || stat -f %Lp "$d/nmroot/config.yaml")" "600" "install changed the config's mode"
  [ -x "$wrapper" ] || fail "wrapper is not executable"
  assert_equals "$(PATH=/usr/bin:/bin "$wrapper" -p hi)" "claude-ran ttl=5m args=-p hi" "the wrapper must run the baked claude with the TTL set and its args passed through"
  assert_contains "$out" "the running daemon was not touched" "install must say it did not restart"
  [ -z "$(mac_run "$d" check)" ] || fail "check is not silent after install"
  assert_absent "$d/nmroot/other-root" "install touched another root"
  pass "launchd install writes the wrapper and one config key, leaves plists and launchctl alone"
}

test_mac_install_is_idempotent_and_survives_a_plist_rewrite() {
  local d out before after
  d=$(make_mac_case mac-idem)
  : > "$d/nmroot/config.yaml"
  mac_run "$d" install >/dev/null
  before=$(cat "$d/nmroot/config.yaml"; cat "$d/nmroot/firstmate/claude-cache-ttl")
  out=$(mac_run "$d" install)
  after=$(cat "$d/nmroot/config.yaml"; cat "$d/nmroot/firstmate/claude-cache-ttl")
  assert_equals "$after" "$before" "second install changed files"
  assert_contains "$out" "already current" "second install should report current"
  # no-mistakes rewrites the plist on every daemon start or update: only the proxy variables come back.
  sed -i.bak 's#http://p:1#http://p:2#' "$d/agents/com.kunchenguid.no-mistakes.daemon.aaaa1111.plist"
  [ -z "$(mac_run "$d" check)" ] || fail "a rewritten plist must not make the setting look lost"
  assert_equals "$(grep -c '^agent_path_override:' "$d/nmroot/config.yaml")" "1" "override block duplicated"
  pass "launchd install is idempotent and a regenerated plist does not undo it"
}

test_mac_install_adds_claude_to_an_existing_override_block() {
  local d
  d=$(make_mac_case mac-block)
  printf 'agent: auto\nagent_path_override:\n  codex: /opt/codex\nmax_concurrent_runs: 2\n' > "$d/nmroot/config.yaml"
  mac_run "$d" install >/dev/null || fail "install failed"
  assert_equals "$(cat "$d/nmroot/config.yaml")" "agent: auto
agent_path_override:
  claude: \"$d/nmroot/firstmate/claude-cache-ttl\"
  codex: /opt/codex
max_concurrent_runs: 2" "claude must join the existing block"
  [ -z "$(mac_run "$d" check)" ] || fail "check is not silent after install"
  pass "launchd install adds claude to an existing agent_path_override block"
}

test_mac_install_matches_the_existing_block_indentation() {
  local d out rc
  d=$(make_mac_case mac-indent)
  printf 'agent_path_override:\n    # mine\n    codex: /opt/codex\nagent: auto\n' > "$d/nmroot/config.yaml"
  mac_run "$d" install >/dev/null || fail "install failed"
  assert_equals "$(cat "$d/nmroot/config.yaml")" "agent_path_override:
    claude: \"$d/nmroot/firstmate/claude-cache-ttl\"
    # mine
    codex: /opt/codex
agent: auto" "claude must use the block's four-space indentation"
  if python3 -c 'import yaml' 2>/dev/null; then
    assert_equals "$(python3 -c 'import sys, yaml; print(sorted(yaml.safe_load(open(sys.argv[1]))["agent_path_override"]))' "$d/nmroot/config.yaml")" "['claude', 'codex']" "the config must stay valid YAML"
  fi
  [ -z "$(mac_run "$d" check)" ] || fail "check is not silent after install"
  printf 'agent_path_override:\n\tcodex: /opt/codex\n' > "$d/nmroot/config.yaml"
  assert_contains "$(mac_run "$d" check)" "is not a plain mapping" "a tab-indented block must show as unsupported"
  out=$(mac_run "$d" install); rc=$?
  [ "$rc" -ne 0 ] || fail "install must refuse a tab-indented block: $out"
  assert_equals "$(cat "$d/nmroot/config.yaml")" "$(printf 'agent_path_override:\n\tcodex: /opt/codex')" "install changed a tab-indented block"
  pass "launchd install copies the existing block's indentation and refuses tabs"
}

test_mac_install_leaves_a_foreign_claude_override_alone() {
  local d out rc
  d=$(make_mac_case mac-foreign)
  printf 'agent_path_override:\n  claude: /opt/my-claude # mine\n' > "$d/nmroot/config.yaml"
  out=$(mac_run "$d" check)
  assert_contains "$out" "NM_DAEMON_ENV:" "foreign override must show as a gap"
  assert_contains "$out" "already set to something else" "foreign override reason"
  out=$(mac_run "$d" install); rc=$?
  [ "$rc" -ne 0 ] || fail "install must refuse a foreign override"
  assert_equals "$(cat "$d/nmroot/config.yaml")" "agent_path_override:
  claude: /opt/my-claude # mine" "install changed a foreign override"
  assert_absent "$d/nmroot/firstmate" "install wrote a wrapper it could not wire up"
  printf 'agent_path_override: {codex: /opt/codex}\n' > "$d/nmroot/config.yaml"
  out=$(mac_run "$d" install); rc=$?
  [ "$rc" -ne 0 ] || fail "install must refuse an inline mapping"
  assert_equals "$(cat "$d/nmroot/config.yaml")" "agent_path_override: {codex: /opt/codex}" "install changed an inline mapping"
  pass "launchd install refuses to overwrite an override it does not own"
}

test_mac_wrapper_drift_is_reported_and_repaired() {
  local d out
  d=$(make_mac_case mac-drift)
  : > "$d/nmroot/config.yaml"
  mac_run "$d" install >/dev/null
  printf '#!/bin/sh\nexec /bin/true\n' > "$d/nmroot/firstmate/claude-cache-ttl"
  assert_contains "$(mac_run "$d" check)" "wrapper for com.kunchenguid.no-mistakes.daemon.aaaa1111.plist (launchd) is different" "edited wrapper"
  mac_run "$d" install >/dev/null
  [ -z "$(mac_run "$d" check)" ] || fail "install did not repair the wrapper"
  mv "$d/fakebin/claude" "$d/claude.gone"
  assert_contains "$(PATH=/usr/bin:/bin mac_run "$d" check)" "is stale" "wrapper whose claude is gone"
  pass "launchd check reports an edited or stale wrapper and install repairs it"
}

test_mac_status_and_plist_matching() {
  local d out
  d=$(make_mac_case mac-status)
  out=$(mac_run "$d" status)
  assert_contains "$out" "com.kunchenguid.no-mistakes.daemon.aaaa1111.plist: launchd route missing" "status before install"
  : > "$d/nmroot/config.yaml"
  mac_run "$d" install >/dev/null
  assert_contains "$(mac_run "$d" status)" "launchd route current" "status after install"
  # a plist with no --root belongs to the default root; none of these plists name nmroot
  out=$(PATH="$d/fakebin:$PATH" FM_NM_DAEMON_UNIT_DIR="$d/no-systemd" FM_NM_DAEMON_LAUNCHD_DIR="$d/agents" NM_HOME="$d/no-such-root" bash "$SCRIPT" check 2>&1)
  [ -z "$out" ] || fail "a root with no plist must be silent, got: $out"
  [ ! -e "$d/launchctl.log" ] || fail "something ran launchctl"
  pass "launchd status reports the route and only this root's plist matches"
}

fm_test_run test_check_reports_a_missing_drop_in_and_writes_nothing \
  test_install_writes_the_exact_drop_in_and_never_restarts \
  test_install_is_idempotent \
  test_check_reports_a_different_drop_in_and_install_repairs_it \
  test_no_matching_unit_is_silent \
  test_status_and_usage \
  test_status_reads_the_running_daemon_environment \
  test_mac_check_reports_a_missing_override_and_writes_nothing \
  test_mac_install_sets_only_the_claude_override_and_never_touches_launchd \
  test_mac_install_is_idempotent_and_survives_a_plist_rewrite \
  test_mac_install_adds_claude_to_an_existing_override_block \
  test_mac_install_matches_the_existing_block_indentation \
  test_mac_install_leaves_a_foreign_claude_override_alone \
  test_mac_wrapper_drift_is_reported_and_repaired \
  test_mac_status_and_plist_matching
