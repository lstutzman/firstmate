#!/usr/bin/env bash
# Behavior tests for the secret scan: bin/fm-secret-scan.sh with the reviewed
# allowlist in .gitleaks.toml, its pre-push hook (installed through
# bin/fm-git-strip-ai-trailers.sh --secret-scan, the way bin/fm-spawn.sh does),
# the hook wiring bin/fm-spawn.sh does for a firstmate-shaped worktree, the
# evidence URL check bin/fm-evidence-secrets.sh, and the daily evidence-branch
# scan bin/fm-evidence-branch-scan.sh. Every case runs real gitleaks and real
# git against throwaway repositories. Fake secrets are built
# at run time so this file never carries a literal the scan itself would flag.
# gitleaks is required: an absent or too old gitleaks fails the suite, the same
# way the scan refuses to pass without it.
set -u

# A fleet pane already carries GIT_CONFIG core.hooksPath. These cases set that
# override themselves, so drop the inherited one before any git command.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SCAN="$ROOT/bin/fm-secret-scan.sh"
EVIDENCE="$ROOT/bin/fm-evidence-secrets.sh"
STRIP="$ROOT/bin/fm-git-strip-ai-trailers.sh"
BRANCH_SCAN="$ROOT/bin/fm-evidence-branch-scan.sh"
TMP_ROOT=$(fm_test_tmproot fm-secret-scan)
fm_git_identity fmtest fmtest@example.invalid
ZERO=0000000000000000000000000000000000000000

command -v gitleaks >/dev/null 2>&1 || fail "gitleaks is required (bin/fm-install-gitleaks.sh <destination-directory>)"

# random_secret: a fixed 40 character mixed-case value with no hyphen, the shape
# of a real provider key and never a decision slug. It is assembled from
# fragments so this file carries no literal the scan would flag. It is fixed on
# purpose: a randomly generated value is sometimes dropped by gitleaks' stopword
# filter (1 in 40 draws measured), which made the cases flaky. The helper keeps
# its old name so the call sites read as "a key-shaped secret".
random_secret() {
  printf '%s%s%s%s%s\n' Zk8Qw3Lm Xp7Rt2Vb Nc5Hy9Fd Js4Ga6Eu Mo1Ti0Wl
}

# canary_value: the reviewed canary .gitleaks.toml allowlists for
# tests/fm-officer-progress.test.sh, assembled from fragments so this file does
# not itself carry the literal (the scan would refuse it here: the allowlist is
# bound to that other file's path).
canary_value() {
  printf '%s%s%s\n' FIXTURESECRET 0123456789 abcdefghijklmnopqrstuv
}

# new_repo <name>: an empty repository with one initial commit, path in REPO.
new_repo() {
  REPO="$TMP_ROOT/$1"
  git init -q "$REPO"
  git -C "$REPO" commit -q --allow-empty -m 'initial'
}

# commit_file <path> <content-line> <message>: add one line to a file in REPO.
commit_file() {
  mkdir -p "$REPO/$(dirname "$1")"
  printf '%s\n' "$2" >>"$REPO/$1"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "$3"
}

# scan_range <repo> <range>: run the scan; sets OUT and RC.
scan_range() {
  OUT=$("$SCAN" --repo "$1" --range "$2" 2>&1)
  RC=$?
}

test_decision_keys_and_canaries_pass() {
  local base cfg
  new_repo decision
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_file docs/notes.md 'blocked on key=merge-handoff-9 until Lee answers' 'decision key in prose'
  commit_file state.json '{"key": "surgeon-holds-2026-10-23", "n": 1}' 'decision key in json'
  commit_file tests/fm-officer-progress.test.sh "FIXTURE_TOKEN=\"$(canary_value)\"" 'reviewed canary in its own test file'
  scan_range "$REPO" "$base..HEAD"
  expect_code 0 "$RC" "decision slugs and the reviewed canary must pass the scan: $OUT"
  # The same lines are findings under gitleaks' default rules alone, so the
  # allowlist, not a blind spot, is what lets them pass.
  cfg="$TMP_ROOT/default-only.toml"
  printf '[extend]\nuseDefault = true\n' >"$cfg"
  OUT=$("$SCAN" --repo "$REPO" --config "$cfg" --range "$base..HEAD" 2>&1)
  RC=$?
  expect_code 1 "$RC" "without the allowlist the same lines must be findings (the case would be vacuous otherwise)"
  pass "secret scan: decision-key slugs and a reviewed canary pass; the default rules alone flag them"
}

