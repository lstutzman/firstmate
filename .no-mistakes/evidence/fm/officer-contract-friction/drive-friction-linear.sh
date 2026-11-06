#!/usr/bin/env bash
# Behavior tests for the friction officer's deterministic pass, driven through
# bin/fm-officer.sh run against a fixture archive and fixture home records.
#
# Covers: Lee-step and wait detection in status logs (bracketed and bare
# markers, keyed answers, unkeyed next-line waits, re-asks measured once, the
# ledger for cleaned-up tasks, deduplication, the day window), root-cause
# grouping with a proposed fix and owner, ssh to the home's own host, product
# decisions kept off the cards, transcript Lee steps (typed commands, asks
# measured to Lee's next message, ssh to the session's own host), line-anchored
# agent-side refusals, a worker resumed outside its worktree, the fleet-app
# velocity findings file and its limits, per-finding ids, event counts and
# read-only states (open, started, settled), byte-identical digests on re-run, the
# boundary (no network, no writes outside the lane), a remote archive,
# Captain's Log cards no status line accounts for (and an unreachable log),
# the bosun-unsure class (answers from live pull request and origin/HEAD facts
# into bosun-answers.json only, session logs kept, unreadable and unbucketed
# items skipped, unsettled items in the digest, an unreachable host as a
# coverage gap),
# and the registry refusing a friction line with no archive.
# With writes: linear (a fake linear-axi that logs every call): every finding filed once with
# Improvement, agent and area:fleet in the Fleet project, a repeat night raising the
# Found line, no transcript text in an item, a missing label or writes: none starting nothing
# and leaving the card on Start fix, the create cap naming what it leaves, the rubric
# narrowing what starts, and only standing-work findings handed to the office.
set -u

# shellcheck source=tests/officer-helpers.sh
. {run-worktree}/tests/officer-helpers.sh

OFFICER="$ROOT/bin/fm-officer.sh"
TMP_ROOT=$(fm_test_tmproot fm-officer-friction)
DATE=2026-10-23
T=1792749600      # 2026-10-23T10:00:00Z
PREV=1792663200   # 2026-10-22T10:00:00Z
NOW=1792818000    # 2026-10-24T05:00:00Z
export TZ=UTC

# fake_linear <bindir>: linear-axi driven by $FAKE_LINEAR_DIR (labels.txt, exists.txt, state.<id>); it logs every
# call to $FAKE_LINEAR_DIR/log and refuses to run without that variable, so no test can reach the real Linear.
fake_linear() {
  cat > "$1/linear-axi" <<'SH'
#!/usr/bin/env bash
d=${FAKE_LINEAR_DIR:-}
[ -n "$d" ] || { echo '{"ok":false,"error":{"code":"UNKNOWN","message":"no fake linear dir"}}'; exit 1; }
printf '%s\n' "$*" >> "$d/log"
case "$1 $2" in
  "label list")
    printf '{"ok":true,"data":{"labels":['
    sep=''; while IFS= read -r l; do printf '%s{"name":"%s"}' "$sep" "$l"; sep=','; done < "$d/labels.txt"
    echo ']}}' ;;
  "issue search")
    q=${3#friction-fp:}
    if [ -n "$q" ] && grep -qF -- "$q" "$d/exists.txt" 2>/dev/null; then
      echo '{"ok":true,"data":{"issues":[{"identifier":"PC-55"}]}}'
    else echo '{"ok":true,"data":{"issues":[]}}'; fi ;;
  "issue view")
    st=$(cat "$d/state.$3" 2>/dev/null || echo Todo)
    case "$st" in Done) ty=completed ;; *) ty=unstarted ;; esac
    desc="Found: 1 times (first 2026-10-20, last 2026-10-20, by friction)"
    [ "$3" = PC-55 ] && desc="$desc\\nfriction-fp:$(tr -d '\n' < "$d/exists.txt")"
    echo '{"ok":true,"data":{"issue":{"identifier":"'"$3"'","state":"'"$st"'","stateType":"'"$ty"'","description":"'"$desc"'"}}}' ;;
  "issue create")
    case " $* " in
      *" --verify "*)
        n=$(( $(cat "$d/created" 2>/dev/null || echo 100) + 1 )); echo "$n" > "$d/created"
        for a in "$@"; do [ "${prev:-}" = "--body-file" ] && cat "$a" >> "$d/bodies" && echo >> "$d/bodies"; prev=$a; done
        echo '{"ok":true,"data":{"issue":{"identifier":"PC-'"$n"'"}}}' ;;
      *) echo '{"ok":true,"data":{"dryRun":true}}' ;;
    esac ;;
  "issue update")
    case " $* " in *" --verify "*) echo "UPDATE $3" >> "$d/updates" ;; esac
    echo '{"ok":true,"data":{"issue":{"identifier":"'"$3"'"}}}' ;;
  "issue comment")
    case " $* " in *" --verify "*) echo "COMMENT $3" >> "$d/comments" ;; esac
    echo '{"ok":true,"data":{"dryRun":true}}' ;;
  "issue relation") echo '{"ok":true,"data":{"dryRun":true}}' ;;
  *) echo '{"ok":false,"error":{"code":"UNKNOWN","message":"unexpected call"}}'; exit 1 ;;
