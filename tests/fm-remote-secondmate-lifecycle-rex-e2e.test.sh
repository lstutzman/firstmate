#!/usr/bin/env bash
# Remote secondmate lifecycle on the rex backend and through retirement, over the deterministic
# generic SSH boundary. The herdr-route half is tests/fm-remote-secondmate-lifecycle-e2e.test.sh;
# both share tests/remote-secondmate-lifecycle-fixture.sh.
set -u
# Nothing here reads the caller's stdin, but remote job staging reads its stdin
# to EOF, so an inherited open pipe would park a job in `head` indefinitely.
exec </dev/null

# shellcheck source=tests/remote-secondmate-lifecycle-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-secondmate-lifecycle-fixture.sh"

# The rex cases start from a registered remote route already launched on herdr.
seed_remote_ios_route
printf 'pi\n' > "$PARENT/config/crew-harness"
spawn_remote_ios_on_herdr

# A remote may instead run a rex second mate on that host's persistent personal
# rex server: the parent asks for the backend explicitly, and the remote home's
# own control script launches, states, and reports the rex route.
remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-rex.meta"
cp "$PARENT/state/ios.meta" "$TMP_ROOT/parent-ios-before-rex.meta"

# A remote still on the herdr-only doctor exits 2 on --backend: a herdr request
# retries bare, a rex request does not, because that remote cannot run rex.
FM_FAKE_SSH_MODE=doctor-old remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate --backend herdr >/dev/null \
  || fail "a herdr spawn did not survive the old remote doctor's --backend refusal"
assert_grep 'remote_backend=herdr' "$PARENT/state/ios.meta" \
  "the old-doctor herdr spawn did not record its backend"
cp "$PARENT/state/ios.meta" "$TMP_ROOT/parent-ios-before-old-rex.meta"
if FM_FAKE_SSH_MODE=doctor-old remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate --backend rex \
  >"$TMP_ROOT/spawn-rex-old-doctor.out" 2>&1; then
  fail "a rex spawn was accepted by a remote too old to select its backend"
fi
assert_grep 'not ready' "$TMP_ROOT/spawn-rex-old-doctor.out" \
  "the old-doctor rex refusal did not come from readiness"
cmp -s "$TMP_ROOT/parent-ios-before-old-rex.meta" "$PARENT/state/ios.meta" \
  || fail "the refused rex spawn rewrote the recorded route"

# An explicit backend outside {herdr, rex} is refused before any remote call.
ssh_before=$(cat "$SSH_COUNT")
if remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate --backend tmux >"$TMP_ROOT/spawn-tmux-backend.out" 2>&1; then
  fail "an unknown remote backend was accepted"
fi
assert_grep 'runs only on the herdr or rex backend' "$TMP_ROOT/spawn-tmux-backend.out" \
  "an unknown remote backend did not fail with the backend refusal"
[ "$(cat "$SSH_COUNT")" = "$ssh_before" ] || fail "an unknown remote backend still made a remote call"

# A rex route reply that breaks the contract at the parent boundary is refused
# and leaves the recorded route untouched: a non-local server, or a target
# whose session half is not the reported session.
cp "$PARENT/state/ios.meta" "$TMP_ROOT/parent-ios-pre-launch.meta"
if FM_FAKE_SSH_MODE=launch-rex-bad-server-route remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate --backend rex \
  >"$TMP_ROOT/spawn-rex-bad-server.out" 2>&1; then
  fail "a rex route naming a non-local server was accepted"
fi
assert_grep 'malformed Rex route metadata' "$TMP_ROOT/spawn-rex-bad-server.out" \
  "a non-local rex server route did not fail with the rex metadata refusal"
cmp -s "$TMP_ROOT/parent-ios-pre-launch.meta" "$PARENT/state/ios.meta" \
  || fail "a refused rex server route rewrote the recorded route"
if FM_FAKE_SSH_MODE=launch-rex-mismatched-route remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate --backend rex \
  >"$TMP_ROOT/spawn-rex-mismatched.out" 2>&1; then
  fail "a rex route whose target did not match its session was accepted"
fi
assert_grep 'malformed Rex route metadata' "$TMP_ROOT/spawn-rex-mismatched.out" \
  "a session-mismatched rex route did not fail with the rex metadata refusal"
