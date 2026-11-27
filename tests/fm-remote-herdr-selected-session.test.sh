#!/usr/bin/env bash
# tests/fm-remote-herdr-selected-session.test.sh - a remote second mate can live
# in the account's own Herdr session, and the host-local control plane never
# starts a second agent beside one that is already running.
#
#   A) Without ~/.firstmate/remote-herdr-session the session is exactly
#      fm-remote and the route carries no selection marker.
#   B) With it, launch, route, state, and retire all use that session, retire
#      closes only this mate's pane, and no server is ever stopped.
#   C) An unusable selection (fm-remote*, spaces, two lines, a symlink) refuses
#      launch and route, and state reads unverified, each naming the file.
#   D) A route recorded in another session is refused while one is selected.
#   E) launch and relaunch refuse when the home's state/.lock names a live
#      process and the recorded endpoint is not that agent, and say to use adopt.
#   F) adopt binds the record to a running agent when every proof holds, and
#      refuses on each missing proof without changing the record.
#   G) The parent accepts a plain session name only with the selection marker.
#
# The Herdr CLI is the stateful fixture in tests/remote-herdr-fixture.sh (A-E)
# or a small read-only fake (F), and omp is a fake that answers `models --json`;
# no real Herdr server, ssh, or vendor tool is used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
[ -d /proc/$$ ] || { echo "skip: adopt's working-directory proof reads /proc here"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-herdr-selected-session)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
LIVE_PIDS=()
trap 'if [ "${#LIVE_PIDS[@]}" -gt 0 ]; then kill "${LIVE_PIDS[@]}" 2>/dev/null || true; fi; fm_test_cleanup || true' EXIT

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
install_remote_herdr_fixture "$FAKEBIN-root" "$TMP_ROOT/herdr.state" "$TMP_ROOT/herdr.log" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
mv "$FAKEBIN-root/bin/herdr" "$FAKEBIN/herdr"
rmdir "$FAKEBIN-root/bin" "$FAKEBIN-root"
ln -sf "$(command -v git)" "$FAKEBIN/git"
ln -sf "$(command -v jq)" "$FAKEBIN/jq"
ln -sf "$(command -v node)" "$FAKEBIN/node"
cat > "$FAKEBIN/omp" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != models ] || printf '%s\n' '{"models":[{"provider":"anthropic","id":"claude-test","selector":"anthropic/claude-test"}]}'
exit 0
SH
chmod +x "$FAKEBIN/omp"
# A long-lived stand-in agent: the lock library recognizes a harness by its
# process name, so this is a copy of a real binary named claude that blocks
# reading a fifo this test keeps open.
HARNESS_BIN="$TMP_ROOT/harness-bin"
mkdir -p "$HARNESS_BIN"
cp "$(fm_test_nonplatform_binary "$(command -v jq)" "$TMP_ROOT")" "$HARNESS_BIN/claude" \
  || fail "cannot build the stand-in agent binary"
AGENT_FIFO="$TMP_ROOT/agent.fifo"
mkfifo "$AGENT_FIFO"
exec 7<>"$AGENT_FIFO"

# assert_line <line> <file> <msg>: the file holds exactly this whole line.
assert_line() {
  grep -Fx -- "$1" "$2" >/dev/null || fail "$3"
}

seed_home() { # <id> -> prints the seeded secondmate home
  local id=$1 home="$TMP_ROOT/home-$1"
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Charter\n\nStand by until steering arrives.\n' > "$home/data/charter.md"
  git -C "$home" init -q
  printf '%s\n' "$home"
}

ctl() { # <account-home> <secondmate-home> <control-args...>
  local account=$1 home=$2
  shift 2
  PATH="$FAKEBIN:$BASE_PATH" TMUX='' FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    HOME="$account" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" "$@"
}

new_account() { # <name> [selected-session] -> prints the account home
  local acct="$TMP_ROOT/acct-$1"
  mkdir -p "$acct/.firstmate"
  printf '%s\n' "$ROOT" > "$acct/.firstmate/remote-herdr-owner"
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$acct/.firstmate/remote-herdr-session"
  printf '%s\n' "$acct"
}

launch() { # <account> <home> <id>
  ctl "$1" "$2" launch "$3" omp anthropic/claude-test high herdr
}

# --- A) no selection: exactly fm-remote ---------------------------------------

