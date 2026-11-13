#!/usr/bin/env bash
# Behavior tests for the registry hooks= token and bin/fm-project-hooks.sh: a
# scratch repo with a tracked hook installer and the token. Project init makes
# the hooks live, fleet sync repairs an inert clone and is silent on a live one,
# the session-start diagnostic fires on an inert clone only, a project with no
# token is untouched, and every check ignores the GIT_CONFIG_* override that a
# firstmate-launched session injects for its per-task hooks directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-project-hooks-tests)
INSTALLER=scripts/install-git-hooks.sh

# new_home <project-registry-annotation>: isolated FM_HOME with projects "hooked"
# (carrying the annotation) and "plain" (no token), both clones of a scratch repo
# whose tracked installer only sets core.hooksPath.
new_home() {
  local h name work
  h=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  mkdir -p "$h/projects" "$h/data"
  for name in hooked plain; do
    work="$h/work-$name"
    git init -q "$work"
    git -C "$work" symbolic-ref HEAD refs/heads/main
    mkdir -p "$work/scripts/git-hooks"
    printf '#!/usr/bin/env bash\ngit config core.hooksPath scripts/git-hooks\n' > "$work/$INSTALLER"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$work/scripts/git-hooks/pre-commit"
    git -C "$work" add -A
    git -C "$work" commit -qm c0
    git clone -q "$work" "$h/projects/$name"
  done
  {
    printf -- '- hooked [no-mistakes %s] - hooked project (added 2026-11-13)\n' "$1"
    printf -- '- plain [no-mistakes] - plain project (added 2026-11-13)\n'
  } > "$h/data/projects.md"
  printf '%s\n' "$h"
}

hooks() {  # <home> args...
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-project-hooks.sh" "$@"
}

local_hooks_path() { git -C "$1" config --local --get core.hooksPath 2>/dev/null || true; }

test_mode_reads_hooks_token_and_refuses_malformed() {
  local h out rc
  h=$(new_home "hooks=$INSTALLER")
  out=$(FM_HOME="$h" "$ROOT/bin/fm-project-mode.sh" --hooks hooked) || fail "--hooks failed on a valid token"
  [ "$out" = "$INSTALLER" ] || fail "--hooks printed '$out'"
  out=$(FM_HOME="$h" "$ROOT/bin/fm-project-mode.sh" --hooks plain)
  [ -z "$out" ] || fail "--hooks printed '$out' for a project with no token"
  out=$(FM_HOME="$h" "$ROOT/bin/fm-project-mode.sh" hooked)
  [ "$out" = "no-mistakes off" ] || fail "hooks token changed the posture: '$out'"
  for bad in 'hooks=' 'hooks=/etc/x.sh' 'hooks=../x.sh' 'hooks=a/../x.sh' 'hooks=a;b'; do
    h=$(new_home "$bad")
    FM_HOME="$h" "$ROOT/bin/fm-project-mode.sh" --hooks hooked >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 3 ] || fail "malformed '$bad' exited $rc, wanted 3"
  done
  pass "the hooks= token is read back, leaves posture alone, and malformed values are refused"
}

test_ensure_makes_hooks_live() {
  local h out
  h=$(new_home "hooks=$INSTALLER")
  [ -z "$(local_hooks_path "$h/projects/hooked")" ] || fail "fixture clone starts with hooks set"
  out=$(hooks "$h" ensure projects/hooked) || fail "ensure failed: $out"
  case "$out" in *"hooked: hooks: repaired"*) ;; *) fail "no repaired line: $out" ;; esac
  [ "$(hooks "$h" status hooked)" = live ] || fail "hooks are not live after init"
  [ "$(local_hooks_path "$h/projects/hooked")" = scripts/git-hooks ] || fail "core.hooksPath not set in the clone"
  out=$(hooks "$h" ensure hooked)
  [ -z "$out" ] || fail "second ensure was not a silent no-op: $out"
  pass "ensure makes declared hooks live and is a no-op once live"
}

