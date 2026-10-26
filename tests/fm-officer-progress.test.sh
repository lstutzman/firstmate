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
    case " $* " in
      *' --unblocked '*)
        if [ -f "$PROGRESS_WORLD/linear/unblocked.json" ]; then
          cat "$PROGRESS_WORLD/linear/unblocked.json"
          exit
        fi ;;
    esac
    cat "$PROGRESS_WORLD/linear/list.json" ;;
  'issue view') cat "$PROGRESS_WORLD/linear/$3.json" ;;
  *) exit 99 ;;
esac
SH
  cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PROGRESS_WORLD/calls"
[ "$1 $2" = 'api GET' ] || exit 99
python3 -I - "$PROGRESS_WORLD/prs.json" <<'PY'
import json, sys
for pr in json.load(open(sys.argv[1])):
    print('PRJSON ' + json.dumps(pr))
PY
SH
  chmod +x "$FAKEBIN/linear-axi" "$FAKEBIN/gh-axi"
}

run_progress() {
  PROGRESS_WORLD="$WORLD" PATH="$FAKEBIN:$PATH" FM_HOME="$WORLD_HOME" FM_OFFICER_NOW="$NOW" \
    bash "$OFFICER" run progress --date "$DATE"
}

linear_item() {  # <id> <title>
  python3 -I - "$WORLD" "$1" "$2" <<'PY'
import json, sys
root, ident, title = sys.argv[1:]
json.dump({'ok':True,'data':{'issues':[{'identifier':ident}]}},open(root+'/linear/list.json','w'))
json.dump({'ok':True,'data':{'issue':{'identifier':ident,'title':title,'state':'Todo',
          'stateType':'unstarted','priority':0,'parent':None,'description':''}}},open(root+'/linear/'+ident+'.json','w'))
PY
}

test_backlog_discovery() {
  make_world backlog
  linear_item PC-1 'Bug: reported crash'
  cat > "$WORLD_HOME/data/backlog.md" <<'MD'
## In flight

- [ ] busy - Fix a bug already moving (repo: project) (kind: bug)

## Queued

- [ ] bug-one - Fix a reported crash (repo: project) (kind: bug) (linear: PC-1)
- [ ] feature-one - Add the requested export (repo: project) (kind: feature) (requested-by: Lee)
- [ ] unasked - Add an unrequested feature (repo: project) (kind: feature)

## Done

- [x] finished - Fix the old crash (repo: project) (kind: bug)
MD
  local out file
  out=$(run_progress) || fail "progress officer run failed: $out"
  file="$WORLD_HOME/data/officers/progress/$DATE.progress-run.json"
  assert_equals 'bug-one feature-one' "$(jq -r '[.start_requests[].id] | join(" ")' "$file")" \
    'only authorised unstarted backlog work is requested'
  assert_equals 'PC-1' "$(jq -r '.start_requests[0].linear_id' "$file")" 'Linear evidence is retained'
  assert_equals "$WORLD_HOME" "$(jq -r '.start_requests[0].owner_home' "$file")" 'owning home is named'
  assert_equals 'bug' "$(jq -r '.start_requests[0].authorising_class' "$file")" 'authority is explicit'
  assert_equals 'busy' "$(jq -r '.doing[0].id' "$file")" 'moving work appears in doing'
  assert_equals 'finished' "$(jq -r '.done[0].id' "$file")" 'finished work appears in done'
  assert_contains "$out" "DIGEST $DATE" 'the existing digest protocol is retained'
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
]
json.dump({'ok':True,'data':{'issues':[{'identifier':s[0]} for s in spec]}},
          open(os.path.join(root,'linear','list.json'),'w'))
for ident, title, state, parent, priority in spec:
    doc = {'identifier':ident, 'title':title, 'state':state, 'priority':priority,
           'stateType': 'started' if state == 'In Progress' else 'completed' if state == 'Done' else 'unstarted',
           'parent': parent + ' Parent title' if parent else None, 'description':''}
    json.dump({'ok':True,'data':{'issue':doc}}, open(os.path.join(root,'linear',ident+'.json'),'w'))
json.dump([{'number':17,'title':'PC-17 fix crash','body':'Linear: PC-17',
            'html_url':'https://github.com/example/project/pull/17','head':{'ref':'fix-crash'}}],
          open(os.path.join(root,'prs.json'),'w'))
PY
  cat > "$WORLD_HOME/data/backlog.md" <<'MD'
