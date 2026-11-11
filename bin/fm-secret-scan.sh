#!/usr/bin/env bash
# fm-secret-scan.sh - single owner of how this repository runs its gitleaks
# secret scan. CI, the per-task pre-push hook and the no-mistakes lint step all
# call it, so a push is refused locally for exactly what CI would fail.
# docs/secret-scan.md owns the policy; .gitleaks.toml owns the allowlist.
#
# Usage:
#   fm-secret-scan.sh --required-version
#       Print the minimum gitleaks version this scan needs.
#   fm-secret-scan.sh [--repo <dir>] [--config <file>] --range <rev-range>
#       Scan the commits in <rev-range> (for example base..head). CI uses this.
#   fm-secret-scan.sh [--repo <dir>] [--config <file>] --push-range <before> <after>
#       Scan the commits a push to a branch added: before..after, or just
#       <after> when <before> is the all-zero id or not a commit here (a new
#       branch or a force push). CI uses this for a push event.
#   fm-secret-scan.sh [--repo <dir>] [--config <file>] --branch
#       Scan HEAD's commits that no origin remote-tracking ref has yet
#       (all remote-tracking refs when there is no origin). The no-mistakes
#       lint step uses this.
#   fm-secret-scan.sh [--repo <dir>] [--config <file>] pre-push <remote> <url>
#       Git pre-push mode: reads "<local-ref> <local-oid> <remote-ref>
#       <remote-oid>" lines on stdin and scans each pushed ref's new commits.
#       The pre-push wrapper bin/fm-git-strip-ai-trailers.sh installs for a
#       fleet launch (install --secret-scan) runs this before chaining on.
#
# Exit 0 clean, 1 a finding (the push or job is refused), 2 the scan could not
# run (gitleaks missing or older than the minimum, bad arguments, unreadable
# config). Every non-zero exit blocks; a scan that cannot run never passes.
#
# A finding prints as file, line, rule and short commit only (a report
# template that never names the secret or the matched line), with gitleaks
# --redact on as well, so the secret value is never printed.
# A finding is a real secret until proven otherwise: rotate it, never
# allowlist it (docs/secret-scan.md). Config precedence: --config, then
# <repo>/.gitleaks.toml, then this script's own checkout's .gitleaks.toml.
#
# ACCEPTED RESIDUAL. `git push --no-verify` skips the hook, a tool that writes
# refs without running git never reaches it, and a branch can edit
# .gitleaks.toml in the same push it scans (the merge review is the control for
# a config change). CI re-runs the scan on every pull request and main push.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REQUIRED_GITLEAKS=8.30.1
ZERO_OID=0000000000000000000000000000000000000000

die() { # <message>
  printf 'fm-secret-scan: %s\n' "$1" >&2
  exit 2
}

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_GITLEAKS"
  exit 0
fi

REPO=
CONFIG=
MODE=
RANGE=
BEFORE=
AFTER=
while [ "$#" -gt 0 ]; do
  case "$1" in
  --repo)
    [ "$#" -ge 2 ] || die "--repo needs a directory"
    REPO=$2
    shift 2
    ;;
  --config)
    [ "$#" -ge 2 ] || die "--config needs a file"
    CONFIG=$2
    shift 2
    ;;
  --range)
    [ "$#" -ge 2 ] || die "--range needs a revision range"
    MODE=range RANGE=$2
    shift 2
    ;;
  --push-range)
    [ "$#" -ge 3 ] || die "--push-range needs <before> <after>"
    MODE=push-range BEFORE=$2 AFTER=$3
    shift 3
    ;;
  --branch)
    MODE=branch
    shift
    ;;
  pre-push)
    MODE=pre-push
    break
    ;;
  -h | --help)
    sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -n "$MODE" ] || die "choose --range, --push-range, --branch or pre-push (see --help)"

command -v gitleaks >/dev/null 2>&1 || die "gitleaks not found; install the pinned build with bin/fm-install-gitleaks.sh <destination-directory> and put that directory on PATH (needs $REQUIRED_GITLEAKS or newer)"
found=$(gitleaks version 2>/dev/null | head -n 1 | tr -d '[:space:]v')
case "$found" in
[0-9]*.[0-9]*.[0-9]*) ;;
*) die "cannot read the gitleaks version (got '$found')" ;;
esac
oldest=$(printf '%s\n%s\n' "$REQUIRED_GITLEAKS" "$found" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)
[ "$oldest" = "$REQUIRED_GITLEAKS" ] || die "gitleaks $found is older than the required $REQUIRED_GITLEAKS; install the pinned build with bin/fm-install-gitleaks.sh <destination-directory>"

