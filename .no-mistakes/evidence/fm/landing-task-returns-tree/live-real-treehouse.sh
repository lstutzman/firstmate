#!/usr/bin/env bash
# Live lab: real treehouse pool, real git remote, real bin/fm-tree-park.sh + fm-send.sh.
# Faked: gh (forge), no-mistakes status, herdr, and fm-control.sh (endpoint stop/relaunch).
set -u
ROOT=$1; EV=$2
. "$ROOT/tests/lib.sh"; . "$ROOT/bin/fm-wake-lib.sh"
fm_git_identity fmtest fmtest@example.invalid
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX); dir=$LAB
BRANCH=fm/lab-task; URL=https://github.com/o/r/pull/42; ID=task-a
export TREEHOUSE_ROOT="$dir/pool"
mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/pool" "$dir/fakebin" "$dir/root"
git init -q --bare "$dir/remote.git"; git clone -q "$dir/remote.git" "$dir/project" 2>/dev/null
git -C "$dir/project" commit -q --allow-empty -m init; git -C "$dir/project" push -q origin HEAD:refs/heads/main
git -C "$dir/project" checkout -q -b "$BRANCH"; echo change > "$dir/project/change.txt"
git -C "$dir/project" add change.txt; git -C "$dir/project" commit -q -m change; git -C "$dir/project" push -q -u origin "$BRANCH"
git -C "$dir/project" checkout -q main 2>/dev/null || git -C "$dir/project" checkout -q -b main origin/main
echo "== real treehouse lease of the ship's first slot"
WT=$(cd "$dir/project" && treehouse get --lease --lease-holder "$ID" 2>"$dir/th-get.err") || { cat "$dir/th-get.err"; exit 1; }
echo "slot: $WT"
git -C "$WT" checkout -q "$BRANCH" && git -C "$WT" branch -q --set-upstream-to="origin/$BRANCH"
head=$(git -C "$WT" rev-parse HEAD); echo "$head" > "$dir/gh-head"
echo '- project [no-mistakes merger=slarti] - fixture (added 2026-01-01)' > "$dir/home/data/projects.md"
cp -R "$ROOT/bin" "$dir/root/bin"
sed -n '/cat > "\$dir\/root\/bin\/fm-control.sh" <<.SH./,/^SH$/p' "$ROOT/tests/fm-tree-park.test.sh" | sed '1d;$d' > "$dir/root/bin/fm-control.sh"; chmod +x "$dir/root/bin/fm-control.sh"
for f in gh no-mistakes herdr; do
  sed -n "/cat > \"\\\$dir\\/fakebin\\/$f\" <<'SH'/,/^SH\$/p" "$ROOT/tests/fm-tree-park.test.sh" | sed '1d;$d' > "$dir/fakebin/$f"; chmod +x "$dir/fakebin/$f"
