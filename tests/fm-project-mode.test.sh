#!/usr/bin/env bash
# tests/fm-project-mode.test.sh - unit tests for the `forgejo` and `external`
# values of bin/fm-project-mode.sh's closed `forge=` registry binding. The
# binding's grammar, its Gerrit value, and its refusals are pinned in
# tests/fm-task-delivery.test.sh; this file covers only what forgejo and
# external add: forgejo binds in any token order, keeps +yolo (unlike gerrit),
# and is refused on local-only like every forge; external binds, reports
# yolo=off with a refusal like gerrit, and is refused on local-only; and the
# plain (no --forge/--raw) output stays exactly two words, because tests/fm-secondmate-safety.test.sh and
# tests/fm-secondmate-lifecycle-e2e.test.sh assert that shape with strict
# string equality.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-mode-tests)
DATA="$TMP_ROOT/data"
mkdir -p "$DATA"

cat > "$DATA/projects.md" <<'EOF'
## Projects
- legacy - a project registered before any bracket token existed (added 2026-01-01)
- flagged [direct-PR +yolo] - mode and yolo, no forge token (added 2026-01-01)
- lab [no-mistakes forge=forgejo] - forge token after mode (added 2026-01-01)
- lead [forge=forgejo direct-PR +yolo] - forge token first, order must not matter (added 2026-01-01)
- kept [local-only forge=forgejo] - a forge on a mode that publishes nothing (added 2026-01-01)
- colon [no-mistakes forge:forgejo] - a colon-spelled token is not a forge binding (added 2026-01-01)
- glabbed [no-mistakes forge=gitlab] - gitlab is not a forge value (added 2026-01-01)
- reviewed [direct-PR forge=external] - a review tool uploads its own snapshot (added 2026-01-01)
- reviewed-yolo [direct-PR +yolo forge=external] - +yolo cannot apply to an external review (added 2026-01-01)
- reviewed-local [local-only forge=external] - an external review on a mode that publishes nothing (added 2026-01-01)
- near-miss [direct-PR forg=external] - a near miss of the forge key (added 2026-01-01)
- landed [direct-PR +yolo merger=slarti] - one home merges this project (added 2026-01-01)
- landed-first [merger=slarti no-mistakes] - merger token first, order must not matter (added 2026-01-01)
- landed-blank [direct-PR merger=] - an empty merger binding (added 2026-01-01)
- landed-bad [direct-PR merger=sl/arti] - a merger that is not a home id (added 2026-01-01)
- lagged [no-mistakes +yolo merger=slarti landing-lag=48] - landing lag limited to 48 hours (added 2026-01-01)
- lagged-first [landing-lag=12 direct-PR] - landing-lag token first, order must not matter (added 2026-01-01)
- lagged-blank [direct-PR landing-lag=] - an empty landing-lag value (added 2026-01-01)
- lagged-zero [direct-PR landing-lag=0] - a zero landing lag (added 2026-01-01)
- lagged-word [direct-PR landing-lag=2d] - a landing lag that is not whole hours (added 2026-01-01)
- lagged-long [direct-PR landing-lag=1234567] - a landing lag longer than six digits (added 2026-01-01)
EOF

run_mode() {
  FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" "$1" 2>/dev/null
}
run_forge() {
  FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --forge "$1" 2>/dev/null
}

[ "$(run_mode legacy)" = "no-mistakes off" ] || fail "legacy entry's default output changed: $(run_mode legacy)"
[ "$(run_forge legacy)" = "none" ] || fail "an entry with no forge token must report forge none: $(run_forge legacy)"
[ "$(run_mode flagged)" = "direct-PR on" ] || fail "flagged entry's mode/yolo output changed: $(run_mode flagged)"
[ "$(run_forge flagged)" = "none" ] || fail "mode and +yolo with no forge token must report forge none: $(run_forge flagged)"
pass "fm-project-mode: an entry with no forge token reports forge none and keeps its two-word default output"

[ "$(run_mode lab)" = "no-mistakes off" ] || fail "lab entry's mode output changed: $(run_mode lab)"
[ "$(run_forge lab)" = "forgejo" ] || fail "forge=forgejo after the mode token did not resolve: $(run_forge lab)"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" lab 2>&1 >/dev/null)
[ -z "$err" ] || fail "a registered forge=forgejo warned: $err"
pass "fm-project-mode: forge=forgejo placed after the mode token binds forgejo without a warning"

