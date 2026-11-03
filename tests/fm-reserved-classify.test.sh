#!/usr/bin/env bash
# Behavior tests for bin/fm-reserved-classify.sh, the path-rule admission
# classifier. Drives the executable on stdin and, for the contract with
# bin/fm-pr-merge.sh, through fm_admission_load and fm_admission_classify.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLASSIFY="$ROOT/bin/fm-reserved-classify.sh"
TMP_ROOT=$(fm_test_tmproot fm-reserved-classify)

RULES="$TMP_ROOT/firstmate.rules"
cat > "$RULES" <<'EOF'
# authority: an office never merges a change to its own authority
AGENTS.md authority
bin/fm-pr-merge.sh authority
bin/fm-office*.sh authority
bin/fm-officer*.{sh,py} authority
.agents/skills/{office-roles,officer-roles}/** authority
.github/workflows/** authority

deploy/*token* credentials
deploy/** production
**/secrets.env credentials
docs/v1.0/?.md authority
EOF

# run <rules> <paths...>: prints stdout; the exit status goes to $TMP_ROOT/rc,
# because callers capture the output in a subshell.
run() {
  local rules=$1 out rc
  shift
  out=$(printf '%s\n' "$@" | "$CLASSIFY" --rules "$rules" 2>"$TMP_ROOT/err")
  rc=$?
  printf '%s' "$rc" > "$TMP_ROOT/rc"
  printf '%s' "$out"
}

test_no_match_is_none() {
  local out
  out=$(run "$RULES" README.md src/app.ts)
  expect_code 0 "$(cat "$TMP_ROOT/rc")" "unmatched paths exit 0"
  assert_equals none "$out" "unmatched paths print none"
  out=$(printf '' | "$CLASSIFY" --rules "$RULES")
  assert_equals none "$out" "empty input prints none"
  pass "no matching rule prints none"
}

test_exact_and_wildcard_matches() {
  local out
  out=$(run "$RULES" AGENTS.md)
  assert_equals authority "$out" "exact path matches"
  out=$(run "$RULES" sub/AGENTS.md)
  assert_equals none "$out" "an exact glob does not match a nested copy"
  out=$(run "$RULES" bin/fm-office.sh bin/fm-office-authority-lib.sh)
  assert_equals authority "$out" "star matches inside a segment"
  out=$(run "$RULES" bin/fm-officer-surgeon.py)
  assert_equals authority "$out" "brace alternatives match"
  out=$(run "$RULES" bin/fm-officer.rb)
  assert_equals none "$out" "a brace alternative not listed does not match"
  pass "exact, star and brace globs"
}

test_double_star_and_slash_rules() {
  local out
  out=$(run "$RULES" .github/workflows/ci.yml .github/workflows/deep/x.yml)
  assert_equals authority "$out" "double star matches nested files"
  out=$(run "$RULES" .github/other.yml)
  assert_equals none "$out" "double star stays under its prefix"
  out=$(run "$RULES" secrets.env a/b/secrets.env)
  assert_equals credentials "$out" "leading **/ matches no directory and many"
  out=$(run "$RULES" bin/x/fm-pr-merge.sh)
  assert_equals none "$out" "star never crosses a slash"
  out=$(run "$RULES" docs/v1.0/a.md docs/v1x0/a.md docs/v1.0/ab.md)
  assert_equals authority "$out" "dot is literal and ? is one non-slash character"
  pass "double star, slash and literal-dot rules"
}

test_first_match_wins_and_output_is_sorted_unique() {
  local out
  out=$(run "$RULES" deploy/app-token.json)
  assert_equals credentials "$out" "the first matching rule wins over a later one"
  out=$(run "$RULES" deploy/app.service)
  assert_equals production "$out" "later rule applies when the earlier does not match"
  out=$(run "$RULES" deploy/a deploy/b deploy/x-token.sh AGENTS.md README.md)
  assert_equals $'authority\ncredentials\nproduction' "$out" "classes are sorted and unique, clear paths add nothing"
  pass "first match wins; output sorted and unique"
}

test_input_normalisation() {
  local out
  out=$(printf 'AGENTS.md' | "$CLASSIFY" --rules "$RULES")
  assert_equals authority "$out" "a last line without a newline is read"
  out=$(printf '\n\nAGENTS.md\n\n' | "$CLASSIFY" --rules "$RULES")
  assert_equals authority "$out" "blank lines are skipped"
  pass "input normalisation"
}