cmp -s "$TMP_ROOT/parent-ios-pre-launch.meta" "$PARENT/state/ios.meta" \
  || fail "a refused rex session route rewrote the recorded route"
pass "remote secondmate backend selection is strict on both sides of the boundary"

# The remote host itself launches on rex: with no recorded endpoint (a
# never-launched route) the remote control script runs the host-local spawn on
# the remote's own rex server and both sides record the rex route.
install_remote_rex_fixture "$REMOTE_ROOT" "$REX_FAKE" "unix://$REX_FAKE/rex.sock" codex
rm -f "$remote_route_meta"
remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate --backend rex >/dev/null \
  || fail "a remote rex secondmate launch was refused"
assert_grep 'remote_backend=rex' "$PARENT/state/ios.meta" "the rex launch did not record its backend"
assert_grep 'remote_rex_session_id=session:' "$PARENT/state/ios.meta" "the rex launch did not record its session"
assert_grep 'remote_rex_server=unix://' "$PARENT/state/ios.meta" "the rex launch did not record its server"
assert_grep 'remote_target=' "$PARENT/state/ios.meta" "the rex launch did not record its target"
assert_grep 'backend=rex' "$remote_route_meta" "the remote endpoint record did not record the rex backend"
assert_grep 'rex_server=unix://' "$remote_route_meta" "the remote endpoint record did not record the rex server"
assert_grep 'rex_session_id=session:' "$remote_route_meta" "the remote endpoint record did not record the rex session"
[ "$(jq '[.sessions[] | select((.windows[0].blocks | length) > 0)] | length' "$REX_FAKE/state.json")" -ge 1 ] \
  || fail "the remote rex launch did not create its own session"
jq -e '.sessions[] | select(.label | startswith("2ndmate-ios-"))' "$REX_FAKE/state.json" >/dev/null \
  || fail "the remote rex launch did not use the secondmate home's per-home session"
assert_grep ' send -s ' "$REX_FAKE/log" "the remote rex launch did not deliver its launch text"
assert_grep 'fm-ios' "$REX_FAKE/sent" "the remote rex launch delivered no launch-source text"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "the rex endpoint was not projected alive from its own host"
route=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh route ios)
assert_contains "$route" 'backend=rex' "the remote route did not report rex"
assert_contains "$route" 'rex_session_id=session:' "the remote route did not report its rex session"
assert_contains "$route" 'rex_server=unix://' "the remote route did not report its rex server"
pass "the remote control plane launches, states, and reports a rex route"

# A rex route pinned to a server that is not this host's local unix socket is
# refused by every verb and classified unverified by the state probe.
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-rex-good.meta"
awk '/^rex_server=/{print "rex_server=tcp://127.0.0.1:7299"; next} {print}' \
  "$remote_route_meta" > "$remote_route_meta.new"
mv -f "$remote_route_meta.new" "$remote_route_meta"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = unverified ] \
  || fail "a non-local rex server record was not classified unverified"
if remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh route ios >/dev/null 2>&1; then
  fail "a non-local rex server record stayed operational for route"
fi
if remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh launch ios codex - - rex >/dev/null 2>&1; then
  fail "a non-local rex server record accepted a launch"
fi
mv -f "$TMP_ROOT/remote-ios-rex-good.meta" "$remote_route_meta"

