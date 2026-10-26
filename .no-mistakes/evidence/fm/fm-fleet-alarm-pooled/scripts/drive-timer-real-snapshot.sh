#!/usr/bin/env bash
set -u
WT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/fakebin"
trap 'rm -rf "$LAB"' EXIT
clean() { env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
cat > "$LAB/fakebin/cpa-usage-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = models ]; then printf 'models[1]{account,model,requests,failed}:\n  busy@x,claude-opus-5-5,30,0\n'
else printf 'accounts[3]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:\n  idle@x,claude,0,,1.0,2026-10-30T10:00:00Z,,1,0\n  busy@x,claude,0.4,,0.93,2026-10-30T10:00:00Z,,1,0\n  spare@x,claude,0,,0.1,2026-10-30T10:00:00Z,,1,0\n'; fi
SH
chmod +x "$LAB/fakebin/cpa-usage-axi"
touch "$LAB/config/fleet-ledger"
echo "== T1 timer channel: carrying busy@x at 93%, idle@x at 100% not carrying -> Captain's Log card"
clean PATH="$LAB/fakebin:$PATH" python3 "$WT/bin/fm-fleet-alarm.py" timer; echo "rc=$?"
echo "-- state/fleet-alarm.status (card source):"; cat "$LAB/state/fleet-alarm.status"
echo
echo "== T2 real cpa-usage-axi (read-only, live quota data) through the alarm check, no secondmates"
rm -f "$LAB/state/.fleet-alarm.json" "$LAB/config/fleet-ledger"
out=$(clean python3 "$WT/bin/fm-fleet-alarm.py" check 2>&1); echo "rc=$? output: ${out:-<silent>}" | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/<acct>/g'
echo
echo "== T3 fm-fleet-snapshot.sh --json with a 300 KB status line and 90 open decisions with 6 KB text"
python3 - "$LAB" <<'PY'
import sys,time
from pathlib import Path
lab=Path(sys.argv[1]); now=int(time.time())
with (lab/'state/big.status').open('w') as f:
    for i in range(90):
        f.write(f'needs-decision [key=d{i}] [at={now-100}]: ' + 'q'*6000 + '\n')
    f.write(f'working [at={now}]: ' + 'z'*300000 + '\n')
(lab/'state/big.meta').write_text(f'spawn_gen=s{now}.1\nkind=ship\nproject=alpha\n')
PY
start=$(date +%s.%N)
clean timeout 120 "$WT/bin/fm-fleet-snapshot.sh" --json > "$LAB/snap.json" 2> "$LAB/snap.err"; rc=$?
end=$(date +%s.%N)
echo "rc=$rc elapsed=$(python3 -c "print(round($end-$start,2))")s stdout_bytes=$(wc -c < "$LAB/snap.json") stderr: $(head -c 300 "$LAB/snap.err")"
python3 - "$LAB/snap.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
def walk(o,path=''):
    if isinstance(o,dict):
        for k,v in o.items(): yield from walk(v,path+'.'+k)
    elif isinstance(o,list):
        for i,v in enumerate(o): yield from walk(v,path+f'[{i}]')
    else: yield path,o
strs=[(p,v) for p,v in walk(d) if isinstance(v,str)]
longest=max(strs,key=lambda x:len(x[1]))
print('top-level keys:',sorted(d)[:12])
print('longest string field:',longest[0],len(longest[1]),'chars; ends with',repr(longest[1][-20:]))
keys=sorted({v for p,v in walk(d) if p.endswith('.key') and isinstance(v,str) and v.startswith('d')})
print('open decision keys retained:',len(keys))
print('truncation markers:',sum(1 for p,v in strs if v.endswith('[text truncated]')))
PY
