#!/usr/bin/env bash
# Run optional dependency setup before a fresh ship/scout starts.
# Usage: bash fm-spawn-setup.sh <project-config-dir> <task-copy> <log-dir> <launch-brief>
# docs/configuration.md owns the configuration schema. The caller must validate
# task-copy isolation first; this helper never allocates or repairs a copy.
# All setup failures are advisory and appended to the private launch brief.
set -u
# shellcheck source=bin/fm-timeout-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-timeout-lib.sh"
config=$1
copy=$2
logs=$3
brief=$4
seconds=600
[ -d "$config" ] && [ ! -e "$config/off" ] || exit 0
config=$(cd "$config" && pwd -P) || exit 1
report_failure() {
  printf '\nSpawn dependency setup: %s. Rerun this install inside the task copy before testing. Log: %s\n' "$1" "$2" | tee -a "$brief" >&2
}
for script in "$config"/*.sh; do
  [ -f "$script" ] || continue
  step=${script##*/}
  step=${step%.sh}
  [ ! -e "$config/$step.off" ] || continue
  if ! mkdir -p "$logs"; then
    report_failure "$step could not start (cannot create log directory)" "$logs"
    continue
  fi
  log="$logs/$step.log"
  result=0
  (cd "$copy" && fm_run_timed "$seconds" bash "$script") > "$log" 2>&1 || result=$?
  if [ "$result" -eq 0 ]; then
    printf '\nSetup %s passed.\n' "$step" >> "$log"
  else
    reason="exit $result"
    if fm_timed_out "$result"; then reason="timed out after ${seconds}s"; fi
    printf '\nSetup %s failed: %s.\n' "$step" "$reason" >> "$log"
    report_failure "$step failed ($reason)" "$log"
  fi
done
exit 0
