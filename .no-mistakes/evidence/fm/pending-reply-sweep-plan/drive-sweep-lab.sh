#!/usr/bin/env bash
# Live driver: real fm-pending-reply-lib.sh builds records in a disposable lab home,
# then the real bin/fm-pending-reply-sweep.sh and bin/fm-retention.sh run against it.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME=$LAB
S=$LAB/state
. "$ROOT/bin/fm-pending-reply-lib.sh"
. "$ROOT/bin/fm-wake-lib.sh"
mk() { # <task> <text> <delivered:0|1> -> corr ; real create + failed recovery + real escalation
  local c; c=$(fm_pending_reply_create "$LAB" "$S" "$1" "$2") || return 1
  [ "$3" = 1 ] && fm_pending_reply_mark_delivered "$S" "$c"
  fm_pending_reply_set "$(fm_pending_reply_path "$S" "$c")" phase recovery_sending
  fm_pending_reply_finish_recovery "$S" "$c" failed
  fm_pending_reply_maybe_escalate "$S" "$c" >/dev/null 2>&1
  printf '%s' "$c"
}
echo "== lab home: $LAB"
C_OPCLOSED=$(mk slarti "merge https://github.com/o/r/pull/1 please" 1)
C_OPEN=$(mk slarti "please review the plan and reply" 1)
C_UNDEL=$(mk cl-keeper "file the board card" 0)
C_UNPROVEN=$(mk cl-keeper "rotate nothing, just ack" 1)
# operator already closed C_OPCLOSED's escalation in the library vocabulary (as fm-send --resolve-key writes it)
fm_wake_status_append_self_announced "$S" "$S/slarti.status" \
  "resolved [key=pending-reply-$C_OPCLOSED]: $(fm_pending_reply_resolved_note slarti "$C_OPCLOSED" operator-resolve-key) ack" >/dev/null
# C_UNPROVEN: escalation line removed (never written)
grep -v "pending-reply-$C_UNPROVEN" "$S/cl-keeper.status" > "$S/x" && mv "$S/x" "$S/cl-keeper.status"
for c in $C_OPCLOSED $C_OPEN $C_UNDEL $C_UNPROVEN; do echo "record $c phase=$(fm_pending_reply_get "$(fm_pending_reply_path "$S" $c)" phase) delivered=$(fm_pending_reply_get "$(fm_pending_reply_path "$S" $c)" delivered_epoch)"; done
echo "== slarti.status"; cat "$S/slarti.status"; echo "== cl-keeper.status"; cat "$S/cl-keeper.status"
snap() { (cd "$S" && find . -type f ! -name '*.lock' | sort | xargs cksum); }
echo; echo "### S1 dry run"; B=$(snap)
bash "$ROOT/bin/fm-pending-reply-sweep.sh"; echo "exit=$?"
[ "$(snap)" = "$B" ] && echo "S1 home unchanged by dry run: YES" || echo "S1 home unchanged: NO"
echo; echo "### S2 --apply (no keys)"
bash "$ROOT/bin/fm-pending-reply-sweep.sh" --apply; echo "exit=$?"
echo "opclosed phase=$(fm_pending_reply_get "$(fm_pending_reply_path "$S" $C_OPCLOSED)" phase) via=$(fm_pending_reply_get "$(fm_pending_reply_path "$S" $C_OPCLOSED)" resolved_via)"
echo "open phase=$(fm_pending_reply_get "$(fm_pending_reply_path "$S" $C_OPEN)" phase)"
echo; echo "### S4 adversarial --apply --key on undelivered, unproven, unknown"
B1=$(cksum < "$S/cl-keeper.status")
bash "$ROOT/bin/fm-pending-reply-sweep.sh" --apply --key "pending-reply-$C_UNDEL" --key "pending-reply-$C_UNPROVEN,pending-reply-0000000000000000"; echo "exit=$?"
[ "$(cksum < "$S/cl-keeper.status")" = "$B1" ] && echo "S4 cl-keeper.status unchanged: YES" || echo "S4 cl-keeper.status unchanged: NO"
echo "undel phase=$(fm_pending_reply_get "$(fm_pending_reply_path "$S" $C_UNDEL)" phase) unproven phase=$(fm_pending_reply_get "$(fm_pending_reply_path "$S" $C_UNPROVEN)" phase)"
echo; echo "### S3 --apply --key on delivered open review record"
bash "$ROOT/bin/fm-pending-reply-sweep.sh" --apply --key "pending-reply-$C_OPEN"; echo "exit=$?"
echo "open phase=$(fm_pending_reply_get "$(fm_pending_reply_path "$S" $C_OPEN)" phase) via=$(fm_pending_reply_get "$(fm_pending_reply_path "$S" $C_OPEN)" resolved_via)"
echo "slarti open decisions: [$(status_open_decisions "$S/slarti.status" | cut -f1 | tr '\n' ' ')]"
tail -1 "$S/slarti.status"
echo; echo "### S5 dry run after: totals"
bash "$ROOT/bin/fm-pending-reply-sweep.sh" | tail -1
echo; echo "### S6 retention long tail: 3000 old resolved, 5 young resolved, 1 marker-named, + escalated kept"
D=$S/pending-replies; old=1700000000
for i in $(seq 1 3000); do c=$(printf 'b%015x' $i); printf 'schema=fm-pending-reply.v1\ncorr_id=%s\ntask_id=slarti\nphase=resolved\nescalated_epoch=\nescalation_closed_epoch=\nresolved_epoch=%s\nresolved_via=status\n' $c $((old+i)) > $D/$c; done
for i in 1 2 3 4 5; do c=$(printf 'c%015x' $i); printf 'phase=resolved\nescalated_epoch=\nresolved_epoch=1799990000\n' > $D/$c; done
c=d000000000000001; printf 'phase=resolved\nescalated_epoch=1\nescalation_closed_epoch=\nresolved_epoch=%s\n' $old > $D/$c   # resolved but escalation never closed: keep
c=e000000000000001; printf 'phase=resolved\nescalated_epoch=\nresolved_epoch=%s\n' $old > $D/$c; printf 'pending:%s\n' $c > $S/.backlog-handoff-slarti.wake-pending
echo "records before: $(ls $D | grep -cE '^[0-9a-f]{16}$')"
t0=$(date +%s.%N); FM_RETENTION_NOW=1800000000 bash "$ROOT/bin/fm-retention.sh" run --force; echo "exit=$?"; t1=$(date +%s.%N)
echo "elapsed=$(echo "$t1 - $t0" | bc)s"
echo "records after: $(ls $D | grep -cE '^[0-9a-f]{16}$')"
for c in $C_OPCLOSED $C_OPEN $C_UNDEL $C_UNPROVEN d000000000000001 e000000000000001 c000000000000001; do [ -f $D/$c ] && echo "kept $c" || echo "removed $c"; done
ar=$(ls $S/*pending-replies-*.tar.gz $S/*/pending-replies-*.tar.gz 2>/dev/null | head -1); echo "archive=$ar entries=$(tar tzf "$ar" | grep -c .)"
echo; echo "### teardown"; rm -rf "$LAB"; [ ! -e "$LAB" ] && echo "lab removed"
