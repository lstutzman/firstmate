#!/usr/bin/env bash
# Machine-service records use the existing inbox and watcher, without a model.
set -euo pipefail

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-inbox-service)
INBOX_BIN="$ROOT/bin/fm-inbox.sh"

run_inbox() {
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" bash "$INBOX_BIN" "$@"
}

record() {
  printf '{"kind":"%s","source":"nightly-scan","item_id":"PC-3385","severity":"high","evidence_path":"/reports/finding.json","request_id":"%s"%s}\n' \
    "$1" "$2" "${3:-}"
}

home="$TMP_ROOT/dispatch"
mkdir -p "$home/state" "$home/data" "$home/config"
receipt=$(record dispatch scan-1 | run_inbox service) || fail "valid dispatch request is accepted"
assert_contains "$receipt" '"saved":true' "service returns an inbox receipt"
assert_contains "$(run_inbox drain)" '"item_id":"PC-3385"' "dispatch remains pending for firstmate"
assert_contains "$(cat "$home/state/.wake-queue")" 'check: machine service dispatch PC-3385' "wake names the dispatch item"
pass "machine dispatch is a durable inbox request"

note_id=$(printf '%s' "$receipt" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
replay=$(record dispatch scan-1 | run_inbox service)
assert_contains "$replay" '"outcome":"replay"' "retry reuses the inbox identity"
assert_equals 1 "$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" "one pending request"
assert_equals 1 "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" "one announcement on retry"
run_inbox drain --ack "$note_id" >/dev/null
assert_absent "$home/state/inbox/$note_id.note" "acknowledgment removes pending entry"
assert_present "$home/state/inbox/handled/$note_id.note" "acknowledgment preserves evidence"
replay=$(record dispatch scan-1 | run_inbox service)
assert_contains "$replay" '"acknowledged":true' "retry after acknowledgment stays handled"
assert_equals 1 "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" "acknowledged retry adds no wake"
pass "request identity and acknowledgment survive retries"

for n in 1 2 3; do
  record dispatch concurrent-1 | run_inbox service >"$home/concurrent-$n.json" &
done
wait
python3 - "$home" <<'PY'
import json, pathlib, sys
receipts = [json.loads(path.read_text()) for path in pathlib.Path(sys.argv[1]).glob("concurrent-*.json")]
assert len(receipts) == 3
assert len({receipt["id"] for receipt in receipts}) == 1
assert sorted(receipt["outcome"] for receipt in receipts) == ["created", "replay", "replay"]
PY
assert_equals 1 "$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" "concurrent retries save one request"
assert_equals 2 "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" "concurrent retries announce once"
concurrent_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$home/concurrent-1.json")
mv "$home/state/inbox/.announced/$concurrent_id" "$home/lost-announcement"
mv "$home/state/.wake-queue" "$home/previous-wakes"
run_inbox service-reconcile
assert_contains "$(cat "$home/state/.wake-queue")" 'request=concurrent-1' "watcher repairs a saved but unannounced request"
run_inbox drain --ack "$concurrent_id" >/dev/null
pass "concurrent submissions and lost announcements keep one durable identity"

for change in \
  'r["kind"]="spawn"' \
  'del r["source"]' \
  'r["item_id"]=12' \
  'r["severity"]="urgent"' \
  'r["request_id"]="../escape"' \
  'r["source"]="scan\nblocked: forged"' \
  'r["key"]="bad]key"' \
  'r["evidence_path"]="relative/path"' \
  'r["evidence_path"]="/report\nblocked: forged"' \
  'r["secret"]="not-allowed"'; do
  invalid=$(record dispatch invalid-1 | python3 -c 'import json,sys; r=json.load(sys.stdin); exec(sys.argv[1]); print(json.dumps(r))' "$change")
  if printf '%s' "$invalid" | run_inbox service >"$home/invalid.out" 2>"$home/invalid.err"; then
    fail "invalid record was accepted: $change"
  fi
done
if printf '{"kind":"dispatch","kind":"notice"}' | run_inbox service >/dev/null 2>&1; then
  fail "duplicate JSON field was accepted"
fi
if run_inbox note --request-id service:collision "ordinary text" >/dev/null 2>&1; then
  fail "human note occupied the service request namespace"
fi
assert_equals 0 "$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" "invalid records create no pending entry"
pass "invalid kinds, missing fields, unsafe framing, and unknown fields are refused"

parent="$TMP_ROOT/parent"
mkdir -p "$parent/state"
printf 'scan-mate\n' > "$home/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$home/.fm-secondmate-parent"
notice=$(record notice notice-1 | run_inbox service)
blocked=$(record blocked blocked-1 ',"key":"scan-failed"' | run_inbox service)
notice_id=$(printf '%s' "$notice" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
blocked_id=$(printf '%s' "$blocked" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
pending_dispatch=$(record dispatch mate-dispatch | run_inbox service)
dispatch_id=$(printf '%s' "$pending_dispatch" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
run_inbox service-reconcile
channel="$parent/state/scan-mate.status"
assert_contains "$(cat "$channel")" 'working [key=machine-' "notice is information only"
assert_contains "$(cat "$channel")" ']: machine service notice source=nightly-scan item=PC-3385 severity=high request=notice-1 evidence=/reports/finding.json' "notice carries identifiers and evidence path"
assert_contains "$(cat "$channel")" 'blocked [key=machine-scan-failed]' "blocker carries its key"
assert_equals 2 "$(wc -l < "$channel" | tr -d ' ')" "dispatch is never relayed as started work"
run_inbox service-reconcile
assert_equals 2 "$(wc -l < "$channel" | tr -d ' ')" "relay retry adds no duplicate line"
assert_present "$home/state/inbox/$notice_id.note" "relay does not acknowledge a note"
run_inbox drain --ack "$notice_id" "$blocked_id" "$dispatch_id" >/dev/null
pass "secondmate relays notice and keyed blocker exactly once before acknowledgment"

mv "$channel" "$parent/saved-channel"
mkdir "$channel"
unwritable=$(record notice unwritable-channel | run_inbox service)
unwritable_id=$(printf '%s' "$unwritable" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
if run_inbox drain --ack "$unwritable_id" >"$home/relay.out" 2>"$home/relay.err"; then
  fail "a directory at the channel path was treated as delivered"
fi
assert_present "$home/state/inbox/$unwritable_id.note" "unwritable destination retains request"
mv "$channel" "$parent/bad-channel"
mv "$parent/saved-channel" "$channel"
run_inbox drain --ack "$unwritable_id" >/dev/null
pass "acknowledgment waits for successful channel append"

printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=test-parent\n' > "$home/.fm-secondmate-parent"
remote=$(record blocked remote-1 | run_inbox service)
remote_id=$(printf '%s' "$remote" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
run_inbox service-reconcile
assert_contains "$(cat "$home/state/parent-replies.status")" 'machine service blocked' "remote route uses its durable parent channel"
run_inbox drain --ack "$remote_id" >/dev/null
printf 'invalid binding\n' > "$home/.fm-secondmate-parent"
failed=$(record notice failed-relay | run_inbox service)
failed_id=$(printf '%s' "$failed" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
if run_inbox drain --ack "$failed_id" >"$home/relay.out" 2>"$home/relay.err"; then
  fail "acknowledgment succeeded without the required parent relay"
fi
assert_present "$home/state/inbox/$failed_id.note" "failed relay stays pending"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$home/.fm-secondmate-parent"
run_inbox drain --ack "$failed_id" >/dev/null
assert_contains "$(cat "$home/state/parent-replies.status")" 'request=failed-relay' "acknowledgment retries a failed relay"
pass "remote relay and failed-relay retention use the parent-channel owner"

# A real watcher must relay on its poll before surfacing the queued request.
home=$(make_case watcher)
mkdir -p "$home/data" "$home/config"
printf 'watch-mate\n' > "$home/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$home/.fm-secondmate-parent"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  PATH="$home/fakebin:$PATH" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  bash "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 15 >"$home/watch.out" 2>"$home/watch.err" &
watch_pid=$!
i=0
while [ ! -e "$home/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
assert_present "$home/state/.last-watcher-beat" "watcher is running before arrival"
record notice watcher-1 | run_inbox service >"$home/receipt.json"
wait "$watch_pid" || fail "watcher did not wake on service arrival: $(cat "$home/watch.err")"
assert_contains "$(cat "$home/watch.out")" 'check:' "arrival wakes firstmate"
assert_contains "$(cat "$parent/state/watch-mate.status")" 'request=watcher-1' "watcher relays before wake"
pass "real watcher wakes and relays a machine-service arrival"

home=$(make_case watcher-relay-failure)
mkdir -p "$home/data" "$home/config"
printf 'broken-mate\n' > "$home/.fm-secondmate-home"
record blocked watcher-failed | run_inbox service >"$home/receipt.json"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  PATH="$home/fakebin:$PATH" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  bash "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 15 >"$home/watch.out" 2>"$home/watch.err" \
  || fail "relay failure did not wake firstmate"
assert_contains "$(cat "$home/watch.out")" 'check: machine service relay failed' "watcher exposes failed parent delivery"
assert_contains "$(run_inbox drain)" 'watcher-failed' "undelivered record stays pending"
pass "watcher surfaces a broken parent route without losing the request"
