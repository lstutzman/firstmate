#!/usr/bin/env bash
# Progress officer behavior through the registered officer's run interface.
set -u

# shellcheck source=tests/officer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/officer-helpers.sh"

OFFICER="$ROOT/bin/fm-officer.sh"
TMP_ROOT=$(fm_test_tmproot fm-officer-progress)
DATE=2026-10-25
NOW=1792994400
export TZ=UTC

make_world() {
  WORLD="$TMP_ROOT/$1"
  WORLD_HOME="$WORLD/home"
  officer_home "$WORLD_HOME"
  FAKEBIN=$(fm_fakebin "$WORLD")
  mkdir -p "$WORLD/linear"
  printf -- '- progress - Finds authorised work to start (role: progress; cadence: daily 07:00; team: PC; repos: example/project; requested: PC-10; model: none; added 2026-10-26)\n' > "$WORLD_HOME/data/officers.md"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$WORLD_HOME/data/backlog.md"
  printf '{"ok":true,"data":{"issues":[]}}\n' > "$WORLD/linear/list.json"
  printf '[]\n' > "$WORLD/prs.json"
  cat > "$FAKEBIN/linear-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PROGRESS_WORLD/calls"
case "$1 $2" in
  'issue list')
    python3 -I - "$PROGRESS_WORLD/linear" "$@" <<'PYLIST'
import json, pathlib, sys
root, args = pathlib.Path(sys.argv[1]), sys.argv[2:]
def opt(flag, default=None):
    return args[args.index(flag) + 1] if flag in args else default
cursor, state, unblocked = opt('--after', 'first'), opt('--state'), '--unblocked' in args
if (root / 'page-cap').exists():
    n = 0 if cursor == 'first' else int(cursor)
    issues = [] if unblocked or state != 'unstarted' else [
        {'identifier': 'PC-' + str(n + 100), 'title': 'Bug: paged item', 'state': 'Todo'}]
    print(json.dumps({'ok': True, 'data': {'issues': issues,
                                           'pagination': {'hasNextPage': bool(issues), 'endCursor': str(n + 1)}}}))
    sys.exit()
if (root / 'padding').exists() and not unblocked and state != 'unstarted':
    n = 0 if cursor == 'first' else int(cursor)
    more = n + 1 < int((root / 'padding').read_text())
    print(json.dumps({'ok': True, 'data': {'issues': [], 'pagination': {'hasNextPage': more, 'endCursor': str(n + 1)}}}))
    sys.exit()
page = root / ('page-%s.json' % cursor)
if state != 'unstarted' or not page.exists():
    page = root / ('unblocked.json' if unblocked and (root / 'unblocked.json').exists() else 'list.json')
try:
    doc = json.loads(page.read_text())
except ValueError:
    print(page.read_text())
    sys.exit()
if cursor == 'second' and state == 'unstarted' and (root / 'rate-left').exists():
    remaining = int((root / 'rate-left').read_text())
    if remaining:
        (root / 'rate-left').write_text(str(remaining - 1))
    else:
        doc = {'ok': True, 'data': {'issues': [], 'pagination': {'hasNextPage': False}}}
types = {'Done': 'completed', 'In Progress': 'started', 'Backlog': 'backlog'}
data = doc.get('data')
if isinstance(data, dict) and isinstance(data.get('issues'), list):
    data['issues'] = [i for i in data['issues'] if (i.get('stateType') or types.get(i.get('state'), 'unstarted')) == state]
    data.setdefault('pagination', {'hasNextPage': False})
print(json.dumps(doc))
PYLIST
    ;;
  'issue view')
    python3 -I - "$PROGRESS_WORLD/linear" "$3" <<'PYFIX'
import json, pathlib, sys
root, ident = pathlib.Path(sys.argv[1]), sys.argv[2]
path = root / (ident + '.json')
doc = json.loads(path.read_text()) if path.exists() else {'ok':True,'data':{'issue':{'identifier':ident,'title':'Requested root','state':'Done'}}}
children = []
for candidate in root.glob('PC-*.json'):
    entry = json.loads(candidate.read_text()).get('data', {}).get('issue', {})
    if (entry.get('parent') or '').split(' ')[0] == ident:
        children.append(entry)
if 'data' in doc:
    doc['data'].setdefault('subIssues', children)
print(json.dumps(doc))
PYFIX
    ;;
  *) exit 99 ;;
esac
SH
  cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PROGRESS_WORLD/calls"
[ "$1 $2" = 'api GET' ] || exit 99
case "$3" in
  */pulls/[0-9]*)
    number=${3##*/}
    [ "$4" = --jq ] || exit 99
    # Like gh-axi: a string result prints raw, an object prints as TOON key lines.
    jq -r "$5"' | if type == "string" then . else to_entries[] | "\(.key): \(.value)" end' \
      "$PROGRESS_WORLD/pr-$number.json" || exit 1
    exit ;;
esac
python3 -I - "$PROGRESS_WORLD/prs.json" <<'PY'
import json, sys
for pr in json.load(open(sys.argv[1])):
    print('PRJSON ' + json.dumps(pr))
PY
SH
  chmod +x "$FAKEBIN/linear-axi" "$FAKEBIN/gh-axi"
}

stub_sleep() {
  local real_python
  real_python=$(command -v python3)
  # Record backoff instead of waiting it out; other python3 uses pass through.
  cat > "$FAKEBIN/python3" <<SH
#!/usr/bin/env bash
case "\$2" in
  *fm-officer-progress.py) exec "$real_python" -I -c 'import os, runpy, sys, time
clock = [time.monotonic()]
time.monotonic = lambda: clock[0]
def wait(s):
    if s < 0.1: return
    clock[0] += s
    if s >= 1: open(os.environ["PROGRESS_WORLD"] + "/sleeps", "a").write("%g\n" % s)
time.sleep = wait
sys.argv = sys.argv[2:]
runpy.run_path(sys.argv[0], run_name="__main__")' "\$@" ;;
esac
exec "$real_python" "\$@"
SH
  chmod +x "$FAKEBIN/python3"
}

run_progress() {
  PROGRESS_WORLD="$WORLD" PATH="$FAKEBIN:$PATH" FM_HOME="$WORLD_HOME" FM_OFFICER_NOW="$NOW" \
    bash "$OFFICER" run progress --date "$DATE"
}

linear_item() {  # <id> <title>
  python3 -I - "$WORLD" "$1" "$2" <<'PY'
import json, sys
root, ident, title = sys.argv[1:]
issue = {'identifier':ident,'title':title,'state':'Todo','stateType':'unstarted','priority':0}
json.dump({'ok':True,'data':{'issues':[issue]}},open(root+'/linear/list.json','w'))
json.dump({'ok':True,'data':{'issue':dict(issue,parent=None,description='')}},open(root+'/linear/'+ident+'.json','w'))
PY
}