test_metacharacters_are_literal() {
  local rules="$TMP_ROOT/meta.rules" out
  printf 'a+b(c).txt authority\n' > "$rules"
  out=$(run "$rules" 'a+b(c).txt')
  assert_equals authority "$out" "regex metacharacters in a glob match themselves"
  out=$(run "$rules" 'aab(c)xtxt')
  assert_equals none "$out" "regex metacharacters do not act as operators"
  pass "regex metacharacters stay literal"
}

test_broken_rules_refuse() {
  local rules="$TMP_ROOT/bad.rules" out
  out=$(printf 'x\n' | "$CLASSIFY" --rules "$TMP_ROOT/missing.rules" 2>&1)
  expect_code 1 "$?" "missing rules file"
  assert_contains "$out" "missing or unreadable" "missing file is explained"
  local cases=(
    'onlyglob'
    'a b c'
    'a.txt none'
    'a.txt bad/class'
    'a.txt .hidden'
    'a{b,c.txt authority'
    'a}b.txt authority'
  )
  local line
  for line in "${cases[@]}"; do
    printf 'ok.txt fine\n%s\n' "$line" > "$rules"
    out=$(printf 'ok.txt\n' | "$CLASSIFY" --rules "$rules" 2>"$TMP_ROOT/err")
    expect_code 1 "$?" "rejects: $line"
    assert_equals '' "$out" "prints nothing on a bad rules file: $line"
    assert_contains "$(cat "$TMP_ROOT/err")" "$rules line 2" "names the bad line: $line"
  done
  : > "$rules"
  out=$(printf 'ok.txt\n' | "$CLASSIFY" --rules "$rules")
  assert_equals none "$out" "an empty rules file flags nothing"
  pass "broken rules files refuse"
}

test_usage_errors() {
  "$CLASSIFY" </dev/null >/dev/null 2>&1
  expect_code 1 "$?" "no --rules"
  "$CLASSIFY" --rules </dev/null >/dev/null 2>&1
  expect_code 1 "$?" "--rules without a file"
  "$CLASSIFY" --bogus </dev/null >/dev/null 2>&1
  expect_code 1 "$?" "unknown argument"
  "$CLASSIFY" --help | grep -q 'Usage: fm-reserved-classify.sh --rules' || fail "help prints usage"
  pass "usage errors and help"
}

test_meets_the_admission_contract() {
  local home="$TMP_ROOT/home" cfg paths
  mkdir -p "$home/config/admission" "$home/project"
  cfg="$home/config/admission/firstmate"
  cat > "$cfg" <<EOF
command=$CLASSIFY --rules $RULES
classes=authority credentials production
clear=none
EOF
  # shellcheck source=bin/fm-admission-lib.sh
  . "$ROOT/bin/fm-admission-lib.sh"
  fm_admission_load "$cfg" || fail "admission config loads: $FM_ADMISSION_ERROR"
  paths="$TMP_ROOT/paths"
  printf 'README.md\n' > "$paths"
  fm_admission_classify "$home/project" "$paths" || fail "clear diff classifies: $FM_ADMISSION_ERROR"
  assert_equals '' "$FM_ADMISSION_FLAGGED" "a clear diff flags no class"
  printf 'README.md\nAGENTS.md\ndeploy/app.service\n' > "$paths"
  fm_admission_classify "$home/project" "$paths" || fail "flagged diff classifies: $FM_ADMISSION_ERROR"
  assert_equals $'authority\nproduction' "$FM_ADMISSION_FLAGGED" "flagged classes reach the admission library"
  printf '%s\n' "x.txt undeclared" > "$TMP_ROOT/undeclared.rules"
  sed -i.bak "s|$RULES|$TMP_ROOT/undeclared.rules|" "$cfg" && rm -f "$cfg.bak"
  fm_admission_load "$cfg" || fail "second config loads"
  printf 'x.txt\n' > "$paths"
  if fm_admission_classify "$home/project" "$paths"; then
    fail "a class missing from classes= and clear= must refuse"
  fi
  assert_contains "$FM_ADMISSION_ERROR" "undeclared" "undeclared verdict is named"
  pass "meets the admission classifier contract"
}

test_no_match_is_none
test_exact_and_wildcard_matches
test_double_star_and_slash_rules
test_first_match_wins_and_output_is_sorted_unique
test_input_normalisation
test_metacharacters_are_literal
test_broken_rules_refuse
test_usage_errors
test_meets_the_admission_contract
