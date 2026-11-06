#!/usr/bin/env bash
# drive.sh <code-root> <workdir>: run the real friction officer (bin/fm-officer.sh run friction) from <code-root>
# against a synthetic one-day archive holding the card events, and print its findings.
set -u
ROOT=$1; W=$2; DATE=2026-10-23; export TZ=UTC
mkdir -p "$W"
. "$ROOT/tests/officer-helpers.sh"
home="$W/fixturehost"; archive="$W/archive"
officer_home "$home"; home=$(cd "$home" && pwd -P)
cat > "$W/day.json" <<'J'
{"sessions": [{"machine": "alpha", "id": "cards", "first_prompt": "hello", "calls": [
 ["Bash", {"command": "bash tests/fm-pending-reply.test.sh"}, "/bin/bash: line 3: fm_pending_reply_detect_wrong_home: command not found", true],
 ["Bash", {"command": "bash tests/fm-pending-reply.test.sh"}, "/bin/bash: line 4: fm_pending_reply_path: command not found", true],
 ["Bash", {"command": "bash tests/fm-retention.test.sh"}, "/bin/bash: line 9: now_epoch: command not found", true],
 ["Bash", {"command": "bash -c 'record_claude_idle'"}, "bash: record_claude_idle: command not found", true],
 ["Bash", {"command": "bash -c 'run_progress'"}, "bash: run_progress: command not found", true],
 ["Bash", {"command": "bash -c 'run_office_local_merge'"}, "bash: run_office_local_merge: command not found", true],
 ["Bash", {"command": "bash bin/fm-crew-state.sh"}, "/bin/bash: line 9: fail: command not found", true],
 ["Bash", {"command": "make"}, "/bin/bash: line 4: jq: command not found", true],
 ["Bash", {"command": "make"}, "/bin/bash: line 4: gitleaks: command not found", true],
 ["Bash", {"command": "bash tests/fm-officer-friction.test.sh"}, "lee@alpha: Permission denied (publickey).", true],
 ["Bash", {"command": "bash tests/fm-officer-friction.test.sh"}, "lee@beta: Permission denied (publickey).", true],
 ["Bash", {"command": "bash tests/fm-git-retry-lib.test.sh"}, "git@github.com: Permission denied (publickey).", true],
 ["Bash", {"command": "bash tests/fm-git-*.test.sh"}, "git@github.com: Permission denied (publickey).", true],
 ["Bash", {"command": "bin/fm-test-run.sh --changed"}, "lee@alpha: Permission denied (publickey).", true],
 ["Bash", {"command": "ssh deepthought true"}, "lee@deepthought: Permission denied (publickey).", true],
 ["Bash", {"command": "git push origin fm/x"}, "git@github.com: Permission denied (publickey).", true],
 ["Bash", {"command": "echo tests/fm-x.test.shy; ssh dt true"}, "lee@dt: Permission denied (publickey).", true]]}]}
J
officer_archive "$archive" "$DATE" "$W/day.json"
printf -- '- friction - Finds what slowed agents down (role: friction; cadence: daily 06:15; archive: %s; hosts: alpha; model: none; added 2026-10-24)\n' "$archive" > "$home/data/officers.md"
FM_HOME="$home" FM_OFFICER_NOW=1792818000 "$ROOT/bin/fm-officer.sh" run friction --date "$DATE" > "$W/run.out" 2>&1; echo "officer exit: $?"
json="$home/data/officers/friction/$DATE.json"
echo "missing-tool findings: $(jq -r '[.findings[] | select(.cause=="missing-tool") | .name] | sort | join(",")' "$json")"
echo "ssh-key agent-hit events: $(jq '[.events[] | select(.kind=="agent-hit" and .sub=="ssh-key")] | length' "$json")"
echo "ssh-key event hosts/details:"; jq -c '[.events[] | select(.kind=="agent-hit" and .sub=="ssh-key") | (.detail // .text // .host // .)]' "$json" | cut -c1-600
echo "ssh-key finding: $(jq -c '[.findings[] | select(.sub=="ssh-key") | {cause,sub,title:(.title//.name), events:(.events//.count)}]' "$json")"
