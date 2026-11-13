#!/usr/bin/env bash
# Keep a registered project's own git hooks live in its clone.
# A project declares its hook installer with a hooks=<repo-relative path> token on
# its data/projects.md line (bin/fm-project-mode.sh --hooks owns the token). The
# installer only sets the clone's core.hooksPath; nothing here infers an
# installer from a file name, and a project with no token is never touched.
#
# Live means the clone's OWN config (git config --local) sets core.hooksPath and
# the resolved hooks directory exists. Every firstmate-launched session injects
# core.hooksPath through GIT_CONFIG_COUNT/GIT_CONFIG_PARAMETERS, which a plain
# `git config --get` would report as the clone's setting, so every git call here
# runs with that injection removed.
#
# Subcommands (<project> is a clone directory, or a name under this home's projects dir):
#   declared <project>   print the declared installer path, or nothing
#   status <project>     print none (no token), live, or inert
#   ensure <project>     no token or live: print nothing. Inert: run the declared,
#                        tracked installer once from the clone with bash, re-check,
#                        and print "<name>: hooks: repaired (...)" or
#                        "<name>: hooks: failed: <reason>". Exit 1 on failure.
#                        It never stashes, resets or discards anything.
#   diagnose             print one "HOOKS_INERT: ..." line per registered clone under
#                        this home's projects dir whose declared hooks are inert or
#                        whose hooks= token is refused
# Callers: bin/fm-fleet-sync.sh (repair after a successful refresh), project
# initialization (the project-management skill, bin/fm-home-seed.sh), and
# bin/fm-bootstrap.sh (session-start diagnostic).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

usage() { echo "usage: fm-project-hooks.sh declared|status|ensure <project> | diagnose" >&2; }

# Run git against a clone with firstmate's injected config removed.
clean_git() {
  env -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM -u GIT_DIR -u GIT_WORK_TREE git "$@"
}

resolve_clone() {
  local arg=$1
  case "$arg" in
    /*|./*|../*) printf '%s\n' "$arg" ;;
    *) if [ -d "$PROJECTS/${arg#projects/}" ]; then printf '%s\n' "$PROJECTS/${arg#projects/}"; else printf '%s\n' "$arg"; fi ;;
  esac
}

# Sets CLONE, NAME, INSTALLER (empty when undeclared). Returns 1 on a refused token.
load() {
  CLONE=$(resolve_clone "$1")
  NAME=$(basename "$CLONE")
  INSTALLER=$("$FM_ROOT/bin/fm-project-mode.sh" --hooks "$NAME" 2>/dev/null) || {
    echo "$NAME: hooks: failed: registry hooks= token is refused (run bin/fm-project-mode.sh --hooks $NAME)"
    return 1
  }
}

is_live() {
  local hp abs
  hp=$(clean_git -C "$CLONE" config --local --get core.hooksPath 2>/dev/null) || return 1
  [ -n "$hp" ] || return 1
  case "$hp" in
    /*) [ -d "$hp" ] ;;
    *) abs=$(clean_git -C "$CLONE" rev-parse --show-toplevel 2>/dev/null) || return 1
       [ -d "$abs/$hp" ] ;;
  esac
}

cmd=${1:-}
case "$cmd" in
  declared|status|ensure)
    [ $# -eq 2 ] || { usage; exit 1; }
    load "$2" || exit 1
    case "$cmd" in
      declared) [ -z "$INSTALLER" ] || echo "$INSTALLER" ;;
      status)
        if [ -z "$INSTALLER" ]; then echo none
        elif is_live; then echo live
        else echo inert; fi ;;
      ensure)
        [ -n "$INSTALLER" ] || exit 0
        is_live && exit 0
        top=$(clean_git -C "$CLONE" rev-parse --show-toplevel 2>/dev/null) || top=""
        if [ -z "$top" ] || ! [ "$top" -ef "$CLONE" ]; then
          echo "$NAME: hooks: failed: not a clone root"; exit 1
        fi
        if ! clean_git -C "$CLONE" ls-files --error-unmatch -- "$INSTALLER" >/dev/null 2>&1 || [ ! -f "$CLONE/$INSTALLER" ]; then
          echo "$NAME: hooks: failed: declared installer $INSTALLER is not a tracked file in the checked-out tree"; exit 1
        fi
        if ! out=$(cd "$CLONE" && env -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS bash "$INSTALLER" 2>&1); then
          echo "$NAME: hooks: failed: installer $INSTALLER exited non-zero: $(printf '%s\n' "$out" | tail -n 1)"; exit 1
        fi
        if is_live; then
          echo "$NAME: hooks: repaired (ran $INSTALLER; core.hooksPath=$(clean_git -C "$CLONE" config --local --get core.hooksPath))"
        else
          echo "$NAME: hooks: failed: installer $INSTALLER ran but core.hooksPath is still unset or its directory is missing"; exit 1
        fi ;;
    esac ;;
  diagnose)
    [ -d "$PROJECTS" ] || exit 0
    for dir in "$PROJECTS"/*; do
      [ -d "$dir" ] || continue
      clean_git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || continue
      CLONE=$dir; NAME=$(basename "$dir")
      INSTALLER=$("$FM_ROOT/bin/fm-project-mode.sh" --hooks "$NAME" 2>/dev/null) || {
        echo "HOOKS_INERT: $NAME: the registry hooks= token is refused, so this clone's git hooks are never checked or repaired; correct its data/projects.md line (run: bin/fm-project-mode.sh --hooks $NAME)"
        continue
      }
      [ -n "$INSTALLER" ] || continue
      is_live || echo "HOOKS_INERT: $NAME: declared git hooks ($INSTALLER) are not live in this clone, so commits skip the project's own pre-commit; the next fleet sync repairs it only if the clone is clean on its default branch and refreshes successfully, otherwise run: bin/fm-project-hooks.sh ensure $NAME"
    done ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac
