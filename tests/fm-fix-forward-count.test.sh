#!/usr/bin/env bash
# tests/fm-fix-forward-count.test.sh - bin/fm-fix-forward-count.sh counts merged PRs, PRs carrying the
# `Fixes-regression-from:` line, and reverts per repository, with text and JSON output. A fake gh on PATH
# answers `gh pr list` from per-repository JSON files, applies the `merged:>=DATE` / `merged:>DATE` qualifier the way
# GitHub search documents it (by UTC merge date, inclusive for >=), records its arguments, and fails for an
# unreadable repo the way real gh does: `gh repo view` fails, while `gh pr list --search` answers [] with exit 0.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fix-forward-count-tests)
COUNT="$ROOT/bin/fm-fix-forward-count.sh"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
DATA="$TMP_ROOT/data"
mkdir -p "$DATA"
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = "repo view" ]; then
  [ -f "$FAKE_GH_DATA/$(printf '%s' "$3" | tr '/' '_')" ] && exit 0
  echo "GraphQL: could not resolve to a Repository with the name '$3'. (repository)" >&2; exit 1
fi
[ "$1 $2" = "pr list" ] || exit 2
printf '%s\n' "$*" >> "$FAKE_GH_DATA/.calls"
repo=
search=
while [ $# -gt 0 ]; do
  [ "$1" = --repo ] && repo=$2
  [ "$1" = --search ] && search=$2
  shift
done
f="$FAKE_GH_DATA/$(printf '%s' "$repo" | tr '/' '_')"
[ -f "$f" ] || { [ -n "$search" ] && { echo '[]'; exit 0; }; echo "GraphQL: could not resolve to a Repository with the name '$repo'" >&2; exit 1; }
case $search in
  'merged:>='*) jq --arg d "${search#merged:>=}" '[.[] | select((.mergedAt // "9999")[0:10] >= $d)]' "$f" ;;
  'merged:>'*) jq --arg d "${search#merged:>}" '[.[] | select((.mergedAt // "9999")[0:10] > $d)]' "$f" ;;
  *) cat "$f" ;;
esac
SH
chmod +x "$FAKEBIN/gh"
export FAKE_GH_DATA="$DATA"
export PATH="$FAKEBIN:$PATH"

cat > "$DATA/o_a" <<'JSON'
[
 {"number":1,"title":"Add thing","body":"Testing\n\nFixes-regression-from: https://github.com/o/a/pull/90\n"},
 {"number":2,"title":"Revert \"Add other thing\"","body":null},
 {"number":3,"title":"Plain","body":"Mentions Fixes-regression-from: in prose, not a line start"},
 {"number":4,"title":"Fix","body":"Fixes-regression-from: https://github.com/o/a/pull/91"},
 {"number":5,"title":"Not a PR link","body":"Fixes-regression-from: 91"}
]
JSON
printf '[]' > "$DATA/o_b"
for r in firstmate skills fleet-app PropertyCompass2; do printf '[]' > "$DATA/lstutzman_$r"; done

