#!/usr/bin/env bash
# Spawn setup runs in the task copy and reports recoverable install failures.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-setup)
setup_home="$TMP_ROOT/home"
proj="$TMP_ROOT/project"
wt="$TMP_ROOT/wt"
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
fm_test_spawn_home "$setup_home" claude
fm_git_worktree "$proj" "$wt" setup-test
printf 'installed-at\ndisabled-ran\n' >> "$proj/.git/info/exclude"
setup="$setup_home/config/spawn-setup/project"
run_spawn() {
  fm_test_spawn_brief "$setup_home" "$1"
  fm_test_run_spawn "$setup_home" "$wt" "$fakebin" "$1" "$proj" --mode no-mistakes --yolo off > "$TMP_ROOT/$1.out" 2>&1 || fail "spawn failed: $(cat "$TMP_ROOT/$1.out")"
}
run_spawn setup-none
[ ! -e "$setup_home/state/setup-none.setup" ] || fail 'unconfigured setup created state'
pass 'no config leaves spawn unchanged'
mkdir -p "$setup"
printf 'pwd > installed-at\n' > "$setup/10-install.sh"
run_spawn setup-installed
[ -f "$wt/installed-at" ] || fail 'setup did not install in task copy'
[ "$(cat "$wt/installed-at")" = "$wt" ] || fail 'setup ran outside task copy'
[ ! -e "$proj/installed-at" ] || fail 'setup changed project copy'
assert_grep 'passed' "$setup_home/state/setup-installed.setup/10-install.log" 'setup result not logged'
pass 'configured setup runs in task copy with logged output'
printf 'touch disabled-ran\n' > "$setup/20-disabled.sh"
touch "$setup/20-disabled.off"
run_spawn setup-disabled
[ ! -e "$wt/disabled-ran" ] || fail 'disabled step ran'
[ ! -e "$setup_home/state/setup-disabled.setup/20-disabled.log" ] || fail 'disabled step created log'
pass 'individual off switch skips its step'
printf 'printf "install failed\\n"; exit 7\n' > "$setup/30-fail.sh"
run_spawn setup-failed
assert_grep 'spawned setup-failed' "$TMP_ROOT/setup-failed.out" 'failure prevented worker launch'
assert_grep '30-fail failed (exit 7)' "$setup_home/data/setup-failed/launch-brief.md" 'worker did not receive failure'
assert_grep 'setup-failed.setup/30-fail.log' "$setup_home/data/setup-failed/launch-brief.md" 'worker did not receive log path'
assert_grep 'install failed' "$setup_home/state/setup-failed.setup/30-fail.log" 'command output missing'
pass 'failed install is logged and reported while spawn succeeds'
rm -f "$setup/30-fail.sh"
direct="$TMP_ROOT/direct"
mkdir -p "$direct/config" "$direct/bin"
printf 'touch timeout-ran\n' > "$direct/config/10-slow.sh"
cat > "$direct/bin/timeout" <<'SH'
#!/usr/bin/env bash
for last; do :; done
printf 'bound=%s command=%s\n' "$3" "$last" > "$FM_FAKE_TIMEOUT_ARGS"
exit 124
SH
chmod +x "$direct/bin/timeout"
: > "$direct/brief.md"
FM_TIMEOUT_MECHANISM_OVERRIDE='' FM_FAKE_TIMEOUT_ARGS="$direct/timeout-args" PATH="$direct/bin:$PATH" \
  bash "$ROOT/bin/fm-spawn-setup.sh" "$direct/config" "$wt" "$direct/logs" "$direct/brief.md" 2>/dev/null ||
  fail 'timed-out setup failed the helper'
[ "$(cat "$direct/timeout-args")" = "bound=600 command=$(cd "$direct/config" && pwd -P)/10-slow.sh" ] ||
  fail "setup step was not bounded at 600 seconds: $(cat "$direct/timeout-args")"
assert_grep '10-slow failed (timed out after 600s)' "$direct/brief.md" 'timeout not reported'
assert_grep 'direct/logs/10-slow.log' "$direct/brief.md" 'timeout log path not reported'
pass 'each step is bounded at the fixed 600-second deadline and a timeout is reported'
wt2="$TMP_ROOT/wt2"
git -C "$proj" worktree add --quiet -b setup-test-2 "$wt2"
gate="$TMP_ROOT/gate"
mkdir -p "$gate"
printf 'block-setup\n' >> "$proj/.git/info/exclude"
touch "$wt/block-setup"
cat > "$setup/40-block.sh" <<SH
[ -e block-setup ] || exit 0
touch '$gate/entered'
n=0
while [ ! -e '$gate/release' ] && [ "\$n" -lt 600 ]; do sleep 0.1; n=\$((n + 1)); done
SH
run_spawn setup-blocked &
blocked_pid=$!
n=0
while [ ! -e "$gate/entered" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
[ -e "$gate/entered" ] || { touch "$gate/release"; wait "$blocked_pid" || true; fail 'blocking setup never started'; }
fm_test_spawn_brief "$setup_home" setup-concurrent
concurrent_rc=0
fm_test_run_spawn "$setup_home" "$wt2" "$fakebin" setup-concurrent "$proj" --mode no-mistakes --yolo off > "$TMP_ROOT/setup-concurrent.out" 2>&1 || concurrent_rc=$?
touch "$gate/release"
wait "$blocked_pid" || fail "blocked spawn failed: $(cat "$TMP_ROOT/setup-blocked.out")"
[ "$concurrent_rc" -eq 0 ] || fail "concurrent spawn was refused while setup ran: $(cat "$TMP_ROOT/setup-concurrent.out")"
assert_grep 'spawned setup-concurrent' "$TMP_ROOT/setup-concurrent.out" 'concurrent spawn did not launch'
assert_grep 'spawned setup-blocked' "$TMP_ROOT/setup-blocked.out" 'blocked spawn did not launch'
pass 'a long setup does not block another spawn in the same home and project'
rm -f "$setup/40-block.sh" "$wt/block-setup"
touch "$setup/off"
run_spawn setup-off
[ ! -e "$setup_home/state/setup-off.setup" ] || fail 'project off switch still ran setup'
pass 'project off switch skips all setup'
