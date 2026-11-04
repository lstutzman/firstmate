#!/usr/bin/env bash
# Live drive of fm-office.sh wake sources + fm-officer.sh consumer: in disposable lab homes.
set -u
R=$1   # worktree root
export TZ=UTC
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
P=$LAB/primary; N=$LAB/navigator; A=$LAB/archive
"$R/bin/fm-lab-home.sh" create "$P" >/dev/null; "$R/bin/fm-lab-home.sh" create "$N" >/dev/null
chmod 700 "$P/state" "$N/state"
DATE=2026-10-23; NOW=1792825200
. "$R/tests/officer-helpers.sh" 2>/dev/null
printf '{"sessions": [{"machine": "alpha", "id": "s1", "first_prompt": "hello", "calls": [["Bash", {"command": "rm -f /tmp/x"}, "", false]]}]}\n' > $LAB/spec.json
officer_archive "$A" "$DATE" $LAB/spec.json
printf -- '- triage - t (role: triage; cadence: daily 06:00; archive: %s; hosts: alpha; model: none; consumer: navigator; added 2026-10-24)\n' "$A" > "$P/data/officers.md"
printf 'navigator\n' > "$N/.fm-office"
printf '# Charter\n\n# Office authority\n' > "$N/data/charter.md"
printf -- '- PropertyCompass2 [direct-PR merger=slarti] - app (added 2026-10-02)\n' > "$N/data/projects.md"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$N/.fm-secondmate-parent"
printf -- '- navigator - office (home: %s; scope: office; projects: none; added 2026-11-04)\n' "$N" > "$P/data/secondmates.md"
setsrc() { printf '# Offices\n\n- navigator - Drive progress (role: navigator; runs-on: lab; dispatch: PropertyCompass2; merge: none; merge-via: PropertyCompass2=slarti; auto-merge-classes: none; wip: 2; tick: every 2h; sources: %s; added 2026-11-04)\n' "$1" > "$P/data/offices.md"; }
off() { FM_HOME="$1" FM_OFFICE_HOST=lab "$R/bin/fm-office.sh" "${@:2}"; }
ofr() { FM_OFFICER_NOW=$NOW FM_HOME="$P" "$R/bin/fm-officer.sh" "$@"; }
# one real watcher sweep in the office home; prints the wake reason
sweep() { rm -f "$N/state/.last-check" "$N/state/.watcher-down" "$N/state/.wake-queue"; FM_HOME="$N" FM_CHECK_INTERVAL=0 FM_POLL=1 FM_HEARTBEAT=100000 timeout 40 "$R/bin/fm-watch.sh" 2>&1 | tail -n 5; echo "[watcher rc=${PIPESTATUS[0]}]"; }

echo "=== S1 register-sources (sources with a space after a comma) ==="
setsrc 'tick, lane:triage,lane:triage:high'
off "$N" register-sources; echo "rc=$?"
ls "$N/state" | grep office-
echo "--- fm-office ensure in primary (expect no OFFICE: lines)"; FM_HOME="$P" FM_OFFICE_HOST=lab "$R/bin/fm-office.sh" ensure; echo "rc=$?"
echo "--- fm-officer register/ensure triage with consumer: navigator"
ofr register triage; echo "rc=$?"; ofr ensure; echo "ensure rc=$?"

echo "=== S2 officer run writes digest; main check stays silent ==="
ofr run triage --date $DATE >/dev/null; echo "run rc=$?"; cat "$P/data/officers/triage/digest"
out=$(ofr check triage); echo "main check output: [$out]"

echo "=== S3 office watcher sweep wakes the office with the lane digest ==="
sweep
echo "--- second sweep of same digest (expect no lane line repeat)"
sweep

echo "=== S4 high lane: write a high-severity finding into the digest .json ==="
path=$(awk '{print $4}' "$P/data/officers/triage/digest"); case $path in /*) ;; *) path=$P/$path;; esac
printf '{"findings":[{"severity":"high","title":"x"},{"severity":"low"},{"severity":5}]}\n' > "${path%.md}.json"
FM_HOME="$N" "$N/state/office-lane-triage-high.check.sh"; echo "rc=$?"
FM_HOME="$N" "$N/state/office-lane-triage-high.check.sh"; echo "repeat rc=$? (silent expected)"

echo "=== S5 tick via shim with queued backlog ==="
printf '## In flight\n\n## Queued\n- [ ] job-a - A (repo: x) (kind: ship)\n- [ ] h - H (repo: x) (hold: c)\n\n## Done\n' > "$N/data/backlog.md"
FM_OFFICE_NOW=$NOW "$N/state/office-tick.check.sh"; echo "rc=$?"
printf 'kind=ship\n' > "$N/state/t1.meta"; printf 'kind=scout\n' > "$N/state/t2.meta"
FM_OFFICE_NOW=$((NOW+7200)) "$N/state/office-tick.check.sh"; echo "full places rc=$? (silent expected)"
rm "$N/state/t1.meta" "$N/state/t2.meta"

echo "=== S6 adversarial: office drops lane:triage -> main is woken again, ensure reports ==="
setsrc 'tick'
off "$N" register-sources
rm -f "$P/data/officers/triage/.digest.reported" "$P/state/triage.reported" 2>/dev/null
ofr run triage --date $DATE --force >/dev/null 2>&1 || ofr run triage --date $DATE >/dev/null 2>&1
out=$(ofr check triage); echo "main check output: [$out]"
ofr ensure
echo "--- lane check with source no longer listed (silent expected)"; FM_HOME="$N" "$R/bin/fm-office.sh" check lane:triage; echo "rc=$?"

echo "=== S7 adversarial: tampered shim is untrusted -> ensure gap, watcher rejects, consumer falls back ==="
setsrc 'tick,lane:triage'; off "$N" register-sources >/dev/null
printf 'echo pwned\n' >> "$N/state/office-lane-triage.check.sh"
FM_HOME="$P" FM_OFFICE_HOST=lab "$R/bin/fm-office.sh" ensure
ofr ensure
sweep
echo "=== S8 register refuses consumer office that is remote ==="
printf -- '- navigator - nav (host: deepthought; root: /r; home: /r/navigator; scope: office; projects: PropertyCompass2; added 2026-11-04)\n' > "$P/data/secondmates.md"
ofr register triage; echo "register rc=$? (nonzero expected)"