test_injected_git_config_does_not_hide_an_inert_clone() {
  local h out
  h=$(new_home "hooks=$INSTALLER")
  mkdir -p "$TMP_ROOT/injected-hooks"
  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$TMP_ROOT/injected-hooks" \
    GIT_CONFIG_PARAMETERS="'core.hooksPath=$TMP_ROOT/injected-hooks'" hooks "$h" status hooked)
  [ "$out" = inert ] || fail "injected override made an inert clone read '$out'"
  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$TMP_ROOT/injected-hooks" \
    GIT_CONFIG_PARAMETERS="'core.hooksPath=$TMP_ROOT/injected-hooks'" hooks "$h" diagnose)
  case "$out" in *"HOOKS_INERT: hooked:"*) ;; *) fail "diagnose missed the inert clone under an injected override: $out" ;; esac
  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$TMP_ROOT/injected-hooks" \
    GIT_CONFIG_PARAMETERS="'core.hooksPath=$TMP_ROOT/injected-hooks'" hooks "$h" ensure hooked)
  case "$out" in *"repaired"*) ;; *) fail "ensure skipped the repair under an injected override: $out" ;; esac
  [ "$(local_hooks_path "$h/projects/hooked")" = scripts/git-hooks ] || fail "repair wrote the injected value, not the installer's"
  pass "an injected GIT_CONFIG override neither hides an inert clone nor leaks into the repair"
}

test_fleet_sync_repairs_inert_and_is_silent_on_live() {
  local h out
  h=$(new_home "hooks=$INSTALLER")
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" 2>/dev/null)
  case "$out" in *"hooked: hooks: repaired"*) ;; *) fail "fleet sync did not repair the inert clone: $out" ;; esac
  [ "$(hooks "$h" status hooked)" = live ] || fail "clone not live after fleet sync"
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" 2>/dev/null)
  case "$out" in *"hooks:"*) fail "fleet sync spoke about hooks on a live clone: $out" ;; esac
  pass "fleet sync repairs an inert clone once and says nothing about a live one"
}

test_project_without_token_is_untouched() {
  local h out
  h=$(new_home "hooks=$INSTALLER")
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" >/dev/null 2>&1
  [ -z "$(local_hooks_path "$h/projects/plain")" ] || fail "fleet sync touched a project with no token"
  [ "$(hooks "$h" status plain)" = none ] || fail "status for a project with no token"
  out=$(hooks "$h" ensure plain)
  [ -z "$out" ] && [ -z "$(local_hooks_path "$h/projects/plain")" ] || fail "ensure touched a project with no token: $out"
  case "$(hooks "$h" diagnose)" in *plain*) fail "diagnose named a project with no token" ;; esac
  pass "a project with no hooks= token is never touched or diagnosed"
}

test_diagnose_fires_on_inert_and_is_silent_on_live() {
  local h out
  h=$(new_home "hooks=$INSTALLER")
  out=$(hooks "$h" diagnose)
  case "$out" in *"HOOKS_INERT: hooked: "*"fleet sync"*"fm-project-hooks.sh ensure hooked"*) ;; *) fail "no diagnostic naming the repair: $out" ;; esac
  hooks "$h" ensure hooked >/dev/null
  out=$(hooks "$h" diagnose)
  [ -z "$out" ] || fail "diagnose spoke about a live clone: $out"
  pass "the diagnostic names the repair on an inert clone and is silent on a live one"
}

test_bootstrap_surfaces_the_diagnostic() {
  local h out
  h=$(new_home "hooks=$INSTALLER")
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null || true)
  case "$out" in *"HOOKS_INERT: hooked:"*) ;; *) fail "bootstrap did not print HOOKS_INERT: $out" ;; esac
  hooks "$h" ensure hooked >/dev/null
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null || true)
  case "$out" in *HOOKS_INERT*) fail "bootstrap reported a live clone as inert: $out" ;; esac
  pass "session-start bootstrap prints HOOKS_INERT for an inert clone only"
}

