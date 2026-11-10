#!/usr/bin/env bash
# tests/fm-lee-step.test.sh - the captain-step renderer (bin/fm-lee-step.sh), the
# resumed-worker directory check (bin/fm-worktree-assert.sh), and the shared cause
# vocabulary both rely on (bin/fm-classify-lib.sh status_line_cause).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lee-step)
HOME_FIX="$TMP_ROOT/home"
mkdir -p "$HOME_FIX/config" "$HOME_FIX/state"
STEP="$ROOT/bin/fm-lee-step.sh"

step() { FM_HOME="$HOME_FIX" "$STEP" "$@"; }

# Host-aware: the configured Lee-step host is the reader's machine.
printf '# the machine the captain reads Lee steps on\nSlartibartfast\n' > "$HOME_FIX/config/lee-step-host"
out=$(step --cause sudo --no-recipe 'no recipe swaps the disk' slartibartfast /x/swap.sh c2)
assert_contains "$out" '[cause=sudo]' 'the step states why no agent can run it'
assert_contains "$out" $'\nbash /x/swap.sh c2' 'a session already on the target host gets a plain bash line'
assert_not_contains "$out" 'ssh' 'no ssh to the machine the session is already on'
assert_contains "$out" 'No fleet-admin recipe: no recipe swaps the disk' 'the step prints why no recipe covers it'
out=$(step --cause tool slartibartfast /x/a.sh 2>&1 >/dev/null)
assert_not_contains "$out" 'lee-step-host is unset' 'a configured Lee-step host raises no note'
out=$(step --cause credential lee@SLARTIBARTFAST.local /x/a.sh)
assert_contains "$out" $'\nbash /x/a.sh' 'user@host and a domain suffix still match the Lee-step host, case-insensitively'
out=$(step --cause policy deepthought /x/swap.sh "it's here")
want_ssh="ssh -t deepthought 'bash /x/swap.sh it\\'\\''s\\ here'"
assert_contains "$out" "$want_ssh" 'a host other than the Lee-step host gets one ssh -t line with the remote command single-quoted'
# The ssh line round-trips: a shell parses the remote command back to the original words.
remote=$(printf '%s\n' "$out" | sed -n '2p')
[ "$(eval "set -- ${remote#ssh -t deepthought }; printf '%s' \"\$1\"")" = "bash /x/swap.sh it\\'s\\ here" ] \
  || fail "the ssh remote command must survive one more shell parse: $remote"
# Without config/lee-step-host the reader's machine is unknown, so every step is ssh,
# even one naming the machine this script runs on.
rm -f "$HOME_FIX/config/lee-step-host"
self=$(hostname -s)
out=$(step --cause tool "$self" /x/a.sh)
assert_contains "$out" "ssh -t $self 'bash /x/a.sh'" 'with no config/lee-step-host every step is an ssh line'
assert_not_contains "$out" $'\nbash /x/a.sh' 'with no config/lee-step-host the script host never decides'
note=$(step --cause tool "$self" /x/a.sh 2>&1 >/dev/null)
assert_contains "$note" 'config/lee-step-host is unset' 'an ssh-to-self line from an unset host says which file fixes it'
pass 'lee steps are host-aware'

# The cause is required and closed.
for bad in "" decision external bogus; do
  step --cause "$bad" h /x/a.sh >/dev/null 2>&1 && fail "cause '$bad' must be refused"
done
step h /x/a.sh >/dev/null 2>&1 && fail 'a step with no --cause must be refused'
step --cause physical h >/dev/null 2>&1 && fail 'a step with no script must be refused'
step --cause sudo 'h;rm' /x/a.sh >/dev/null 2>&1 && fail 'a host with shell metacharacters must be refused'
for ok in credential policy tool physical; do
  step --cause "$ok" otherhost /x/a.sh >/dev/null || fail "cause '$ok' must be accepted"
done
# A sudo step is refused unless it states that no fleet-admin recipe covers it.
err=$(step --cause sudo otherhost /x/a.sh 2>&1 >/dev/null) && fail 'a sudo step with no --no-recipe must be refused'
assert_contains "$err" 'sudo -n fleet-admin <recipe>' 'the sudo refusal points at the recipe route'
step --cause sudo --no-recipe '   ' otherhost /x/a.sh >/dev/null 2>&1 && fail 'a blank --no-recipe reason must be refused'
step --cause sudo --no-recipe otherhost /x/a.sh >/dev/null 2>&1 && fail '--no-recipe with no script must be refused'
step --cause sudo --no-recipe 'no recipe installs pam' otherhost /x/a.sh >/dev/null 2>&1 || fail 'a sudo step naming the recipe gap must be accepted'
pass 'every lee step must name a closed-set cause'

# The same vocabulary parses off a status line, physical and a paused external wait included.
(
  # shellcheck source=bin/fm-classify-lib.sh
  . "$ROOT/bin/fm-classify-lib.sh"
  [ "$(status_line_cause 'needs-decision [at=1790000000] [cause=physical] [key=k]: plug it in')" = physical ] || exit 1
  line='paused [at=1790000000] [cause=external]: pc-db unreachable, expected back soon; until 2099-01-01T00:00Z'
  [ "$(status_line_cause "$line")" = external ] || exit 1
  [ "$(status_paused_until "$line")" -gt "$(date +%s)" ] || exit 1
  [ "$(status_line_cause 'blocked [at=1790000000] [cause=bogus]: x')" = unstated ] || exit 1
) || fail 'status_line_cause must read physical and a paused external wait'
pass 'the cause vocabulary reads physical and paused external waits'

# A resumed worker must be inside the worktree its task record names.
WT="$TMP_ROOT/wt"
OTHER="$TMP_ROOT/other"
mkdir -p "$WT/sub" "$OTHER"
printf 'worktree=%s\nkind=ship\n' "$WT" > "$HOME_FIX/state/job.meta"
assert_wt() { (cd "$1" && FM_HOME="$HOME_FIX" "$ROOT/bin/fm-worktree-assert.sh" job 2>&1); }
assert_wt "$WT" >/dev/null || fail 'the recorded worktree itself must pass'
assert_wt "$WT/sub" >/dev/null || fail 'a directory inside the recorded worktree must pass'
out=$(assert_wt "$OTHER"); code=$?
[ "$code" -eq 1 ] || fail "a session in another directory must refuse with exit 1 (got $code)"
assert_contains "$out" "cd -- '$WT'" 'the refusal names the exact directory to return to'
assert_contains "$out" "$OTHER" 'the refusal names where the session actually is'
# A sibling that merely shares the worktree path as a prefix is another directory.
mkdir -p "$WT-two"
assert_wt "$WT-two" >/dev/null && fail 'a sibling sharing the path prefix must refuse'
(cd "$WT" && FM_HOME="$HOME_FIX" "$ROOT/bin/fm-worktree-assert.sh" nope >/dev/null 2>&1); [ $? -eq 2 ] || fail 'a missing task record must exit 2'
printf 'kind=ship\n' > "$HOME_FIX/state/bare.meta"
(cd "$WT" && FM_HOME="$HOME_FIX" "$ROOT/bin/fm-worktree-assert.sh" bare >/dev/null 2>&1); [ $? -eq 2 ] || fail 'a record with no worktree must exit 2'
pass 'a resume outside the recorded worktree refuses with the expected directory'
