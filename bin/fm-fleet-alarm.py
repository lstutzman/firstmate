#!/usr/bin/env python3
"""Quota and secondmate alarm; no endpoint control or second fleet watcher.

Usage: fm-fleet-alarm.py check | timer | arm | timer-files <linux|darwin> <dir>
FM_HOME selects the primary home. config/fleet-alarm.json accepts seven_day
(default .9, carrying-account threshold), pool_remaining (.1, mean remaining
weekly capacity across non-stale Claude readings), silent_minutes
(60), stale_minutes (120), persist_polls (2), budget_seconds (24), carrying_reset_hours (6),
carrying_pool_floor (.4), and working_ceiling_multiple (6). cpa-usage-host selects local
or SSH quota reads, as in dispatch resolution. A missing host uses local CLI.
Both readers share FM_CHECK_TIMEOUT (default 30); budget must leave 5 seconds.
Secondmate inventory reads published home summaries (bounded remote reads fall
back to the parent cache); no full fleet snapshot runs here. Unreachable homes
without usable cached inventory are recorded quietly as not_collected.
Partial child observations retain independently complete in-flight counts;
other incomplete inventories alert with their reason, but only after the same
inventory finding appears in persist_polls consecutive polls of a channel, so
an item missing on one poll and back on the next raises nothing.
The timer's needs-decision line carries a [cause=...] tag (bin/fm-classify-lib.sh
status_line_cause owns the vocabulary): decision for quota pressure, tool for an
unreadable reader or inventory. A silent secondmate is external: a paused wait line
naming the secondmate and an `until` recheck time stale_minutes ahead, not a question.
A wait still silent at its recheck time is re-emitted once, on the next timer poll, as
needs-decision [cause=external] naming the secondmate, how long it has been down and
the recovery it was expected by, even when its home is unreadable by then; it
resolves when the condition clears.
A secondmate whose own latest line is `working`, or `paused` with no `until` time, younger than
working_ceiling_multiple (6) times silent_minutes, or `paused` with an `until` time less than
silent_minutes past, while it holds work (in flight, an active child or a parked child), has asked main
nothing open, and has no status-source ask (one on a task it also holds as a captain-hold row
does not count) and a complete decision list, is working a long task and
is not silent either.
A secondmate waiting on an open captain decision is healthy waiting and is never silent: no
open decision row has source status unless the mate also holds that task id as a captain-hold row
(no child is asking it anything), its
decision list is complete and holds at least one captain-hold row, and its summary is valid or its
only invalidity is kind child_current_unavailable. Its in-flight count need not be covered by held
or parked work then, and a live worker beside the hold does not change that. Any status-source ask
on a task with no captain-hold row of the same id, a truncated decision list, any other
invalidity kind, or in-flight work with no open captain decision still alarms. A child ask on a
task the mate holds for the captain is suppressed for as long as that hold is open, including a
later, unrelated ask from the same child.
The Claude quota context line shows the proxy's view: the accounts serving now (successful Claude
traffic in the last 15 minutes, from `cpa-usage-axi models --hours 0.25`), pooled 7d headroom across
non-stale accounts, and accounts over the seven_day threshold labelled rotated out. A carrying
account (successful traffic in the last 60 minutes) over seven_day raises a quota decision only when
no non-stale account under the threshold is serving; once the proxy has rotated, nothing needs the
captain. The line is appended only to
cards whose alarms include a quota alarm (quota:, stale:, pool, ignored:, quota-read); on other
alarms it is left off.
A carrying-account finding alarms once. While its weekly reset is within carrying_reset_hours
and mean remaining weekly capacity across non-stale readings stays above carrying_pool_floor,
later polls neither repeat it nor list it on other alarms. It re-alerts when either condition
stops holding, and the pool-near-empty alarm is unaffected.
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
# First matching prefix of a current alarm names the cause on the timer's needs-decision line.
CAUSES = (('quota:', 'decision'), ('pool', 'decision'), ('silent:', 'external'), ('stale:', 'tool'),
          ('quota-read', 'tool'), ('mate-read', 'tool'), ('config', 'tool'))


def cause_of(alarms):
    return next((cause for prefix, cause in CAUSES if any(key.startswith(prefix) for key in alarms)), 'tool')


def is_inventory(key):
    return key == 'mate-read' or key.startswith('mate-read:')
SERVING_MINUTES = 15
QUOTA_PREFIX = 'Claude quota context (not an alarm; proxy view): '
SERVING_HOURS = str(SERVING_MINUTES / 60)
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
                  stale_minutes=120, persist_polls=2, budget_seconds=24,
                  carrying_reset_hours=6, carrying_pool_floor=.4,
                  working_ceiling_multiple=6)
    path = CONFIG / 'fleet-alarm.json'
    if path.exists():
        supplied = json.loads(path.read_text())
        if not isinstance(supplied, dict) or set(supplied) - set(values):
            raise ValueError('unknown fleet-alarm configuration')
        values.update(supplied)
    for key, value in values.items():
        if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
            raise ValueError('invalid fleet-alarm configuration')
        if key in ('seven_day', 'pool_remaining', 'carrying_pool_floor') and value > 1:
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


def child_asking(summary, counts):
    # A child asking its second mate (a status-source row), or a decision list too short to tell.
    # A status-source ask on a task the mate also holds as a captain-hold row is the mate waiting
    # on the captain, so it is not the child asking the mate; row ids decide, never hold reasons.
    decisions = summary.get('decisions_open', [])
    if not isinstance(decisions, list) or counts['decisions_open'] > len(decisions):
        return True
    rows = [row for row in decisions if isinstance(row, dict)]
    held = {row.get('id') for row in rows if row.get('verb') == 'captain-hold'}
    return any(row.get('source') == 'status' and row.get('id') not in held for row in rows)


def waiting_on_captain(summary, counts):
    # No child is asking the mate anything and the complete decision list shows a filed captain
    # decision, so the mate has nothing to say until Lee answers. A live worker beside the hold
    # (usually working on or paused behind it) does not change that.
    invalidity = summary.get('invalidity')
    partial = isinstance(invalidity, dict) and invalidity.get('kind') == 'child_current_unavailable'
    if not (summary['valid'] or partial) or child_asking(summary, counts):
        return False
    return any(isinstance(row, dict) and row.get('verb') == 'captain-hold' for row in summary.get('decisions_open', []))


def working_on_task(summary, counts, open_decisions, last_verb, paused_until, age, cfg):
    # The mate's own latest line says it is working, or paused for work it still holds, and
    # nobody is waiting on it: a long task that reports sparingly, not a mate gone quiet. A
    # declared pause is quiet again once its clearing time is more than the silence window
    # past; any other line once it is older than working_ceiling_multiple silence windows.
    if last_verb not in ('working', 'paused') or open_decisions != '0' or child_asking(summary, counts):
        return False
    if not (counts.get('in_flight', 0) or counts['active_children'] or counts['holds']):
        return False
    window = cfg['silent_minutes'] * 60
    if paused_until:
        return time.time() <= int(paused_until) + window
    return age != 'null' and float(age) < cfg['working_ceiling_multiple'] * window


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
      line=$(status_agent_event_line "$3/$id.status" "$3/$id.status" "$4") || exit 1
      verb=$(status_line_verb "$line")
      case "$verb" in working|paused) ;; *) verb=other ;; esac
      until=$(status_paused_until "$line" || true)
      open=$(status_open_decisions "$window" secondmate | LC_ALL=C awk -F '\t' '$2 == "needs-decision" || $2 == "blocked"' | LC_ALL=C wc -l | tr -d ' ')
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$SECONDMATE_REGISTRY_HOST" "$SECONDMATE_REGISTRY_HOME" "$age" "$open" "$verb" "$until"
      ;;
  esac
done < "$2"
''', 'fleet-alarm', BIN, registry, STATE, str(int(time.time()))])
    seen = set()
    routes = list(csv.reader(io.StringIO(roster), delimiter='\t'))
    for index, row in enumerate(routes):
        name, host, home, age, open_decisions, last_verb, paused_until = row
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
            # A done child with a recorded PR is waiting on merge, not silent work.
            waiting = counts.get('waiting_on_merge', 0)
            if type(waiting) is not int or waiting < 0:
                raise ValueError('invalid work counts')
            work[0] = max(0, work[0] - waiting)
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
            if waiting_on_captain(summary, counts):
                continue
            if working_on_task(summary, counts, open_decisions, last_verb, paused_until, age, cfg):
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
    eased = set()
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
        rows = accounts(read([*cpa, 'accounts'], 4))

        def served(hours, share):
            names = set()
            for row in table(read([*cpa, 'models', '--hours', hours, '--limit', '1000'], share), 'models'):
                requests, failed = int(row['requests']), int(row['failed'])
                if not 0 <= failed <= requests:
                    raise ValueError('invalid traffic counts')
                if row['model'].startswith('claude-') and requests > failed:
                    names.add(row['account'])
            return names

        carrying = served('1', 3)
        serving = served(SERVING_HOURS, 2)
        live = [row for row in rows if row['used_7d'] is not None and row['age_min'] is not None
                and row['age_min'] < cfg['stale_minutes']]
        live_pool = [row['used_7d'] for row in live]
        pooled = (f"{sum(1 - Decimal(str(used)) for used in live_pool) / len(live_pool):.0%} mean 7d headroom "
                  f"across {len(live_pool)} non-stale accounts") if live_pool else 'no non-stale readings'
        rotated = sorted(f"{row['account']} 7d {row['used_7d']:.0%}" for row in live if row['used_7d'] > cfg['seven_day'])
        # The proxy has rotated when a non-stale account with headroom is serving current traffic.
        rotated_away = any(row['account'] in serving and row['used_7d'] <= cfg['seven_day'] for row in live)
        live_used = {row['account']: row['used_7d'] for row in live}
        servers = ', '.join(f"{name} 7d {live_used[name]:.0%}" if name in live_used else f'{name} reading stale/unknown'
                            for name in sorted(serving)) or f'none (no successful Claude traffic in last {SERVING_MINUTES} minutes)'
        quota_info = (f'{QUOTA_PREFIX}Serving Claude accounts '
                      f'(successful traffic in last {SERVING_MINUTES} minutes): {servers}; pooled: {pooled}; '
                      f"rotated out (over {cfg['seven_day']:.0%} 7d): {', '.join(rotated) if rotated else 'none'}")
        pool, ignored, carrying_keys = [], 0, {}
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
            if name in carrying and row['used_7d'] > cfg['seven_day'] and not rotated_away:
                reset = row['reset_7d']
                # cpa-usage-axi's reset time drifts a minute between reads; key on the nearest hour.
                try:
                    rounded = datetime.fromisoformat(reset.replace('Z', '+00:00')) + timedelta(minutes=30)
                    reset = rounded.replace(minute=0, second=0, microsecond=0).isoformat()
                except ValueError:
                    pass
                key = 'quota:' + name + ':' + reset
                findings[key] = f"Carrying Claude account {name} 7d {row['used_7d']:.0%} (resets {row['reset_7d']})"
                carrying_keys[key] = row['reset_7d']
        # A carrying account about to reset while the pool has ample headroom is not worth repeating.
        if pool and carrying_keys:
            remaining = sum(1 - Decimal(str(used)) for used in pool) / len(pool)
            if remaining > Decimal(str(cfg['carrying_pool_floor'])):
                for key, reset in carrying_keys.items():
                    try:
                        due = datetime.fromisoformat(reset.replace('Z', '+00:00')).timestamp() - time.time()
                    except ValueError:
                        continue
                    if 0 <= due <= cfg['carrying_reset_hours'] * 3600:
                        eased.add(key)
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
    return findings, quota_info, not_collected, eased


def check(channel):
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / '.fleet-alarm.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if channel == 'timer':
                print('RUN-RESULT ' + json.dumps({'summary': 'skipped: another fleet-alarm run holds the lock',
                                                  'counts': {'alerts': 0}, 'outcome': 'skipped'}))
            return
        record = STATE / '.fleet-alarm.json'
        stored = json.loads(record.read_text()) if record.exists() else {}
        old = stored.get('conditions', {})
        timer_open = stored.get('timer_open', False)
        try:
            cfg = settings()
            raw, quota_info, not_collected, eased = collect(cfg)
        except (ValueError, OSError) as error:
            cfg = {'persist_polls': 1}
            raw = {'config': f'Fleet alarm configuration invalid: {error}'}
            quota_info = ''
            not_collected = {}
            eased = set()
        # An inventory finding must persist across consecutive polls of this channel before it
        # alarms; the count resets as soon as the finding is absent from a poll.
        suspect = {key: n + 1 for key, n in stored.get('suspect', {}).get(channel, {}).items()
                   if key in raw}
        suspect.update({key: 1 for key in raw if is_inventory(key) and key not in suspect})
        current = {key: value for key, value in raw.items()
                   if not is_inventory(key) or suspect[key] >= cfg['persist_polls']}
        # A finding that stops being eased alerts again, so forget its receipts.
        for key in set(stored.get('eased', [])) - eased:
            if key in current:
                old.pop(key, None)
        fresh = {key: value for key, value in current.items()
                 if channel not in old.get(key, [])}
        # An eased finding that already alarmed on this channel stays quiet until it is no longer eased.
        quiet = {key for key in eased if key in current and channel in old.get(key, [])}
        # An unavailable reader does not prove that its previous alarms cleared.
        preserved = {key: receipts for key, receipts in old.items()
                     if ((key in raw and key not in current)
                         or 'config' in raw
                         or ('quota-read' in raw and key.startswith(('quota:', 'stale:', 'pool', 'ignored:')))
                         or ('mate-read' in raw and key.startswith(('silent:', 'mate-read:')))
                         or (key.startswith('silent:') and 'mate-read:' + key[7:] in raw)
                         or (key.startswith(('silent:', 'mate-read:'))
                             and key.split(':', 1)[1] in not_collected))}
        alarms = [key for key in current if not key.startswith('ignored:') and key not in quiet]
        cleared = channel == 'timer' and not alarms and timer_open and not preserved
        now = time.time()
        timer_state = stored.get('timer_state', 'question' if timer_open else None)
        wait_record = stored.get('wait')
        held_silent = [key for key in preserved if key.startswith('silent:') and key not in current]
        holding = alarms + held_silent
        all_silent = bool(holding) and all(key.startswith('silent:') for key in holding)
        if channel == 'timer':
            if not any(key.startswith('silent:') for key in holding):
                wait_record = None
            elif all_silent and wait_record is None:
                wait_record = {'since': now, 'until': now + cfg.get('stale_minutes', 120) * 60}
        expired = (channel == 'timer' and all_silent and timer_state != 'expired'
                   and wait_record is not None and now >= wait_record['until'])
        regroup = channel == 'timer' and all_silent and timer_state == 'question'
        if (fresh if channel == 'check' else set(fresh) & set(alarms)) or cleared or expired or regroup:
            shown = [key for key in (current if channel == 'timer' else fresh) if key not in quiet]
            details = [raw[key] for key in shown]
            if channel == 'timer':
                details += [f'Secondmate holding work silent, inventory not currently readable: {key[7:]}'
                            for key in held_silent]
            if quota_info and any(key.startswith(('quota:', 'stale:', 'pool', 'ignored:', 'quota-read'))
                                  for key in shown):
                details.append(quota_info)
            text = '; '.join(details).replace('\n', ' ')
            if channel == 'timer':
                if not (CONFIG / 'fleet-ledger').exists():
                    raise ValueError('timer requires config/fleet-ledger for Captain\'s Log delivery')
                status_path = STATE / 'fleet-alarm.status'
                stamp = f'[at={int(now)}]'
                with status_path.open('a') as status:
                    # Alarms that are all silent secondmates are an external wait, not a question for
                    # the captain: name the dependency, when it should recover, and recheck then. A wait
                    # still silent at its recheck time becomes one needs-decision [cause=external].
                    if cleared:
                        status.write(f'resolved {stamp} [key=fleet-alarm]: Fleet alarm conditions cleared\n')
                        timer_state = None
                    elif all_silent:
                        since = time.strftime('%Y-%m-%dT%H:%MZ', time.gmtime(wait_record['since']))
                        until = time.strftime('%Y-%m-%dT%H:%MZ', time.gmtime(wait_record['until']))
                        if expired or timer_state == 'expired':
                            minutes = int((now - wait_record['since']) // 60)
                            status.write(f'needs-decision {stamp} [cause=external] [key=fleet-alarm]: {text}; '
                                         f'down since {since} ({minutes} minutes); was expected back by {until} '
                                         'when the secondmate reported again\n')
                            timer_state = 'expired'
                        else:
                            if timer_state == 'question':
                                status.write(f'resolved {stamp} [key=fleet-alarm]: Fleet alarm question superseded by an external wait\n')
                            status.write(f'paused {stamp} [cause=external] [key=fleet-alarm]: {text}; '
                                         f'expected back when the secondmate reports again; until {until}\n')
                            timer_state = 'wait'
                    else:
                        cause = cause_of([key for key in alarms if not key.startswith('silent:')])
                        status.write(f'needs-decision {stamp} [cause={cause}] [key=fleet-alarm]: {text}\n')
                        timer_state = 'question'
                run([BIN / 'fm-fleet-ledger.sh', 'appended', CONFIG, status_path], 3)
                timer_open = not cleared
            else:
                print(text)
        new = {key: sorted(set(old.get(key, [])) | ({channel} if key in fresh else set()))
               for key in current}
        new.update(preserved)
        with tempfile.NamedTemporaryFile(mode='w', dir=STATE, prefix='.fleet-alarm-', delete=False) as file:
            json.dump({'conditions': new, 'timer_open': timer_open, 'timer_state': timer_state,
                       'wait': wait_record, 'not_collected': not_collected, 'eased': sorted(eased | {key for key in stored.get('eased', []) if key not in current and key in preserved}),
                       'suspect': {**stored.get('suspect', {}), channel: suspect}}, file)
            temporary = file.name
        os.replace(temporary, record)
        if channel == 'timer':
            quota = ('quota unreadable' if 'quota-read' in raw
                     else quota_info.removeprefix(QUOTA_PREFIX) or 'quota not read')
            open_alerts = len(holding)
            summary = ((f'{open_alerts} alert(s) open' if open_alerts else 'no alerts') + f'; {quota}')[:200]
            print('RUN-RESULT ' + json.dumps({'summary': summary, 'counts': {'alerts': open_alerts}}))


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