test_untracked_installer_fails_without_touching_the_tree() {
  local h out rc clone
  h=$(new_home "hooks=scripts/missing.sh")
  clone="$h/projects/hooked"
  printf 'wip\n' > "$clone/scratch.txt"
  out=$(hooks "$h" ensure hooked); rc=$?
  [ "$rc" -ne 0 ] || fail "ensure succeeded with no installer"
  case "$out" in *"hooked: hooks: failed:"*) ;; *) fail "no failed line: $out" ;; esac
  [ -f "$clone/scratch.txt" ] || fail "ensure disturbed the working tree"
  h=$(new_home "hooks=scripts/loose.sh")
  printf '#!/usr/bin/env bash\ngit config core.hooksPath scripts/git-hooks\n' > "$h/projects/hooked/scripts/loose.sh"
  out=$(hooks "$h" ensure hooked); rc=$?
  [ "$rc" -ne 0 ] && [ -z "$(local_hooks_path "$h/projects/hooked")" ] || fail "ran an untracked installer: $out"
  pass "a missing or untracked installer fails with a reason and leaves the tree alone"
}

test_diagnose_reports_a_refused_token() {
  local h out
  h=$(new_home "hooks=/etc/x.sh")
  out=$(hooks "$h" diagnose)
  case "$out" in *"HOOKS_INERT: hooked: "*"refused"*) ;; *) fail "diagnose was silent on a refused hooks= token: $out" ;; esac
  case "$out" in *plain*) fail "diagnose named a project with no token: $out" ;; esac
  pass "diagnose reports a refused hooks= token instead of skipping the clone"
}

test_fleet_sync_leaves_a_dirty_clone_alone() {
  local h out
  h=$(new_home "hooks=$INSTALLER")
  printf '# local edit\n' >> "$h/projects/hooked/scripts/git-hooks/pre-commit"
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" 2>/dev/null)
  case "$out" in *"hooked: hooks:"*) fail "fleet sync ran the hooks repair on a dirty clone: $out" ;; esac
  [ -z "$(local_hooks_path "$h/projects/hooked")" ] || fail "fleet sync set core.hooksPath in a dirty clone"
  grep -q '# local edit' "$h/projects/hooked/scripts/git-hooks/pre-commit" || fail "fleet sync disturbed the dirty clone's edit"
  pass "fleet sync leaves a dirty clone's hooks alone and prints no hooks line"
}

test_home_seed_runs_the_installer_in_a_new_clone() {
  local h child
  h=$(new_home "hooks=$INSTALLER")
  mkdir -p "$h/state"
  printf -- '- hooked [direct-PR hooks=%s] - hooked project (added 2026-11-13)\n' "$INSTALLER" > "$h/data/projects.md"
  child="$TMP_ROOT/seeded-child"
  FM_HOME="$h" FM_BACKEND=tmux FM_SECONDMATE_CHARTER='hooks work for hooked' FM_SECONDMATE_SCOPE='hooks work for hooked' \
    "$ROOT/bin/fm-home-seed.sh" kid "$child" hooked >/dev/null 2>&1 || fail "home seed failed"
  [ -d "$child/projects/hooked" ] || fail "home seed did not clone the project"
  [ "$(local_hooks_path "$child/projects/hooked")" = scripts/git-hooks ] || fail "home seed did not run the declared installer in the new clone"
  [ -z "$(local_hooks_path "$h/projects/hooked")" ] || fail "home seed touched the parent's clone"
  pass "seeding a home runs the declared hooks installer in the new clone"
}

fm_test_run \
  test_mode_reads_hooks_token_and_refuses_malformed \
  test_ensure_makes_hooks_live \
  test_injected_git_config_does_not_hide_an_inert_clone \
  test_fleet_sync_repairs_inert_and_is_silent_on_live \
  test_project_without_token_is_untouched \
  test_diagnose_fires_on_inert_and_is_silent_on_live \
  test_bootstrap_surfaces_the_diagnostic \
  test_untracked_installer_fails_without_touching_the_tree \
  test_diagnose_reports_a_refused_token \
  test_fleet_sync_leaves_a_dirty_clone_alone \
  test_home_seed_runs_the_installer_in_a_new_clone
