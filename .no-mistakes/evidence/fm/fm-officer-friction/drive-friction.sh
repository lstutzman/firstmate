#!/usr/bin/env bash
# Live drive of bin/fm-officer.sh run friction in a disposable lab home.
set -u
ROOT=$1; EV=$2
. "$ROOT/tests/officer-helpers.sh" 2>/dev/null || true
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
LAB=$(cd "$LAB" && pwd -P)
ARCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-arch.XXXXXX")
export TZ=UTC
DATE=2026-10-24; T=1792836000; NOW=1792915200   # 2026-10-24T10:00Z, 2026-10-25T08:00Z
HOST=$(hostname)
S=$LAB/state
# Two remote second mates, so their channel logs are the only copies of their asks.
cat > $LAB/data/secondmates.md <<EOF
- m1 - mate one (host: m1host; root: /r1; home: /h1; scope: x; projects: none; added 2026-10-24)
- m2 - mate two (host: m2host; root: /r2; home: /h2; scope: x; projects: none; added 2026-10-24)
EOF
# Seed: ssh-to-self (Lee asked twice to ssh to this very host)
cat > $S/task-swap.status <<EOF
needs-decision [key=swap-c2] [at=$T]: Lee, please run: ssh -t $HOST 'bash /x/swap.sh c2'
needs-decision [key=swap-c2] [at=$((T+1800))]: did not take. Lee, run again: ssh -t $HOST 'bash /x/swap.sh c2'
resolved [key=swap-c2] [at=$((T+7200))]: Lee ran it locally
EOF
# Seed: Node line blocked by shell-file hook
cat > $S/task-node.status <<EOF
needs-decision [key=node-line] [at=$T]: Making Node the default needs one line from Lee (hooks block me editing his shell startup file)
resolved [key=node-line] [at=$((T+600))]: Lee ran the line
EOF
# Seed: fleet-app deploy sudo
cat > $S/task-fleet.status <<EOF
blocked [key=fleet-sudo] [at=$T]: the fleet-app deploy needs sudo on slartibartfast: Lee runs sudo systemctl restart fleet
resolved [key=fleet-sudo] [at=$((T+2400))]: Lee restarted it
EOF
# Seed: new credential naming rule
cat > $S/task-mail.status <<EOF
needs-decision [key=mailbox-token] [at=$T]: creating staging secret E2E_MAILBOX_TOKEN is a credential change: the rules need Lee's own words naming it
resolved [key=mailbox-token] [at=$((T+5400))]: Lee approved
EOF
# Seed: wrong-directory restore
cat > $S/task-restore.status <<EOF
paused [at=$T]: Lee: after the reboot this worker session was restored in the wrong directory
EOF
# Channel cases: m1 and m2 each relay an unrelated ask with the same key; no task copy -> 2 asks
cat > $S/m1.status <<EOF
needs-decision [key=merge-word] [at=$T]: relayed: Lee needs to give the merge word for PR 5
resolved [key=merge-word] [at=$((T+1200))]: Lee said merge
EOF
cat > $S/m2.status <<EOF
needs-decision [key=merge-word] [at=$((T+60))]: relayed: Lee needs to give the merge word for PR 9
resolved [key=merge-word] [at=$((T+1260))]: Lee said merge
EOF
# Channel copy of a task's ask (same key as task-node) -> folds into task-node, counted once
cat > $S/parent-replies.status <<EOF
needs-decision [key=node-line] [at=$((T+20))]: relayed: Node default needs one line from Lee
EOF
# Archive: one session where Lee types ssh to its own host and gets publickey refusal; one to another host
cat > $ARCH.spec.json <<EOF
{"sessions":[{"machine":"$HOST","id":"s-dt","first_prompt":"hi","cwd":"$LAB","raw":[
 {"type":"user","timestamp":"2026-10-24T10:05:00.000Z","message":{"content":"<bash-input>ssh -t $HOST 'bash /x/swap.sh c2'</bash-input>"}},
 {"type":"user","timestamp":"2026-10-24T10:05:01.000Z","message":{"content":"<bash-stdout></bash-stdout><bash-stderr>lee@$HOST: Permission denied (publickey).</bash-stderr>"}},
 {"type":"user","timestamp":"2026-10-24T10:06:00.000Z","message":{"content":"<bash-input>ssh -t otherbox 'bash /x/lic.sh'</bash-input>"}},
 {"type":"user","timestamp":"2026-10-24T10:06:01.000Z","message":{"content":"<bash-stdout></bash-stdout><bash-stderr>lee@otherbox: Permission denied (publickey).</bash-stderr>"}}]},
 {"machine":"$HOST","id":"s-w","first_prompt":"go","cwd":"/tmp/x","calls":[
  ["Bash",{"command":"python3 x"},"/bin/bash: python3: command not found",true],
  ["Bash",{"command":"python3 y"},"/bin/bash: python3: command not found",true],
  ["Bash",{"command":"python3 z"},"/bin/bash: python3: command not found",true]]}]}
EOF
officer_archive "$ARCH" "$DATE" "$ARCH.spec.json"
printf -- '- friction - Finds what slowed agents down (role: friction; cadence: daily 06:15; archive: %s; hosts: %s; model: none; added 2026-10-24)\n' "$ARCH" "$HOST" > $LAB/data/officers.md
cd "$ROOT"
echo "== fm-officer.sh list"; FM_HOME=$LAB bin/fm-officer.sh list
echo "== fm-officer.sh run friction --date $DATE"
FM_HOME=$LAB FM_OFFICER_NOW=$NOW bin/fm-officer.sh run friction --date $DATE; echo "rc=$?"
L=$LAB/data/officers/friction
ls $L
cp $L/$DATE.md $EV/digest-$DATE.md; cp $L/$DATE.velocity-findings.json $EV/velocity-findings-$DATE.json; cp $L/$DATE.json $EV/events-$DATE.json
sha1=$(sha256sum $L/$DATE.md $L/$DATE.json)
FM_HOME=$LAB FM_OFFICER_NOW=$NOW bin/fm-officer.sh run friction --date $DATE >/dev/null; sha2=$(sha256sum $L/$DATE.md $L/$DATE.json)
[ "$sha1" = "$sha2" ] && echo "RERUN byte-identical: yes" || echo "RERUN byte-identical: NO"
echo "== missing day"; FM_HOME=$LAB FM_OFFICER_NOW=$NOW bin/fm-officer.sh run friction --date 2026-10-20; echo "rc=$?"
echo "== bad captains-log"; sed -i 's/model: none;/model: none; captains-log: http:\/\/x;/' $LAB/data/officers.md; FM_HOME=$LAB bin/fm-officer.sh run friction --date $DATE; echo "rc=$?"
echo "LAB=$LAB ARCH=$ARCH"
rm -rf "$LAB" "$ARCH" "$ARCH.spec.json"
