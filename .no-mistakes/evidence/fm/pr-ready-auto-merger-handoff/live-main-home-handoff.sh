#!/usr/bin/env bash
# Live: a main home (no parent) registers a ready PR for a merger=slarti project
# with the REAL bin/fm-pr-check.sh and REAL bin/fm-send.sh; Slarti is a real
# Herdr pane in an isolated fm-lab-* session. Only the forge CLIs (gh, gh-axi,
# no-mistakes) are fixtures.
set -u
WT={run-worktree}
E=~/.no-mistakes/evidence/01M6P4TSGKGJ3YVV18H9SKQYYD
S=$1
. "$E/fixture-lib.sh"
dir=$(make_case live-main)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
ORIG_PATH=$PATH
cat > "$dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
args=("\$@"); n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then args=("\${args[@]:0:\$((n-2))}"); fi
PATH='$ORIG_PATH' exec '$WT/bin/fm-herdr-lab.sh' run '$S' "\${args[@]}"
SH
chmod +x "$dir/fakebin/herdr"
fm_test_tasks_toml "$LAB/.tasks.toml"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
printf '%s\n' "- project [no-mistakes +yolo merger=slarti] - fixture (added 2026-01-01)" > "$LAB/data/projects.md"
fm_write_meta "$LAB/state/task-a.meta" "window=firstmate:fm-task-a" "endpoint_task_id=task-a" \
  "worktree=$dir/wt" "project=$dir/project" "kind=ship" "mode=no-mistakes"
fm_write_meta "$LAB/state/slarti.meta" "backend=herdr" "window=$S:w1:p1" "herdr_session=$S" \
  "herdr_pane_id=w1:p1" "endpoint_task_id=slarti" "kind=secondmate" "harness=claude"
url=https://github.com/o/r/pull/4837
run() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$LAB" HERDR_SESSION="$S" \
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" FM_TEST_GLAB_LOG="$dir/glab.log" \
  FM_TEST_GERRIT_AXI_LOG="$dir/gerrit-axi.log" PATH="$dir/fakebin:$ORIG_PATH" "$@" "$WT/bin/fm-pr-check.sh" task-a "$url"; }
echo "== run 1: register PR (head A)"; run env; echo "rc=$?"
echo "== slarti inbox records after run 1:"; find "$LAB/state/slarti.inbox" -type f 2>/dev/null | sort; 
for f in $(find "$LAB/state/slarti.inbox" -type f 2>/dev/null | sort); do echo "--- $f"; cat "$f"; echo; done
echo "== task-a.status handoff lines (expect none):"; grep -c merge-handoff "$LAB/state/task-a.status" 2>/dev/null || echo 0
echo "== record:"; cat "$LAB/state/task-a.merge-handoff"
echo "== run 2: same head again"; run env; echo "rc=$?"
echo "== run 3: new head B"; run env FM_TEST_GH_HEAD=1111111111111111111111111111111111111111; echo "rc=$?"
echo "== handoff records delivered to slarti inbox, by count:"; grep -rl "merge-handoff-4837" "$LAB/state/slarti.inbox" 2>/dev/null | wc -l
echo "== slarti pane screen:"; "$WT/bin/fm-herdr-lab.sh" run "$S" pane read w1:p1 2>&1 | tail -8
rm -rf "$LAB" "$TMP_ROOT"
