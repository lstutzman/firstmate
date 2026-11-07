#!/usr/bin/env bash
# Live: real treehouse v3 pool shared by clones of one origin, in a disposable lab.
set -u
WT=$1; LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-th-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
export TREEHOUSE_ROOT="$LAB/pool" FM_TREEHOUSE_PEER_ROOTS="$LAB/nonexistent"
echo "LAB=$LAB TREEHOUSE_ROOT=$TREEHOUSE_ROOT"
git init -q "$LAB/src"; git -C "$LAB/src" commit -q --allow-empty -m init
git clone -q --bare "$LAB/src" "$LAB/App.git"; ORIGIN="$LAB/App.git"
H="$LAB/fm-homes"; mkdir -p "$H/main/data" "$H/main/state" "$H/main/projects" "$H/nav/projects" "$H/old/projects"
git clone -q "$ORIGIN" "$H/main/projects/App"
printf '%s\n' '- App [direct-PR] - app (added 2026-11-07)' > "$H/main/data/projects.md"
git clone -q "$ORIGIN" "$H/nav/projects/App"
printf 'max_trees = 20\n' > "$H/nav/projects/App/treehouse.toml"
printf '/treehouse.toml\n' >> "$H/nav/projects/App/.git/info/exclude"
git clone -q "$ORIGIN" "$H/old/projects/App"   # pre-fix style clone: no treehouse.toml
echo "== nav grows the shared pool to 17 slots (max_trees 20) and returns them"
paths=()
for i in $(seq 1 17); do p=$(cd "$H/nav/projects/App" && treehouse get --lease 2>/dev/null) || { echo "nav lease $i FAILED"; break; }; paths+=("$p"); done
echo "nav leased ${#paths[@]} slots"
for p in "${paths[@]}"; do (cd "$H/nav/projects/App" && treehouse return "$p" >/dev/null 2>&1); done
ls -d "$TREEHOUSE_ROOT"/.treehouse/*/ ; echo "slots on disk: $(ls "$TREEHOUSE_ROOT"/.treehouse/*/ | wc -l)"
echo "== BASELINE: clone without treehouse.toml (default 16) tries to get a slot"
(cd "$H/old/projects/App" && treehouse get --lease 2>&1); echo "old exit=$?"
echo "== fm-office ensure reports the mismatch"
FM_TREEHOUSE_PEER_ROOTS="$H" FM_HOME="$H/main" FM_DATA_OVERRIDE="$H/main/data" bash "$WT/bin/fm-office.sh" ensure; echo "ensure exit=$?"
echo "== real fm-home-seed seeds the Librarian home (peer roots only via call-site args)"
FM_HOME="$H/main" FM_SECONDMATE_CHARTER=librarian FM_SECONDMATE_SCOPE=librarian "$WT/bin/fm-home-seed.sh" lib "$H/lib" App; echo "seed exit=$?"
echo "-- lib treehouse.toml:"; cat "$H/lib/projects/App/treehouse.toml"
echo "-- lib git status --porcelain: [$(git -C "$H/lib/projects/App" status --porcelain)]"
echo "== Librarian clone gets a slot from the shared pool"
lp=$(cd "$H/lib/projects/App" && treehouse get --lease 2>&1); echo "lib exit=$? path=$lp"
(cd "$H/lib/projects/App" && treehouse status 2>&1 | tail -5)
[ -d "$lp" ] && (cd "$H/lib/projects/App" && treehouse return "$lp" >/dev/null 2>&1)
echo "== teardown"; /usr/bin/trash "$LAB" && echo "lab trashed"