ACCT_PLAIN=$(new_account plain)
ID=sm-plain
HOME_PLAIN=$(seed_home "$ID")
launch "$ACCT_PLAIN" "$HOME_PLAIN" "$ID" > "$TMP_ROOT/a.out" 2> "$TMP_ROOT/a.err"
expect_code 0 "$?" "the unselected launch failed"$'\n'"$(cat "$TMP_ROOT/a.err")"
[ "$(sed -n 's/^herdr_session=//p' "$TMP_ROOT/a.out")" = fm-remote ] \
  || fail "the unselected launch left fm-remote"$'\n'"$(cat "$TMP_ROOT/a.out")"
assert_no_regex '^herdr_session_source=' "$TMP_ROOT/a.out" "an unselected route carries a selection marker"
pass "A without a selection the route is exactly fm-remote and unmarked"

# --- B) a selected session is used by every verb -------------------------------

ACCT_SEL=$(new_account sel default)
ID=sm-sel
HOME_SEL=$(seed_home "$ID")
: > "$TMP_ROOT/herdr.log"
launch "$ACCT_SEL" "$HOME_SEL" "$ID" > "$TMP_ROOT/b.out" 2> "$TMP_ROOT/b.err"
expect_code 0 "$?" "the selected-session launch failed"$'\n'"$(cat "$TMP_ROOT/b.err")"
[ "$(sed -n 's/^herdr_session=//p' "$TMP_ROOT/b.out")" = default ] \
  || fail "the launch did not use the selected session"$'\n'"$(cat "$TMP_ROOT/b.out")"
[ "$(sed -n 's/^herdr_session_source=//p' "$TMP_ROOT/b.out")" = selected ] \
  || fail "the route did not mark its session as selected"
case "$(sed -n 's/^target=//p' "$TMP_ROOT/b.out")" in default:?*) ;; *) fail "the target is outside the selected session" ;; esac
META_SEL="$HOME_SEL/state/parent-route/$ID.meta"
[ "$(sed -n 's/^herdr_session=//p' "$META_SEL")" = default ] || fail "the endpoint record names another session"
assert_no_grep 'session fm-remote' "$TMP_ROOT/herdr.log" "the selected launch reached the fm-remote session"
assert_grep 'session default' "$TMP_ROOT/herdr.log" "the selected launch never addressed the selected session"
[ "$(ctl "$ACCT_SEL" "$HOME_SEL" state "$ID")" = alive ] || fail "the selected endpoint did not read alive"
ctl "$ACCT_SEL" "$HOME_SEL" route "$ID" | grep -q '^herdr_session_source=selected$' || fail "route lost the selection marker"
# A sibling mate in the same selected session, to prove retire touches only its own panes.
SIB=sm-sib
HOME_SIB=$(seed_home "$SIB")
launch "$ACCT_SEL" "$HOME_SIB" "$SIB" > "$TMP_ROOT/sib.out" 2>&1 || fail "the sibling launch failed"$'\n'"$(cat "$TMP_ROOT/sib.out")"
SIB_PANE=$(sed -n 's/^target=default://p' "$TMP_ROOT/sib.out")
ctl "$ACCT_SEL" "$HOME_SEL" retire "$ID" --force > "$TMP_ROOT/retire.out" 2>&1 \
  || fail "retire in the selected session failed"$'\n'"$(cat "$TMP_ROOT/retire.out")"
[ "$(jq -r --arg p "$SIB_PANE" '[.tabs[]|select(.pane_id==$p)]|length' "$TMP_ROOT/herdr.state")" = 1 ] \
  || fail "retire closed the sibling mate's pane"
SEL_PANE=$(sed -n 's/^target=default://p' "$TMP_ROOT/b.out")
[ "$(jq -r --arg p "$SEL_PANE" '[.tabs[]|select(.pane_id==$p)]|length' "$TMP_ROOT/herdr.state")" = 0 ] \
  || fail "retire left the retired mate's own pane open"
assert_no_regex 'server stop|session stop' "$TMP_ROOT/herdr.log" "retire stopped a Herdr server or session"
pass "B launch, route, state, and retire use the selected session, retire closes only its own pane and stops nothing"

# --- C) an unusable selection refuses ------------------------------------------

