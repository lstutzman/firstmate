#!/usr/bin/env bash
# Remote secondmate lifecycle over the deterministic generic SSH boundary: provisioning, seeding,
# spawn, inheritance, reply, update, restart and liveness recovery on the herdr route.
# The rex backend and retirement half is tests/fm-remote-secondmate-lifecycle-rex-e2e.test.sh;
# both share tests/remote-secondmate-lifecycle-fixture.sh.
set -u
# Nothing here reads the caller's stdin, but remote job staging reads its stdin
# to EOF, so an inherited open pipe would park a job in `head` indefinitely.
exec </dev/null

# shellcheck source=tests/remote-secondmate-lifecycle-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-secondmate-lifecycle-fixture.sh"

read -r -t 1 _ 2>/dev/null
stdin_rc=$?
[ "$stdin_rc" -eq 1 ] || fail "the suite's stdin is not at end of file (read status $stdin_rc), so remote job staging could block on it"
pass "the suite reads no inherited stdin"

bound_rc=0
bound_out=$( (
  FM_TEST_WAIT_BOUND=1
  sleep 30 >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$TMP_ROOT/bound-child.pid"
  wait_bounded "$!" "a child that never exits"
) 2>&1) || bound_rc=$?
bound_child=$(cat "$TMP_ROOT/bound-child.pid")
[ "$bound_rc" -ne 0 ] || fail "wait_bounded returned success for a child that never exits"
case "$bound_out" in
  *"timed out after 1s waiting for a child that never exits"*) ;;
  *) fail "wait_bounded did not name what it timed out on: $bound_out" ;;
esac
bound_state=$(ps -o stat= -p "$bound_child" 2>/dev/null | tr -d '[:space:]')
case "$bound_state" in ''|Z*) ;; *) kill "$bound_child" 2>/dev/null; fail "wait_bounded left its child running (state $bound_state)" ;; esac
pass "a background job that never exits fails by name at the wait bound"

hold_rc=0
hold_out=$(FM_FAKE_HOLD_BOUND=1 FM_FAKE_SSH_MODE=inherit-block FM_FAKE_SSH_COUNT="$TMP_ROOT/hold-ssh.count" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" FM_FAKE_INHERIT_PAYLOAD="$TMP_ROOT/hold.payload" \
  FM_FAKE_INHERIT_ENTERED="$TMP_ROOT/hold.entered" FM_FAKE_INHERIT_RELEASE="$TMP_ROOT/hold.never-released" \
  "$FAKEBIN/fake-ssh" -- remote-mac fm-remote-entrypoint.sh _ _ _ \
  "$(printf 'fm-remote-inherit.sh\0put\0data/captain-shared.md' | base64 | tr -d '\n')" 2>&1) || hold_rc=$?
[ -f "$TMP_ROOT/hold.entered" ] || fail "the fake-ssh inherit hold was never entered"
[ "$hold_rc" -eq 97 ] || fail "a fake-ssh hold whose release never appears exited $hold_rc, not 97: $hold_out"
case "$hold_out" in
  *"timed out waiting for the inherit release"*) ;;
  *) fail "the fake-ssh hold did not name its missing release: $hold_out" ;;
esac
pass "a fake-ssh hold whose release never appears fails by name"

printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=0\n' \
  "$(printf ios | base64 | tr -d '\n')" \
  "$(printf 'Concurrent provisioning charter.\n' | base64 | tr -d '\n')" \
  > "$TMP_ROOT/provision.manifest"
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/concurrent-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/provision.manifest" \
  > "$TMP_ROOT/provision-one.out" 2>&1 &
provision_one=$!
provision_wait=0
while [ ! -f "$TMP_ROOT/provision.entered" ]; do
  kill -0 "$provision_one" 2>/dev/null || fail "first provisioning attempt exited before cloning"
  provision_wait=$((provision_wait + 1))
  [ "$provision_wait" -le 250 ] || fail "first provisioning attempt never reached cloning"
  sleep 0.02
done
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/concurrent-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/provision.manifest" \
  > "$TMP_ROOT/provision-two.out" 2>&1 &
provision_two=$!
sleep 0.2
[ "$(grep -cF clone "$TMP_ROOT/provision-clones")" -eq 1 ] \
  || fail "overlapping provisioning reached home classification concurrently"
touch "$TMP_ROOT/provision.release"
wait_bounded "$provision_one" "the first overlapping home provisioning" || fail "first serialized provisioning attempt failed"
wait_bounded "$provision_two" "the second overlapping home provisioning" || fail "reconciled provisioning attempt failed"
[ "$(cat "$TMP_ROOT/concurrent-home/.fm-secondmate-home")" = ios ] \
  || fail "serialized provisioning lost the published home"
[ "$(grep -cF clone "$TMP_ROOT/provision-clones")" -eq 1 ] \
  || fail "reconciled provisioning cloned the already-published home"
pass "overlapping remote home provisioning serializes through publication and rollback"

# A competing cleanup aimed at the public home path must never reach a clone
# that is still being written: the home clone is staged privately and published
# by rename, so the racing rm -rf finds only an absent path.
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=0\n' \
  "$(printf race | base64 | tr -d '\n')" \
  "$(printf 'Cleanup-race provisioning charter.\n' | base64 | tr -d '\n')" \
  > "$TMP_ROOT/race.manifest"
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/raced-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_FAKE_CLONE_HOLD_DIR="$TMP_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/race.manifest" \
  > "$TMP_ROOT/race-provision.out" 2>&1 &
race_provision=$!
race_wait=0
while [ ! -f "$TMP_ROOT/race-clone.held" ]; do
  kill -0 "$race_provision" 2>/dev/null || fail "provision exited before its clone could be held"
  race_wait=$((race_wait + 1))
  [ "$race_wait" -le 250 ] || fail "provision clone never reached the held point"
  sleep 0.02
done
rm -rf -- "$TMP_ROOT/raced-home"
touch "$TMP_ROOT/race-clone.release"
wait_bounded "$race_provision" "the raced home provisioning" \
  || { sed 's/^/race-provision: /' "$TMP_ROOT/race-provision.out"; fail "competing home cleanup reached a live provisioning clone"; }
[ "$(cat "$TMP_ROOT/raced-home/.fm-secondmate-home")" = race ] \
  || fail "raced provisioning lost its published home marker"
if [ "$(git -C "$TMP_ROOT/raced-home" rev-parse --show-toplevel 2>/dev/null)" = "$TMP_ROOT/raced-home" ] \
  && [ "$(git -C "$TMP_ROOT/raced-home" rev-parse HEAD)" = "$(git -C "$REMOTE_ROOT" rev-parse HEAD)" ] \
  && git -C "$TMP_ROOT/raced-home" fsck --full --no-progress >/dev/null 2>&1 \
  && [ -z "$(git -C "$TMP_ROOT/raced-home" status --porcelain)" ] \
  && cmp -s "$REMOTE_ROOT/AGENTS.md" "$TMP_ROOT/raced-home/AGENTS.md"; then
  :
else
  fail "raced provisioning published an incomplete clone"
fi
if find "$TMP_ROOT" -maxdepth 1 -name '.fm-home-provisioning.*' -print -quit | grep -q .; then
  fail "raced provisioning left staging litter beside the home"
fi
pass "competing cleanup of the public home cannot reach a live provisioning clone"

# A home that appears at the public path while the clone is staged must make
# the provision die without adopting, altering, or nesting into that home.
rm -f -- "$TMP_ROOT/race-clone.held" "$TMP_ROOT/race-clone.release"
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/appeared-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_FAKE_CLONE_HOLD_DIR="$TMP_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/race.manifest" \
  > "$TMP_ROOT/appeared-provision.out" 2>&1 &
appeared_provision=$!
race_wait=0
while [ ! -f "$TMP_ROOT/race-clone.held" ]; do
  kill -0 "$appeared_provision" 2>/dev/null || fail "appeared-home provision exited before its clone could be held"
  race_wait=$((race_wait + 1))
  [ "$race_wait" -le 250 ] || fail "appeared-home provision clone never reached the held point"
  sleep 0.02
