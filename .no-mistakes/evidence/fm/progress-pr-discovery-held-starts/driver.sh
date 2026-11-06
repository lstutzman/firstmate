#!/usr/bin/env bash
# Progress officer behavior through the registered officer's run interface.
set -u

# shellcheck source=tests/officer-helpers.sh
. "{run-worktree}/tests/officer-helpers.sh"

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
  printf '{"rows":[]}\n' > "$WORLD/top-of-mind.json"
  stub_python
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

stub_python() {
  local real_python
  real_python=$(command -v python3)
  cat > "$FAKEBIN/python3" <<SH
#!/usr/bin/env bash
case "\$2" in
  *fm-officer-progress.py) exec "$real_python" -I -c '
import io, json, os, pathlib, runpy, sys, time, urllib.request
root = pathlib.Path(os.environ["PROGRESS_WORLD"])
def fetch(url, timeout):
    with (root / "fetches").open("a") as log: log.write(str(url) + " " + str(timeout) + "\n")
    if (root / "fetch-failure").exists(): raise OSError("fixture unavailable")
    return io.BytesIO((root / "top-of-mind.json").read_bytes())
urllib.request.urlopen = fetch
if (root / "stub-sleep").exists():
    clock = [time.monotonic()]
    time.monotonic = lambda: clock[0]
    def wait(s):
        if s < 0.1: return
        clock[0] += s
        if s >= 1: (root / "sleeps").open("a").write("%g\n" % s)
    time.sleep = wait
sys.argv = sys.argv[2:]
runpy.run_path(sys.argv[0], run_name="__main__")' "\$@" ;;
esac
exec "$real_python" "\$@"
SH
  chmod +x "$FAKEBIN/python3"
}

stub_sleep() {
  touch "$WORLD/stub-sleep"
}

run_progress() {
  FM_LOCAL_JEV="$WORLD/local-jev.py" PROGRESS_WORLD="$WORLD" PATH="$FAKEBIN:$PATH" FM_HOME="$WORLD_HOME" FM_OFFICER_NOW="$NOW" \
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

REAL_GH=~/.nvm/versions/node/v24.22.1/bin/gh-axi
live_world() {  # <name>: officer pointed at the real lstutzman/firstmate repo, PR listing through real gh-axi
  make_world "$1"
  sed -i 's|repos: example/project|repos: lstutzman/firstmate|' "$WORLD_HOME/data/officers.md"
  cp "$FAKEBIN/gh-axi" "$WORLD/gh-axi-stub"
  cat > "$FAKEBIN/gh-axi" <<EOS
#!/usr/bin/env bash
case "\$3" in
  */pulls\?*)
    printf 'REAL %s\n' "\$*" >> "\$PROGRESS_WORLD/calls"
    n=\$(cat "\$PROGRESS_WORLD/fail-count" 2>/dev/null || echo 0)
    if [ "\$n" -gt 0 ]; then
      echo \$((n - 1)) > "\$PROGRESS_WORLD/fail-count"
      echo "Post https://api.github.com/graphql: read tcp: connection reset by peer token=ghp_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE12" >&2
      exit 1
    fi
    exec $REAL_GH "\$@" ;;
esac
exec "$WORLD/gh-axi-stub" "\$@"
EOS
  chmod +x "$FAKEBIN/gh-axi"
  linear_item PC-61 'Bug: checked work starts'
  cat > "$WORLD_HOME/data/backlog.md" <<'MD'
## In flight

- [ ] pc23-a - PC-23 first piece (kind: bug) (pr: https://github.com/lstutzman/firstmate/pull/4596)
- [ ] pc23-b - PC-23 second piece (kind: bug) (pr: https://github.com/lstutzman/firstmate/pull/4602)
- [ ] pc23-c - PC-23 third piece (kind: bug) (pr: https://github.com/lstutzman/firstmate/pull/4626)

## Done

- [x] pc27-a - PC-2700 one outcome (kind: bug)
- [x] pc27-b - PC-2700 two outcome (kind: bug)
- [x] pc27-c - PC-2700 three outcome (kind: bug)
MD
}
