#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-drain.py (the open-PR drain state of a project's GitHub repository) and the
# brief text bin/fm-brief.sh writes from it. A fake gh on PATH answers `gh pr list --state open` from
# open.json and `--state closed` from closed.json, so each case drives a PR timeline with no network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-drain)
DRAIN="$ROOT/bin/fm-pr-drain.py"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
GHDATA="$TMP_ROOT/gh"
mkdir -p "$GHDATA"
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
[ -z "${FAKE_GH_FAIL:-}" ] || { echo "HTTP 502: bad gateway" >&2; exit 1; }
state= limit=30 search=
while [ $# -gt 0 ]; do
  case $1 in --state) state=$2 ;; --limit) limit=$2 ;; --search) search=1 ;; esac
  shift
done
# GitHub's search API returns at most 1000 results, whatever --limit asks for.
[ -z "$search" ] || [ "$limit" -le 1000 ] || limit=1000
python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))[:int(sys.argv[2])]))' "$FAKE_GH_DATA/$state.json" "$limit"
SH
chmod +x "$FAKEBIN/gh"
export FAKE_GH_DATA="$GHDATA" PATH="$FAKEBIN:$PATH"

PROJECT="$TMP_ROOT/project"
fm_git_init_commit "$PROJECT"
git -C "$PROJECT" remote add origin git@github.com:o/r.git

# timeline <open-created-hours-ago...> -- <closed created:closed hours-ago...>
timeline() {
  python3 -I - "$GHDATA" "$@" <<'PY'
import json, sys, time
def iso(hours):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() - float(hours) * 3600))
out, args = sys.argv[1], sys.argv[2:]
cut = args.index('--')
json.dump([{'createdAt': iso(h)} for h in args[:cut]], open(out + '/open.json', 'w'))
json.dump([{'createdAt': iso(c), 'closedAt': iso(d)} for c, d in (a.split(':') for a in args[cut + 1:])],
          open(out + '/closed.json', 'w'))
PY
}

# A peak of 20 PRs opened 10 hours ago, of which all but <open> closed an hour ago.
peak_then() {  # <open>
  local args=() i
  for ((i = 0; i < $1; i++)); do args+=(10); done
  args+=(--)
  for ((i = $1; i < 20; i++)); do args+=(10:1); done
  timeline "${args[@]}"
}

test_twenty_open_turns_drain_on() {
  local args=() i
  for ((i = 0; i < 20; i++)); do args+=(3); done
  timeline "${args[@]}" --
  assert_equals "on o/r 20" "$("$DRAIN" state "$PROJECT")" "20 open PRs did not read as drain on"
  pass "20 open PRs turn the drain on"
}

test_drain_holds_from_nineteen_down_to_one() {
  local n
  for n in 19 18 17 16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1; do
    peak_then "$n"
    assert_equals "on o/r $n" "$("$DRAIN" state "$PROJECT")" "$n open PRs after a peak of 20 did not stay in drain"
  done
  pass "after a peak of 20 the drain holds at every count from 19 down to 1"
}

test_zero_open_turns_drain_off() {
  peak_then 0
  assert_equals "off o/r 0" "$("$DRAIN" state "$PROJECT")" "0 open PRs did not end the drain"
  pass "0 open PRs end the drain"
}

test_a_zero_since_the_peak_keeps_drain_off() {
  # 20 opened and closed 30 hours ago, then 0, then 5 new PRs 2 hours ago.
  local args=(2 2 2 2 2 --) i
  for ((i = 0; i < 20; i++)); do args+=(40:30); done
  timeline "${args[@]}"
  assert_equals "off o/r 5" "$("$DRAIN" state "$PROJECT")" "5 open PRs after a return to 0 read as drain on"
  pass "a return to 0 after the peak keeps later PRs out of drain"
}

test_unreadable_or_undecided_history_is_unknown() {
  local out
  timeline 5 5 --
  out=$(FAKE_GH_FAIL=1 "$DRAIN" state "$PROJECT")
  assert_contains "$out" "unknown o/r GitHub unreadable: HTTP 502" "an unreadable GitHub did not read as unknown: $out"
  timeline 900 900 --
  out=$("$DRAIN" state "$PROJECT")
  assert_contains "$out" "unknown o/r open count stayed between 1 and 19" "a window with no 0 or 20 did not read as unknown: $out"
  pass "an unreadable GitHub or a history with no 0 or 20 in the window reads as unknown"
}