# The parent's startup liveness probe keeps a live rex route alive and reports
# a recorded/remote backend mismatch instead of migrating it.
BOOT_REX=$(remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_not_contains "$BOOT_REX" 'SECONDMATE_LIVENESS: secondmate ios:' \
  "the full sweep did not keep the live rex route alive"
cp "$PARENT/state/ios.meta" "$TMP_ROOT/parent-ios-rex-good.meta"
awk '/^remote_backend=/{print "remote_backend=herdr"; next} {print}' \
  "$PARENT/state/ios.meta" > "$PARENT/state/ios.meta.new"
mv -f "$PARENT/state/ios.meta.new" "$PARENT/state/ios.meta"
BOOT_DRIFT=$(remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_contains "$BOOT_DRIFT" "runs on backend 'rex', but this home recorded 'herdr'" \
  "the full sweep did not report the recorded/remote backend drift"
mv -f "$TMP_ROOT/parent-ios-rex-good.meta" "$PARENT/state/ios.meta"

# A named key reaches the rex endpoint through its recorded route: the parent's
# fm-send crosses to the remote key verb, which must address the rex block from
# that host's endpoint record rather than as a bare tmux-looking target.
: > "$REX_FAKE/keys"
remote_env "$ROOT/bin/fm-send.sh" fm-ios --key Escape >"$TMP_ROOT/send-rex-key.out" 2>&1 \
  || fail "a key was not sent to the remote rex secondmate: $(cat "$TMP_ROOT/send-rex-key.out")"
grep -qx escape "$REX_FAKE/keys" || fail "the remote rex endpoint never received the Escape key"
pass "a key reaches a remote rex secondmate through its recorded endpoint"

# Recovery keeps the recorded backend: once the rex agent exits, the startup
# sweep relaunches the mate on rex again, never on the herdr default.
rex_target_before=$(sed -n 's/^remote_target=//p' "$PARENT/state/ios.meta" | tail -1)
herdr_launches_before=$(grep -c '^tab create' "$HERDR_LOG" || true)
rm -f "$REX_FAKE/agent-blocks"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = dead ] \
  || fail "the exited rex agent was not projected dead from its own host"
BOOT_REX_DEAD=$(FM_BOOTSTRAP_VERBOSE_FACTS=1 remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_not_contains "$BOOT_REX_DEAD" 'SECONDMATE_LIVENESS: secondmate ios:' \
  "the dead rex secondmate was not relaunched cleanly"
assert_contains "$BOOT_REX_DEAD" 'secondmate ios relaunched after remote endpoint dead' \
  "the dead rex secondmate was not reported relaunched"
assert_grep 'remote_backend=rex' "$PARENT/state/ios.meta" "recovery moved the rex secondmate off its recorded backend"
assert_grep 'backend=rex' "$remote_route_meta" "recovery rewrote the remote endpoint onto another backend"
[ "$(sed -n 's/^remote_target=//p' "$PARENT/state/ios.meta" | tail -1)" != "$rex_target_before" ] \
  || fail "recovery did not record a fresh rex endpoint"
[ "$(grep -c '^tab create' "$HERDR_LOG" || true)" = "$herdr_launches_before" ] \
  || fail "recovery launched the rex secondmate into herdr"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "the relaunched rex endpoint did not read alive"
pass "liveness recovery relaunches a remote rex secondmate on rex"

# A stopped remote rex server stays stopped under every control-plane probe:
# Rex starts a missing server as exit-empty, which remote readiness refuses and
# cannot repair while it answers. Once a persistent server is started, the
# startup sweep relaunches the mate on it.
"$REMOTE_ROOT/bin/rex" server stop >/dev/null || fail "the fake remote rex server did not stop"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = unreadable ] \
  || fail "a stopped remote rex server was not projected unreadable"
if remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh launch ios codex - - rex >/dev/null 2>&1; then
  fail "a launch over a stopped remote rex server was accepted"
fi
[ -f "$REX_FAKE/down" ] || fail "a remote control-plane probe started the stopped rex server"
"$REMOTE_ROOT/bin/rex" server start >/dev/null || fail "the fake remote rex server did not start"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = missing ] \
  || fail "the restarted rex server did not prove the old block missing"
BOOT_REX_RESTARTED=$(FM_BOOTSTRAP_VERBOSE_FACTS=1 remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_contains "$BOOT_REX_RESTARTED" 'secondmate ios relaunched after remote endpoint missing' \
  "the rex secondmate was not relaunched onto the restarted persistent server"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "the rex secondmate relaunched onto the restarted server did not read alive"
pass "remote rex control-plane probes never start a stopped server, and recovery follows a persistent start"

# Retirement contract: neither close nor home deletion is authorized without
# an answering server whose identity matches the launch record. Exercise both
# ordinary and forced retirement; observing only a refusal would miss a close
# that happened before the refusal.
cp "$REX_FAKE/state.json" "$TMP_ROOT/rex-before-refused-retire.json"
for server_failure in repointed unreadable unreachable; do
  case "$server_failure" in
    repointed) printf 'unix:///other/rex.sock\n' > "$REX_FAKE/endpoint" ;;
    unreadable) touch "$REX_FAKE/whoami-fail" ;;
    unreachable) touch "$REX_FAKE/unreachable" ;;
  esac
  for retire_force in '' --force; do
    : > "$REX_FAKE/log"
    if remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh retire ios ${retire_force:+"$retire_force"} \
      > "$TMP_ROOT/rex-refused-retire.out" 2>&1; then
      fail "rex retirement accepted $server_failure server ($retire_force)"
    fi
    assert_present "$REMOTE_HOME" "refused rex retirement deleted the home"
    assert_grep 'restore access to the recorded Rex server' "$TMP_ROOT/rex-refused-retire.out" \
      "refused rex retirement omitted the human action"
    assert_no_grep 'block close' "$REX_FAKE/log" "refused rex retirement attempted to close the block"
    cmp -s "$TMP_ROOT/rex-before-refused-retire.json" "$REX_FAKE/state.json" \
      || fail "refused rex retirement changed running sessions"
  done
  printf 'unix://%s/rex.sock\n' "$REX_FAKE" > "$REX_FAKE/endpoint"
  rm -f "$REX_FAKE/whoami-fail" "$REX_FAKE/unreachable"
