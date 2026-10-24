#!/usr/bin/env bash
# Live drive of the officer kind in a disposable lab home. Run from the gate worktree.
set -u
WT=$PWD
EV=/home/lee/.no-mistakes/evidence/01M5Q418J8HAXSBXYZHMM74JS0
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-work.XXXXXX")
trap 'TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null; rm -rf "$LAB" "$WORK"' EXIT
rmdir "$LAB" && bin/fm-lab-home.sh create "$LAB" >/dev/null && mkdir -p "$LAB/tmux"
chmod 700 "$LAB/state"
E() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
drain_ack() {  # act as the lab captain: drain and acknowledge the lab wake queue
  local err seq gen
  err=$(E bin/fm-wake-drain.sh 2>&1 >"$WORK/drain.out")
  seq=$(printf '%s\n' "$err" | sed -n 's/.*--ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p')
  gen=$(printf '%s\n' "$err" | sed -n 's/.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p')
  echo "  drained: $(cut -f3- "$WORK/drain.out" | sed "s#$LAB#\$LAB#g" | tr '\n' '|')"
  [ -n "$seq" ] && E bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
hdr() { printf '\n===== %s =====\n' "$*"; }
DATE=$(date -d yesterday +%Y-%m-%d)
ARCH="$WORK/archive"
HOME_REAL=$(cd "$LAB" && pwd -P)

# --- fixture archive in the transcript-archive layout --------------------------------
cat > "$WORK/spec.py" <<'PY'
import json, sys
home, date, mate, briefed = sys.argv[1], sys.argv[2], sys.argv[4], sys.argv[5]
brief = ("FIRSTMATE_OP: v1 launch-brief: # Current worker role contract\n"
         "Your steering inbox is `%s/state/t1.inbox`; read it.\n" % home)
heredoc = "cat > /tmp/x.sh <<'EOF'\nrm -f -- \"$tmp\"\npkill -f thing\nEOF"
ghp = "ghp_" + "Ab1Cd2" + "x1" * 14
aws = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
calls = [
  ["Read", {"file_path": "%s/state/t1.inbox" % home}, brief, False],
  ["Bash", {"command": "rm -f build.log"}, "", False],
  ["Bash", {"command": "pkill -f vite"}, "", False],
  ["Bash", {"command": "cat ~/.zshrc"}, "export X=1", False],
  ["Bash", {"command": heredoc}, "", False],
  ["Bash", {"command": "sleep 30 && cat status"}, "working", False],
  ["Bash", {"command": "sleep 30 && cat status"}, "working", False],
  ["Edit", {"file_path": "/w/e2e.spec.ts", "old_string": "a",
            "new_string": "await page.waitForLoadState('networkidle')"}, "ok", False],
  ["Bash", {"command": "gh pr create --title t --body \"## Summary\nonly a summary\""}, "url", False],
  ["Bash", {"command": "deploy --token " + ghp}, "bash: " + ghp + ": command not found", True],
  ["Bash", {"command": "aws s3 ls"}, "InvalidSignature for secret " + aws + " rejected", True],
  ["Bash", {"command": "git push --force"}, "PreToolUse hook error: BLOCKED by guard", True],
  ["Bash", {"command": "git push --force"}, "PreToolUse hook error: BLOCKED by guard", True],
  ["Read", {"file_path": "/w/a.txt"}, "x", False],
  ["Read", {"file_path": "/w/a.txt"}, "x", False],
]
sessions = [
  {"machine": "alpha", "id": "w1", "cwd": "/w",
   "first_prompt": "Firstmate operational input waiting: read '%s/state/operational-inbox/1.msg'" % home,
   "calls": calls},
  {"machine": "alpha", "id": "m1", "cwd": home, "first_prompt": "good morning, what is the fleet doing?", "calls": []},
  {"machine": "alpha", "id": "n1", "cwd": "/tmp/nm", "first_prompt": "Workspace boundary (important):\n- stay", "calls": []},
  {"machine": "alpha", "id": "c1", "cwd": "/tmp", "first_prompt": "You are a wake classifier. Label this.", "calls": []},
  {"machine": "alpha", "id": "r1", "cwd": "/tmp", "first_prompt": "You review this diff as a read-only reviewer.", "calls": []},
  {"machine": "alpha", "id": "m2", "cwd": mate, "first_prompt": "ahoy from the second mate", "calls": []},
  {"machine": "alpha", "id": "w2", "cwd": "/w2",
   "first_prompt": "Firstmate operational input waiting: read 'x'",
   "calls": [["Read", {"file_path": "/x"}, "FIRSTMATE_OP: v1 launch-brief: # Current worker role contract\nYour steering inbox is `%s/state/t9.inbox`; read it.\n" % briefed, False]]},
  {"machine": "alpha", "id": "m3", "cwd": briefed, "first_prompt": "status of the briefed home?", "calls": []},
  {"machine": "alpha", "id": "o1", "cwd": "/somewhere/else", "first_prompt": "random chat", "calls": []},
]
json.dump({"sessions": sessions}, open(sys.argv[3], "w"))
PY
MATE="$WORK/mate-home"; mkdir -p "$MATE/state" "$MATE/data"; MATE=$(cd "$MATE" && pwd -P)
BRIEFED=/srv/remote-only-home   # named only in a worker launch brief; not readable here
printf -- '- mate - lab second mate (home: %s; scope: lab; projects: sample; added %s)\n' "$MATE" "$(date +%F)" > "$LAB/data/secondmates.md"
python3 -I "$WORK/spec.py" "$HOME_REAL" "$DATE" "$WORK/spec.json" "$MATE" "$BRIEFED"
( . tests/officer-helpers.sh; officer_archive "$ARCH" "$DATE" "$WORK/spec.json" )
printf 'working\ndone: PR ready\n' > "$LAB/state/t1.status"
printf 'worktree=/w\n' > "$LAB/state/t1.meta"

# --- registry -------------------------------------------------------------------------
cat > "$LAB/data/officers.md" <<EOF
# Officers
- triage - Joins each day's archived sessions to firstmate tasks and outcomes (role: triage; cadence: daily 00:00; archive: $ARCH; hosts: alpha,beta; model: none; added $(date +%F))
EOF

hdr "S1 register / list / ensure (healthy)"
E bin/fm-officer.sh register triage; echo "register rc=$?"
E bin/fm-officer.sh list
ls -l "$LAB/state/officer-triage.check.sh" | awk '{print $1, $NF}'
echo "--- ensure output (expect nothing):"; E bin/fm-officer.sh ensure; echo "--- ensure rc=$?"

hdr "S2 real watcher sweeps: check starts the due run detached, then the watcher surfaces one check: wake"
for i in 1 2 3 4; do
  E FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    timeout 60 bin/fm-watch.sh > "$WORK/watch$i.out" 2> "$WORK/watch$i.err"; rc=$?
  echo "watcher pass $i rc=$rc stdout: $(sed "s#$LAB#\$LAB#g" "$WORK/watch$i.out")"
  drain_ack
  grep -q 'officer triage' "$WORK/watch$i.out" && break
done
echo "--- runs.log:"; cat "$LAB/data/officers/triage/runs.log"
echo "--- digest:"; cat "$LAB/data/officers/triage/digest"

hdr "S2b repeat watcher sweep: same digest is not surfaced again"
E FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
  timeout 20 bin/fm-watch.sh > "$WORK/watchR.out" 2>&1; echo "watcher rc=$? (124 = ran 20s with no wake)"
grep -c 'officer triage' "$WORK/watchR.out"
echo "--- direct check (expect nothing):"; E bash "$LAB/state/officer-triage.check.sh"; echo "check rc=$?"

hdr "S3 rendered digest"
cat "$LAB/data/officers/triage/$DATE.md"
cp "$LAB/data/officers/triage/$DATE.md" "$EV/triage-digest.md"
python3 -I - "$LAB/data/officers/triage/$DATE.json" > "$EV/triage-digest-summary.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
w = [s for s in d["sessions"] if s["class"] == "worker"][0]
print(json.dumps({k: d[k] for k in ("session_mix", "coverage", "workers", "wasted_turns", "top_errors", "findings", "actionable")}
  | {"worker_session": {k: w.get(k) for k in ("session", "join", "duration_s", "turns", "tokens", "cost_usd", "violations")}}, indent=1, sort_keys=True))
PY
echo "--- heredoc body counted as commands? rm-not-trash hits:"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print([f["summary"] for f in d["findings"] if f.get("rule") in ("rm-not-trash","pkill-f")]); print({s["session"]: s["class"] for s in d["sessions"]})' "$LAB/data/officers/triage/$DATE.json"

hdr "S4 secrets never reach the lane"
for s in ghp_Ab1Cd2 wJalrXUtnFEMI K7MDENG EXAMPLEKEY "only a summary" "good morning"; do
  if grep -rqF "$s" "$LAB/data/officers/"; then echo "LEAK: $s"; else echo "absent: $s"; fi
done

hdr "S5 re-run the same day is byte-identical"
sha256sum "$LAB/data/officers/triage/$DATE".{json,md} > "$WORK/a.sum"
find "$LAB" -path "$LAB/data/officers" -prune -o -type f -print | grep -v '/tmux/' | sort | xargs sha256sum > "$WORK/before.sum"
E bin/fm-officer.sh run triage --date "$DATE"; echo "run rc=$?"
sha256sum "$LAB/data/officers/triage/$DATE".{json,md} > "$WORK/b.sum"
cat "$WORK/a.sum"; cmp "$WORK/a.sum" "$WORK/b.sum" && echo "IDENTICAL"

hdr "S6 a run writes only its lane: no file outside data/officers/ added or changed"
find "$LAB" -path "$LAB/data/officers" -prune -o -type f -print | grep -v '/tmux/' | sort | xargs sha256sum > "$WORK/after.sum"
diff <(awk '{print $2}' "$WORK/before.sum") <(awk '{print $2}' "$WORK/after.sum") | sed 's#'"$LAB"'#$LAB#'
echo "--- pre-existing files whose content changed:"
join -1 2 -2 2 <(sort -k2 "$WORK/before.sum") <(sort -k2 "$WORK/after.sum") | awk '$2 != $3 {print $1}' | sed 's#'"$LAB"'#$LAB#'
cat "$LAB/state/t1.status"

hdr "S7 unreachable archive host: silent until attempts run out, one failure line, then silent"
printf -- '- remote - Reads a remote archive (role: triage; cadence: daily 00:00; archive: nohost.invalid:/srv/x; model: none; added %s)\n' "$(date +%F)" >> "$LAB/data/officers.md"
E bin/fm-officer.sh register remote
for i in 1 2 3 4 5 6 7 8; do
  out=$(E FM_OFFICER_ATTEMPTS=2 FM_OFFICER_RETRY_SECS=0 bash "$LAB/state/officer-remote.check.sh"); echo "check $i rc=$? out=[${out}]"
  sleep 1; for _ in $(seq 1 40); do [ -d "$LAB/data/officers/remote/.run.lock" ] || break; sleep 0.25; done
done
echo "--- runs.log:"; cat "$LAB/data/officers/remote/runs.log"

hdr "S8 scheduled run that hangs is bounded and logged as timed out"
mkdir -p "$WORK/fakebin"; printf '#!/bin/sh\nexec sleep 60\n' > "$WORK/fakebin/ssh"; chmod +x "$WORK/fakebin/ssh"
printf -- '- hang - Reads a hanging archive (role: triage; cadence: daily 00:00; archive: hanghost:/srv/x; model: none; added %s)\n' "$(date +%F)" >> "$LAB/data/officers.md"
E bin/fm-officer.sh register hang
E PATH="$WORK/fakebin:$PATH" FM_OFFICER_RUN_TIMEOUT=3 bash "$LAB/state/officer-hang.check.sh"; echo "check rc=$?"
for _ in $(seq 1 60); do grep -q failed "$LAB/data/officers/hang/runs.log" 2>/dev/null && break; sleep 0.25; done
echo "--- runs.log:"; cat "$LAB/data/officers/hang/runs.log"
echo "--- immediate re-check does not start another run (retry window):"
E PATH="$WORK/fakebin:$PATH" FM_OFFICER_RUN_TIMEOUT=3 bash "$LAB/state/officer-hang.check.sh"; sleep 1
[ -d "$LAB/data/officers/hang/.run.lock" ] && echo "RUN STARTED (bad)" || echo "no new run"

hdr "S9 ensure / real bootstrap print OFFICER: lines for gaps"
cat >> "$LAB/data/officers.md" <<EOF
- scorer - Scores sessions with a model (role: triage; cadence: daily 06:00; archive: $ARCH; model: sonnet; added $(date +%F))
- unreg - Not yet registered (role: triage; cadence: daily 06:00; archive: $ARCH; model: none; added $(date +%F))
- broken line without fields
- weekly - Wrong cadence (role: triage; cadence: weekly; archive: $ARCH; model: none; added $(date +%F))
EOF
echo "--- fm-officer.sh ensure:"; E bin/fm-officer.sh ensure
echo "--- stale: pin clock 3 days ahead:"; E FM_OFFICER_NOW=$(( $(date +%s) + 3*86400 )) bin/fm-officer.sh ensure | grep -E 'triage|remote|hang'
echo "--- bin/fm-bootstrap.sh OFFICER lines:"
E timeout 120 bin/fm-bootstrap.sh > "$WORK/boot.out" 2>&1; echo "bootstrap rc=$?"
grep '^OFFICER:' "$WORK/boot.out"

hdr "S10 second mate home refuses officers"
SM=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$SM"; bin/fm-lab-home.sh create "$SM" >/dev/null
touch "$SM/.fm-secondmate-home"; cp "$LAB/data/officers.md" "$SM/data/officers.md"
env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$SM" bin/fm-officer.sh register triage; echo "register rc=$?"
env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$SM" bin/fm-officer.sh run triage --date "$DATE"; echo "run rc=$?"
env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$SM" bin/fm-officer.sh ensure
ls "$SM/state" | grep officer || echo "no officer check in second mate state"
rm -rf "$SM"

hdr "S11 retire keeps findings"
E bin/fm-officer.sh retire triage
ls "$LAB/state" | grep 'officer-triage' || echo "check gone"
ls "$LAB/data/officers/triage/" | grep -E "$DATE"
grep -c '^- triage ' "$LAB/data/officers.md"
