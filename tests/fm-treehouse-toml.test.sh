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
  assert_equals "" "$(git -C "$w/homes/lib/projects/App" status --porcelain)" "status after inherit"
  inherit "$w" lib >/dev/null
  assert_equals 1 "$(grep -cxF /treehouse.toml "$(git -C "$w/homes/lib/projects/App" rev-parse --path-format=absolute --git-path info/exclude)")" "one exclude entry"
  pass 'a new clone inherits max_trees from an existing clone and stays clean'
}

test_seed_clone_inherits_max_trees() {
  local w main
  w="$TMP_ROOT/seed"; main="$w/fm-homes/main"
  mkdir -p "$main/projects" "$main/data" "$main/state" "$w/fm-homes/nav/projects"
  fm_git_init_commit "$main/projects/App"
  fm_git_add_origin "$main/projects/App" "$w/App.git"
  printf '%s\n' '- App [direct-PR] - app (added 2026-11-07)' > "$main/data/projects.md"
  git clone -q "$(git -C "$main/projects/App" remote get-url origin)" "$w/fm-homes/nav/projects/App"
  printf 'max_trees = 24\n' > "$w/fm-homes/nav/projects/App/treehouse.toml"
  FM_HOME="$main" FM_SECONDMATE_CHARTER='librarian' FM_SECONDMATE_SCOPE='librarian' \
    "$ROOT/bin/fm-home-seed.sh" lib "$w/fm-homes/lib" App >/dev/null || fail "seed failed"
  assert_equals 'max_trees = 24' "$(cat "$w/fm-homes/lib/projects/App/treehouse.toml")" "seeded clone's treehouse.toml"
  assert_equals "" "$(git -C "$w/fm-homes/lib/projects/App" status --porcelain)" "seeded clone status"
  pass 'fm-home-seed gives a new clone the max_trees of a peer home clone'
}

test_remote_provision_clone_inherits_max_trees() {
  local w origin
  mkdir -p "$TMP_ROOT/provision/homes/nav/projects"
  w=$(cd "$TMP_ROOT/provision" && pwd -P)
  fm_git_init_commit "$w/src"
  git clone -q --bare "$w/src" "$w/App.git"
  origin="file://$w/App.git"
  git clone -q "$origin" "$w/homes/nav/projects/App"
  printf 'max_trees = 24\n' > "$w/homes/nav/projects/App/treehouse.toml"
  b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
  printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=1\nproject=%s|%s|%s|%s\n' \
    "$(b64 lib)" "$(b64 'Librarian charter.')" "$(b64 App)" "$(b64 "$origin")" \
    "$(b64 '- App [direct-PR] - app (added 2026-11-07)')" "$(b64 direct-PR)" > "$w/manifest"
  FM_HOME="$w/homes/lib" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-remote-home-provision.sh" < "$w/manifest" >/dev/null 2>&1 \
    || fail "remote provision failed"
  assert_equals 'max_trees = 24' "$(cat "$w/homes/lib/projects/App/treehouse.toml")" "provisioned clone's treehouse.toml"
  assert_equals "" "$(git -C "$w/homes/lib/projects/App" status --porcelain)" "provisioned clone status"
  pass 'fm-remote-home-provision gives a new clone the max_trees of a peer home clone'
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

fm_test_run test_new_clone_inherits_max_trees test_seed_clone_inherits_max_trees test_remote_provision_clone_inherits_max_trees test_largest_max_trees_wins test_existing_file_is_kept \
  test_other_origin_is_not_a_peer test_ensure_reports_differing_max_trees test_ensure_is_silent_when_they_agree
