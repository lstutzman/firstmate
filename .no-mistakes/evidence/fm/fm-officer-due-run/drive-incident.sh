#!/usr/bin/env bash
# Live replay of the 29->30 Oct incident against a disposable FM_HOME.
# usage: drive-incident.sh <repo-root> <label>
set -u
REPO=$1; LABEL=$2
export TZ=UTC
. "$REPO/tests/officer-helpers.sh"
OFF="$REPO/bin/fm-officer.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-officer-lab.XXXXXX")
D=2026-10-29
M_1835=$(date -u -d '2026-10-29T18:35:47Z' +%s)
C_0559=$(date -u -d '2026-10-30T05:59:00Z' +%s)
C_0700=$(date -u -d '2026-10-30T07:00:00Z' +%s)
C_0630=$(date -u -d '2026-10-30T06:30:00Z' +%s)
waitdone() { local i=0; until [ "$(grep -c " $D " "$1/data/officers/triage/runs.log")" -ge "$2" ] && [ ! -d "$1/data/officers/triage/.run.lock" ]; do i=$((i+1)); [ $i -lt 300 ] || { echo "  (timed out waiting for run $2)"; return 1; }; sleep 0.1; done; }
world() { local h="$LAB/$1/home" a="$LAB/$1/archive"; officer_home "$h"
  printf '{"sessions": [{"machine": "alpha", "id": "s1", "first_prompt": "hello", "calls": [["Bash", {"command": "rm -f /tmp/x"}, "", false]]}]}\n' > "$LAB/$1/spec.json"
  officer_archive "$a" "$D" "$LAB/$1/spec.json"; officer_registry "$h" "$a" alpha "daily 06:00"
  FM_HOME="$h" "$OFF" register triage >/dev/null; printf '%s' "$h"; }
echo "== [$LABEL] Scenario A: incident replay — manual run for $D at 29 Oct 18:35Z, watcher check at 30 Oct 05:59Z then 07:00Z"
H=$(world incident)
FM_OFFICER_NOW=$M_1835 FM_HOME="$H" "$OFF" run triage --date "$D" >/dev/null && echo "  manual run done"
echo "  runs.log after manual run:"; sed 's/^/    /' "$H/data/officers/triage/runs.log"
FM_OFFICER_NOW=$C_0559 FM_HOME="$H" bash "$H/state/officer-triage.check.sh"; sleep 1
echo "  after 05:59 check, runs logged for $D: $(grep -c " $D " "$H/data/officers/triage/runs.log") (expect 1: before cadence)"
FM_OFFICER_NOW=$C_0700 FM_HOME="$H" bash "$H/state/officer-triage.check.sh"
waitdone "$H" 2
echo "  after 07:00 check, runs.log:"; sed 's/^/    /' "$H/data/officers/triage/runs.log"
echo "  scheduled run-output.log present: $([ -f "$H/data/officers/triage/run-output.log" ] && echo yes || echo no)"
echo "  next check output: $(FM_OFFICER_NOW=$C_0700 FM_HOME="$H" "$OFF" check triage)"
echo "== [$LABEL] Scenario B: adversarial — manual run at 30 Oct 06:30Z (after cadence), check at 07:00Z with retry gate off"
H=$(world late)
FM_OFFICER_NOW=$C_0630 FM_HOME="$H" "$OFF" run triage --date "$D" >/dev/null
FM_OFFICER_NOW=$C_0700 FM_OFFICER_RETRY_SECS=0 FM_HOME="$H" bash "$H/state/officer-triage.check.sh"; sleep 2
echo "  runs logged for $D: $(grep -c " $D " "$H/data/officers/triage/runs.log") (expect 1); run started: $([ -e "$H/data/officers/triage/run-output.log" ] || [ -d "$H/data/officers/triage/.run.lock" ] && echo yes || echo no)"
echo "== [$LABEL] Scenario C: scheduled run is not repeated by later checks the same morning (retry gate off)"
H="$LAB/incident/home"; [ -d "$H/data/officers/triage/.run.lock" ] && echo "  lock held!"
mv "$H/data/officers/triage/run-output.log" "$H/data/officers/triage/run-output.first.log" 2>/dev/null
FM_OFFICER_NOW=$((C_0700+600)) FM_OFFICER_RETRY_SECS=0 FM_HOME="$H" bash "$H/state/officer-triage.check.sh"; sleep 2
echo "  runs logged for $D: $(grep -c " $D " "$H/data/officers/triage/runs.log") (expect 2); new run started: $([ -e "$H/data/officers/triage/run-output.log" ] && echo yes || echo no)"
rm -rf "$LAB"
