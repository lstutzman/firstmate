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
printf 'while :; do :; done\n' > "$setup/40-timeout.sh"
printf '1\n' > "$setup/40-timeout.timeout"
started=$(date +%s)
run_spawn setup-timeout
elapsed=$(($(date +%s) - started))
[ "$elapsed" -lt 20 ] || fail "setup timeout took ${elapsed}s"
assert_grep '40-timeout failed (timed out after 1s)' "$setup_home/data/setup-timeout/launch-brief.md" 'timeout not reported'
assert_grep 'spawned setup-timeout' "$TMP_ROOT/setup-timeout.out" 'timeout prevented worker launch'
pass "setup timeout is enforced and worker still launches (${elapsed}s total spawn)"
printf 'touch invalid-ran\n' > "$setup/50-invalid.sh"
printf '0\n' > "$setup/50-invalid.timeout"
run_spawn setup-invalid
[ ! -e "$wt/invalid-ran" ] || fail 'invalid timeout ran unbounded setup'
assert_grep '50-invalid failed (invalid timeout)' "$setup_home/data/setup-invalid/launch-brief.md" 'invalid timeout not reported'
pass 'invalid timeout skips the command and reports failure'
touch "$setup/off"
run_spawn setup-off
[ ! -e "$setup_home/state/setup-off.setup" ] || fail 'project off switch still ran setup'
pass 'project off switch skips all setup'
