#!/usr/bin/env bash
# Live drive: the real Surgeon CLI (bin/fm-officer.sh run surgeon) calls the real ~/.local/bin/linear-attach,
# which talks to a local Linear GraphQL emulator (no real Linear, fake token helper). linear-axi is the suite's fake.
set -u
E=$(cd "$(dirname "$0")" && pwd)
cd "$1"
head -n 1229 tests/fm-officer-surgeon.test.sh | sed "s|\$(dirname \"\${BASH_SOURCE\[0\]}\")|$PWD/tests|" > "$E/harness.sh"
. "$E/harness.sh"
PORT=18947; GQL="$E/gql.log"; MODEF="$E/mode"; : > "$GQL"; echo ok > "$MODEF"
python3 "$E/emulator.py" $PORT "$GQL" "$MODEF" & EMU=$!
trap 'kill $EMU 2>/dev/null; wait $EMU 2>/dev/null' EXIT
sleep 1
wire_real_attach() {  # replace the fake linear-attach with the real one pointed at the emulator
  cp "$E/a-desktop.png" "$VISUAL_DIR/captures/shots/a-desktop.png"
  cat > "$FAKEBIN/linear-attach" <<SH
#!/bin/sh
echo "\$*" >> "$LDIR/attach.log"
LINEAR_TOKEN_API_URL=http://127.0.0.1:$PORT/graphql LINEAR_ATTACH_TOKEN=$E/fake-linear-token exec $HOME/.local/bin/linear-attach "\$@"
SH
  chmod +x "$FAKEBIN/linear-attach"
}
section() { printf '\n===== %s =====\n' "$*"; printf '\n===== %s =====\n' "$*" >> "$GQL"; }

section "S1 new visual defect: real linear-attach uploads and attaches the PNG to the new item"
make_visual_world liveok; wire_real_attach; home=$WORLD_HOME
run_surgeon "$home" 2>&1 | tee "$E/s1.out"; echo "exit=${PIPESTATUS[0]}"
echo "--- attach.log"; cat "$LDIR/attach.log"
echo "--- item body screenshot lines"; grep -h 'Screenshot' "$LDIR/bodies"
echo "--- pending_attach state: $(jq -c .pending_attach "$home/data/officers/surgeon/review-state.json")"

section "S2 rate limited (real exit 75): gap + pending, next night retried and attached"
make_visual_world liverl; wire_real_attach; home=$WORLD_HOME; echo ratelimit > "$MODEF"
run_surgeon "$home" 2>&1 | grep -i 'coverage gap' ; echo "--- pending: $(jq -c .pending_attach "$home/data/officers/surgeon/review-state.json")"
echo ok > "$MODEF"; write_visual "$VISUAL_DIR/findings.json" "$VSTAMP2"
run_surgeon_next_day "$home" liverl 2>&1 | grep -i 'coverage gap\|attached' ; echo "exit=${PIPESTATUS[0]}"
echo "--- attach.log"; cat "$LDIR/attach.log"; echo "--- pending after retry: $(jq -c .pending_attach "$home/data/officers/surgeon/review-state.json")"

section "S3 upload refused for rights (real exit 3): named Lee's-call gap, nothing uploaded"
make_visual_world liveforbid; wire_real_attach; home=$WORLD_HOME; echo forbidden > "$MODEF"
run_surgeon "$home" 2>&1 | grep -i 'coverage gap'; echo "exit=${PIPESTATUS[0]}"
echo ok > "$MODEF"

section "S4 closed item recurs: recurrence item gets the screenshot"
make_visual_world liverecur; wire_real_attach; home=$WORLD_HOME
run_surgeon "$home" >/dev/null 2>&1; echo Done > "$LDIR/state.PC-101"; write_visual "$VISUAL_DIR/findings.json" "$VSTAMP2"
run_surgeon_next_day "$home" liverecur 2>&1 | grep -i 'coverage gap'; echo "--- attach.log"; cat "$LDIR/attach.log"
jq -c '.findings[]? | select(.source=="visual" and .filing.action=="created") | .filing' "$home/data/officers/surgeon/$DATE2.json" 2>/dev/null || jq -c '[.. | objects | select(.recurrence_of?)]' "$home/data/officers/surgeon/$DATE2.json"

section "S5 duplicate bump on a later night attaches nothing new"
make_visual_world livebump; wire_real_attach; home=$WORLD_HOME
run_surgeon "$home" >/dev/null 2>&1; write_visual "$VISUAL_DIR/findings.json" "$VSTAMP2"
run_surgeon_next_day "$home" livebump >/dev/null 2>&1; echo "--- attach.log (expect one line)"; cat "$LDIR/attach.log"
grep -c '^issue update PC-101' "$LINEAR_LOG" | sed 's/^/issue update PC-101 calls: /'
echo; echo "TMP_ROOT=$TMP_ROOT"
