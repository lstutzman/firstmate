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
# velocity findings file and its limits, byte-identical digests on re-run, the
# boundary (no network, no writes outside the lane), a remote archive,
# Captain's Log cards no status line accounts for (and an unreachable log),
# and the registry refusing a friction line with no archive.
set -u

# shellcheck source=tests/officer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/officer-helpers.sh"

OFFICER="$ROOT/bin/fm-officer.sh"
TMP_ROOT=$(fm_test_tmproot fm-officer-friction)
DATE=2026-10-23
T=1792749600      # 2026-10-23T10:00:00Z
PREV=1792663200   # 2026-10-22T10:00:00Z
NOW=1792818000    # 2026-10-24T05:00:00Z
export TZ=UTC

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
    user("<bash-input>/opt/homebrew/bin/op run --env-file=/Users/x/prod.env -- python3 s.py --token ghp_AbCdEf0123456789abcdefGHIJ</bash-input>", t + 500),
    user("<bash-input>brew install openjdk@21</bash-input>", t + 600)]},
  {"machine": "alpha", "id": "s-worker", "first_prompt": ": Firstmate operational input waiting: read 'w'",
   "calls": [["Read", msg, brief, False],
             ["Bash", {"command": "env"}, "PreToolUse:Bash hook error: [~/.claude/hooks/pre-bash-secret-exposure.py]: BLOCKED (secret exposure): bare env dumps every secret", True],
             ["Bash", {"command": "sudo true"}, "sudo: a terminal is required to read the password", True],
             ["Bash", {"command": "make"}, "OK lint\n/bin/bash: line 4: slopwatch: command not found\nOK done", True],
             ["Read", {"file_path": "/rules.md"}, "Rules: never print secrets. bash: x: command not found is bad. sudo: a terminal is required", False],
             ["Bash", {"command": "op-agent read x"}, "[ERROR] 2026/10/23 01:47:08 Too many requests. Your client has been rate-limited.", True]],
   "cwd": "/home/primary/clone"},
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

