#!/usr/bin/env bash
# Progress officer behavior through the registered officer's run interface.
set -u

# shellcheck source=tests/officer-helpers.sh
. /home/lee/.no-mistakes/worktrees/4e1bb7649f99/01M5YCK1458QJZPGKTYYH4AERM/tests/officer-helpers.sh

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
time.sleep = lambda s: s >= 1 and open(os.environ["PROGRESS_WORLD"] + "/sleeps", "a").write("%g\n" % s)
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
make_world manual
python3 -I - "$WORLD" <<'PYFIX'
import json, pathlib, sys
w = pathlib.Path(sys.argv[1]); root = w / 'linear'
spec = [
    ('PC-201', '[scheduled-review] Audit session boundaries', None, ''),
    ('PC-202', 'Security: rotate leaked credential', None, ''),
    ('PC-203', 'Bug: Business Health tile shows NaN', None, ''),
    ('PC-204', 'Bug: Business Health wording for empty state', None, ''),
    ('PC-205', 'Bug: parent read fails', 'PC-299', ''),
    ('PC-206', 'Bug: already has an open PR', None, ''),
    ('PC-207', 'Tidy layout spacing', None, '(kind: bug)'),
    ('PC-208', 'Decide pricing tiers', None, ''),
]
listed = []
for ident, title, parent, description in spec:
    issue = dict(identifier=ident, title=title, state='Todo', stateType='unstarted')
    listed.append(issue)
    (root / (ident + '.json')).write_text(json.dumps(dict(ok=True, data=dict(issue=dict(issue, parent=parent, description=description)))))
(root / 'list.json').write_text(json.dumps(dict(ok=True, data=dict(issues=listed))))
(root / 'PC-299.json').write_text(json.dumps(dict(ok=False, error=dict(code='NOT_FOUND'))))
(w / 'prs.json').write_text(json.dumps([{'number': 7, 'title': 'Fix PC-206', 'headRefName': 'fm/PC-206', 'body': 'Fixes PC-206', 'html_url': 'https://github.com/example/project/pull/7'}]))
PYFIX
lane="$WORLD_HOME/data/officers/progress"; file="$lane/$DATE.json"
echo "=== RUN 1: partial Linear coverage, PR discovery OK ==="
run_progress; echo "exit=$?"
echo "--- start_requests"; jq -r '.start_requests[] | "\(.rank) \(.id) class=\(.authorising_class) src=\(.tag_source)  \(.title)"' "$file"
echo "--- asks_for_lee"; jq -r '.asks_for_lee[] | "\(.id) \(.title) -> \(.reason)"' "$file"
echo "--- excluded"; jq -r '.excluded[] | "\(.id) \(.title) -> \(.reason)"' "$file"
echo "--- coverage"; jq -r '.coverage[]' "$file"
echo "--- page asking (progress-state.json)"; jq -r '.asking[] | "[\(.waiting_on)] \(.question)"' "$lane/progress-state.json"
echo "--- handoff script"; ls "$lane"; cat "$lane/$DATE.start-requests.sh" 2>/dev/null
echo; echo "=== RUN 2: open-PR discovery fails ==="
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/gh-axi"
run_progress >/dev/null; echo "exit=$?"
echo "start_requests: $(jq '.start_requests|length' "$file")"; jq -r '.coverage[]' "$file"
echo "page asks:"; jq -r '.asking[] | "[\(.waiting_on)] \(.question)"' "$lane/progress-state.json"
echo "handoff:"; cat "$lane/$DATE.start-requests.sh" 2>/dev/null | grep -c PC- 
echo; echo "=== RUN 3: PR OK, registered home unreadable ==="
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
python3 -I -c 'import json,sys; [print("PRJSON "+json.dumps(p)) for p in json.load(open(sys.argv[1]))]' "$PROGRESS_WORLD/prs.json"
SH
chmod +x "$FAKEBIN/gh-axi"
printf -- '- missing - Missing (home: %s; scope: fixtures; projects: project; added 2026-10-26)\n' "$WORLD/missing" > "$WORLD_HOME/data/secondmates.md"
run_progress >/dev/null; echo "exit=$?"
echo "start_requests: $(jq '.start_requests|length' "$file")"; jq -r '.coverage[]' "$file"
