#!/usr/bin/env python3
"""PR-drain state of one project's GitHub repository (the captain's open-PR drain rule).

Usage: fm-pr-drain.py state <project-dir>
       fm-pr-drain.py class <value>
       fm-pr-drain.py evidence < <captain's-intent-text>
       fm-pr-drain.py security <PC-n>

A repository enters drain at 20 or more open PRs and leaves it only when its open count reaches 0.
state prints one line and exits 0:
  on <owner/repo> <open>       in drain
  off <owner/repo> <open>      not in drain
  unknown <owner/repo> <why>   GitHub could not be read or the history is not decisive
  none                         the clone's origin is not on github.com, so the rule does not apply
The state is derived from GitHub itself, so every home on every machine reads the same answer with no
shared marker: the open list gives the count now, and when it is between 1 and 19 the PRs closed in the
last 14 days are walked back from now (a close adds one PR, a creation removes one) until the count was
20 or more (on) or 0 (off). Read-only: one `gh pr list` of open PRs, plus one of recently closed PRs only
in that 1..19 band. FM_PR_DRAIN_TIMEOUT (default 20) bounds each read in seconds.
class exits 0 when <value> is a recognised drain declaration: an exemption class (production-outage,
cve, security, wolverine, lee-research, lee-explicit, officer, scheduled) or a landing job (restack,
red-gate-fix, returned-pr-fix, review), and 2 otherwise. bin/fm-brief.sh --pr-drain writes it into a
brief and bin/fm-spawn.sh reads it back.
evidence reads a brief's `## Captain's intent` section body on stdin (bin/fm-spawn.sh extracts it with
bin/fm-brief-heading-lib.sh) and exits 0 when it holds a quoted captain instruction with a timestamp,
the proof a `lee-explicit` brief needs: at least one double-quoted span, and an ISO-8601 UTC timestamp (YYYY-MM-DDTHH:MM:SSZ) on the same line as a quote or on the line before it.
It exits 2 and names what is missing otherwise. It does not check that the quote is real.
security reads the Linear item <PC-n> (read-only) and exits 0 when it carries the label `security` (any case)
and its priority is Urgent (1) or High (2), the proof a `security` brief needs (fleet rules s3: high or critical
security fixes start at once). It exits 2 and names the item and what is missing otherwise, including when Linear
cannot be read. Linear is read through one helper, read_item: a read-only GraphQL query authenticated by
`linear-token header --print-to-pipe` (the credential linear-axi uses; never printed or stored).
FM_PR_DRAIN_LINEAR_READER names an executable that replaces it (tests): it gets the item id as its argument and
prints JSON such as {"priority": 1, "labels": ["Bug", "security"]}.
"""
from datetime import datetime, timedelta, timezone
import json
import os
import re
import subprocess
import sys
import urllib.request

THRESHOLD = 20
WINDOW_DAYS = 14
CLOSED_LIMIT = 1000
EXEMPT = ('production-outage', 'cve', 'security', 'wolverine', 'lee-research', 'lee-explicit', 'officer', 'scheduled')
LANDING = ('restack', 'red-gate-fix', 'returned-pr-fix', 'review')
STAMP = re.compile(r'\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?Z\b')
ITEM = re.compile(r'^PC-[0-9]+$')
PRIORITIES = {1: 'Urgent', 2: 'High'}
QUOTE = re.compile(r'"[^"\n]+"')
ORIGIN = re.compile(r'^(?:git@github\.com:|ssh://git@github\.com/|https://github\.com/)'
                    r'([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?$')


def gh(repo, *args):
    result = subprocess.run(['gh', 'pr', 'list', '-R', repo, *args], stdin=subprocess.DEVNULL,
                            capture_output=True, text=True,
                            timeout=float(os.environ.get('FM_PR_DRAIN_TIMEOUT', 20)), check=False)
    if result.returncode:
        raise ValueError((result.stderr.strip().splitlines() or ['gh failed'])[0][:160])
    return json.loads(result.stdout)


def when(stamp):
    return datetime.fromisoformat(stamp.replace('Z', '+00:00'))