test_closed_list_at_the_search_cap_is_unknown() {
  local args=(5 --) i
  for ((i = 0; i < 1200; i++)); do args+=(48:24); done
  timeline "${args[@]}"
  assert_contains "$("$DRAIN" state "$PROJECT")" "unknown o/r 1000 or more PRs closed in 14 days" \
    "a closed list cut at GitHub's 1000-result search cap was walked as if complete"
  pass "a closed list that reaches GitHub's 1000-result search cap reads as unknown"
}

test_non_github_origin_is_not_applicable() {
  local other="$TMP_ROOT/other"
  fm_git_init_commit "$other"
  git -C "$other" remote add origin "file://$TMP_ROOT/nowhere.git"
  assert_equals "none" "$(FAKE_GH_FAIL=1 "$DRAIN" state "$other")" "a non-GitHub origin was queried"
  pass "a clone whose origin is not on github.com is outside the rule"
}

test_classes_are_validated() {
  local value
  for value in production-outage cve security wolverine lee-research lee-explicit officer scheduled restack red-gate-fix returned-pr-fix review; do
    "$DRAIN" class "$value" || fail "$value was not accepted as a drain class"
  done
  "$DRAIN" class feature && fail "an unknown drain class was accepted"
  pass "every exemption class and landing job is accepted and nothing else"
}

brief() {  # <id> <mode> <args...>
  local id=$1 mode=$2
  shift 2
  FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-brief.sh" "$id" r --mode "$mode" --project "$PROJECT" "$@" >"$TMP_ROOT/brief.out" 2>&1
}

# The PR drain check line a brief hands its worker, or nothing.
drain_check() {  # <id>
  # shellcheck disable=SC2016 # literal backticks, not an expansion
  sed -n 's/^PR drain check: .*run `\([^`]*\)` from your worktree\.$/\1/p' "$TMP_ROOT/home/data/$1/brief.md"
}

test_brief_tells_workers_to_check_drain_before_a_pr() {
  local home="$TMP_ROOT/home" id check
  mkdir -p "$home/data"
  peak_then 0
  for id in calm-nm:no-mistakes calm-direct:direct-PR; do
    brief "${id%%:*}" "${id#*:}" || fail "the ${id#*:} brief did not scaffold: $(cat "$TMP_ROOT/brief.out")"
    check=$(drain_check "${id%%:*}")
    [ -n "$check" ] || fail "a ${id#*:} brief written outside drain has no PR drain check"
    assert_grep "If your branch already has an open pull request, skip this check and finish through the Definition of done, /no-mistakes included." \
      "$home/data/${id%%:*}/brief.md" "the ${id#*:} drain check does not spare a branch that already has a pull request"
    assert_no_regex "^# PR drain$" "$home/data/${id%%:*}/brief.md" "a brief written outside drain has a PR drain section"
  done
  # The command the brief hands the worker reads the live state from the worktree.
  peak_then 7
  assert_equals "on o/r 7" "$(cd "$PROJECT" && eval "$check")" "the brief's drain check did not read the live drain"
  peak_then 0
  assert_equals "off o/r 0" "$(cd "$PROJECT" && eval "$check")" "the brief's drain check did not see the drain end"
  brief local local-only || fail "the local-only brief did not scaffold"
  assert_no_grep "PR drain" "$home/data/local/brief.md" "a local-only brief mentions the PR drain"
  peak_then 7
  brief drained no-mistakes || fail "the drained brief did not scaffold"
  grep -qx "# PR drain" "$home/data/drained/brief.md" || fail "a brief written in drain has no PR drain section"
  [ -n "$(drain_check drained)" ] || fail "a brief written in drain has no PR drain check"
  for id in cve restack red-gate-fix returned-pr-fix review; do
    brief "x-$id" no-mistakes --pr-drain "$id" || fail "the $id brief did not scaffold"
    assert_no_grep "PR drain check" "$home/data/x-$id/brief.md" "a $id brief was told to check the drain"
    assert_no_regex "^# PR drain$" "$home/data/x-$id/brief.md" "a $id brief in drain was told not to open a PR"
    assert_grep "PR drain: $id" "$home/data/x-$id/brief.md" "--pr-drain did not record $id"
  done
  brief x-wolverine no-mistakes --pr-drain wolverine || fail "the wolverine brief did not scaffold"
  grep -qx "# PR drain" "$home/data/x-wolverine/brief.md" || fail "a wolverine brief in drain has no PR drain section"
  [ -n "$(drain_check x-wolverine)" ] || fail "a wolverine brief in drain does not carry the drain check"
  brief bad no-mistakes --pr-drain feature && fail "an unknown --pr-drain class was accepted"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" scouted r --scout --pr-drain cve >/dev/null 2>&1 &&
    fail "--pr-drain was accepted on a scout"
  pass "PR-opening briefs carry a live drain check, landing jobs and cve skip it, and --pr-drain is validated"
}

