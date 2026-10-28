#!/usr/bin/env bash
# Live driver: real fm-spawn.sh + real tmux (private lab socket) + real treehouse + real npm ci.
set -u
ROOT=$1; EV=$2
LAB=$(mktemp -d "/tmp/fm-lab.XXXXXX")
bash "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/treehouse"
touch "$LAB/state/.last-watcher-beat"
echo "LAB=$LAB"
T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
# scratch project: package.json depending on a local tarball, so npm ci works offline
P="$LAB/work/depproj"; mkdir -p "$P/vendor" "$LAB/pkgsrc/leftpad-lab"
cat > "$LAB/pkgsrc/leftpad-lab/package.json" <<'J'
{"name":"leftpad-lab","version":"1.0.0","main":"index.js"}
J
echo 'module.exports=(s,n)=>String(s).padStart(n)' > "$LAB/pkgsrc/leftpad-lab/index.js"
(cd "$LAB/pkgsrc/leftpad-lab" && npm pack --silent --pack-destination "$P/vendor" >/dev/null)
cat > "$P/package.json" <<'J'
{"name":"depproj","version":"0.0.0","private":true,"dependencies":{"leftpad-lab":"file:vendor/leftpad-lab-1.0.0.tgz"}}
J
(cd "$P" && npm install --silent --no-audit --no-fund >/dev/null && rm -rf node_modules)
printf 'node_modules/\nworker-saw.txt\n' > "$P/.gitignore"
git -C "$P" init -q && git -C "$P" add -A && git -C "$P" -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone -q --bare "$P" "$P.origin.git" && git -C "$P" remote add origin "file://$P.origin.git" && git -C "$P" fetch -q origin
SETUP="$LAB/config/spawn-setup/depproj"; mkdir -p "$SETUP"
printf 'set -e\nnpm ci --no-audit --no-fund\nnode -e "console.log(require(\\"leftpad-lab\\")(\\"ok\\",6))"\n' > "$SETUP/10-npm.sh"
printf 'echo "restore: package source unreachable" >&2\nexit 3\n' > "$SETUP/20-restore.sh"
brief() { mkdir -p "$LAB/data/$1"; printf "# Task\n## Captain's intent\nlive spawn-setup check $1\n\n## Firstmate spec\nVerify dependency setup.\n" > "$LAB/data/$1/brief.md"; }
T new-session -d -s primary -x 200 -y 50 -c "$ROOT" \
  -e FM_HOME="$LAB" -e TREEHOUSE_ROOT="$LAB/treehouse" -e FM_SPAWN_NO_GUARD=1 bash --noprofile --norc
spawn() { # id outfile [extra]
  local id=$1 out=$2
  T send-keys -t primary "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE bin/fm-spawn.sh $id $P \"sh -c 'ls node_modules > worker-saw.txt 2>&1; sleep 900'\" --mode local-only --yolo off > $out 2>&1; echo \"rc=\$?\" >> $out" Enter
}
waitfor() { local f=$1 n=0; while ! grep -q '^rc=' "$f" 2>/dev/null && [ $n -lt 600 ]; do sleep 0.5; n=$((n+1)); done; }
{
echo "=== Scenario 1: fresh spawn installs deps (npm ci) in the task copy; failing step reported, worker still launches"
brief live1; spawn live1 "$LAB/s1.out"; waitfor "$LAB/s1.out"; cat "$LAB/s1.out" | tail -5
WT1=$(grep '^worktree=' "$LAB/state/live1.meta" | cut -d= -f2-); echo "worktree=$WT1"
sleep 2
echo "--- worker-saw.txt (what the worker found at start):"; cat "$WT1/worker-saw.txt"
echo "--- node_modules in source project? "; ls "$P/node_modules" 2>&1
echo "--- state/live1.setup:"; ls "$LAB/state/live1.setup"; echo "--- 10-npm.log:"; cat "$LAB/state/live1.setup/10-npm.log"; echo "--- 20-restore.log:"; cat "$LAB/state/live1.setup/20-restore.log"
echo "--- launch-brief tail:"; tail -4 "$LAB/data/live1/launch-brief.md"
echo
echo "=== Scenario 2: per-step off switch (20-restore.off) skips only that step"
touch "$SETUP/20-restore.off"
brief live2; spawn live2 "$LAB/s2.out"; waitfor "$LAB/s2.out"; tail -2 "$LAB/s2.out"
ls "$LAB/state/live2.setup"; grep -c 'Spawn dependency setup' "$LAB/data/live2/launch-brief.md" || true
echo
echo "=== Scenario 3: long setup does not block a second spawn of the same project"
rm -f "$SETUP/10-npm.sh"; GATE="$LAB/gate"; mkdir -p "$GATE"
cat > "$SETUP/05-slow.sh" <<SH
[ -e "$GATE/first-taken" ] && exit 0
touch "$GATE/first-taken" "$GATE/entered"
n=0; while [ ! -e "$GATE/release" ] && [ \$n -lt 1200 ]; do sleep 0.1; n=\$((n+1)); done
SH
T new-window -d -t primary -n second -c "$ROOT" bash --noprofile --norc
brief live3; brief live4
spawn live3 "$LAB/s3.out"
n=0; while [ ! -e "$GATE/entered" ] && [ $n -lt 600 ]; do sleep 0.5; n=$((n+1)); done
echo "first spawn setup entered: $( [ -e "$GATE/entered" ] && echo yes || echo no )"
T send-keys -t primary:second "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE bin/fm-spawn.sh live4 $P \"sh -c 'sleep 900'\" --mode local-only --yolo off > $LAB/s4.out 2>&1; echo \"rc=\$?\" >> $LAB/s4.out" Enter
waitfor "$LAB/s4.out"
echo "second spawn finished while first setup still blocked (release absent=$( [ ! -e "$GATE/release" ] && echo yes)); s3 done yet=$(grep -c '^rc=' "$LAB/s3.out" 2>/dev/null || echo 0)"
tail -2 "$LAB/s4.out"
touch "$GATE/release"; waitfor "$LAB/s3.out"; tail -2 "$LAB/s3.out"
echo
echo "=== Scenario 4: project-wide off switch skips all setup"
touch "$SETUP/off"; brief live5; spawn live5 "$LAB/s5.out"; waitfor "$LAB/s5.out"; tail -2 "$LAB/s5.out"
[ -e "$LAB/state/live5.setup" ] && echo "setup state present (UNEXPECTED)" || echo "no live5.setup state dir: setup skipped"
} 2>&1
echo "=== teardown"
for id in live1 live2 live3 live4 live5; do
  w=$(grep '^worktree=' "$LAB/state/$id.meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$w" ] && TREEHOUSE_ROOT="$LAB/treehouse" treehouse return --force "$w" >/dev/null 2>&1
done
T kill-server 2>/dev/null
rm -rf "$LAB"; echo "lab removed: $( [ -e "$LAB" ] && echo no || echo yes )"
