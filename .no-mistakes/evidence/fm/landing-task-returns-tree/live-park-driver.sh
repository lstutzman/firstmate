#!/usr/bin/env bash
# Live driver: real treehouse (scratch TREEHOUSE_ROOT), real git remote, real
# bin/fm-tree-park.sh / fm-send.sh / fm-teardown.sh / fm-crew-state.sh.
# External boundaries faked: gh (forge PR head), no-mistakes axi status, herdr
# pane lookup, and the control plane's exit/relaunch (no real agent endpoint).
set -u
ROOT=$1; LAB=$2
. "$ROOT/tests/lib.sh"
. "$ROOT/bin/fm-pr-lib.sh"; . "$ROOT/bin/fm-wake-lib.sh"
fm_git_identity fmtest fmtest@example.invalid
BRANCH=fm/lab-task; URL=https://github.com/o/r/pull/42; ID=task-a
export TREEHOUSE_ROOT="$LAB/pool"
th_status() { (cd "$LAB/project" && treehouse status 2>&1); }
mk() {  # <scenario>: build a lab whose task holds a real leased slot on BRANCH at the pushed head
  local name=$1 dir=$LAB/$1 wt head
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin" "$dir/root"
  export TREEHOUSE_ROOT="$dir/pool"
  git init -q --bare "$dir/remote.git"; git clone -q "$dir/remote.git" "$dir/project" 2>/dev/null
  git -C "$dir/project" commit -q --allow-empty -m init; git -C "$dir/project" push -q origin HEAD:refs/heads/main
  git -C "$dir/project" checkout -q -b "$BRANCH"; echo change > "$dir/project/change.txt"
  git -C "$dir/project" add change.txt; git -C "$dir/project" commit -q -m change; git -C "$dir/project" push -q origin "$BRANCH"
  git -C "$dir/project" checkout -q main
  wt=$(cd "$dir/project" && treehouse get --lease --lease-holder "$ID" 2>/dev/null) || { echo "lease failed"; exit 1; }
  git -C "$wt" fetch -q origin; git -C "$wt" checkout -q -B "$BRANCH" "origin/$BRANCH"; git -C "$wt" branch -q --set-upstream-to="origin/$BRANCH"
  head=$(git -C "$wt" rev-parse HEAD); echo "$head" > "$dir/gh-head"; echo "$wt" > "$dir/wt0"
  echo '- project [no-mistakes merger=slarti] - fixture (added 2026-01-01)' > "$dir/home/data/projects.md"
  cp -R "$ROOT/bin" "$dir/root/bin"
  cat > "$dir/root/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_LAB/control.log"
case "${2:-}" in
  exit) exit 0 ;;
  relaunch) wt=$(grep '^worktree=' "$FM_TEST_LAB/home/state/$1.meta" | tail -1 | cut -d= -f2-)
    printf 'relaunch worktree=%s head=%s branch=%s\n' "$wt" "$(git -C "$wt" rev-parse HEAD)" "$(git -C "$wt" symbolic-ref --quiet --short HEAD)" >> "$FM_TEST_LAB/control.log"
    [ "${3:-}" != --note-file ] || cp "$4" "$FM_TEST_LAB/relaunch-note"; exit 0 ;;
esac; exit 2
SH
  printf '#!/usr/bin/env bash\n[ "$1 $2" = "pr view" ] || exit 2\nprintf "%%s %%s\\n" "${FM_TEST_GH_STATE:-OPEN}" "$(cat "$FM_TEST_LAB/gh-head")"\n' > "$dir/fakebin/gh"
  printf '#!/usr/bin/env bash\nprintf "run:\\n  id: r1\\n  status: handed_off\\n  outcome: handed-off\\n"\n' > "$dir/fakebin/no-mistakes"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "session list") printf '{"sessions":[{"name":"lab","running":true,"socket_path":"%s/herdr.sock"}]}\n' "$FM_TEST_LAB" ;;
  "status --json") echo '{"server":{"running":true}}' ;;
  "pane get") echo '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/root/bin/fm-control.sh" "$dir/fakebin/"*
  fm_write_meta "$dir/home/state/$ID.meta" window=lab:p1 endpoint_task_id=$ID backend=herdr herdr_session=lab \
    herdr_workspace_id=w1 herdr_tab_id=w1:t1 herdr_pane_id=p1 harness=claude spawn_gen=fm.lab123456 \
    "worktree=$wt" "project=$dir/project" kind=ship mode=no-mistakes pr_at=1700000050 "pr=$URL" "pr_head=$head"
  chmod 0600 "$dir/home/state/$ID.meta"
  printf 'done [at=1700000100]: PR %s checks green\n' "$URL" > "$dir/home/state/$ID.status"
  printf '%s %s\n' "$URL" "$head" > "$dir/home/state/$ID.merge-handoff"; cp "$dir/home/state/$ID.merge-handoff" "$dir/home/state/$ID.nm-released"
  FM_HOME="$dir/home" fm_treehouse_slot_owner_claim "$wt" "$ID" "$dir/home" || { echo claim failed; exit 1; }
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$ID"); "$ROOT/bin/fm-busy-event.sh" apply "$dir/home/state" "$ID" idle --gen "$gen" --source claude-hook --event stop
  : > "$dir/control.log"; D=$dir
}
E() { FM_TEST_LAB="$D" FM_HOME="$D/home" FM_ROOT_OVERRIDE="$D/root" FM_CONFIG_OVERRIDE="$D/home/config" PATH="$D/fakebin:$PATH" "$@"; }
meta() { echo "--- record:"; grep -E '^(worktree|parked[a-z_]*)=' "$D/home/state/$ID.meta"; }
wait_parked() { local i=0; until grep -q '^parked=1' "$D/home/state/$ID.meta" || [ $i -ge 150 ]; do sleep 0.2; i=$((i+1)); done; }
hr() { echo; echo "================ $* ================"; }

