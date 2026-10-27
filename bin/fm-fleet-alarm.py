#!/usr/bin/env python3
"""Quota and secondmate alarm; no endpoint control or second fleet watcher.

Usage: fm-fleet-alarm.py check | timer | arm | timer-files <linux|darwin> <dir>
FM_HOME selects the primary home. config/fleet-alarm.json accepts seven_day
(default .9, carrying-account threshold), pool_remaining (.1, mean remaining
weekly capacity across non-stale Claude readings), silent_minutes
(60), stale_minutes (120), and budget_seconds (24). cpa-usage-host selects local
or SSH quota reads, as in dispatch resolution. A missing host uses local CLI.
Both readers share FM_CHECK_TIMEOUT (default 30); budget must leave 5 seconds.
Secondmate inventory reads published home summaries (bounded remote reads fall
back to the parent cache); no full fleet snapshot runs here. Unreachable homes
without usable cached inventory are recorded quietly as not_collected.
Partial child observations retain independently complete in-flight counts;
other incomplete inventories alert with their reason.
Registry and summary inputs are bounded at 64/256 KiB.
Parent-channel age uses the shared classifier, excluding parent appends.
One alert per condition/reset window, rearmed on clear. check and timer share a
locked record, but independent delivery receipts, so a check cannot consume the
timer's Captain's Log notification. timer requires config/fleet-ledger enabled.
arm registers the private check shim. timer-files only writes scheduler files;
it never loads or starts a scheduler. See docs/configuration.md for installation.
"""
import csv
import hashlib
from datetime import datetime, timedelta
from decimal import Decimal
import fcntl
import io
import json
import math
import os
from pathlib import Path
import plistlib
import re
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


class ReaderUnavailable(ValueError):
    def __init__(self, returncode):
        super().__init__('reader unavailable or timed out')
        self.returncode = returncode