esac
SH
  chmod +x "$1/linear-axi"
}
LINEAR_BIN="$TMP_ROOT/linear-bin"
mkdir -p "$LINEAR_BIN"
fake_linear "$LINEAR_BIN"
export PATH="$LINEAR_BIN:$PATH"

write_status() {  # <home>
  local s=$1/state
  cat > "$s/task-cf.status" <<EOF
working [at=$((T - 60))]: started
needs-decision [at=$T] [key=cf-scope]: Cloudflare refuses the agent token for Email Routing and KV (code 10000); one widening Lee needs
resolved [key=cf-scope] [at=$((T + 3600))]: answered: Lee in main chat: "cf done"
needs-decision [at=$PREV] [key=old-day]: Cloudflare refuses the agent token again; Lee needs to widen it
EOF
  cat > "$s/parent-replies.status" <<EOF
needs-decision [at=$((T + 30))] [key=cf-scope]: relayed: Cloudflare refuses the agent token for Email Routing; Lee needs to widen it
EOF
  cat > "$s/task-node.status" <<EOF
needs-decision key=node-line at=$T: corr=21b6eac25a90a9f8 Making Node the default needs one line from Lee (hooks block me editing his shell startup file)
resolved key=node-line at=$((T + 600)): Lee ran the line
EOF
  cat > "$s/task-swap.status" <<EOF
needs-decision [key=swap-c2] [at=$T]: arm 2 done. Lee, please run: ssh -t fixturehost 'bash /x/swap.sh c2' -- it should end with OK. Options: (a) run it now; (b) skip
needs-decision [key=swap-c2] [at=$((T + 1800))]: the c2 swap did not take effect. Lee, please run it again: ssh -t fixturehost 'bash /x/swap.sh c2'
resolved [key=swap-c2] [at=$((T + 7200))]: Lee ran the c2 swap locally; it ended OK
EOF
  cat > "$s/task-mail.status" <<EOF
needs-decision [at=$T] [key=mailbox-token]: creating staging secret E2E_MAILBOX_TOKEN is a credential change: the rules need Lee's own words naming it
resolved [key=mailbox-token] [at=$((T + 5400))]: Lee approved creating E2E_MAILBOX_TOKEN
EOF
  cat > "$s/task-lic.status" <<EOF
blocked [at=$T]: the licence install needs sudo on the gate host; Lee runs the script
working [at=$((T + 900))]: resumed after the install
EOF
  cat > "$s/task-pick.status" <<EOF
needs-decision [at=$T] [key=wording]: Lee, pick (a) the short wording or (b) the long one
resolved [key=wording] [at=$((T + 120))]: Lee chose (a)
EOF
  printf '%s\n' \
    "{\"v\":1,\"ts\":$T,\"event\":\"task.status\",\"task\":\"gone\",\"state\":\"blocked\",\"key\":\"fleet-sudo\",\"text\":\" the fleet-app deploy needs sudo on slartibartfast: Lee runs sudo systemctl restart fleet\"}" \
    "{\"v\":1,\"ts\":$((T + 2400)),\"event\":\"task.status\",\"task\":\"gone\",\"state\":\"resolved\",\"key\":\"fleet-sudo\",\"text\":\" Lee restarted it\"}" \
    "{\"v\":1,\"ts\":$((T + 5)),\"event\":\"task.status\",\"task\":\"task-lic\",\"state\":\"blocked\",\"key\":null,\"text\":\" the licence install needs sudo on the gate host; Lee runs the script\"}" \
    > "$s/fleet-ledger.jsonl"
}

