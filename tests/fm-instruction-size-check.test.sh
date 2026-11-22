#!/usr/bin/env bash
# Regression tests for bin/fm-instruction-size-check.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-instruction-size-check.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-instr-size.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/docs"
head -c 1000 /dev/zero | tr '\0' 'a' > "$TMP_ROOT/AGENTS.md"

run() { "$CHECK" --root "$TMP_ROOT" 2>&1; }

printf '{"AGENTS.md": 1000}\n' > "$TMP_ROOT/docs/instruction-size-pins.json"
out=$(run) || fail "a file at its pin should pass: $out"
assert_contains "$out" "ok files=1" "pass output"

printf '{"AGENTS.md": 999}\n' > "$TMP_ROOT/docs/instruction-size-pins.json"
if out=$(run); then fail "a file over its pin should fail"; fi
assert_contains "$out" "over its pin of 999" "over-pin message"

printf '{"AGENTS.md": 1512}\n' > "$TMP_ROOT/docs/instruction-size-pins.json"
if out=$(run); then fail "a file 512 bytes under its pin should fail"; fi
assert_contains "$out" "lower the pin to 1000" "stale-pin message"

printf '{"AGENTS.md": 1511}\n' > "$TMP_ROOT/docs/instruction-size-pins.json"
run >/dev/null || fail "a file 511 bytes under its pin should pass"

printf '{"MISSING.md": 10}\n' > "$TMP_ROOT/docs/instruction-size-pins.json"
if out=$(run); then fail "a missing pinned file should fail"; fi
assert_contains "$out" "pinned but missing" "missing message"

"$CHECK" >/dev/null 2>&1 || fail "the repository's own pins do not hold"
echo "ok - fm-instruction-size-check.sh"
echo FM_TEST_COMPLETE
