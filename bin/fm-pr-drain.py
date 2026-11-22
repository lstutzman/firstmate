#!/usr/bin/env python3
"""PR-drain state of one project's GitHub repository (the captain's open-PR drain rule).

Usage: fm-pr-drain.py state <project-dir> [<project-name>]
       fm-pr-drain.py open <project-dir>
       fm-pr-drain.py gate <project-dir> [<project-name>]
       fm-pr-drain.py class <value>
       fm-pr-drain.py slots-class <value>
       fm-pr-drain.py evidence < <captain's-intent-text>
       fm-pr-drain.py security <PC-n>

A repository enters drain at 24 or more eligible open PRs and leaves it when its eligible count is at or below S (its
config/ci-slots line; 0 when it declares none). An eligible PR is a ready (non-draft) open PR that is not a promotion PR
(head branch `staging`) and, where a local task record shows it, not waiting for the captain's merge word; a PR held
for a release day (Wednesday) or another home's wait is left out when its holding home labels it `held`.
One function, tally, counts for state, open and gate, so the three read the same PRs. It counts each landing unit once: a
landing pile (a ready PR whose head branch starts `landing/pile-`) and the member PRs its body names (`Member: PR n` or
`Members in order: PR n ... and PR m ...`, read only up to the end of that sentence) are one unit, counted as the pile,
because the pile is the PR that takes the CI slot (one exact-head gate on its merged tree) and its members wait unmerged
in it. A draft pile folds nothing; the same rule applies to the closed PRs in state's walk-back.
state prints one line and exits 0:
  on <owner/repo> <open>       in drain
  off <owner/repo> <open>      not in drain
  unknown <owner/repo> <why>   GitHub could not be read or the history is not decisive
  none                         the clone's origin is not on github.com, so the rule does not apply
The state is derived from GitHub itself, so every home on every machine reads the same answer with no
shared marker: the open list gives the eligible count now, and when it is above S and below 24 the PRs closed in the
last 14 days are walked back from now (a close adds one PR, a creation removes one; closed PRs count as eligible unless
they were drafts, promotion PRs or labelled `held`) until the count was 24 or more (on) or S or fewer (off). Read-only: one `gh pr list`
of open PRs, plus one of recently closed PRs only in that band. FM_PR_DRAIN_TIMEOUT (default 20) bounds each read in seconds.
open prints one line, the CI-slot count (P: the eligible count state reads, so drafts, promotion PRs, PRs waiting for the
captain and PRs labelled `held` are left out, and a pile counts once) that bin/fm-fleet-alarm.py compares with a project's
CI slots (config/ci-slots; bin/fm-project-capacity-lib.sh owns it), from one `gh pr list` read:
  open <owner/repo> <n>        the repository has n eligible open PRs
  unknown <owner/repo> <why>   GitHub could not be read
  none                         the clone's origin is not on github.com
gate is the worker's CI slots check, run just before it opens a pull request (bin/fm-dod-lib.sh writes the step into
a brief). It prints one line: `hold <owner/repo> <why>` when the opening must wait, `open <owner/repo>` when it may
go ahead (also for a project with no CI slots), `unknown <owner/repo> <why>` when a declaration or GitHub cannot be
read, or `none` off github.com. It holds when the ready open PRs, less drafts and promotion PRs and with a pile and its
members counted once, reach the open-PR cap (config/open-pr-cap, default min(2 x S, 16)). The PRs waiting for the
captain's merge word (bin/fm-ci-slots-held.sh) and the PRs labelled `held` use no CI slot but are counted toward the cap
(Lee, 2026-11-22T12:51:39Z, card open-pr-cap-recorded-holds). <project-name> is the registered name that
names the project in those files; it defaults to the directory's name. FM_HOME picks the home whose config is read.
class exits 0 when <value> is a recognised drain declaration: an exemption class (production-outage,
cve, security, wolverine, lee-research, lee-explicit, officer, scheduled) or a landing job (restack,
red-gate-fix, returned-pr-fix, review), and 2 otherwise. bin/fm-brief.sh --pr-drain writes it into a
brief and bin/fm-spawn.sh reads it back.
slots-class exits 0 when <value> is a drain declaration that also bypasses the CI-slots cap: production-outage, cve,
security, lee-explicit and the four landing jobs; wolverine, lee-research, officer and scheduled stay held. It is
bin/fm-brief.sh's one list of the classes whose briefs carry no CI slots check.
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
prints JSON such as {"priority": 1, "labels": ["Bug", "security"]}. FM_PR_DRAIN_LINEAR_URL replaces the GraphQL
endpoint (tests).
"""
from datetime import datetime, timedelta, timezone
import json
import os
import re
import subprocess
import sys
import urllib.request