def run(argv, seconds):
    # Reuse the repository's process-tree timeout implementation on all platforms.
    result = subprocess.run(
        ['bash', '-c', '. "$1/fm-timeout-lib.sh"; shift; fm_run_timed "$@"',
         'fleet-alarm', str(BIN), str(seconds), *map(str, argv)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, check=False)
    if result.returncode:
        raise ReaderUnavailable(result.returncode)
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


def table(text, name):
    lines = text.splitlines()
    header = next((line for line in lines if line.startswith(name + '[')), None)
    if header is None:
        raise ValueError('no ' + name + ' header in quota reading')
    fields = header.split('{', 1)[1].split('}', 1)[0].split(',')
    return list(csv.DictReader(io.StringIO('\n'.join(
        line.strip() for line in lines[lines.index(header) + 1:]
        if line.startswith('  '))), fieldnames=fields))


def accounts(text):
    rows = table(text, 'accounts')
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


def read_json(path, limit=262144):
    if path.is_symlink() or not path.is_file():
        raise ValueError('inventory is not a regular file')
    with path.open() as file:
        content = file.read(limit + 1)
    if len(content.encode()) > limit:
        raise ValueError('inventory exceeds byte limit')
    return json.loads(content)


def mate_findings(read, cfg, not_collected):
    findings = {}
    registry = Path(os.environ.get('FM_DATA_OVERRIDE', HOME / 'data')) / 'secondmates.md'
    if not registry.exists():
        return findings
    if registry.is_symlink() or not registry.is_file() or registry.stat().st_size > 65536:
        raise ValueError('unsafe or oversized secondmate registry')
    # The shared parser owns the registry grammar and the classifier owns which
    # parent-channel events count as the secondmate speaking.
    roster = read(['bash', '-c', r'''
. "$1/fm-secondmate-registry-lib.sh"
. "$1/fm-classify-lib.sh"
window=$(mktemp) || exit 1
trap 'rm -f "$window"' EXIT
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "- "*)
      secondmate_registry_parse_line "$line" || exit 1
      id=$SECONDMATE_REGISTRY_ID
      age=$(status_agent_event_age "$3/$id.status" "$3/$id.status" "$4") || exit 1
      : > "$window"
      if [ -f "$3/$id.status" ] && [ ! -L "$3/$id.status" ]; then
        size=$(LC_ALL=C wc -c < "$3/$id.status") || exit 1
        LC_ALL=C tail -c 65536 "$3/$id.status" | LC_ALL=C awk -v cut=$((size > 65536)) 'NR > cut' \
          | LC_ALL=C tail -n 200 > "$window" || exit 1
      fi
      open=$(status_open_decisions "$window" secondmate | LC_ALL=C awk -F '\t' '$2 == "needs-decision" || $2 == "blocked"' | LC_ALL=C wc -l | tr -d ' ')
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$SECONDMATE_REGISTRY_HOST" "$SECONDMATE_REGISTRY_HOME" "$age" "$open"
      ;;
  esac
done < "$2"
''', 'fleet-alarm', BIN, registry, STATE, str(int(time.time()))])
    seen = set()
    routes = list(csv.reader(io.StringIO(roster), delimiter='\t'))
    for index, row in enumerate(routes):
        name, host, home, age, open_decisions = row
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name) or name in seen or not Path(home).is_absolute():
            raise ValueError('invalid or duplicate secondmate route')
        seen.add(name)
        if len(seen) > 40:
            raise ValueError('secondmate inventory incomplete: too many records')
        if host:
            digest = hashlib.sha256(f'{name}\n{host}\n{home}\n'.encode()).hexdigest()
            cache = Path(os.environ.get('FM_SNAPSHOT_CACHE_DIR', STATE / 'secondmate-summary-cache'))
            path = cache / (digest + '.json')
        else:
            path = Path(home) / 'state/home-summary.json'
        remote_unavailable = False
        try:
            if host:
                try:
                    summary = json.loads(read([BIN / 'fm-on.sh', name, 'fm-remote-file.sh',
                                               'get', 'state/home-summary.json', '262144'],
                                              len(routes) - index + 1))
                except ReaderUnavailable as error:
                    remote_unavailable = error.returncode in (124, 137, 255)
                    if not remote_unavailable:
                        raise ValueError(f'remote summary reader failed with exit {error.returncode}') from error
                    summary = read_json(path)
            else:
                summary = read_json(path)
            if (summary['schema'] != 'fm-secondmate-home-summary.v1'
                    or summary['hold_classifier_schema'] != 'fm-captain-hold-buckets.v1'
                    or summary['home'] != home or type(summary['valid']) is not bool):
                raise ValueError('invalid cached home summary')
            generated = summary['generated_epoch']
            if (type(generated) not in (int, float) or not math.isfinite(generated)
                    or generated < 0 or max(0, time.time() - generated) >= cfg['stale_minutes'] * 60):
                raise ValueError('cached home summary is stale or invalid')
            counts = summary['counts']
            if not isinstance(counts, dict):
                raise ValueError('invalid work counts')
            work = [counts.get('in_flight', 0), counts['active_children'], counts['decisions_open'], counts['holds']]
            if any(type(n) is not int or n < 0 for n in work):
                raise ValueError('invalid work counts')
            invalidity = summary.get('invalidity')
            partial_counts = (isinstance(invalidity, dict)
                              and invalidity.get('kind') == 'child_current_unavailable'
                              and 'in_flight' in counts)
            if not summary['valid'] and not partial_counts:
                reason = summary.get('reason')
                if not isinstance(reason, str) or not reason.strip():
                    reason = 'no completeness reason supplied'
                raise ValueError('home inventory incomplete: ' + reason[:500])
            # The fallback is usable; later local metadata errors must still alert.
            remote_unavailable = False
            if not any(work) and open_decisions == '0':
                continue
            ages = [] if age == 'null' else [float(age)]
            meta = STATE / (name + '.meta')
            if meta.exists():
                if meta.stat().st_size > 65536 or meta.is_symlink():
                    raise ValueError('unsafe or oversized task metadata')
                spawn = ''
                for line in meta.read_text().splitlines():
                    if line.startswith('spawn_gen='):
                        spawn = line.split('=', 1)[1]
                match = re.match(r'^s([0-9]+)(?:\.|$)', spawn)
                if match:
                    ages.append(time.time() - int(match[1]))
            ages = [a for a in ages if math.isfinite(a) and a >= 0]
            if not ages or min(ages) > cfg['silent_minutes'] * 60:
                findings['silent:' + name] = f"Secondmate holding work silent over {cfg['silent_minutes']:g} minutes: {name}"
        except (ValueError, KeyError, TypeError, OSError) as error:
            if remote_unavailable:
                not_collected[name] = f'remote summary not collected: {error}'
            else:
                findings['mate-read:' + name] = f'Secondmate work inventory unavailable: {name}: {error}'
    return findings