friction_registry() {  # <home> <archive>
  printf -- '- friction - Finds what slowed agents down, above all waits on Lee (role: friction; cadence: daily 06:15; archive: %s; hosts: alpha; model: none; added 2026-10-24)\n' \
    "$2" > "$1/data/officers.md"
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

test_merge_word_is_not_a_missing_tool() {
  local home json
  local DATE=2026-10-26 T=1793033657 NOW=1793077200
  home=$(make_world merge-word)
  cat > "$home/state/slarti.status" <<'EOF'
needs-decision [key=fleet-app-pr67-merge] [at=1793033657]: For a Lee merge-word card (fleet-app needs his word on every PR). New progress-officer page: https://github.com/lstutzman/fleet-app/pull/67. It is a read-only page, separate from Captain's Choice and the Captain's Log, showing what the progress officer is doing, has done, and is asking for, plus its one-line summary and the file's age (stale or failed states are shown plainly). Captain's Log decisions appear only as links to the Log. It includes a pull job that reads the officer's JSON file (format agreed with Deep Thought) and the fleet-app route behind it. No-mistakes review passed and the fleet-app suite passes; there is no CI on
resolved [key=fleet-app-pr67-merge] [at=1793035197]: Lee approved the merge
EOF
  run_officer "$home" >/dev/null || fail "merge-word fixture run must succeed"
  json="$home/data/officers/friction/$DATE.json"
  assert_equals "1540" "$(status_event "$json" slarti fleet-app-pr67-merge '.wait_s')" \
    "the original merge-word wait is read and measured, not silently dropped"
  assert_equals 0 "$(jq '[.events[] | select(.task == "slarti" and .cause == "missing-tool")] | length' "$json")" \
    "the original merge approval is not classified as a missing tool"
  assert_equals 0 "$(jq '[.findings[] | select(.carded and (.evidence.tasks | index("slarti")))] | length' "$json")" \
    "the original merge approval produces no friction card"

  cat > "$home/state/missing-tool.status" <<EOF
blocked [at=$T] [key=missing-tool]: openjdk is not installed; Lee needs to install the missing tool
resolved [at=$((T + 1540))] [key=missing-tool]: Lee installed openjdk
EOF
  run_officer "$home" >/dev/null || fail "missing-tool fixture run must succeed"
  assert_equals "missing-tool" "$(status_event "$json" missing-tool missing-tool '.cause')" \
    "a genuine missing tool retains its cause"
  assert_equals "true" "$(finding "$json" missing-tool tool '.carded')" \
    "a genuine missing-tool wait still produces a card"
  pass "fm-officer friction: merge approval is not a missing tool; genuine missing tools still card"
}

test_status_waits_and_root_causes() {
  local home out json mate
  home=$(make_world status)
  mate="$TMP_ROOT/status/matehome"
  officer_home "$mate"
  mate=$(cd "$mate" && pwd -P)
  printf -- '- dt - fixture mate (home: %s; scope: fixture work; projects: alpha; added 2026-10-24)\n' "$mate" \
    > "$home/data/secondmates.md"
  cat > "$mate/state/task-dt.status" <<EOF
needs-decision [at=$T] [key=dt-gate]: the gate-integrity guard needs ALLOW_GATE_EDIT from Lee
resolved [key=dt-gate] [at=$((T + 600))]: Lee set it
EOF
  cat > "$home/state/dt.status" <<EOF
needs-decision [at=$((T + 20))] [key=dt-gate]: relayed: the gate-integrity guard needs ALLOW_GATE_EDIT from Lee
EOF
  cat > "$home/state/task-pra.status" <<EOF
needs-decision [at=$T] [key=merge]: PR 1 needs Lee's merge word
EOF
  cat > "$home/state/task-prb.status" <<EOF
needs-decision [at=$((T + 60))] [key=merge]: PR 2 needs Lee's merge word
EOF
  printf -- '- m1 - remote mate (host: h1; root: /r; home: /r/m1; scope: fixture work; projects: alpha; added 2026-10-24)\n- m2 - remote mate (host: h2; root: /r; home: /r/m2; scope: fixture work; projects: alpha; added 2026-10-24)\n' \
    >> "$home/data/secondmates.md"
  printf 'needs-decision [at=%s] [key=relayed-approval]: relayed: the destructive cleanup needs Lee'"'"'s word\n' "$T" \
    > "$home/state/m1.status"
  printf 'needs-decision [at=%s] [key=relayed-approval]: relayed: the destructive reset needs Lee'"'"'s word\n' "$((T + 90))" \
    > "$home/state/m2.status"
  out=$(run_officer "$home") || fail "friction run must succeed: $out"
  assert_contains "$out" "DIGEST $DATE " "run prints the digest marker"
  json="$home/data/officers/friction/$DATE.json"
  assert_equals "credential scope Cloudflare 3600 resolved-key lee" \
    "$(status_event "$json" task-cf cf-scope '"\(.cause) \(.sub) \(.service) \(.wait_s) \(.measured_by) \(.answered_by)"')" \
    "a keyed Cloudflare token refusal is a scope wait measured to its resolved line, answered by Lee"
  assert_equals "1 3600 task-cf" "$(finding "$json" credential scope '"\(.events) \(.wait_total_s) \(.evidence.tasks | join(","))"')" \
    "a relayed copy of a keyed ask in the parent channel is the same ask, and the channel is not a task"
  assert_equals "An agent token lacks a scope, so Lee widens it|Cloudflare" \
    "$(finding "$json" credential scope '"\(.title)|\(.name)"')" \
    "the finding title is a stable template, and the group keeps the service's name"
  assert_equals "1 600 task-dt" \
    "$(finding "$json" guard-hook gate-edit '"\(.events) \(.wait_total_s) \(.evidence.tasks | join(","))"')" \
    "a mate's relay into its parent channel log folds into the worker's copy in the mate's home"
  assert_equals "2 task-pra,task-prb" "$(finding "$json" policy merge-word '"\(.events) \(.evidence.tasks | join(","))"')" \
    "two task logs that reuse a key are two asks"
  assert_equals 2 "$(jq '[.events[] | select(.key == "relayed-approval")] | length' "$json")" \
    "two mates' channel logs that reuse a key with no task copy are two asks"
  assert_equals "Lee (token owner); main keeps the scope list" "$(finding "$json" credential scope .owner)" "the finding names an owner"
  assert_equals "guard-hook secret-hook 600" "$(status_event "$json" task-node node-line '"\(.cause) \(.sub) \(.wait_s)"')" \
    "bare key= and at= markers parse, and a shell startup file the hook blocks is the secret hook"
  assert_equals "environment ssh-to-self 7200 false" \
    "$(status_event "$json" task-swap swap-c2 '"\(.cause) \(.sub) \(.wait_s) \(.reask)"')" \
    "a Lee step re-asked after an ssh line to the home's own host is ssh-to-self, measured from the first ask"
  assert_equals "1 1" "$(finding "$json" environment ssh-to-self '"\(.reasks) \(.waits_measured)"')" \
    "the re-ask is counted once and not measured again"
  assert_equals "policy credential-approval 5400" "$(status_event "$json" task-mail mailbox-token '"\(.cause) \(.sub) \(.wait_s)"')" \
    "a new credential waiting on Lee's naming word is the credential-approval policy"
  assert_equals "sudo 900 next-line" "$(status_event "$json" task-lic null '"\(.cause) \(.wait_s) \(.measured_by)"')" \
    "an unkeyed sudo wait is measured to the task's next line"
  assert_equals 1 "$(jq '[.events[] | select(.task == "task-lic" and .kind == "status-wait")] | length' "$json")" \
    "a ledger record of a line still in the live log is not counted twice"
  assert_equals "sudo 2400 ledger" "$(status_event "$json" gone fleet-sudo '"\(.cause) \(.wait_s) \(.source)"')" \
    "a cleaned-up task's wait is read from the fleet ledger"
  assert_equals 3 "$(finding "$json" sudo sudo .events)" "sudo waits group across tasks"
  assert_equals 0 "$(jq '[.events[] | select(.key == "old-day")] | length' "$json")" "a line opened on another day is not counted"
  assert_equals "false" "$(finding "$json" decision decision .carded)" "a product decision is reported but never carded"
  assert_grep "Lee-step ssh lines target the machine they run on" "$home/data/officers/friction/$DATE.md" \
    "the digest names the finding"
  pass "fm-officer friction: status-log waits on Lee are detected, measured, and grouped by root cause"
}

test_transcript_lee_steps_and_refusals() {
  local home json md
  home=$(make_world transcript)
  run_officer "$home" >/dev/null || fail "run must succeed"
  json="$home/data/officers/friction/$DATE.json"
  md="$home/data/officers/friction/$DATE.md"
  assert_equals "lee-command 300 2" \
    "$(jq -r '[.events[] | select(.kind == "lee-ask")][0] | "\(.cause) \(.wait_s) \(.count)"' "$json")" \
    "an ask is collapsed with its repeat and measured to the next message Lee typed, not the wake prompt"
  assert_equals "environment ssh-to-self" \
    "$(jq -r '[.events[] | select(.kind == "lee-command" and (.signature | startswith("ssh")))][0] | "\(.cause) \(.sub)"' "$json")" \
    "Lee typing ssh to the session's own host is ssh-to-self"
  assert_equals "credential ssh-key" \
    "$(jq -r '[.events[] | select(.kind == "lee-command" and (.signature | startswith("ssh -t beta")))][0] | "\(.cause) \(.sub)"' "$json")" \
    "a key refusal from another host is a missing ssh key, not ssh-to-self"
  assert_equals "op run" "$(jq -r '[.events[] | select(.kind == "lee-command" and .service == "1Password")][0].signature' "$json")" \
    "a typed command keeps only its command words"
  assert_equals "openjdk" "$(jq -r '[.events[] | select(.kind == "lee-command" and .cause == "missing-tool")][0].tool' "$json")" \
    "an install Lee typed names the missing tool"
  assert_no_grep "AbCdEf0123456789" "$json" "a token Lee typed never reaches the findings file"
  assert_no_grep "prod.env" "$md" "no argument text reaches the digest"
  assert_equals "guard-hook refused pre-bash-secret-exposure.py" \
    "$(jq -r '[.events[] | select(.kind == "agent-hit" and .cause == "guard-hook")][0] | "\(.cause) \(.sub) \(.tool)"' "$json")" \
    "a hook refusal is agent-side friction named by its hook"
  assert_equals 1 "$(jq '[.events[] | select(.kind == "agent-hit" and .cause == "sudo")] | length' "$json")" \
    "a sudo prompt counts only where a tool result line starts with it"
  assert_equals 1 "$(jq '[.events[] | select(.kind == "agent-hit" and .tool == "slopwatch")] | length' "$json")" \
    "command not found counts only at a line start, not in quoted rules text"
  assert_equals "service-limit rate-limit" \
    "$(jq -r '[.events[] | select(.kind == "agent-hit" and .service == "1Password")][0] | "\(.cause) \(.sub)"' "$json")" \
    "a 1Password Too many requests line is a rate limit"
  assert_equals "environment wrong-cwd task-wt" \
    "$(jq -r '[.events[] | select(.kind == "session-cwd")][0] | "\(.cause) \(.sub) \(.task)"' "$json")" \
    "a worker whose session runs outside its task worktree started in the wrong directory"
  pass "fm-officer friction: transcript Lee steps, asks and refusals are detected without transcript text"
}

test_velocity_findings_file() {
  local home vel
  home=$(make_world velocity)
  run_officer "$home" >/dev/null || fail "run must succeed"
  vel="$home/data/officers/friction/$DATE.velocity-findings.json"
  assert_present "$vel" "the velocity findings file is written"
  python3 -I - "$vel" <<'PY' || fail "the velocity findings file must match fleet-app's FINDINGS_SCHEMA limits"
import json, re, sys
d = json.load(open(sys.argv[1]))
top = {"schema_version", "source", "run_id", "generated_at", "window", "outcome", "summary", "notes",
       "cost_usd", "evidence", "bottlenecks"}
assert set(d) == top, sorted(set(d) ^ top)
assert d["schema_version"] == 1 and d["source"] == "friction-officer" and d["outcome"] == "ok"
assert re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,63}", d["run_id"]), d["run_id"]
assert d["generated_at"] == "2026-10-24T05:00:00Z", d["generated_at"]
assert d["window"] == {"from": "2026-10-23T00:00:00Z", "to": "2026-10-24T00:00:00Z"}, d["window"]
assert 1 <= len(d["summary"]) <= 300 and len(d["notes"]) <= 12 and all(1 <= len(n) <= 400 for n in d["notes"])
assert len(d["evidence"]) <= 12 and all(set(e) == {"name", "state", "detail"} and len(e["name"]) <= 40
                                         and e["state"] in ("read", "missing") for e in d["evidence"])
limits = {"title": 90, "tldr": 180, "evidence": 400, "improvement": 400, "impact": 250, "owner": 60, "time_saved": 200}
cats = {"waiting", "rework", "tooling", "review", "environment", "coordination", "cost", "other"}
assert 1 <= len(d["bottlenecks"]) <= 5, len(d["bottlenecks"])
for b in d["bottlenecks"]:
    assert set(b) == set(limits) | {"category", "severity", "confidence", "effort"}, sorted(b)
    for k, n in limits.items():
        assert 1 <= len(b[k]) <= n, (k, len(b[k]))
    assert b["category"] in cats and b["effort"] in ("S", "M", "L")
    assert 3 <= b["severity"] <= 5 and 3 <= b["confidence"] <= 5, (b["title"], b["severity"], b["confidence"])
    assert not re.search(r"\d", b["title"]), b["title"]
PY
  assert_equals "An agent token lacks a scope, so Lee widens it" \
    "$(jq -r '[.bottlenecks[] | select(.tldr | startswith("Cloudflare: "))][0].title' "$vel")" \
    "a status-backed Lee step clears the card bar, with the service named in its tldr, not its title"
  assert_no_grep "pick (a) the short wording" "$vel" "a product decision never becomes a card"
  pass "fm-officer friction: the velocity findings file has fleet-app's shape and limits"
}