write_spec() {  # <file> <home>
  python3 -I - "$1" "$2" "$(officer_worker_brief "$2" task-wt)" "$T" <<'PY'
import json, sys
path, home, brief, t = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
iso = lambda e: __import__("datetime").datetime.fromtimestamp(e, __import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def user(text, at): return {"type": "user", "timestamp": iso(at), "message": {"content": text}}
def say(text, at): return {"type": "assistant", "timestamp": iso(at), "message": {"content": [{"type": "text", "text": text}]}}
msg = {"file_path": home + "/state/operational-inbox/1.msg"}
spec = {"sessions": [
  {"machine": "alpha", "id": "s-mate", "first_prompt": "ahoy", "cwd": home, "raw": [
    say("Run this in your own terminal: `ssh -t beta 'bash ~/x/lic.sh'` and tell me when it ends.", t),
    user(": Firstmate operational input waiting: read 'x'", t + 60),
    say("Still waiting for Lee to run `ssh -t beta 'bash ~/x/lic.sh'`.", t + 120),
    user("done", t + 300),
    user("<bash-input>ssh -t alpha 'bash /x/swap.sh c2'</bash-input>", t + 400),
    user("<bash-stdout></bash-stdout><bash-stderr>lee@alpha: Permission denied (publickey).</bash-stderr>", t + 401),
    user("<bash-input>ssh -t beta 'bash /x/lic.sh'</bash-input>", t + 450),
    user("<bash-stdout></bash-stdout><bash-stderr>lee@beta: Permission denied (publickey).</bash-stderr>", t + 451),
    user("<bash-input>/opt/homebrew/bin/op run --env-file=~/prod.env -- python3 s.py --token ghp_AbCdEf0123456789abcdefGHIJ</bash-input>", t + 500),
    user("<bash-input>brew install openjdk@21</bash-input>", t + 600)]},
  {"machine": "alpha", "id": "s-worker", "first_prompt": ": Firstmate operational input waiting: read 'w'",
   "calls": [["Read", msg, brief, False],
             ["Bash", {"command": "env"}, "PreToolUse:Bash hook error: [~/.claude/hooks/pre-bash-secret-exposure.py]: BLOCKED (secret exposure): bare env dumps every secret", True],
             ["Bash", {"command": "sudo true"}, "sudo: a terminal is required to read the password", True],
             ["Bash", {"command": "make"}, "OK lint\n/bin/bash: line 4: slopwatch: command not found\nOK done", True],
             ["Read", {"file_path": "/rules.md"}, "Rules: never print secrets. bash: x: command not found is bad. sudo: a terminal is required", False],
             ["Bash", {"command": "op-agent read x"}, "[ERROR] 2026/10/23 01:47:08 Too many requests. Your client has been rate-limited.", True]],
   "cwd": "~/clone"},
]}
json.dump(spec, open(path, "w"))
PY
}

make_world() {  # <name>
  local name=$1 home archive
  home="$TMP_ROOT/$name/fixturehost"
  archive="$TMP_ROOT/$name/archive"
  officer_home "$home"
  home=$(cd "$home" && pwd -P)
  write_status "$home"
  printf 'kind=ship\nworktree=/work/task-wt\n' > "$home/state/task-wt.meta"
  write_spec "$TMP_ROOT/$name/spec.json" "$home"
  officer_archive "$archive" "$DATE" "$TMP_ROOT/$name/spec.json"
  friction_registry "$home" "$archive"
  printf '%s\n' "$home"
}

friction_registry() {  # <home> <archive> [extra registry fields, each led by "; "]
  printf -- '- friction - Finds what slowed agents down, above all waits on Lee (role: friction; cadence: daily 06:15; archive: %s; hosts: alpha%s; model: none; added 2026-10-24)\n' \
    "$2" "${3:-}" > "$1/data/officers.md"
}

# linear_world <name> [extra registry fields]: a world whose friction line writes Linear items through the fake.
# Call it directly, not in $(...): it sets LW_HOME (the home) and FAKE_LINEAR_DIR (the fake's folder) for the test.
linear_world() {
  local name=$1 home
  home=$(make_world "$name")
  LW_HOME=$home
  friction_registry "$home" "$TMP_ROOT/$name/archive" "; writes: linear; jev: /nonexistent/jev.py${2:-}"
  export FAKE_LINEAR_DIR="$TMP_ROOT/$name/linear"
  mkdir -p "$FAKE_LINEAR_DIR"
  printf '%s\n' Bug Improvement agent area:fleet > "$FAKE_LINEAR_DIR/labels.txt"
}

run_officer() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" FM_OFFICER_NOW="$NOW" "$OFFICER" run friction --date "$DATE" "$@"
}