BIN = os.path.dirname(os.path.abspath(__file__))
THRESHOLD = 24
PROMOTION_HEAD = 'staging'
# The one label a holding home sets on a PR it holds (Wednesday pile, waiting for the captain's word) and removes when the
# hold ends: the PR uses no CI slot, so it leaves the slot counts, but it still counts toward the open-PR cap.
HELD_LABEL = 'held'
# A landing pile (Slarti's merge train: several member PRs merged onto one branch, gated once on its merged tree) is a PR
# whose head branch starts with PILE_HEAD and whose body names its members in one clause: `Member: PR 6239 ...` or
# `Members in order: PR 6268 ... and PR 6271 ...`, ending at the first sentence end. Only that clause is read, so the
# pile it is laid on (`after PR 6276`) is never taken for a member.
PILE_HEAD = 'landing/pile-'
MEMBERS = re.compile(r'\bMembers?(?: in order)?\s*:\s*(.*?)(?:\.(?:\s|$)|\n\s*\n|$)', re.S)
MEMBER_REF = re.compile(r'(?:\bPR\s+#?|#|/pull/)(\d+)')
WINDOW_DAYS = 14
CLOSED_LIMIT = 1000
EXEMPT = ('production-outage', 'cve', 'security', 'wolverine', 'lee-research', 'lee-explicit', 'officer', 'scheduled')
LANDING = ('restack', 'red-gate-fix', 'returned-pr-fix', 'review')
# The classes that bypass the CI-slots cap (config/ci-slots): drain exemptions that carry real urgency or the
# captain's word, and the landing jobs, which open no new PR. wolverine, lee-research, officer and scheduled stay held.
SLOTS_EXEMPT = ('production-outage', 'cve', 'security', 'lee-explicit') + LANDING
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


def repo_of(project):
    """The clone's origin as owner/repo, or None when it is not on github.com."""
    # The configured URL first, then its insteadOf expansion, so either spelling of a GitHub origin counts.
    match = None
    for argv in (['config', '--get', 'remote.origin.url'], ['remote', 'get-url', 'origin']):
        origin = subprocess.run(['git', '-C', project, *argv], capture_output=True, text=True,
                                check=False).stdout.strip()
        match = match or ORIGIN.match(origin)
    return match.group(1) if match else None


def normal(pr):
    """One PR from `gh pr list --json` as the fields every count reads."""
    return {'number': pr.get('number'), 'createdAt': pr.get('createdAt'), 'closedAt': pr.get('closedAt'),
            'isDraft': bool(pr.get('isDraft')), 'url': pr.get('url') or '', 'head': pr.get('headRefName') or '',
            'body': pr.get('body') or '', 'promotion': pr.get('headRefName') == PROMOTION_HEAD,
            'labelHeld': any(label.get('name') == HELD_LABEL for label in pr.get('labels') or [])}


def open_prs(project):
    """(repo, [normalised open PRs]) for the clone's open PRs, or a one-line answer string:
    `unknown <owner/repo> <why>` when GitHub cannot be read, or `none` off github.com."""
    repo = repo_of(project)
    if not repo:
        return 'none'
    try:
        prs = gh(repo, '--state', 'open', '--limit', '1000', '--json', 'number,createdAt,isDraft,url,headRefName,labels,body')
        return repo, [normal(pr) for pr in prs]
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired, AttributeError) as error:
        return f'unknown {repo} GitHub unreadable: {error}'.replace('\n', ' ')