test_partial_coverage_starts() {
  make_world partial-starts
  stub_sleep
  python3 -I - "$WORLD/linear" <<'PYFIX'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = [
    ('PC-61', '[scheduled-review] Check boundaries', None, ''),
    ('PC-62', 'Bug: business health crashes', None, ''),
    ('PC-63', 'Bug: hidden hold', None, '(hold: Lee decides)'),
    ('PC-64', 'Bug: unreadable parent', 'PC-65', ''),
    ('PC-66', 'Bug: approve pricing', None, 'Ask Lee: approve pricing'),
    ('PC-67', 'Bug: merge a fix', None, 'Decision for Lee: merge the fix'),
    ('PC-68', 'Bug: business health pricing decision', None, ''),
    ('PC-69', 'Bug: productize results', None, ''),
]
listed = []
for ident, title, parent, description in spec:
    issue = dict(identifier=ident, title=title, state='Todo', stateType='unstarted')
    listed.append(issue)
    (root / (ident + '.json')).write_text(json.dumps(dict(ok=True, data=dict(
        issue=dict(issue, parent=parent, description=description)))))
(root / 'list.json').write_text(json.dumps(dict(ok=True, data=dict(issues=listed))))
(root / 'PC-65.json').write_text(json.dumps(dict(ok=False, error=dict(code='NOT_FOUND'))))
# A separate requested tree fails, without invalidating checked candidates.
(root / 'PC-10.json').write_text(json.dumps(dict(ok=False, error=dict(code='NOT_FOUND'))))
PYFIX
  run_progress > "$WORLD/output" || fail 'partial coverage run failed'
  local lane="$WORLD_HOME/data/officers/progress" file="$WORLD_HOME/data/officers/progress/$DATE.json"
  assert_equals 'PC-61 PC-62 PC-68 PC-69' "$(jq -r '[.start_requests[].id] | join(" ")' "$file")" \
    'checked review and technical bugs start despite unrelated discovery gaps'
  assert_equals 'code-review linear-title-prefix:scheduled-review' \
    "$(jq -r '.start_requests[0] | .authorising_class + " " + .tag_source' "$file")" 'scheduled review prefix authorises review work'
  assert_equals 'PC-63 PC-64' "$(jq -r '[.excluded[].id] | sort | join(" ")' "$file")" \
    'held and unreadable-parent items never start'
  assert_equals 'PC-66 PC-67' "$(jq -r '[.asks_for_lee[].id] | sort | join(" ")' "$file")" \
    'choice words outside known names and restricted work ask for cards'
  assert_contains "$(jq -r '.asking[].question' "$lane/progress-state.json")" \
    "Needs a Captain's Log card: Bug: merge a fix; Outside automatic-start authority: merge" 'restricted work needs a card'
  assert_contains "$(jq -r '.coverage[]' "$file")" 'start check PC-64: NOT_FOUND' 'unreadable candidate is named'
  assert_contains "$(jq -r '.coverage[]' "$file")" 'Linear labels not readable by linear-axi' 'missing label support is explicit'
  assert_contains "$(jq -r '.asking[].question' "$lane/progress-state.json")" "Needs a Captain's Log card:" 'choices name the needed card'
  assert_equals 'null' "$(jq -r '.filler' "$file")" 'partial coverage never proves idleness'
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/gh-axi"
  run_progress >/dev/null || fail 'PR discovery failure must still publish state'
  assert_equals '0' "$(jq '.start_requests | length' "$file")" 'failed PR discovery starts nothing'
  assert_contains "$(jq -r '.excluded[].id' "$file")" 'PC-61' 'checked work waits for PR evidence'
  assert_contains "$(jq -r '.coverage[]' "$file")" \
    'Starts held: duplicate-start check unavailable: open PR discovery unavailable or incomplete' 'the held reason is named'
  assert_equals '1' "$(jq '[.coverage[] | select(contains("open PR discovery"))] | length' "$file")" 'the held reason is named once'
  [ ! -s "$lane/$DATE.start-requests.sh" ] || ! grep -q 'PC-61' "$lane/$DATE.start-requests.sh" \
    || fail 'failed PR discovery must not hand off a start'
  pass 'progress: checked items start with partial coverage and choices ask for cards'
}

test_review_words_and_explicit_asks() {
  make_world review-words
  stub_sleep
  python3 -I - "$WORLD/linear" <<'PYFIX'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = [
    ('PC-2857', 'Code review finding: delete bypasses validation', 'Outside automatic-start authority: delete'),
    ('PC-3763', '[scheduled-review] Legal billing error handling', 'Lee decides the legal choice'),
    ('PC-3764', 'Bug: billing export fails', 'Ask Lee: approve pricing before work starts'),
    ('PC-3765', 'Bug: credential parser fails', 'Needs Lee to rotate production credentials'),
    ('PC-3766', 'Bug: delete action skips validation', 'Billing code drops the wrong row'),
    ('PC-3767', '[scheduled-review] Merge-word classifier drops findings', 'Related closed PR: https://github.com/example/project/pull/4069'),
    ('PC-3768', 'Security: leaked production credential must be rotated', ''),
    ('PC-3769', 'Bug: stale cache', 'Decision: keep the old API, fix in follow-up'),
    ('PC-3770', 'Bug: slow report', 'Decision-making notes: Lee chose option A on 20 Oct'),
]
issues = []
for ident, title, description in spec:
    issue = dict(identifier=ident, title=title, state='Todo', stateType='unstarted', description=description)
    if ident == 'PC-3767': issue['url'] = 'https://github.com/example/project/pull/4069'
    issues.append(dict(issue, description=''))
    (root / (ident + '.json')).write_text(json.dumps(dict(ok=True, data=dict(issue=issue))))
(root / 'list.json').write_text(json.dumps(dict(ok=True, data=dict(issues=issues))))
PYFIX
  printf '{"state":"closed","merged":true}\n' > "$WORLD/pr-4069.json"
  run_progress > "$WORLD/output" || fail 'review word classification failed'
  local file="$WORLD_HOME/data/officers/progress/$DATE.json"
  assert_equals 'PC-2857 PC-3763 PC-3766 PC-3767 PC-3769 PC-3770' "$(jq -r '[.start_requests[].id] | join(" ")' "$file")" \
    'review findings start when sensitive words describe code, old classifier reasons, or recorded decisions'
  assert_equals 'PC-3764 PC-3765 PC-3768' "$(jq -r '[.asks_for_lee[].id] | sort | join(" ")' "$file")" \
    'explicit Lee asks and restricted security titles retain approval boundaries'
  assert_equals 'Outside automatic-start authority: production' \
    "$(jq -r '.asks_for_lee[] | select(.id == "PC-3768") | .reason' "$file")" 'security titles keep the restricted-word gate'
  assert_contains "$(cat "$WORLD/calls")" 'issue view PC-3764 --full' 'full candidate reads check explicit asks'
  pass 'progress: review findings start and explicit Lee asks remain asks'
}