finding() {  # <json> <cause> <sub> <jq-path>
  jq -r --arg c "$2" --arg s "$3" "[.findings[] | select(.cause == \$c and .sub == \$s)][0] | $4" "$1"
}

status_event() {  # <json> <task> <key|null> <jq-path>
  jq -r --arg t "$2" --arg k "$3" \
    "[.events[] | select(.kind == \"status-wait\" and .task == \$t and ((.key // \"null\") == \$k))][0] | $4" "$1"
}

EV=~/.no-mistakes/evidence/01M6QBFR5FYY27R1W692E7SX8K
echo "== Scenario A: writes: linear night 1 =="
linear_world ev
home=$LW_HOME; dir=$FAKE_LINEAR_DIR; json="$home/data/officers/friction/$DATE.json"
run_officer "$home" > "$EV/A-run-stdout.txt" 2>&1; echo "run exit=$?"
cp "${json%.json}.md" "$EV/A-digest.md"; cp "$json" "$EV/A-digest.json"; cp "$dir/log" "$EV/A-linear-calls.log"; cp "$dir/bodies" "$EV/A-linear-bodies.txt"
echo "creates verified: $(grep -c '^issue create .*--verify' $dir/log)"
echo "real findings: $(jq '[.findings[]|select(.linear.class=="real")]|length' $json)"
echo "start requests: $(jq -r '[.start_requests[]|"\(.id)->\(.linear_id // .issue)"]|join(", ")' $json)"
echo "leaks of status text in bodies: $(grep -c -e '/x/swap.sh' -e 'arm 2 done' -e 'cf done' $dir/bodies)"
echo "== Scenario B: same-day rerun =="
run_officer "$home" >/dev/null 2>&1; echo "rerun exit=$? creates now: $(grep -c '^issue create .*--verify' $dir/log)"
echo "== Scenario C: later night raises Found =="
jq '.issues |= map_values(.last = "2026-10-20")' "$home/data/officers/friction/found.json" > $TMP_ROOT/f.json && cp $TMP_ROOT/f.json "$home/data/officers/friction/found.json"
run_officer "$home" >/dev/null 2>&1; echo "exit=$? updates: $(wc -l < $dir/updates) comments: $(wc -l < $dir/comments) creates: $(grep -c '^issue create .*--verify' $dir/log)"
jq -r '[.findings[]|select(.linear.issue!=null)][0].linear|"first filed: issue=\(.issue) found=\(.found) score=\(.score)"' $json
echo "== Scenario D: writes: none =="
h2=$(make_world evnone); export FAKE_LINEAR_DIR="$TMP_ROOT/evnone/linear"; mkdir -p $FAKE_LINEAR_DIR
run_officer "$h2" >/dev/null 2>&1; echo "exit=$? linear called: $([ -e $FAKE_LINEAR_DIR/log ] && echo yes || echo no) starts: $(jq '.start_requests|length' $h2/data/officers/friction/$DATE.json)"
jq -r '.coverage.notes[]' $h2/data/officers/friction/$DATE.json | grep -i linear
cp $h2/data/officers/friction/$DATE.md "$EV/D-digest-writes-none.md"
echo "== F4: each linear gap printed once in digest =="
for f in "$EV/A-digest.md" "$EV/D-digest-writes-none.md"; do echo "$f dup lines:"; grep -v '^\s*$' "$f" | sort | uniq -d | grep -iv '^|\|^-\{3\}' | head; done
