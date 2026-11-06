#!/usr/bin/env bash
# Spawn a real worker in a disposable home and show the published home summary's endpoints carry `kind`.
set -u
cd "$1"
. tests/fixtures.sh
TMP_ROOT=$(fm_test_tmproot fm-live-kind)
command -v tasks-axi >/dev/null || { echo 'tasks-axi missing'; exit 2; }
id='live-kind-item'; home="$TMP_ROOT/home"; proj="$TMP_ROOT/project"; wt="$TMP_ROOT/wt"
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
fm_test_spawn_home "$home" claude
fm_git_worktree "$proj" "$wt" live-kind
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$home/.tasks.toml"
tasks-axi add "$id" "item" --kind ship --file "$home/data/backlog.md" >/dev/null
fm_test_spawn_brief "$home" "$id"
fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off > "$TMP_ROOT/out" 2>&1 || { cat "$TMP_ROOT/out"; exit 1; }
jq '{valid, counts, endpoints: [.endpoints[] | {id, kind, state}]}' "$home/state/home-summary.json"
jq -e '.endpoints | length > 0 and all(.kind != null)' "$home/state/home-summary.json" >/dev/null && echo 'PASS: every endpoint carries kind'
