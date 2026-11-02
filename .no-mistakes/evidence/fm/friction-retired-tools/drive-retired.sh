#!/usr/bin/env bash
# Driver: runs the real friction officer (bin/fm-officer.sh run friction) in a disposable home.
# usage: drive-retired.sh <repo-root> <defs.sh>
set -u
REPO=$1; cd "$1/tests"
. "$2"
OFFICER="$1/bin/fm-officer.sh"
home=$(make_world drv)
# agent-side: railway & zzztool command not found x3; Lee-side: Lee types `brew install railway` x3
jq --argjson t "$T" '.sessions[1].calls += [range(3) as $i | "railway", "zzztool" | ["Bash", {"command": "x"}, "/bin/bash: line 4: \(.): command not found", true]]
  | .sessions[0].raw += [range(3) as $i | {"type":"user","timestamp":("2026-10-23T11:0\($i):00.000Z"),"message":{"content":"<bash-input>brew install railway</bash-input>"}}]' \
  "$TMP_ROOT/drv/spec.json" > "$TMP_ROOT/drv/spec2.json"
officer_archive "$TMP_ROOT/drv/archive" "$DATE" "$TMP_ROOT/drv/spec2.json"
run_officer "$home" >/dev/null; echo "officer exit=$?"
dir="$home/data/officers/friction"
echo "== findings for railway / zzztool (json) =="
jq -c '.findings[] | select(.name=="railway" or .name=="zzztool") | {id,cause,sub,name,events,lee_events,severity,carded,title,fix}' "$dir/$DATE.json"
echo "== velocity cards mentioning railway / zzztool =="
jq -c '[.bottlenecks[] | select((.id|test("railway|zzztool")) or ((.improvement//"")|test("railway|zzztool")))] | map({id,improvement})' "$dir/$DATE.velocity-findings.json"
echo "== digest lines mentioning railway =="
grep -n -i -A3 "railway" "$dir"/$DATE.md | head -30
rm -rf "$TMP_ROOT"
