#!/usr/bin/env bash
# tests/fm-fleet-ledger-remote.test.sh - the task.dispatched record a parent
# writes for a second mate it launches on another host. docs/fleet-ledger.md
# owns the record contract: such a record carries the requested effort, or
# "default", and skills_commit "unknown", because the dispatcher cannot read the
# remote host's skills. The assertions drive the real chain - parent fm-spawn ->
# fm-on -> the real remote entrypoint -> the remote host's own fm-spawn -
# against a fake herdr CLI, with a readable skills directory on the parent so a
# record that read the dispatcher's own skills would show a hash instead.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-fleet-ledger-remote)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
CLAIMS="$TMP_ROOT/claims"
SKILLS="$TMP_ROOT/parent-skills"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" \
  "$REMOTE_ROOT" "$CLAIMS" "$SKILLS/alpha"
trap 'FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true; if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then kill "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" 2>/dev/null || true; fi; chmod -R u+w -- "$TMP_ROOT" 2>/dev/null; rm -rf -- "$TMP_ROOT"' EXIT
printf 'parent skill\n' > "$SKILLS/alpha/SKILL.md"


# The remote host's tracked code root is this branch, as a real git repository:
# fm-on and the remote entrypoint both require the dispatched command to be
# tracked there, and the remote side runs the real scripts under test.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)

# The remote host's own non-second-mate tooling only has to stay resolvable;
# the second mate itself always launches on Herdr, whose fixture logs every
# invocation verbatim.
cat > "$REMOTE_ROOT/bin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/tmux"
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
# The readiness gate is answered here rather than by the real doctor, which
# would inspect the RUNNER's own account; tests/fm-remote-doctor.test.sh owns
# the doctor's behavior against controlled account fixtures.
if printf '%s' "$4" | base64 --decode 2>/dev/null | tr '\0' '\n' | head -1 | grep -q '^fm-remote-doctor.sh$'; then
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

printf 'codex\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
printf 'codex\n' > "$PARENT/config/crew-harness"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$PARENT/data/backlog.md"
printf '%s\n' "$$" > "$PARENT/state/.lock"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_SKILLS_DIR="$SKILLS" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$@"
}

FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" --no-projects >/dev/null \
  || fail "remote seed did not provision the route under test"
: > "$PARENT/config/fleet-ledger"

remote_dispatched_fields() {  # [spawn args...]: launch, then print the new record's effort and skills_commit
  local out
  reset_remote_herdr_fixture "$HERDR_STATE"
  : > "$HERDR_LOG"
  rm -f "$PARENT/state/fleet-ledger.jsonl"
  out=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate "$@" 2>&1) \
    || fail "the remote second-mate launch failed: $out"
  assert_contains "$out" 'remote=remote-mac' "the launch did not take the remote route"
  jq -c 'select(.event == "task.dispatched") | [.task, .kind, .effort, .skills_commit]' "$PARENT/state/fleet-ledger.jsonl"
}

assert_equals '["ios","secondmate","high","unknown"]' "$(remote_dispatched_fields --effort high)" \
  "a remote second mate launched with --effort high"
pass "a remote second mate records its requested effort and unknown skills, not the dispatcher's"

assert_equals '["ios","secondmate","default","unknown"]' "$(remote_dispatched_fields)" \
  "a remote second mate launched without an effort"
pass "a remote second mate launched without an effort records effort default"

echo "ALL TESTS PASSED"
