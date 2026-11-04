#!/usr/bin/env bash
# A spawn republishes state/home-summary.json after the backlog item moves to
# In flight, so the summary never keeps the "no in-flight backlog item" reason.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-home-summary)
command -v tasks-axi >/dev/null 2>&1 || { pass 'skipped (tasks-axi is not installed)'; exit 0; }
id='summary-after-commit'
home="$TMP_ROOT/home"
proj="$TMP_ROOT/project"
wt="$TMP_ROOT/wt"
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
fm_test_spawn_home "$home" claude
fm_git_worktree "$proj" "$wt" summary-test
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$home/.tasks.toml"
tasks-axi add "$id" "item for $id" --kind ship --file "$home/data/backlog.md" >/dev/null
fm_test_spawn_brief "$home" "$id"
fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off > "$TMP_ROOT/out" 2>&1 ||
  fail "spawn failed: $(cat "$TMP_ROOT/out")"
summary="$home/state/home-summary.json"
[ -s "$summary" ] || fail 'spawn did not publish a home summary'
if grep -q 'no in-flight backlog item' "$summary"; then
  fail "summary still carries the unowned-child reason: $(cat "$summary")"
fi
grep -q "\"$id\"" "$summary" || fail "summary does not list $id: $(cat "$summary")"
jq -e '.valid == true' "$summary" >/dev/null || fail "summary is not valid: $(cat "$summary")"
pass 'spawn republishes a valid home summary after the In flight transition'