done
fm_write_meta "$dir/home/state/$ID.meta" window=lab:p1 endpoint_task_id=$ID backend=herdr herdr_session=lab herdr_workspace_id=w1 herdr_tab_id=w1:t1 herdr_pane_id=p1 harness=claude spawn_gen=fm.lab123456 "worktree=$WT" "project=$dir/project" kind=ship mode=no-mistakes pr_at=1700000050 "pr=$URL" "pr_head=$head"
chmod 0600 "$dir/home/state/$ID.meta"
printf 'done [at=1700000100]: PR %s checks green\n' "$URL" > "$dir/home/state/$ID.status"
printf '%s %s\n' "$URL" "$head" > "$dir/home/state/$ID.merge-handoff"; cp "$dir/home/state/$ID.merge-handoff" "$dir/home/state/$ID.nm-released"
FM_HOME="$dir/home" fm_treehouse_slot_owner_claim "$WT" "$ID" "$dir/home"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$ID"); "$ROOT/bin/fm-busy-event.sh" apply "$dir/home/state" "$ID" idle --gen "$gen" --source claude-hook --event stop
: > "$dir/control.log"
L() { FM_TEST_LAB="$dir" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/root" FM_CONFIG_OVERRIDE="$dir/home/config" PATH="$dir/fakebin:$PATH" "$@"; }
echo "== treehouse status before park"; (cd "$dir/project" && treehouse status)
echo "== S1: watcher sweep parks the handed-off ship"
L "$dir/root/bin/fm-tree-park.sh" sweep; echo "sweep rc=$?"
for i in $(seq 1 100); do grep -q '^parked=1' "$dir/home/state/$ID.meta" && break; sleep 0.2; done
echo "-- park log"; cat "$dir/home/state/$ID.park-log" 2>/dev/null
echo "-- record after park"; grep -E '^(worktree|parked[a-z_]*|pr|pr_head)=' "$dir/home/state/$ID.meta"
echo "-- control log"; cat "$dir/control.log"
echo "-- treehouse status after park (slot should be free/not leased)"; (cd "$dir/project" && treehouse status)
echo "== S2: a second sweep does nothing"; L "$dir/root/bin/fm-tree-park.sh" sweep; echo "rc=$?"
echo "== S3: adversarial: new work can take the freed slot"
OTHER=$(cd "$dir/project" && treehouse get --lease --lease-holder other-task 2>/dev/null); echo "other task got: $OTHER"
echo "== S4: merger restacks the PR branch while parked"
git -C "$dir/project" checkout -q "$BRANCH"; echo restack > "$dir/project/restack.txt"; git -C "$dir/project" add restack.txt; git -C "$dir/project" commit -q -m restack
git -C "$dir/project" push -q origin "$BRANCH"; newhead=$(git -C "$dir/project" rev-parse HEAD); git -C "$dir/project" checkout -q main
echo "$newhead" > "$dir/gh-head"; echo "parked_head=$head new PR head=$newhead"
echo "== S4: steer the parked task via fm-send"
L "$dir/root/bin/fm-send.sh" "$ID" "please fix the restack conflict"; echo "send rc=$?"
echo "-- record after unpark"; grep -E '^(worktree|parked[a-z_]*)=' "$dir/home/state/$ID.meta"
NEWWT=$(grep '^worktree=' "$dir/home/state/$ID.meta" | cut -d= -f2-)
echo "-- fresh copy: branch=$(git -C "$NEWWT" symbolic-ref --short HEAD 2>&1) head=$(git -C "$NEWWT" rev-parse HEAD) status=[$(git -C "$NEWWT" status --porcelain)]"
echo "-- control log"; cat "$dir/control.log"; echo "-- relaunch note"; cat "$dir/relaunch-note" 2>/dev/null
echo "-- inbox"; ls "$dir/home/state" | grep -i -E 'inbox|steer' ; cat "$dir/home/state/$ID".inbox* 2>/dev/null | tail -3
echo "-- treehouse status after unpark"; (cd "$dir/project" && treehouse status)
echo "== S5: adversarial: a dirty copy is never parked"
mkdir -p "$dir/home/state/$ID.inbox/handled"; mv "$dir/home/state/$ID.inbox"/*.msg "$dir/home/state/$ID.inbox/handled/"; sleep 1; printf "done [at=%s]: PR %s checks green\n" "$(date +%s)" "$URL" >> "$dir/home/state/$ID.status"
printf '%s %s\n' "$URL" "$newhead" > "$dir/home/state/$ID.merge-handoff"; cp "$dir/home/state/$ID.merge-handoff" "$dir/home/state/$ID.nm-released"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$ID"); "$ROOT/bin/fm-busy-event.sh" apply "$dir/home/state" "$ID" idle --gen "$gen" --source claude-hook --event stop
echo wip > "$NEWWT/uncommitted.txt"
L "$dir/root/bin/fm-tree-park.sh" park "$ID"; echo "park rc=$? (expect 1)"
grep -E '^(worktree|parked)=' "$dir/home/state/$ID.meta"; ls "$NEWWT/uncommitted.txt"
echo "== S6: adversarial: an unpushed commit is never parked"
rm "$NEWWT/uncommitted.txt"; echo local > "$NEWWT/local.txt"; git -C "$NEWWT" add local.txt; git -C "$NEWWT" commit -q -m local-only
L "$dir/root/bin/fm-tree-park.sh" park "$ID"; echo "park rc=$? (expect 1)"
grep -E '^(worktree|parked)=' "$dir/home/state/$ID.meta"; git -C "$NEWWT" log --oneline -1
echo "== cleanup"; (cd "$dir/project" && treehouse return --force "$NEWWT" >/dev/null 2>&1; [ -n "$OTHER" ] && treehouse return --force "$OTHER" >/dev/null 2>&1); rm -rf "$LAB"; echo "lab removed"