done
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "the rex agent did not survive refused retirement"
pass "rex retirement refuses server drift and unreadable or unreachable identity without closing or deleting"

mv -f "$TMP_ROOT/remote-ios-before-rex.meta" "$remote_route_meta"
mv -f "$TMP_ROOT/parent-ios-before-rex.meta" "$PARENT/state/ios.meta"
pass "a remote secondmate may run on rex with strict route validation both ways"

# Host loss never creates a local replacement. Remove both the published ledger
# and its parent-side cache so the structured-home read degrades explicitly;
# endpoint liveness remains the startup supervisor's concern.
rm -f -- "$REMOTE_HOME/state/home-summary.json"
rm -rf -- "$PARENT/state/secondmate-summary-cache"
launches_before=$(grep -c '^tab create' "$HERDR_LOG" || true)
rm -rf -- "$PARENT/state/.watch.lock"
rm -f -- "$PARENT/state/.last-watcher-beat"
BOOT_UNAVAILABLE=$(FM_FAKE_SSH_MODE=unreachable remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_contains "$BOOT_UNAVAILABLE" 'SECONDMATE_LIVENESS: secondmate ios: skipped: remote host unavailable or endpoint state unknown' \
  "bootstrap did not preserve an unreachable remote endpoint as unknown"
UNAVAILABLE=$(FM_FAKE_SSH_MODE=unreachable remote_env "$ROOT/bin/fm-fleet-snapshot.sh" --json)
printf '%s' "$UNAVAILABLE" | jq -e '.secondmate_current.records | any(.id == "ios"
  and .current.state == "unknown" and .provenance.selected != "structured-home"
  and (.current.reason | test("home ledger.*(timed out|missing|unreadable|invalid)")))' >/dev/null \
  || fail "unreachable no-ledger remote home did not degrade to explicit unknown state"
printf '%s' "$UNAVAILABLE" | jq -e '.tasks[] | select(.id == "ios") | .paths.home.present == null and .endpoint.agent_alive == "unknown"' >/dev/null \
  || fail "unreachable remote endpoint liveness was not left to supervision"
rm -f "$PARENT/state/.wake-queue"
launches_after=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before" -eq "$launches_after" ] || fail "unreachable projection attempted a replacement launch"
assert_present "$PARENT/state/ios.meta" "unreachable readiness removed the parent route metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" "unreachable readiness removed the registry route"
pass "unreachable no-ledger remote state remains explicit with no local respawn or failover"

# Retirement delegates its safety check to the remote home. An in-flight child
# record refuses cleanup and preserves both machines' durable routes.
# A sibling remote secondmate workspace shares fm-remote and must survive every
# refusal and the eventual successful retirement of ios.
# This fixture overrides FM_ROOT for transport, so teardown's root-owned guard
# sees the fixture root rather than the source script path used by fm-send.
publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$REMOTE_ROOT/bin/fm-watch.sh"
resolve_ios_pending
SIBLING_CREATE=$("$REMOTE_ROOT/bin/herdr" workspace create --cwd "$REMOTE_ROOT" \
  --label 2ndmate-macos --no-focus --session fm-remote)
SIBLING_WORKSPACE=$(printf '%s' "$SIBLING_CREATE" | jq -r '.result.workspace.workspace_id')
SIBLING_PANE=$(printf '%s' "$SIBLING_CREATE" | jq -r '.result.root_pane.pane_id')
[ -n "$SIBLING_WORKSPACE" ] && [ "$SIBLING_WORKSPACE" != null ] \
  || fail "the shared-session sibling fixture did not create a workspace"
