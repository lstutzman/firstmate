#!/usr/bin/env bash
# Drives docs/office-provisioning.md step 9 verbatim against a disposable fleet
# (main + local navigator + quartermaster homes). Usage: step9-live.sh <repo-root>
set -u
REPO=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-step9.XXXXXX")
MAIN=$T/main NAV_HOME=$T/navigator QM_HOME=$T/quartermaster
export -n FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE 2>/dev/null
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
mkdir -p "$MAIN/data" "$MAIN/state" "$T/archive"; chmod 700 "$MAIN/state"
for h in "$NAV_HOME:navigator" "$QM_HOME:quartermaster"; do
  d=${h%%:*}; id=${h##*:}; mkdir -p "$d/data" "$d/state"; chmod 700 "$d/state"
  printf '%s\n' "$id" > "$d/.fm-office"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" > "$d/.fm-secondmate-parent"
done
printf -- '- navigator - nav (home: %s; scope: office; projects: PropertyCompass2; added 2026-11-04)\n- quartermaster - qm (home: %s; scope: office; projects: firstmate,skills,fleet-app; added 2026-11-04)\n' "$NAV_HOME" "$QM_HOME" > "$MAIN/data/secondmates.md"
# Step 2 office lines, verbatim from the doc.
printf '# Offices\n\n' > "$MAIN/data/offices.md"
sed -n '/^cat >> "\$MAIN\/data\/offices.md" <<.EOF.$/,/^EOF$/p' "$REPO/docs/office-provisioning.md" | sed '1d;$d' >> "$MAIN/data/offices.md"
# Officers present before step 9: triage + progress, and the Surgeon line as its docs give it (no consumer yet).
cat > "$MAIN/data/officers.md" <<L
- triage - Joins archived sessions (role: triage; cadence: daily 06:00; archive: $T/archive; hosts: alpha; model: none; added 2026-10-24)
- progress - Starts authorised unstarted work through firstmate (role: progress; cadence: daily 07:00; team: PC; repos: example/project; requested: PC-123; model: none; added 2026-10-26)
- surgeon - Triage plus intake (role: surgeon; cadence: daily 06:00; archive: $T/archive; hosts: alpha; app: https://app.test; model: none; added 2026-11-04)
L
cd "$REPO"
FM_HOME=$NAV_HOME bin/fm-office.sh register-sources && FM_HOME=$QM_HOME bin/fm-office.sh register-sources
FM_HOME=$MAIN bin/fm-officer.sh register progress
echo "== pre-step-9 offices.md:"; grep '^- ' "$MAIN/data/offices.md" | sed 's/.*sources:/  sources:/'
echo "== step 9 block, run verbatim from docs/office-provisioning.md:"
sed -n '/^## 9\./,/^### /p' "$REPO/docs/office-provisioning.md" | sed -n '/^```sh$/,/^```$/p' | sed '1d;$d' > "$T/step9.sh"
cat "$T/step9.sh" | sed 's/^/  | /'
rc=0
( cd "$REPO" && MAIN=$MAIN NAV_HOME=$NAV_HOME QM_HOME=$QM_HOME bash -ex "$T/step9.sh" ) > "$T/out" 2>&1 || rc=1
sed 's/^/    /' "$T/out"; echo "    block exit rc=$rc"
echo "== post-step-9 records:"
grep '^- ' "$MAIN/data/offices.md" | sed 's/.*sources:/  sources:/'
grep -E '^- (progress|surgeon) ' "$MAIN/data/officers.md" | grep -oE '(consumer|start-home): [^;]*' | sed 's/^/  /'
ls "$NAV_HOME/state" "$QM_HOME/state" | grep -E 'office-lane|^/' | sed 's/^/  /'
echo "== office ensure lines naming lane:progress/lane:surgeon (expect none):"
grep -E "OFFICE: .*(lane:progress|lane:surgeon)" "$T/out" | sed "s/^/  /"
echo "== fm-officer.sh ensure (officer gaps):"
FM_HOME=$MAIN bin/fm-officer.sh ensure | sed 's/^/  /'
echo "  (end, $(FM_HOME=$MAIN bin/fm-officer.sh ensure | grep -c 'consumer\|start-home') consumer/start-home gaps)"
echo "== adversarial: surgeon consumer navigator only (no main) with lane:surgeon:high:"
sed -i 's/consumer: main,navigator;/consumer: navigator;/' "$MAIN/data/officers.md"
FM_HOME=$MAIN bin/fm-officer.sh register surgeon; echo "    register exit=$?"
FM_HOME=$MAIN bin/fm-officer.sh ensure | sed 's/^/  /'
sed -i 's/- surgeon - \(.*\)consumer: navigator;/- surgeon - \1consumer: main,navigator;/' "$MAIN/data/officers.md"
echo "== adversarial: quartermaster without lane:progress (start-home navigator,quartermaster):"
sed -i 's/,lane:page-check,lane:progress;/,lane:page-check;/' "$MAIN/data/offices.md"
FM_HOME=$MAIN bin/fm-officer.sh register progress; echo "    register exit=$?"
/usr/bin/trash "$T"
exit $rc