## Queued

- [ ] carded - Bug: carded elsewhere (kind: bug) (linear: PC-18) (hold: Lee decides) (hold-kind: captain)
- [ ] blocked-bug - Bug: blocked by another issue (kind: bug) (linear: PC-20) (blocked-by: dependency)
- [ ] wording - Choose revised wording (kind: bug)
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
  local file="$WORLD_HOME/data/officers/progress/$DATE.progress-run.json"
  run_progress >/dev/null || fail 'linear discovery failed'
  assert_equals 'PC-14 PC-19 PC-16 PC-15 PC-12' \
    "$(jq -r '[.start_requests[].linear_id] | join(" ")' "$file")" \
    'security then review/bugs by severity then deeply nested requested work'
  assert_equals 'requested-feature' \
    "$(jq -r '.start_requests[] | select(.linear_id == "PC-12") | .authorising_class' "$file")" \
    'a leaf inherits the recorded root request across completed parents'
  assert_equals 'PC-13 PC-21 business legal payments product wording' \
    "$(jq -r '[.asks_for_lee[].id] | sort | join(" ")' "$file")" 'choices need Lee, including descendants'
  assert_equals 'PC-17 blocked-bug carded open-branch' \
    "$(jq -r '[.excluded[].id] | sort | join(" ")' "$file")" 'PRs, blocks, and existing cards exclude starts'
  assert_equals 'null' "$(jq -r '.filler' "$file")" 'no filler while authorised work is ready'
  assert_contains "$(cat "$WORLD_HOME/data/officers/progress/$DATE.md")" 'PC-12' 'ranked digest includes leaf'
  pass 'progress: discovers deep Linear children, ranks work, and keeps choices for Lee'
}

test_filler_and_failure_coverage() {
  make_world filler
  local file="$WORLD_HOME/data/officers/progress/$DATE.progress-run.json" out
  out=$(run_progress) || fail 'empty run failed'
  assert_equals '1' "$(jq -r '.filler | length > 0 | if . then 1 else 0 end' "$file")" 'idle fleet proposes filler'
  assert_contains "$out" "DIGEST $DATE 1" 'filler generates a digest for firstmate'
  assert_equals '0' "$(jq '.start_requests | length' "$file")" 'filler is a proposal, not an authorised start'
  printf 'bad response\n' > "$WORLD/linear/list.json"
  run_progress >/dev/null || fail 'coverage gaps must still publish state'
  assert_equals 'null' "$(jq -r '.filler' "$file")" 'missing evidence never looks like an idle fleet'
  assert_equals '1' "$(jq '.coverage | length' "$file")" 'read failure is reported'
  pass 'progress: proposes filler only with complete idle evidence'
}

test_linear_block_and_model_boundary() {
  make_world dependency
  linear_item PC-1 'Security: fix exposure'
  printf '{"ok":true,"data":{"issues":[]}}\n' > "$WORLD/linear/unblocked.json"
  local file="$WORLD_HOME/data/officers/progress/$DATE.progress-run.json"
  run_progress >/dev/null || fail 'blocked Linear run failed'
  assert_equals '0' "$(jq '.start_requests | length' "$file")" 'Linear dependency blocks an otherwise authorised start'
  assert_equals 'PC-1' "$(jq -r '.excluded[0].id' "$file")" 'blocked Linear issue stays visible'
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
  local file="$WORLD_HOME/data/officers/progress/$DATE.progress-run.json" first
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
  local lane="$WORLD_HOME/data/officers/progress" file="$WORLD_HOME/data/officers/progress/$DATE.progress-run.json" count
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
  local other="$WORLD/remote-home" file="$WORLD_HOME/data/officers/progress/$DATE.progress-run.json"
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
  assert_equals '0' "$(jq '.start_requests | length' "$file")" 'unreadable registered homes suppress duplicate starts'
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
  pass 'progress: fleet-app state matches the agreed schema and Slarti sample'
}

test_home_status_and_boundary() {
  make_world homes
  linear_item PC-91 'Bug: remote crash'
  local other="$WORLD/other" file="$WORLD_HOME/data/officers/progress/$DATE.progress-run.json" before after
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

test_backlog_discovery
test_linear_trees_and_exclusions
test_filler_and_failure_coverage
test_home_status_and_boundary
test_linear_block_and_model_boundary
test_state_schema_and_idempotence
test_executable_start_requests
test_remote_home_and_missing_home
test_fleet_app_page_schema
