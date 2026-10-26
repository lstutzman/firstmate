#!/usr/bin/env python3
"""Quota and secondmate alarm; no endpoint control or second fleet watcher.

Usage: fm-fleet-alarm.py check | timer | arm | timer-files <linux|darwin> <dir>
FM_HOME selects the primary home. config/fleet-alarm.json accepts seven_day
(default .9), pool_remaining (.1, mean remaining weekly capacity), silent_minutes
(60), stale_minutes (120), and budget_seconds (24). cpa-usage-host selects local
or SSH quota reads, as in dispatch resolution. A missing host uses local CLI.
Both readers share FM_CHECK_TIMEOUT (default 30); budget must leave 5 seconds.
The snapshot reader owns registered-home selection and remote ledger collection.
One alert per condition/reset window, rearmed on clear. check and timer share a
locked record, but independent delivery receipts, so a check cannot consume the
timer's Captain's Log notification. timer requires config/fleet-ledger enabled.
arm registers the private check shim. timer-files only writes scheduler files;
it never loads or starts a scheduler. See docs/configuration.md for installation.
"""
import csv
import fcntl
import io
import json
import math
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import time

BIN = Path(__file__).resolve().parent
HOME = Path(os.environ.get('FM_HOME', BIN.parent)).resolve()
STATE = Path(os.environ.get('FM_STATE_OVERRIDE', HOME / 'state'))
CONFIG = Path(os.environ.get('FM_CONFIG_OVERRIDE', HOME / 'config'))
ID = 'fleet-alarm'
RETIRED_MINUTES = 7 * 24 * 60


