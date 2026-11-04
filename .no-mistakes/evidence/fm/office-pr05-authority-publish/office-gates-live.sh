#!/usr/bin/env bash
# Live drive of the office spawn gate and ensure against published records, office homes minted as lab homes.
set -u
ROOT=$1
W=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-office-gates.XXXXXX")" && pwd -P)
export FM_OFFICE_HOST=$(hostname -s); H=$FM_OFFICE_HOST
OFFICE="$ROOT/bin/fm-office.sh"
step() { printf '\n$ %s\n' "$*"; }
pub() { FM_HOME="$W/main" FM_DATA_OVERRIDE="$W/main/data" FM_CONFIG_OVERRIDE="$W/main/config" FM_STATE_OVERRIDE="$W/main/state" bash "$OFFICE" publish "$1"; echo "[exit $?]"; }
ens() { FM_HOME="$W/main" FM_DATA_OVERRIDE="$W/main/data" bash "$OFFICE" ensure; echo "[exit $?]"; }
spawn() { local h=$1; shift; (cd "$W/$h" && FM_HOME="$W/$h" bash "$ROOT/bin/fm-spawn.sh" "$@" 2>&1 | grep -v -e '^fm-gate-refuse' -e '^●' -e '^WARNING: watcher' | head -3); }
mkdir -p "$W/proj" "$W/main/data" "$W/main/config/admission" "$W/main/state"
for id in navigator quartermaster plain; do
  mkdir -p "$W/$id"; bash "$ROOT/bin/fm-lab-home.sh" create "$W/$id" >/dev/null; mkdir -p "$W/$id/config/admission"
  echo "$id" > "$W/$id/.fm-secondmate-home"
  printf -- '- %s - m (home: %s/%s; scope: x; projects: none; added 2026-11-04)\n' "$id" "$W" "$id" >> "$W/main/data/secondmates.md"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$W/main" > "$W/$id/.fm-secondmate-parent"
done
for id in navigator quartermaster; do
  echo "$id" > "$W/$id/.fm-office"; printf '# Charter\n\n# Office authority\n' > "$W/$id/data/charter.md"
done
printf -- '- PropertyCompass2 [direct-PR merger=slarti] - app (added 2026-10-02)\n' > "$W/navigator/data/projects.md"
printf -- '- firstmate [no-mistakes admission=fm] - fm (added 2026-10-02)\n' > "$W/quartermaster/data/projects.md"
cat > "$W/main/data/offices.md" <<O
# Offices

- navigator - Drive progress (role: navigator; runs-on: $H; dispatch: PropertyCompass2; merge: none; merge-via: PropertyCompass2=slarti; auto-merge-classes: none; wip: 2; tick: every 2h; sources: tick; added 2026-11-04)
- quartermaster - Fleet (role: quartermaster; runs-on: $H; dispatch: firstmate; merge: firstmate; merge-via: none; auto-merge-classes: none; wip: 2; tick: every 4h; sources: tick; added 2026-11-04)
O
printf 'command=%s/bin/fm-reserved-classify.sh\nclasses=authority\nclear=none\n' "$ROOT" > "$W/main/config/admission/fm"
printf 'AGENTS.md authority\n' > "$W/main/config/admission/fm.rules"
cp "$W/main/config/admission/fm" "$W/main/config/admission/fm.rules" "$W/quartermaster/config/admission/"
for id in navigator quartermaster; do FM_HOME="$W/$id" bash "$OFFICE" register-sources >/dev/null 2>&1; done

echo "== G1: an office with no published record refuses every spawn"
step "fm-spawn.sh ship firstmate (quartermaster, never published)"; spawn quartermaster t1 "$W/proj" --mode direct-PR --yolo off
step "publish quartermaster"; pub quartermaster
step "publish navigator"; pub navigator
step "publish plain"; pub plain
step "ls -a plain/config"; ls -a "$W/plain/config"
echo "== G2: published record: office-local admission edit (implicit sibling rules) is reported"
echo 'extra.md authority' >> "$W/quartermaster/config/admission/fm.rules"
step "ensure"; ens
cp "$W/main/config/admission/fm.rules" "$W/quartermaster/config/admission/fm.rules"
step "ensure after restoring the master copy"; ens
echo "== G3: deleting one office signal refuses instead of falling back"
mv "$W/quartermaster/.fm-office" "$W/o.bak"
step "fm-spawn.sh (.fm-office deleted)"; spawn quartermaster t1 "$W/proj" --mode direct-PR --yolo off
mv "$W/o.bak" "$W/quartermaster/.fm-office"
printf '# Charter\n' > "$W/quartermaster/data/charter.md"
step "fm-spawn.sh (charter heading deleted)"; spawn quartermaster t1 "$W/proj" --mode direct-PR --yolo off
printf '# Charter\n\n# Office authority\n' > "$W/quartermaster/data/charter.md"
echo "== G4: missing receipt and a record copied from another office refuse"
mv "$W/quartermaster/config/.fm-inherit-office-authority.generation" "$W/r.bak"
step "fm-spawn.sh (receipt deleted)"; spawn quartermaster t1 "$W/proj" --mode direct-PR --yolo off
mv "$W/r.bak" "$W/quartermaster/config/.fm-inherit-office-authority.generation"
cp "$W/quartermaster/config/office-authority" "$W/n.rec"; cp "$W/navigator/config/office-authority" "$W/nav.orig"
cp "$W/n.rec" "$W/navigator/config/office-authority"
step "fm-spawn.sh in navigator holding quartermaster's record"; spawn navigator t3 "$W/proj" --mode direct-PR --yolo off
cp "$W/nav.orig" "$W/navigator/config/office-authority"
echo "== G5: a proven record enforces dispatch= and never creates a second mate"
step "fm-spawn.sh in quartermaster for an undispatched project"; spawn quartermaster t4 "$W/proj" --mode direct-PR --yolo off
step "fm-spawn.sh secondmate from quartermaster"; spawn quartermaster sm-x --secondmate
echo "== G6: removing the office line revokes"
sed -i '/^- navigator/d' "$W/main/data/offices.md"
step "publish navigator"; pub navigator
step "fm-spawn.sh in navigator after revocation"; spawn navigator t3 "$W/proj" --mode direct-PR --yolo off
echo "== G7: plain second mate behaves as before (no office gate)"
step "fm-spawn.sh in plain home (no office signals)"; spawn plain t5 "$W/nosuchproject" --mode direct-PR --yolo off
rm -rf "$W"