# HOME_PLAIN holds a real endpoint record, so route and state reach the
# selection check instead of stopping at a missing record.
check_bad() { # <label> <account>
  local label=$1 acct=$2
  if ctl "$acct" "$HOME_PLAIN" launch sm-plain omp anthropic/claude-test high herdr > "$TMP_ROOT/c.out" 2>&1; then
    fail "$label: launch accepted an unusable selection"
  fi
  grep -q 'remote-herdr-session' "$TMP_ROOT/c.out" || fail "$label: launch did not name the selection file"$'\n'"$(cat "$TMP_ROOT/c.out")"
  if ctl "$acct" "$HOME_PLAIN" route sm-plain > "$TMP_ROOT/c.out" 2>&1; then
    fail "$label: route accepted an unusable selection"
  fi
  grep -q 'remote-herdr-session' "$TMP_ROOT/c.out" || fail "$label: route did not name the selection file"$'\n'"$(cat "$TMP_ROOT/c.out")"
  ctl "$acct" "$HOME_PLAIN" state sm-plain > "$TMP_ROOT/c.out" 2> "$TMP_ROOT/c.err"
  [ "$(cat "$TMP_ROOT/c.out")" = unverified ] || fail "$label: state did not read unverified: $(cat "$TMP_ROOT/c.out")"
  grep -q 'remote-herdr-session' "$TMP_ROOT/c.err" || fail "$label: state did not name the selection file"$'\n'"$(cat "$TMP_ROOT/c.err")"
}
bad_n=0
for bad in fm-remote fm-remote-0123456789abcdef 'two words' '-leading' ''; do
  bad_n=$((bad_n + 1))
  acct=$(new_account "bad-$bad_n" "$bad")
  [ -n "$bad" ] || : > "$acct/.firstmate/remote-herdr-session"
  check_bad "value '$bad'" "$acct"
done
acct=$(new_account bad-two)
printf 'default\nother\n' > "$acct/.firstmate/remote-herdr-session"
check_bad "two lines" "$acct"
acct=$(new_account bad-link)
printf 'default\n' > "$TMP_ROOT/real-selection"
ln -s "$TMP_ROOT/real-selection" "$acct/.firstmate/remote-herdr-session"
check_bad "a symlink" "$acct"
pass "C an unusable selection file refuses launch and route and reads state unverified, naming the file"

# --- D) another session's route is refused while one is selected ---------------

ID=sm-moved
HOME_MOVED=$(seed_home "$ID")
ACCT_MOVED=$(new_account moved default)
launch "$ACCT_MOVED" "$HOME_MOVED" "$ID" > "$TMP_ROOT/d.out" 2>&1 || fail "the pre-move launch failed"$'\n'"$(cat "$TMP_ROOT/d.out")"
META_MOVED="$HOME_MOVED/state/parent-route/$ID.meta"
cp "$META_MOVED" "$TMP_ROOT/meta.moved"
sed -e "s|^herdr_session=.*|herdr_session=fm-remote|" -e "s|^window=default:|window=fm-remote:|" "$TMP_ROOT/meta.moved" > "$META_MOVED"
if ctl "$ACCT_MOVED" "$HOME_MOVED" route "$ID" > "$TMP_ROOT/d.out" 2>&1; then
  fail "a selected-session account accepted an endpoint recorded in fm-remote"
fi
assert_grep "expected 'default'" "$TMP_ROOT/d.out" "the refusal did not name the selected session"
cp "$TMP_ROOT/meta.moved" "$META_MOVED"
pass "D a route recorded in another session is refused while one is selected"

# --- E) launch and relaunch refuse beside a live lock holder --------------------

start_agent() { # <home> -> sets AGENT_PID; a live "claude" whose cwd is <home>
  ( cd "$1" && exec "$HARNESS_BIN/claude" . "$AGENT_FIFO" ) &
  AGENT_PID=$!
  LIVE_PIDS+=("$AGENT_PID")
}
write_lock() { # <home> <pid> <session-id>
  mkdir -p "$1/state"
  printf '%s\n' "$2" > "$1/state/.lock"
  [ -z "${3:-}" ] || printf '%s\n' "$3" > "$1/state/.lock-session"
}

ID=sm-live
HOME_LIVE=$(seed_home "$ID")
ACCT_LIVE=$(new_account live default)
launch "$ACCT_LIVE" "$HOME_LIVE" "$ID" > "$TMP_ROOT/e.out" 2>&1 || fail "the pre-lock launch failed"$'\n'"$(cat "$TMP_ROOT/e.out")"
# The mate's endpoint goes away (its pane closes) while its agent lives on elsewhere.
LIVE_PANE=$(sed -n 's/^target=default://p' "$TMP_ROOT/e.out")
jq --arg p "$LIVE_PANE" '.tabs |= [.[]|select(.pane_id != $p)] | .typed |= with_entries(select(.key != $p))' \
  "$TMP_ROOT/herdr.state" > "$TMP_ROOT/herdr.state.new" && mv "$TMP_ROOT/herdr.state.new" "$TMP_ROOT/herdr.state"