[ -n "$SIBLING_PANE" ] && [ "$SIBLING_PANE" != null ] \
  || fail "the shared-session sibling fixture did not create a pane"
printf 'kind=ship\n' > "$REMOTE_HOME/state/child.meta"
rm -rf "$PARENT/state/procevent"
: > "$PARENT/state/procevent"
if remote_env "$ROOT/bin/fm-teardown.sh" ios >/dev/null 2>&1; then
  fail "remote retirement ignored in-flight child work"
fi
assert_present "$REMOTE_HOME" "refused remote retirement removed the home"
assert_present "$PARENT/state/ios.meta" "refused remote retirement removed parent metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" "refused remote retirement removed the route"
rm -f "$PARENT/state/procevent"
mkdir "$PARENT/state/procevent"
remote_env "$ROOT/bin/fm-bootstrap.sh" >/dev/null \
  || fail "bootstrap failed while repairing a preserved remote reply source"
assert_present "$PARENT/state/procevent/remote-reply-ios.source" \
  "bootstrap did not repair reply registration after retirement rollback"
resolve_ios_pending
rm -f "$REMOTE_HOME/state/child.meta"
mkdir -p "$PARENT/data/handoff"
ln -s "$TMP_ROOT/missing-outbox-target" "$PARENT/data/handoff/ios.outbox.md"
if remote_env "$ROOT/bin/fm-teardown.sh" ios >/dev/null 2>&1; then
  fail "remote retirement accepted an unsafe backlog outbox"
fi
assert_present "$REMOTE_HOME" "unsafe backlog outbox retirement removed the remote home"
rm -f "$PARENT/data/handoff/ios.outbox.md"
mkdir -p "$TMP_ROOT/external-pending"
printf 'task_id=ios\nphase=resolved\n' > "$TMP_ROOT/external-pending/escape"
mv "$PARENT/state/pending-replies" "$PARENT/state/pending-replies.safe"
ln -s "$TMP_ROOT/external-pending" "$PARENT/state/pending-replies"
if remote_env "$ROOT/bin/fm-teardown.sh" ios >/dev/null 2>&1; then
  fail "remote retirement accepted a symlinked pending-replies directory"
