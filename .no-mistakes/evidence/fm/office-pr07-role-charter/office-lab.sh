#!/usr/bin/env bash
# Disposable lab: drive fm-brief.sh --office, fm-home-seed.sh --office,
# fm-office.sh publish/ensure and the reserved classifier against a lab FM_HOME.
set -u
R={run-worktree}
cd "$R"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB" FM_OFFICE_HOST=slartibartfast
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-homes.XXXXXX"); mkdir -p "$LAB/remotes"
step() { printf '\n===== %s =====\n' "$*"; }
for p in PropertyCompass2 firstmate skills fleet-app; do
  git init -q --bare "$LAB/remotes/$p.git"
  git init -q -b main "$LAB/projects/$p"
  git -C "$LAB/projects/$p" -c user.email=l@x -c user.name=lab commit -q --allow-empty -m init
  git -C "$LAB/projects/$p" remote add origin "$LAB/remotes/$p.git"
  git -C "$LAB/projects/$p" push -q origin main
done
cat > "$LAB/data/projects.md" <<P
- PropertyCompass2 [direct-PR +yolo] - PC (added 2026-11-04)
- firstmate [direct-PR +yolo] - fm fork (added 2026-11-04)
- skills [direct-PR +yolo] - skills (added 2026-11-04)
- fleet-app [direct-PR] - fleet app (added 2026-11-04)
P
NAV=$H/navigator QM=$H/quartermaster
cat > "$LAB/data/offices.md" <<O
# Offices

- navigator - Drive PropertyCompass forward progress from Top of Mind, feature ideation and requested items (role: navigator; runs-on: slartibartfast; dispatch: PropertyCompass2; merge: none; merge-via: PropertyCompass2=slarti; auto-merge-classes: none; wip: 2; tick: every 2h; sources: tick; added 2026-11-04)
- quartermaster - Drive fleet, officer and agent self-improvement from friction, velocity, cost and page findings (role: quartermaster; runs-on: slartibartfast; dispatch: firstmate,skills,fleet-app; merge: firstmate,skills; merge-via: fleet-app=slarti; auto-merge-classes: none; wip: 2; tick: every 4h; sources: tick; added 2026-11-04)
- librarian - placeholder (role: librarian; runs-on: slartibartfast; dispatch: skills; merge: none; merge-via: none; auto-merge-classes: none; wip: 1; tick: every 4h; sources: tick; added 2026-11-04)
- lapnav - laptop (role: navigator; runs-on: macbook; dispatch: PropertyCompass2; merge: none; merge-via: none; auto-merge-classes: none; wip: 1; tick: every 4h; sources: tick; added 2026-11-04)
O
mkdir -p "$LAB/config/admission"
for p in firstmate skills; do
  printf 'command=%s/bin/fm-reserved-classify.sh --rules %s/config/admission/%s.rules\nclasses=authority\nclear=none\n' "$QM" "$QM" "$p" > "$LAB/config/admission/$p"
done
# firstmate.rules exactly as docs/office-provisioning.md step 3 writes it
awk '/firstmate.rules" <<.EOF./{f=1;next} f&&/^EOF$/{exit} f' docs/office-provisioning.md > "$LAB/config/admission/firstmate.rules"
awk '/skills.rules" <<.EOF./{f=1;next} f&&/^EOF$/{exit} f' docs/office-provisioning.md > "$LAB/config/admission/skills.rules"

step "S1 fm-brief.sh navigator --secondmate --office navigator PropertyCompass2"
bin/fm-brief.sh navigator --secondmate --office navigator PropertyCompass2; echo "rc=$?"
B=$LAB/data/navigator/brief.md
echo "--- headings:"; grep -n '^# ' "$B"
echo "--- Office cycle / Office authority / Definition of done sections:"
awk '/^# Office cycle/||/^# Office authority/||/^# Definition of done/{p=1} /^# /&&!/^# Office cycle/&&!/^# Office authority/&&!/^# Definition of done/{p=0} p' "$B"
echo "--- idle-by-default phrases remaining (expect none):"
grep -n 'do not generate your own work\|Act only on tasks the main firstmate routes\|go idle' "$B" || echo "(none)"
step "S1b plain second-mate template still idle by default"
bin/fm-brief.sh plainmate --secondmate PropertyCompass2 >/dev/null; echo "rc=$?"
grep -n 'Act only on tasks the main firstmate routes\|go idle\|# Office' "$LAB/data/plainmate/brief.md"

