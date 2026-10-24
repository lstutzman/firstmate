#!/usr/bin/env bash
# Behavior tests for the triage officer's deterministic pass, driven through
# bin/fm-officer.sh run against a fixture archive and fixture home records.
#
# Covers: session classification, the three join paths (launch brief,
# worktree, trace context) with their recorded join method, outcome resolution
# from the ledger, the live status log and a scout report, unresolved homes,
# byte-identical reruns, archive coverage, rule violations that report only a
# normalised command head, a remote archive read over ssh, and the model seam
# refusing anything but model: none.
set -u

# shellcheck source=tests/officer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/officer-helpers.sh"

OFFICER="$ROOT/bin/fm-officer.sh"
TMP_ROOT=$(fm_test_tmproot fm-officer-triage)
DATE=2026-10-23

# spec <file> <home>: four sessions and two task records for the join tests.
write_spec() {
  local file=$1 home=$2
  python3 -I - "$file" "$home" "$(officer_worker_brief "$home" task-done)" \
    "$(officer_worker_brief "$home" task-failed)" <<'PY'
import json, sys
path, home, brief_done, brief_failed = sys.argv[1:5]
msg = {"file_path": home + "/state/operational-inbox/1.msg"}
spec = {"sessions": [
  {"machine": "alpha", "id": "s-done", "first_prompt": ": Firstmate operational input waiting: read 'x'",
   "calls": [["Read", msg, brief_done, False],
             ["Bash", {"command": "rm -rf /home/lee/private/notes.txt"}, "", False]]},
  {"machine": "alpha", "id": "s-failed", "first_prompt": ": Firstmate operational input waiting: read 'y'",
   "calls": [["Read", msg, brief_failed, False],
             ["Bash", {"command": "sleep 30 && git status"}, "", False]]},
  {"machine": "alpha", "id": "s-classifier", "first_prompt": "You are an emotion-tone classifier for conversations.",
   "calls": []},
  {"machine": "alpha", "id": "s-engine", "first_prompt": "MAIN DIALOG MIRROR turn 3",
   "calls": [["Read", {"file_path": "/x"}, "ok", False], ["Read", {"file_path": "/x"}, "ok", False]]},
  {"machine": "alpha", "id": "s-worktree", "first_prompt": "hello", "cwd": "/work/task-merged",
   "calls": []},
  {"machine": "alpha", "id": "s-trace", "first_prompt": "hello",
   "calls": [["Bash", {"command": "echo $TRACEPARENT"},
              "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01", False]]},
  {"machine": "alpha", "id": "s-elsewhere", "first_prompt": ": Firstmate operational input waiting: read 'z'",
   "calls": [["Read", msg, "FIRSTMATE_OP: v1 launch-brief\nYour steering inbox is `/far/home/state/far-task.inbox`.", False]]},
]}
json.dump(spec, open(path, "w"))
PY
}

# A home whose records resolve each joined task to a known outcome.
make_world() {
  local name=$1 home archive
  home="$TMP_ROOT/$name/home"
  archive="$TMP_ROOT/$name/archive"
  officer_home "$home"
  printf 'working [at=1]: started\ndone [at=2]: finished\n' > "$home/state/task-done.status"
  printf 'working [at=1]: started\nfailed [at=2]: could not build\n' > "$home/state/task-failed.status"
  printf 'kind=ship\nworktree=/work/task-merged\n' > "$home/state/task-merged.meta"
  printf '%s\n' '{"v":1,"ts":5,"event":"task.merged","task":"task-merged","via":"local"}' > "$home/state/fleet-ledger.jsonl"
  printf 'kind=scout\ntraceparent=00-0123456789abcdef0123456789abcdef-1111111111111111-01\n' > "$home/state/task-scout.meta"
  mkdir -p "$home/data/task-scout"
  printf 'report\n' > "$home/data/task-scout/report.md"
  write_spec "$TMP_ROOT/$name/spec.json" "$home"
  officer_archive "$archive" "$DATE" "$TMP_ROOT/$name/spec.json"
  officer_registry "$home" "$archive" "alpha,beta"
  printf '%s\n' "$home"
}

run_officer() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" "$OFFICER" run triage --date "$DATE" "$@"
}

session_field() {  # <json> <session> <jq-path>
  jq -r --arg s "alpha:$2" ".sessions[] | select(.session == \$s) | $3" "$1"
}

test_classification_join_and_outcomes() {
  local home out json
  home=$(make_world join)
  out=$(run_officer "$home") || fail "triage run must succeed: $out"
  assert_contains "$out" "DIGEST $DATE " "run prints the digest marker"
  json="$home/data/officers/triage/$DATE.json"
  assert_equals worker "$(session_field "$json" s-done .class)" "a launch-brief session is a worker"
  assert_equals classifier "$(session_field "$json" s-classifier .class)" "classifier call is classified"
  assert_equals supervision-engine "$(session_field "$json" s-engine .class)" "supervision engine turn is classified"
  assert_equals task-done "$(session_field "$json" s-done .join.task)" "worker joins its task"
  assert_equals launch-brief "$(session_field "$json" s-done .join.via)" "join method is recorded"
  assert_equals "done" "$(session_field "$json" s-done .join.outcome)" "done outcome comes from the status log"
  assert_equals failed "$(session_field "$json" s-failed .join.outcome)" "failed outcome comes from the status log"
  assert_equals worktree "$(session_field "$json" s-worktree .join.via)" "cwd joins a task meta worktree"
  assert_equals merged "$(session_field "$json" s-worktree .join.outcome)" "the ledger outcome wins"
  assert_equals trace-context "$(session_field "$json" s-trace .join.via)" "a traceparent joins by trace id"
  assert_equals reported "$(session_field "$json" s-trace .join.outcome)" "a scout report is its outcome"
  assert_equals 0123456789abcdef0123456789abcdef "$(session_field "$json" s-trace .join.trace_id)" "the trace id is recorded"
  assert_equals unresolved "$(session_field "$json" s-elsewhere .join.outcome)" "a home not readable here stays unresolved"
  assert_equals 1 "$(jq -r '.wasted_turns["sleep-then-check"]' "$json")" "sleep-then-check is counted"
  assert_equals 1 "$(jq -r '.wasted_turns["re-read"]' "$json")" "a re-read is counted"
  assert_grep "worker task task-failed ended failed" "$json" "a failed worker task is a finding"
  pass "fm-officer triage: classifies sessions, joins tasks three ways, resolves outcomes"
}