done
mkdir "$TMP_ROOT/appeared-home"
printf 'foreign\n' > "$TMP_ROOT/appeared-home/foreign"
touch "$TMP_ROOT/race-clone.release"
if wait_bounded "$appeared_provision" "the provisioning that met an appearing home"; then
  fail "provision adopted a home that appeared while it was being provisioned"
fi
grep -qF "remote home appeared while it was being provisioned" "$TMP_ROOT/appeared-provision.out" \
  || { sed 's/^/appeared-provision: /' "$TMP_ROOT/appeared-provision.out"; fail "appeared-home provision died for the wrong reason"; }
[ "$(find "$TMP_ROOT/appeared-home" -mindepth 1 | wc -l | tr -d ' ')" -eq 1 ] \
  && [ "$(cat "$TMP_ROOT/appeared-home/foreign")" = foreign ] \
  || fail "provision altered a home that appeared while it was being provisioned"
if find "$TMP_ROOT" -maxdepth 1 -name '.fm-home-provisioning.*' -print -quit | grep -q .; then
  fail "appeared-home provisioning left staging litter beside the home"
fi
pass "a home that appears mid-provision makes the provision die without touching it"
if [ "${FM_TEST_PROVISION_ONLY:-0}" = 1 ]; then
  echo "ALL TESTS PASSED"
  exit 0
fi

mkdir -p "$TMP_ROOT/seed-parent/data" "$TMP_ROOT/seed-parent/state"
FM_SECONDMATE_CHARTER='Failing seed charter.' FM_SECONDMATE_SCOPE='failed seed' \
  FM_FAKE_SSH_MODE=provision-block-fail seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-fail remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-fail-home" --no-projects \
  > "$TMP_ROOT/seed-fail.out" 2>&1 &
seed_fail_pid=$!
seed_wait=0
while [ ! -f "$TMP_ROOT/seed.entered" ]; do
  kill -0 "$seed_fail_pid" 2>/dev/null || fail "failing seed exited before remote provisioning"
  seed_wait=$((seed_wait + 1))
  [ "$seed_wait" -le 250 ] || fail "failing seed never reached remote provisioning"
  sleep 0.02
done
FM_SECONDMATE_CHARTER='Successful seed charter.' FM_SECONDMATE_SCOPE='successful seed' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-keep remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-keep-home" --no-projects > "$TMP_ROOT/seed-keep.out" 2>&1 &
seed_keep_pid=$!
sleep 0.2
kill -0 "$seed_keep_pid" 2>/dev/null || fail "competing seed bypassed the shared registry transaction"
touch "$TMP_ROOT/seed.release"
if wait_bounded "$seed_fail_pid" "the known-failing seed"; then
  fail "known-failing seed unexpectedly succeeded"
fi
wait_bounded "$seed_keep_pid" "the serialized successful seed" || fail "serialized successful seed failed"
assert_no_grep '- seed-fail ' "$TMP_ROOT/seed-parent/data/secondmates.md" "failed seed route survived rollback"
assert_grep '- seed-keep ' "$TMP_ROOT/seed-parent/data/secondmates.md" "failed seed rollback removed a competing successful route"
assert_present "$TMP_ROOT/seed-keep-home/.fm-secondmate-home" "serialized seed lost its published remote home"
pass "remote seed rollback preserves serialized competing routes"

: > "$DOCTOR_LOG"
if FM_SECONDMATE_CHARTER='Unknown readiness charter.' FM_SECONDMATE_SCOPE='unknown readiness' \
  FM_FAKE_SSH_MODE=doctor-fix-unknown seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-unknown remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-unknown-home" --no-projects \
  > "$TMP_ROOT/seed-unknown.out" 2>&1; then
  fail "seeding claimed success after readiness repair completion became unknown"
fi
assert_grep 'remote readiness completion is unknown' "$TMP_ROOT/seed-unknown.out" \
  "unknown readiness did not report its distinct completion state"
assert_grep '- seed-unknown ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "unknown readiness removed the registered route"
assert_present "$TMP_ROOT/seed-parent/data/seed-unknown/brief.md" \
  "unknown readiness removed the scaffolded brief"
assert_absent "$TMP_ROOT/seed-unknown-home" \
  "unknown readiness proceeded into remote home provisioning"
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fix-unknown -
doctor-fix-unknown --fix' ] || fail "unknown readiness did not occur during the repair stage"$'\n'"$(cat "$DOCTOR_LOG")"
pass "unknown readiness preserves its route and brief for reconciliation"

# A host that cannot hold a durable second mate must be rejected by the
# readiness gate before any home is created on it, and the operator must get the
# gap text rather than a bare refusal.
: > "$DOCTOR_LOG"
if FM_SECONDMATE_CHARTER='Unready host charter.' FM_SECONDMATE_SCOPE='unready host' \
  FM_FAKE_SSH_MODE=doctor-human seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-toolless remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-toolless-home" --no-projects \
  > "$TMP_ROOT/seed-toolless.out" 2>&1; then
  fail "seeding proceeded against a host that is not ready for a remote second mate"
fi
assert_grep 'check gui-session=human:' \
  "$TMP_ROOT/seed-toolless.out" "the seed hid the remaining human gap"
assert_grep 'action: gui-session:' \
  "$TMP_ROOT/seed-toolless.out" "the seed hid the operator step that closes the gap"
assert_grep 'remote runtime preflight failed' "$TMP_ROOT/seed-toolless.out" \
  "the seed did not report the failing stage"
assert_absent "$TMP_ROOT/seed-toolless-home" "the seed provisioned a home despite a failing preflight"
assert_no_grep '- seed-toolless ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "the refused route survived the preflight rollback"
assert_absent "$TMP_ROOT/seed-parent/data/seed-toolless/brief.md" \
  "the refused route left its scaffolded charter behind"
