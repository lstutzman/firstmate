#!/usr/bin/env bash
# fm-lint-ratchet.sh - the daily move of firstmate's lint ratchet.
#
# bin/fm-lint.sh enforces a stricter ShellCheck check on every shell file that
# is not named in bin/fm-lint-ratchet.exceptions, so new files must pass and
# the check only ever gets stricter. This helper moves one listed file at a
# time off that list; fm-lint.sh owns the check definition and the list format.
# One small change a day keeps review cheap.
#
# Daily run (not scheduled by this repo; an office tick or a timer calls it):
#   1. file=$(bin/fm-lint-ratchet.sh next)    exit 1 with no output when empty
#   2. fix "$file" until: bin/fm-lint-ratchet.sh check "$file"
#   3. bin/fm-lint-ratchet.sh retire "$file"  removes it from the list
#   4. run bin/fm-lint.sh, commit, and open one pull request
#
# Usage:
#   fm-lint-ratchet.sh next           print the next listed file
#   fm-lint-ratchet.sh list           print every listed file
#   fm-lint-ratchet.sh count          print how many files remain
#   fm-lint-ratchet.sh check <file>   lint <file> with the ratchet enforced
#   fm-lint-ratchet.sh retire <file>  check <file>, then remove it from the list
#   fm-lint-ratchet.sh --help         print this usage
#
# FM_LINT_RATCHET_LIST overrides the list path (same variable as fm-lint.sh).
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SELF_DIR/.." && pwd -P)"
LIST=${FM_LINT_RATCHET_LIST:-$ROOT/bin/fm-lint-ratchet.exceptions}

usage() {
  awk '/^# Usage:/ { on = 1 } on && /^#/ { sub(/^# ?/, ""); print; next } on { exit }' "${BASH_SOURCE[0]}"
}

entries() {
  [ -f "$LIST" ] || return 0
  grep -Ev '^[[:space:]]*(#|$)' "$LIST"
}

listed() {  # <file>
  entries | grep -Fxq -- "$1"
}

# check_file <file>: lint with an empty exception list so the ratchet applies.
check_file() {
  local empty rc=0
  empty=$(mktemp) || return 1
  FM_LINT_RATCHET_LIST=$empty "$SELF_DIR/fm-lint.sh" "$1" || rc=$?
  /usr/bin/trash "$empty" 2>/dev/null || true
  return "$rc"
}

need_listed() {  # <file>
  [ -n "${1:-}" ] || { printf 'fm-lint-ratchet.sh: a file is required.\n' >&2; exit 2; }
  listed "$1" || { printf 'fm-lint-ratchet.sh: %s is not on the exception list.\n' "$1" >&2; exit 1; }
}

case "${1:-}" in
  next) first=$(entries | head -n 1); [ -n "$first" ] || exit 1; printf '%s\n' "$first" ;;
  list) entries ;;
  count) entries | wc -l | tr -d '[:space:]'; echo ;;
  check) need_listed "${2:-}"; (cd "$ROOT" && check_file "$2") ;;
  retire)
    need_listed "${2:-}"
    (cd "$ROOT" && check_file "$2") || exit 1
    tmp=$(mktemp) || exit 1
    grep -Fxv -- "$2" "$LIST" > "$tmp"
    cat "$tmp" > "$LIST"
    /usr/bin/trash "$tmp" 2>/dev/null || true
    printf 'fm-lint-ratchet.sh: retired %s\n' "$2"
    ;;
  --help|-h) usage ;;
  *) usage >&2; exit 2 ;;
esac
