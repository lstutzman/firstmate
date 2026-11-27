#!/usr/bin/env bash
# Bind a REMOTE secondmate's route to an agent that is already running on its
# host, then republish this parent's own route record to match.
#
# Usage: fm-remote-secondmate-adopt.sh <id> <agent_session_id>
#
# For a mate whose endpoint is gone but whose agent is alive in another Herdr
# pane, for example one started by hand in the user's visible session. An agent
# started without Firstmate's launch flags is accepted when the host's proofs
# pass: the pane holds that agent session, its agent matches the recorded
# harness, and the home's state/.lock and state/.lock-session name a live
# harness process inside that pane whose working directory is the mate's home.
# This never launches, relaunches, or stops anything.
#
# bin/fm-remote-secondmate-control.sh's adopt verb runs on the secondmate's
# host and rewrites only the host's endpoint record (its header owns the proofs).
# This parent's route record (state/<id>.meta here, marked remote_host=... to a
# different machine) is a separate file that verb cannot reach. This wrapper is
# the other half, shaped like bin/fm-remote-secondmate-relaunch.sh: it runs the
# host verb through bin/fm-on.sh, reads the confirmed session and target back
# out of the endpoint's own route report, and rewrites remote_herdr_session=
# and remote_target= in place. A refused or failed adopt leaves this parent's
# record untouched. Steers to the mate then ring the adopted pane.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-remote-herdr-identity-lib.sh
. "$SCRIPT_DIR/fm-remote-herdr-identity-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ "$#" -eq 2 ] || usage
ID=$1
SESSION_ID=$2
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac
case "$SESSION_ID" in ''|*[!A-Za-z0-9._-]*) die "invalid agent session id" ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "no metadata for $ID at $META"
REMOTE_HOST=$(fm_meta_get "$META" remote_host)
[ -n "$REMOTE_HOST" ] \
  || die "task $ID is not a remotely placed secondmate; adopt applies only to a remote route"
# A record written before rex existed names no backend, which means herdr
# (bin/fm-spawn.sh and the liveness sweep read it the same way).
RECORDED_BACKEND=$(fm_meta_get "$META" remote_backend)
[ "${RECORDED_BACKEND:-herdr}" = herdr ] \
  || die "task $ID is recorded on the $RECORDED_BACKEND backend; adopt binds only a Herdr endpoint"
[ -n "$(fm_meta_get "$META" remote_herdr_session)" ] && [ -n "$(fm_meta_get "$META" remote_target)" ] \
  || die "the record for $ID names no remote_herdr_session and remote_target to rebind"

ADOPT_OUT=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh \
  adopt "$ID" "$SESSION_ID" </dev/null 2>&1) || {
  rc=$?
  printf '%s\n' "$ADOPT_OUT" >&2
  exit "$rc"
}
printf '%s\n' "$ADOPT_OUT"

[ "$(printf '%s\n' "$ADOPT_OUT" | sed -n 's/^schema=//p' | tail -1)" \
  = fm-remote-secondmate-control.v1 ] \
  || die "the host adopted $ID but reported no route confirmation to record"
[ "$(printf '%s\n' "$ADOPT_OUT" | sed -n 's/^backend=//p' | tail -1)" = herdr ] \
  || die "the host's route confirmation is not a Herdr route"
NEW_TARGET=$(printf '%s\n' "$ADOPT_OUT" | sed -n 's/^target=//p' | tail -1)
NEW_SESSION=$(printf '%s\n' "$ADOPT_OUT" | sed -n 's/^herdr_session=//p' | tail -1)
NEW_SOURCE=$(printf '%s\n' "$ADOPT_OUT" | sed -n 's/^herdr_session_source=//p' | tail -1)
# The same acceptance bin/fm-spawn.sh applies to a launched route.
if ! fm_remote_herdr_session_name_valid "$NEW_SESSION" \
  && { [ "$NEW_SOURCE" != selected ] || ! fm_remote_herdr_selectable_session_name "$NEW_SESSION"; }; then
  die "the host reported Herdr session '${NEW_SESSION:-missing}', which is neither an fm-remote session nor the host's selected session; its own record is already rebound, so reconcile this parent's record by hand"
fi
[ -n "$NEW_TARGET" ] && [ "${NEW_TARGET%%:*}" = "$NEW_SESSION" ] \
  || die "the host's route confirmation carried a target outside session '$NEW_SESSION'"

META_LOCK=$(fm_meta_lock_path "$META") || die "metadata lock path is invalid for $ID"
fm_lock_acquire_wait "$META_LOCK"
META_TMP=$(mktemp "$STATE/.fm-remote-adopt-meta.XXXXXX") || {
  fm_lock_release "$META_LOCK"
  die "cannot stage the updated record"
}
# Rewritten in place so every other line, and the order pr= identity lines
# depend on, stays as it was (see bin/fm-remote-secondmate-relaunch.sh).
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    remote_herdr_session=*) printf 'remote_herdr_session=%s\n' "$NEW_SESSION" ;;
    remote_target=*) printf 'remote_target=%s\n' "$NEW_TARGET" ;;
    *) printf '%s\n' "$line" ;;
  esac
done < "$META" > "$META_TMP"
chmod 0600 "$META_TMP"
mv -f -- "$META_TMP" "$META"
fm_lock_release "$META_LOCK"
printf 'adopted %s: route now %s\n' "$ID" "$NEW_TARGET"
