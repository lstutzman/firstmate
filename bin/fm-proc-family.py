#!/usr/bin/env python3
"""Stop one worker's own process family, and nothing else.

Usage:
  fm-proc-family.py capture <pid>
  fm-proc-family.py stop <label> <root-pid> <root-identity>

The family boundary is the session a runtime backend created for the worker's
endpoint: every process whose session id is the recorded root pid, plus every
descendant of those processes. The root is a session leader, so processes that
outlive it (reparented to init) keep the session id and stay inside the
boundary. A pid cannot be reused while any process still carries it as a
session id, so a leaderless family is certain to be the original one; a live
root must also match its recorded start identity or nothing is signalled.

capture prints the root's start identity (one line, `starttime=<n>` on Linux or
`lstart=<text>` elsewhere) and exits 0 only when <pid> is alive and leads its
own session; any other pid exits 1 and prints nothing, because no boundary can
be proved for it.

stop sends TERM to the family, waits FM_PROC_FAMILY_GRACE seconds (default 2),
then KILLs whatever of that family is still alive and still has the identity it
had when it was found. Each signalled pid is re-checked just before the signal.
Never signalled: this process, its process group and its ancestors, pid 1 and below, and shared
infrastructure a worker can start from its own pane (the no-mistakes daemon,
Colima and Docker, terminal multiplexers, Herdr, Treehouse) with everything
under it. Exit 0: stopped, or nothing to stop. Exit 3: no boundary (the root
was recorded as unusable). Exit 4: the stop refused (the caller is itself
inside the family, or the live root is a different process than recorded).
Everything but the exit code goes to stderr; stdout carries only capture's
identity.
"""
import os
import re
import signal
import subprocess
import sys
import time

# Shared infrastructure that can be started from a worker's pane but is never
# the worker's own process: AGENTS.md rule 7 and the harness safety rules.
PROTECTED = re.compile(
    r'^(no-mistakes|colima|limactl|lima|dockerd|docker|containerd|herdr|tmux|zellij|treehouse)(\.exe)?$')


def identity(pid):
    """Start identity of pid, or None when it is not alive or unreadable."""
    try:
        with open(f'/proc/{pid}/stat') as stat:
            fields = stat.read().rsplit(')', 1)[1].split()
        return f'starttime={fields[19]}' if len(fields) >= 20 and fields[19].isdigit() else None
    except OSError:
        if os.path.isdir('/proc/self'):
            return None
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart='], capture_output=True,
                            text=True, env={**os.environ, 'LC_ALL': 'C'}, check=False)
    text = result.stdout.strip()
    return f'lstart={text}' if result.returncode == 0 and text else None


def table():
    """{pid: (ppid, command basename)} from one ps read."""
    result = subprocess.run(['ps', '-A', '-ww', '-o', 'pid=,ppid=,comm='], capture_output=True,
                            text=True, check=False)
    rows = {}
    for line in result.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows[int(parts[0])] = (int(parts[1]), os.path.basename(parts[2].strip()))
    return rows


def sid_of(pid):
    try:
        return os.getsid(pid)
    except OSError:
        return None


def pgid_of(pid):
    try:
        return os.getpgid(pid)
    except OSError:
        return None


def ancestors(rows, pid):
    chain = set()
    while pid > 1 and pid not in chain:
        chain.add(pid)
        pid = rows.get(pid, (0, ''))[0]
    return chain


def family(rows, root):
    """Pids of the session led by root plus their descendants, minus protected infrastructure."""
    members = {pid for pid in rows if sid_of(pid) == root}
    children = {}
    for pid, (ppid, _) in rows.items():
        children.setdefault(ppid, []).append(pid)

    def below(seeds):
        found, queue = set(seeds), list(seeds)
        while queue:
            for child in children.get(queue.pop(), ()):
                if child not in found:
                    found.add(child)
                    queue.append(child)
        return found

    everyone = below(members)
    shielded = below({pid for pid in everyone if PROTECTED.match(rows[pid][1])})
    return everyone - shielded


def capture(pid):
    if pid <= 1 or sid_of(pid) != pid:
        return 1
    found = identity(pid)
    if found is None:
        return 1
    print(found)
    return 0


def say(text):
    print(text, file=sys.stderr)


def stop(label, root, recorded):
    if root <= 1:
        return 3
    rows = table()
    own = ancestors(rows, os.getpid())
    if sid_of(os.getpid()) == root:
        say(f'teardown: refusing to stop the {label} process family: this process runs inside session {root}')
        return 4
    if root in rows:
        if identity(root) != recorded:
            say(f'teardown: refusing to stop the {label} process family: pid {root} is no longer the recorded '
                'session root (the pid was reused)')
            return 4
    found = {pid for pid in family(rows, root) if pid > 1}
    if found & own:
        # An ancestor of this process (the supervisor, a wrapper) is inside the family, so
        # the boundary cannot be told apart from the caller: signal nothing.
        say(f'teardown: refusing to stop the {label} process family: this process descends from it')
        return 4
    own_group = pgid_of(os.getpid())
    members = sorted(pid for pid in found if pgid_of(pid) not in (None, own_group))
    if not members:
        return 0
    seen = {pid: identity(pid) for pid in members}
    say(f'teardown: stopping the {label} process family (session {root}): {" ".join(map(str, members))}')

    def signal_all(sig):
        for pid in members:
            if seen[pid] is not None and identity(pid) == seen[pid]:
                try:
                    os.kill(pid, sig)
                except OSError:
                    pass

    signal_all(signal.SIGTERM)
    deadline = time.monotonic() + float(os.environ.get('FM_PROC_FAMILY_GRACE', '2'))
    while time.monotonic() < deadline and any(
            seen[pid] is not None and identity(pid) == seen[pid] for pid in members):
        time.sleep(0.1)
    left = [pid for pid in members if seen[pid] is not None and identity(pid) == seen[pid]]
    if left:
        say(f'teardown: force-killing the {label} process family: {" ".join(map(str, left))}')
        signal_all(signal.SIGKILL)
    return 0


def main(argv):
    try:
        if len(argv) == 3 and argv[1] == 'capture':
            return capture(int(argv[2]))
        if len(argv) == 5 and argv[1] == 'stop':
            return stop(argv[2], int(argv[3]), argv[4])
    except ValueError:
        pass
    say((__doc__ or '').split('\n\n')[0])
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