start_agent "$HOME_LIVE"
write_lock "$HOME_LIVE" "$AGENT_PID" live-session-1
TABS_BEFORE=$(jq -c '.tabs' "$TMP_ROOT/herdr.state")
if launch "$ACCT_LIVE" "$HOME_LIVE" "$ID" > "$TMP_ROOT/e.out" 2>&1; then
  fail "launch started a second agent beside a live lock holder"
fi
assert_grep "state/.lock names live process $AGENT_PID" "$TMP_ROOT/e.out" "launch did not name the live holder"
assert_grep 'adopt' "$TMP_ROOT/e.out" "launch did not point at adopt"
[ "$(jq -c '.tabs' "$TMP_ROOT/herdr.state")" = "$TABS_BEFORE" ] || fail "a refused launch changed the Herdr panes"
if ctl "$ACCT_LIVE" "$HOME_LIVE" relaunch "$ID" omp anthropic/claude-test high > "$TMP_ROOT/e.out" 2>&1; then
  fail "relaunch started a second agent beside a live lock holder"
fi
assert_grep "state/.lock names live process $AGENT_PID" "$TMP_ROOT/e.out" "relaunch did not name the live holder"
assert_grep 'adopt' "$TMP_ROOT/e.out" "relaunch did not point at adopt"
[ "$(jq -c '.tabs' "$TMP_ROOT/herdr.state")" = "$TABS_BEFORE" ] || fail "a refused relaunch changed the Herdr panes"
# A stale lock (the process is gone) does not block a launch.
kill "$AGENT_PID" 2>/dev/null || true
timeout 10 bash -c "while kill -0 $AGENT_PID 2>/dev/null; do sleep 0.1; done"
launch "$ACCT_LIVE" "$HOME_LIVE" "$ID" > "$TMP_ROOT/e.out" 2>&1 \
  || fail "a stale lock blocked a launch"$'\n'"$(cat "$TMP_ROOT/e.out")"
pass "E launch and relaunch refuse beside a live lock holder and point at adopt; a stale lock does not block"

# --- F) adopt -----------------------------------------------------------------

# A read-only fake Herdr: one session, panes with agent registrations, process
# info, and nothing that can start, stop, or write anything.
ADOPT_BIN="$TMP_ROOT/adopt-bin"
ADOPT_DIR="$TMP_ROOT/adopt-fake"
mkdir -p "$ADOPT_BIN" "$ADOPT_DIR"
cat > "$ADOPT_BIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_ADOPT_DIR
printf '%s\n' "$*" >> "$D/log"
args=("$@")
pane=""
for ((i=0; i<${#args[@]}; i++)); do [ "${args[$i]}" = --pane ] && pane=${args[$((i+1))]:-}; done
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":%s,"socket":"%s"}}\n' "$(cat "$D/running")" "$D/sock" ;;
  "pane list") jq '{result:{panes:[.panes[]|{pane_id}]}}' "$D/panes.json" ;;
  "agent get")
    jq --arg p "${3:-}" 'first(.panes[]|select(.pane_id==$p)) as $x
      | if $x == null then {error:{code:"agent_not_found"}}
        else {result:{agent:{agent:$x.agent, agent_status:"idle", agent_session:{kind:"id", value:$x.session}}}} end' "$D/panes.json" ;;
  "pane get")
    jq --arg p "${3:-}" 'first(.panes[]|select(.pane_id==$p)) as $x
      | if $x == null then {error:{code:"pane_not_found"}}
        else {result:{pane:{pane_id:$x.pane_id, tab_id:$x.tab_id, workspace_id:$x.workspace_id}}} end' "$D/panes.json" ;;
  "pane process-info")
    jq --arg p "$pane" 'first(.panes[]|select(.pane_id==$p)) as $x
      | {result:{type:"pane_process_info", process_info:{pane_id:$p, shell_pid:$x.shell_pid,
         foreground_process_group_id:$x.shell_pid,
         foreground_processes:[{pid:$x.fg_pid, name:"claude", argv0:"claude", argv:["claude"], cmdline:"claude"}]}}}' "$D/panes.json" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$ADOPT_BIN/herdr"
