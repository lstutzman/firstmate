#!/usr/bin/env bash
# Live: a remote second-mate home (deepthought) registers ready PRs with the REAL
# bin/fm-pr-check.sh. Only gh/gh-axi/no-mistakes are fixtures.
set -u
WT={run-worktree}
E=~/.no-mistakes/evidence/01M6P4TSGKGJ3YVV18H9SKQYYD
. "$E/fixture-lib.sh"
dir=$(make_case live-sm)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
ORIG_PATH=$PATH
printf '%s\n' deepthought > "$LAB/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$LAB/.fm-secondmate-parent"
fm_test_tasks_toml "$LAB/.tasks.toml"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
printf '%s\n' "- PropertyCompass2 [no-mistakes +yolo merger=slarti admission=pc-review] - fixture (added 2026-01-01)" > "$LAB/data/projects.md"
mkdir -p "$dir/PropertyCompass2"
for t in t4837 t4839; do fm_write_meta "$LAB/state/$t.meta" "window=firstmate:fm-$t" "endpoint_task_id=$t" \
  "worktree=$dir/wt" "project=$dir/PropertyCompass2" "kind=ship" "mode=no-mistakes"; done
replies="$LAB/state/parent-replies.status"
run() { local id=$1 url=$2; shift 2; env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$LAB" \
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" FM_TEST_GLAB_LOG="$dir/glab.log" \
  FM_TEST_GERRIT_AXI_LOG="$dir/gerrit-axi.log" PATH="$dir/fakebin:$ORIG_PATH" "$@" "$WT/bin/fm-pr-check.sh" "$id" "$url" 2>&1 | grep -v '●\|WARNING: watcher'; }
U1=https://github.com/lstutzman/PropertyCompass2/pull/4837; U2=https://github.com/lstutzman/PropertyCompass2/pull/4839
echo "== S1 deepthought registers PR 4837 and 4839 (admission-bound merger=slarti project)"
run t4837 $U1 env; run t4839 $U2 env
echo "== S1 parent channel (parent-replies.status) handoff lines:"; grep merge-handoff "$replies"
echo "== S1 open keyed decisions the parent sees (fm-classify-lib status_open_decisions):"
bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$WT" "$replies"
echo "== S2 re-register 4837 same head (expect silent):"; run t4837 $U1 env
echo "count 4837 lines: $(grep -c merge-handoff-4837 "$replies")"
echo "== S3 merger home itself (identity slarti) registers a new head (expect no handoff):"
printf '%s\n' slarti > "$LAB/.fm-secondmate-home"
run t4837 $U1 env FM_TEST_GH_HEAD=2222222222222222222222222222222222222222
echo "count 4837 lines: $(grep -c merge-handoff-4837 "$replies")"
printf '%s\n' deepthought > "$LAB/.fm-secondmate-home"
echo "== S4 task held for the captain, new head (expect no handoff):"
FM_HOME="$LAB" "$WT/bin/fm-captain-hold.sh" hold t4839 --title 'Held' --reason 'payments PR waits on Lee' >/dev/null 2>&1 && echo held
run t4839 $U2 env FM_TEST_GH_HEAD=3333333333333333333333333333333333333333
echo "count 4839 lines: $(grep -c merge-handoff-4839 "$replies")"
echo "== S5 project with no merger (expect no handoff):"
printf '%s\n' "- PropertyCompass2 [no-mistakes +yolo] - fixture (added 2026-01-01)" > "$LAB/data/projects.md"
fm_write_meta "$LAB/state/t4840.meta" "window=firstmate:fm-t4840" "endpoint_task_id=t4840" \
  "worktree=$dir/wt" "project=$dir/PropertyCompass2" "kind=ship" "mode=no-mistakes"
run t4840 https://github.com/lstutzman/PropertyCompass2/pull/4840 env
echo "count 4840 lines: $(grep -c merge-handoff-4840 "$replies")"
rm -rf "$LAB" "$TMP_ROOT"
