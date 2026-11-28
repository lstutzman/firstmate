#!/usr/bin/env bash
# fm-spawn refuses a ship task on a harness with no wired safety hooks (fleet rules
# section 9) before leasing a worktree, while a scout and a hooked harness are not
# refused by that rule. bin/fm-harness-safety-lib.sh owns the table; a home states its
# own answers in config/harness-safety-hooks. This suite unsets the permissive test table
# that tests/lib.sh installs, so the production table is what runs.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
unset FM_HARNESS_SAFETY_OVERRIDE
TMP_ROOT=$(fm_test_tmproot fm-spawn-harness-safety)
home="$TMP_ROOT/home"
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake" pi)
fm_test_spawn_home "$home" claude
fm_git_init_commit "$TMP_ROOT"
real="$home/projects/real"
wt="$TMP_ROOT/wt"
fm_git_worktree "$real" "$wt" harness-safety-test
MSG='has no wired safety hooks'

# spawn <id> <harness> [extra fm-spawn args]: output in $TMP_ROOT/<id>.out, exit code in $rc.
spawn() {
  local id=$1 harness=$2
  shift 2
  fm_test_spawn_brief "$home" "$id"
  rc=0
  (cd "$home" && fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$real" --harness "$harness" "$@") > "$TMP_ROOT/$id.out" || rc=$?
}

for harness in pi pi-signed omp kimi opencode; do
  spawn "ship-$harness" "$harness" --mode no-mistakes --yolo off
  [ "$rc" -ne 0 ] || fail "$harness ship spawn succeeded: $(cat "$TMP_ROOT/ship-$harness.out")"
  assert_grep "$MSG" "$TMP_ROOT/ship-$harness.out" "$harness ship: expected the safety-hook refusal"
  assert_grep 'claude, codex, or agy' "$TMP_ROOT/ship-$harness.out" "$harness ship: the refusal must offer a hooked harness"
  [ ! -e "$home/state/ship-$harness.meta" ] || fail "$harness ship: meta was written"
done
pass 'a ship task on a hookless or unrecorded harness is refused, naming a hooked harness'

spawn scout-pi pi --scout
! grep -q "$MSG" "$TMP_ROOT/scout-pi.out" || fail "a scout on pi hit the ship-only refusal: $(cat "$TMP_ROOT/scout-pi.out")"
pass 'a scout on a hookless harness is not refused by the safety-hook rule'

spawn ship-claude claude --mode no-mistakes --yolo off
[ "$rc" -eq 0 ] || fail "a claude ship spawn was refused: $(cat "$TMP_ROOT/ship-claude.out")"
pass 'a ship task on a hooked harness still spawns'

printf '%s\n' '# pi hooks wired on this machine' 'pi yes' > "$home/config/harness-safety-hooks"
spawn ship-pi-yes pi --mode no-mistakes --yolo off
! grep -q "$MSG" "$TMP_ROOT/ship-pi-yes.out" || fail "config/harness-safety-hooks did not lift the refusal: $(cat "$TMP_ROOT/ship-pi-yes.out")"
printf '%s\n' 'claude no' > "$home/config/harness-safety-hooks"
spawn ship-claude-no claude --mode no-mistakes --yolo off
[ "$rc" -ne 0 ] || fail 'config/harness-safety-hooks could not mark claude as hookless'
assert_grep "$MSG" "$TMP_ROOT/ship-claude-no.out" 'claude no: expected the refusal'
rm -f "$home/config/harness-safety-hooks"
pass "a home's config/harness-safety-hooks overrides the built-in table"

# shellcheck source=bin/fm-harness-safety-lib.sh
. "$ROOT/bin/fm-harness-safety-lib.sh"
[ "$(fm_harness_safety_hooks agy)" = yes ] || fail 'agy must be hooked'
[ "$(fm_harness_safety_hooks no-such-harness)" = no ] || fail 'an unknown harness must default to no'
printf '%s\n' '* yes' 'kimi no' 'bogus maybe' > "$TMP_ROOT/table"
[ "$(fm_harness_safety_hooks kimi "$TMP_ROOT")" = no ] || fail 'a table in a config dir is read only as harness-safety-hooks'
mkdir -p "$TMP_ROOT/cfg"
cp "$TMP_ROOT/table" "$TMP_ROOT/cfg/harness-safety-hooks"
[ "$(fm_harness_safety_hooks pi "$TMP_ROOT/cfg")" = yes ] || fail 'a wildcard line must apply'
[ "$(fm_harness_safety_hooks kimi "$TMP_ROOT/cfg")" = no ] || fail 'the last matching line must win'
pass 'the table defaults unknown harnesses to no and honors wildcard and last-line-wins'

# A raw launch command is not a verified adapter: a spoofed basename must not count as hooked.
fm_test_spawn_brief "$home" ship-raw
rc=0
(cd "$home" && fm_test_run_spawn "$home" "$wt" "$fakebin" ship-raw "$real" --harness '/tmp/x/claude --yes' --mode no-mistakes --yolo off) > "$TMP_ROOT/ship-raw.out" || rc=$?
[ "$rc" -ne 0 ] || fail "a raw launch spoofing claude spawned a ship: $(cat "$TMP_ROOT/ship-raw.out")"
assert_grep "$MSG" "$TMP_ROOT/ship-raw.out" 'raw launch: expected the safety-hook refusal'
[ "$(fm_harness_safety_hooks claude '' raw)" = no ] || fail 'a raw launch must not take the built-in yes'
pass 'a raw launch command counts as unhooked for a ship task'
