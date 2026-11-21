#!/usr/bin/env bash
# tests/fm-backlog-reconcile.test.sh - the read-only sweep of `## Queued` rows that reality has closed.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECONCILE="$ROOT/bin/fm-backlog-reconcile.py"
TMP_ROOT=$(fm_test_tmproot fm-backlog-reconcile)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# make_world <name>: a home with a backlog, a registered local sibling and fake linear-axi and gh readers.
# FIXTURE/linear/<ID> holds the Linear state name and FIXTURE/pr/<n> the PR state; every call is logged.
make_world() {
  W="$TMP_ROOT/$1"
  mkdir -p "$W/home/data" "$W/home/state" "$W/sibling/data" "$W/bin" "$W/linear" "$W/pr"
  : > "$W/calls"
  cat > "$W/bin/linear-axi" <<'SH'
#!/usr/bin/env bash
printf 'linear %s\n' "$*" >> "$WORLD/calls"
id=$3
[ -f "$WORLD/linear/$id" ] || exit 1
printf '{"ok":true,"data":{"issue":{"identifier":"%s","state":"%s"}}}\n' "$id" "$(cat "$WORLD/linear/$id")"
SH
  cat > "$W/bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$WORLD/calls"
n=${3##*/}
[ -f "$WORLD/pr/$n" ] || exit 1
printf '{"state":"%s"}\n' "$(cat "$WORLD/pr/$n")"
SH
  chmod +x "$W/bin/linear-axi" "$W/bin/gh"
  printf -- '- sibling - mate (home: %s; scope: s; projects: p; added 2026-11-01)\n- far - remote mate (host: h; root: /r; home: /far; scope: s; projects: p; added 2026-11-01)\n' \
    "$W/sibling" > "$W/home/data/secondmates.md"
}

reconcile() { WORLD="$W" PATH="$W/bin:$PATH" FM_HOME="$W/home" python3 "$RECONCILE" "$@"; }

test_reports_each_kind_of_closed_queued_row() {
  make_world kinds
  cat > "$W/home/data/backlog.md" <<'MD'
## In flight
- [ ] running - Running work (repo: x) (kind: ship)

## Queued
- [ ] lin-done - Ship PC-101 (repo: x) (kind: ship) (since 2026-10-01)
- [ ] lin-open - Ship PC-102 (repo: x) (kind: ship) (since 2026-10-02)
- [ ] pr-merged - Fix it https://github.com/o/r/pull/7 (repo: x) (kind: ship) (since 2026-10-03)
- [ ] pr-open - Fix it https://github.com/o/r/pull/8 (repo: x) (kind: ship) (since 2026-10-04)
- [ ] running - Duplicate of in-flight (repo: x) (kind: ship)
- [ ] elsewhere - Already in the sibling (repo: x) (kind: ship)
- [ ] held - Held PC-101 (repo: x) (kind: ship) (hold: waits) (hold-kind: external)

## Done
MD
  printf '## In flight\n- [ ] elsewhere - Working there (repo: x) (kind: ship)\n\n## Queued\n\n## Done\n' > "$W/sibling/data/backlog.md"
  printf 'Done\n' > "$W/linear/PC-101"; printf 'In Progress\n' > "$W/linear/PC-102"
  printf 'MERGED\n' > "$W/pr/7"; printf 'OPEN\n' > "$W/pr/8"
  cp "$W/home/data/backlog.md" "$W/backlog.before"
  out=$(reconcile) || fail "the sweep failed: $out"
  assert_contains "$out" 'linear-closed: lin-done: PC-101 is Done' 'a queued row whose Linear item is Done is reported'
  assert_contains "$out" 'pr-closed: pr-merged: https://github.com/o/r/pull/7 is merged' 'a queued row whose PR merged is reported'
  assert_contains "$out" 'duplicate: running: already a row in this home (in flight)' 'a queued row that is also in flight here is reported'
  assert_contains "$out" 'duplicate: elsewhere: already a row in '"$W/sibling"' (in flight)' 'a queued row in flight in a sibling home is reported'
  assert_not_contains "$out" 'lin-open' 'an open Linear item is not a finding'
  assert_not_contains "$out" 'pr-open' 'an open PR is not a finding'
  assert_not_contains "$out" 'held:' 'a held row is skipped'
  assert_contains "$out" '1 remote homes not read for duplicates' 'a remote home is named as unchecked, never silently passed'
  assert_equals "$(cat "$W/backlog.before")" "$(cat "$W/home/data/backlog.md")" 'the sweep never changes the backlog'
  assert_equals "4" "$(jq '.findings | length' "$W/home/state/backlog-reconcile.json")" 'the report file carries every finding'
  pass 'reconcile: reports queued rows closed in Linear, by a PR, or duplicated, and changes nothing'
}

test_lookups_are_bounded_and_failures_are_unchecked() {
  make_world bounded
  {
    printf '## Queued\n'
    for n in 1 2 3 4; do printf -- '- [ ] r-%s - Work PC-20%s (repo: x) (kind: ship) (since 2026-10-0%s)\n' "$n" "$n" "$n"; done
    printf '\n## Done\n'
  } > "$W/home/data/backlog.md"
  for n in 1 2 3; do printf 'Done\n' > "$W/linear/PC-20$n"; done # PC-204 has no fixture: the lookup fails
  out=$(reconcile --max-linear 2) || fail "the sweep failed: $out"
  assert_equals "2" "$(grep -c '^linear ' "$W/calls")" 'only --max-linear Linear lookups are made, oldest rows first'
  assert_contains "$out" 'linear-closed: r-1' 'the oldest row is checked first'
  assert_contains "$out" 'linear-closed: r-2' 'the second oldest row is checked'
  assert_not_contains "$out" 'r-3' 'a row past the bound is not guessed at'
  assert_contains "$out" '2 Linear and 0 PR lookups unchecked' 'rows past the bound are counted as unchecked'
  out=$(reconcile --max-linear 10) || fail "the sweep failed: $out"
  assert_contains "$out" '1 Linear and 0 PR lookups unchecked' 'a failed lookup is unchecked, not a finding'
  pass 'reconcile: lookups are bounded per run, oldest first, and a failed lookup is reported as unchecked'
}

test_missing_backlog_and_json() {
  make_world missing
  out=$(reconcile 2>&1); rc=$?
  assert_equals "1" "$rc" 'a home with no backlog is an error'
  printf '## Queued\n- [ ] a - A (repo: x) (kind: ship)\n\n## Done\n' > "$W/home/data/backlog.md"
  assert_equals '{"findings":0,"queued":1,"schema":"fm-backlog-reconcile.v1"}' "$(reconcile --json | jq -cS '{schema, queued, findings: (.findings | length)}')" '--json prints the report'
  pass 'reconcile: a missing backlog is an error and --json prints the report document'
}

test_reports_each_kind_of_closed_queued_row
test_lookups_are_bounded_and_failures_are_unchecked
test_missing_backlog_and_json
echo FM_TEST_COMPLETE