def fold_piles(prs):
    """(prs without the members a ready landing pile in the list carries, those members). A pile and its members are one
    landing unit, counted once as the pile: the pile is the PR that takes the CI slot (one exact-head gate on its merged
    tree), and its members wait in it unmerged. Before the pile existed each member counted on its own, so each carried
    member is returned with its closedAt set to when the earliest pile carrying it was created (or its own creation, when
    later). A draft pile folds nothing, a pile is never folded into another pile, and a number the list does not hold is
    ignored."""
    piles = [pr for pr in prs if pr['head'].startswith(PILE_HEAD)]
    carried = {}
    for pile in piles:
        if not pile['isDraft'] and not pile['promotion']:
            clause = MEMBERS.search(pile['body'])
            for n in {int(n) for n in MEMBER_REF.findall(clause.group(1))} if clause else set():
                if n not in carried or when(pile['createdAt']) < when(carried[n]):
                    carried[n] = pile['createdAt']
    for pile in piles:
        carried.pop(pile['number'], None)
    kept = [pr for pr in prs if pr['number'] not in carried]
    members = [dict(pr, closedAt=max(pr['createdAt'], carried[pr['number']], key=when))
               for pr in prs if pr['number'] in carried]
    return kept, members


def tally(project, prs):
    """The one count behind `state`, `open` and `gate`. Returns a dict: `units`, the eligible landing units (ready, not a
    promotion PR, not labelled held, not waiting for the captain, a pile and its members as the pile alone), and the
    counts left out of it: `drafts`, `promotion`, `held` (waiting for the captain, by a task record), `labelled`
    (labelled held, no record showing them waiting for the captain) and `folded` (members a pile carries). `held` and
    `labelled` PRs use no CI slot, so `units` is the CI-slot count (state and open); the open-PR cap counts them too, so
    `cap` (units + held + labelled) is the cap count (gate), by Lee's word of 2026-11-22. `carried` holds the folded
    members that were eligible on their own before their pile existed, closed at that pile's creation (state's walk-back)."""
    prs, members = fold_piles(prs)
    ready = [pr for pr in prs if not pr['isDraft'] and not pr['promotion']]
    held = held_urls(project, [pr['url'] for pr in ready]) if ready else set()
    units = [pr for pr in ready if pr['url'] not in held and not pr['labelHeld']]
    labelled = sum(1 for pr in ready if pr['labelHeld'] and pr['url'] not in held)
    return {'units': units, 'cap': len(units) + len(held) + labelled, 'drafts': sum(1 for pr in prs if pr['isDraft']),
            'held': len(held), 'promotion': sum(1 for pr in prs if pr['promotion'] and not pr['isDraft']),
            'labelled': labelled, 'folded': len(members),
            'carried': [pr for pr in members if not pr['isDraft'] and not pr['promotion'] and not pr['labelHeld']]}


def open_count(project):
    """The CI-slot count of the clone's repository, as one line like state: `open <owner/repo> <n>`."""
    found = open_prs(project)
    if isinstance(found, str):
        return found
    repo, prs = found
    return f"open {repo} {len(tally(project, prs)['units'])}"


def project_mode(flag, name):
    """What bin/fm-project-mode.sh answers for a project (S or the cap), or raises ValueError when it refuses."""
    out = subprocess.run([os.path.join(BIN, 'fm-project-mode.sh'), flag, name], stdin=subprocess.DEVNULL,
                         capture_output=True, text=True, check=False,
                         timeout=float(os.environ.get('FM_PR_DRAIN_TIMEOUT', 20)))
    if out.returncode:
        raise ValueError((out.stderr.strip().splitlines() or ['unreadable'])[0][:160])
    return out.stdout.strip()


def held_urls(project, urls):
    """The ready PR URLs that wait for the captain's merge word, an empty set when that cannot be read."""
    try:
        out = subprocess.run([os.path.join(BIN, 'fm-ci-slots-held.sh'), project], input='\n'.join(urls) + '\n',
                             capture_output=True, text=True, check=False,
                             timeout=float(os.environ.get('FM_PR_DRAIN_TIMEOUT', 20)))
        return set(out.stdout.split()) & set(urls) if not out.returncode else set()
    except (OSError, subprocess.TimeoutExpired):
        return set()