ln -sf "$(command -v jq)" "$ADOPT_BIN/jq"
ln -sf "$(command -v git)" "$ADOPT_BIN/git"

adopt_ctl() { # <account> <home> <args...>
  local acct=$1 home=$2
  shift 2
  PATH="$ADOPT_BIN:$BASE_PATH" FM_FAKE_ADOPT_DIR="$ADOPT_DIR" TMUX='' FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    HOME="$acct" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" "$@"
}

ID=sm-adopt
SID=b3ba97e9-bcd8-4d07-af30-1e71b5ecd936
HOME_AD=$(seed_home "$ID")
ACCT_AD=$(new_account adopt default)
mkdir -p "$HOME_AD/state/parent-route" "$HOME_AD/data/.parent-route"
META_AD="$HOME_AD/state/parent-route/$ID.meta"
write_old_meta() {
  fm_write_meta "$META_AD" \
    "window=fm-remote:w9:p9" "endpoint_task_id=$ID" "worktree=$HOME_AD" "project=$ROOT" \
    "harness=claude" "kind=secondmate" "mode=secondmate" "yolo=off" "tasktmp=" \
    "model=" "effort=" "backend=herdr" "herdr_session=fm-remote" "herdr_workspace_id=w9" \
    "herdr_tab_id=w9:t9" "herdr_pane_id=w9:p9" "proc_root=4242" "proc_root_id=old" "home=$HOME_AD" "projects="
  cp "$META_AD" "$TMP_ROOT/meta.ad.orig"
}
start_agent "$HOME_AD"
AD_PID=$AGENT_PID
write_lock "$HOME_AD" "$AD_PID" "$SID"
printf 'true\n' > "$ADOPT_DIR/running"
write_panes() { # <agent> <session-id> <shell-pid>
  jq -n --arg agent "$1" --arg sid "$2" --argjson shell "$3" --argjson fg "$AD_PID" \
    '{panes:[{pane_id:"wXA:p2", tab_id:"wXA:t2", workspace_id:"wXA", agent:$agent, session:$sid, shell_pid:$shell, fg_pid:$fg},
             {pane_id:"wXA:p3", tab_id:"wXA:t3", workspace_id:"wXA", agent:"claude", session:"other-session", shell_pid:$shell, fg_pid:1}]}' \
    > "$ADOPT_DIR/panes.json"
}
write_panes claude "$SID" "$$"
write_old_meta

# Refusals first: each leaves the record byte-identical and runs nothing.
expect_refusal() { # <label> <expected-text> <adopt-args...>
  local label=$1 want=$2
  shift 2
  if adopt_ctl "$ACCT_AD" "$HOME_AD" adopt "$@" > "$TMP_ROOT/f.out" 2>&1; then
    fail "adopt accepted: $label"$'\n'"$(cat "$TMP_ROOT/f.out")"
  fi
  grep -q -- "$want" "$TMP_ROOT/f.out" || fail "adopt's refusal for '$label' did not say why"$'\n'"$(cat "$TMP_ROOT/f.out")"
  cmp -s "$META_AD" "$TMP_ROOT/meta.ad.orig" || fail "a refused adopt ($label) changed the endpoint record"
}
expect_refusal "an agent session no pane holds" 'no pane in Herdr session' "$ID" no-such-session
write_panes omp "$SID" "$$"
expect_refusal "a pane whose agent is another harness" "the record for $ID says harness" "$ID" "$SID"
write_panes claude "$SID" "$$"
printf 'false\n' > "$ADOPT_DIR/running"
expect_refusal "a session whose server is not running" 'is not running; adopt never starts one' "$ID" "$SID"
printf 'true\n' > "$ADOPT_DIR/running"
write_lock "$HOME_AD" "$AD_PID" other-session
expect_refusal "a lock sidecar naming another agent session" 'names agent session' "$ID" "$SID"
write_lock "$HOME_AD" "$AD_PID" "$SID"
edit_panes() { # <jq-filter>
  jq "$1" "$ADOPT_DIR/panes.json" > "$ADOPT_DIR/p.new" && mv "$ADOPT_DIR/p.new" "$ADOPT_DIR/panes.json"
}
# The lock holder is neither the pane's shell, a foreground process, nor a descendant of its shell.
edit_panes '.panes[0].shell_pid = 999999 | .panes[0].fg_pid = 1'
expect_refusal "a lock holder outside the pane" 'is not inside pane' "$ID" "$SID"
write_panes claude "$SID" "$$"
OTHER_HOME=$(seed_home sm-elsewhere)
start_agent "$OTHER_HOME"
write_lock "$HOME_AD" "$AGENT_PID" "$SID"
jq --argjson fg "$AGENT_PID" '.panes[0].fg_pid = $fg' "$ADOPT_DIR/panes.json" > "$ADOPT_DIR/p.new" && mv "$ADOPT_DIR/p.new" "$ADOPT_DIR/panes.json"
expect_refusal "a lock holder running outside the mate's home" 'not this home' "$ID" "$SID"
write_lock "$HOME_AD" "$AD_PID" "$SID"
write_panes claude "$SID" "$$"
rm -f "$HOME_AD/state/.lock-session"
expect_refusal "a missing lock sidecar" 'cannot be proven' "$ID" "$SID"
write_lock "$HOME_AD" "$AD_PID" "$SID"
printf 'not-a-pid\n' > "$HOME_AD/state/.lock"
expect_refusal "a lock that names no live harness" 'does not name a live harness process' "$ID" "$SID"
write_lock "$HOME_AD" "$AD_PID" "$SID"
# An endpoint that is still alive is a second agent, not a rebind.
edit_panes ".panes += [{pane_id:\"w9:p9\", tab_id:\"w9:t9\", workspace_id:\"w9\", agent:\"claude\", session:\"old\", shell_pid:$$, fg_pid:$AD_PID}]"
expect_refusal "a recorded endpoint that is still alive" 'is still alive' "$ID" "$SID"
write_panes claude "$SID" "$$"
grep -Eq 'server (stop|start)|session (stop|start)|agent start|pane (run|send|close)|workspace (create|close)' "$ADOPT_DIR/log" \
  && fail "a refused adopt ran a lifecycle or write command on Herdr"
