#!/usr/bin/env bash
# Behavior tests for bin/fm-treehouse-toml-lib.sh: a new clone inherits a peer's
# treehouse.toml, an existing one is kept, and fm-office.sh ensure reports
# clones of one origin that disagree on max_trees.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OFFICE="$ROOT/bin/fm-office.sh"
TMP_ROOT=$(fm_test_tmproot fm-treehouse-toml)

# world <name>: an origin repo and an empty homes root; prints the world dir.
world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/homes"
  git init -q "$w/origin"
  echo "$w"
}

# clone_into <world> <home> [max_trees]: clone origin as <home>'s project.
clone_into() {
  mkdir -p "$1/homes/$2/projects"
  git clone -q "$1/origin" "$1/homes/$2/projects/App" 2>/dev/null
  [ -z "${3:-}" ] || printf 'other = "x"\nmax_trees = %s\n' "$3" > "$1/homes/$2/projects/App/treehouse.toml"
}

inherit() { # <world> <home>
  FM_TREEHOUSE_PEER_ROOTS="$1/homes" bash -c ". '$ROOT/bin/fm-treehouse-toml-lib.sh'; fm_th_inherit '$1/homes/$2/projects/App' App"
}

ensure() { FM_TREEHOUSE_PEER_ROOTS="$1/homes" FM_HOME="$1/primary" FM_DATA_OVERRIDE="$1/primary/data" bash "$OFFICE" ensure; }

test_new_clone_inherits_max_trees() {
  local w out; w=$(world inherit)
  clone_into "$w" nav 24; clone_into "$w" lib
  out=$(inherit "$w" lib)
  assert_equals 'other = "x"
max_trees = 24' "$(cat "$w/homes/lib/projects/App/treehouse.toml")" "inherited file"
  assert_contains "$out" "$w/homes/nav/projects/App" "output names the source"
  pass 'a new clone inherits max_trees from an existing clone'
}

test_largest_max_trees_wins() {
  local w out; w=$(world largest)
  clone_into "$w" a 20; clone_into "$w" b 30; clone_into "$w" lib
  out=$(inherit "$w" lib)
  assert_contains "$(cat "$w/homes/lib/projects/App/treehouse.toml")" "max_trees = 30" "largest value"
  assert_contains "$out" "max_trees 30" "output says which"
  pass 'the largest max_trees is taken when peers differ'
}

test_existing_file_is_kept() {
  local w; w=$(world keep)
  clone_into "$w" nav 24; clone_into "$w" lib 8
  inherit "$w" lib >/dev/null
  assert_contains "$(cat "$w/homes/lib/projects/App/treehouse.toml")" "max_trees = 8" "kept file"
  pass 'an existing treehouse.toml is not overwritten'
}

test_other_origin_is_not_a_peer() {
  local w; w=$(world origin)
  clone_into "$w" nav 24; clone_into "$w" lib
  git -C "$w/homes/nav/projects/App" remote set-url origin "$w/elsewhere"
  inherit "$w" lib >/dev/null
  [ ! -e "$w/homes/lib/projects/App/treehouse.toml" ] || fail "copied from a clone of another origin"
  pass 'a clone of a different origin is not a peer'
}

test_ensure_reports_differing_max_trees() {
  local w out; w=$(world mismatch)
  clone_into "$w" nav 24; clone_into "$w" lib
  out=$(ensure "$w")
  assert_contains "$out" "OFFICE: pool:" "pool line"
  assert_contains "$out" "$w/homes/lib/projects/App=16" "names the default clone"
  pass 'ensure reports clones that differ on max_trees'
}

test_ensure_is_silent_when_they_agree() {
  local w out; w=$(world agree)
  clone_into "$w" nav 24; clone_into "$w" lib 24
  out=$(ensure "$w")
  assert_equals "" "$out" "ensure output"
  pass 'ensure is silent when clones agree on max_trees'
}

fm_test_run test_new_clone_inherits_max_trees test_largest_max_trees_wins test_existing_file_is_kept \
  test_other_origin_is_not_a_peer test_ensure_reports_differing_max_trees test_ensure_is_silent_when_they_agree