days_ago() { date -u -d "$1 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"$1"d +%Y-%m-%d; }
cat > "$DATA/o_w" <<JSON
[
 {"number":1,"title":"Today","body":"","mergedAt":"$(days_ago 0)T12:00:00Z"},
 {"number":2,"title":"First day of a 7-day window","body":"","mergedAt":"$(days_ago 6)T00:00:01Z"},
 {"number":3,"title":"Exactly 7 days ago","body":"","mergedAt":"$(days_ago 7)T23:59:59Z"},
 {"number":4,"title":"Last week","body":"","mergedAt":"$(days_ago 10)T12:00:00Z"}
]
JSON

test_text_output() {
  local out
  out=$(bash "$COUNT" --repo o/a --repo o/b)
  assert_equals "o/a merged=5 fix_forward=2 reverts=1
o/b merged=0 fix_forward=0 reverts=0" "$out" "text output"
  pass "fm-fix-forward-count.sh: text output counts merged, linked and reverted PRs"
}

test_json_output_and_window() {
  local out
  : > "$DATA/.calls"
  out=$(bash "$COUNT" --json --days 3 --repo o/a)
  assert_equals 3 "$(jq -r .days <<<"$out")" "days"
  assert_equals "$(days_ago 2)" "$(jq -r .since <<<"$out")" "since is the first of the 3 counted days"
  assert_equals "5 2 1 false" \
    "$(jq -r '.repos[0] | "\(.merged) \(.fix_forward) \(.reverts) \(.truncated)"' <<<"$out")" "json counts"
  assert_grep "--state merged" "$DATA/.calls" "only merged PRs are read"
  pass "fm-fix-forward-count.sh: json output"
}

test_window_is_exactly_n_days() {
  assert_equals "o/w merged=2 fix_forward=0 reverts=0" "$(bash "$COUNT" --repo o/w)" \
    "7-day window counts today and 6 days ago, not 7 days ago"
  assert_equals "o/w merged=1 fix_forward=0 reverts=0" "$(bash "$COUNT" --days 1 --repo o/w)" \
    "1-day window counts today only"
  pass "fm-fix-forward-count.sh: a PR merged exactly N days ago falls outside the N-day window"
}

test_bsd_date_fallback() {
  local bsdbin="$TMP_ROOT/bsdbin" real_date
  real_date=$(command -v date)
  mkdir -p "$bsdbin"
  cat > "$bsdbin/date" <<SH
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = -d ] && { echo "date: illegal option -- d" >&2; exit 1; }; done
args=()
for a in "\$@"; do
  case \$a in -v-*d) n=\${a#-v-}; args+=(-d "\${n%d} days ago") ;; *) args+=("\$a") ;; esac
done
exec "$real_date" "\${args[@]}"
SH
  chmod +x "$bsdbin/date"
  assert_equals "o/w merged=2 fix_forward=0 reverts=0" "$(PATH="$bsdbin:$PATH" bash "$COUNT" --repo o/w)" \
    "BSD-style date gives the same window"
  pass "fm-fix-forward-count.sh: falls back to BSD date -v when date -d is unavailable"
}

test_truncated_marker() {
  local out
  out=$(bash "$COUNT" --limit 5 --repo o/a)
  assert_equals "o/a merged=5 fix_forward=2 reverts=1 truncated" "$out" "truncated marker"
  pass "fm-fix-forward-count.sh: a repository at the read limit is marked truncated"
}

test_unreadable_repo_is_reported_and_others_still_print() {
  local out rc
  out=$(bash "$COUNT" --repo o/missing --repo o/b); rc=$?
  assert_equals 1 "$rc" "exit status"
  assert_contains "$out" "o/missing unreadable: GraphQL: could not resolve" "unreadable line"
  assert_contains "$out" "o/b merged=0" "readable repo still printed"
  out=$(bash "$COUNT" --json --repo o/missing) || true
  assert_contains "$(jq -r '.repos[0].error' <<<"$out")" "could not resolve" "json error"
  pass "fm-fix-forward-count.sh: an unreadable repository is reported without hiding the others"
}

test_default_repositories() {
  local out
  : > "$DATA/.calls"
  bash "$COUNT" >/dev/null 2>&1 || true
  for r in lstutzman/firstmate lstutzman/skills lstutzman/fleet-app lstutzman/PropertyCompass2; do
    assert_grep "--repo $r " "$DATA/.calls" "default repository $r"
  done
  : > "$DATA/.calls"
  FM_FIX_FORWARD_REPOS="o/a o/b" bash "$COUNT" >/dev/null
  assert_equals 2 "$(wc -l < "$DATA/.calls" | tr -d ' ')" "env override reads two repositories"
  pass "fm-fix-forward-count.sh: default repositories and the env override"
}

test_usage_errors() {
  local rc
  bash "$COUNT" --days 0 >/dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "days 0"
  bash "$COUNT" --bogus >/dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "unknown flag"
  pass "fm-fix-forward-count.sh: usage errors exit 2"
}

fm_test_run \
  test_text_output \
  test_json_output_and_window \
  test_window_is_exactly_n_days \
  test_bsd_date_fallback \
  test_truncated_marker \
  test_unreadable_repo_is_reported_and_others_still_print \
  test_default_repositories \
  test_usage_errors