test_rerun_is_byte_identical() {
  local home first
  home=$(make_world idem)
  run_officer "$home" >/dev/null || fail "first run must succeed"
  first=$(cat "$home/data/officers/triage/$DATE.json" "$home/data/officers/triage/$DATE.md")
  run_officer "$home" >/dev/null || fail "second run must succeed"
  assert_equals "$first" "$(cat "$home/data/officers/triage/$DATE.json" "$home/data/officers/triage/$DATE.md")" \
    "re-running a day rewrites identical bytes"
  pass "fm-officer triage: re-running the same day is byte-identical"
}

test_coverage_names_missing_host() {
  local home json
  home=$(make_world coverage)
  run_officer "$home" >/dev/null || fail "run must succeed"
  json="$home/data/officers/triage/$DATE.json"
  assert_grep "no archived sessions from expected host beta" "$json" "a missing expected host is a coverage finding"
  assert_no_grep "expected host alpha" "$json" "a present host is not flagged"
  pass "fm-officer triage: coverage names a missing expected host"
}

test_rule_violation_reports_command_head_only() {
  local home json findings
  home=$(make_world rules)
  run_officer "$home" >/dev/null || fail "run must succeed"
  json="$home/data/officers/triage/$DATE.json"
  findings=$(jq -c '[.findings[] | select(.kind == "rule-violation")]' "$json")
  assert_equals 1 "$(printf '%s' "$findings" | jq length)" "one bare rm gives one rule-violation finding"
  assert_equals alpha:s-done "$(printf '%s' "$findings" | jq -r '.[0].session')" "the finding names its session"
  assert_contains "$(printf '%s' "$findings" | jq -r '.[0].summary')" "rm -rf ..." "the finding carries the command head"
  assert_no_grep "notes.txt" "$json" "no argument text reaches the findings file"
  assert_no_grep "notes.txt" "$home/data/officers/triage/$DATE.md" "no argument text reaches the digest"
  pass "fm-officer triage: a bare rm is one finding with no transcript excerpt"
}

test_missing_manifest_is_a_coverage_finding() {
  local home out
  home=$(make_world nomanifest)
  out=$(FM_HOME="$home" "$OFFICER" run triage --date 2026-10-01) || fail "a day with no manifest still produces a digest: $out"
  assert_grep "no archive manifest for 2026-10-01" "$home/data/officers/triage/2026-10-01.json" "the missing day is reported"
  pass "fm-officer triage: a day the archive never wrote is a coverage finding"
}

test_remote_archive_reads_over_ssh() {
  local home archive fakebin out
  home=$(make_world remote)
  archive="$TMP_ROOT/remote/archive"
  fakebin=$(fm_fakebin "$TMP_ROOT/remote")
  # The fake ssh drops its options and host, then runs the remote command here.
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/ssh.calls"
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; *) break ;; esac; done
shift
exec bash -c "$*"
SH
  chmod +x "$fakebin/ssh"
  officer_registry "$home" "archivehost:$archive" "alpha,beta"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$OFFICER" run triage --date "$DATE") || fail "remote run must succeed: $out"
  assert_grep "BatchMode=yes" "$fakebin/ssh.calls" "the archive host is reached non-interactively"
  assert_equals "done" "$(session_field "$home/data/officers/triage/$DATE.json" s-done .join.outcome)" \
    "the remote scan joins against local home records"
  printf '#!/usr/bin/env bash\nexit 255\n' > "$fakebin/ssh"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$OFFICER" run triage --date "$DATE" 2>&1) && fail "an unreachable host must fail the run"
  assert_contains "$out" "unreachable" "the failure names the unreachable host"
  assert_grep "$DATE failed" "$home/data/officers/triage/runs.log" "the failure is logged"
  pass "fm-officer triage: a host:dir archive is scanned over ssh; unreachable fails the run"
}

test_model_seam_accepts_only_none() {
  local home out
  home=$(make_world model)
  sed -i.bak 's/model: none/model: sonnet/' "$home/data/officers.md"
  out=$(run_officer "$home" 2>&1) && fail "a model other than none must be refused"
  assert_contains "$out" "not available yet" "the refusal names the missing slice"
  pass "fm-officer triage: slice 1 refuses model scoring"
}

test_classification_join_and_outcomes
test_rerun_is_byte_identical
test_coverage_names_missing_host
test_rule_violation_reports_command_head_only
test_missing_manifest_is_a_coverage_finding
test_remote_archive_reads_over_ssh
test_model_seam_accepts_only_none