test_real_looking_key_still_fails() {
  local base secret
  new_repo realkey
  base=$(git -C "$REPO" rev-parse HEAD)
  secret=$(random_secret)
  commit_file config/service.env "SERVICE_API_KEY=\"$secret\"" 'add a service key'
  scan_range "$REPO" "$base..HEAD"
  expect_code 1 "$RC" "a real-looking key must fail the scan: $OUT"
  assert_contains "$OUT" "refused" "the refusal must say so"
  assert_contains "$OUT" "config/service.env" "the finding must name the file"
  assert_not_contains "$OUT" "$secret" "the secret value must never be printed"
  pass "secret scan: a real-looking key fails, names its file and is never printed"
}

test_allowlist_cannot_hide_a_key_in_a_decision_slug_shape() {
  local base secret
  new_repo slugs
  base=$(git -C "$REPO" rev-parse HEAD)
  secret=$(random_secret)
  # Mixed case and no hyphen is not a decision slug even in key= position.
  commit_file notes.txt "key=$secret" 'key= with a real-looking value'
  scan_range "$REPO" "$base..HEAD"
  expect_code 1 "$RC" "key=<real-looking value> must still fail: $OUT"
  assert_not_contains "$OUT" "$secret" "the secret value must never be printed"
  # A reviewed canary string is allowed only in the test file that plants it.
  new_repo canary-path
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_file tests/other.test.sh "FIXTURE_TOKEN=\"$(canary_value)\"" 'canary in another file'
  scan_range "$REPO" "$base..HEAD"
  expect_code 1 "$RC" "a reviewed canary in a different file must still fail: $OUT"
  pass "secret scan: the allowlist covers decision slugs and named canaries only, by shape and path"
}

test_lavish_token_is_allowlisted_by_commit_and_path_only() {
  local base evidence_path token commit
  evidence_path=.no-mistakes/evidence/fm/fm-crew-hosted-lavish-shipB-r1/browser-after-round1.txt
  # The same file at a new commit is a finding: the entry names one commit.
  new_repo lavish-new
  base=$(git -C "$REPO" rev-parse HEAD)
  token=$(random_secret)
  commit_file "$evidence_path" "board url https://example.invalid/board?artifact_load_token=$token" 'same path, new commit'
  scan_range "$REPO" "$base..HEAD"
  expect_code 1 "$RC" "the Lavish path at any other commit must fail: $OUT"
  assert_not_contains "$OUT" "$token" "the token value must never be printed"
  # In the real history the one allowlisted commit passes (skipped where a
  # shallow checkout does not carry it).
  commit=4d572468c20199c54eba9236591d09603183306e
  if git -C "$ROOT" cat-file -e "$commit^{commit}" 2>/dev/null; then
    scan_range "$ROOT" "$commit^..$commit"
    expect_code 0 "$RC" "the allowlisted historical commit must pass: $OUT"
    pass "secret scan: the historical Lavish token passes only at its own commit and path; a new commit fails"
  else
    pass "secret scan: a new commit of the Lavish path fails (historical commit absent in this checkout, positive half skipped)"
  fi
}

