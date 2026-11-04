#!/usr/bin/env bash
# Live scenario driver: disposable main home + office homes, real firstmate CLIs.
set -u
R=$1 LAB=$2
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_OFFICE_HOST=slartibartfast
M=$LAB/main
"$R/bin/fm-lab-home.sh" create "$M" >/dev/null
for id in navigator quartermaster slarti; do "$R/bin/fm-lab-home.sh" create "$LAB/$id" >/dev/null; printf '%s\n' "$id" > "$LAB/$id/.fm-secondmate-home"; done
for id in navigator quartermaster; do
  printf '%s\n' "$id" > "$LAB/$id/.fm-office"
  printf '# Charter\n\n# Office authority\n' > "$LAB/$id/data/charter.md"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$M" > "$LAB/$id/.fm-secondmate-parent"
done
for id in navigator quartermaster slarti; do
  printf -- '- %s - mate (home: %s/%s; scope: x; projects: none; added 2026-11-04)\n' "$id" "$LAB" "$id" >> "$M/data/secondmates.md"
done
printf -- '- PropertyCompass2 [no-mistakes merger=slarti] - pc (added 2026-10-02)\n' > "$LAB/navigator/data/projects.md"
printf -- '- firstmate [no-mistakes admission=fm] - fm (added 2026-10-02)\n- skills [no-mistakes admission=sk] - sk (added 2026-10-02)\n' > "$LAB/quartermaster/data/projects.md"
printf -- '- friction - y (role: friction; cadence: daily 06:15; added 2026-10-24)\n- progress - x (role: progress; cadence: daily 07:00; added 2026-10-26)\n' > "$M/data/officers.md"
cat > "$M/data/offices.md" <<EOF
# Offices

- navigator - Drive progress (role: navigator; runs-on: slartibartfast; dispatch: PropertyCompass2; merge: none; merge-via: PropertyCompass2=slarti; auto-merge-classes: none; wip: 2; tick: every 2h; sources: tick; added 2026-11-04)
- quartermaster - Drive fleet (role: quartermaster; runs-on: slartibartfast; dispatch: firstmate,skills; merge: firstmate,skills; merge-via: none; auto-merge-classes: none; wip: 2; tick: every 4h; sources: tick; added 2026-11-04)
EOF
mkdir -p "$M/config/admission" "$LAB/quartermaster/config/admission"
# The documented setup: --rules names an absolute path inside the main home's config/admission.
for n in fm sk; do
  printf 'fm-only/** authority\n' > "$M/config/admission/$n.rules"
  printf 'command=%s/bin/fm-reserved-classify.sh --rules %s/config/admission/%s.rules\nclasses=authority\nclear=none\n' "$R" "$M" "$n" > "$M/config/admission/$n"
  cp "$M/config/admission/$n" "$M/config/admission/$n.rules" "$LAB/quartermaster/config/admission/"
done
pub() { FM_HOME="$M" bash "$R/bin/fm-office.sh" publish "$1"; echo "  [rc=$?]"; }
ens() { FM_HOME="$M" bash "$R/bin/fm-office.sh" ensure; echo "  [ensure rc=$?]"; }
spawn() { local h=$1; shift; (cd "$h" && FM_HOME="$h" bash "$R/bin/fm-spawn.sh" "$@" 2>&1 | grep -E 'refused|error|deferred' | head -2); }

echo "== S1 publish each office; plain mate gets nothing =="
pub navigator; pub quartermaster; pub slarti
echo "-- navigator config/office-authority:"; cat "$LAB/navigator/config/office-authority"
echo "-- quartermaster config/office-authority:"; cat "$LAB/quartermaster/config/office-authority"
echo "-- receipt present: $(ls "$LAB/navigator/config/.fm-inherit-office-authority.generation" 2>&1)"
echo "-- slarti config: $(ls -A "$LAB/slarti/config")(empty means no record, no receipt)"
echo "-- ensure after publish (documented --rules path inside config/admission):"; ens

echo "== S2 office spawn gate reads the published record =="
echo "-- navigator spawning a second mate (record loaded, mandate refuses):"; spawn "$LAB/navigator" --secondmate rogue
echo "-- slarti (plain mate, not an office) spawning a second mate:"; spawn "$LAB/slarti" --secondmate rogue

echo "== S3 adversarial: delete one office signal =="
mv "$LAB/navigator/.fm-office" "$LAB/navigator/.fm-office.bak"
spawn "$LAB/navigator" --secondmate rogue
mv "$LAB/navigator/.fm-office.bak" "$LAB/navigator/.fm-office"
sed -i 's/^# Office authority$/# Notes/' "$LAB/navigator/data/charter.md"
spawn "$LAB/navigator" --secondmate rogue
sed -i 's/^# Notes$/# Office authority/' "$LAB/navigator/data/charter.md"

echo "== S4 adversarial: tamper with or drop the record =="
sed -i 's/^wip=2$/wip=9/' "$LAB/navigator/config/office-authority"
spawn "$LAB/navigator" --secondmate rogue
ens
pub navigator
cp "$LAB/navigator/config/.fm-inherit-office-authority.generation" "$LAB/rcpt.bak"
rm "$LAB/navigator/config/.fm-inherit-office-authority.generation"
spawn "$LAB/navigator" --secondmate rogue
cp "$LAB/rcpt.bak" "$LAB/navigator/config/.fm-inherit-office-authority.generation"

echo "== S5 registry change: ensure reports stale, publish fixes, removal revokes =="
sed -i 's/wip: 2; tick: every 2h/wip: 3; tick: every 2h/' "$M/data/offices.md"
ens; pub navigator; grep '^wip=' "$LAB/navigator/config/office-authority"; ens
grep -v '^- navigator ' "$M/data/offices.md" > "$M/x" && mv "$M/x" "$M/data/offices.md"
pub navigator
echo "-- record after revocation: $(cat "$LAB/navigator/config/office-authority" 2>&1)"
spawn "$LAB/navigator" --secondmate rogue

echo "== S6 office-local admission edit is reported and not blessed by republish =="
printf 'bin/** none\n' >> "$LAB/quartermaster/config/admission/fm.rules"
ens; pub quartermaster; ens
cp "$M/config/admission/fm.rules" "$LAB/quartermaster/config/admission/fm.rules"; ens

echo "== S7 refusals of publish itself =="
pub nobody 2>&1
FM_HOME="$LAB/quartermaster" bash "$R/bin/fm-office.sh" publish quartermaster 2>&1; echo "  [rc=$?]"
mv "$M/config/admission/sk" "$M/config/admission/sk.gone"
pub quartermaster 2>&1
echo "-- quartermaster receipt after failed publish: $(sed -n 4p "$LAB/quartermaster/config/.fm-inherit-office-authority.generation" 2>&1)"
mv "$M/config/admission/sk.gone" "$M/config/admission/sk"
