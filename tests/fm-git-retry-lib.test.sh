#!/usr/bin/env bash
# Behavior tests for bin/fm-git-retry-lib.sh (fm_git_retry): a fake git fails with an
# ssh connection error and is retried; a real git refusal is returned at once; the
# attempt limit holds. Delays are zeroed so the suite does not sleep.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-git-retry-lib.sh
. "$ROOT/bin/fm-git-retry-lib.sh"

export FM_GIT_RETRY_DELAYS="0 0"
FM_GIT_RETRY_ATTEMPTS=3
T=$(fm_test_tmproot git-retry)

# fake <name> <fail-count> <rc> <stderr-text>: fails <fail-count> times, then succeeds.
fake() {
  printf '%s\n' "$4" >"$T/$1.msg"
  cat >"$T/$1" <<SH
#!/usr/bin/env bash
n=\$(cat "$T/$1.count" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" >"$T/$1.count"
if [ "\$n" -le $2 ]; then cat "$T/$1.msg" >&2; exit $3; fi
echo ok-stdout
SH
  chmod +x "$T/$1"; rm -f "$T/$1.count"
}
calls() { cat "$T/$1.count" 2>/dev/null || echo 0; }

fake ssh_once 1 128 'fatal: Could not read from remote repository.'
out=$(fm_git_retry "$T/ssh_once" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = ok-stdout ] && [ "$(calls ssh_once)" = 2 ] \
  && pass "ssh failure is retried and then succeeds" || fail "ssh failure retry (rc=$rc calls=$(calls ssh_once))"

fake pubkey_once 1 128 'git@github.com: Permission denied (publickey).'
fm_git_retry "$T/pubkey_once" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$(calls pubkey_once)" = 2 ] \
  && pass "publickey denial is retried" || fail "publickey retry (rc=$rc)"

fake rc255 1 255 'ssh: connect to host github.com port 22: Connection reset'
fm_git_retry "$T/rc255" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$(calls rc255)" = 2 ] \
  && pass "exit 255 is retried" || fail "exit 255 retry (rc=$rc)"

fake rejected 9 1 ' ! [rejected] main -> main (non-fast-forward)'
err=$(fm_git_retry "$T/rejected" 2>&1 >/dev/null); rc=$?
[ "$rc" -eq 1 ] && [ "$(calls rejected)" = 1 ] && case $err in *non-fast-forward*) true ;; *) false ;; esac \
  && pass "push rejection is not retried and its stderr and status survive" || fail "rejection retried (rc=$rc calls=$(calls rejected))"

fake missing_ref 9 128 "fatal: couldn't find remote ref refs/heads/nope"
fm_git_retry "$T/missing_ref" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 128 ] && [ "$(calls missing_ref)" = 1 ] \
  && pass "missing ref is not retried" || fail "missing ref retried (rc=$rc)"

fake always_ssh 99 128 'fatal: Could not read from remote repository.'
fm_git_retry "$T/always_ssh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 128 ] && [ "$(calls always_ssh)" = 3 ] \
  && pass "attempt limit holds (3 tries) and the last status is returned" || fail "attempt limit (rc=$rc calls=$(calls always_ssh))"

FM_GIT_RETRY_ATTEMPTS=2
fake limit2 99 128 'fatal: Could not read from remote repository.'
fm_git_retry "$T/limit2" >/dev/null 2>&1
[ "$(calls limit2)" = 2 ] && pass "FM_GIT_RETRY_ATTEMPTS is honored" || fail "attempts override"


FM_GIT_RETRY_ATTEMPTS=3
fake errexit_once 1 255 'ssh: connect to host github.com port 22: Connection reset'
err=$( (set -e; fm_git_retry "$T/errexit_once" >/dev/null; echo after-call >&2) 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [ "$(calls errexit_once)" = 2 ] && case $err in *fm-git-retry:*after-call*) true ;; *) false ;; esac \
  && pass "a bare call under set -e still retries and the script continues" || fail "set -e bare call (rc=$rc calls=$(calls errexit_once))"

fake errexit_always 99 128 'fatal: Could not read from remote repository.'
err=$( (set -e; fm_git_retry "$T/errexit_always" >/dev/null; echo after-call >&2) 2>&1 ); rc=$?
[ "$rc" -eq 128 ] && [ "$(calls errexit_always)" = 3 ] && case $err in *'Could not read from remote'*) true ;; *) false ;; esac \
  && case $err in *after-call*) false ;; *) true ;; esac \
  && pass "a bare failing call under set -e retries, prints git's stderr and then exits" || fail "set -e bare failure (rc=$rc calls=$(calls errexit_always))"