def collect(cfg):
    findings = {}
    not_collected = {}
    quota_info = ''
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
        traffic = table(read([*cpa, 'models', '--hours', '1', '--limit', '1000'], 2), 'models')
        carrying = set()
        for row in traffic:
            requests, failed = int(row['requests']), int(row['failed'])
            if not 0 <= failed <= requests:
                raise ValueError('invalid traffic counts')
            if row['model'].startswith('claude-') and requests > failed:
                carrying.add(row['account'])
        pressure = ', '.join(f"{row['account']} 7d {row['used_7d']:.0%}"
                             for row in rows if row['used_7d'] is not None
                             and (row['age_min'] is None or row['age_min'] < RETIRED_MINUTES))
        carriers = ', '.join(sorted(carrying)) if carrying else 'none (no successful Claude traffic in last 60 minutes)'
        quota_info = f'Claude account pressure: {pressure}; Carrying Claude accounts: {carriers}'
        pool, ignored = [], 0
        for row in rows:
            name = row['account']
            if row['age_min'] is None or row['used_7d'] is None:
                findings['stale:' + name] = f'Claude quota reading unknown: {name}'
                continue
            if row['age_min'] >= RETIRED_MINUTES:
                ignored += 1
                continue
            if row['age_min'] >= cfg['stale_minutes']:
                findings['stale:' + name] = f'Claude quota reading stale: {name}'
            else:
                pool.append(row['used_7d'])
            if name in carrying and row['used_7d'] > cfg['seven_day']:
                reset = row['reset_7d']
                # cpa-usage-axi's reset time drifts a minute between reads; key on the nearest hour.
                try:
                    rounded = datetime.fromisoformat(reset.replace('Z', '+00:00')) + timedelta(minutes=30)
                    reset = rounded.replace(minute=0, second=0, microsecond=0).isoformat()
                except ValueError:
                    pass
                key = 'quota:' + name + ':' + reset
                findings[key] = f"Carrying Claude account {name} 7d {row['used_7d']:.0%} (resets {row['reset_7d']})"
        if ignored:
            findings[f'ignored:{ignored}'] = f'{ignored} ignored stale Claude accounts (no reading for 7 days)'
        # Compare decimal quota fractions so exactly 10% remaining is not below 10%.
        if pool and sum(1 - Decimal(str(used)) for used in pool) / len(pool) < Decimal(str(cfg['pool_remaining'])):
            findings['pool'] = 'Claude pool near empty'
    except (ValueError, KeyError, OSError) as error:
        findings['quota-read'] = f'Claude quota unavailable; reading may be stale: {type(error).__name__}: {error}'
    try:
        findings.update(mate_findings(read, cfg, not_collected))
    except (ValueError, KeyError, TypeError, OSError) as error:
        findings['mate-read'] = f'Secondmate work inventory unavailable: {type(error).__name__}: {error}'
    return findings, quota_info, not_collected


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
            current, quota_info, not_collected = collect(settings())
        except (ValueError, OSError) as error:
            current = {'config': f'Fleet alarm configuration invalid: {error}'}
            quota_info = ''
            not_collected = {}
        fresh = {key: value for key, value in current.items()
                 if channel not in old.get(key, [])}
        # An unavailable reader does not prove that its previous alarms cleared.
        preserved = {key: receipts for key, receipts in old.items()
                     if ('config' in current
                         or ('quota-read' in current and key.startswith(('quota:', 'stale:', 'pool', 'ignored:')))
                         or ('mate-read' in current and key.startswith(('silent:', 'mate-read:')))
                         or (key.startswith('silent:') and 'mate-read:' + key[7:] in current)
                         or (key.startswith(('silent:', 'mate-read:'))
                             and key.split(':', 1)[1] in not_collected))}
        alarms = [key for key in current if not key.startswith('ignored:')]
        cleared = channel == 'timer' and not alarms and timer_open and not preserved
        if (fresh if channel == 'check' else set(fresh) & set(alarms)) or cleared:
            details = list((current if channel == 'timer' else fresh).values())
            if quota_info:
                details.append(quota_info)
            text = '; '.join(details).replace('\n', ' ')
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
            json.dump({'conditions': new, 'timer_open': timer_open,
                       'not_collected': not_collected}, file)
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