[ "$(cat "$DOCTOR_LOG")" = 'doctor-human -
doctor-human --fix
doctor-human -' ] || fail "the seed did not run the check, repair, re-check sequence"$'\n'"$(cat "$DOCTOR_LOG")"
pass "remote seeding checks, repairs, and re-checks readiness, then stops on a remaining gap"

# The same gate must accept a host whose only gaps were repairable.
: > "$DOCTOR_LOG"
rm -f "$TMP_ROOT/doctor.repaired"
out=$(FM_SECONDMATE_CHARTER='Repairable host charter.' FM_SECONDMATE_SCOPE='repairable host' \
  FM_FAKE_SSH_MODE=doctor-fixable seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-repair remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-repair-home" --no-projects 2>&1) \
  || fail "seeding refused a host whose gaps the repair closed"$'\n'"$out"
assert_present "$TMP_ROOT/seed-repair-home/.fm-secondmate-home" "the repaired host was never provisioned"
assert_grep '- seed-repair ' "$TMP_ROOT/seed-parent/data/secondmates.md" "the repaired route was not registered"
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fixable -
doctor-fixable --fix
doctor-fixable -' ] || fail "the repaired seed did not re-check after its repair"$'\n'"$(cat "$DOCTOR_LOG")"
pass "remote seeding proceeds once the repair closes every gap"

# Seeding must not need a copy of the project in this home: firstmate names the
# origin it already resolved, the seed validates and transports it, and the
# primary project tree is left exactly as it was found.
projects_snapshot() { # <dir>
  local dir=$1 path
  (
    cd "$dir" 2>/dev/null || exit 0
    find . -print | LC_ALL=C sort | while IFS= read -r path; do
      if [ -f "$path" ] && [ ! -L "$path" ]; then
        printf '%s %s\n' "$path" "$(sha256_file "$path")"
      else
        printf '%s\n' "$path"
      fi
    done
  )
}
mkdir -p "$TMP_ROOT/seed-parent/projects"
fm_git_init_commit "$TMP_ROOT/seed-parent/projects/resident"
# Pin the bare origin's initial branch to the one fm_git_init_commit creates.
# Left to init.defaultBranch, its HEAD names a branch the push never creates on
# a host that still defaults to master, and cloning it checks out nothing.
git init -q --bare -b main "$TMP_ROOT/beta.git"
fm_git_init_commit "$TMP_ROOT/beta-src"
git -C "$TMP_ROOT/beta-src" remote add origin "file://$TMP_ROOT/beta.git"
git -C "$TMP_ROOT/beta-src" push -q -u origin HEAD
rm -rf "$TMP_ROOT/beta-src"
cat > "$TMP_ROOT/seed-parent/data/projects.md" <<'EOF'
- beta [direct-PR] - beta project (added 2026-08-06)
- delta [local-only] - delta project (added 2026-08-06)
EOF
BETA_ORIGIN="file://$TMP_ROOT/beta.git"
PROJECTS_BEFORE=$(projects_snapshot "$TMP_ROOT/seed-parent/projects")

if FM_SECONDMATE_CHARTER='Unsupplied origin charter.' FM_SECONDMATE_SCOPE='unsupplied origin' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-noorigin remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-noorigin-home" beta > "$TMP_ROOT/seed-noorigin.out" 2>&1; then
  fail "seeding an uncloned project with no origin claimed success"
fi
assert_grep 'pass beta=<origin-url>' "$TMP_ROOT/seed-noorigin.out" \
  "the refusal did not name how to supply the origin"
assert_absent "$TMP_ROOT/seed-noorigin-home" "the unresolvable origin still provisioned a remote home"

if FM_SECONDMATE_CHARTER='Unsafe origin charter.' FM_SECONDMATE_SCOPE='unsafe origin' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-unsafe remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-unsafe-home" 'beta=ext::git-upload-pack' \
  > "$TMP_ROOT/seed-unsafe.out" 2>&1; then
  fail "seeding accepted a remote-helper origin the remote host would execute"
fi
assert_grep 'not an accepted clone URL' "$TMP_ROOT/seed-unsafe.out" \
  "the unsafe-origin refusal did not name the reason"
assert_absent "$TMP_ROOT/seed-unsafe-home" "the unsafe origin still provisioned a remote home"

if FM_SECONDMATE_CHARTER='Local-only charter.' FM_SECONDMATE_SCOPE='local only' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-localonly remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-localonly-home" "delta=$BETA_ORIGIN" \
  > "$TMP_ROOT/seed-localonly.out" 2>&1; then
  fail "a supplied origin bypassed the local-only delivery-mode refusal"
fi
assert_grep 'is local-only and cannot be provisioned remotely' "$TMP_ROOT/seed-localonly.out" \
  "the local-only refusal did not name the registered mode"

if FM_SECONDMATE_CHARTER='Unregistered charter.' FM_SECONDMATE_SCOPE='unregistered' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-unregistered remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-unregistered-home" "gamma=$BETA_ORIGIN" \
  > "$TMP_ROOT/seed-unregistered.out" 2>&1; then
  fail "a supplied origin bypassed the project registry requirement"
fi
assert_grep 'has no registry record' "$TMP_ROOT/seed-unregistered.out" \
  "the unregistered-project refusal did not name the missing record"

out=$(FM_SECONDMATE_CHARTER='Own beta delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='beta delivery and validation' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-noclone remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-noclone-home" "beta=$BETA_ORIGIN" 2>&1) \
  || fail "seeding refused a registered project whose origin was supplied"$'\n'"$out"
assert_contains "$out" "home=remote-mac:$TMP_ROOT/seed-noclone-home" \
  "the no-clone seed did not report the host-qualified home"
assert_grep '- seed-noclone ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "the no-clone seed did not register the remote route"
assert_present "$TMP_ROOT/seed-noclone-home/projects/beta/README.md" \
  "the remote host did not clone the supplied origin"
[ "$(git -C "$TMP_ROOT/seed-noclone-home/projects/beta" remote get-url origin)" = "$BETA_ORIGIN" ] \
  || fail "the remote clone did not come from the supplied origin"
assert_grep '- beta [direct-PR]' "$TMP_ROOT/seed-noclone-home/data/projects.md" \
  "the remote home did not publish the project's registered posture"
assert_absent "$TMP_ROOT/seed-parent/projects/beta" \
  "seeding cloned the project into the primary project tree"
[ "$(projects_snapshot "$TMP_ROOT/seed-parent/projects")" = "$PROJECTS_BEFORE" ] \
  || fail "seeding changed the primary project tree"
pass "remote seeding provisions a supplied origin without touching the primary project tree"

# The receiving host validates the origin itself rather than trusting whatever
# reached it, so a manifest naming an executable transport provisions nothing.
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=1\nproject=%s|%s|%s|%s\n' \
  "$(printf unsafe-origin | base64 | tr -d '\n')" \
  "$(printf 'Unsafe origin manifest charter.\n' | base64 | tr -d '\n')" \
  "$(printf beta | base64 | tr -d '\n')" \
  "$(printf 'ext::git-upload-pack' | base64 | tr -d '\n')" \
  "$(printf -- '- beta [direct-PR] - beta project (added 2026-08-06)' | base64 | tr -d '\n')" \
  "$(printf direct-PR | base64 | tr -d '\n')" \
  > "$TMP_ROOT/unsafe-origin.manifest"
if FM_HOME="$TMP_ROOT/unsafe-origin-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/unsafe-origin.manifest" \
  > "$TMP_ROOT/unsafe-origin.out" 2>&1; then
  fail "remote provisioning accepted an origin the transport had not validated"
fi
assert_grep 'not an accepted clone URL' "$TMP_ROOT/unsafe-origin.out" \
  "remote provisioning did not name the rejected origin"
assert_absent "$TMP_ROOT/unsafe-origin-home" "the rejected manifest left a remote home behind"
pass "remote provisioning re-validates a supplied origin at the receiving host"

# Firstmate is a shared template, so seeding must carry a project origin from any
# forge or host, not a privileged one. These four URL shapes have to survive the
# parent's validation, the manifest, the transport, and the receiving host's own
# validation, and arrive at git unchanged. A fixture resolver records the exact
# clone source the remote side hands to git and then serves it from a local bare
# repository, because an offline run cannot reach bitbucket.org itself.
FORGE_CLONE_LOG="$TMP_ROOT/forge-clone.log"
FORGE_ORIGIN_MAP="$TMP_ROOT/forge-origin.map"
: > "$FORGE_CLONE_LOG"
: > "$FORGE_ORIGIN_MAP"
forge_project() { # <project> <origin-url>
  local project=$1 origin=$2 tab
  tab=$(printf '\t')
  fm_git_init_commit "$TMP_ROOT/forge-src-$project"
  printf 'served from %s\n' "$origin" > "$TMP_ROOT/forge-src-$project/ORIGIN.txt"
  git -C "$TMP_ROOT/forge-src-$project" add ORIGIN.txt
  git -C "$TMP_ROOT/forge-src-$project" \
    -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm origin
  git clone --quiet --bare "$TMP_ROOT/forge-src-$project" "$TMP_ROOT/forge-$project.git"
  rm -rf "$TMP_ROOT/forge-src-$project"
  printf '%s%s%s\n' "$origin" "$tab" "$TMP_ROOT/forge-$project.git" >> "$FORGE_ORIGIN_MAP"
  printf -- '- %s [direct-PR] - %s project (added 2026-08-06)\n' "$project" "$project" \
    >> "$TMP_ROOT/seed-parent/data/projects.md"
}
forge_project bitbucket-app 'https://bitbucket.org/team/bitbucket-app.git'
forge_project ghe-app 'https://git.example.com/org/ghe-app.git'
forge_project gitlab-app 'ssh://git@gitlab.self.hosted:2222/group/subgroup/gitlab-app.git'
forge_project scp-app 'git@host.internal:group/scp-app.git'

cat > "$REMOTE_ROOT/bin/git" <<SH
#!/usr/bin/env bash
# Fixture origin resolver for the remote side: record the clone source exactly as
# the production code hands it to git, then serve any recorded URL from a local
# bare repository so the run stays offline. Everything else is real git.
set -u
if [ "\${1:-}" = clone ]; then
  printf '%s\n' "\$*" >> '$FORGE_CLONE_LOG'
  args=()
  for arg in "\$@"; do
    replacement=\$(awk -v k="\$arg" -F'\t' '\$1 == k { print \$2; exit }' '$FORGE_ORIGIN_MAP' 2>/dev/null)
    if [ -n "\$replacement" ]; then args+=("\$replacement"); else args+=("\$arg"); fi
  done
  exec '$REAL_GIT' "\${args[@]}"
fi
exec '$REAL_GIT' "\$@"
SH
chmod +x "$REMOTE_ROOT/bin/git"

FORGE_HOME="$TMP_ROOT/seed-forge-home"
out=$(FM_SECONDMATE_CHARTER='Own delivery for projects hosted anywhere.' \
  FM_SECONDMATE_SCOPE='multi-forge delivery' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-forge remote-mac "$REMOTE_ROOT" \
  "$FORGE_HOME" \
  'bitbucket-app=https://bitbucket.org/team/bitbucket-app.git' \
  'ghe-app=https://git.example.com/org/ghe-app.git' \
  'gitlab-app=ssh://git@gitlab.self.hosted:2222/group/subgroup/gitlab-app.git' \
  'scp-app=git@host.internal:group/scp-app.git' 2>&1) \
  || fail "seeding refused origins hosted outside GitHub"$'\n'"$out"

while IFS="$(printf '\t')" read -r forge_origin _; do
  [ -n "$forge_origin" ] || continue
  assert_grep "$forge_origin" "$FORGE_CLONE_LOG" \
    "the remote host did not clone from the supplied origin $forge_origin"
done < "$FORGE_ORIGIN_MAP"
for forge_project_name in bitbucket-app ghe-app gitlab-app scp-app; do
  assert_present "$FORGE_HOME/projects/$forge_project_name/.git" \
    "the remote home has no clone for $forge_project_name"
  assert_grep "$forge_project_name" "$FORGE_HOME/data/projects.md" \
    "the remote registry omitted $forge_project_name"
  assert_absent "$TMP_ROOT/seed-parent/projects/$forge_project_name" \
    "seeding $forge_project_name cloned it into the primary project tree"
done
# Each clone must carry its own origin's content, so one shared fixture repo
# cannot make a mismatched route look routed.
[ "$(cat "$FORGE_HOME/projects/bitbucket-app/ORIGIN.txt")" = \
  'served from https://bitbucket.org/team/bitbucket-app.git' ] \
  || fail "the bitbucket route did not clone its own origin"
[ "$(cat "$FORGE_HOME/projects/scp-app/ORIGIN.txt")" = \
  'served from git@host.internal:group/scp-app.git' ] \
  || fail "the scp-like route did not clone its own origin"
[ "$(projects_snapshot "$TMP_ROOT/seed-parent/projects")" = "$PROJECTS_BEFORE" ] \
  || fail "seeding non-GitHub projects changed the primary project tree"
assert_grep '- seed-forge ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "the multi-forge route was not registered"

rm -f "$REMOTE_ROOT/bin/git"
[ -z "$(git -C "$REMOTE_ROOT" status --porcelain)" ] \
  || fail "the fixture origin resolver was left behind in the remote code root"
pass "seeding carries bitbucket, self-hosted, and scp-like origins through to the remote clone"

# Provision and register the remote route from the captain-facing primary.
seed_remote_ios_route
pass "remote seed registers the route and provisions the whole home and project clone on that host"

PROTOCOL_HOME="$TMP_ROOT/protocol-home"
mkdir -p "$PROTOCOL_HOME/config" "$PROTOCOL_HOME/data" "$PROTOCOL_HOME/state"
printf 'complete inherited payload\n' > "$TMP_ROOT/inherit-complete"
inherit_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/inherit-complete" | tr -d ' ')
inherit_hash=$(sha256_file "$TMP_ROOT/inherit-complete")
if printf 'complete' | FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/crew-harness "$inherit_bytes" "$inherit_hash" 1 >/dev/null 2>&1; then
  fail "remote inheritance published a truncated payload"
fi
assert_absent "$PROTOCOL_HOME/config/crew-harness" "truncated inheritance published a destination"
FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/crew-harness "$inherit_bytes" "$inherit_hash" 2 \
  < "$TMP_ROOT/inherit-complete" >/dev/null
printf 'stale inherited payload\n' > "$TMP_ROOT/inherit-stale"
inherit_stale_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/inherit-stale" | tr -d ' ')
inherit_stale_hash=$(sha256_file "$TMP_ROOT/inherit-stale")
if FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/crew-harness "$inherit_stale_bytes" "$inherit_stale_hash" 1 \
  < "$TMP_ROOT/inherit-stale" >/dev/null 2>&1; then
  fail "remote inheritance accepted a superseded payload generation"
fi
cmp -s "$TMP_ROOT/inherit-complete" "$PROTOCOL_HOME/config/crew-harness" \
  || fail "superseded inheritance replaced the current payload"
pass "remote inheritance rejects incomplete and superseded payload generations"

# Add one local route to prove mixed fleets remain parseable and projected.
mkdir -p "$LOCAL_HOME/data" "$LOCAL_HOME/state" "$LOCAL_HOME/config" "$LOCAL_HOME/projects" "$LOCAL_HOME/bin"
printf 'local\n' > "$LOCAL_HOME/.fm-secondmate-home"
printf 'fixture\n' > "$LOCAL_HOME/AGENTS.md"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LOCAL_HOME/data/backlog.md"
cat >> "$PARENT/data/secondmates.md" <<EOF
- local - Local delivery (home: $LOCAL_HOME; scope: local work; projects: alpha; added 2026-08-02)
EOF
remote_env "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "mixed local and remote registry validation failed"
pass "mixed local and remote routes validate without migration"

# Launch on the remote home's own configured backend. Parent metadata records
# host placement separately from that backend and arms the reply source.
printf 'pi\n' > "$PARENT/config/crew-harness"
launches_before_inherit=0
[ ! -f "$HERDR_LOG" ] || launches_before_inherit=$(grep -c '^tab create' "$HERDR_LOG" || true)
if FM_FAKE_SSH_MODE=inherit-partial remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-inherit-partial.out" 2>&1; then
  fail "remote spawn launched after ambiguous partial inheritance"
fi
launches_after_inherit=0
[ ! -f "$HERDR_LOG" ] || launches_after_inherit=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before_inherit" -eq "$launches_after_inherit" ] \
  || fail "remote spawn reached launch after ambiguous partial inheritance"
assert_absent "$PARENT/state/ios.meta" "failed remote inheritance published launch metadata"
spawn_remote_ios_on_herdr
pass "remote spawn launches on the remote-local backend and records a host-qualified route"

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-default-session.meta"
legacy_pane=$(sed -n 's/^herdr_pane_id=//p' "$remote_route_meta")
awk -v pane="$legacy_pane" '
  /^window=/ { print "window=default:" pane; next }
  /^herdr_session=/ { print "herdr_session=default"; next }
  { print }
' "$TMP_ROOT/remote-ios-before-default-session.meta" > "$remote_route_meta"
cp "$HERDR_LOG" "$TMP_ROOT/herdr-before-default-session.log"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios 2>/dev/null)" = unverified ] \
  || fail "legacy default-session metadata was not classified unverified"
if remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh route ios >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh send ios probe >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh key ios Enter >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh capture ios >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh observe ios >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh retire ios --force >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh launch ios codex - - herdr >/dev/null 2>&1; then
  fail "legacy default-session metadata remained operational"
fi
cmp -s "$TMP_ROOT/herdr-before-default-session.log" "$HERDR_LOG" \
  || fail "legacy default-session metadata caused a Herdr operation"
assert_present "$REMOTE_HOME" "refused legacy retirement removed the remote home"
assert_grep 'herdr_session=default' "$remote_route_meta" "refused legacy retirement rewrote endpoint metadata"

awk -v pane="$legacy_pane" '
  /^window=/ { print "window=default:" pane; next }
  { print }
' "$TMP_ROOT/remote-ios-before-default-session.meta" > "$remote_route_meta"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios 2>/dev/null)" = unverified ] \
  || fail "mismatched fm-remote target was not classified unverified"
cmp -s "$TMP_ROOT/herdr-before-default-session.log" "$HERDR_LOG" \
  || fail "mismatched fm-remote target caused a Herdr operation"
mv -f "$TMP_ROOT/remote-ios-before-default-session.meta" "$remote_route_meta"
pass "legacy and mismatched remote endpoints fail closed before backend access"

cp "$PARENT/state/ios.meta" "$TMP_ROOT/parent-ios-before-nonherdr.meta"
cp "$PARENT/data/secondmates.md" "$TMP_ROOT/registry-before-nonherdr.md"
set +e
FM_FAKE_SSH_MODE=launch-nonherdr-route remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-nonherdr-route.out" 2>&1
nonherdr_parent_rc=$?
set -e
[ "$nonherdr_parent_rc" -ne 0 ] || fail "parent accepted a non-herdr remote launch route"
assert_grep "remote launch returned backend 'tmux', expected herdr" "$TMP_ROOT/spawn-nonherdr-route.out" \
  "parent refusal did not name the returned remote backend"
cmp -s "$TMP_ROOT/parent-ios-before-nonherdr.meta" "$PARENT/state/ios.meta" \
  || fail "parent rewrote its endpoint metadata after a non-herdr route refusal"
cmp -s "$TMP_ROOT/registry-before-nonherdr.md" "$PARENT/data/secondmates.md" \
  || fail "parent removed or changed the registry route after a non-herdr route refusal"

set +e
FM_FAKE_SSH_MODE=launch-default-session-route remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-default-session-route.out" 2>&1
default_session_parent_rc=$?
set -e
[ "$default_session_parent_rc" -ne 0 ] || fail "parent accepted an interactive default-session remote route"
assert_grep "remote launch returned Herdr session 'default', expected 'fm-remote'" "$TMP_ROOT/spawn-default-session-route.out" \
  "parent refusal did not name the default session"
cmp -s "$TMP_ROOT/parent-ios-before-nonherdr.meta" "$PARENT/state/ios.meta" \
  || fail "parent rewrote its endpoint metadata after a default-session route refusal"

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-legacy.meta"
cat > "$remote_route_meta" <<EOF
window=firstmate:fm-ios
worktree=$REMOTE_HOME
project=$REMOTE_ROOT
harness=codex
kind=secondmate
backend=tmux
EOF
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-legacy-before-refusal.meta"
printf 'fm-ios|%s\n' "$REMOTE_HOME" > "$TMUX_STATE"
set +e
remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh launch ios codex - - herdr \
  > "$TMP_ROOT/legacy-alive-refusal.out" 2>&1
legacy_alive_rc=$?
set -e
[ "$legacy_alive_rc" -ne 0 ] || fail "remote control reused an alive legacy tmux endpoint"
assert_grep "endpoint is recorded on backend 'tmux', expected 'herdr'" "$TMP_ROOT/legacy-alive-refusal.out" \
  "remote refusal did not name the endpoint's recorded backend"
cmp -s "$TMP_ROOT/remote-ios-legacy-before-refusal.meta" "$remote_route_meta" \
  || fail "remote refusal changed the legacy endpoint metadata"
assert_present "$TMUX_STATE" "remote refusal killed the alive legacy endpoint"
cmp -s "$TMP_ROOT/registry-before-nonherdr.md" "$PARENT/data/secondmates.md" \
  || fail "remote legacy refusal removed or changed the registry route"
mv -f "$TMP_ROOT/remote-ios-before-legacy.meta" "$remote_route_meta"
rm -f "$TMUX_STATE"
pass "non-herdr remote endpoints are refused without changing either route"

rm -f "$TMP_ROOT/inherit.entered" "$TMP_ROOT/inherit.release" "$TMP_ROOT/inherit.payload"
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
stale spawn preference
EOF
FM_FAKE_SSH_MODE=inherit-block remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-concurrent.out" 2>&1 &
spawn_concurrent=$!
spawn_inherit_wait=0
# Earlier inherited files traverse the worker before captain-shared.md. Allow
# the configured convergence budget, as remote_env does, before timing out.
while [ ! -f "$TMP_ROOT/inherit.entered" ]; do
  kill -0 "$spawn_concurrent" 2>/dev/null || fail "remote spawn exited before its blocked inheritance write"
  spawn_inherit_wait=$((spawn_inherit_wait + 1))
  [ "$spawn_inherit_wait" -le "$(( ${FM_SECONDMATE_CONVERGENCE_TIMEOUT:-900} * 50 ))" ] || fail "remote spawn never reached its blocked inheritance write"
  sleep 0.02
done
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
current post-spawn preference
EOF
remote_env "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/spawn-concurrent-push.out" 2>&1 &
spawn_config_push=$!
sleep 0.2
kill -0 "$spawn_config_push" 2>/dev/null \
  || fail "config push bypassed the active remote spawn inheritance transaction"
touch "$TMP_ROOT/inherit.release"
wait_bounded "$spawn_concurrent" "the serialized remote spawn" || fail "serialized remote spawn failed"
wait_bounded "$spawn_config_push" "the config push behind the remote spawn" || fail "config push failed after serialized remote spawn"$'\n'"$(cat "$TMP_ROOT/spawn-concurrent-push.out")"
[ "$(tail -1 "$REMOTE_HOME/data/captain-shared.md")" = 'current post-spawn preference' ] \
  || fail "stale spawn inheritance overwrote later config convergence"
pass "remote spawn serializes inheritance through launch publication"

# A normal marked parent request traverses SSH as a durable remote inbox
# record plus a rung doorbell - the payload is never typed into the pane. An
# ambiguous transport (the remote leg executed, then ssh exit 255) is retried
# identically once, and the idempotent remote write lands both executions on
# ONE record; the send reports itself unconfirmed with a correlation-preserving
# resend command, and the expectation resolves only after the correlated remote log
# delta is ingested.
ssh_before_send=$(cat "$SSH_COUNT")
records_before_send=$(find "$PARENT_ROUTE_INBOX" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')
set +e
FM_FAKE_SSH_MODE=ambiguous remote_env "$ROOT/bin/fm-send.sh" fm-ios \
  'report the build result' > "$TMP_ROOT/send.out" 2> "$TMP_ROOT/send.err"
send_rc=$?
set -e
[ "$send_rc" -ne 0 ] || fail "ambiguous remote send claimed definite delivery"
assert_grep 'Only the correlation-reusing resend below is idempotent' "$TMP_ROOT/send.err" "ambiguous remote send did not state the correlation-preserving resend boundary"
assert_no_grep 'do not resend' "$TMP_ROOT/send.err" "ambiguous remote send kept the deleted do-not-resend trap"
ssh_after_send=$(cat "$SSH_COUNT")
[ "$ssh_after_send" -eq $((ssh_before_send + 2)) ] \
  || fail "ambiguous remote send was not retried exactly once (ssh calls: $((ssh_after_send - ssh_before_send)))"
records_after_send=$(find "$PARENT_ROUTE_INBOX" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
[ "$records_after_send" -eq $((records_before_send + 1)) ] \
  || fail "the retried remote steer did not dedup onto one new record, went $records_before_send -> $records_after_send"
assert_no_grep 'report the build result' "$HERDR_LOG" "the steer payload was typed into the remote pane"
assert_grep 'Firstmate instruction waiting' "$HERDR_LOG" "the remote doorbell never rang"
CORR=$(newest_remote_inbox_corr)
[ -n "$CORR" ] || fail "remote send did not carry a correlation token"
assert_grep "FM_PENDING_REPLY_EXISTING_CORR=$CORR" "$TMP_ROOT/send.err" "ambiguous remote send did not print its correlation-reusing command"
phase=$(grep '^phase=' "$PARENT/state/pending-replies/$CORR" | cut -d= -f2-)
[ "$phase" = delivery_unknown ] || fail "ambiguous remote send did not preserve its pending expectation"
printf 'done [corr=%s]: remote build passed\n' "$CORR" >> "$REMOTE_HOME/state/parent-replies.status"
await_reply_result "$PARENT/state/procevent-inbox/$SID.1.result" \
  || fail "remote reply source did not capture the correlated answer"
RESULT="$PARENT/state/procevent-inbox/$SID.1.result"
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios 1 "$RESULT" >/dev/null \
  || fail "remote reply ingest failed"
assert_grep "done [corr=$CORR]: remote build passed" "$PARENT/state/ios.status" "correlated remote reply did not reach the parent status channel"
phase=$(grep '^phase=' "$PARENT/state/pending-replies/$CORR" | cut -d= -f2-)
[ "$phase" = resolved ] || fail "correlated remote reply did not resolve the parent expectation"
pass "marked send and routed reply complete through the existing parent correlation owner"

# Inline steers are local only: even a plain short body sent straight to the
# remote leg keeps the pointer doorbell and an unhandled record, and its
# idempotent re-run lands on that same record.
unhandled_before=$(find "$PARENT_ROUTE_INBOX" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')
handled_before=$(find "$PARENT_ROUTE_INBOX/handled" -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')
for _ in 1 2; do
  remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh send ios 'plain remote steer' >/dev/null 2>&1 \
    || fail "plain remote send failed"
done
[ "$(find "$PARENT_ROUTE_INBOX" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" -eq $((unhandled_before + 1)) ] \
  || fail "a plain short remote steer must be one unhandled pointer record, deduplicated on re-run"
[ "$(find "$PARENT_ROUTE_INBOX/handled" -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')" -eq "$handled_before" ] \
  || fail "a remote steer must never be written already taken"
assert_no_grep 'plain remote steer' "$HERDR_LOG" "a plain remote steer typed its body instead of the pointer doorbell"
pass "remote leg: a plain short steer keeps the pointer doorbell (inline is local only)"
rm -f "$PARENT/state/.wake-queue"

printf '{"revision":2}\n' > "$PARENT/config/crew-dispatch.json"
printf 'grok\n' > "$PARENT/config/crew-harness"
set +e
FM_FAKE_SSH_MODE=inherit-partial remote_env "$ROOT/bin/fm-config-push.sh" \
  > "$TMP_ROOT/config-partial.out" 2>&1
config_partial_rc=$?
set -e
[ "$config_partial_rc" -ne 0 ] || fail "partial remote inheritance claimed complete convergence"
assert_grep '"revision":2' "$REMOTE_HOME/config/crew-dispatch.json" "partial inheritance did not apply its first file"
[ "$(cat "$REMOTE_HOME/config/crew-harness")" != grok ] \
  || fail "partial inheritance unexpectedly applied the failed file"
NUDGE_MARKER="$PARENT/state/.secondmate-nudge-pending/ios.pending"
assert_grep 'remote=1' "$NUDGE_MARKER" "partial inheritance left no durable remote reread marker"
publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$REMOTE_ROOT/bin/fm-watch.sh"
remote_env "$ROOT/bin/fm-bootstrap.sh" > "$TMP_ROOT/config-partial-retry.out" \
  || fail "bootstrap did not converge partial remote inheritance"
[ "$(cat "$REMOTE_HOME/config/crew-harness")" = grok ] \
  || fail "bootstrap did not apply the remaining inherited file"
assert_absent "$NUDGE_MARKER" "bootstrap cleared no remote reread marker after convergence"
PARTIAL_CONFIG_CORR=$(newest_remote_inbox_corr)
[ -n "$PARTIAL_CONFIG_CORR" ] || fail "bootstrap config reread did not carry a correlation token"
printf 'done [corr=%s]: converged inherited config re-read\n' "$PARTIAL_CONFIG_CORR" >> "$REMOTE_HOME/state/parent-replies.status"
await_reply_result "$PARENT/state/procevent-inbox/$SID.2.result" \
  || fail "remote reply source did not capture the converged config acknowledgment"
PARTIAL_CONFIG_RESULT="$PARENT/state/procevent-inbox/$SID.2.result"
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios 2 "$PARTIAL_CONFIG_RESULT" >/dev/null \
  || fail "converged remote config acknowledgment was not ingested"
pass "partial remote inheritance retains reread intent through bootstrap convergence"

rm -f "$TMP_ROOT/inherit.entered" "$TMP_ROOT/inherit.release" "$TMP_ROOT/inherit.payload"
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
stale concurrent preference
EOF
FM_FAKE_SSH_MODE=inherit-block remote_env "$ROOT/bin/fm-config-push.sh" \
  > "$TMP_ROOT/config-concurrent-first.out" 2>&1 &
config_first=$!
inherit_wait=0
while [ ! -f "$TMP_ROOT/inherit.entered" ]; do
  kill -0 "$config_first" 2>/dev/null || fail "first inheritance transaction exited before its blocked write"
  inherit_wait=$((inherit_wait + 1))
  # Match the earlier spawn/inheritance wait (120-second ceiling): a loaded portable runner can
  # spend several seconds in the remote entrypoint before reaching this write.
  [ "$inherit_wait" -le "$(( ${FM_SECONDMATE_CONVERGENCE_TIMEOUT:-900} * 50 ))" ] || fail "first inheritance transaction never reached its blocked write"
  sleep 0.02
done
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
current concurrent preference
EOF
remote_env "$ROOT/bin/fm-bootstrap.sh" > "$TMP_ROOT/config-concurrent-second.out" 2>&1 &
config_second=$!
sleep 0.2
kill -0 "$config_second" 2>/dev/null \
  || fail "bootstrap bypassed the active remote inheritance transaction"
touch "$TMP_ROOT/inherit.release"
wait_bounded "$config_first" "the first inheritance transaction" || fail "first serialized inheritance transaction failed"
wait_bounded "$config_second" "the bootstrap inheritance transaction" || fail "bootstrap inheritance transaction failed after waiting"
[ "$(tail -1 "$REMOTE_HOME/data/captain-shared.md")" = 'current concurrent preference' ] \
  || fail "later bootstrap convergence was overwritten by stale inherited bytes"
pass "config push and bootstrap serialize remote inheritance convergence"

printf 'codex\n' > "$PARENT/config/crew-harness"
# A failed reread nudge now means the durable remote inbox RECORD could not be
# written (a swallowed doorbell alone no longer fails a recorded steer), so
# the failure is induced by making the remote steering inbox unwritable.
chmod 555 "$PARENT_ROUTE_INBOX"
if remote_env "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/config-push-fail.out" 2>&1; then
  chmod 755 "$PARENT_ROUTE_INBOX"
  fail "remote config push claimed success after its reread record could not be written"
fi
if [ ! -f "$NUDGE_MARKER" ]; then
  chmod 755 "$PARENT_ROUTE_INBOX"
  printf 'config push failure output:\n%s\n' "$(cat "$TMP_ROOT/config-push-fail.out")" >&2
  fail "failed remote config reread did not retain a retry marker"
fi
assert_grep 'remote=1' "$NUDGE_MARKER" "remote config reread marker lost its placement"
chmod 755 "$PARENT_ROUTE_INBOX"
remote_env "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/config-push-retry.out" \
  || fail "unchanged remote config push did not retry its pending reread"
assert_absent "$NUDGE_MARKER" "successful remote config reread left its retry marker"
assert_grep 'config-reread: sent' "$TMP_ROOT/config-push-retry.out" "remote config reread retry was not reported"
CONFIG_CORR=$(newest_remote_inbox_corr)
[ -n "$CONFIG_CORR" ] || fail "remote config reread did not carry a correlation token"
printf 'done [corr=%s]: inherited config re-read\n' "$CONFIG_CORR" >> "$REMOTE_HOME/state/parent-replies.status"
await_reply_result "$PARENT/state/procevent-inbox/$SID.3.result" \
  || fail "remote reply source did not capture the config reread acknowledgement"
CONFIG_RESULT="$PARENT/state/procevent-inbox/$SID.3.result"
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios 3 "$CONFIG_RESULT" >/dev/null \
  || fail "remote config reread acknowledgement was not ingested"
pass "remote inherited config retains and retries a failed live reread nudge"

resolve_ios_pending

# Structured fleet state comes from each home's published ledger. The remote
# host is explicit, and the local route remains alongside it.
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LOCAL_HOME" \
  "$ROOT/bin/fm-home-summary-refresh.sh" >/dev/null \
  || fail "local fixture did not publish its home ledger"
remote_env "$ROOT/bin/fm-on.sh" ios fm-home-summary-refresh.sh >/dev/null \
  || fail "remote fixture did not publish its home ledger"
SNAPSHOT=$(remote_env "$ROOT/bin/fm-fleet-snapshot.sh" --json)
if ! printf '%s' "$SNAPSHOT" | jq -e '.secondmate_current.records | any(.id == "ios" and .remote == true and .host == "remote-mac" and .provenance.selected == "structured-home")' >/dev/null; then
  printf 'secondmate projection:\n%s\n' "$(printf '%s' "$SNAPSHOT" | jq '.secondmate_current')" >&2
  fail "fleet snapshot did not select the remote structured-home projection"
fi
printf '%s' "$SNAPSHOT" | jq -e '.tasks[] | select(.id == "ios") | .paths.home.present == null and .endpoint.agent_alive == "unknown"' >/dev/null \
  || fail "the fleet snapshot performed or invented a remote endpoint-liveness probe"
printf '%s' "$SNAPSHOT" | jq -e '.secondmate_current.records | any(.id == "local" and .remote == false)' >/dev/null \
  || fail "fleet snapshot lost the existing local secondmate route"
pass "fleet snapshot projects mixed local and remote structured state"
rm -f "$PARENT/state/.wake-queue"

# The remote code root updates independently, then the persistent home imports
# and fast-forwards to that host-local commit without touching project clones.
REMOTE_SEED="$TMP_ROOT/firstmate-seed"
git clone -q "file://$REMOTE_ORIGIN" "$REMOTE_SEED"
git -C "$REMOTE_SEED" config user.email test@example.com
git -C "$REMOTE_SEED" config user.name Test
printf 'remote update probe\n' > "$REMOTE_SEED/REMOTE_UPDATE_PROBE"
git -C "$REMOTE_SEED" add REMOTE_UPDATE_PROBE
git -C "$REMOTE_SEED" commit -qm 'advance remote code root'
git -C "$REMOTE_SEED" push -q origin main
UPDATE_OUT=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh update ios)
assert_contains "$UPDATE_OUT" 'synced:' "remote update did not report a host-local fast-forward"
[ "$(git -C "$REMOTE_HOME" rev-parse HEAD)" = "$(git -C "$REMOTE_ROOT" rev-parse HEAD)" ] \
  || fail "remote persistent home did not fast-forward to its code-root commit"
assert_present "$REMOTE_HOME/REMOTE_UPDATE_PROBE" "remote update did not materialize the code-root commit"
pass "remote update imports and fast-forwards the persistent home on its configured host"

# The remote restart verb is not a second implementation: its host-local leg runs
# the ORDINARY control plane against a record that is plain and local on that
# host. These two refusals can only come from that plane's own pre-stop
# capability tables, and they leave the live agent exactly as it was - which is
# the whole safety property of asking before anything is stopped.
RELAUNCH_UNVERIFIED=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh \
  relaunch ios notaharness - - 2>&1) && fail "an unverified runtime should refuse a remote restart"
assert_contains "$RELAUNCH_UNVERIFIED" 'unverified remote secondmate harness' \
  "the remote restart verb did not refuse an unverified runtime"
RELAUNCH_ROUTE_META="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$RELAUNCH_ROUTE_META" "$TMP_ROOT/ios-before-relaunch.meta"
mkdir -p "$TMP_ROOT/not-a-checkout"
sed "s|^worktree=.*|worktree=$TMP_ROOT/not-a-checkout|" \
  "$TMP_ROOT/ios-before-relaunch.meta" > "$RELAUNCH_ROUTE_META"
RELAUNCH_CHECKPOINT=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh \
  relaunch ios codex - - 2>&1) && fail "a restart with no accountable checkout should refuse"
assert_contains "$RELAUNCH_CHECKPOINT" 'refusing to relaunch without a checkout whose unlanded work can be accounted for' \
  "the host-local restart did not reach the control plane's own pre-stop checkpoint"
cp "$TMP_ROOT/ios-before-relaunch.meta" "$RELAUNCH_ROUTE_META"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "a refused remote restart must leave the running agent untouched"
pass "the remote restart verb delegates to the host-local control plane and refuses before stopping anything"


rm -f "$TMP_ROOT/doctor.repaired"
: > "$DOCTOR_LOG"
[ "$(FM_FAKE_SSH_MODE=doctor-fixable remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = unreadable ] \
  || fail "the stopped-server fixture did not make the pre-repair endpoint probe unreadable"
launches_before_repair=$(grep -c '^tab create' "$HERDR_LOG" || true)
BOOT_REPAIRED=$(FM_FAKE_SSH_MODE=doctor-fixable remote_env "$ROOT/bin/fm-bootstrap.sh")
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fixable --backend
doctor-fixable --fix
doctor-fixable --backend' ] || fail "liveness did not check, repair, and re-check readiness before probing"$'\n'"$(cat "$DOCTOR_LOG")"
assert_not_contains "$BOOT_REPAIRED" 'SECONDMATE_LIVENESS: secondmate ios:' \
  "successful pre-probe readiness repair produced a liveness failure"
launches_after_repair=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before_repair" -eq "$launches_after_repair" ] \
  || fail "readiness repair introduced a new remote relaunch point"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "the endpoint was not probed successfully after readiness repair"
pass "startup repairs remote readiness before probing without relaunching"

# --- ordinary-supervision recovery of a dead remote endpoint -----------------
# The watcher's cadence-gated liveness tick (bin/fm-watch.sh
# secondmate_liveness_tick) drives the same shared probe+relaunch library the
# startup sweep used above: a positively dead remote endpoint relaunches
# through the guarded remote spawn and emits exactly one check wake, while an
# unreachable host is preserved untouched. The tick runs against a dedicated
# state dir holding only this mate's endpoint meta so no other supervision
# source can fire first.

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
WATCH_STATE="$TMP_ROOT/watch-liveness-state"
mkdir -p "$WATCH_STATE"
cp "$PARENT/state/ios.meta" "$WATCH_STATE/ios.meta"
# The remote spawn path mints its inheritance generation from a counter that
# lives beside the task record, so the dedicated watch state needs the real
# one; otherwise the pushed payload reads as superseded on the remote home.
cp "$PARENT/state/.remote-inherit-ios.generation" "$WATCH_STATE/" 2>/dev/null || true
touch "$WATCH_STATE/home-summary.json"

# A graceful agent exit leaves the pane with no registered agent - the exact
# incident this tick exists for.
ios_pane=$(sed -n 's/^herdr_pane_id=//p' "$remote_route_meta")
[ -n "$ios_pane" ] || fail "the remote route meta did not record its Herdr pane"
jq --arg p "$ios_pane" \
  '.typed |= with_entries(select(.key != $p)) | .working |= with_entries(select(.key != $p))' \
  "$HERDR_STATE" > "$TMP_ROOT/herdr-dead.json" && mv "$TMP_ROOT/herdr-dead.json" "$HERDR_STATE"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = dead ] \
  || fail "the agent-free remote pane did not classify dead"

tabs_before=$(grep -c '^tab create' "$HERDR_LOG" || true)
# The watcher bounds this relaunch itself: its guarded spawn runs under
# FM_SECONDMATE_LIVENESS_TIMEOUT, and either outcome wakes and exits the
# watcher. The leg waits for that same bound plus probe headroom on the wall
# clock, so a slow runner cannot fail a relaunch the watcher still accepts.
watch_relaunch_timeout=120
# exec keeps $! the watcher itself rather than the function's subshell, so a
# kill reaches the process that probes and writes into the fixture root.
FM_STATE_OVERRIDE="$WATCH_STATE" FM_SECONDMATE_LIVENESS_SECS=1 FM_POLL=1 \
  FM_SECONDMATE_LIVENESS_TIMEOUT="$watch_relaunch_timeout" \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  remote_env exec "$ROOT/bin/fm-watch.sh" \
  > "$TMP_ROOT/watch-liveness.out" 2> "$TMP_ROOT/watch-liveness.err" &
watch_pid=$!
watch_deadline=$((SECONDS + watch_relaunch_timeout + 30))
while kill -0 "$watch_pid" 2>/dev/null && [ "$SECONDS" -lt "$watch_deadline" ]; do
  sleep 0.1
done
if kill -0 "$watch_pid" 2>/dev/null; then
  kill "$watch_pid" 2>/dev/null || true
  fail "the watcher did not exit on its auto-relaunch wake within its ${watch_relaunch_timeout}s relaunch bound: $(cat "$TMP_ROOT/watch-liveness.out" "$TMP_ROOT/watch-liveness.err" 2>/dev/null)"
fi
wait "$watch_pid" \
  || fail "the liveness watcher leg exited non-zero: $(cat "$TMP_ROOT/watch-liveness.err")"
watch_pid=''
grep -F 'check: secondmate ios auto-relaunched after remote endpoint dead on its configured host (host=remote-mac)' \
  "$TMP_ROOT/watch-liveness.out" >/dev/null \
  || fail "the dead remote secondmate was not auto-relaunched: $(cat "$TMP_ROOT/watch-liveness.out")"
[ "$(grep -c 'check: secondmate ios auto-relaunched' "$TMP_ROOT/watch-liveness.out")" -eq 1 ] \
  || fail "the remote auto-relaunch did not produce exactly one captain-facing line"
grep -F $'\tcheck\tsecondmate-relaunch-ios-' "$WATCH_STATE/.wake-queue" >/dev/null \
  || fail "the durable auto-relaunch wake row was not queued: $(cat "$WATCH_STATE/.wake-queue" 2>/dev/null)"
grep -F 'relaunched' "$WATCH_STATE/.secondmate-relaunch-ios" >/dev/null \
  || fail "the durable per-mate ledger did not record the relaunch"
tabs_after=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$tabs_after" -gt "$tabs_before" ] \
  || fail "the remote relaunch did not create a fresh remote endpoint ($tabs_before -> $tabs_after)"
assert_grep 'remote_host=remote-mac' "$WATCH_STATE/ios.meta" \
  "the watcher relaunch dropped the remote host route"
assert_grep 'herdr_session=fm-remote' "$remote_route_meta" \
  "the watcher relaunch did not re-record the pinned remote Herdr session"
assert_grep '- ios ' "$PARENT/data/secondmates.md" \
  "the watcher relaunch changed the registry route"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "the auto-relaunched remote endpoint did not read alive"
# Production relaunch updates the parent route meta and inheritance generation
# in place; the dedicated watch state above kept the rest of this suite's
# parent state out of scope, so fold both records back now.
cp "$WATCH_STATE/ios.meta" "$PARENT/state/ios.meta"
cp "$WATCH_STATE/.remote-inherit-ios.generation" "$PARENT/state/" 2>/dev/null || true
pass "watch liveness: a dead remote secondmate is auto-relaunched on its own host with one wake"

# Host loss mid-supervision is never evidence of death: the same tick on an
# unreachable route probes, preserves, and stays silent.
WATCH_STATE_UNREACHABLE="$TMP_ROOT/watch-liveness-unreachable"
mkdir -p "$WATCH_STATE_UNREACHABLE"
cp "$WATCH_STATE/ios.meta" "$WATCH_STATE_UNREACHABLE/ios.meta"
touch "$WATCH_STATE_UNREACHABLE/home-summary.json"
ssh_before=$(cat "$SSH_COUNT" 2>/dev/null || printf '0')
FM_FAKE_SSH_MODE=unreachable FM_STATE_OVERRIDE="$WATCH_STATE_UNREACHABLE" \
  FM_SECONDMATE_LIVENESS_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  remote_env exec "$ROOT/bin/fm-watch.sh" \
  > "$TMP_ROOT/watch-unreachable.out" 2> "$TMP_ROOT/watch-unreachable.err" &
watch_pid=$!
sleep 4
kill -0 "$watch_pid" 2>/dev/null \
  || fail "the watcher exited against an unreachable remote secondmate: $(cat "$TMP_ROOT/watch-unreachable.out" "$TMP_ROOT/watch-unreachable.err")"
kill "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
watch_pid=''
sleep 1
ssh_after=$(cat "$SSH_COUNT" 2>/dev/null || printf '0')
[ "$ssh_after" -gt "$ssh_before" ] || fail "the unreachable remote endpoint was never probed"
# A watcher that survives this stop keeps probing into the fixture root until
# the EXIT trap races its removal, so prove nothing polls past a few cycles.
touch "$TMP_ROOT/watch-unreachable.stopped"
sleep 3
[ "$(cat "$SSH_COUNT" 2>/dev/null || printf '0')" = "$ssh_after" ] \
  || fail "the stopped unreachable watcher kept probing the remote endpoint"
[ -z "$(find "$WATCH_STATE_UNREACHABLE" -newer "$TMP_ROOT/watch-unreachable.stopped" -print)" ] \
  || fail "the stopped unreachable watcher kept writing its state"
[ ! -s "$WATCH_STATE_UNREACHABLE/.wake-queue" ] \
  || fail "an unreachable remote probe queued a wake: $(cat "$WATCH_STATE_UNREACHABLE/.wake-queue")"
assert_absent "$WATCH_STATE_UNREACHABLE/.secondmate-relaunch-ios" \
  "an unreachable remote probe ledgered a relaunch attempt"
assert_grep 'remote_host=remote-mac' "$WATCH_STATE_UNREACHABLE/ios.meta" \
  "an unreachable remote probe changed the route metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" \
  "an unreachable remote probe changed the registry route"
pass "watch liveness: an unreachable remote secondmate is probed, preserved, and never failed over"

# --- a stale herdr client shadowing the one the server accepts --------------
# The remote host's job PATH can resolve an older self-updated herdr ahead of
# the one its running server accepts; the server then refuses every command
# from it with protocol_mismatch. The host-local state read must still reach
# the live endpoint through the accepted client.
make_herdr_client_pair "$TMP_ROOT/client-pair" 0.7.1 14 0.7.5 16
export FM_HERDR_PAIR_DIR="$TMP_ROOT/client-pair"
SHADOWED_STATE=$(FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  PATH="$TMP_ROOT/client-pair/stale:$REMOTE_ROOT/bin:$TMP_ROOT/client-pair/tools:/usr/bin:/bin" \
  "$REMOTE_ROOT/bin/fm-remote-secondmate-control.sh" state ios 2>"$TMP_ROOT/shadowed-state.err")
[ "$SHADOWED_STATE" = alive ] \
  || fail "a live endpoint behind a stale shadowing client must still read alive, got: $SHADOWED_STATE ($(cat "$TMP_ROOT/shadowed-state.err"))"
assert_contains "$(cat "$TMP_ROOT/client-pair/stale.log")" 'pane get' "the stale client was not the one the job PATH resolved first"
unset FM_HERDR_PAIR_DIR
pass "the host-local state read steps around a stale shadowing herdr client"

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-liveness-legacy.meta"
cp "$PARENT/state/ios.meta" "$TMP_ROOT/parent-ios-before-liveness-legacy.meta"
cp "$PARENT/data/secondmates.md" "$TMP_ROOT/registry-before-liveness-legacy.md"
cat > "$remote_route_meta" <<EOF
window=firstmate:fm-ios
worktree=$REMOTE_HOME
project=$REMOTE_ROOT
harness=codex
kind=secondmate
backend=tmux
EOF
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-liveness-legacy.meta"
printf 'fm-ios|%s\n' "$REMOTE_HOME" > "$TMUX_STATE"
tmux_state_before=$(cat "$TMUX_STATE")
launches_before_legacy=$(grep -c '^tab create' "$HERDR_LOG" || true)
BOOT_LEGACY=$(remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_contains "$BOOT_LEGACY" "SECONDMATE_LIVENESS: secondmate ios: skipped: remote endpoint state is unverified on remote-mac" \
  "liveness accepted an alive legacy remote backend"
cmp -s "$TMP_ROOT/remote-ios-liveness-legacy.meta" "$remote_route_meta" \
  || fail "liveness rewrote the alive legacy endpoint metadata"
cmp -s "$TMP_ROOT/parent-ios-before-liveness-legacy.meta" "$PARENT/state/ios.meta" \
  || fail "liveness rewrote the parent route metadata for an alive legacy endpoint"
cmp -s "$TMP_ROOT/registry-before-liveness-legacy.md" "$PARENT/data/secondmates.md" \
  || fail "liveness changed the registry route for an alive legacy endpoint"
[ "$(cat "$TMUX_STATE")" = "$tmux_state_before" ] \
  || fail "liveness changed or killed the alive legacy endpoint"
launches_after_legacy=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before_legacy" -eq "$launches_after_legacy" ] \
  || fail "liveness relaunched an alive legacy endpoint"
mv -f "$TMP_ROOT/remote-ios-before-liveness-legacy.meta" "$remote_route_meta"
rm -f "$TMUX_STATE"
pass "startup reports alive legacy backends without changing their routes"
echo "ALL TESTS PASSED"