test_rerun_digest_is_byte_identical() {
  local home first
  home=$(make_world idem)
  run_officer "$home" >/dev/null || fail "first run must succeed"
  first=$(cat "$home/data/officers/friction/$DATE.json" "$home/data/officers/friction/$DATE.md")
  FM_HOME="$home" FM_OFFICER_NOW=$((NOW + 3600)) "$OFFICER" run friction --date "$DATE" >/dev/null || fail "second run must succeed"
  assert_equals "$first" "$(cat "$home/data/officers/friction/$DATE.json" "$home/data/officers/friction/$DATE.md")" \
    "re-running a day rewrites identical digest bytes"
  assert_equals "2026-10-24T06:00:00Z" "$(jq -r .generated_at "$home/data/officers/friction/$DATE.velocity-findings.json")" \
    "only the velocity file carries the run time"
  pass "fm-officer friction: a re-run is byte-identical apart from the velocity file's run time"
}

test_boundary_reads_only_and_writes_only_its_lane() {
  local home fakebin before after cmd
  home=$(make_world boundary)
  fakebin=$(fm_fakebin "$TMP_ROOT/boundary")
  for cmd in ssh curl gh gh-axi linear-axi op op-agent fm-send.sh; do
    # shellcheck disable=SC2016 # the stub expands "$*" when it runs, not here.
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >> "%s/calls"\nexit 1\n' "$cmd" "$fakebin" > "$fakebin/$cmd"
    chmod +x "$fakebin/$cmd"
  done
  before=$(cd "$TMP_ROOT/boundary" && find . -path ./fixturehost/data/officers -prune -o -path ./fakebin -prune -o -type f -print | sort | xargs cksum)
  PATH="$fakebin:$PATH" run_officer "$home" >/dev/null || fail "run must succeed"
  after=$(cd "$TMP_ROOT/boundary" && find . -path ./fixturehost/data/officers -prune -o -path ./fakebin -prune -o -type f -print | sort | xargs cksum)
  assert_equals "$before" "$after" "no file outside the officer's lane is created or changed"
  assert_absent "$fakebin/calls" "a local archive run calls no network, GitHub, Linear, 1Password, or steering command"
  assert_equals "$DATE.json $DATE.md $DATE.velocity-findings.json digest runs.log" \
    "$(cd "$home/data/officers/friction" && find . -maxdepth 1 -type f ! -name '.*' | sed 's|^\./||' | sort | tr '\n' ' ' | sed 's/ $//')" \
    "the lane holds only the findings, the digest marker, and the run log"
  pass "fm-officer friction: the pass reads records and writes only its lane"
}