def gate(project, name):
    """The worker's CI slots check: `hold`, `open`, `unknown` or `none`, as one line."""
    found = open_prs(project)
    if isinstance(found, str):
        return found
    repo, prs = found
    try:
        slots = project_mode('--ci-slots', name)
        cap = project_mode('--open-pr-cap', name)
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        return f'unknown {repo} the CI slots declaration for {name} is unreadable: {error}'.replace('\n', ' ')
    if not slots:
        return f'open {repo}'
    seen = tally(project, prs)
    counted = seen['cap']
    if counted >= int(cap):
        return (f'hold {repo} open-PR cap reached: {counted} eligible open PR(s) against the open-PR cap of {cap} '
                f"(config/open-pr-cap; min(2 x {slots} CI slots, 16) unless declared; {seen['drafts']} draft PR(s) and "
                f"{seen['promotion']} promotion PR(s) are not counted; {seen['held']} PR(s) waiting for the captain's merge word and "
                f"{seen['labelled']} PR(s) labelled `{HELD_LABEL}` use no CI slot but are counted; "
                f"{seen['folded']} member PR(s) are counted in the landing pile that carries them); open no pull request until one merges or closes")
    return f'open {repo}'


def state(project, name=None):
    repo = repo_of(project)
    if not repo:
        return 'none'
    try:
        # The open read (no --search) proves the repository is readable; a search answers [] when it is not.
        found = open_prs(project)
        if isinstance(found, str):
            return found
        repo, prs = found
        seen = tally(project, prs)
        opened = seen['units'] + seen['carried']
        count = len(seen['units'])
        name = name or os.path.basename(os.path.abspath(project))
        try:
            # S when the project declares CI slots, else drain ends only at 0.
            floor = int(project_mode('--ci-slots', name) or 0)
        except (ValueError, OSError, subprocess.TimeoutExpired) as error:
            return f'unknown {repo} the CI slots declaration for {name} is unreadable: {error}'.replace('\n', ' ')
        if count >= THRESHOLD or count <= floor:
            return f"{'on' if count > floor else 'off'} {repo} {count}"
        since = datetime.now(timezone.utc) - timedelta(days=WINDOW_DAYS)
        closed = [pr for pr in gh(repo, '--state', 'closed', '--search', f"closed:>={since:%Y-%m-%dT%H:%M:%SZ}",
                                  '--limit', str(CLOSED_LIMIT), '--json', 'number,createdAt,closedAt,isDraft,headRefName,labels,body')]
        if len(closed) >= CLOSED_LIMIT:
            return f'unknown {repo} {CLOSED_LIMIT} or more PRs closed in {WINDOW_DAYS} days (the GitHub search cap)'
        # The same landing-unit rule as the open list: a closed pile and the members it carried count once.
        closed = [pr for pr in sum(fold_piles([normal(pr) for pr in closed]), [])
                  if not pr['isDraft'] and not pr['promotion'] and not pr['labelHeld']]
        steps = {}
        for pr in opened + closed:
            if when(pr['createdAt']) >= since:
                steps[when(pr['createdAt'])] = steps.get(when(pr['createdAt']), 0) - 1
            if pr['closedAt'] and when(pr['closedAt']) >= since:
                steps[when(pr['closedAt'])] = steps.get(when(pr['closedAt']), 0) + 1
        live = count
        # Events sharing one timestamp apply together, so a same-second open and close is no false peak or floor.
        for moment in sorted(steps, reverse=True):
            live += steps[moment]
            if live >= THRESHOLD or live <= floor:
                return f"{'on' if live > floor else 'off'} {repo} {count}"
        # shortcut: 14 days between S and 23 eligible open PRs is undecided; widen WINDOW_DAYS if that becomes common.
        return f'unknown {repo} eligible open count stayed between {floor + 1} and {THRESHOLD - 1} for {WINDOW_DAYS} days'
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
        request = urllib.request.Request(os.environ.get('FM_PR_DRAIN_LINEAR_URL', 'https://api.linear.app/graphql'),
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
    if len(sys.argv) in (3, 4) and sys.argv[1] == 'state':
        print(state(sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None))
    elif len(sys.argv) == 3 and sys.argv[1] == 'open':
        print(open_count(sys.argv[2]))
    elif len(sys.argv) in (3, 4) and sys.argv[1] == 'gate':
        print(gate(sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else os.path.basename(os.path.abspath(sys.argv[2]))))
    elif len(sys.argv) == 3 and sys.argv[1] == 'slots-class':
        sys.exit(0 if sys.argv[2] in SLOTS_EXEMPT else 2)
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
