# shellcheck shell=bash
# Bounded retry for the first (master) ssh connection of a git network call.
# Usage: . bin/fm-git-retry-lib.sh; fm_git_retry git -C "$dir" fetch origin ...
#
# GitHub intermittently refuses a valid key on a fresh ssh connection (about 1 in
# 3 on slartibartfast on 2026-11-04); once ControlMaster holds a master connection,
# reuse authenticates every time. So only the call that has to open the master
# needs a retry, and only for an ssh connection or authentication failure:
#   - the command exited 255 (ssh's own failure code), or
#   - its stderr says "Could not read from remote repository" or
#     "Permission denied (publickey)".
# Any other failure (rejected push, non-fast-forward, missing ref) is returned at
# once, never retried. The command's stdout, stderr and exit status are those of
# its last attempt, so callers keep their existing redirections.
#
# Tunables (named constants; override from the environment, tests set the delays to 0):
#   FM_GIT_RETRY_ATTEMPTS  total attempts, first try included (default 3)
#   FM_GIT_RETRY_DELAYS    space-separated seconds slept after attempt 1, 2, ... (default "2 5")
#
# Scope: git clone, fetch and push only. Do not wrap gh or gh-axi API calls.

FM_GIT_RETRY_ATTEMPTS="${FM_GIT_RETRY_ATTEMPTS:-3}"
FM_GIT_RETRY_DELAYS="${FM_GIT_RETRY_DELAYS:-2 5}"

fm_git_retry_is_ssh_failure() { # <rc> <stderr-file>
  [ "$1" -eq 255 ] && return 0
  grep -qE 'Could not read from remote repository|Permission denied \(publickey\)' "$2" 2>/dev/null
}

fm_git_retry() { # <command...>
  local attempt=1 rc err delay delays
  err=$(mktemp "${TMPDIR:-/tmp}/fm-git-retry.XXXXXX") || { "$@"; return; }
  # shellcheck disable=SC2206 # word splitting of the delay list is intended
  delays=($FM_GIT_RETRY_DELAYS)
  while :; do
    rc=0; "$@" 2>"$err" || rc=$?
    if [ "$rc" -eq 0 ] || [ "$attempt" -ge "$FM_GIT_RETRY_ATTEMPTS" ] \
      || ! fm_git_retry_is_ssh_failure "$rc" "$err"; then
      cat "$err" >&2
      rm -f "$err"
      return "$rc"
    fi
    delay=${delays[attempt-1]:-${delays[${#delays[@]}-1]:-0}}
    printf 'fm-git-retry: ssh connection failed (attempt %s/%s); retrying in %ss\n' \
      "$attempt" "$FM_GIT_RETRY_ATTEMPTS" "$delay" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}