test_ci_modes_scan_only_what_the_event_adds() {
  local old_secret base mid
  new_repo ci-modes
  old_secret=$(random_secret)
  commit_file old.env "OLD_API_KEY=\"$old_secret\"" 'old history with a key'
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_file clean.txt 'nothing here' 'a clean change'
  scan_range "$REPO" "$base..HEAD"
  expect_code 0 "$RC" "history before the base must not be re-scanned: $OUT"
  # A push event: before..after, and the all-zero before falls back to the tip commit.
  OUT=$("$SCAN" --repo "$REPO" --push-range "$base" HEAD 2>&1)
  expect_code 0 "$?" "a push range over a clean commit must pass: $OUT"
  OUT=$("$SCAN" --repo "$REPO" --push-range "$ZERO" HEAD 2>&1)
  expect_code 0 "$?" "a new-branch push scans only the tip commit: $OUT"
  mid=$(random_secret)
  commit_file added.env "ADDED_API_KEY=\"$mid\"" 'a key added mid-range'
  commit_file later.txt 'removed nothing' 'a later clean commit'
  scan_range "$REPO" "$base..HEAD"
  expect_code 1 "$RC" "a key in a middle commit of the range must fail even though the tip is clean: $OUT"
  OUT=$("$SCAN" --repo "$REPO" --push-range "$base" HEAD 2>&1)
  expect_code 1 "$?" "the push-range mode must fail on the same range: $OUT"
  pass "secret scan: --range and --push-range scan only the commits an event adds, in every commit of the range"
}

install_hooks() { # <hooks-dir> <worktree> <flags...>
  local dir=$1 wt=$2
  shift 2
  "$STRIP" install "$@" "$dir" "$wt" || fail "hook install failed"
}

# hook_fixture <name>: a repository with a bare origin and a task worktree on
# fm/t1, hooks installed with --secret-scan. Sets FX_WT, FX_ORIGIN, FX_HOOKS.
hook_fixture() {
  local dir="$TMP_ROOT/$1"
  fm_git_worktree "$dir/repo" "$dir/wt" fm/t1
  FX_WT="$dir/wt"
  FX_ORIGIN="$dir/repo.origin.git"
  FX_HOOKS="$dir/hooks"
  install_hooks "$FX_HOOKS" "$FX_WT" --secret-scan
}

# push_with_hooks <ref-spec> [remote]: push from FX_WT with the hooks active.
push_with_hooks() {
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$FX_HOOKS \
    git -C "$FX_WT" push "${2:-origin}" "$1" 2>&1
}

