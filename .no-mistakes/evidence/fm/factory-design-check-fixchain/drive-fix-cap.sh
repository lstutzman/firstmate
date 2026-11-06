#!/usr/bin/env bash
# Drives bin/fm-officer.sh run surgeon in a disposable fixture world, then delivers the capped request via fm-inbox.sh into a lab home.
set -u
W=$1
cd "$W/tests"
eval "$(sed -n '1,955p' fm-officer-surgeon.test.sh | sed 's#\$(dirname "\${BASH_SOURCE\[0\]}")#'"$W"'/tests#')"
step() { echo; echo "== $*"; }
make_world capdrive "${LINEAR_ON}jev: $TMP_ROOT/capdrive/jev.py; "; home=$WORLD_HOME
fake_jev "$TMP_ROOT/capdrive/jev.py"
printf 'Older report.\\nFound: 2 times (first 2026-10-01, last 2026-10-20, by surgeon)' > "$LDIR/pc9.desc"
set_pages capdrive '[]' '[{"fp":"f1","title":"Crash on save duplicate-me","disposition":"new","severity":"P2"}]'
json="$home/data/officers/surgeon/$DATE.json"; state="$home/data/officers/surgeon/review-state.json"
step "S1 first run: recurring P2 finding PC-9 starts"
run_surgeon "$home" >/dev/null || { echo FAIL run; exit 1; }
jq -c '[.start_requests[] | {kind, issue}]' "$json"
fp=$(jq -r '.start_requests[0].fingerprint' "$json"); jq -c --arg fp "$fp" '{starts_by_fp: .starts_by_fp[$fp]}' "$state"
step "S2 fixes never chain: same item fails again on a later day -> no second start"
run_surgeon_next_day "$home" capdrive >/dev/null || echo "run rc=$?"
jq -c '{start_requests: [.start_requests[] | {kind, issue}], asks: [.asks_for_lee[].key]}' "$home/data/officers/surgeon/$DATE2.json"
jq -c --arg fp "$fp" '{starts_by_fp: .starts_by_fp[$fp]}' "$state"
step "S3 boundary: 2 prior starts (PC-1,PC-2), PC-9 recurs -> third start allowed"
jq --arg fp "$fp" 'del(.handled["PC-9"]) | .starts_by_fp[$fp] = ["PC-1","PC-2"]' "$state" > "$state.t" && mv "$state.t" "$state"
run_surgeon "$home" >/dev/null || echo FAIL
jq -c '[.start_requests[] | {kind, issue}]' "$json"; jq -c --arg fp "$fp" '.starts_by_fp[$fp]' "$state"
step "S4 cap: 3 prior starts (PC-1..3), PC-9 recurs -> no 4th start, one capped-repeat request, nothing in asks_for_lee"
jq --arg fp "$fp" 'del(.handled["PC-9"]) | .starts_by_fp[$fp] = ["PC-1","PC-2","PC-3"]' "$state" > "$state.t" && mv "$state.t" "$state"
run_surgeon "$home" >/dev/null || echo FAIL
jq '{start_requests: [.start_requests[] | {kind, issue, tries, ask_key, reason, home: .execute.env.FM_HOME, rid: .execute.request_id}], asks_for_lee: [.asks_for_lee[].key]}' "$json"
jq -c --arg fp "$fp" '{starts_by_fp_after_cap: .starts_by_fp[$fp]}' "$state"
echo "-- digest lines for start requests:"; grep -h -i "fix-cap" "$home/data/officers/surgeon/"*.md 2>/dev/null | head -5
rid1=$(jq -r '.start_requests[0].execute.request_id' "$json")
step "S5 same-day rerun: capped request repeats with the same request id (idempotent)"
run_surgeon "$home" >/dev/null || echo FAIL
jq -c '[.start_requests[] | {kind, issue, rid: .execute.request_id}]' "$json"; echo "first rid=$rid1"
step "S6 next day: capped item is not asked again"
run_surgeon_next_day "$home" capdrive "$DATE3" 2 >/dev/null || echo "rc=$?"
jq -c '{start_requests: [.start_requests[] | {kind, issue}], asks: [.asks_for_lee[].key]}' "$home/data/officers/surgeon/$DATE3.json"
step "S7 deliver the capped request through fm-inbox.sh into a disposable lab home (the office lane)"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null
argv=$(jq -c '.start_requests[0].execute.argv' "$json")
mapfile -t A < <(jq -r '.[]' <<<"$argv")
echo "-- first delivery:"; FM_HOME="$LAB" "${A[@]}" | jq -c '{outcome, id}' 2>/dev/null || FM_HOME="$LAB" "${A[@]}"
echo "-- second delivery (replay):"; FM_HOME="$LAB" "${A[@]}" | jq -c '{outcome, id}' 2>/dev/null
echo "-- lab inbox list:"; FM_HOME="$LAB" "$W/bin/fm-inbox.sh" list | head -20
echo "-- note body tail:"; grep -rl "fix-cap" "$LAB" | head -3; f=$(grep -rl "surgeon-PC-9-fix-cap" "$LAB" | head -1); [ -n "$f" ] && grep -o "This is a capped repeat[^\"]*Lee decides the next step." "$f" | head -1
rm -rf "$LAB"; rm -rf "$TMP_ROOT"