[ "$(run_mode lead)" = "direct-PR on" ] || fail "forge=forgejo must keep +yolo, which only gerrit deactivates: $(run_mode lead)"
[ "$(run_forge lead)" = "forgejo" ] || fail "forge=forgejo placed before the mode token did not resolve: $(run_forge lead)"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" lead 2>&1 >/dev/null)
[ -z "$err" ] || fail "+yolo on a forge=forgejo project was refused or warned: $err"
pass "fm-project-mode: forge=forgejo binds in any token order and keeps +yolo"

for flag in "" --forge; do
  # shellcheck disable=SC2086 # An empty flag must expand to nothing.
  out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" $flag kept 2>/dev/null)
  status=$?
  [ "$status" -eq 3 ] || fail "local-only with forge=forgejo did not refuse${flag:+ under $flag} (status $status, got '$out')"
  [ -z "$out" ] || fail "a refused local-only forge still handed the caller a posture: '$out'"
done
pass "fm-project-mode: forge=forgejo on local-only is refused like every forge"

[ "$(run_mode colon)" = "no-mistakes off" ] || fail "a colon-spelled token changed the posture: $(run_mode colon)"
[ "$(run_forge colon)" = "none" ] || fail "forge:forgejo must not bind a forge; only forge=forgejo does: $(run_forge colon)"
pass "fm-project-mode: the colon spelling forge:forgejo is not a forge binding"

for flag in "" --forge; do
  # shellcheck disable=SC2086 # An empty flag must expand to nothing.
  out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" $flag glabbed 2>/dev/null)
  status=$?
  [ "$status" -eq 3 ] || fail "forge=gitlab did not refuse${flag:+ under $flag} (status $status, got '$out')"
  [ -z "$out" ] || fail "a refused forge=gitlab still handed the caller a posture: '$out'"
done
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" glabbed 2>&1 >/dev/null) || true
assert_contains "$err" 'forge=forgejo' "the unknown-forge refusal did not name forge=forgejo as an accepted value"
assert_contains "$err" 'forge=external' "the unknown-forge refusal did not name forge=external as an accepted value"
pass "fm-project-mode: a value outside none|gerrit|forgejo|external is refused and the refusal names the accepted values"

[ "$(run_forge reviewed)" = "external" ] || fail "forge=external did not resolve: $(run_forge reviewed)"
[ "$(run_mode reviewed)" = "direct-PR off" ] || fail "forge=external changed the two-word output: $(run_mode reviewed)"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" reviewed 2>&1 >/dev/null)
[ -z "$err" ] || fail "a registered forge=external warned: $err"
[ "$(run_mode reviewed-yolo)" = "direct-PR off" ] || fail "+yolo on forge=external must report yolo=off: $(run_mode reviewed-yolo)"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" reviewed-yolo 2>&1 >/dev/null)
assert_contains "$err" "yolo is inactive for forge=external" "+yolo on forge=external was dropped without a refusal"
for flag in "" --forge; do
  # shellcheck disable=SC2086 # An empty flag must expand to nothing.
  out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" $flag reviewed-local 2>/dev/null)
  status=$?
  [ "$status" -eq 3 ] || fail "local-only with forge=external did not refuse${flag:+ under $flag} (status $status, got '$out')"
  [ -z "$out" ] || fail "a refused local-only external forge still handed the caller a posture: '$out'"
done
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" near-miss 2>&1 >/dev/null)
assert_contains "$err" "forge=external" "the near-miss warning does not list forge=external"
pass "fm-project-mode: forge=external binds direct-PR, reports yolo=off with a refusal, and is refused on local-only"

[ "$(run_forge missing-project)" = "none" ] || fail "a missing project must default --forge to none: $(run_forge missing-project)"
[ "$(FM_DATA_OVERRIDE="$TMP_ROOT/no-such-dir" "$PROJECT_MODE" --forge legacy 2>/dev/null)" = "none" ] \
  || fail "an absent registry file must default --forge to none"
pass "fm-project-mode: a missing project or absent registry defaults --forge to none"