def run(argv, seconds):
    # Reuse the repository's process-tree timeout implementation on all platforms.
    result = subprocess.run(
        ['bash', '-c', '. "$1/fm-timeout-lib.sh"; shift; fm_run_timed "$@"',
         'fleet-alarm', str(BIN), str(seconds), *map(str, argv)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, check=False)
    if result.returncode:
        raise ValueError('reader unavailable or timed out')
    return result.stdout


def settings():
    values = dict(seven_day=.9, pool_remaining=.1, silent_minutes=60,
                  stale_minutes=120, budget_seconds=24)
    path = CONFIG / 'fleet-alarm.json'
    if path.exists():
        supplied = json.loads(path.read_text())
        if not isinstance(supplied, dict) or set(supplied) - set(values):
            raise ValueError('unknown fleet-alarm configuration')
        values.update(supplied)
    for key, value in values.items():
        if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
            raise ValueError('invalid fleet-alarm configuration')
        if key in ('seven_day', 'pool_remaining') and value > 1:
            raise ValueError('quota thresholds must be fractions')
    if values['budget_seconds'] > float(os.environ.get('FM_CHECK_TIMEOUT', 30)) - 5:
        raise ValueError('budget_seconds must fit inside FM_CHECK_TIMEOUT minus 5')
    return values


def accounts(text):
    lines = text.splitlines()
    header = next((line for line in lines if line.startswith('accounts[')), None)
    if header is None:
        raise ValueError('no accounts header in quota reading')
    fields = header.split('{', 1)[1].split('}', 1)[0].split(',')
    rows = list(csv.DictReader(io.StringIO('\n'.join(
        line.strip() for line in lines[lines.index(header) + 1:]
        if line.startswith('  '))), fieldnames=fields))
    claude = [row for row in rows if row.get('provider') == 'claude']
    if not claude:
        raise ValueError('no Claude quota readings')
    for row in claude:
        for field in ('used_7d', 'age_min'):
            if row[field] == '':
                row[field] = None
                continue
            row[field] = float(row[field])
            value = row[field]
            if not math.isfinite(value) or value < 0 or (field == 'used_7d' and value > 1):
                raise ValueError('invalid quota reading')
    return claude


def collect(cfg):
    findings = {}
    deadline = time.monotonic() + cfg['budget_seconds']

    def read(argv, share=1):
        remaining = deadline - time.monotonic()
        if remaining < 1:
            raise ValueError('reader budget exhausted')
        return run(argv, max(1, int(remaining / share)))

    host = read(['bash', '-c', '. "$1/fm-env-lib.sh"; fm_config_line "$2" cpa-usage-host',
                 'fleet-alarm', BIN, CONFIG]).rstrip('\n') or 'local'
    if host == 'local' or host == os.uname().nodename.split('.')[0]:
        cpa = ['cpa-usage-axi']
    elif host and all(c.isalnum() or c in '.@_-' for c in host) and not host.startswith('-'):
        cpa = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3', '--', host,
               'cpa-usage-axi']
    else:
        raise ValueError('invalid cpa-usage-host')
    try:
        rows = accounts(read([*cpa, 'accounts'], 3))
        # The tool owns threshold evaluation, including reset rollover handling.
        threshold = read([*cpa, 'check', '--five-hour', 'off', '--seven-day',
                          str(cfg['seven_day'])], 2).strip()
        alerts = threshold[len('alert: '):].split('; ') if threshold.startswith('alert: ') else []
        pool, ignored = [], 0
        for row in rows:
            name = row['account']
            if row['age_min'] is None or row['used_7d'] is None:
                findings['stale:' + name] = f'Claude quota reading unknown: {name}'
                continue
            if row['age_min'] >= RETIRED_MINUTES:
                ignored += 1
                continue
            pool.append(row['used_7d'])
            if row['age_min'] >= cfg['stale_minutes']:
                findings['stale:' + name] = f'Claude quota reading stale: {name}'
            alert = next((item for item in alerts if item.startswith(name + ' 7d ')), None)
            if alert:
                key = 'quota:' + name + ':' + row['reset_7d']
                findings[key] = alert
        if ignored:
            findings[f'ignored:{ignored}'] = f'{ignored} ignored stale Claude accounts (no reading for 7 days)'
        if not pool:
            raise ValueError('no current Claude quota readings')
        if sum(1 - used for used in pool) / len(pool) <= cfg['pool_remaining']:
            findings['pool'] = 'Claude pool near empty'
    except (ValueError, KeyError, OSError) as error:
        findings['quota-read'] = f'Claude quota unavailable; reading may be stale: {type(error).__name__}: {error}'
    try:
        snapshot = json.loads(read([BIN / 'fm-fleet-snapshot.sh', '--json']))
        mates = snapshot['secondmate_current']
        if mates.get('truncated', 0) or mates.get('registry', {}).get('complete') is not True:
            findings['mate-read'] = 'Secondmate work inventory incomplete'
        for mate in mates['records']:
            if mate.get('registered') is not True:
                continue
            counts = mate['counts']
            holding = any(counts.get(k, 0) > 0 for k in ('in_flight', 'active_children', 'decisions_open', 'holds'))
            holding = holding or bool(mate.get('parent_event', {}).get('open_decisions'))
            if mate.get('current', {}).get('state') == 'unknown':
                findings['mate-read:' + mate['id']] = f"Secondmate work inventory unavailable: {mate['id']}"
            if not holding:
                continue
            ages = [mate.get('parent_event', {}).get('agent_age_seconds')]
            spawn = str(mate.get('spawn_gen') or '')
            if spawn.startswith('s') and spawn[1:].split('.', 1)[0].isdigit():
                ages.append(time.time() - int(spawn[1:].split('.', 1)[0]))
            ages = [a for a in ages if isinstance(a, (int, float)) and a >= 0]
            if not ages or min(ages) > cfg['silent_minutes'] * 60:
                findings['silent:' + mate['id']] = f"Secondmate holding work silent over {cfg['silent_minutes']:g} minutes: {mate['id']}"
    except (ValueError, KeyError, TypeError, OSError) as error:
        findings['mate-read'] = f'Secondmate work inventory unavailable: {type(error).__name__}: {error}'
    return findings


