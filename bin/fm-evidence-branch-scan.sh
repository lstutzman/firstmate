#!/usr/bin/env bash
# fm-evidence-branch-scan.sh - scan what the orphan no-mistakes/evidence branch
# gained in the last two days. The daily Evidence secret scan workflow runs it.
# docs/secret-scan.md owns the policy.
#
# Usage:
#   fm-evidence-branch-scan.sh [--repo <dir>]
#       Scan refs/remotes/origin/no-mistakes/evidence in <dir> (default: the
#       current repository). Two scans run, and both always run:
#       bin/fm-secret-scan.sh over the branch's commits from the last two
#       days, and bin/fm-evidence-secrets.sh check over the files those
#       commits added or modified, read from the branch tip.
#
# Exit 0 clean or no evidence branch (a notice says so), 1 a finding in either
# scan, 2 a scan could not run. Paths are read NUL-separated, so a quoted or
# non-ASCII file name is scanned like any other. No worktree is created.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF=refs/remotes/origin/no-mistakes/evidence
SINCE=--since=2.days.ago

REPO=
while [ "$#" -gt 0 ]; do
  case "$1" in
  --repo)
    [ "$#" -ge 2 ] || { echo "fm-evidence-branch-scan: --repo needs a directory" >&2; exit 2; }
    REPO=$2
    shift 2
    ;;
  -h | --help)
    sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "fm-evidence-branch-scan: unknown argument: $1 (see --help)" >&2
    exit 2
    ;;
  esac
done
if [ -z "$REPO" ]; then
  REPO=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "fm-evidence-branch-scan: not inside a git work tree (use --repo)" >&2
    exit 2
  }
fi

if ! git -C "$REPO" rev-parse --verify --quiet "$REF" >/dev/null; then
  echo "::notice::No no-mistakes/evidence branch in this repository; nothing to scan."
  exit 0
fi

status=0
record() { # <exit-code>
  [ "$1" -le "$status" ] || status=$1
}

"$SCRIPT_DIR/fm-secret-scan.sh" --repo "$REPO" --range "$SINCE $REF"
record $?

files=$(mktemp -d "${TMPDIR:-/tmp}/fm-evidence-branch-scan.XXXXXX") || exit 2
trap 'rm -rf "$files"' EXIT
count=0
while IFS= read -r -d '' path; do
  [ -n "$path" ] || continue
  git -C "$REPO" cat-file -e "$REF:$path" 2>/dev/null || continue
  mkdir -p "$files/$(dirname -- "$path")"
  git -C "$REPO" cat-file blob "$REF:$path" >"$files/$path" || { record 2; continue; }
  count=$((count + 1))
done < <(git -C "$REPO" log -z "$SINCE" --name-only --diff-filter=AM --format= "$REF")

if [ "$count" -gt 0 ]; then
  (cd "$files" && "$SCRIPT_DIR/fm-evidence-secrets.sh" check .)
  record $?
else
  echo "No evidence files changed in the last two days."
fi
exit "$status"
