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

test_a_mate_home_reads_the_primary_registry_and_backlog() {
  make_world mate
  mkdir -p "$W/mate/data"
  printf -- '- mate - this mate (home: %s; scope: s; projects: p; added 2026-11-01)\n' "$W/mate" >> "$W/home/data/secondmates.md"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$W/home" > "$W/mate/.fm-secondmate-parent"
  printf '## In flight\n- [ ] at-primary - Primary runs it (repo: x) (kind: ship)\n\n## Queued\n\n## Done\n' > "$W/home/data/backlog.md"
  printf '## In flight\n\n## Queued\n\n## Done\n- [x] at-sibling - Sibling finished it (repo: x) (kind: ship)\n' > "$W/sibling/data/backlog.md"
  printf '## In flight\n\n## Queued\n- [ ] at-primary - Stale copy (repo: x) (kind: ship)\n- [ ] at-sibling - Stale copy (repo: x) (kind: ship)\n- [ ] fresh - Fresh (repo: x) (kind: ship)\n\n## Done\n' > "$W/mate/data/backlog.md"
  out=$(reconcile --home "$W/mate") || fail "the sweep failed: $out"
  assert_contains "$out" 'duplicate: at-primary: already a row in '"$W/home"' (in flight)' 'a mate row the primary holds in flight is reported'
  assert_contains "$out" 'duplicate: at-sibling: already a row in '"$W/sibling"' (done)' 'a mate row another mate finished is reported, from the primary registry'
  assert_not_contains "$out" 'fresh' 'a row no other home holds is not a finding'
  assert_contains "$out" '1 remote homes not read for duplicates' 'remote homes in the primary registry are counted'
  assert_not_contains "$out" 'registry not found' 'the primary registry was read'
  mv "$W/mate/.fm-secondmate-parent" "$W/parent.moved"
  out=$(reconcile --home "$W/mate") || fail "the sweep failed: $out"
  assert_not_contains "$out" 'duplicate:' 'with no parent record and no registry no other home is read'
  assert_contains "$out" 'registry not found; duplicates in other homes unchecked' 'a missing registry is named, never silently passed'
  assert_equals "false" "$(jq '.registry_found' "$W/mate/state/backlog-reconcile.json")" 'the report records the missing registry'
  pass 'reconcile: a mate home checks duplicates against the primary and every local home in its registry'
}

test_only_the_rows_own_item_is_looked_up() {
  make_world own
  cat > "$W/home/data/backlog.md" <<'MD'
## Queued
- [ ] follow - Follow up on PC-301 then PC-302 (repo: x) (kind: ship) (since 2026-10-01)
- [ ] field - Follow up on PC-301 review comments (repo: x) (kind: ship) (linear: FLEET-9) (since 2026-10-02)
- [ ] hashes - Pin SHA-256 sums and ISO-8601 dates (repo: x) (kind: ship) (since 2026-10-03)
- [ ] own-pr - Land https://github.com/o/r/pull/20 after https://github.com/o/r/pull/21 (repo: x) (kind: ship) (since 2026-10-04)
- [ ] body-ctx - Rework the parser (repo: x) (kind: ship) (since 2026-10-05)
  Context: PC-303 and https://github.com/o/r/pull/22 already landed.

## Done
MD
  printf 'In Progress\n' > "$W/linear/PC-301"; printf 'Done\n' > "$W/linear/PC-302"; printf 'Done\n' > "$W/linear/PC-303"
  printf 'Done\n' > "$W/linear/FLEET-9"
  printf 'OPEN\n' > "$W/pr/20"; printf 'MERGED\n' > "$W/pr/21"; printf 'MERGED\n' > "$W/pr/22"
  out=$(reconcile) || fail "the sweep failed: $out"
  assert_not_contains "$out" 'follow:' 'a later identifier in the title is context: the row is judged on its first'
  assert_contains "$out" 'linear-closed: field: FLEET-9 is Done' 'a (linear: ...) field names the row item over the title'
  assert_not_contains "$out" 'hashes' 'SHA-256 and ISO-8601 are not Linear identifiers'
  assert_not_contains "$out" 'own-pr' 'a second PR link on the title line is context'
  assert_not_contains "$out" 'body-ctx' 'identifiers and PR links in the body are context'
  assert_equals "linear issue view PC-301 --output json
linear issue view FLEET-9 --output json" "$(grep '^linear ' "$W/calls")" 'only each row own Linear item is looked up, so context never spends the budget'
  assert_equals "gh pr view https://github.com/o/r/pull/20 --json state" "$(grep '^gh ' "$W/calls")" 'only the first PR link on the title line is looked up'
  pass 'reconcile: a queued row is judged only on its own Linear item and pull request'
}

test_reports_each_kind_of_closed_queued_row
test_a_mate_home_reads_the_primary_registry_and_backlog
test_only_the_rows_own_item_is_looked_up
test_lookups_are_bounded_and_failures_are_unchecked
test_missing_backlog_and_json
echo FM_TEST_COMPLETE