if [ -z "$REPO" ]; then
  REPO=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git work tree (use --repo)"
fi
[ -d "$REPO" ] || die "repository is not a directory: $REPO"
if [ -z "$CONFIG" ]; then
  if [ -f "$REPO/.gitleaks.toml" ]; then
    CONFIG="$REPO/.gitleaks.toml"
  elif [ -f "$ROOT/.gitleaks.toml" ]; then
    CONFIG="$ROOT/.gitleaks.toml"
  else
    die "no .gitleaks.toml in $REPO or $ROOT (use --config)"
  fi
fi
[ -r "$CONFIG" ] || die "config is not readable: $CONFIG"

# scan_log_opts <git-log-options>: one gitleaks run over that history slice.
# Output is redacted; exit 99 is gitleaks' finding code (1 stays a tool error).
scan_log_opts() {
  local opts=$1 out tmpl rc
  out=$(mktemp "${TMPDIR:-/tmp}/fm-secret-scan.XXXXXX") || die "cannot create a temporary file"
  tmpl="$out.tmpl"
  # One line per finding: file, line, rule and short commit. The template
  # never references the secret or the matched line, so no value can print.
  printf '%s\n' '{{ range . }}  {{ .File }}:{{ .StartLine }}  {{ .RuleID }}  commit {{ printf "%.8s" .Commit }}' '{{ end }}' >"$tmpl"
  gitleaks git --no-banner --no-color --redact --exit-code 99 \
    --config "$CONFIG" --log-opts="$opts" \
    --report-format template --report-template "$tmpl" --report-path "$out.report" -- "$REPO" >"$out" 2>&1
  rc=$?
  case "$rc" in
  0) rm -f "$out" "$tmpl" "$out.report" ;;
  99)
    printf 'fm-secret-scan: refused: possible secret in commits %s (values never printed):\n' "$opts" >&2
    cat "$out.report" >&2
    printf 'fm-secret-scan: rotate a real secret and remove it from the branch; never allowlist it (docs/secret-scan.md).\n' >&2
    rm -f "$out" "$tmpl" "$out.report"
    return 1
    ;;
  *)
    printf 'fm-secret-scan: gitleaks failed (exit %s) on %s:\n' "$rc" "$opts" >&2
    cat "$out" >&2
    rm -f "$out" "$tmpl" "$out.report"
    return 2
    ;;
  esac
}

# not_on_remote <rev>: revisions reachable from <rev> that origin (or, with no
# origin remote, every remote-tracking ref) does not have yet.
not_on_remote() {
  if git -C "$REPO" remote | grep -qx origin; then
    printf '%s --not --remotes=origin' "$1"
  else
    printf '%s --not --remotes' "$1"
  fi
}

case "$MODE" in
range) scan_log_opts "$RANGE" ;;
push-range)
  if [ "$BEFORE" != "$ZERO_OID" ] && git -C "$REPO" cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
    scan_log_opts "$BEFORE..$AFTER"
  else
    scan_log_opts "$AFTER^..$AFTER"
  fi
  ;;
branch) scan_log_opts "$(not_on_remote HEAD)" ;;
pre-push)
  status=0
  while read -r local_ref local_oid remote_ref remote_oid; do
    [ -n "${local_ref:-}" ] || continue
    [ "$local_oid" != "$ZERO_OID" ] || continue # a delete pushes no commits
    if [ "$remote_oid" != "$ZERO_OID" ] && git -C "$REPO" cat-file -e "$remote_oid^{commit}" 2>/dev/null; then
      opts="$remote_oid..$local_oid"
    else
      opts=$(not_on_remote "$local_oid")
    fi
    scan_log_opts "$opts" || {
      rc=$?
      [ "$rc" -le "$status" ] || status=$rc
      printf 'fm-secret-scan: push of %s to %s refused.\n' "$local_ref" "${remote_ref:-the remote}" >&2
    }
  done
  exit "$status"
  ;;
esac
