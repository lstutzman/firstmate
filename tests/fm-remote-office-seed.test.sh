#!/usr/bin/env bash
# tests/fm-remote-office-seed.test.sh - seeding an office on another host:
# bin/fm-remote-home-seed.sh --office <id> drives the real remote route
# (fm-on.sh -> fm-remote-entrypoint.sh -> fm-remote-home-provision.sh, then
# fm-office.sh publish, arm-status and register-sources in the remote home)
# across the repo's deterministic SSH boundary and checks the remote home the
# way a local office seed is checked: marker, charter, admission copies, project
# tokens, a published authority record the home's gate accepts, registered
# checks, and an empty structured backlog that a re-seed never overwrites.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-office-seed)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
SSH_COUNT="$TMP_ROOT/ssh.count"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config/admission" "$PARENT/projects" "$REMOTE_ROOT"

cleanup() {
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    kill "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" 2>/dev/null || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

# The remote host's tracked code root, a real git repo the provisioning clones.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'

git init -q --bare "$TMP_ROOT/alpha.git"
git -C "$PARENT/projects" init -q -b main alpha
git -C "$PARENT/projects/alpha" config user.email test@example.com
git -C "$PARENT/projects/alpha" config user.name Test
printf 'alpha\n' > "$PARENT/projects/alpha/README.md"
git -C "$PARENT/projects/alpha" add README.md
git -C "$PARENT/projects/alpha" commit -qm init
git -C "$PARENT/projects/alpha" remote add origin "file://$TMP_ROOT/alpha.git"
git -C "$PARENT/projects/alpha" push -q -u origin main
git --git-dir="$TMP_ROOT/alpha.git" symbolic-ref HEAD refs/heads/main
printf -- '- alpha [direct-PR] - alpha project (added 2026-08-04)\n' > "$PARENT/data/projects.md"
printf -- '- progress - x (role: progress; cadence: daily 07:00; added 2026-10-26)\n' > "$PARENT/data/officers.md"
cat > "$PARENT/data/offices.md" <<'EOF'
# Offices

- lib - Keep the documents placed (role: librarian; runs-on: remote-mac; dispatch: alpha; merge: alpha; merge-via: none; auto-merge-classes: none; wip: 1; tick: every 4h; sources: tick,lane:progress; added 2026-11-07)
- away - Runs elsewhere (role: librarian; runs-on: other-host; dispatch: alpha; merge: none; merge-via: none; auto-merge-classes: none; wip: 1; tick: every 4h; sources: tick; added 2026-11-07)
EOF
printf 'command=%s --rules %s\nclasses=authority\nclear=none\n' "$ROOT/bin/fm-reserved-classify.sh" "$REMOTE_HOME/config/admission/alpha.rules" > "$PARENT/config/admission/alpha"
printf 'AGENTS.md authority\n' > "$PARENT/config/admission/alpha.rules"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
command_name=$(perl -MMIME::Base64=decode_base64 -e 'my @a = split(/\0/, decode_base64($ARGV[0])); print $a[0];' "$4")
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf 'check herdr=ok: /usr/bin/herdr\n'
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  "$@"
}

seed_office() { # <id>
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" "$1" remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" alpha --office "$1"
}

