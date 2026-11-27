#!/usr/bin/env bash
# tests/fm-remote-secondmate-adopt.test.sh - bin/fm-remote-secondmate-adopt.sh,
# the parent-side wrapper that rebinds a remote secondmate's route to an agent
# already running on its host.
#
# The wrapper runs the host-local adopt verb through fm-on.sh and then rewrites
# the parent's own remote_herdr_session= and remote_target= from the route the
# host confirmed. A refused or malformed adopt must leave the parent's record
# untouched, and a plain session name is accepted only with the host's
# selection marker. The remote transport is faked at the SSH boundary exactly
# as tests/fm-remote-secondmate-relaunch.test.sh fakes it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

TMP=$(fm_test_tmproot fm-remote-secondmate-adopt)
HOME_DIR="$TMP/home"
FAKEBIN=$(fm_fakebin "$TMP/fake")
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
SID=b3ba97e9-bcd8-4d07-af30-1e71b5ecd936

printf -- '- gil - Gilligan (host: remote-mac; root: /srv/fm; home: /srv/fm-home; scope: ops; projects: alpha; added 2026-08-01)\n' \
  > "$HOME_DIR/data/secondmates.md"

reset_meta() {
  fm_write_meta "$HOME_DIR/state/gil.meta" \
    "window=remote:gil" \
    "endpoint_task_id=gil" \
    "worktree=/srv/fm-home" \
    "project=/srv/fm" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=/srv/fm-home" \
    "projects=alpha" \
    "remote_host=remote-mac" \
    "remote_root=/srv/fm" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:wHJ:p2"
}

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
argv_b64=$4
fields=$(perl -MMIME::Base64=decode_base64 -e '
  my @args=split(/\0/, decode_base64($ARGV[0]));
  print join("\t", map { defined $_ ? $_ : "" } @args[0..3]);
' "$argv_b64")
IFS=$'\t' read -r cmd action id sid <<FIELDS
$fields
FIELDS
printf '%s %s %s\n' "$action" "$id" "$sid" >> "$FM_FAKE_ADOPT_LOG"
[ "$cmd" = fm-remote-secondmate-control.sh ] || exit 93
[ "$action" = adopt ] || exit 94
case "$FM_FAKE_ADOPT_MODE" in
  refuse)
    printf "error: no pane in Herdr session 'default' holds agent session %s\n" "$sid" >&2
    exit 1
    ;;
  no-route) printf 'adopted\n'; exit 0 ;;
  foreign-session) session=fm-other; source= ;;
  unmarked-plain) session=default; source= ;;
  *) session=default; source=selected ;;
esac
printf 'schema=fm-remote-secondmate-control.v1\n'
printf 'backend=herdr\n'
printf 'target=%s:wXA:p2\n' "$session"
printf 'herdr_session=%s\n' "$session"
[ -z "$source" ] || printf 'herdr_session_source=%s\n' "$source"
printf 'harness=claude\nmodel=\neffort=\n'
SH
chmod +x "$FAKEBIN/fake-ssh"

run_adopt() { # <args...>
  env FM_HOME="$HOME_DIR" FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    FM_FAKE_ADOPT_LOG="$TMP/ssh.log" FM_FAKE_ADOPT_MODE="${FM_FAKE_ADOPT_MODE:-}" \
    "$ROOT/bin/fm-remote-secondmate-adopt.sh" "$@" 2>&1
}

# --- a confirmed adopt rewrites exactly the two route fields, in place --------
reset_meta
printf 'pr=https://github.com/example/repo/pull/1\n' >> "$HOME_DIR/state/gil.meta"
OUT=$(run_adopt gil "$SID"); RC=$?
expect_code 0 "$RC" "a confirmed adopt should succeed"$'\n'"$OUT"
grep -Fx 'remote_herdr_session=default' "$HOME_DIR/state/gil.meta" >/dev/null || fail "the parent's session was not rebound"
grep -Fx 'remote_target=default:wXA:p2' "$HOME_DIR/state/gil.meta" >/dev/null || fail "the parent's target was not rebound"
assert_no_grep 'wHJ' "$HOME_DIR/state/gil.meta" "the hidden pane is still recorded"
grep -Fx 'harness=claude' "$HOME_DIR/state/gil.meta" >/dev/null || fail "an unrelated field changed"
[ "$(tail -n 1 "$HOME_DIR/state/gil.meta")" = 'pr=https://github.com/example/repo/pull/1' ] \
  || fail "the rewrite moved the pr= identity out of last place"
assert_grep "adopt gil $SID" "$TMP/ssh.log" "the host verb did not receive the id and agent session"
pass "a confirmed adopt rebinds the parent's session and target in place"

# --- every refusal leaves the parent's record byte-identical ------------------
for mode in refuse no-route foreign-session unmarked-plain; do
  reset_meta
  cp "$HOME_DIR/state/gil.meta" "$TMP/before.meta"
  FM_FAKE_ADOPT_MODE=$mode
  OUT=$(run_adopt gil "$SID"); RC=$?
  unset FM_FAKE_ADOPT_MODE
  [ "$RC" -ne 0 ] || fail "mode $mode: a bad adopt was reported as successful"$'\n'"$OUT"
  case "$mode" in
    refuse) assert_contains "$OUT" "no pane in Herdr session" "the host's refusal did not reach the caller" ;;
    no-route) assert_contains "$OUT" "reported no route confirmation" "a missing route report was not named" ;;
    *) assert_contains "$OUT" "neither an fm-remote session nor the host's selected session" "a foreign session was not refused by name" ;;
  esac
  cmp -s "$TMP/before.meta" "$HOME_DIR/state/gil.meta" || fail "mode $mode: the parent's record changed"
done
pass "a refused, unconfirmed, or foreign-session adopt leaves the parent's record untouched"

# --- records adopt must not touch ------------------------------------------------
fm_write_meta "$HOME_DIR/state/local1.meta" \
  "window=firstmate:fm-local1" "endpoint_task_id=local1" "worktree=/srv/local1" "project=/srv/local1" \
  "harness=claude" "kind=secondmate" "mode=secondmate" "yolo=off" "home=/srv/local1"
OUT=$(run_adopt local1 "$SID"); RC=$?
[ "$RC" -ne 0 ] || fail "a local secondmate was accepted by the remote adopt tool"
assert_contains "$OUT" "not a remotely placed secondmate" "the refusal did not say why"
OUT=$(run_adopt gil 'bad id'); RC=$?
[ "$RC" -ne 0 ] || fail "an invalid agent session id was accepted"
OUT=$(run_adopt gil); RC=$?
expect_code 2 "$RC" "a missing argument is a usage error"
pass "a local mate, a bad session id, and a missing argument are refused"

echo "ALL TESTS PASSED"
