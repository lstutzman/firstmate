#!/usr/bin/env bash
# Live scenario: one tokened master per project serves Quartermaster and Librarian.
set -u
ROOT=$1
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$W"' EXIT
M=$W/main
mkdir -p "$M/projects" "$M/data" "$M/state" "$M/config/admission" "$W/fakebin" "$W/remotes"
# no-mistakes is an external tool the seed calls; stub only it so no real pipeline is initialised.
printf '#!/usr/bin/env bash\ncase "$1" in init) touch .no-mistakes-init;; doctor) :;; *) exit 2;; esac\n' > "$W/fakebin/no-mistakes"; chmod +x "$W/fakebin/no-mistakes"
export PATH="$W/fakebin:$PATH" FM_OFFICE_HOST=slartibartfast
for p in firstmate skills; do
  git init -q -b main "$M/projects/$p"; git -C "$M/projects/$p" commit -q --allow-empty -m init
  git init -q --bare "$W/remotes/$p.git"; git -C "$M/projects/$p" remote add origin "$W/remotes/$p.git"
done
cat > "$M/data/projects.md" <<EOF
- firstmate [direct-PR +yolo] - firstmate (added 2026-11-07)
- skills [direct-PR +yolo] - skills (added 2026-11-07)
EOF
cat > "$M/data/offices.md" <<EOF
# Offices

- quartermaster - Fleet self-improvement (role: quartermaster; runs-on: slartibartfast,deepthought; dispatch: firstmate,skills; merge: firstmate,skills; merge-via: none; auto-merge-classes: none; wip: 2; tick: every 4h; sources: tick; added 2026-11-04)
- librarian - Keep fleet documents placed and current (role: librarian; runs-on: slartibartfast,deepthought; dispatch: firstmate,skills; merge: firstmate,skills; merge-via: none; auto-merge-classes: none; wip: 1; tick: every 4h; sources: tick; added 2026-11-07)
- libtwo - Adversarial second librarian (role: librarian; runs-on: slartibartfast; dispatch: firstmate,skills; merge: firstmate,skills; merge-via: none; auto-merge-classes: none; wip: 1; tick: every 4h; sources: tick; added 2026-11-07)
EOF
# Masters written exactly as docs/office-provisioning.md section 3 now says.
for p in firstmate skills; do
  printf 'command=@OFFICE_HOME@/bin/fm-reserved-classify.sh --rules @OFFICE_HOME@/config/admission/%s.rules\nclasses=authority\nclear=none\n' "$p" > "$M/config/admission/$p"
done
printf 'AGENTS.md authority\nbin/fm-office-authority-lib.sh authority\n' > "$M/config/admission/firstmate.rules"
printf 'global/** authority\n' > "$M/config/admission/skills.rules"
echo "== master config/admission/firstmate"; cat "$M/config/admission/firstmate"
rc_all=0
for id in quartermaster librarian; do
  H=$W/$id
  echo; echo "== SCENARIO seed $id"
  if out=$(FM_HOME="$M" "$ROOT/bin/fm-home-seed.sh" "$id" "$H" firstmate skills --office "$id" 2>&1); then echo "seed $id: OK"; else echo "seed $id: FAILED"; echo "$out" | tail -5; rc_all=1; continue; fi
  echo "-- $id copy of config/admission/firstmate:"; cat "$H/config/admission/firstmate"
  grep -q '@OFFICE_HOME@' "$H/config/admission/firstmate" && { echo "FAIL token left"; rc_all=1; }
  cmp -s "$M/config/admission/firstmate.rules" "$H/config/admission/firstmate.rules" && echo "rules copied verbatim: OK"
  echo "== SCENARIO publish $id"
  FM_HOME="$M" "$ROOT/bin/fm-office.sh" publish "$id" && echo "publish $id: OK" || { echo "publish $id FAILED"; rc_all=1; }
  ls "$H"/state/office-authority* "$H"/data/office-authority* 2>/dev/null
done
echo; echo "== SCENARIO ensure (both offices)"
out=$(FM_HOME="$M" "$ROOT/bin/fm-office.sh" ensure 2>&1); echo "${out:-<no gaps reported>}"
echo "$out" | grep -q 'office \(quartermaster\|librarian\):' && { echo "FAIL ensure gaps"; rc_all=1; }
echo; echo "== SCENARIO classify a diff through each office's own config"
printf 'project\n' > /dev/null
for id in quartermaster librarian; do
  H=$W/$id
  for paths in "AGENTS.md" "docs/readme-only.md"; do
    printf '%s\n' "$paths" > "$W/paths"
    r=$(bash -c '. "$1/bin/fm-admission-lib.sh"; fm_admission_load "$2" || { echo "LOADERR $FM_ADMISSION_ERROR"; exit 1; }; echo "cmd: ${FM_ADMISSION_COMMAND[*]}"; fm_admission_classify "$3" "$4" || { echo "CLSERR $FM_ADMISSION_ERROR"; exit 1; }; echo "flagged=[${FM_ADMISSION_FLAGGED}]"' _ "$ROOT" "$H/config/admission/firstmate" "$M/projects/firstmate" "$W/paths" 2>&1)
    echo "$id firstmate diff {$paths}: $r"
  done
done
echo; echo "== ADVERSARIAL: office edits its own rules after publish -> ensure must notice"
echo '# loosened' > "$W/librarian/config/admission/firstmate.rules"
out=$(FM_HOME="$M" "$ROOT/bin/fm-office.sh" ensure 2>&1); echo "${out:-<no gaps reported>}"
echo; echo "== ADVERSARIAL: literal Quartermaster-path master refuses Librarian (old behaviour preserved)"
for p in firstmate skills; do
  printf 'command=%s/bin/fm-reserved-classify.sh --rules %s/config/admission/%s.rules\nclasses=authority\nclear=none\n' "$W/quartermaster" "$W/quartermaster" "$p" > "$M/config/admission/$p"
done
if out=$(FM_HOME="$M" "$ROOT/bin/fm-home-seed.sh" libtwo "$W/libtwo" firstmate skills --office libtwo 2>&1); then echo "FAIL: literal master seeded librarian"; rc_all=1; else echo "refused: $(echo "$out" | grep -m1 error)"; fi
echo; echo "== ADVERSARIAL: tokened master with --rules pointing outside the office home is refused"
printf 'command=@OFFICE_HOME@/bin/fm-reserved-classify.sh --rules /elsewhere/firstmate.rules\nclasses=authority\nclear=none\n' > "$M/config/admission/firstmate"
if out=$(FM_HOME="$M" "$ROOT/bin/fm-home-seed.sh" libtwo "$W/libtwo" firstmate skills --office libtwo 2>&1); then echo "FAIL: foreign rules accepted"; rc_all=1; else echo "refused: $(echo "$out" | grep -m1 error)"; fi
[ -e "$W/libtwo/.fm-office" ] && { echo "FAIL refused seed left marker"; rc_all=1; }
echo; echo "overall rc=$rc_all"
exit $rc_all