# shellcheck source=bin/fm-brief-heading-lib.sh
. "$ROOT/bin/fm-brief-heading-lib.sh"

# A brief file whose `## Captain's intent` section holds the given lines.
intent_brief() {  # <name> <intent-line>...
  local file="$TMP_ROOT/intent-$1.md"
  shift
  { printf '# Task\n## Captain'"'"'s intent\n'; printf '%s\n' "$@"; printf '\n## Firstmate spec\nLee (x, 2026-11-16T18:19:06Z): "outside the section"\n'; } >"$file"
  printf '%s' "$file"
}

# Run the evidence check on a brief the way bin/fm-spawn.sh does.
brief_evidence() {  # <brief-file>
  fm_brief_task_heading_body "$1" "## Captain's intent" | "$DRAIN" evidence
}

test_lee_explicit_evidence_needs_a_quote_and_a_timestamp() {
  local file
  file=$(intent_brief same 'Lee (main chat, 2026-11-16T18:19:06Z): "build the gate"')
  brief_evidence "$file" 2>/dev/null || fail "a quote with a timestamp on its line was refused"
  file=$(intent_brief prev 'Lee, main chat 2026-11-16T18:19:06Z:' '"build the gate"')
  brief_evidence "$file" 2>/dev/null || fail "a quote with a timestamp on the line before was refused"
  file=$(intent_brief noquote 'Lee (main chat, 2026-11-16T18:19:06Z): build the gate')
  brief_evidence "$file" 2>"$TMP_ROOT/err" && fail "a brief with no quote was accepted"
  assert_grep "double-quoted" "$TMP_ROOT/err" "the refusal did not name the missing quote"
  file=$(intent_brief nostamp 'Lee (main chat): "build the gate"')
  brief_evidence "$file" 2>"$TMP_ROOT/err" && fail "a brief with no timestamp was accepted"
  assert_grep "timestamp" "$TMP_ROOT/err" "the refusal did not name the missing timestamp"
  file=$(intent_brief far '2026-11-16T18:19:06Z' 'context' 'Lee: "build the gate"')
  brief_evidence "$file" 2>/dev/null && fail "a timestamp two lines before the quote was accepted"
  file=$(intent_brief fenced 'Lee pasted:' '```sh' '# rerun the gate' 'make gate' '```' 'Lee (main chat, 2026-11-16T18:19:06Z): "build the gate"')
  brief_evidence "$file" 2>/dev/null || fail "a quote after a fenced block with a # comment was refused"
  file="$TMP_ROOT/intent-outside.md"
  printf '# Task\n## Captain'"'"'s intent\nbuild the gate\n\n# Notes\n## Captain'"'"'s intent\nLee (x, 2026-11-16T18:19:06Z): "outside the task"\n' >"$file"
  brief_evidence "$file" 2>/dev/null && fail "a quote under a second intent heading outside # Task was accepted"
  pass "lee-explicit evidence needs a quoted instruction and a UTC timestamp in the captain's intent, and names what is missing"
}

# A stub Linear reader: prints the JSON in $FAKE_LINEAR_JSON, or fails when FAKE_LINEAR_FAIL is set.
cat > "$TMP_ROOT/linear-reader" <<'SH'
#!/usr/bin/env bash
[ -z "${FAKE_LINEAR_FAIL:-}" ] || { echo "Linear request failed: boom" >&2; exit 1; }
printf '%s' "$FAKE_LINEAR_JSON"
SH
chmod +x "$TMP_ROOT/linear-reader"