test_remote_archive_reads_over_ssh() {
  local home archive fakebin out
  home=$(make_world remote)
  archive="$TMP_ROOT/remote/archive"
  fakebin=$(fm_fakebin "$TMP_ROOT/remote")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/ssh.calls"
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; *) break ;; esac; done
shift
exec bash -c "$*"
SH
  chmod +x "$fakebin/ssh"
  friction_registry "$home" "archivehost:$archive"
  out=$(PATH="$fakebin:$PATH" run_officer "$home") || fail "remote run must succeed: $out"
  assert_grep "BatchMode=yes" "$fakebin/ssh.calls" "the archive host is reached non-interactively"
  assert_equals "environment ssh-to-self" \
    "$(jq -r '[.events[] | select(.kind == "lee-command" and (.signature | startswith("ssh")))][0] | "\(.cause) \(.sub)"' \
      "$home/data/officers/friction/$DATE.json")" "the remote scan carries the triage helpers it imports"
  pass "fm-officer friction: a host:dir archive is scanned over ssh"
}

test_captains_log_cards_read_only() {
  local home fakebin json vel md hashed
  home=$(make_world cards)
  fakebin=$(fm_fakebin "$TMP_ROOT/cards")
  printf 'needs-decision [at=%s] [key=captain-hold-pc-1234-1]: Lee, pick (a) or (b) for PC-1234\n' "$T" \
    > "$home/state/task-hold.status"
  # fleet-app cardId(): lowercased "<task>-<key>", a dash, and ten hex characters of sha256("<task>\0<key>").
  hashed="task-cf-cf-scope-$(printf 'task-cf\0cf-scope' | sha256sum | cut -c1-10)"
  jq -n --arg h "$hashed" --arg t "2026-10-23T10:01:00.000Z" '{name: "captains-log", value: {cards: [
      {id: $h, band: "now", question: "Widen the Cloudflare token?", advice: "a", replies: ["yes"],
       asked: $t, state: "asked"},
      {id: "pc-1234", band: "now", question: "Pick (a) or (b)?", advice: "a", replies: ["a"],
       asked: $t, state: "asked"},
      {id: "cf-dns-step", band: "now", question: "Add the MX record in the Cloudflare dashboard > zone settings",
       advice: "it is one record", replies: ["done"], asked: "2026-10-23T10:01:40.000Z", state: "answered",
       answer: {text: "done", at: "2026-10-23T10:31:40.000Z"}},
      {id: "old-card", band: "now", question: "Sign in to the Azure portal > admin", advice: "a", replies: ["ok"],
       asked: "2026-10-22T10:00:00.000Z", state: "asked"}]}}' > "$TMP_ROOT/cards/state.json"
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fakebin/curl.calls"
cat "$TMP_ROOT/cards/state.json"
SH
  chmod +x "$fakebin/curl"
  printf -- '- friction - Finds friction (role: friction; cadence: daily 06:15; archive: %s; captains-log: https://fleet.test/api/captains-log; model: none; added 2026-10-24)\n' \
    "$TMP_ROOT/cards/archive" > "$home/data/officers.md"
  PATH="$fakebin:$PATH" run_officer "$home" >/dev/null || fail "run with a Captain's Log must succeed"
  json="$home/data/officers/friction/$DATE.json"
  vel="$home/data/officers/friction/$DATE.velocity-findings.json"
  assert_grep "https://fleet.test/api/captains-log" "$fakebin/curl.calls" "the registry URL is the one endpoint read"
  assert_equals "cf-dns-step credential console-step Cloudflare 1800" \
    "$(jq -r '[.events[] | select(.kind == "card-only")] | map("\(.card) \(.cause) \(.sub) \(.service) \(.wait_s)") | join(";")' "$json")" \
    "only a card asked that day with no keyed or held status line is counted, measured to its answer"
  assert_equals "cf-dns-step" "$(finding "$json" credential console-step '.evidence.cards | join(",")')" \
    "the finding names the card as evidence"
  assert_equals "read" "$(jq -r '.evidence[] | select(.name == "Captain'"'"'s Log") | .state' "$vel")" \
    "the velocity file records the Captain's Log as read"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
