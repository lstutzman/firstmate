#!/usr/bin/env bash
# Live driver: real bin/fm-send.sh --resolve-key (local inbox plane; durable enqueue is
# delivery, the doorbell ring is best-effort and tmux is absent on this host) settles
# the escalated pending-reply record the real library built, in a disposable lab home.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME=$LAB; S=$LAB/state
. "$ROOT/bin/fm-pending-reply-lib.sh"
printf 'window=sess:fm-mate\nkind=ship\n' > "$S/mate.meta"
c=$(fm_pending_reply_create "$LAB" "$S" mate "please ack the plan")
fm_pending_reply_mark_delivered "$S" "$c"
fm_pending_reply_set "$(fm_pending_reply_path "$S" "$c")" phase recovery_sending
fm_pending_reply_finish_recovery "$S" "$c" failed
fm_pending_reply_maybe_escalate "$S" "$c" >/dev/null 2>&1
R=$(fm_pending_reply_path "$S" "$c")
echo "before: phase=$(fm_pending_reply_get "$R" phase)"; cat "$S/mate.status"
echo "sweep before:"; bash "$ROOT/bin/fm-pending-reply-sweep.sh" | tail -1
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_SEND_SETTLE=0 timeout 90 \
  "$ROOT/bin/fm-send.sh" mate --resolve-key "pending-reply-$c" "ack, this was already answered"; echo "fm-send exit=$?"
echo "after: phase=$(fm_pending_reply_get "$R" phase) resolved_via=$(fm_pending_reply_get "$R" resolved_via)"
tail -1 "$S/mate.status"
echo "inbox records: $(ls "$S/mate.inbox" 2>/dev/null | wc -l)"
echo "sweep after:"; bash "$ROOT/bin/fm-pending-reply-sweep.sh" | tail -1
rm -rf "$LAB"; [ ! -e "$LAB" ] && echo "lab removed"