security_check() {  # <item> <json>
  FM_PR_DRAIN_LINEAR_READER="$TMP_ROOT/linear-reader" FAKE_LINEAR_JSON=$2 "$DRAIN" security "$1" 2>"$TMP_ROOT/err"
}

test_security_needs_the_label_and_urgent_or_high_priority() {
  security_check PC-5174 '{"priority": 1, "labels": ["Bug", "agent", "Security"]}' || fail "an Urgent item labelled Security was refused"
  security_check PC-5174 '{"priority": 2, "labels": ["security"]}' || fail "a High item labelled security was refused"
  security_check PC-5174 '{"priority": 1, "labels": ["Bug", "agent"]}' && fail "an item with no security label was accepted"
  assert_grep "PC-5174" "$TMP_ROOT/err" "the refusal did not name the item"
  assert_grep "label \`security\`" "$TMP_ROOT/err" "the refusal did not name the missing label"
  security_check PC-5174 '{"priority": 3, "labels": ["security"]}' && fail "a Medium item was accepted"
  assert_grep "priority Urgent or High" "$TMP_ROOT/err" "the refusal did not name the priority"
  security_check PC-5174 '{"priority": 4, "labels": ["security"]}' && fail "a Low item was accepted"
  security_check PC-5174 '{"priority": 0, "labels": ["security"]}' && fail "an item with no priority was accepted"
  security_check PC-5174 '{"priority": 1, "labels": ["security-review"]}' && fail "a similarly named label was accepted"
  security_check PC-5174 'not json' && fail "an unreadable answer was accepted"
  FAKE_LINEAR_FAIL=1 security_check PC-5174 '' && fail "an unreadable Linear was accepted"
  assert_grep "readable Linear item" "$TMP_ROOT/err" "the refusal did not say Linear could not be read"
  security_check 'PC-5174; x' '{"priority": 1, "labels": ["security"]}' && fail "a malformed item id was accepted"
  FM_PR_DRAIN_LINEAR_READER="$TMP_ROOT/nowhere" "$DRAIN" security PC-1 2>/dev/null && fail "a missing reader was accepted"
  pass "security needs the label (any case) and Urgent or High priority, and names what is missing or unreadable"
}

test_security_reads_linear_graphql_without_echoing_the_credential() {
  local server="$TMP_ROOT/linear-server.py" port token='Bearer lin_api_test_SECRET_9f3c' answer
  cat > "$FAKEBIN/linear-token" <<SH
#!/usr/bin/env bash
[ "\$*" = "header --print-to-pipe" ] || exit 2
printf '%s\n' '$token'
SH
  chmod +x "$FAKEBIN/linear-token"
  cat > "$server" <<'SERVER'
import http.server, json, os, sys
root = sys.argv[1]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with open(f'{root}/linear-request.json', 'w') as f:
            json.dump({'authorization': self.headers.get('Authorization'), 'body': body}, f)
        with open(f'{root}/linear-answer') as f:
            status, answer = f.read().split('\n', 1)
        self.send_response(int(status))
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(answer.encode())
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
with open(f'{root}/linear-port.tmp', 'w') as f:
    f.write(str(server.server_port))
os.rename(f'{root}/linear-port.tmp', f'{root}/linear-port')
server.serve_forever()
SERVER
  python3 -I "$server" "$TMP_ROOT" >/dev/null 2>&1 &
  LINEAR_SERVER_PID=$!
  trap 'kill "$LINEAR_SERVER_PID" 2>/dev/null; fm_test_cleanup' EXIT
  for _ in $(seq 50); do [ -s "$TMP_ROOT/linear-port" ] && break; sleep 0.1; done
  port=$(cat "$TMP_ROOT/linear-port") || fail "the stub Linear server did not start"
  live() {  # <status> <answer>
    printf '%s\n%s' "$1" "$2" > "$TMP_ROOT/linear-answer"
    FM_PR_DRAIN_LINEAR_URL="http://127.0.0.1:$port/graphql" "$DRAIN" security PC-5174 2>"$TMP_ROOT/err"
  }
  live 200 '{"data":{"issue":{"identifier":"PC-5174","priority":1,"labels":{"nodes":[{"name":"Bug"},{"name":"agent"},{"name":"security"}]}}}}' ||
    fail "an Urgent item labelled security was refused over GraphQL: $(cat "$TMP_ROOT/err")"
  python3 -I -c 'import json, sys
r = json.load(open(sys.argv[1]))
assert r["authorization"] == sys.argv[2], "the linear-token header was not sent"
assert r["body"]["variables"] == {"id": "PC-5174"}, r["body"]["variables"]' "$TMP_ROOT/linear-request.json" "$token" ||
    fail "the GraphQL request did not carry the credential and the item id"
  live 200 '{"data":{"issue":{"identifier":"PC-5174","priority":3,"labels":{"nodes":[{"name":"security"}]}}}}' &&
    fail "a Medium item was accepted over GraphQL"
  assert_grep "priority Urgent or High" "$TMP_ROOT/err" "the GraphQL refusal did not name the priority"
  for answer in '{"data":{"issue":null}}' '{"data":null,"errors":[{"message":"Entity not found"}]}' 'not json'; do
    live 200 "$answer" && fail "an unusable GraphQL answer was accepted: $answer"
    assert_grep "readable Linear item" "$TMP_ROOT/err" "the refusal did not say Linear was unreadable for: $answer"
    assert_no_grep "SECRET" "$TMP_ROOT/err" "the credential reached stderr for: $answer"
  done
  live 401 '{"errors":[{"message":"Authentication required, got Bearer lin_api_test_SECRET_9f3c"}]}' &&
    fail "a refused GraphQL read was accepted"
  assert_grep "readable Linear item" "$TMP_ROOT/err" "the 401 refusal did not say Linear was unreadable"
  assert_no_grep "SECRET" "$TMP_ROOT/err" "the credential reached stderr on a 401"
  kill "$LINEAR_SERVER_PID"
  trap fm_test_cleanup EXIT
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/linear-token"
  live 200 '' && fail "a security item was accepted with no Linear credential"
  assert_grep "readable Linear item" "$TMP_ROOT/err" "a missing credential did not refuse as unreadable"
  pass "security reads the item over Linear GraphQL with the linear-token header, refuses null, errors, non-JSON and 401 answers, and never echoes the credential"
}

