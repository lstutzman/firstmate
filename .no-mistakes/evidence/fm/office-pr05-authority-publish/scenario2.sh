#!/usr/bin/env bash
set -u
R=$1 LAB=$2 M=$2/main Q=$2/quartermaster
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_OFFICE_HOST=slartibartfast
ens() { FM_HOME="$M" bash "$R/bin/fm-office.sh" ensure | grep -v 'source tick'; }
pub() { FM_HOME="$M" bash "$R/bin/fm-office.sh" publish "$1"; echo "  [rc=$?]"; }
dig() { bash -c '. "$1"; fm_office_admission_digest "$2" fm' _ "$R/bin/fm-office-authority-lib.sh" "$1"; }
echo "== S6b quartermaster republished; master vs office digest with absolute --rules inside config/admission =="
pub quartermaster
echo "main digest:   $(dig "$M/config")"; echo "office digest: $(dig "$Q/config")"
echo "-- ensure (no authority gaps expected):"; ens
echo "-- edit the office-local config the classifier reads (classes widened):"
cp "$Q/config/admission/fm" "$LAB/fm.bak"; sed -i 's/^clear=none$/clear=authority/' "$Q/config/admission/fm"
ens; pub quartermaster; echo "-- after republish (must still report):"; ens
cp "$LAB/fm.bak" "$Q/config/admission/fm"
echo "-- implicit sibling .rules variant (no --rules arg):"
for d in "$M" "$Q"; do printf 'command=%s/bin/fm-reserved-classify.sh\nclasses=authority\nclear=none\n' "$R" > "$d/config/admission/sk"; done
cp "$M/config/admission/sk.rules" "$Q/config/admission/sk.rules"
pub quartermaster; ens
printf 'bin/** none\n' >> "$Q/config/admission/sk.rules"; echo "-- office-local sk.rules edited:"; ens
cp "$M/config/admission/sk.rules" "$Q/config/admission/sk.rules"; echo "-- restored:"; ens
echo "== S8 fm-config-push.sh convergence publishes the record =="
printf 'kind=secondmate\nid=quartermaster\nhome=%s\n' "$Q" > "$M/state/quartermaster.meta"
sed -i 's/wip: 2; tick: every 4h/wip: 1; tick: every 4h/' "$M/data/offices.md"
ens
FM_HOME="$M" bash "$R/bin/fm-config-push.sh" 2>&1 | grep -iE 'office|quartermaster|error' | head -8
echo "-- quartermaster wip now: $(grep '^wip=' "$Q/config/office-authority")"
ens; echo "[end]"
