#!/usr/bin/env bash
# Live drive: bin/fm-pr-merge.sh in disposable lab homes for a project registered
# [no-mistakes +yolo merger=slarti]. The forge CLIs (gh, gh-axi) are logging
# stubs that refuse, so no real PR is touched; reaching them proves the merger
# gate let the merge through.
set -u
WT=$1
ROOTTMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-merger.XXXXXX")
mkdir -p "$ROOTTMP/fakebin" "$ROOTTMP/project/PropertyCompass2"
for c in gh gh-axi; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >> %q\necho "stub %s: forge not available in lab" >&2\nexit 1\n' "$c" "$ROOTTMP/forge.log" "$c" > "$ROOTTMP/fakebin/$c"
  chmod +x "$ROOTTMP/fakebin/$c"
done
git init -q "$ROOTTMP/wt" && git -C "$ROOTTMP/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkhome() {  # <dir> <secondmate-id-or-empty> <parent-home-or-empty> <merger-token>
  local h=$1
  "$WT/bin/fm-lab-home.sh" create "$h" >/dev/null
  printf '%s\n' '## Projects' "- PropertyCompass2 [no-mistakes +yolo $4] - lab fixture (added 2026-10-23)" > "$h/data/projects.md"
  printf 'window=fm-pc-1\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\n' "$ROOTTMP/wt" "$ROOTTMP/project/PropertyCompass2" > "$h/state/pc-1.meta"
  [ -z "$2" ] || printf '%s\n' "$2" > "$h/.fm-secondmate-home"
  [ -z "$3" ] || { mkdir -p "$3/state"; printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$3" > "$h/.fm-secondmate-parent"; }
}
merge() {  # <home>
  : > "$ROOTTMP/forge.log"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$ROOTTMP/fakebin:$PATH" FM_HOME="$1" "$WT/bin/fm-pr-merge.sh" pc-1 https://github.com/lstutzman/PropertyCompass2/pull/3769 > "$ROOTTMP/out" 2> "$ROOTTMP/err"
  echo "exit=$?"; echo "stderr:"; sed 's/^/  /' "$ROOTTMP/err"; echo "forge calls: $(wc -l < "$ROOTTMP/forge.log" | tr -d ' ')"
}
MAIN=$ROOTTMP/main; DT=$ROOTTMP/deepthought; SL=$ROOTTMP/slarti
mkhome "$MAIN" "" "" "merger=slarti"
mkhome "$DT" deepthought "$MAIN" "merger=slarti"
mkhome "$SL" slarti "" "merger=slarti"

echo "## A. Deep Thought (secondmate with a local parent) tries to merge PropertyCompass2 #3769"
merge "$DT"
echo "## A2. Run the printed handoff command; parent (main) status stream gets a keyed decision"
printf '%s\n' 'needs-decision: an earlier unkeyed question from deepthought' > "$MAIN/state/deepthought.status"
bash -c "$(tail -n 1 "$ROOTTMP/err")"; echo "handoff rc=$?"
echo "main/state/deepthought.status:"; sed 's/^/  /' "$MAIN/state/deepthought.status"
echo "open decisions (status_open_decisions):"
bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$WT" "$MAIN/state/deepthought.status" | sed 's/^/  /'

echo "## B. The main home (no marker, no parent) tries to merge"
merge "$MAIN"

echo "## C. The merger home slarti merges: passes the merger gate and reaches the forge"
merge "$SL"; echo "forge log:"; sed 's/^/  /' "$ROOTTMP/forge.log"

echo "## D. Adversarial: Deep Thought's registry carries an empty merger= token"
printf '%s\n' '## Projects' "- PropertyCompass2 [no-mistakes +yolo merger=] - lab (added 2026-10-23)" > "$DT/data/projects.md"
merge "$DT"
echo "## E. Adversarial: Deep Thought's registry carries merger=slarti;rm -rf"
printf '%s\n' '## Projects' "- PropertyCompass2 [no-mistakes +yolo merger=sl\$arti] - lab (added 2026-10-23)" > "$DT/data/projects.md"
merge "$DT"
echo "## F. No merger token: Deep Thought keeps today's behavior and reaches the forge"
printf '%s\n' '## Projects' "- PropertyCompass2 [no-mistakes +yolo] - lab (added 2026-10-23)" > "$DT/data/projects.md"
merge "$DT"
echo "## G. Spoof attempt: a symlinked .fm-secondmate-home pointing at a file saying slarti"
printf '%s\n' '## Projects' "- PropertyCompass2 [no-mistakes +yolo merger=slarti] - lab (added 2026-10-23)" > "$DT/data/projects.md"
rm "$DT/.fm-secondmate-home"; printf 'slarti\n' > "$ROOTTMP/fake-id"; ln -s "$ROOTTMP/fake-id" "$DT/.fm-secondmate-home"
merge "$DT"
rm -rf "$ROOTTMP"; echo "lab torn down"