test_security_brief_needs_a_linear_item() {
  local home="$TMP_ROOT/home"
  mkdir -p "$home/data"
  peak_then 0
  brief sec-none no-mistakes --pr-drain security && fail "a security brief with no --linear was scaffolded"
  assert_grep "needs --linear" "$TMP_ROOT/brief.out" "the refusal did not name --linear"
  cat > "$FAKEBIN/linear-axi" <<'STUB'
#!/usr/bin/env bash
printf 'issue:\n  identifier: %s\n  description: "Acceptance:\\n- fixed"\n' "$3"
STUB
  chmod +x "$FAKEBIN/linear-axi"
  peak_then 7
  brief sec-ok no-mistakes --pr-drain security --linear PC-5174 || fail "a security brief with --linear did not scaffold: $(cat "$TMP_ROOT/brief.out")"
  assert_grep "PR drain: security" "$home/data/sec-ok/brief.md" "--pr-drain did not record security"
  assert_no_grep "PR drain check" "$home/data/sec-ok/brief.md" "a security brief was told to check the drain"
  assert_no_regex "^# PR drain$" "$home/data/sec-ok/brief.md" "a security brief in drain was told not to open a PR"
  pass "a security brief refuses to scaffold without --linear and skips the drain wording with it"
}

test_open_count_reads_one_repository() {
  local other="$TMP_ROOT/other-open"
  timeline 1 2 3 --
  assert_equals "open o/r 3" "$("$DRAIN" open "$PROJECT")" "the open PR count was not read"
  peak_then 0
  assert_equals "open o/r 0" "$("$DRAIN" open "$PROJECT")" "an empty repository did not read as 0 open PRs"
  assert_contains "$(FAKE_GH_FAIL=1 "$DRAIN" open "$PROJECT")" "unknown o/r GitHub unreadable: HTTP 502" "an unreadable GitHub was not reported"
  fm_git_init_commit "$other"
  git -C "$other" remote add origin "file://$TMP_ROOT/nowhere.git"
  assert_equals "none" "$(FAKE_GH_FAIL=1 "$DRAIN" open "$other")" "a non-GitHub origin was queried"
  pass "open prints the open PR count, unknown when GitHub is unreadable, and none off github.com"
}