test_merge_ask_pr_state() {
  make_world merge-state
  stub_sleep
  python3 -I - "$WORLD/linear" <<'PYFIX'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
issues = [dict(identifier='PC-4069', title='Bug: payment retry fails', description=''),
          dict(identifier='PC-4200', title='Pricing fix', description='Merge word needed: https://github.com/example/project/pull/4200')]
for issue in issues:
    issue.update(state='Todo', stateType='unstarted', priority=0)
    (root / (issue['identifier'] + '.json')).write_text(json.dumps(dict(ok=True, data=dict(issue=dict(issue, parent=None)))))
(root / 'list.json').write_text(json.dumps(dict(ok=True, data=dict(issues=issues))))
PYFIX
  cat > "$WORLD_HOME/data/backlog.md" <<'MD'
## Queued

- [ ] merged - Merge payments fix (kind: captain) (hold: merge word) (hold-kind: captain) (pr: https://github.com/example/project/pull/4069) (linear: PC-4069)
- [ ] closed - Merge legal fix (kind: captain) (hold: merge word) (hold-kind: captain) (pr: https://github.com/example/project/pull/4078)
- [ ] open - Ask Lee: Merge payments fix (kind: bug) (pr: https://github.com/example/project/pull/4095)
- [ ] unread - Merge billing fix (kind: captain) (hold: merge word) (hold-kind: captain) (pr: https://github.com/example/project/pull/4112)
- [ ] linked - Merge pricing fix (kind: captain) (hold: merge word) (hold-kind: captain) (linear: PC-4200)
MD
  printf '{"state":"closed","merged":true}\n' > "$WORLD/pr-4069.json"
  printf '{"state":"closed","merged":true}\n' > "$WORLD/pr-4200.json"
  printf '{"state":"closed","merged":false}\n' > "$WORLD/pr-4078.json"
  printf '{"state":"open","merged":false}\n' > "$WORLD/pr-4095.json"
  run_progress > "$WORLD/output" || fail 'merge ask reconciliation failed'
  local file="$WORLD_HOME/data/officers/progress/$DATE.json"
  assert_equals 'closed open unread' "$(jq -r '[.asks_for_lee[].id, .excluded[].id] | sort | join(" ")' "$file")" \
    'merged PR merge asks disappear, including PRs named only in linked Linear text, while other asks remain'
  assert_equals 'PR closed unmerged: check whether still needed' \
    "$(jq -r '[.asks_for_lee[], .excluded[]] | .[] | select(.id == "closed") | .reason' "$file")" 'closed unmerged PR asks are relabelled'
  assert_contains "$(jq -r '.coverage[]' "$file")" 'pull/4112' 'failed PR state read is named in coverage'
  assert_equals '0' "$(jq '.start_requests | length' "$file")" 'a closed merge ask never resurfaces as unchecked linked work'
  assert_not_contains "$(jq -r '.asking[].key' "$WORLD_HOME/data/officers/progress/progress-state.json")" 'merged' 'merged PR card is absent from page'
  assert_contains "$(cat "$WORLD/calls")" '/repos/example/project/pulls/4069' 'merge ask reads exact PR state'
  pass 'progress: merge asks require a current open PR'
}

test_github_reads_respect_deadline() {
  make_world github-deadline
  stub_sleep
  cat > "$WORLD_HOME/data/backlog.md" <<'MD'
## Queued

- [ ] merged - Merge payments fix (kind: captain) (hold: merge word) (hold-kind: captain) (pr: https://github.com/example/project/pull/4069)
MD
  printf '{"state":"closed","merged":true}\n' > "$WORLD/pr-4069.json"
  FM_OFFICER_RUN_TIMEOUT=30 run_progress > "$WORLD/output" || fail 'deadline-bounded GitHub reads failed'
  local file="$WORLD_HOME/data/officers/progress/$DATE.json"
  assert_contains "$(jq -r '.coverage[]' "$file")" 'pull/4069 (run deadline reached)' 'skipped PR state read is a named gap'
  assert_contains "$(jq -r '.coverage[]' "$file")" 'open PR discovery unavailable' 'skipped open PR listing is a named gap'
  assert_not_contains "$(cat "$WORLD/calls" 2>/dev/null)" 'pulls' 'no GitHub read starts after the run deadline'
  assert_equals 'merged' "$(jq -r '.excluded[].id' "$file")" 'an unchecked merge ask stays listed'
  pass 'progress: GitHub reads stop at the run deadline and publish the gap'
}

test_ancestor_asks_hold_only_routed_asks() {
  make_world ancestor-asks
  python3 -I - "$WORLD/linear" <<'PYFIX'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = [('PC-10', 'Requested fleet tooling', 'started', None),
        ('PC-24', 'Billing settings redesign', 'started', 'PC-10'),
        ('PC-25', 'Add settings form', 'unstarted', 'PC-24'),
        ('PC-26', 'Bug: billing rounding', 'unstarted', None),
        ('PC-27', 'Bug: rounding test missing', 'unstarted', 'PC-26'),
        ('PC-28', 'Choose pricing tier', 'unstarted', 'PC-10'),
        ('PC-29', 'Implement tier screen', 'unstarted', 'PC-28')]
issues = []
for ident, title, state, parent in spec:
    issue = dict(identifier=ident, title=title, state='Todo', stateType=state, priority=0)
    issues.append(issue)
    (root / (ident + '.json')).write_text(json.dumps(dict(ok=True, data=dict(
        issue=dict(issue, parent=parent + ' Parent' if parent else None, description='')))))
(root / 'list.json').write_text(json.dumps(dict(ok=True, data=dict(issues=issues))))
PYFIX
  cat > "$WORLD_HOME/data/backlog.md" <<'MD'
## Queued

- [ ] rounding-test - Rounding test missing (kind: bug) (linear: PC-27)
- [ ] rounding - Fix billing rounding (linear: PC-26)
MD
  run_progress > "$WORLD/output" || fail 'ancestor ask run failed'
  local file="$WORLD_HOME/data/officers/progress/$DATE.json"
  assert_equals 'PC-25 PC-26 PC-27' "$(jq -r '[.start_requests[].linear_id] | sort | join(" ")' "$file")" \
    'children of in-flight or startable ancestors start'
  assert_equals 'PC-28' "$(jq -r '[.asks_for_lee[].linear_id] | join(" ")' "$file")" 'an unstarted pricing choice asks Lee'
  assert_equals 'PC-29' "$(jq -r '[.excluded[].linear_id] | join(" ")' "$file")" 'only a child of a listed ask waits'
  pass 'progress: descendants wait only for ancestors listed as Lee asks'
}

test_linear_rate_limit_recovers() {
  make_world rate-recovery
  stub_sleep
  printf '{"ok":true,"data":{"issues":[],"pagination":{"hasNextPage":true,"endCursor":"second"}}}\n' > "$WORLD/linear/page-first.json"
  printf '{"ok":false,"error":{"code":"RATE_LIMITED"}}\n' > "$WORLD/linear/page-second.json"
  printf '3\n' > "$WORLD/linear/rate-left"
  run_progress > "$WORLD/output" || fail 'rate-limited page recovery failed'
  local file="$WORLD_HOME/data/officers/progress/$DATE.json"
  assert_equals '3' "$(jq '.linear_coverage.rate_limit_retries' "$file")" 'run-wide backoff survives more than two rate limits'
  assert_equals '8' "$(jq '.linear_coverage.pages_fetched' "$file")" 'team and unblocked discovery finish after recovery'
  assert_not_contains "$(jq -r '.coverage[]' "$file")" 'RATE_LIMITED' 'successful retry completes discovery'
  assert_contains "$(cat "$WORLD/sleeps")" '120' 'repeated rate limits increase backoff'
  assert_contains "$(cat "$WORLD/sleeps")" '12' 'remaining requests retain slower pacing'
  make_world rate-deadline
  stub_sleep
  printf '{"ok":false,"error":{"code":"RATE_LIMITED"}}\n' > "$WORLD/linear/list.json"
  FM_OFFICER_RUN_TIMEOUT=70 run_progress > "$WORLD/output" || fail 'rate-limit deadline reporting failed'
  file="$WORLD_HOME/data/officers/progress/$DATE.json"
  assert_contains "$(jq -r '.coverage[]' "$file")" 'run deadline reached before rate-limit retry' 'rate-limit waits preserve the run deadline'
  assert_equals '1' "$(jq '.linear_coverage.rate_limit_retries' "$file")" 'no retry exceeds the remaining run time'
  assert_equals '30' "$(paste -sd' ' "$WORLD/sleeps")" 'deadline stops backoff before another long wait'
  pass 'progress: rate-limited pages recover within the run budget'
}

test_linear_pagination() {
  make_world pagination
  printf '{"ok":true,"data":{"issues":[{"identifier":"PC-1","title":"Bug: first","state":"Todo"}],"pagination":{"hasNextPage":true,"endCursor":"second"}}}\n' > "$WORLD/linear/page-first.json"
  printf '{"ok":true,"data":{"issues":[{"identifier":"PC-2","title":"Bug: second","state":"Todo"},{"identifier":"PC-3","title":"Tidy docs","state":"Todo"}],"pagination":{"hasNextPage":false,"endCursor":"last"}}}\n' > "$WORLD/linear/page-second.json"
  printf '{"ok":true,"data":{"issue":{"identifier":"PC-10","title":"Root","state":"Done"},"subIssues":[]}}\n' > "$WORLD/linear/PC-10.json"
  printf '{"ok":true,"data":{"issue":{"identifier":"PC-1","title":"Bug: first","state":"Todo","parent":null}}}\n' > "$WORLD/linear/PC-1.json"
  printf '{"ok":true,"data":{"issue":{"identifier":"PC-2","title":"Bug: second","state":"Todo","parent":null}}}\n' > "$WORLD/linear/PC-2.json"
  run_progress > "$WORLD/output" || fail 'paged discovery failed'
  local file="$WORLD_HOME/data/officers/progress/$DATE.json"
  assert_equals 'PC-1 PC-2' "$(jq -r '[.start_requests[].id] | join(" ")' "$file")" 'all team pages are classified'
  assert_equals '8 6' "$(jq -r '.linear_coverage | "\(.pages_fetched) \(.items_seen)"' "$file")" 'every state pass counts pages and items'
  assert_contains "$(cat "$WORLD/calls")" '--state started' 'the team listing reads open states'
  assert_not_contains "$(cat "$WORLD/calls")" '--state completed' 'completed issues are never listed'
  assert_not_contains "$(cat "$WORLD/calls")" '--state canceled' 'canceled issues are never listed'
  assert_not_contains "$(grep -e '--unblocked' "$WORLD/calls")" '--state started' 'the unblocked listing reads only unstarted states'
  assert_contains "$(cat "$WORLD/calls")" 'issue view PC-1 --full' 'start candidates are read in full'
  assert_not_contains "$(cat "$WORLD/calls")" 'issue view PC-3' 'ordinary list items never cause view calls'
  assert_contains "$(cat "$WORLD_HOME/data/officers/progress/$DATE.md")" '8 pages' 'digest reports coverage counts'
  assert_contains "$(cat "$WORLD/output")" '8 pages' 'run log reports coverage counts'
  pass 'progress: paginates open-state listings and reads only start candidates'
}

test_linear_rate_limit() {
  make_world rate-limit
  printf '{"ok":true,"data":{"issues":[{"identifier":"PC-1","title":"Bug: first","state":"Todo"}],"pagination":{"hasNextPage":true,"endCursor":"second"}}}\n' > "$WORLD/linear/page-first.json"
  printf '{"ok":false,"error":{"code":"UNKNOWN","message":"rate limit exceeded; never echo external secrets"}}\n' > "$WORLD/linear/page-second.json"
  stub_sleep
  run_progress > "$WORLD/output" || fail 'rate limit must publish available evidence'
  local file="$WORLD_HOME/data/officers/progress/$DATE.json"
  assert_contains "$(jq -r '.coverage[]' "$file")" 'RATE_LIMITED' 'coverage names the actual failure'
  assert_equals '30 60 120' "$(paste -sd' ' "$WORLD/sleeps")" 'a limit that outlasts the short backoff is not waited on further'
  assert_contains "$(cat "$WORLD/output")" 'Linear quota exhausted, discovery resumes after' 'run log transport includes the cause'
  assert_contains "$(cat "$WORLD_HOME/data/officers/progress/$DATE.md")" 'RATE_LIMITED' 'digest includes cause'
  assert_not_contains "$(cat "$WORLD/output")" 'never echo' 'external messages stay private'
  assert_equals '3' "$(jq '.linear_coverage.rate_limit_retries' "$file")" 'an exhausted quota stops further Linear requests'
  assert_equals '0' "$(jq '.start_requests | length' "$file")" 'incomplete discovery suppresses automatic starts'
  assert_contains "$(jq -r '.excluded[].id' "$file")" 'PC-1' 'successfully fetched items are still classified'
  # The quota is hourly: resume one hour after the limit, never inside this run.
  local resume lane="$WORLD_HOME/data/officers/progress"
  resume=$(jq '.resume_after' "$lane/linear-resume-after.json")
  [ "$resume" -ge $((NOW + 3600 + 210)) ] && [ "$resume" -le $((NOW + 3600 + 300)) ] \
    || fail "resume time is one hour after the exhausting limit (got $resume)"
  assert_contains "$(jq -r '.coverage[]' "$file")" "$(date -u -d "@$resume" +%Y-%m-%dT%H:%M:%SZ)" 'coverage names the resume time'
  : > "$WORLD/calls"
  NOW=$((NOW + 1800)) run_progress > "$WORLD/output" || fail 'run inside the quota window failed'
  assert_not_contains "$(cat "$WORLD/calls")" 'issue list' 'runs before the resume time skip Linear discovery'
  assert_contains "$(jq -r '.coverage[]' "$file")" 'Linear quota exhausted earlier; discovery skipped until' 'the skipped discovery is a named gap'
  printf '{"ok":true,"data":{"issues":[],"pagination":{"hasNextPage":false}}}\n' > "$WORLD/linear/page-second.json"
  : > "$WORLD/calls"
  NOW=$((resume + 1)) run_progress > "$WORLD/output" || fail 'run after the quota window failed'
  assert_contains "$(cat "$WORLD/calls")" 'issue list' 'discovery resumes after the resume time'
  assert_not_contains "$(jq -r '.coverage[]' "$file")" 'RATE_LIMITED' 'resumed discovery completes'
  assert_not_contains "$(jq -r '.coverage[]' "$file")" 'quota exhausted' 'no quota gap once the window has passed'
  pass 'progress: an exhausted Linear quota defers discovery to a later run'
}

test_linear_page_cap() {
  make_world page-cap
  touch "$WORLD/linear/page-cap"
  run_progress > "$WORLD/output" || fail 'page cap must publish coverage'
  local file="$WORLD_HOME/data/officers/progress/$DATE.json"
  assert_contains "$(jq -r '.coverage[]' "$file")" 'page cap reached (100 pages)' 'cap has a specific cause'
  assert_equals '105 100' "$(jq -r '.linear_coverage | "\(.pages_fetched) \(.team_items)"' "$file")" 'page cap retains exact progress'
  assert_equals '0' "$(jq '.start_requests | length' "$file")" 'capped reads suppress automatic starts'
  assert_contains "$(cat "$WORLD/output")" 'page cap reached' 'cap reaches run log transport'
  assert_not_contains "$(cat "$WORLD/calls")" 'issue view' 'an incomplete team listing skips requested-tree reads'
  pass 'progress: page cap names the bound and preserves progress'
}

test_linear_child_cap() {
  make_world child-cap
  python3 -I - "$WORLD/linear/PC-10.json" <<'PYCHILD'
import json,sys
json.dump({'ok':True,'data':{'issue':{'identifier':'PC-10','title':'Root','state':'Todo'},
 'subIssues':[{'identifier':'PC-'+str(n)} for n in range(50)]}},open(sys.argv[1],'w'))
PYCHILD
  sed -i 's/requested: PC-10;/requested: PC-10,PC-11;/' "$WORLD_HOME/data/officers.md"
  run_progress > "$WORLD/output" || fail 'child cap must publish coverage'
  local file="$WORLD_HOME/data/officers/progress/$DATE.json"
  assert_contains "$(jq -r '.coverage[]' "$file")" 'sub-issues page cap reached' 'unpageable child connection never claims complete coverage'
  assert_contains "$(jq -r '.coverage[]' "$file")" 'requested roots not read: PC-11' 'roots skipped after a tree failure are named'
  python3 -I - "$WORLD/linear" <<'PYDESC'
import json,os,sys
root=sys.argv[1]
json.dump({'ok':True,'data':{'issue':{'identifier':'PC-10','title':'Root','state':'Todo'},
 'subIssues':[{'identifier':'PC-55'},{'identifier':'PC-56'}]}},open(os.path.join(root,'PC-10.json'),'w'))
json.dump({'ok':False,'error':{'code':'NOT_FOUND'}},open(os.path.join(root,'PC-55.json'),'w'))
PYDESC
  run_progress > "$WORLD/output" || fail 'descendant failure must publish coverage'
  assert_contains "$(jq -r '.coverage[]' "$file")" 'requested-tree descendant PC-55: NOT_FOUND (exit 0); 1 queued hierarchy reads skipped' \
    'a failed descendant read is named as a descendant with the unread queue'
  assert_equals '0' "$(jq '.start_requests | length' "$file")" 'incomplete hierarchy suppresses starts'
  pass 'progress: hidden CLI child limit is an explicit coverage gap'
}

test_start_candidate_checks() {
  make_world start-checks
  python3 -I - "$WORLD" <<'PY'
import json, os, sys
root = sys.argv[1]
cut = '\n... (truncated, 400 chars total - use --full to see complete body)'
spec = [('PC-30', 'Parent epic', None, '', ''),
        ('PC-31', 'Bug: child of a blocked parent', 'PC-30', '', ''),
        ('PC-32', 'Bug: held in the full text', None, 'Details' + cut, 'Details (hold: Lee decides)'),
        ('PC-33', 'Tidy docs', None, 'Notes' + cut, 'Notes'),
        ('PC-34', 'Bug: ready', None, '', '')]
listed = []
for ident, title, parent, short, full in spec:
    doc = {'identifier':ident, 'title':title, 'state':'Todo', 'stateType':'unstarted', 'priority':0}
    listed.append(dict(doc, description=short))
    json.dump({'ok':True,'data':{'issue':dict(doc, parent=parent and parent + ' Parent title', description=full)}},
              open(os.path.join(root,'linear',ident+'.json'),'w'))
json.dump({'ok':True,'data':{'issues':listed}}, open(os.path.join(root,'linear','list.json'),'w'))
json.dump({'ok':True,'data':{'issues':listed[1:]}}, open(os.path.join(root,'linear','unblocked.json'),'w'))
PY
  local file="$WORLD_HOME/data/officers/progress/$DATE.json"
  run_progress >/dev/null || fail 'start check run failed'
  assert_equals 'PC-34' "$(jq -r '[.start_requests[].id] | join(" ")' "$file")" 'only fully checked candidates start'
  assert_equals 'PC-31 PC-32' "$(jq -r '[.excluded[].id] | sort | join(" ")' "$file")" \
    'a blocked parent and a hold after the listing cut both stop a start'
  assert_contains "$(cat "$WORLD/calls")" 'issue view PC-30 --full' 'a candidate parent chain is read'
  assert_not_contains "$(cat "$WORLD/calls")" 'issue view PC-33' 'non-candidates are never read'
  assert_equals '1' "$(jq '.linear_coverage.descriptions_truncated' "$file")" 'unread cut descriptions are counted'
  printf '{"ok":false,"error":{"code":"NOT_FOUND"}}\n' > "$WORLD/linear/PC-34.json"
  run_progress >/dev/null || fail 'failed start check must publish coverage'
  assert_contains "$(jq -r '.coverage[]' "$file")" 'start check PC-34: NOT_FOUND' 'a failed candidate read names its cause'
  assert_equals '0' "$(jq '.start_requests | length' "$file")" 'a candidate whose read failed is not started'
  pass 'progress: start candidates are read in full with their parent chains'
}

test_start_check_budget() {
  make_world start-budget
  stub_sleep
  python3 -I - "$WORLD" <<'PY'
import json, os, sys
root = sys.argv[1]
spec = [('PC-41', 'Bug: lowest ranked', 2), ('PC-42', 'Bug: second', 1), ('PC-43', 'Security: highest ranked', 3)]
listed = []
for ident, title, priority in spec:
    doc = {'identifier':ident, 'title':title, 'state':'Todo', 'stateType':'unstarted', 'priority':priority}
    listed.append(doc)
    json.dump({'ok':True,'data':{'issue':dict(doc, parent=None, description='')}},
              open(os.path.join(root,'linear',ident+'.json'),'w'))
json.dump({'ok':True,'data':{'issues':listed}}, open(os.path.join(root,'linear','list.json'),'w'))
PY
  # 3 padded team states x 98 pages + 1 unstarted page + 2 unblocked pages + 1 requested root = 298 of 300 requests.
  printf '98\n' > "$WORLD/linear/padding"
  local file="$WORLD_HOME/data/officers/progress/$DATE.json"
  run_progress > "$WORLD/output" || fail 'budget-limited start checks must publish state'
  assert_equals 'PC-43 PC-42' "$(jq -r '[.start_requests[].id] | join(" ")' "$file")" \
    'the two highest-ranked checked candidates still start'
  assert_equals 'PC-41' "$(jq -r '[.excluded[].id] | join(" ")' "$file")" 'the lowest-ranked candidate is left unchecked'
  assert_contains "$(jq -r '.coverage[]' "$file")" 'start check PC-41: request budget reached' 'the gap names the candidate and cause'
  assert_equals '1 300' "$(jq -r '.linear_coverage | "\(.unverified_starts) \(.requests)"' "$file")" \
    'unverified candidates are counted within the request budget'
  assert_contains "$(cat "$WORLD/output")" 'Coverage gap: Linear discovery: start check PC-41' 'the run log names the gap'
  pass 'progress: start checks run in rank order and an over-budget candidate alone is withheld'
}

test_backlog_discovery() {
  make_world backlog
  linear_item PC-1 'Bug: reported crash'
  cat > "$WORLD_HOME/data/backlog.md" <<'MD'
## In flight

- [ ] busy - Fix a bug already moving (repo: project) (kind: bug)

## Queued

- [ ] bug-one - Fix a reported crash (repo: project) (kind: bug) (linear: PC-1)
- [ ] cve-fix - Fix CVE-2026-12345 (repo: project) (kind: cve)
- [ ] feature-one - Add the requested export (repo: project) (kind: feature) (requested-by: Lee) (reference: CVE-2026-12345)
- [ ] unasked - Add an unrequested feature (repo: project) (kind: feature)

## Done

- [x] finished - Fix the old crash (repo: project) (kind: bug)
MD
  local out file
  out=$(run_progress) || fail "progress officer run failed: $out"
  file="$WORLD_HOME/data/officers/progress/$DATE.json"
  assert_equals 'cve-fix bug-one feature-one' "$(jq -r '[.start_requests[].id] | join(" ")' "$file")" \
    'only authorised unstarted backlog work is requested, CVE first'
  assert_equals 'null' "$(jq -r '.start_requests[0].linear_id' "$file")" 'a CVE identifier is not a Linear id'
  assert_equals 'PC-1' "$(jq -r '.start_requests[1].linear_id' "$file")" 'Linear evidence is retained'
  assert_equals "$WORLD_HOME" "$(jq -r '.start_requests[1].owner_home' "$file")" 'owning home is named'
  assert_equals 'bug' "$(jq -r '.start_requests[1].authorising_class' "$file")" 'authority is explicit'
  assert_equals '1' "$(jq '.unclassified' "$file")" 'an unrequested feature is counted, not asked'
  assert_equals '0' "$(jq '.asks_for_lee | length' "$file")" 'missing authority alone is not a Lee ask'
  assert_equals 'busy' "$(jq -r '.doing[0].id' "$file")" 'moving work appears in doing'
  assert_equals 'finished' "$(jq -r '.done[0].id' "$file")" 'finished work appears in done'
  assert_contains "$out" "DIGEST $DATE" 'the existing digest protocol is retained'
  assert_not_contains "$(cat "$WORLD/calls")" 'issue view CVE-' 'non-team references never become hierarchy roots'
  pass 'progress: discovers and separates backlog work'
}

test_linear_trees_and_exclusions() {
  make_world linear
  python3 -I - "$WORLD" <<'PY'
import json, os, sys
root = sys.argv[1]
spec = [
 ('PC-10', 'Requested fleet tooling', 'In Progress', None, 3),
 ('PC-11', 'Intermediate work', 'Done', 'PC-10', 3),
 ('PC-12', 'Implement a leaf', 'Todo', 'PC-11', 3),
 ('PC-13', 'Choose pricing for the leaf', 'Todo', 'PC-12', 1),
 ('PC-14', 'Fix CVE-2026-12345', 'Backlog', None, 1),
 ('PC-15', 'Bug: crash on save', 'Todo', None, 2),
 ('PC-16', 'Code review finding: missing bounds check', 'Todo', None, 1),
 ('PC-17', 'Bug: already has a PR', 'Todo', None, 1),
 ('PC-18', 'Bug: carded elsewhere', 'Todo', None, 1),
 ('PC-19', 'Security: token exposure', 'Todo', None, 2),
 ('PC-20', 'Bug: blocked by another issue', 'Todo', None, 1),
 ('PC-21', 'Implement pricing child', 'Todo', 'PC-13', 1),
 ('PC-22', 'Old finished work', 'Done', None, 1),
 ('PC-23', 'Implement the leaf screen', 'Todo', 'PC-13', 1),
]
listed = []
for ident, title, state, parent, priority in spec:
    doc = {'identifier':ident, 'title':title, 'state':state, 'priority':priority,
           'stateType': 'started' if state == 'In Progress' else 'completed' if state == 'Done' else 'unstarted'}
    listed.append(doc)
    json.dump({'ok':True,'data':{'issue':dict(doc, parent=parent + ' Parent title' if parent else None,
                                              description='')}},
              open(os.path.join(root,'linear',ident+'.json'),'w'))
json.dump({'ok':True,'data':{'issues':listed}}, open(os.path.join(root,'linear','list.json'),'w'))
json.dump([{'number':17,'title':'PC-17 fix crash','body':'Linear: PC-17',
            'html_url':'https://github.com/example/project/pull/17','head':{'ref':'fix-crash'}}],
          open(os.path.join(root,'prs.json'),'w'))
PY
  cat > "$WORLD_HOME/data/backlog.md" <<'MD'
## Queued

- [ ] carded - Bug: carded elsewhere (kind: bug) (linear: PC-18) (hold: Lee decides) (hold-kind: captain)
- [ ] blocked-bug - Bug: blocked by another issue (kind: bug) (linear: PC-20) (blocked-by: dependency)
- [ ] wording - Ask Lee: Choose revised wording (kind: bug)
- [ ] legal - Change legal text (kind: security)
- [ ] payments - Change payments behavior (kind: bug)
- [ ] business - Make a business decision (kind: fleet) (requested-by: Lee)
- [ ] product - Make a product decision (kind: feature) (requested-by: Lee)
- [ ] open-branch - Fix a crash with an existing PR (kind: bug)
MD
  python3 -I - "$WORLD/prs.json" <<'PY'
import json,sys
path=sys.argv[1]
prs=json.load(open(path))
prs.append({'title':'Fix a crash','body':'','head':{'ref':'fm/open-branch'}})
json.dump(prs,open(path,'w'))
PY
  local file="$WORLD_HOME/data/officers/progress/$DATE.json"
  run_progress >/dev/null || fail 'linear discovery failed'
  assert_equals 'PC-14 PC-19 PC-16 PC-15  PC-12' \
    "$(jq -r '[.start_requests[].linear_id] | join(" ")' "$file")" \
    'security then review/bugs by severity then deeply nested requested work'
  assert_equals 'linear-title-prefix:CVE linear-title-prefix:Security linear-title-prefix:Code review linear-title-prefix:Bug backlog requested-root:PC-10' \
    "$(jq -r '[.start_requests[].tag_source] | join(" ")' "$file")" 'each start names the source of its authority'
  assert_equals '0' "$(jq '.unclassified' "$file")" 'every open item in the tree is classified'
  assert_equals 'PC-10' "$(jq -r '[.doing[].id] | join(" ")' "$file")" 'the requested root in progress is doing'
  assert_equals 'requested-feature' \
    "$(jq -r '.start_requests[] | select(.linear_id == "PC-12") | .authorising_class' "$file")" \
    'a leaf inherits the recorded root request across completed parents'
  assert_equals 'PC-13 PC-21 business legal product wording' \
    "$(jq -r '[.asks_for_lee[].id] | sort | join(" ")' "$file")" 'choices need Lee, including descendants'
  assert_equals 'PC-17 PC-23 blocked-bug carded open-branch' \
    "$(jq -r '[.excluded[].id] | sort | join(" ")' "$file")" 'PRs, blocks, and existing cards exclude starts'
  assert_contains "$(jq -r '.excluded[] | select(.id == "PC-23") | .reason' "$file")" 'PC-13' \
    "a descendant waits for its ancestor's open Lee ask"
  assert_equals 'null' "$(jq -r '.filler' "$file")" 'no filler while authorised work is ready'
  assert_not_contains "$(cat "$WORLD/calls")" 'issue view PC-22' 'finished issues outside a tree are never read one by one'
  assert_contains "$(cat "$WORLD/calls")" 'issue view PC-11' 'finished ancestors are still read for lineage'
  assert_equals '' "$(jq -r '.done[].id' "$file")" 'Linear history does not fill done'
  assert_contains "$(cat "$WORLD_HOME/data/officers/progress/$DATE.md")" 'PC-12' 'ranked digest includes leaf'
  pass 'progress: discovers deep Linear children, ranks work, and keeps choices for Lee'
}

test_filler_and_failure_coverage() {
  make_world filler
  local file="$WORLD_HOME/data/officers/progress/$DATE.json" out
  out=$(run_progress) || fail 'empty run failed'
  assert_equals 'null' "$(jq -r '.filler' "$file")" 'unreadable labels cannot prove an idle fleet'
  assert_contains "$out" "DIGEST $DATE 1" 'the label gap generates a digest for firstmate'
  assert_equals '0' "$(jq '.start_requests | length' "$file")" 'idle evidence creates no ranked work item'
  assert_contains "$(jq -r '.coverage[]' "$file")" 'Linear labels not readable by linear-axi' 'idle evidence names missing label support'
  printf 'bad response\n' > "$WORLD/linear/list.json"
  run_progress >/dev/null || fail 'coverage gaps must still publish state'
  assert_equals 'null' "$(jq -r '.filler' "$file")" 'missing evidence never looks like an idle fleet'
  assert_equals '7' "$(jq '.coverage | length' "$file")" 'every failed listing pass and the label gap are reported'
  pass 'progress: proposes filler only with complete idle evidence'
}

test_linear_free_text_source() {
  make_world freetext
  python3 -I - "$WORLD" <<'PY'
import json, os, sys
root = sys.argv[1]
spec = [('PC-5', 'Add export', '(kind: feature) (requested-by: Lee)'),
        ('PC-6', 'Add another export', ''),
        ('PC-7', 'Product page redesign', ''),
        ('PC-8', 'Fix production login timeout', '')]
listed = []
for ident, title, description in spec:
    doc = {'identifier':ident, 'title':title, 'priority':0,
           'state': 'In Progress' if ident == 'PC-7' else 'Todo',
           'stateType': 'started' if ident == 'PC-7' else 'unstarted', 'description':description}
    listed.append(doc)
    json.dump({'ok':True,'data':{'issue':dict(doc, parent=None, description=description)}},
              open(os.path.join(root,'linear',ident+'.json'),'w'))
json.dump({'ok':True,'data':{'issues':listed}}, open(os.path.join(root,'linear','list.json'),'w'))
PY
  printf '## Done\n\n- [x] billing-export - Billing export\n' > "$WORLD_HOME/data/backlog.md"
  local file="$WORLD_HOME/data/officers/progress/$DATE.json"
  run_progress >/dev/null || fail 'free-text Linear run failed'
  assert_equals 'PC-5' "$(jq -r '[.start_requests[].id] | join(" ")' "$file")" \
    'a free-text tagged Linear item starts and an untagged one does not'
  assert_equals 'requested-feature linear-free-text:requested-by' \
    "$(jq -r '.start_requests[0] | .authorising_class + " " + .tag_source' "$file")" 'the start names its free-text source'
  assert_contains "$(cat "$WORLD_HOME/data/officers/progress/$DATE.md")" 'source: linear-free-text:requested-by' \
    'the digest shows where the authority came from'
  assert_equals '0' "$(jq '.doing + .done + .asks_for_lee | length' "$file")" \
    'choice words alone never place moving or finished Linear or backlog work in doing, done, or asks'
  assert_equals '3' "$(jq '.unclassified' "$file")" 'untagged, moving choice, and restricted-word items are counted'
  rm "$WORLD/linear/PC-5.json"
  jq '.data.issues |= map(select(.identifier != "PC-5"))' "$WORLD/linear/list.json" > "$WORLD/list.new"
  mv "$WORLD/list.new" "$WORLD/linear/list.json"
  run_progress >/dev/null || fail 'idle free-text Linear run failed'
  assert_equals '0' "$(jq '.asks_for_lee | length' "$file")" 'moving choice work never becomes a new card'
  assert_equals 'null' "$(jq -r '.filler' "$file")" 'missing label support still prevents filler'
  printf 'kind=ship\ntitle=Bug: meta-only crash\n' > "$WORLD_HOME/state/meta-bug.meta"
  run_progress >/dev/null || fail 'meta-only run failed'
  assert_equals 'meta-bug task-meta' "$(jq -r '.doing[] | .id + " " + .tag_source' "$file")" \
    'a task known only from its meta file is not labelled as backlog'
  pass 'progress: Linear free-text authority starts work and names its source'
}

test_linear_block_and_model_boundary() {
  make_world dependency
  linear_item PC-1 'Security: fix exposure'
  printf '## Queued\n\n- [ ] exposure - Fix exposure (kind: security) (linear: PC-1)\n' > "$WORLD_HOME/data/backlog.md"
  printf '{"ok":true,"data":{"issues":[]}}\n' > "$WORLD/linear/unblocked.json"
  local file="$WORLD_HOME/data/officers/progress/$DATE.json"
  run_progress >/dev/null || fail 'blocked Linear run failed'
  assert_equals '0' "$(jq '.start_requests | length' "$file")" 'Linear dependency blocks an otherwise authorised start'
  assert_equals 'exposure' "$(jq -r '.excluded[0].id' "$file")" 'blocked Linear issue stays visible'
  printf '{"ok":true,"data":{"issues":[],"pagination":{"hasNextPage":true}}}\n' > "$WORLD/linear/list.json"
  run_progress >/dev/null || fail 'truncated read run failed'
  assert_equals 'null' "$(jq -r '.filler' "$file")" 'capped Linear reads never trigger filler'
  assert_contains "$(jq -r '.coverage[]' "$file")" 'Linear discovery' 'capped read is incomplete coverage'
  printf -- '- progress - Invalid model (role: progress; cadence: daily 07:00; repos: example/project; model: cheap; added 2026-10-26)\n' > "$WORLD_HOME/data/officers.md"
  if run_progress > "$WORLD/refusal" 2>&1; then fail 'model use must be refused'; fi
  assert_contains "$(cat "$WORLD/refusal")" 'model "cheap" is not available' 'no model path is silently enabled'
  pass 'progress: Linear dependencies and partial reads suppress unsafe starts'
}

test_state_schema_and_idempotence() {
  make_world schema
  cat > "$WORLD_HOME/data/backlog.md" <<'MD'
## Queued

- [ ] fleet-request - Add requested operator tooling (kind: fleet) (requested-by: Lee)
- [ ] feature-request - Add requested export (kind: feature) (requested-by: Lee)
- [ ] unclassified - Investigate an unclassified request
- [ ] critical - Critical crash (kind: bug) (severity: critical)
MD
  run_progress >/dev/null || fail 'schema run failed'
  local file="$WORLD_HOME/data/officers/progress/$DATE.json" first
  first=$(cat "$file")
  python3 -I - "$ROOT/docs/schemas/progress-run.schema.json" "$file" <<'PY' || fail 'state schema validation failed'
import datetime, json, sys
schema, doc = [json.load(open(p)) for p in sys.argv[1:]]
# Validate the schema's supported vocabulary without a third-party dependency.
types = {'object':dict, 'array':list, 'string':str, 'integer':int, 'null':type(None)}
def validate(value, spec):
    if '$ref' in spec:
        spec = schema['$defs'][spec['$ref'].split('/')[-1]]
    if 'type' in spec:
        ts = spec['type'] if isinstance(spec['type'],list) else [spec['type']]
        assert any(type(value) is types[t] for t in ts), (value,spec)
    if 'const' in spec: assert value == spec['const']
    if 'enum' in spec: assert value in spec['enum'], value
    if isinstance(value,dict):
        assert set(spec.get('required',[])) <= set(value), value
        props = spec.get('properties',{})
        if spec.get('additionalProperties') is False: assert set(value) <= set(props)
        for k,v in value.items(): validate(v,props[k])
    if isinstance(value,list):
        for v in value: validate(v,spec['items'])
validate(doc,schema)
datetime.date.fromisoformat(doc['date'])
assert datetime.datetime.fromisoformat(doc['generated_at'].replace('Z','+00:00')).tzinfo
assert [r['rank'] for r in doc['start_requests']] == list(range(1,len(doc['start_requests'])+1))
assert doc['start_requests'][0]['id'] == 'critical'
assert any(r['authorising_class'] == 'requested-fleet' for r in doc['start_requests'])
assert any(r['authorising_class'] == 'requested-feature' for r in doc['start_requests'])
PY
  run_progress >/dev/null || fail 'repeat run failed'
  assert_equals "$first" "$(cat "$file")" 'unchanged inputs and clock produce identical state'
  pass 'progress: versioned state schema and repeatable output'
}

test_executable_start_requests() {
  make_world executable
  cat > "$WORLD_HOME/data/backlog.md" <<'MD'
## Queued

- [ ] safe - Fix a crash $(touch injected) (kind: bug)
- [ ] legal - Revise legal text (kind: feature) (requested-by: Lee)
MD
  run_progress >/dev/null || fail 'executable request generation failed'
  local lane="$WORLD_HOME/data/officers/progress" file="$WORLD_HOME/data/officers/progress/$DATE.json" count
  assert_present "$lane/$DATE.start-requests.sh" 'firstmate receives an executable handoff'
  FM_HOME="$WORLD_HOME" bash "$lane/$DATE.start-requests.sh" > "$WORLD/executed" || fail 'start handoff failed'
  FM_HOME="$WORLD_HOME" bash "$lane/$DATE.start-requests.sh" > "$WORLD/repeated" || fail 'repeated handoff failed'
  count=$(FM_HOME="$WORLD_HOME" bash "$ROOT/bin/fm-inbox.sh" receipts --all-pending)
  assert_contains "$count" 'Fix a crash' 'the firstmate inbox receives the authorised start'
  assert_not_contains "$count" 'Revise legal text' 'Lee choices never become executable starts'
  assert_not_contains "$count" 'Captain intent' 'officer findings are never relabeled as captain speech'
  assert_contains "$(cat "$WORLD/repeated")" 'replay' 'repeated execution never duplicates an intake request'
  assert_absent "$ROOT/injected" 'titles cannot execute shell substitutions'
  assert_equals 'start' "$(jq -r '.start_requests[0].execute.action' "$file")" 'JSON exposes automatic-start action'
  pass 'progress: executable starts use the existing idempotent firstmate intake'
}

test_remote_home_and_missing_home() {
  make_world remote
  local other="$WORLD/remote-home" file="$WORLD_HOME/data/officers/progress/$DATE.json"
  officer_home "$other"
  printf '## Queued\n\n- [ ] remote-bug - Fix remote crash (kind: bug)\n' > "$other/data/backlog.md"
  printf -- '- remote - Remote fixtures (host: fixture; root: /fixture/root; home: %s; scope: fixtures; projects: project; added 2026-10-26)\n' \
    "$other" > "$WORLD_HOME/data/secondmates.md"
  cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PROGRESS_WORLD/calls"
for arg in "$@"; do remote=$arg; done
case "$remote" in
  'python3 -I - scan --home '*) exec bash -c "$remote" ;;
  *) exit 99 ;;
esac
SH
  chmod +x "$FAKEBIN/ssh"
  run_progress >/dev/null || fail 'remote home read failed'
  assert_equals "fixture:$other" "$(jq -r '.start_requests[0].owner_home' "$file")" 'remote owner is retained'
  assert_equals 'remote-bug' "$(jq -r '.start_requests[0].id' "$file")" 'remote backlog is discovered'
  printf -- '- missing - Missing fixtures (home: %s; scope: fixtures; projects: project; added 2026-10-26)\n' \
    "$WORLD/missing" >> "$WORLD_HOME/data/secondmates.md"
  run_progress >/dev/null || fail 'missing-home report failed'
  assert_equals '0' "$(jq '.start_requests | length' "$file")" 'an unreadable home leaves no duplicate-start check to pass'
  assert_contains "$(jq -r '.excluded[].id' "$file")" 'remote-bug' 'checked work waits for every home'
  assert_contains "$(jq -r '.coverage[]' "$file")" 'Starts held: duplicate-start check unavailable: home records unavailable' 'the held reason is named'
  assert_equals 'null' "$(jq -r '.filler' "$file")" 'an unreadable home never proves idleness'
  assert_contains "$(jq -r '.coverage[]' "$file")" 'home records unavailable' 'missing local home is not skipped silently'
  pass 'progress: registered remote homes are read and unavailable homes are reported'
}

test_fleet_app_page_schema() {
  make_world page
  cat > "$WORLD_HOME/data/officers.md" <<'MD'
- progress - Tracks progress (role: progress; cadence: daily 07:00; repos: example/project; captains-log: https://fleet.example/api/captains-log; model: none; added 2026-10-26)
MD
  cat > "$WORLD_HOME/data/backlog.md" <<'MD'
## In flight

- [ ] working - Fix current crash (kind: bug)

## Queued

- [ ] ready - Fix the next crash (kind: bug)
- [ ] choice - Change pricing (kind: feature)
- [ ] existing-card - Choose legal text (kind: captain) (hold: Lee decides) (hold-kind: captain)

## Done

- [x] finished - Fix old crash (kind: bug)
MD
  run_progress >/dev/null || fail 'page run failed'
  local file="$WORLD_HOME/data/officers/progress/progress-state.json"
  assert_equals '1' "$(jq '.schema_version' "$file")" 'page schema is version 1'
  assert_equals 'progress' "$(jq -r '.officer' "$file")" 'page names registered officer'
  assert_equals 'bug' "$(jq -r '.doing[0].source' "$file")" 'page maps the authorising class to its agreed source'
  assert_equals 'bug' "$(jq -r '.done[0].source' "$file")" 'page records the completed source'
  assert_equals 'firstmate' "$(jq -r '.asking[] | select(.key == "ready") | .waiting_on' "$file")" 'start requests wait on firstmate'
  assert_equals 'captains_log' "$(jq -r '.asking[] | select(.key == "existing-card") | .kind' "$file")" 'existing Log cards remain references'
  assert_equals 'key kind link' "$(jq -r '.asking[] | select(.key == "existing-card") | keys | join(" ")' "$file")" 'a Log reference repeats no decision text'
  assert_equals 'https://fleet.example/captains-log#existing-card' \
    "$(jq -r '.asking[] | select(.key == "existing-card") | .link' "$file")" 'Log reference uses the existing card key'
  assert_equals '0' "$(jq '[keys[] | select(. == "start_requests" or . == "coverage" or . == "filler")] | length' "$file")" 'execution details stay out of the page contract'
  python3 -I - "$ROOT/docs/schemas/progress-state.schema.json" "$ROOT/tests/fixtures/progress/state-v1.json" "$file" <<'PY' || fail 'page schema contract failed'
import datetime, json, re, sys
schema = json.load(open(sys.argv[1]))
types = {'object':dict, 'array':list, 'string':str, 'integer':int, 'null':type(None)}
def validate(value, spec):
    if '$ref' in spec: spec = schema['$defs'][spec['$ref'].split('/')[-1]]
    if 'oneOf' in spec:
        matches=0
        for candidate in spec['oneOf']:
            try: validate(value,candidate)
            except AssertionError: continue
            matches+=1
        assert matches==1,(value,matches)
        return
    if 'type' in spec: assert type(value) is types[spec['type']],(value,spec)
    if 'const' in spec: assert value==spec['const']
    if 'enum' in spec: assert value in spec['enum']
    if isinstance(value,str):
        assert len(value)>=spec.get('minLength',0)
        assert len(value)<=spec.get('maxLength',len(value))
        if 'pattern' in spec: assert re.search(spec['pattern'],value),value
        if spec.get('format')=='date-time': assert datetime.datetime.fromisoformat(value.replace('Z','+00:00')).tzinfo
    if type(value) is int: assert spec.get('minimum',value)<=value<=spec.get('maximum',value)
    if isinstance(value,dict):
        assert set(spec.get('required',[]))<=set(value),value
        props=spec.get('properties',{})
        if spec.get('additionalProperties') is False: assert set(value)<=set(props),value
        for k,v in value.items(): validate(v,props[k])
    if isinstance(value,list):
        assert len(value)<=spec.get('maxItems',len(value))
        for v in value: validate(v,spec['items'])
for path in sys.argv[2:]:
    doc=json.load(open(path))
    validate(doc,schema)
    for key,field in [('doing','id'),('done','id'),('asking','key')]:
        assert len({r[field] for r in doc[key]})==len(doc[key])
PY
  local first_started first_asked previous_now=$NOW
  first_started=$(jq -r '.doing[0].started_at' "$file")
  first_asked=$(jq -r '.asking[] | select(.key == "ready") | .asked_at' "$file")
  NOW=$((NOW + 60))
  run_progress >/dev/null || fail 'second page observation failed'
  NOW=$previous_now
  assert_equals "$first_started" "$(jq -r '.doing[0].started_at' "$file")" 'watch start remains the first observation'
  assert_equals "$first_asked" "$(jq -r '.asking[] | select(.key == "ready") | .asked_at' "$file")" 'waiting time survives repeat observations'
  jq '.done = []' "$file" > "$file.new" && mv "$file.new" "$file"
  printf -- '- [x] fresh - Fix new crash (kind: bug)\n' >> "$WORLD_HOME/data/backlog.md"
  NOW=$((NOW + 120))
  run_progress >/dev/null || fail 'third page observation failed'
  NOW=$previous_now
  assert_equals 'fresh' "$(jq -r '[.done[].id] | join(" ")' "$file")" \
    'an outcome reported earlier and off the page does not return as new; a new outcome does'
  pass 'progress: fleet-app state matches the agreed schema and Slarti sample'
}

test_home_status_and_boundary() {
  make_world homes
  linear_item PC-91 'Bug: remote crash'
  local other="$WORLD/other" file="$WORLD_HOME/data/officers/progress/$DATE.json" before after
  officer_home "$other"
  printf -- '- other - Owns fixtures (home: %s; scope: fixtures; projects: project; added 2026-10-26)\n' \
    "$other" > "$WORLD_HOME/data/secondmates.md"
  cat > "$other/data/backlog.md" <<'MD'
## Queued

- [ ] remote-bug - Fix remote crash (kind: bug) (linear: PC-91)
- [ ] card - Fix a held bug (kind: bug)
- [ ] active - Fix an active bug (kind: bug)
MD
  printf 'needs-decision [at=1] [key=choice]: Lee decides\nworking [at=2]: working\n' > "$other/state/card.status"
  printf 'kind=ship\n' > "$other/state/active.meta"
  printf 'working [at=2]: started\n' > "$other/state/active.status"
  cat > "$WORLD_HOME/data/backlog.md" <<'MD'
## Queued

- [ ] duplicate - Fix same remote crash (kind: bug) (linear: PC-91)
MD
  # Any forbidden command becomes a visible failure in the invocation log.
  local cmd
  for cmd in fm-send.sh fm-spawn.sh fm-pr-merge.sh curl; do
    cat > "$FAKEBIN/$cmd" <<'SH'
#!/usr/bin/env bash
printf 'forbidden %s\n' "$0" >> "$PROGRESS_WORLD/calls"
exit 99
SH
    chmod +x "$FAKEBIN/$cmd"
  done
  before=$(python3 -I - "$WORLD_HOME" "$other" <<'PY'
import hashlib, os, sys
for root in sys.argv[1:]:
 for base, dirs, files in os.walk(root):
  dirs[:] = [d for d in dirs if d != 'officers']
  for f in sorted(files):
   p = os.path.join(base,f)
   print(p,hashlib.sha256(open(p,'rb').read()).hexdigest())
PY
)
  run_progress >/dev/null || fail 'home discovery failed'
  assert_equals '1' "$(jq '.start_requests | length' "$file")" 'duplicate Linear requests collapse'
  assert_equals 'active' "$(jq -r '.doing[0].id' "$file")" 'meta suppresses restarting a queued item'
  assert_equals 'card' "$(jq -r '.excluded[0].id' "$file")" 'working never closes a keyed Lee call'
  after=$(python3 -I - "$WORLD_HOME" "$other" <<'PY'
import hashlib, os, sys
for root in sys.argv[1:]:
 for base, dirs, files in os.walk(root):
  dirs[:] = [d for d in dirs if d != 'officers']
  for f in sorted(files):
   p = os.path.join(base,f)
   print(p,hashlib.sha256(open(p,'rb').read()).hexdigest())
PY
)
  assert_equals "$before" "$after" 'all home records outside the findings lane are unchanged'
  assert_not_contains "$(cat "$WORLD/calls")" 'forbidden' 'officer never dispatches, steers, merges, or posts'
  assert_not_contains "$(cat "$WORLD/calls")" 'issue update' 'officer never writes Linear'
  pass 'progress: reads other homes and status without acting on them'
}

test_ancestor_asks_hold_only_routed_asks
test_linear_rate_limit_recovers
test_merge_ask_pr_state
test_github_reads_respect_deadline
test_review_words_and_explicit_asks
test_partial_coverage_starts
test_linear_pagination
test_linear_rate_limit
test_linear_page_cap
test_linear_child_cap
test_start_candidate_checks
test_start_check_budget
test_backlog_discovery
test_linear_trees_and_exclusions
test_filler_and_failure_coverage
test_home_status_and_boundary
test_linear_free_text_source
test_linear_block_and_model_boundary
test_state_schema_and_idempotence
test_executable_start_requests
test_remote_home_and_missing_home
test_fleet_app_page_schema
