#!/usr/bin/env bash
# Live drive of fm-office.sh publish and the office gates against a disposable main home.
set -u
ROOT=$1
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-office-live.XXXXXX")
export FM_OFFICE_HOST=$(hostname -s)
H=$FM_OFFICE_HOST
OFFICE="$ROOT/bin/fm-office.sh"
step() { printf '\n$ %s\n' "$*"; }
pub() { FM_HOME="$W" FM_DATA_OVERRIDE="$W/data" FM_CONFIG_OVERRIDE="$W/config" FM_STATE_OVERRIDE="$W/state" bash "$OFFICE" publish "$1"; echo "[exit $?]"; }
ens() { FM_HOME="$W" FM_DATA_OVERRIDE="$W/data" bash "$OFFICE" ensure; echo "[exit $?]"; }
mkdir -p "$W/data" "$W/config/admission" "$W/state"
for id in navigator quartermaster; do
  mkdir -p "$W/$id/data" "$W/$id/config/admission" "$W/$id/state"
  echo "$id" > "$W/$id/.fm-secondmate-home"; echo "$id" > "$W/$id/.fm-office"
  printf '# Charter\n\n# Office authority\n' > "$W/$id/data/charter.md"
  printf -- '- %s - office (home: %s/%s; scope: office; projects: none; added 2026-11-04)\n' "$id" "$W" "$id" >> "$W/data/secondmates.md"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$W" > "$W/$id/.fm-secondmate-parent"
done
mkdir -p "$W/slarti/data" "$W/slarti/config"; echo slarti > "$W/slarti/.fm-secondmate-home"
printf -- '- slarti - plain (home: %s/slarti; scope: plain; projects: none; added 2026-11-04)\n' "$W" >> "$W/data/secondmates.md"
printf -- '- PropertyCompass2 [direct-PR merger=slarti] - app (added 2026-10-02)\n' > "$W/navigator/data/projects.md"
printf -- '- firstmate [no-mistakes admission=fm] - fm (added 2026-10-02)\n' > "$W/quartermaster/data/projects.md"
printf -- '- progress - x (role: progress; cadence: daily 07:00; added 2026-10-26)\n- friction - y (role: friction; cadence: daily 06:15; added 2026-10-24)\n' > "$W/data/officers.md"
cat > "$W/data/offices.md" <<O
# Offices

- navigator - Drive progress (role: navigator; runs-on: $H; dispatch: PropertyCompass2; merge: none; merge-via: PropertyCompass2=slarti; auto-merge-classes: none; wip: 2; tick: every 2h; sources: tick; added 2026-11-04)
- quartermaster - Fleet (role: quartermaster; runs-on: $H; dispatch: firstmate; merge: firstmate; merge-via: none; auto-merge-classes: none; wip: 2; tick: every 4h; sources: tick; added 2026-11-04)
O
# Documented pattern: absolute --rules path inside the master config/admission (review round 2 fix).
printf 'command=%s/bin/fm-reserved-classify.sh --rules %s/config/admission/fm.rules\nclasses=authority\nclear=none\n' "$ROOT" "$W" > "$W/config/admission/fm"
printf 'AGENTS.md authority\n' > "$W/config/admission/fm.rules"
cp "$W/config/admission/fm" "$W/config/admission/fm.rules" "$W/quartermaster/config/admission/"
for id in navigator quartermaster; do FM_HOME="$W/$id" bash "$OFFICE" register-sources >/dev/null 2>&1; done

echo "== S0: before publishing, ensure reports unpublished records"
step "fm-office.sh ensure"; ens
echo "== S1: publish each office its own record; plain second mate gets nothing"
step "fm-office.sh publish navigator"; pub navigator
step "fm-office.sh publish quartermaster"; pub quartermaster
step "fm-office.sh publish slarti (plain second mate)"; pub slarti
step "cat navigator/config/office-authority"; cat "$W/navigator/config/office-authority"
step "cat quartermaster/config/office-authority"; cat "$W/quartermaster/config/office-authority"
step "cat quartermaster/config/.fm-inherit-office-authority.generation"; cat "$W/quartermaster/config/.fm-inherit-office-authority.generation"
step "ls -a slarti/config"; ls -a "$W/slarti/config"
step "fm-office.sh ensure (byte-identical office copy with absolute --rules inside master config/admission)"; ens
step "fm-office.sh publish navigator (again)"; pub navigator
echo "== S2: publish refusals"
step "publish nobody"; pub nobody 2>&1
step "publish from inside a second-mate home"; FM_HOME="$W/quartermaster" FM_DATA_OVERRIDE="$W/data" bash "$OFFICE" publish quartermaster 2>&1; echo "[exit $?]"
echo "== S3: office merge gate refuses after the office edits its own admission rules"
mkmeta() { printf 'id=t1\nkind=ship\nproject=firstmate\nyolo=on\noffice=quartermaster\n' > "$W/quartermaster/state/t1.meta"; }
mkmeta
merge() { (cd "$W/quartermaster" && FM_HOME="$W/quartermaster" bash "$ROOT/bin/fm-pr-merge.sh" t1 2>&1 | head -5); }
echo 'extra.md authority' >> "$W/quartermaster/config/admission/fm.rules"
step "fm-pr-merge.sh t1 (office-local rules edit)"; merge
step "fm-office.sh ensure"; ens
cp "$W/config/admission/fm.rules" "$W/quartermaster/config/admission/fm.rules"
echo "== S4: missing receipt / deleted signal refuse (spawn and merge)"
spawn() { (cd "$W/quartermaster" && FM_HOME="$W/quartermaster" bash "$ROOT/bin/fm-spawn.sh" "$@" 2>&1 | head -5); }
mv "$W/quartermaster/config/.fm-inherit-office-authority.generation" "$W/rcpt.bak"
step "fm-pr-merge.sh t1 (receipt deleted)"; merge
step "fm-spawn.sh ship firstmate t2 brief (receipt deleted)"; spawn ship firstmate --id t2
mv "$W/rcpt.bak" "$W/quartermaster/config/.fm-inherit-office-authority.generation"
mv "$W/quartermaster/.fm-office" "$W/office.bak"
step "fm-spawn.sh (.fm-office marker deleted, charter heading kept)"; spawn ship firstmate --id t2
mv "$W/office.bak" "$W/quartermaster/.fm-office"
printf '# Charter\n' > "$W/quartermaster/data/charter.md"
step "fm-pr-merge.sh t1 (charter heading deleted, marker kept)"; merge
printf '# Charter\n\n# Office authority\n' > "$W/quartermaster/data/charter.md"
echo "== S5: forged record copied into another office refuses; a registry change makes it stale; removal revokes"
cp "$W/quartermaster/config/office-authority" "$W/navigator/config/office-authority"
step "fm-spawn.sh in navigator with quartermaster's record"; (cd "$W/navigator" && FM_HOME="$W/navigator" bash "$ROOT/bin/fm-spawn.sh" ship PropertyCompass2 --id t3 2>&1 | head -3)
pub navigator
sed -i 's/wip: 2; tick: every 2h/wip: 3; tick: every 2h/' "$W/data/offices.md"
step "ensure after editing navigator's wip"; ens
step "publish navigator"; pub navigator
grep wip= "$W/navigator/config/office-authority"
sed -i '/^- navigator/d' "$W/data/offices.md"
step "publish navigator after its line is removed"; pub navigator
step "fm-spawn.sh in navigator after revocation"; (cd "$W/navigator" && FM_HOME="$W/navigator" bash "$ROOT/bin/fm-spawn.sh" ship PropertyCompass2 --id t3 2>&1 | head -3)
rm -rf "$W"