# A project's open PRs as GitHub reports them: <ready> ready ones numbered 1.., then <drafts> drafts.
open_prs() {  # <ready> <drafts>
  python3 -I -c 'import json, sys
ready, drafts = int(sys.argv[2]), int(sys.argv[3])
json.dump([{"createdAt": "2026-11-01T00:00:00Z", "isDraft": n > ready, "url": f"https://github.com/o/r/pull/{n}"}
           for n in range(1, ready + drafts + 1)], open(sys.argv[1], "w"))' "$GHDATA/open.json" "$1" "$2"
}

test_open_leaves_drafts_out_of_the_count_and_detail_lists_ready_urls() {
  peak_then 5
  open_prs 2 3
  assert_equals "open o/r 2" "$("$DRAIN" open "$PROJECT")" "drafts were counted in the open PR count"
  assert_equals "$(printf 'open o/r 2 5\nhttps://github.com/o/r/pull/1\nhttps://github.com/o/r/pull/2')" \
    "$("$DRAIN" open-detail "$PROJECT")" "open-detail did not print the ready count, the total and the ready PR URLs"
  assert_equals "on o/r 5" "$("$DRAIN" state "$PROJECT")" "state must still count every open PR, drafts included, for the 20-PR drain"
  assert_contains "$(FAKE_GH_FAIL=1 "$DRAIN" open-detail "$PROJECT")" "unknown o/r GitHub unreadable: HTTP 502" "open-detail did not report an unreadable GitHub"
  timeline 1 2 --
  assert_equals "open o/r 2 2" "$("$DRAIN" open-detail "$PROJECT")" "a PR with no isDraft or url field was not counted as ready"
  pass "open and open-detail leave drafts out of the count, open-detail also reports the total and the ready URLs, and state still counts every PR"
}

GATE_HOME="$TMP_ROOT/gate-home"
mkdir -p "$GATE_HOME/config" "$GATE_HOME/state" "$GATE_HOME/data"
gate() {  # prints the verdict line for project r
  FM_HOME="$GATE_HOME" "$DRAIN" gate "$PROJECT" r
}

test_gate_holds_a_pr_opening_at_the_slots_and_at_the_cap() {
  rm -f "$GATE_HOME/config/ci-slots" "$GATE_HOME/config/open-pr-cap"
  open_prs 9 9
  assert_equals "open o/r" "$(gate)" "a project with no CI slots line was held"
  printf '%s\n' 'r 4' > "$GATE_HOME/config/ci-slots"
  open_prs 3 8
  assert_equals "open o/r" "$(gate)" "3 ready PRs and 8 drafts were held against 4 slots"
  open_prs 4 0
  assert_contains "$(gate)" "hold o/r CI slots full: 4 open PR(s) count against 4 CI slot(s)" "4 ready PRs against 4 slots did not hold the PR opening"
  open_prs 4 3
  assert_contains "$(gate)" "3 draft PR(s)" "the hold did not say that drafts were left out"
  open_prs 3 9
  assert_contains "$(gate)" "hold o/r open-PR cap reached: 12 open PR(s) against the open-PR cap of 12 (config/open-pr-cap)" \
    "12 open PRs, drafts included, did not reach the default cap of 12"
  open_prs 3 8
  assert_equals "open o/r" "$(gate)" "11 open PRs reached the default cap of 12"
  printf '%s\n' '# the cap' 'r 5' > "$GATE_HOME/config/open-pr-cap"
  open_prs 3 2
  assert_contains "$(gate)" "against the open-PR cap of 5" "a declared cap of 5 was not used"
  open_prs 3 1
  assert_equals "open o/r" "$(gate)" "4 open PRs reached a declared cap of 5"
  printf '%s\n' 'r twelve' > "$GATE_HOME/config/open-pr-cap"
  assert_contains "$(gate)" "unknown o/r" "a malformed open-pr-cap file did not read as unknown"
  rm "$GATE_HOME/config/open-pr-cap"
  printf '%s\n' 'r four' > "$GATE_HOME/config/ci-slots"
  assert_contains "$(gate)" "unknown o/r" "a malformed ci-slots file did not read as unknown"
  printf '%s\n' 'r 4' > "$GATE_HOME/config/ci-slots"
  assert_contains "$(FAKE_GH_FAIL=1 gate)" "unknown o/r GitHub unreadable" "an unreadable GitHub did not read as unknown"
  assert_equals "none" "$(FM_HOME="$GATE_HOME" FAKE_GH_FAIL=1 "$DRAIN" gate "$TMP_ROOT/other" r)" "a non-GitHub origin was queried"
  pass "gate holds a PR opening at S ready PRs or at the open-PR cap of 12, leaves drafts out of S, and reads unknown or none rather than guessing"
}