adopt_ctl "$ACCT_AD" "$HOME_AD" adopt "$ID" >/dev/null 2>&1 && fail "adopt accepted a missing agent session argument"

# The accepted bind.
: > "$ADOPT_DIR/log"
adopt_ctl "$ACCT_AD" "$HOME_AD" adopt "$ID" "$SID" > "$TMP_ROOT/f.out" 2> "$TMP_ROOT/f.err" \
  || fail "adopt refused a fully proven live agent"$'\n'"$(cat "$TMP_ROOT/f.err")"
[ "$(sed -n 's/^target=//p' "$TMP_ROOT/f.out")" = default:wXA:p2 ] || fail "adopt reported the wrong target"$'\n'"$(cat "$TMP_ROOT/f.out")"
[ "$(sed -n 's/^herdr_session=//p' "$TMP_ROOT/f.out")" = default ] || fail "adopt reported the wrong session"
[ "$(sed -n 's/^herdr_session_source=//p' "$TMP_ROOT/f.out")" = selected ] || fail "adopt dropped the selection marker"
assert_line 'window=default:wXA:p2' "$META_AD" "the record's window was not rebound"
assert_line 'herdr_session=default' "$META_AD" "the record's session was not rebound"
assert_line 'herdr_workspace_id=wXA' "$META_AD" "the record's workspace was not rebound"
assert_line 'herdr_tab_id=wXA:t2' "$META_AD" "the record's tab was not rebound"
assert_line 'herdr_pane_id=wXA:p2' "$META_AD" "the record's pane was not rebound"
assert_no_regex '^proc_root' "$META_AD" "the dead endpoint's process identity survived the rebind"
assert_line 'harness=claude' "$META_AD" "an unrelated record field changed"
assert_line "endpoint_task_id=$ID" "$META_AD" "the task binding changed"
grep -Eq 'server (stop|start)|session (stop|start)|agent start|pane (run|send|close)|workspace (create|close)' "$ADOPT_DIR/log" \
  && fail "adopt ran a lifecycle or write command on Herdr"
[ "$(cat "$HOME_AD/state/.lock")" = "$AD_PID" ] || fail "adopt touched the agent's lock"
kill -0 "$AD_PID" 2>/dev/null || fail "adopt stopped the running agent"
# The adopted route now reads through the ordinary verbs.
adopt_ctl "$ACCT_AD" "$HOME_AD" route "$ID" > "$TMP_ROOT/f.route" 2>&1 || fail "the adopted route does not validate"$'\n'"$(cat "$TMP_ROOT/f.route")"
pass "F adopt binds a fully proven live agent without starting or stopping anything, and every missing proof refuses with the record untouched"

echo "ALL TESTS PASSED"
