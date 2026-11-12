#!/usr/bin/env bash
# tests/fm-config-split.test.sh - bin/fm-config-split.py splits docs/configuration.md by a section map.
# Fixture repositories are built in a temp root: a small configuration doc with shared and fork-only
# sections (a fenced "## " line, a heading with no blank line before it, an extracted tail h3, links
# that cross sections), plus outside files that cite it in every form the script rewrites.
# The real tree is only checked (never changed) by the last test.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-config-split-tests)
SPLIT="$ROOT/bin/fm-config-split.py"

split() { python3 -I "$SPLIT" "$@"; }

# build_fixture <dir>: a git repository holding the fixture; prints nothing.
build_fixture() {
  local d=$1
  mkdir -p "$d/docs/config-split" "$d/bin" "$d/.agents/skills/x"
  cat > "$d/docs/configuration.md" <<'EOF'
# Configuration

Intro line with a [link to the readme](../README.md).

## Alpha (config/alpha)

Alpha is shared and cites [Beta](#beta-configbeta) and [Gamma](#gamma).
See [the script](../bin/tool.sh) and <a href="../bin/tool.sh">raw</a>.

```sh
## not a heading, this is a comment inside a fence
echo hello
```

## Beta (config/beta)

Beta is fork-only and cites [Alpha](#alpha-configalpha).

### Beta detail

Detail text.

## Gamma

Gamma is shared.
## Delta (config/delta)

Delta is fork-only and cites [Gamma](#gamma) and the tail [Delta tail](#delta-tail).
Delta cites docs/configuration.md "Beta (config/beta)" itself.

### Delta tail

Tail text.

## Harbour deck

Harbour deck, fork-only.

## Harbour rules

Harbour rules, fork-only.

## Omega

Omega is shared.
EOF
  printf '# Readme\n' > "$d/README.md"
  printf '#!/usr/bin/env bash\n# tool\n' > "$d/bin/tool.sh"
  cat > "$d/docs/config-split/shared-map.tsv" <<'EOF'
# shared
file	main.md	Main settings
file	tail.md	Tail settings
h2	main.md	Alpha
h2	main.md	Gamma
h2	tail.md	Omega
EOF
  cat > "$d/docs/config-split/fork-local-map.tsv" <<'EOF'
# fork
file	fork.md	Fork settings
file	delta-tail.md	Delta tail reference
h2	fork.md	Beta
h2	main.md	Delta
h2	fork.md	Harbour deck
h2	fork.md	Harbour rules
h3	delta-tail.md	Delta	Delta tail
EOF
  cat > "$d/AGENTS.md" <<'EOF'
# Agents

Cites docs/configuration.md "Beta (config/beta)" and [`docs/configuration.md`](docs/configuration.md#beta-configbeta).
EOF
  cat > "$d/docs/other.md" <<'EOF'
# Other

See [`docs/configuration.md`](../docs/configuration.md) "Delta (config/delta)" and [the setting](configuration.md#beta-configbeta).
The `docs/configuration.md`'s "Gamma" section stays in the index; docs/configuration.md "Omega" is shared.
An ambiguous docs/configuration.md "Harbour" name is skipped, and docs/configuration.md (Beta) is a parenthesised cite.
EOF
  cat > "$d/bin/tool2.sh" <<'EOF'
#!/usr/bin/env bash
echo "error: fix it (docs/configuration.md \"Beta (config/beta)\")" >&2
# wrapped cite: docs/configuration.md
# "Harbour rules" owns the schema
EOF
  cat > "$d/docs/documentation-audiences.json" <<'EOF'
{
  "surfaces": [
    {
      "path": "docs/configuration.md",
      "audience": "operator-current"
    },
    {
      "path": "docs/other.md",
      "audience": "operator-current"
    }
  ]
}
EOF
  git -C "$d" init -q
  fm_git_identity "$d" 2>/dev/null || true
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@t commit -qm base
  cp "$d/docs/configuration.md" "$d/../orig-$(basename "$d").md"
}

tree_digest() { (cd "$1" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum); }

test_check_and_unassigned() {
  local d="$TMP_ROOT/check"
  build_fixture "$d"
  out=$(split --check --root "$d" 2>&1) || fail "check failed on the fixture: $out"
  assert_contains "$out" "h2=7 assigned=7" "check counts the h2 sections (the fenced line is not one)"
  assert_contains "$out" "forkonly_units=5" "check counts fork-local units"
  printf '\n## Zeta\n\nUnmapped.\n' >> "$d/docs/configuration.md"
  out=$(split --check --root "$d" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "check passed with an unmapped h2"
  assert_contains "$out" "unassigned: Zeta" "check names the unmapped h2"
  pass "fm-config-split.py --check: counts sections and rejects an unmapped h2"
}

test_check_duplicates() {
  local d="$TMP_ROOT/dups"
  build_fixture "$d"
  printf '\n## Gamma\n\nAgain.\n' >> "$d/docs/configuration.md"
  out=$(split --check --root "$d" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "check passed with a duplicated heading"
  assert_contains "$out" "duplicate heading anchors: gamma" "check names the duplicate anchor"
  build_fixture "$TMP_ROOT/dups2"
  sed -i 's/^file\tfork.md\tFork settings/file\tfork.md\tOmega/' "$TMP_ROOT/dups2/docs/config-split/fork-local-map.tsv"
  out=$(split --check --root "$TMP_ROOT/dups2" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "check passed with a file title that collides with a heading"
  assert_contains "$out" "collides with a heading anchor 'omega'" "check names the title collision"
  pass "fm-config-split.py --check: duplicate anchors and title collisions fail"
}

test_forkonly_moves_and_conserves() {
  local d="$TMP_ROOT/fork"
  build_fixture "$d"
  local agents_before
  agents_before=$(sha256sum < "$d/AGENTS.md")
  out=$(split --forkonly --root "$d" 2>&1) || fail "forkonly failed: $out"
  assert_contains "$out" "sections_moved=5 files=3" "five units move into three files"
  [ -f "$d/docs/configuration/fork.md" ] && [ -f "$d/docs/configuration/delta-tail.md" ] || fail "moved files missing"
  [ ! -e "$d/docs/configuration/tail.md" ] || fail "forkonly created a file for a shared section"
  ! grep -q '^## Alpha' "$d/docs/configuration/main.md" || fail "forkonly moved a shared section into main.md"
  grep -q '^## Beta (config/beta)$' "$d/docs/configuration/fork.md" || fail "Beta heading not byte-for-byte in fork.md"
  ! grep -q '^## Beta' "$d/docs/configuration.md" || fail "Beta heading left in the index"
  grep -q '^## Alpha (config/alpha)$' "$d/docs/configuration.md" || fail "shared Alpha left the index"
  grep -q '^## not a heading' "$d/docs/configuration.md" || fail "fenced line lost"
  grep -q '<a id="beta-configbeta"></a><a id="beta-detail"></a>Moved to \[Beta (config/beta)\](configuration/fork.md#beta-configbeta)\.$' "$d/docs/configuration.md" ||
    fail "pointer line with hidden anchors missing"
  assert_equals "$agents_before" "$(sha256sum < "$d/AGENTS.md")" "AGENTS.md untouched"
  out=$(split --conserve "$d/../orig-fork.md" --root "$d" 2>&1) || fail "conservation failed: $out"
  assert_contains "$out" "lost=0 changed=0" "no line lost or changed"
  split --check --anchors-of "$d/../orig-fork.md" --root "$d" >/dev/null 2>&1 || fail "an old anchor no longer resolves in the index"
  # link rewrites: cross-file anchor, one more ../ for relative links, the tail h3 in its own file
  grep -q 'cites \[Alpha\](\.\./configuration\.md#alpha-configalpha)' "$d/docs/configuration/fork.md" || fail "anchor into the index not rewritten"
  grep -q 'cites \[Gamma\](\.\./configuration\.md#gamma) and the tail \[Delta tail\](delta-tail\.md#delta-tail)' "$d/docs/configuration/main.md" ||
    fail "Delta unit links not rewritten"
  grep -q '^### Delta tail$' "$d/docs/configuration/delta-tail.md" || fail "tail h3 not in its own file"
  pass "fm-config-split.py --forkonly: moves fork-local units, keeps pointers and anchors, conserves text"
}

test_forkonly_rewrites_citations() {
  local d="$TMP_ROOT/cite"
  build_fixture "$d"
  out=$(split --forkonly --root "$d" 2>&1) || fail "forkonly failed: $out"
  assert_contains "$out" 'skipped docs/other.md: ambiguous name "Harbour"' "the skipped ambiguous name is listed"
  grep -qF 'docs/configuration/fork.md \"Beta (config/beta)\"' "$d/bin/tool2.sh" || fail "escaped quote cite not rewritten"
  grep -q 'docs/configuration/fork.md$' "$d/bin/tool2.sh" || fail "wrapped cite not rewritten"
  grep -qF "[\`docs/configuration/main.md\`](../docs/configuration/main.md) \"Delta (config/delta)\"" "$d/docs/other.md" ||
    fail "link text and href not rewritten together"
  grep -q '(configuration/fork.md#beta-configbeta)' "$d/docs/other.md" || fail "anchor link outside the doc not rewritten"
  grep -qF "docs/configuration.md\`'s \"Gamma\" section" "$d/docs/other.md" || fail "shared section cite changed"
  grep -q 'docs/configuration.md "Omega"' "$d/docs/other.md" || fail "shared Omega cite changed"
  grep -q 'docs/configuration.md "Harbour"' "$d/docs/other.md" || fail "ambiguous name was rewritten"
  grep -q 'docs/configuration/fork.md (Beta)' "$d/docs/other.md" || fail "parenthesised cite not rewritten"
  grep -q 'docs/configuration/fork.md "Beta (config/beta)"' "$d/docs/configuration/main.md" || fail "cite inside a moved unit not rewritten"
  grep -q 'docs/configuration/fork.md' "$d/AGENTS.md" && fail "AGENTS.md was rewritten"
  grep -q '"path": "docs/configuration/fork.md"' "$d/docs/documentation-audiences.json" || fail "inventory entry missing"
  python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$d/docs/documentation-audiences.json" || fail "inventory is not valid JSON"
  pass "fm-config-split.py --forkonly: rewrites citations and links outside AGENTS.md, skips ambiguous names"
}

test_rerun_is_a_noop() {
  local d="$TMP_ROOT/rerun"
  build_fixture "$d"
  split --forkonly --root "$d" >/dev/null || fail "forkonly failed"
  local before
  before=$(tree_digest "$d")
  out=$(split --forkonly --root "$d" 2>&1) || fail "second forkonly failed: $out"
  assert_contains "$out" "written=0" "second run writes nothing"
  assert_equals "$before" "$(tree_digest "$d")" "second run leaves a byte-identical tree"
  pass "fm-config-split.py --forkonly: re-running on a split tree is a no-op"
}

test_full_resplits_a_partly_split_tree() {
  local d="$TMP_ROOT/full"
  build_fixture "$d"
  split --forkonly --root "$d" >/dev/null || fail "forkonly failed"
  out=$(split --full --root "$d" 2>&1) || fail "full failed: $out"
  assert_contains "$out" "files=4" "shared and fork files all exist"
  for f in main tail fork delta-tail; do [ -f "$d/docs/configuration/$f.md" ] || fail "$f.md missing after full"; done
  grep -q '^## Configuration files$' "$d/docs/configuration.md" || fail "index table missing"
  ! grep -q '^## Alpha' "$d/docs/configuration.md" || fail "a shared section stayed in the index"
  grep -qE '^\| .*<a id="alpha-configalpha"></a>.*\[Main settings\]\(configuration/main\.md\)' "$d/docs/configuration.md" || fail "hidden anchors missing from the table row"
  split --check --anchors-of "$d/../orig-full.md" --root "$d" >/dev/null 2>&1 || fail "an old anchor no longer resolves after full"
  local before
  before=$(tree_digest "$d")
  split --full --root "$d" >/dev/null || fail "second full failed"
  assert_equals "$before" "$(tree_digest "$d")" "full is idempotent"
  out=$(split --forkonly --root "$d" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "forkonly accepted a fully split tree"
  assert_contains "$out" "--forkonly needs the pointer lines" "forkonly explains the refusal"
  pass "fm-config-split.py --full: re-splits a partly split tree and is idempotent"
}

test_real_tree_is_mapped() {
  out=$(split --check --root "$ROOT" 2>&1) || fail "the repository's own docs/configuration.md is not fully mapped: $out"
  assert_contains "$out" "unique=yes" "every anchor is unique"
  pass "fm-config-split.py --check: every h2 of the repository's configuration doc is assigned"
}

fm_test_run \
  test_check_and_unassigned \
  test_check_duplicates \
  test_forkonly_moves_and_conserves \
  test_forkonly_rewrites_citations \
  test_rerun_is_a_noop \
  test_full_resplits_a_partly_split_tree \
  test_real_tree_is_mapped
