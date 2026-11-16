#!/usr/bin/env python3
"""PR-drain state of one project's GitHub repository (the captain's open-PR drain rule).

Usage: fm-pr-drain.py state <project-dir>
       fm-pr-drain.py class <value>
       fm-pr-drain.py evidence <brief-file>

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
cve, wolverine, lee-research, lee-explicit, officer, scheduled) or a landing job (restack,
red-gate-fix, returned-pr-fix, review), and 2 otherwise. bin/fm-brief.sh --pr-drain writes it into a
brief and bin/fm-spawn.sh reads it back.
evidence exits 0 when the brief's `## Captain's intent` section holds a quoted captain instruction
with a timestamp, the proof a `lee-explicit` brief needs: at least one double-quoted span, and an
ISO-8601 UTC timestamp (YYYY-MM-DDTHH:MM:SSZ) on the same line as a quote or on the line before it.
It exits 2 and names what is missing otherwise. It does not check that the quote is real.
"""
from datetime import datetime, timedelta, timezone
import json
import os
import re
import subprocess
import sys

THRESHOLD = 20
WINDOW_DAYS = 14
CLOSED_LIMIT = 1000
EXEMPT = ('production-outage', 'cve', 'wolverine', 'lee-research', 'lee-explicit', 'officer', 'scheduled')
LANDING = ('restack', 'red-gate-fix', 'returned-pr-fix', 'review')
STAMP = re.compile(r'\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?Z\b')
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


def evidence(brief):
    """What a lee-explicit brief's `## Captain's intent` section lacks, as a list (empty when complete)."""
    lines, inside = [], False
    with open(brief, encoding='utf-8') as handle:
        for line in handle:
            if line.startswith('## '):
                inside = line.strip() == "## Captain's intent"
            elif line.startswith('# '):
                inside = False
            elif inside:
                lines.append(line.rstrip('\n'))
    if not lines:
        return ["a '## Captain's intent' section"]
    quoted = [i for i, line in enumerate(lines) if QUOTE.search(line)]
    if not quoted:
        return ['a double-quoted captain instruction']
    if not any(STAMP.search(lines[i]) or (i and STAMP.search(lines[i - 1])) for i in quoted):
        return ['an ISO-8601 UTC timestamp (for example 2026-11-16T18:19:06Z) on the quote line or the line before it']
    return []


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'state':
        print(state(sys.argv[2]))
    elif len(sys.argv) == 3 and sys.argv[1] == 'class':
        sys.exit(0 if sys.argv[2] in EXEMPT + LANDING else 2)
    elif len(sys.argv) == 3 and sys.argv[1] == 'evidence':
        try:
            missing = evidence(sys.argv[2])
        except OSError as error:
            missing = [f'a readable brief ({error})']
        if missing:
            print('lee-explicit needs, in the brief\'s "## Captain\'s intent" section: ' + '; '.join(missing), file=sys.stderr)
            sys.exit(2)
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