exit 7
SH
  PATH="$fakebin:$PATH" run_officer "$home" >/dev/null || fail "an unreachable Captain's Log must not fail the run"
  md="$home/data/officers/friction/$DATE.md"
  assert_grep "The Captain's Log is unreachable (curl exit 7)" "$md" "an unreachable endpoint is a coverage gap in the digest"
  assert_equals 0 "$(jq '[.events[] | select(.kind == "card-only")] | length' "$json")" "no card is counted when none was read"
  assert_equals 1 "$(jq '[.events[] | select(.task == "task-cf" and .kind == "status-wait")] | length' "$json")" \
    "the run continues on the status logs"
  assert_equals "missing" "$(jq -r '.evidence[] | select(.name == "Captain'"'"'s Log") | .state' "$vel")" \
    "the velocity file marks the Captain's Log missing"
  printf '#!/usr/bin/env bash\nprintf "<html>sign in</html>"\n' > "$fakebin/curl"
  PATH="$fakebin:$PATH" run_officer "$home" >/dev/null || fail "a non-JSON Captain's Log must not fail the run"
  assert_grep "The Captain's Log is unreadable (not JSON), so" "$md" "a non-JSON answer reads as an unreadable log"
  assert_equals "Not read: the endpoint is unreadable (not JSON); counted from status logs only." \
    "$(jq -r '.evidence[] | select(.name == "Captain'"'"'s Log") | .detail' "$vel")" "the velocity detail reads as a sentence"
  printf -- '- friction - Finds friction (role: friction; cadence: daily 06:15; archive: %s; captains-log: http://fleet.test/api/captains-log; model: none; added 2026-10-24)\n' \
    "$TMP_ROOT/cards/archive" > "$home/data/officers.md"
  assert_contains "$(FM_HOME="$home" "$OFFICER" run friction --date "$DATE" 2>&1)" "captains-log must be an https URL" \
    "a non-https Captain's Log URL is refused"
  pass "fm-officer friction: Captain's Log cards are read once, read-only, and an unreachable log is a coverage gap"
}