fi
assert_present "$REMOTE_HOME" "unsafe pending-replies retirement removed the remote home"
assert_present "$TMP_ROOT/external-pending/escape" "unsafe retirement removed an external pending reply"
rm -f "$PARENT/state/pending-replies"
mv "$PARENT/state/pending-replies.safe" "$PARENT/state/pending-replies"
retired_wake_corr=$(FM_HOME="$PARENT" bash -c '
  . "$1"
  fm_pending_reply_create "$2" "$2/state" ios "New routed work is in your backlog."
' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$PARENT") \
  || fail "could not seed remote receiver wake retirement state"
retired_wake_rec="$PARENT/state/pending-replies/$retired_wake_corr"
FM_HOME="$PARENT" bash -c '
  . "$1"
  fm_pending_reply_set "$2" phase resolved
  fm_pending_reply_set "$2" delivered_epoch 1
' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$retired_wake_rec" \
  || fail "could not settle remote receiver wake retirement state"
printf 'confirmed:%s\n' "$retired_wake_corr" > "$PARENT/state/.backlog-handoff-ios.wake-pending"
printf '%s\tattempt\n' "$(date +%s)" > "$PARENT/state/.secondmate-relaunch-ios"
printf '%s\tdead\n' "$(date +%s)" > "$PARENT/state/.secondmate-relaunch-bound-ios"
liveness_lock="$PARENT/state/.secondmate-liveness-ios.lock"
# The link is published before the claim finishes; signal only after acquire.
# shellcheck disable=SC2016 # Positional parameters expand in the child shell.
( STATE="$PARENT/state" exec bash -c '. "$1" && fm_lock_acquire_wait "$2" && touch "$3" && exec sleep 120' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$liveness_lock" "$TMP_ROOT/liveness.entered" ) &
liveness_holder_pid=$!
liveness_wait=0
while [ ! -f "$TMP_ROOT/liveness.entered" ]; do
  kill -0 "$liveness_holder_pid" 2>/dev/null || fail "liveness lock holder exited before acquiring the lock"
  liveness_wait=$((liveness_wait + 1))
  [ "$liveness_wait" -le 250 ] || fail "liveness lock holder never acquired the lock"
  sleep 0.02
done
liveness_owner=$liveness_holder_pid
[ "$(cat "$liveness_lock/pid" 2>/dev/null)" = "$liveness_owner" ] \
  || fail "liveness lock holder did not own its acquired lock"
if remote_env "$ROOT/bin/fm-teardown.sh" ios > "$TMP_ROOT/teardown-liveness-busy.out" 2>&1; then
  fail "remote retirement proceeded under an active liveness episode"
fi
assert_grep 'liveness check is in progress for ios' "$TMP_ROOT/teardown-liveness-busy.out" \
  "a liveness-busy retirement did not ask for a retry"
assert_present "$REMOTE_HOME" "a liveness-busy retirement removed the remote home"
assert_present "$PARENT/state/ios.meta" "a liveness-busy retirement removed parent metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" "a liveness-busy retirement removed the registry route"
[ "$(cat "$liveness_lock/pid" 2>/dev/null)" = "$liveness_owner" ] \
  || fail "a liveness-busy retirement removed or took the episode's lock"
kill "$liveness_holder_pid" 2>/dev/null || true
wait "$liveness_holder_pid" 2>/dev/null || true
handoff_lock="$PARENT/state/.backlog-handoff-ios.lock"
FM_HOME="$PARENT" /bin/bash -c '
  . "$1"
  fm_lock_acquire_wait "$2"
  touch "$3"
  while [ ! -f "$4" ]; do sleep 0.02; done
  fm_lock_release "$2"
' _ "$ROOT/bin/fm-wake-lib.sh" "$handoff_lock" "$TMP_ROOT/handoff.entered" \
  "$TMP_ROOT/handoff.release" &
handoff_holder_pid=$!
handoff_wait=0
while [ ! -f "$TMP_ROOT/handoff.entered" ]; do
  kill -0 "$handoff_holder_pid" 2>/dev/null || fail "handoff lock holder exited before acquiring the route lock"
  handoff_wait=$((handoff_wait + 1))
  [ "$handoff_wait" -le 250 ] || fail "handoff lock holder never acquired the route lock"
  sleep 0.02
done
rm -f "$TMUX_STATE" "$TMP_ROOT/launch.entered" "$TMP_ROOT/launch.release"
FM_FAKE_SSH_MODE=launch-block remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-retirement.out" 2>&1 &
spawn_retirement_pid=$!
launch_wait=0
# The respawn performs readiness and inheritance jobs before launch. Allow
# the configured convergence budget, just as for the inheritance barriers.
while [ ! -f "$TMP_ROOT/launch.entered" ]; do
  kill -0 "$spawn_retirement_pid" 2>/dev/null || fail "remote respawn exited before its blocked launch"
  launch_wait=$((launch_wait + 1))
  [ "$launch_wait" -le "$(( ${FM_SECONDMATE_CONVERGENCE_TIMEOUT:-900} * 50 ))" ] || fail "remote respawn never reached its blocked launch"
  sleep 0.02
done
# Both opt-in archives must cover the parent-side records on the real remote path.
touch "$PARENT/config/status-archive"
record_export_root="$TMP_ROOT/record-export"
printf '%s\n' "$record_export_root" > "$PARENT/config/record-export-root"
printf 'working: remote task history\ndone: remote task complete\n' > "$PARENT/state/ios.status"
mkdir -p "$PARENT/state/ios.inbox/handled"
printf 'pending remote steer\n' > "$PARENT/state/ios.inbox/001.msg"
printf 'handled remote steer\n' > "$PARENT/state/ios.inbox/handled/002.msg"
grep '^- ios ' "$PARENT/data/secondmates.md" > "$TMP_ROOT/remote-route.saved"
FM_FAKE_SSH_MODE=retire-lost-slot remote_env "$ROOT/bin/fm-teardown.sh" ios \
  > "$TMP_ROOT/teardown-serialized.out" 2> "$TMP_ROOT/teardown-serialized.err" &
teardown_pid=$!
sleep 0.2
kill -0 "$teardown_pid" 2>/dev/null || fail "remote retirement bypassed an active remote respawn"
assert_present "$REMOTE_HOME" "remote retirement removed the home during an active remote respawn"
touch "$TMP_ROOT/launch.release"
if ! wait_bounded "$spawn_retirement_pid" "the serialized remote respawn"; then
  printf 'serialized respawn output:\n%s\n' "$(cat "$TMP_ROOT/spawn-retirement.out")" >&2
  fail "serialized remote respawn failed"
fi
# Pin the archive fixture generation only after the respawn has finished
# publishing metadata, so the exporter sees exactly one spawn_gen.
awk -F= '$1 != "spawn_gen"' "$PARENT/state/ios.meta" > "$TMP_ROOT/remote-meta.tmp"
printf 'spawn_gen=remote-retirement-test\n' >> "$TMP_ROOT/remote-meta.tmp"
mv -- "$TMP_ROOT/remote-meta.tmp" "$PARENT/state/ios.meta"
cp "$PARENT/state/ios.status" "$TMP_ROOT/remote-status.expected"
cp "$PARENT/state/ios.meta" "$TMP_ROOT/remote-meta.saved"
sleep 0.2
kill -0 "$teardown_pid" 2>/dev/null || fail "remote retirement bypassed an active backlog handoff"
touch "$TMP_ROOT/handoff.release"
wait_bounded "$handoff_holder_pid" "the backlog handoff lock holder" || fail "handoff lock holder failed to release"
teardown_rc=0
wait_bounded "$teardown_pid" "the serialized remote retirement" || teardown_rc=$?
if [ "$teardown_rc" -ne 4 ]; then
  printf 'serialized retirement output:\n%s\n%s\n' "$(cat "$TMP_ROOT/teardown-serialized.out")" \
    "$(cat "$TMP_ROOT/teardown-serialized.err")" >&2
  fail "remote retirement with a lost child slot did not exit 4 (exit $teardown_rc)"
fi
assert_grep 'teardown ios complete (remote ' "$TMP_ROOT/teardown-serialized.out" \
  "remote retirement with a lost child slot did not report its local completion on stdout"
assert_grep 'pool slot 3 (/remote/slot-3) dirty or unverified; the pool lost this slot' "$TMP_ROOT/teardown-serialized.err" \
  "remote retirement did not forward the remote lost-slot warning"
assert_grep 'left-behind-clone' "$TMP_ROOT/teardown-serialized.err" \
  "remote retirement did not forward the lost slot's remaining paths"
assert_no_grep 'teardown ios ' "$TMP_ROOT/teardown-serialized.err" \
  "remote retirement forwarded remote completion text to stderr"
assert_absent "$REMOTE_HOME" "remote retirement did not remove the remote home"
assert_absent "$PARENT/state/ios.meta" "remote retirement did not remove parent metadata"
assert_absent "$PARENT/state/.backlog-handoff-ios.wake-pending" \
  "remote retirement left receiver wake state that could poison a replacement route"
assert_absent "$retired_wake_rec" "remote retirement left the retired receiver wake correlation"
assert_absent "$PARENT/state/.secondmate-relaunch-ios" \
  "remote retirement left the relaunch ledger a same-id replacement would inherit"
assert_absent "$PARENT/state/.secondmate-relaunch-bound-ios" \
  "remote retirement left the relaunch park marker a same-id replacement would inherit"
assert_absent "$liveness_lock" "remote retirement left its liveness lock behind"
assert_no_grep '- ios ' "$PARENT/data/secondmates.md" "remote retirement did not remove the registry route"
jq -e --arg workspace "$SIBLING_WORKSPACE" --arg pane "$SIBLING_PANE" '
  any(.workspaces[]; .workspace_id == $workspace and .label == "2ndmate-macos")
  and any(.tabs[]; .workspace_id == $workspace and .pane_id == $pane)
' "$HERDR_STATE" >/dev/null \
  || fail "remote retirement removed the sibling secondmate workspace or pane from fm-remote"
assert_no_grep 'session stop' "$HERDR_LOG" "remote retirement stopped the shared fm-remote session"
assert_no_grep 'server stop' "$HERDR_LOG" "remote retirement stopped the shared fm-remote server"
pass "remote retirement refuses child work, then removes only its own endpoint while a shared-session sibling survives"
cmp -s "$TMP_ROOT/remote-status.expected" "$PARENT/data/ios/status.log" \
  || fail "remote retirement lost the parent-side status history"
assert_absent "$PARENT/state/ios.status" "remote retirement left the archived status live"
pass "remote retirement archives the complete parent-side status log when enabled"
remote_spawn_gen=$(awk -F= '$1 == "spawn_gen" { print substr($0, index($0, "=") + 1) }' "$TMP_ROOT/remote-meta.saved")
remote_record_archive="$record_export_root/archive/ios/$remote_spawn_gen"
cmp -s "$TMP_ROOT/remote-meta.saved" "$remote_record_archive/meta" \
  || fail "remote retirement lost the parent-side metadata export"
cmp -s "$TMP_ROOT/remote-status.expected" "$remote_record_archive/status" \
  || fail "remote retirement lost the parent-side status export"
assert_grep 'pending remote steer' "$remote_record_archive/inbox/001.msg" \
  "remote retirement lost a pending inbox export"
assert_grep 'handled remote steer' "$remote_record_archive/inbox/handled/002.msg" \
  "remote retirement lost a handled inbox export"
assert_present "$remote_record_archive/manifest.v1.json" "remote retirement did not commit the record export manifest"
pass "remote retirement commits parent-side metadata, status, and inbox records before cleanup"

# Reconcile an already-retired remote home with no parent-side status. Holding
# an unrelated presentation lock proves the no-op without risking an unbounded
# hang if that fast path regresses.
mv "$PARENT/data/ios" "$TMP_ROOT/remote-archive.saved"
cp "$TMP_ROOT/remote-meta.saved" "$PARENT/state/ios.meta"
cat "$TMP_ROOT/remote-route.saved" >> "$PARENT/data/secondmates.md"
mkdir -p "$PARENT/state/.status-presentation-lock"
printf '%s\n' "$$" > "$PARENT/state/.status-presentation-lock/pid"
printf 'neighbor\tidentity\t0\t0\n' > "$PARENT/state/.status-presentation-cursor"
cp "$PARENT/state/.status-presentation-cursor" "$TMP_ROOT/remote-cursor.expected"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
remote_noop_rc=0
remote_env fm_run_timed 60 "$ROOT/bin/fm-teardown.sh" ios \
  > "$TMP_ROOT/remote-noop.out" 2> "$TMP_ROOT/remote-noop.err" || remote_noop_rc=$?
[ "$remote_noop_rc" -eq 0 ] || fail "remote missing-status retirement failed or timed out ($remote_noop_rc): $(cat "$TMP_ROOT/remote-noop.err")"
assert_grep 'teardown ios complete (remote ' "$TMP_ROOT/remote-noop.out" "no-op did not drive remote retirement"
cmp -s "$TMP_ROOT/remote-cursor.expected" "$PARENT/state/.status-presentation-cursor" \
  || fail "remote no-op rewrote the neighboring cursor"
assert_present "$PARENT/state/.status-presentation-lock" "remote no-op acquired another presenter's lock"
assert_absent "$PARENT/data/ios" "remote no-op created an empty archive directory"
assert_absent "$PARENT/state/ios.meta" "remote no-op retained stale parent metadata"
assert_absent "$REMOTE_HOME" "remote no-op recreated the retired remote home"
pass "remote missing-status retirement remains lock-free with archival enabled"

# An absent home accepts exactly the retire dispatcher's arguments, and an
# invalid option still fails with usage instead of reporting a retirement.
remote_control_retire() { # <args...>
  FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
    "$REMOTE_ROOT/bin/fm-remote-secondmate-control.sh" retire "$@"
}
retired_rc=0
remote_control_retire ios --force > "$TMP_ROOT/retired-force.out" 2>&1 || retired_rc=$?
[ "$retired_rc" -eq 0 ] || fail "forced retirement of an absent home failed ($retired_rc): $(cat "$TMP_ROOT/retired-force.out")"
assert_grep 'already-retired: ios' "$TMP_ROOT/retired-force.out" "forced retirement of an absent home was not a no-op"
bogus_rc=0
remote_control_retire ios --bogus > "$TMP_ROOT/retired-bogus.out" 2>&1 || bogus_rc=$?
[ "$bogus_rc" -eq 2 ] || fail "an invalid retire option on an absent home did not fail with usage (exit $bogus_rc)"
assert_grep 'fm-remote-secondmate-control.sh retire <id> [--force]' "$TMP_ROOT/retired-bogus.out" "an invalid retire option did not print usage"
assert_no_grep 'already-retired' "$TMP_ROOT/retired-bogus.out" "an invalid retire option reported a retirement"
assert_absent "$REMOTE_HOME" "retiring an absent home recreated it"
pass "an absent remote home retires only with the dispatcher's arguments and is never recreated"

echo "ALL TESTS PASSED"