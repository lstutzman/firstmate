#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty,
# and must not publish test evidence to the public evidence branch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_keeps_evidence_off_the_public_branch() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
evidence = (doc["test"] || {})["evidence"] || {}
puts evidence.key?("store_in_repo") ? evidence["store_in_repo"].inspect : "absent"
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  # Absent means the no-mistakes default, which is not a recorded decision;
  # only an explicit boolean false keeps captures off the public branch.
  [ "$val" = false ] \
    || fail "test.evidence.store_in_repo must be false so evidence is not published (docs/secret-scan.md); got: $val"
  pass "no-mistakes keeps test evidence off the public no-mistakes/evidence branch"
}

test_nm_has_no_deterministic_test_command
test_nm_keeps_evidence_off_the_public_branch