test_registry_and_unharvested_day() {
  local home out
  home=$(make_world registry)
  printf -- '- friction - Finds friction (role: friction; cadence: daily 06:15; model: none; added 2026-10-24)\n' > "$home/data/officers.md"
  out=$(FM_HOME="$home" "$OFFICER" run friction --date "$DATE" 2>&1) && fail "a friction line without an archive must be refused"
  assert_contains "$out" "a friction officer needs archive" "the refusal names the missing field"
  friction_registry "$home" "$TMP_ROOT/registry/archive"
  out=$(FM_HOME="$home" "$OFFICER" run friction --date 2026-10-01 2>&1) && fail "a day with no manifest must fail the run"
  assert_contains "$out" "no archive manifest for 2026-10-01" "the failure names the missing manifest"
  assert_absent "$home/data/officers/friction/2026-10-01.velocity-findings.json" "no velocity file is written for a failed day"
  pass "fm-officer friction: the registry needs an archive, and a missing day fails the run"
}

test_merge_word_is_not_a_missing_tool
test_status_waits_and_root_causes
test_transcript_lee_steps_and_refusals
test_velocity_findings_file
test_rerun_digest_is_byte_identical
test_boundary_reads_only_and_writes_only_its_lane
test_remote_archive_reads_over_ssh
test_captains_log_cards_read_only
test_registry_and_unharvested_day