step "S2 seed navigator office"
bin/fm-home-seed.sh navigator "$NAV" PropertyCompass2 --office navigator; echo "rc=$?"
echo "marker: $(cat "$NAV/.fm-office" 2>&1)"; ls -a "$NAV" | grep '^\.fm-'
echo "--- office home projects.md:"; cat "$NAV/data/projects.md"
echo "--- registered sources:"; ls "$NAV/state" | grep -i 'office\|check' 
grep -n '^- navigator' "$LAB/data/secondmates.md"
step "S3 seed quartermaster office"
bin/fm-home-seed.sh quartermaster "$QM" firstmate skills fleet-app --office quartermaster; echo "rc=$?"
cat "$QM/data/projects.md"; ls "$QM/config/admission"
cmp "$LAB/config/admission/firstmate.rules" "$QM/config/admission/firstmate.rules" && echo "firstmate.rules copied byte-identical"
step "S4 publish both and ensure"
for id in navigator quartermaster; do bin/fm-office.sh publish "$id"; echo "publish $id rc=$?"; done
echo "--- ensure output (librarian and lapnav gaps expected; none for navigator/quartermaster):"
bin/fm-office.sh ensure; echo "ensure rc=$?"
step "S5 quartermaster classifier flags authority files (incl. review fix) and clears ordinary paths"
printf '%s\n' bin/fm-project-mode.sh | "$QM/bin/fm-reserved-classify.sh" --rules "$QM/config/admission/firstmate.rules"
printf '%s\n' bin/fm-pr-lib.sh | "$QM/bin/fm-reserved-classify.sh" --rules "$QM/config/admission/firstmate.rules"
printf '%s\n' .agents/skills/office-roles/SKILL.md | "$QM/bin/fm-reserved-classify.sh" --rules "$QM/config/admission/firstmate.rules"
printf '%s\n' docs/scripts.md | "$QM/bin/fm-reserved-classify.sh" --rules "$QM/config/admission/firstmate.rules"

step "S6 adversarial: plain second mate slarti cannot become an office by re-seeding"
FM_SECONDMATE_CHARTER='Releases and landing piles' bin/fm-home-seed.sh slarti "$H/slarti" PropertyCompass2 >/dev/null; echo "plain seed rc=$?"
sed -i 's/^- lapnav - laptop (role: navigator; runs-on: macbook;/- slarti - convert (role: navigator; runs-on: slartibartfast;/' "$LAB/data/offices.md"
bin/fm-home-seed.sh slarti "$H/slarti" PropertyCompass2 --office slarti; echo "rc=$? (expect nonzero)"
ls -a "$H/slarti" | grep -c '^\.fm-office$' | sed 's/^/office markers in slarti: /'
sed -i 's/^- slarti - convert (role: navigator; runs-on: slartibartfast;/- lapnav - laptop (role: navigator; runs-on: macbook;/' "$LAB/data/offices.md"
step "S7 adversarial: macbook, wrong host, reserved role"
bin/fm-home-seed.sh lapnav "$H/lapnav" PropertyCompass2 --office lapnav; echo "rc=$?"
FM_OFFICE_HOST=deepthought bin/fm-home-seed.sh navigator "$NAV" PropertyCompass2 --office navigator; echo "rc=$?"
FM_OFFICE_HOST=macbook bin/fm-home-seed.sh navigator "$NAV" PropertyCompass2 --office navigator; echo "rc=$?"
bin/fm-home-seed.sh librarian "$H/librarian" skills --office librarian; echo "rc=$?"
bin/fm-brief.sh librarian --secondmate --office librarian skills; echo "brief rc=$?"
step "S8 adversarial: plain re-seed of an office refused, office re-seed converges"
FM_SECONDMATE_CHARTER=plain bin/fm-home-seed.sh navigator "$NAV" PropertyCompass2; echo "rc=$? (expect nonzero)"
grep -c '^# Office authority' "$NAV/data/charter.md" | sed 's/^/office authority headings in charter: /'
bin/fm-home-seed.sh navigator "$NAV" PropertyCompass2 --office navigator >/dev/null; echo "office re-seed rc=$?"
grep -c 'merger=slarti' "$NAV/data/projects.md" | sed 's/^/merger tokens: /'
bin/fm-office.sh ensure 2>&1 | grep -E 'navigator|quartermaster' || echo "(ensure: no navigator/quartermaster gaps)"

step "teardown"
chmod -R u+w "$LAB" 2>/dev/null
chmod -R u+w "$H" 2>/dev/null; /usr/bin/trash "$LAB" "$H" && echo "lab removed"