run_merger() {
  FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --merger "$1" 2>/dev/null
}
[ "$(run_merger landed)" = "slarti" ] || fail "merger=slarti did not resolve: $(run_merger landed)"
[ "$(run_mode landed)" = "direct-PR on" ] || fail "a merger token changed the two-word output: $(run_mode landed)"
[ "$(run_merger landed-first)" = "slarti" ] || fail "merger= placed before the mode did not resolve: $(run_merger landed-first)"
[ "$(run_mode landed-first)" = "no-mistakes off" ] || fail "merger= placed before the mode was read as the mode: $(run_mode landed-first)"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" landed-first 2>&1 >/dev/null)
[ -z "$err" ] || fail "a registered merger= warned: $err"
pass "fm-project-mode: merger=<home> binds in any token order and leaves the default output unchanged"

for name in landed-blank landed-bad; do
  out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --merger "$name" 2>/dev/null)
  status=$?
  [ "$status" -eq 3 ] || fail "a malformed merger for $name did not refuse (status $status, got '$out')"
  [ -z "$out" ] || fail "a refused merger for $name still printed '$out'"
done
pass "fm-project-mode: an empty or malformed merger binding is refused under --merger"

out=$(run_merger legacy); status=$?
[ "$status" -eq 0 ] && [ -z "$out" ] || fail "an entry with no merger token must print nothing (status $status, got '$out')"
out=$(run_merger missing-project); status=$?
[ "$status" -eq 0 ] && [ -z "$out" ] || fail "a missing project must print no merger (status $status, got '$out')"
out=$(FM_DATA_OVERRIDE="$TMP_ROOT/no-such-dir" "$PROJECT_MODE" --merger legacy 2>/dev/null); status=$?
[ "$status" -eq 0 ] && [ -z "$out" ] || fail "an absent registry must print no merger (status $status, got '$out')"
pass "fm-project-mode: no merger token, a missing project, or an absent registry prints no merger"

run_lag() {
  FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --landing-lag "$1" 2>/dev/null
}
[ "$(run_lag lagged)" = "48" ] || fail "landing-lag=48 did not resolve: $(run_lag lagged)"
[ "$(run_mode lagged)" = "no-mistakes on" ] || fail "a landing-lag token changed the two-word output: $(run_mode lagged)"
[ "$(run_merger lagged)" = "slarti" ] || fail "a landing-lag token disturbed the merger binding: $(run_merger lagged)"
[ "$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --branch-prefix lagged 2>/dev/null)" = "fm/" ] \
  || fail "a landing-lag token disturbed the branch prefix"
[ "$(run_lag lagged-first)" = "12" ] || fail "landing-lag= placed before the mode did not resolve: $(run_lag lagged-first)"
[ "$(run_mode lagged-first)" = "direct-PR off" ] || fail "landing-lag= placed before the mode was read as the mode: $(run_mode lagged-first)"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" lagged-first 2>&1 >/dev/null)
[ -z "$err" ] || fail "a registered landing-lag= warned: $err"
pass "fm-project-mode: landing-lag=<hours> binds in any token order and leaves the other outputs unchanged"

for name in lagged-blank lagged-zero lagged-word lagged-long; do
  out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --landing-lag "$name" 2>/dev/null)
  status=$?
  [ "$status" -eq 3 ] || fail "a malformed landing lag for $name did not refuse (status $status, got '$out')"
  [ -z "$out" ] || fail "a refused landing lag for $name still printed '$out'"
done
pass "fm-project-mode: an empty, zero, non-integer, or over-long landing lag is refused under --landing-lag"

out=$(run_lag legacy); status=$?
[ "$status" -eq 0 ] && [ -z "$out" ] || fail "an entry with no landing-lag token must print nothing (status $status, got '$out')"
out=$(run_lag missing-project); status=$?
[ "$status" -eq 0 ] && [ -z "$out" ] || fail "a missing project must print no landing lag (status $status, got '$out')"
out=$(FM_DATA_OVERRIDE="$TMP_ROOT/no-such-dir" "$PROJECT_MODE" --landing-lag legacy 2>/dev/null); status=$?
[ "$status" -eq 0 ] && [ -z "$out" ] || fail "an absent registry must print no landing lag (status $status, got '$out')"
pass "fm-project-mode: no landing-lag token, a missing project, or an absent registry prints no landing lag"

echo "# fm-project-mode.test.sh: all assertions passed"