hr "S1 watcher sweep parks a clean handed-off ship (real treehouse pool)"
mk s1; echo "pool before:"; (cd $D/project; treehouse status 2>&1 | tail -n +2)
E "$D/root/bin/fm-tree-park.sh" sweep; echo "sweep rc=$?"; wait_parked
echo "park-log:"; cat "$D/home/state/$ID.park-log" 2>/dev/null
echo "pool after:"; (cd $D/project; treehouse status 2>&1 | tail -n +2); meta
echo "control: $(cat $D/control.log)"; echo "crew-state: $(E "$D/root/bin/fm-crew-state.sh" $ID 2>&1 | head -2)"
echo "status lines: $(wc -l < $D/home/state/$ID.status)"

hr "S4 steer to the parked task re-acquires a fresh real slot at the PR head"
E "$D/root/bin/fm-send.sh" $ID "restack onto main"; echo "send rc=$?"
echo "pool after steer:"; (cd $D/project; treehouse status 2>&1 | tail -n +2); meta
new=$(grep '^worktree=' $D/home/state/$ID.meta | cut -d= -f2-)
echo "fresh copy HEAD=$(git -C "$new" rev-parse HEAD) branch=$(git -C "$new" symbolic-ref --short HEAD) expected=$(cat $D/gh-head)"
echo "control:"; cat $D/control.log; echo "inbox:"; cat $D/home/state/$ID.inbox/*.msg 2>/dev/null | head -5

hr "S6 teardown after merge on a parked record"
mk s6; E "$D/root/bin/fm-tree-park.sh" park $ID; echo "park rc=$?"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$D/home/data/backlog.md"; echo manual > "$D/home/config/backlog-backend"
before=$(cd $D/project; treehouse status 2>&1 | tail -n +2)
E "$D/root/bin/fm-teardown.sh" $ID 2>&1 | tail -5; echo "teardown rc=${PIPESTATUS[0]}"
echo "record exists after teardown: $([ -e $D/home/state/$ID.meta ] && echo yes || echo no)"
after=$(cd $D/project; treehouse status 2>&1 | tail -n +2); echo "pool after: $after"; [ "$before" = "$after" ] && echo "pool unchanged by teardown"

hr "S5 steer follows a PR head the merger moved while parked"
mk s5; E "$D/root/bin/fm-tree-park.sh" park $ID; echo "park rc=$?"
git -C $D/project checkout -q $BRANCH; echo restack > $D/project/r.txt; git -C $D/project add r.txt; git -C $D/project commit -q -m restack; git -C $D/project push -q origin $BRANCH
git -C $D/project rev-parse HEAD > $D/gh-head; git -C $D/project checkout -q main
E "$D/root/bin/fm-send.sh" $ID "fix the review finding"; echo "send rc=$?"
new=$(grep '^worktree=' $D/home/state/$ID.meta | cut -d= -f2-)
echo "fresh copy HEAD=$(git -C "$new" rev-parse HEAD) expected moved head=$(cat $D/gh-head)"; echo "note:"; cat $D/relaunch-note

hr "S2 adversarial: untracked file in the copy is never parked"
mk s2; wt=$(cat $D/wt0); echo scratch > "$wt/notes.txt"
E "$D/root/bin/fm-tree-park.sh" park $ID; echo "park rc=$?"; (cd $D/project; treehouse status 2>&1 | tail -n +2); meta; ls "$wt/notes.txt"

hr "S3 adversarial: committed-but-unpushed work is never parked"
mk s3; wt=$(cat $D/wt0); echo more > "$wt/more.txt"; git -C "$wt" add more.txt; git -C "$wt" commit -q -m unpushed
E "$D/root/bin/fm-tree-park.sh" park $ID; echo "park rc=$?"; (cd $D/project; treehouse status 2>&1 | tail -n +2); meta; git -C "$wt" log --oneline -1

hr "S7 adversarial: steer to a parked task whose PR merged stays parked, sends nothing"
mk s7; E "$D/root/bin/fm-tree-park.sh" park $ID; echo "park rc=$?"
FM_TEST_GH_STATE=MERGED E "$D/root/bin/fm-send.sh" $ID "restack"; echo "send rc=$?"
meta; echo "pool:"; (cd $D/project; treehouse status 2>&1 | tail -n +2); echo "inbox msgs: $(ls $D/home/state/$ID.inbox/*.msg 2>/dev/null | wc -l)"