def check(channel):
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / '.fleet-alarm.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        record = STATE / '.fleet-alarm.json'
        stored = json.loads(record.read_text()) if record.exists() else {}
        old = stored.get('conditions', {})
        timer_open = stored.get('timer_open', False)
        try:
            current = collect(settings())
        except (ValueError, OSError) as error:
            current = {'config': f'Fleet alarm configuration invalid: {error}'}
        fresh = {key: value for key, value in current.items()
                 if channel not in old.get(key, [])}
        # An unavailable reader does not prove that its previous alarms cleared.
        preserved = {key: receipts for key, receipts in old.items()
                     if ('config' in current
                         or ('quota-read' in current and key.startswith(('quota:', 'stale:', 'pool', 'ignored:')))
                         or ('mate-read' in current and key.startswith(('silent:', 'mate-read:')))
                         or (key.startswith('silent:') and 'mate-read:' + key[7:] in current))}
        alarms = [key for key in current if not key.startswith('ignored:')]
        cleared = channel == 'timer' and not alarms and timer_open
        if (fresh if channel == 'check' else set(fresh) & set(alarms)) or cleared:
            text = '; '.join((current if channel == 'timer' else fresh).values()).replace('\n', ' ')
            if channel == 'timer':
                if not (CONFIG / 'fleet-ledger').exists():
                    raise ValueError('timer requires config/fleet-ledger for Captain\'s Log delivery')
                with (STATE / 'fleet-alarm.status').open('a') as status:
                    verb = 'resolved' if cleared else 'needs-decision'
                    text = 'Fleet alarm conditions cleared' if cleared else text
                    status.write(f'{verb} [at={int(time.time())}] [key=fleet-alarm]: {text}\n')
                run([BIN / 'fm-fleet-ledger.sh', 'appended', CONFIG,
                     STATE / 'fleet-alarm.status'], 3)
                timer_open = not cleared
            else:
                print(text)
        new = {key: sorted(set(old.get(key, [])) | ({channel} if key in fresh else set()))
               for key in current}
        new.update(preserved)
        with tempfile.NamedTemporaryFile(mode='w', dir=STATE, prefix='.fleet-alarm-', delete=False) as file:
            json.dump({'conditions': new, 'timer_open': timer_open}, file)
            temporary = file.name
        os.replace(temporary, record)


def setup(action):
    command = [sys.executable, str(Path(__file__).resolve()), 'timer']
    if action == 'arm':
        STATE.mkdir(parents=True, exist_ok=True)
        shim = STATE / 'fleet-alarm.check.sh'
        if shim.exists() or shim.is_symlink():
            raise ValueError('check already exists; unregister it before arming again')
        with shim.open('x') as file:
            file.write('#!/usr/bin/env bash\nexport FM_HOME=' + shlex.quote(str(HOME)) +
                       '\nexec ' + shlex.join(command[:-1] + ['check']) + '\n')
        shim.chmod(0o700)
        subprocess.run([BIN / 'fm-check-register.sh', ID], check=True)
        return
    platform, directory = sys.argv[2:]
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    environment = {'FM_HOME': str(HOME), 'PATH': os.environ['PATH']}
    if platform == 'darwin':
        value = dict(Label='com.firstmate.fleet-alarm', ProgramArguments=command,
                     EnvironmentVariables=environment, StartInterval=300, RunAtLoad=True)
        with (directory / 'com.firstmate.fleet-alarm.plist').open('xb') as file:
            plistlib.dump(value, file)
    elif platform == 'linux':
        def quote(value):
            return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'
        service = '[Service]\nType=oneshot\n' + ''.join(
            'Environment=' + quote(k + '=' + v) + '\n' for k, v in environment.items())
        service += 'ExecStart=' + ' '.join(quote(v) for v in command) + '\n'
        with (directory / 'firstmate-fleet-alarm.service').open('x') as file:
            file.write(service)
        with (directory / 'firstmate-fleet-alarm.timer').open('x') as file:
            file.write('[Timer]\nOnBootSec=1min\nOnUnitActiveSec=5min\n'
                       '[Install]\nWantedBy=timers.target\n')
    else:
        raise ValueError('platform must be linux or darwin')


if __name__ == '__main__':
    os.umask(0o077)
    try:
        action = sys.argv[1]
        if action in ('check', 'timer') and len(sys.argv) == 2:
            check(action)
        elif (action == 'arm' and len(sys.argv) == 2) or (action == 'timer-files' and len(sys.argv) == 4):
            setup(action)
        else:
            raise ValueError(__doc__)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'fleet-alarm: {error}', file=sys.stderr)
        sys.exit(1)
