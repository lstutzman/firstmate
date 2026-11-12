#!/usr/bin/env bash
# fm_atomic_mkdir must give exactly one winner per directory however the system
# mkdir behaves (uutils coreutils 0.10.0 lets several racers win).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-atomic-mkdir)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
# shellcheck source=bin/fm-atomic-lib.sh
. "$ROOT/bin/fm-atomic-lib.sh"

# A mkdir that reports success even when the directory exists: the worst case of
# a non-atomic system mkdir, put first on PATH.
mkdir -p "$TMP_ROOT/stub"
printf '#!/bin/sh\nfor a; do last=$a; done\n/bin/mkdir -p -- "$last"\nexit 0\n' > "$TMP_ROOT/stub/mkdir"
chmod +x "$TMP_ROOT/stub/mkdir"
PATH="$TMP_ROOT/stub:$PATH"

N=20
ROUNDS=5
race() { # <round-dir> <claim-fn>: print the number of winners
  local dir=$1 fn=$2 i
  mkdir -p "$dir/out"
  for i in $(seq 1 "$N"); do
    ( if $fn "$dir/claim"; then : > "$dir/out/win.$i"; fi ) &
  done
  wait
  find "$dir/out" -name 'win.*' | wc -l | tr -d ' '
}
stub_claim() { mkdir "$1" 2>/dev/null; }

for r in $(seq 1 "$ROUNDS"); do
  winners=$(race "$TMP_ROOT/atomic.$r" fm_atomic_mkdir)
  [ "$winners" = 1 ] || fail "round $r: fm_atomic_mkdir gave $winners winners, want exactly 1"
done
# The stub must make the plain-mkdir claim lose exclusivity, or the test proves nothing.
winners=$(race "$TMP_ROOT/plain" stub_claim)
[ "$winners" -gt 1 ] || fail "stub mkdir produced only $winners winners; the race test would be vacuous"

# The remote job sequence claim, under the same stub: 20 concurrent allocators
# must get the 20 distinct sequence numbers 1..20.
mkdir -p "$TMP_ROOT/account"
mkdir -p "$TMP_ROOT/seq-out"
export FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-job"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
fm_remote_job_prepare_state "$TMP_ROOT/account" || fail "$FM_REMOTE_JOB_ERROR"
pids=()
for i in $(seq 1 "$N"); do
  fm_remote_job_next_seq > "$TMP_ROOT/seq-out/$i" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || fail "a concurrent sequence allocator failed"; done
[ "$(cat "$TMP_ROOT"/seq-out/* | sort -n)" = "$(seq 1 "$N")" ] \
  || fail "concurrent sequence claims were not distinct: $(cat "$TMP_ROOT"/seq-out/* | sort -n | tr '\n' ' ')"

# Contract: mode 0700, existing dir loses, bad parent fails, bad usage fails.
( umask 022; fm_atomic_mkdir "$TMP_ROOT/mode" ) || fail "fresh claim failed"
[ "$(stat -c %a "$TMP_ROOT/mode" 2>/dev/null || stat -f %Lp "$TMP_ROOT/mode")" = 700 ] || fail "claim is not mode 0700"
fm_atomic_mkdir "$TMP_ROOT/mode" 2>/dev/null && fail "claim of an existing directory succeeded"
fm_atomic_mkdir "$TMP_ROOT/no/such/parent" 2>/dev/null && fail "claim under a missing parent succeeded"
fm_atomic_mkdir 2>/dev/null && fail "claim with no argument succeeded"
echo "PASS: fm-atomic-mkdir"