test_pre_push_refuses_a_secret_and_never_prints_it() {
  local out rc secret
  hook_fixture pre-push
  git -C "$FX_WT" commit -q --allow-empty -m 'a clean change'
  out=$(push_with_hooks fm/t1)
  rc=$?
  expect_code 0 "$rc" "a clean push must go through: $out"
  git -C "$FX_ORIGIN" rev-parse --verify -q refs/heads/fm/t1 >/dev/null || fail "the clean push did not reach origin"

  secret=$(random_secret)
  printf 'DEPLOY_API_KEY="%s"\n' "$secret" >"$FX_WT/deploy.env"
  git -C "$FX_WT" add deploy.env
  git -C "$FX_WT" commit -q -m 'add a deploy key'
  # A later commit removes it: the secret is still in history and still refused.
  git -C "$FX_WT" rm -q deploy.env
  git -C "$FX_WT" commit -q -m 'remove the deploy key again'
  out=$(push_with_hooks fm/t1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a push carrying a secret in an earlier commit must be refused"
  assert_contains "$out" "fm-secret-scan: refused" "the refusal must name the scan"
  assert_contains "$out" "deploy.env" "the refusal must name the file"
  assert_not_contains "$out" "$secret" "the secret value must never be printed by the hook"
  [ "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/t1)" != "$(git -C "$FX_WT" rev-parse HEAD)" ] \
    || fail "the refused push still moved origin"
  pass "pre-push hook: a secret in any pushed commit refuses the push, names the file and prints no value"
}

test_pre_push_allows_deletes_and_chains_the_repository_hook() {
  local out rc marker hooks_dir
  hook_fixture chain
  git -C "$FX_WT" commit -q --allow-empty -m 'a clean change'
  push_with_hooks fm/t1 >/dev/null || fail "setup push failed"
  out=$(push_with_hooks ":refs/heads/fm/t1")
  rc=$?
  expect_code 0 "$rc" "deleting a remote branch pushes no commits and must pass: $out"

  # The repository's own pre-push hook still runs after the scan passes, gets
  # git's ref lines, and still blocks.
  hooks_dir=$(git -C "$FX_WT" rev-parse --path-format=absolute --git-path hooks)
  mkdir -p "$hooks_dir"
  marker="$TMP_ROOT/chain.marker"
  rm -f "$marker"
  printf '#!/usr/bin/env bash\ncat >"%s"\n' "$marker" >"$hooks_dir/pre-push"
  chmod +x "$hooks_dir/pre-push"
  git -C "$FX_WT" commit -q --allow-empty -m 'another clean change'
  out=$(push_with_hooks fm/t1)
  rc=$?
  expect_code 0 "$rc" "a clean push with a repository hook must pass: $out"
  [ -e "$marker" ] || fail "the repository's own pre-push hook did not run after the scan passed"
  assert_contains "$(cat "$marker")" "refs/heads/fm/t1" "the repository pre-push hook did not receive git's ref lines"
  pass "pre-push hook: deletes pass and the repository's own pre-push hook still runs"
}

test_pre_push_runs_beside_the_push_guard() {
  local dir out rc secret guard
  dir="$TMP_ROOT/both"
  fm_git_worktree "$dir/repo" "$dir/wt" fm/t1
  FX_WT="$dir/wt"
  FX_ORIGIN="$dir/repo.origin.git"
  FX_HOOKS="$dir/hooks"
  guard="$dir/guard"
  "$ROOT/bin/fm-git-push-guard.sh" write "$guard" "$FX_WT" fm/t1 fm/ || fail "guard write failed"
  install_hooks "$FX_HOOKS" "$FX_WT" --push-guard "$guard" --secret-scan
  git -C "$FX_WT" remote add other "file://$dir/other.git"
  git init -q --bare "$dir/other.git"
  # Guard passes nothing to origin; a clean push to the other remote is refused
  # by the guard's task-branch rule, so use a non-task ref for the scan case.
  secret=$(random_secret)
  printf 'DEPLOY_API_KEY="%s"\n' "$secret" >"$FX_WT/deploy.env"
  git -C "$FX_WT" add deploy.env
  git -C "$FX_WT" commit -q -m 'add a deploy key'
  out=$(push_with_hooks HEAD:refs/heads/side other)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the scan must refuse a secret pushed to a remote the guard allows"
  assert_contains "$out" "fm-secret-scan: refused" "the scan refusal must show beside the guard"
  assert_not_contains "$out" "$secret" "the secret value must never be printed"
  out=$(push_with_hooks fm/t1 origin)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the guard must still refuse an origin push"
  assert_contains "$out" "fm-git-push-guard: refused" "the guard refusal must still show"
  pass "pre-push hook: the secret scan and the forge=external push guard both run"
}

# spawn_case <name> <firstmate-shaped: 1|0> <keep-ai-trailers: 1|0>: spawn a
# claude ship task through the real bin/fm-spawn.sh into a fresh worktree with
# a bare origin. A firstmate-shaped project carries this repository's
# .gitleaks.toml and bin/fm-secret-scan.sh on its default branch, since spawn
# starts the task from origin's base. Sets FX_WT, FX_ORIGIN, FX_HOOKS.
spawn_case() {
  local name=$1 shaped=$2 keep=$3 dir home id fakebin out
  dir="$TMP_ROOT/spawn-$name"
  home="$dir/home"
  id="secret-scan-$name"
  fm_test_spawn_home "$home" claude
  fm_git_init_commit "$dir/repo"
  if [ "$shaped" = 1 ]; then
    mkdir -p "$dir/repo/bin"
    cp "$ROOT/.gitleaks.toml" "$dir/repo/.gitleaks.toml"
    cp "$SCAN" "$dir/repo/bin/fm-secret-scan.sh"
    git -C "$dir/repo" add -A
    git -C "$dir/repo" commit -q -m 'carry the secret scan'
  fi
  fm_git_add_origin "$dir/repo" "$dir/repo.origin.git"
  git -C "$dir/repo" worktree add --quiet -b "fm/$id" "$dir/wt"
  [ "$keep" = 0 ] || : >"$home/config/keep-ai-trailers"
  fm_test_spawn_brief "$home" "$id"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  out=$(fm_test_run_spawn "$home" "$dir/wt" "$fakebin" "$id" "$dir/repo" --mode no-mistakes --yolo off) \
    || fail "spawn $name failed: $out"
  FX_WT="$dir/wt"
  FX_ORIGIN="$dir/repo.origin.git"
  FX_HOOKS="$(cd "$home/state" && pwd -P)/$id.git-hooks"
}

# assert_spawned_hook_refuses_a_secret <label>: commit a key-shaped secret in
# FX_WT and push it through FX_HOOKS; the push must be refused by the scan.
assert_spawned_hook_refuses_a_secret() {
  local label=$1 out rc secret
  [ -x "$FX_HOOKS/pre-push" ] || fail "$label: spawn installed no pre-push hook"
  secret=$(random_secret)
  printf 'DEPLOY_API_KEY="%s"\n' "$secret" >"$FX_WT/deploy.env"
  git -C "$FX_WT" add deploy.env
  git -C "$FX_WT" commit -q -m 'add a deploy key'
  out=$(push_with_hooks HEAD)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$label: the spawned pre-push hook let a secret through"
  assert_contains "$out" "fm-secret-scan: refused" "$label: the refusal must come from the secret scan"
  assert_not_contains "$out" "$secret" "$label: the secret value must never be printed"
  ! git -C "$FX_ORIGIN" rev-parse --verify -q "refs/heads/$(git -C "$FX_WT" branch --show-current)" >/dev/null \
    || fail "$label: the refused push still reached origin"
}

test_spawn_installs_the_scan_hook_in_a_firstmate_worktree() {
  spawn_case shaped 1 0
  assert_spawned_hook_refuses_a_secret "default config"
  spawn_case shaped-keep 1 1
  assert_spawned_hook_refuses_a_secret "keep-ai-trailers"
  spawn_case plain-keep 0 1
  [ ! -e "$FX_HOOKS" ] || fail "a worktree without the secret scan that keeps trailers must still get no hooks directory"
  pass "fm-spawn: a firstmate worktree gets a pre-push hook that refuses a secret, with or without keep-ai-trailers; other worktrees that keep trailers get none"
}

# evidence_repo <name>: a repository whose origin-tracking ref
# refs/remotes/origin/no-mistakes/evidence points at an orphan evidence branch
# with one old commit (ten days ago) carrying both a key-shaped secret and a
# token URL. Sets REPO and EV_TOKEN; the evidence worktree is REPO itself.
evidence_repo() {
  local old
  new_repo "$1"
  EV_TOKEN=$(random_secret)
  git -C "$REPO" checkout -q --orphan no-mistakes/evidence
  git -C "$REPO" rm -q -rf --cached . >/dev/null 2>&1
  mkdir -p "$REPO/fm/old"
  printf 'OLD_API_KEY="%s"\n' "$EV_TOKEN" >"$REPO/fm/old/run.env"
  printf 'opened https://board.example.invalid/b?artifact_load_token=%s\n' "$EV_TOKEN" >"$REPO/fm/old/capture.txt"
  git -C "$REPO" add -A
  old="@$(($(date +%s) - 10 * 86400)) +0000"
  GIT_COMMITTER_DATE=$old GIT_AUTHOR_DATE=$old git -C "$REPO" commit -q -m 'old evidence'
  git -C "$REPO" update-ref refs/remotes/origin/no-mistakes/evidence HEAD
}

# evidence_commit <path> <line>: add a recent evidence commit and move the
# origin-tracking ref to it.
evidence_commit() {
  mkdir -p "$REPO/$(dirname "$1")"
  printf '%s\n' "$2" >"$REPO/$1"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m 'recent evidence'
  git -C "$REPO" update-ref refs/remotes/origin/no-mistakes/evidence HEAD
}

test_evidence_branch_scan_skips_a_repository_without_the_branch() {
  local fake out rc
  new_repo no-evidence
  # A gitleaks the scan would refuse proves the skip never reaches the scan.
  fake="$TMP_ROOT/old-gitleaks"
  mkdir -p "$fake"
  printf '#!/bin/sh\necho 8.0.1\n' >"$fake/gitleaks"
  chmod +x "$fake/gitleaks"
  out=$(PATH="$fake:$PATH" "$BRANCH_SCAN" --repo "$REPO" 2>&1)
  rc=$?
  expect_code 0 "$rc" "a repository without the evidence branch must pass: $out"
  assert_contains "$out" "No no-mistakes/evidence branch" "the skip must say why"
  pass "evidence branch scan: a repository without the evidence branch passes with a notice and runs no scan"
}

test_evidence_branch_scan_reads_only_the_last_two_days() {
  local out rc path
  evidence_repo evidence-window
  evidence_commit fm/new/log.txt 'nothing secret here'
  out=$("$BRANCH_SCAN" --repo "$REPO" 2>&1)
  rc=$?
  expect_code 0 "$rc" "a secret and a token URL older than two days must not be re-scanned: $out"

  # A token URL in a recent capture whose path is quoted by git (non-ASCII and
  # a space) is still read and found.
  path='fm/café run/capture.txt'
  evidence_commit "$path" "opened https://board.example.invalid/b?artifact_load_token=$EV_TOKEN&round=2"
  out=$("$BRANCH_SCAN" --repo "$REPO" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a recent token URL must fail the scan: $out"
  assert_contains "$out" "café run/capture.txt:1: artifact_load_token" "the URL check must name the quoted path, line and parameter"
  assert_not_contains "$out" "fm/old/capture.txt" "an evidence file not touched in the last two days must not be checked"
  assert_not_contains "$out" "$EV_TOKEN" "no value may be printed"
  pass "evidence branch scan: only the last two days are scanned, and a quoted non-ASCII path is still checked"
}

test_evidence_branch_scan_runs_the_secret_scan() {
  local out rc secret
  evidence_repo evidence-secret
  secret=$(random_secret)
  evidence_commit fm/new/run.env "DEPLOY_API_KEY=\"${secret}X\""
  out=$("$BRANCH_SCAN" --repo "$REPO" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a recent key-shaped secret must fail the scan: $out"
  assert_contains "$out" "fm-secret-scan: refused" "the refusal must come from the secret scan"
  assert_contains "$out" "fm/new/run.env" "the finding must name the file"
  assert_not_contains "$out" "fm/old/run.env" "a secret older than two days must not be re-scanned"
  assert_not_contains "$out" "$secret" "no value may be printed"
  pass "evidence branch scan: a recent secret on the evidence branch fails the secret scan"
}

test_scan_cannot_pass_without_a_usable_gitleaks() {
  local out rc fake
  new_repo no-tool
  # No gitleaks on PATH at all: refuse, naming the installer.
  out=$(PATH=/nonexistent /bin/bash "$SCAN" --repo "$REPO" --branch 2>&1)
  rc=$?
  expect_code 2 "$rc" "a missing gitleaks must refuse, not pass: $out"
  assert_contains "$out" "fm-install-gitleaks.sh" "the refusal must name the installer"
  # An older gitleaks than the pin: refuse as well.
  fake="$TMP_ROOT/fake-bin"
  mkdir -p "$fake"
  printf '#!/bin/sh\necho 8.0.1\n' >"$fake/gitleaks"
  chmod +x "$fake/gitleaks"
  out=$(PATH="$fake:$PATH" "$SCAN" --repo "$REPO" --branch 2>&1)
  rc=$?
  expect_code 2 "$rc" "an older gitleaks must refuse: $out"
  assert_contains "$out" "older than the required" "the refusal must say the version is too old"
  [ "$("$SCAN" --required-version)" = "$(gitleaks version | tr -d '[:space:]v')" ] \
    || [ "$(printf '%s\n%s\n' "$("$SCAN" --required-version)" "$(gitleaks version | tr -d '[:space:]v')" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$("$SCAN" --required-version)" ] \
    || fail "the installed gitleaks is older than the pin"
  pass "secret scan: a missing or too old gitleaks refuses (exit 2) and never passes"
}

test_evidence_urls_are_found_and_redacted_without_printing_values() {
  local dir out rc token
  dir="$TMP_ROOT/evidence"
  mkdir -p "$dir/nested"
  token=$(random_secret)
  printf 'opened https://board.example.invalid/b?artifact_load_token=%s&round=1&api_key=%s\n' "$token" "$token" >"$dir/capture.txt"
  printf 'page https://example.invalid/p?page=2&sort=asc and https://example.invalid/?sig=%s#frag\n' "$token" >"$dir/nested/page.log"
  printf 'already https://example.invalid/?token=REDACTED and plain token=%s\n' "$token" >"$dir/clean.txt"
  printf '\211PNG\r\n\032\n\000\000\000\rIHDR\000\000 https://example.invalid/?token=%s\n' "$token" >"$dir/shot.png"
  chmod 640 "$dir/capture.txt"

  out=$("$EVIDENCE" check "$dir" 2>&1)
  rc=$?
  expect_code 1 "$rc" "check must fail on secret-bearing URLs: $out"
  assert_contains "$out" "capture.txt:1: artifact_load_token" "check must name the file, line and parameter"
  assert_contains "$out" "capture.txt:1: api_key" "check must name every parameter on the line"
  assert_contains "$out" "page.log:1: sig" "check must find a parameter before a fragment"
  assert_not_contains "$out" "$token" "check must never print a value"
  assert_not_contains "$out" "clean.txt" "an already redacted URL and a bare token= outside a URL are not findings"
  assert_not_contains "$out" "shot.png" "a binary capture is skipped"

  out=$("$EVIDENCE" redact "$dir" 2>&1)
  rc=$?
  expect_code 0 "$rc" "redact must succeed: $out"
  assert_contains "$out" "redacted 3" "redact must count what it rewrote"
  assert_contains "$(cat "$dir/capture.txt")" "artifact_load_token=REDACTED&round=1&api_key=REDACTED" "redact must keep the rest of the URL"
  assert_not_contains "$(cat "$dir/capture.txt" "$dir/nested/page.log")" "$token" "no value may remain after redact"
  assert_contains "$(cat "$dir/nested/page.log")" "sig=REDACTED#frag" "redact must keep the fragment"
  assert_contains "$(cat "$dir/nested/page.log")" "page=2&sort=asc" "redact must leave harmless parameters"
  [ "$(stat -c %a "$dir/capture.txt" 2>/dev/null || stat -f %Lp "$dir/capture.txt")" = 640 ] || fail "redact must keep the file mode"
  "$EVIDENCE" check "$dir" >/dev/null 2>&1 || fail "check must pass after redact"
  pass "evidence check: finds token-like URL parameters, never prints values, and redact leaves the rest intact"
}

test_code_branches_carry_no_evidence() {
  [ -z "$(git -C "$ROOT" ls-files -- .no-mistakes)" ] || fail "evidence must not be tracked on a code branch"
  git -C "$ROOT" check-ignore -q .no-mistakes/evidence/fm/x/browser-after.txt \
    || fail ".no-mistakes/evidence must be gitignored so captures never reach a code branch"
  pass "evidence: nothing under .no-mistakes is tracked and the evidence path is gitignored"
}

fm_test_run \
  test_decision_keys_and_canaries_pass \
  test_real_looking_key_still_fails \
  test_allowlist_cannot_hide_a_key_in_a_decision_slug_shape \
  test_lavish_token_is_allowlisted_by_commit_and_path_only \
  test_ci_modes_scan_only_what_the_event_adds \
  test_pre_push_refuses_a_secret_and_never_prints_it \
  test_pre_push_allows_deletes_and_chains_the_repository_hook \
  test_pre_push_runs_beside_the_push_guard \
  test_spawn_installs_the_scan_hook_in_a_firstmate_worktree \
  test_scan_cannot_pass_without_a_usable_gitleaks \
  test_evidence_urls_are_found_and_redacted_without_printing_values \
  test_evidence_branch_scan_skips_a_repository_without_the_branch \
  test_evidence_branch_scan_reads_only_the_last_two_days \
  test_evidence_branch_scan_runs_the_secret_scan \
  test_code_branches_carry_no_evidence