def state(project):
    # The configured URL first, then its insteadOf expansion, so either spelling of a GitHub origin counts.
    match = None
    for argv in (['config', '--get', 'remote.origin.url'], ['remote', 'get-url', 'origin']):
        origin = subprocess.run(['git', '-C', project, *argv], capture_output=True, text=True,
                                check=False).stdout.strip()
        match = match or ORIGIN.match(origin)
    if not match:
        return 'none'
    repo = match.group(1)
    try:
        # The open read (no --search) proves the repository is readable; a search answers [] when it is not.
        opened = gh(repo, '--state', 'open', '--limit', '1000', '--json', 'createdAt')
        count = len(opened)
        if count >= THRESHOLD or count == 0:
            return f"{'on' if count else 'off'} {repo} {count}"
        since = datetime.now(timezone.utc) - timedelta(days=WINDOW_DAYS)
        closed = gh(repo, '--state', 'closed', '--search', f"closed:>={since:%Y-%m-%dT%H:%M:%SZ}",
                    '--limit', str(CLOSED_LIMIT), '--json', 'createdAt,closedAt')
        if len(closed) >= CLOSED_LIMIT:
            return f'unknown {repo} {CLOSED_LIMIT} or more PRs closed in {WINDOW_DAYS} days (the GitHub search cap)'
        steps = {}
        for pr in opened + closed:
            if when(pr['createdAt']) >= since:
                steps[when(pr['createdAt'])] = steps.get(when(pr['createdAt']), 0) - 1
            if pr.get('closedAt') and when(pr['closedAt']) >= since:
                steps[when(pr['closedAt'])] = steps.get(when(pr['closedAt']), 0) + 1
        live = count
        # Events sharing one timestamp apply together, so a same-second open and close is no false 0 or 20.
        for moment in sorted(steps, reverse=True):
            live += steps[moment]
            if live >= THRESHOLD or live <= 0:
                return f"{'on' if live > 0 else 'off'} {repo} {count}"
        # shortcut: 14 days of 1..19 open PRs is undecided; widen WINDOW_DAYS if that becomes common.
        return f'unknown {repo} open count stayed between 1 and {THRESHOLD - 1} for {WINDOW_DAYS} days'
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired) as error:
        return f'unknown {repo} GitHub unreadable: {error}'.replace('\n', ' ')


def evidence(text):
    """What a lee-explicit brief's `## Captain's intent` text lacks, as a list (empty when complete)."""
    lines = text.splitlines()
    if not text.strip():
        return ["a '## Captain's intent' section"]
    quoted = [i for i, line in enumerate(lines) if QUOTE.search(line)]
    if not quoted:
        return ['a double-quoted captain instruction']
    if not any(STAMP.search(lines[i]) or (i and STAMP.search(lines[i - 1])) for i in quoted):
        return ['an ISO-8601 UTC timestamp (for example 2026-11-16T18:19:06Z) on the quote line or the line before it']
    return []



def read_item(item):
    """The one Linear read: {'priority': int, 'labels': [names]} for a PC item. Raises ValueError with the reason."""
    reader = os.environ.get('FM_PR_DRAIN_LINEAR_READER')
    timeout = float(os.environ.get('FM_PR_DRAIN_TIMEOUT', 20))
    try:
        if reader:
            out = subprocess.run([reader, item], stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                 timeout=timeout, check=False)
            if out.returncode:
                raise ValueError((out.stderr.strip().splitlines() or ['reader failed'])[0][:160])
            return json.loads(out.stdout)
        token = subprocess.run(['linear-token', 'header', '--print-to-pipe'], stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=timeout, check=False)
        if token.returncode or not token.stdout.strip():
            raise ValueError('no Linear credential from linear-token')
        query = 'query($id:String!){issue(id:$id){identifier priority labels{nodes{name}}}}'
        request = urllib.request.Request('https://api.linear.app/graphql',
                                         data=json.dumps({'query': query, 'variables': {'id': item}}).encode(),
                                         headers={'Authorization': token.stdout.strip(), 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = json.load(response)
        except Exception:
            # Never echo the exception: a header error can quote the Authorization value.
            raise ValueError('Linear GraphQL read failed') from None
        issue = (body.get('data') or {}).get('issue')
        if not issue:
            raise ValueError('no such item or Linear refused the read')
        return {'priority': issue['priority'], 'labels': [n['name'] for n in issue['labels']['nodes']]}
    except (KeyError, TypeError, OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
        raise ValueError(f'Linear unreadable: {type(error).__name__}') from None


def security(item):
    """What a `security` brief's Linear item lacks, as a list (empty when it qualifies)."""
    if not ITEM.match(item or ''):
        return [f"a Property Compass item id such as PC-123 (got '{item}')"]
    try:
        data = read_item(item)
        labels = {str(name).lower() for name in data['labels']}
        priority = data['priority']
    except (ValueError, KeyError, TypeError) as error:
        return [f'a readable Linear item ({error})']
    missing = []
    if 'security' not in labels:
        missing.append('the label `security`')
    if priority not in PRIORITIES:
        missing.append(f'priority Urgent or High (it is {priority!r})')
    return missing


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'state':
        print(state(sys.argv[2]))
    elif len(sys.argv) == 3 and sys.argv[1] == 'class':
        sys.exit(0 if sys.argv[2] in EXEMPT + LANDING else 2)
    elif len(sys.argv) == 2 and sys.argv[1] == 'evidence':
        missing = evidence(sys.stdin.read())
        if missing:
            print('lee-explicit needs, in the brief\'s "## Captain\'s intent" section: ' + '; '.join(missing), file=sys.stderr)
            sys.exit(2)
    elif len(sys.argv) == 3 and sys.argv[1] == 'security':
        missing = security(sys.argv[2])
        if missing:
            print(f"security needs Linear item {sys.argv[2]} to have: " + '; '.join(missing), file=sys.stderr)
            sys.exit(2)
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