test_remote_office_seed_writes_the_office_home() {
  local out
  out=$(seed_office lib 2>&1) || fail "remote office seed failed: $out"
  assert_equals lib "$(cat "$REMOTE_HOME/.fm-office")" "the office marker"
  assert_equals lib "$(cat "$REMOTE_HOME/.fm-secondmate-home")" "the identity marker"
  assert_grep '# Office authority' "$REMOTE_HOME/data/charter.md" "the remote charter lacks the office authority heading"
  assert_grep '- alpha [direct-PR admission=alpha]' "$REMOTE_HOME/data/projects.md" "the merge project lacks admission="
  cmp -s "$PARENT/config/admission/alpha" "$REMOTE_HOME/config/admission/alpha" || fail "the admission config was not copied"
  cmp -s "$PARENT/config/admission/alpha.rules" "$REMOTE_HOME/config/admission/alpha.rules" || fail "the admission rules were not copied"
  assert_present "$REMOTE_HOME/state/office-tick.check.sh" "the tick source was not registered in the remote home"
  assert_present "$REMOTE_HOME/state/office-lane-progress.check.sh" "the lane source was not registered in the remote home"
  assert_present "$REMOTE_HOME/state/office-status.check.sh" "the status check was not armed in the remote home"
  assert_present "$PARENT/state/office-feed.check.sh" "the feed check was not armed in the parent"
  assert_present "$REMOTE_HOME/config/office-feed" "the feed did not reach the remote home"
  assert_contains "$(cat "$REMOTE_HOME/config/office-authority")" "admission-sha256=alpha:" "the record pins the merge project's admission config"
  assert_equals "0|lib|" "$(bash -c '. "$1"; rc=0; fm_office_resolve "$2" "$2/data" "$2/config" || rc=$?; printf "%s|%s|%s\n" "$rc" "$FM_OFFICE_ID" "$FM_OFFICE_ERROR"' \
    _ "$ROOT/bin/fm-office-authority-lib.sh" "$REMOTE_HOME")" "the remote home's gate accepts the published record"
  assert_equals "" "$(FM_HOME="$PARENT" bash "$ROOT/bin/fm-office.sh" ensure | grep 'office lib:' || true)" "the parent's ensure finds no gap for the seeded office"
  pass 'a remote office seed writes the marker, charter, admission copies, tokens, record, feed and checks'
}

test_remote_seed_leaves_an_empty_backlog_and_keeps_an_existing_one() {
  local before
  assert_equals "## In flight

## Queued

## Done" "$(cat "$REMOTE_HOME/data/backlog.md")" "a fresh remote seed leaves an empty structured backlog"
  if command -v tasks-axi >/dev/null 2>&1; then
    assert_contains "$(FM_HOME="$REMOTE_HOME" "$ROOT/bin/fm-tasks-axi.sh" list 2>&1)" "count: 0" "the empty backlog reads as empty"
  fi
  printf '## In flight\n- [ ] kept - an existing item (repo: alpha) (kind: ship) (since 2026-11-07)\n\n## Queued\n\n## Done\n' > "$REMOTE_HOME/data/backlog.md"
  before=$(cat "$REMOTE_HOME/data/backlog.md")
  seed_office lib >/dev/null 2>&1 || fail "re-seeding an existing remote office failed"
  assert_equals "$before" "$(cat "$REMOTE_HOME/data/backlog.md")" "a re-seed keeps an existing backlog byte for byte"
  assert_equals 1 "$(grep -c 'admission=alpha' "$REMOTE_HOME/data/projects.md")" "a re-seed does not duplicate the admission token"
  pass 'a remote seed leaves an empty backlog and a re-seed keeps an existing one'
}

test_remote_office_seed_refusals() {
  local out
  if out=$(seed_office away 2>&1); then fail "an office whose runs-on omits the remote host was seeded"; fi
  assert_contains "$out" "office away runs on other-host, not this host remote-mac" "the runs-on mismatch is named"
  assert_absent "$TMP_ROOT/away-home" "nothing was provisioned"
  assert_equals 0 "$(grep -c '^- away ' "$PARENT/data/secondmates.md")" "the refused office is not registered"
  if out=$(seed_office ghost 2>&1); then fail "an office with no offices.md line was seeded"; fi
  assert_contains "$out" "has no line for office ghost" "a missing office line is named"
  if out=$(remote_env "$ROOT/bin/fm-remote-home-seed.sh" lib remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" alpha 2>&1); then
    fail "a plain re-seed of an office home was accepted"
  fi
  assert_equals lib "$(cat "$REMOTE_HOME/.fm-office")" "a refused plain re-seed leaves the office marker"
  if out=$(remote_env "$ROOT/bin/fm-remote-home-seed.sh" lib remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" alpha --office other 2>&1); then
    fail "an office id that differs from the secondmate id was accepted"
  fi
  assert_contains "$out" "an office id equals its secondmate id" "the id mismatch is named"
  pass 'a remote office seed refuses a host not in runs-on, an unknown office, a plain re-seed and an id mismatch'
}

test_remote_office_seed_writes_the_office_home
test_remote_seed_leaves_an_empty_backlog_and_keeps_an_existing_one
test_remote_office_seed_refusals