test_brief_carries_the_ci_slots_gate_only_when_slots_are_declared() {
  local home="$TMP_ROOT/home" id
  mkdir -p "$home/data" "$home/config"
  rm -f "$home/config/ci-slots"
  peak_then 0
  brief no-slots no-mistakes || fail "the no-slots brief did not scaffold"
  assert_no_grep "CI slots check" "$home/data/no-slots/brief.md" "a project with no CI slots got the CI slots check"
  printf '%s\n' 'r 4' > "$home/config/ci-slots"
  for id in classless:none wolverine:wolverine lee-research:lee-research officer:officer scheduled:scheduled; do
    if [ "${id#*:}" = none ]; then brief "gate-${id%%:*}" no-mistakes; else brief "gate-${id%%:*}" no-mistakes --pr-drain "${id#*:}"; fi || fail "the ${id%%:*} brief did not scaffold"
    assert_grep "CI slots check: just before you open a new pull request" "$home/data/gate-${id%%:*}/brief.md" "a ${id%%:*} brief lacks the CI slots check"
    assert_grep "gate . r" "$home/data/gate-${id%%:*}/brief.md" "the ${id%%:*} brief's gate command does not name the project"
    assert_grep "no PR (CI slots)" "$home/data/gate-${id%%:*}/brief.md" "the ${id%%:*} brief does not say how to park the branch"
  done
  for id in production-outage cve security lee-explicit restack red-gate-fix returned-pr-fix review; do
    brief "gate-x-$id" no-mistakes --pr-drain "$id" --linear PC-1 2>/dev/null || brief "gate-x-$id" no-mistakes --pr-drain "$id" || continue
    assert_no_grep "CI slots check" "$home/data/gate-x-$id/brief.md" "a $id brief, exempt from the CI slots, carries the CI slots check"
  done
  brief gate-local local-only || fail "the local-only brief did not scaffold"
  assert_no_grep "CI slots check" "$home/data/gate-local/brief.md" "a local-only brief carries the CI slots check"
  rm "$home/config/ci-slots"
  pass "a PR-opening brief carries the CI slots check only when its project declares slots, and the exempt classes and local-only briefs never do"
}

test_slots_classes_are_the_urgent_and_landing_ones() {
  local value
  for value in production-outage cve security lee-explicit restack red-gate-fix returned-pr-fix review; do
    "$DRAIN" slots-class "$value" || fail "$value was not accepted as exempt from the CI-slots cap"
  done
  for value in wolverine lee-research officer scheduled feature ""; do
    "$DRAIN" slots-class "$value" && fail "'$value' was accepted as exempt from the CI-slots cap"
  done
  pass "only the urgent classes, lee-explicit and the landing jobs are exempt from the CI-slots cap"
}

fm_test_run \
  test_twenty_open_turns_drain_on \
  test_drain_holds_from_nineteen_down_to_one \
  test_zero_open_turns_drain_off \
  test_a_zero_since_the_peak_keeps_drain_off \
  test_unreadable_or_undecided_history_is_unknown \
  test_closed_list_at_the_search_cap_is_unknown \
  test_non_github_origin_is_not_applicable \
  test_classes_are_validated \
  test_open_count_reads_one_repository \
  test_open_leaves_drafts_out_of_the_count_and_detail_lists_ready_urls \
  test_gate_holds_a_pr_opening_at_the_slots_and_at_the_cap \
  test_brief_carries_the_ci_slots_gate_only_when_slots_are_declared \
  test_slots_classes_are_the_urgent_and_landing_ones \
  test_lee_explicit_evidence_needs_a_quote_and_a_timestamp \
  test_security_needs_the_label_and_urgent_or_high_priority \
  test_security_reads_linear_graphql_without_echoing_the_credential \
  test_security_brief_needs_a_linear_item \
  test_brief_tells_workers_to_check_drain_before_a_pr
