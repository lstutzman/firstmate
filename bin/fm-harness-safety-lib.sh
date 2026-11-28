#!/usr/bin/env bash
# Safety-hook capability of each harness, owned in one place.
# Sourced by bin/fm-spawn.sh. This file has no side effects on source.
#
# Why: the fleet rules (section 9, "Harnesses without safety hooks") let a worker run
# on a harness that enforces none of the deletion, secret, push, or gate hooks only as a
# read-only scout. fm-spawn refuses a SHIP task there; a scout is never refused.
#
# The built-in table records only what the fleet rules' guards inventory states:
#   yes - claude, codex, agy: the fleet's before-Bash and file-write guards run there.
#   no  - pi, pi-signed, omp, kimi: no enforcing hooks (the same inventory).
#   Every other harness is `no` because no harness reference records the deletion,
#   secret, push, or gate hooks as wired there; that is a default, not a finding.
# A home states a different answer for its own machine in config/harness-safety-hooks,
# one `<harness> yes|no` per line (blank lines and `#` comments ignored; the last
# matching line wins). docs/configuration/harnesses.md owns the contract.
# FM_HARNESS_SAFETY_TABLE names a file in the same format that is applied after the
# home's file, and only while FM_TEST_SEAM=1 (tests/lib.sh arms both): the suite points it
# at a permissive table so launch-wiring tests can spawn any adapter, and
# tests/fm-spawn-harness-safety.test.sh unsets it.
#
# fm_harness_safety_hooks <harness> [<config-dir>] [raw] prints yes or no. A raw launch
# command names no verified adapter, so with a third argument the built-in table is
# skipped (its basename could spoof claude) and only an explicit config line can say yes.
fm_harness_safety_hooks() {
  local harness=$1 config_dir=${2:-} raw=${3:-} verdict='' file name value extra
  case "$harness" in
  claude | codex | agy) verdict=yes ;;
  *) verdict=no ;;
  esac
  [ -z "$raw" ] || verdict=no
  for file in "${config_dir:+$config_dir/harness-safety-hooks}" "${FM_TEST_SEAM:+${FM_HARNESS_SAFETY_TABLE:-}}"; do
    [ -n "$file" ] && [ -f "$file" ] || continue
    while read -r name value extra; do
      case "$name" in '' | '#'*) continue ;; esac
      [ "$name" = "$harness" ] || continue
      case "$value" in yes | no) [ -z "$extra" ] && verdict=$value ;; esac
    done < "$file"
  done
  printf '%s\n' "$verdict"
}
