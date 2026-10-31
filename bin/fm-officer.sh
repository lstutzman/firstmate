#!/usr/bin/env bash
# fm-officer.sh - the officer agent kind: registry, schedule, health, report.
#
# An officer is a role agent owned by the primary home. It reads fleet records
# on its own cadence (daily at a time, or every N hours), writes only its findings lane data/officers/<id>/,
# and reports one line to its first mate. It never acts on the fleet. The
# officer-roles skill owns the authority list and digest handling;
# docs/configuration.md "Officers (data/officers.md)" owns the registry schema.
# This header owns the mechanics.
#
# Usage:
#   fm-officer.sh list
#   fm-officer.sh register <id>
#   fm-officer.sh retire <id>
#   fm-officer.sh run <id> [--date YYYY-MM-DD] [--scheduled]
#   fm-officer.sh check <id>
#   fm-officer.sh ensure
#
# register writes state/officer-<id>.check.sh, binds it with
# fm-check-register.sh, and stamps the lane's registered record. retire
# unregisters that check and removes the registry line; findings stay.
#
# Cadence is `daily HH:MM` or `every Nh` (N from 1 to 24). This script owns
# the grammar: cadence_period and slot_of below. A daily officer's run key is a
# date (default yesterday in the home's local time). An interval officer's run
# key is its slot, `YYYY-MM-DDTHH`: slots start at local midnight and repeat
# every N hours until the next midnight, each is due from its start, and a
# scheduled run reads current records (a new date restarts the slots).
#
# run executes the officer's role pass for one run key under the lane's
# .run.lock, and appends one line to the lane's runs.log:
# "<epoch> <key> ok <n-actionable>" or "<epoch> <key> failed <reason>". On
# success the lane's digest file holds "DIGEST <key> <n-actionable> <path>".
# Re-running a key rewrites that key's findings, byte-identical when its
# inputs are unchanged.
#
# check is the body of the watcher check. It is fast and never contacts
# another host:
#   - once the cadence time has passed (an interval officer's slot start) and
#     the run key has no run finished since that time (a same-day manual run,
#     logged earlier, does not count), it starts `run <id> --scheduled` detached in its own session (the watcher
#     stops the check's process group when the check returns); a failed date is
#     retried after FM_OFFICER_RETRY_SECS (default 3600), FM_OFFICER_ATTEMPTS
#     (default 3) times in all, and each run is bounded by
#     FM_OFFICER_RUN_TIMEOUT seconds (default 3600);
#   - it prints "officer <id>: <key>: <n> actionable finding(s) in <path>"
#     once for each new digest with n > 0, and nothing for a repeat or an
#     empty digest (a role that runs often counts only findings it has not
#     already reported, so its n is 0 while nothing is new);
#   - it prints "officer <id>: <key>: run failed <n> time(s): <reason>" once,
#     after the last allowed attempt fails;
#   - every other condition, including an unreachable archive host, is silent
#     with exit 0; ensure reports lasting gaps at session start.
# The lane's check-record.digest and check-record.failure files each hold the
# last line of their kind reported. A scheduled run that the timeout or a
# signal ends before it logs an attempt is logged as "failed timed out" or
# "failed exited <rc>".
#
# ensure (run by bin/fm-bootstrap.sh) prints one "OFFICER: ..." line per
# actionable gap and nothing when every officer is healthy: a malformed
# registry line, an unregistered or out-of-date check, a model other than
# none, no finished run within two cadence periods of registration or of the
# last finished run, and officers listed in a second mate home.
#
# Roles: triage (bin/fm-officer-triage.py), landing
# (bin/fm-officer-landing.py), friction (bin/fm-officer-friction.py),
# progress (bin/fm-officer-progress.py), and pagecheck
# (bin/fm-officer-page-check.py); each role script's header owns its pass.
#
# Officers run in the primary home only: register, run, and check refuse in a
# home carrying .fm-secondmate-home.
#
# Environment: FM_HOME, FM_DATA_OVERRIDE, FM_STATE_OVERRIDE resolve the home as
# the other bin/ scripts do. FM_OFFICER_NOW (epoch seconds) pins the clock for
# tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REGISTRY="$DATA/officers.md"
OFFICER_ROLES="triage landing friction progress pagecheck"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-officer.sh list                         list registered officers
  fm-officer.sh register <id>                install and trust the officer's watcher check
  fm-officer.sh retire <id>                  remove the check and the registry line; findings stay
  fm-officer.sh run <id> [--date KEY]        run the officer's pass for one run key (a date, or an interval officer's YYYY-MM-DDTHH slot; default yesterday or the current slot)
  fm-officer.sh check <id>                   watcher check: start a due run, report a new digest
  fm-officer.sh ensure                       session-start health: one OFFICER: line per gap
See docs/configuration.md "Officers (data/officers.md)" for the registry schema.
EOF
}

die() {
  printf 'fm-officer: %s\n' "$1" >&2
  exit "${2:-1}"
}

now_epoch() {
  case "${FM_OFFICER_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_OFFICER_NOW" ;;
  esac
}

# epoch_fmt <epoch> <format>: local-time strftime on GNU and BSD date.
epoch_fmt() {
  date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2"
}

secondmate_home() { [ -e "$FM_HOME/.fm-secondmate-home" ]; }

CADENCE_RE='^(daily ([01][0-9]|2[0-3]):[0-5][0-9]|every ([1-9]|1[0-9]|2[0-4])h)$'
RUN_KEY_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2})?$'

# cadence_period <cadence>: seconds between runs.
cadence_period() {
  case "$1" in
    every*) local n=${1#every }; printf '%s\n' "$(( ${n%h} * 3600 ))" ;;
    *) printf '86400\n' ;;
  esac
}

# slot_of <cadence> <now>: sets SLOT_KEY and SLOT_SINCE, the run key and start epoch of the
# interval slot holding <now>. Callers use it for `every Nh` cadences only.
slot_of() {
  local period secs hms
  period=$(cadence_period "$1")
  hms=$(epoch_fmt "$2" '%H %M %S')
  secs=$(awk -v t="$hms" 'BEGIN {split(t, h, " "); print h[1] * 3600 + h[2] * 60 + h[3]}')
  SLOT_SINCE=$(( $2 - secs + secs / period * period ))
  SLOT_KEY=$(epoch_fmt "$SLOT_SINCE" %Y-%m-%dT%H)
}

require_primary() {
  secondmate_home && die "officers run only in the primary home; this is a second mate home" 3
  return 0
}

officer_id_valid() {
  case "$1" in ''|*[!a-z0-9-]*|-*) return 1 ;; esac
  [ "${#1}" -le 40 ]
}

# Registry lines: "- <id> - <role sentence> (<key>: <value>; ...; added YYYY-MM-DD)".
OFFICER_LINE_RE='^- ([a-z0-9-]+) - (.+) \((.*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'

registry_lines() {
  [ -f "$REGISTRY" ] || return 0
  grep -E '^- ' "$REGISTRY" || true
}

officer_line() {  # <id>
  local line
  while IFS= read -r line; do
    [[ "$line" =~ $OFFICER_LINE_RE ]] || continue
    [ "${BASH_REMATCH[1]}" = "$1" ] && { printf '%s\n' "$line"; return 0; }
  done <<EOF
$(registry_lines)
EOF
  return 1
}

# line_field <line> <key>: the value of one "key: value" field.
line_field() {
  local fields part key
  [[ "$1" =~ $OFFICER_LINE_RE ]] || return 1
  fields=${BASH_REMATCH[3]}
  while IFS= read -r part; do
    part=${part#"${part%%[![:space:]]*}"}
    part=${part%"${part##*[![:space:]]}"}
    key=${part%%:*}
    if [ "$key" = "$2" ] && [ "$key" != "$part" ]; then
      part=${part#*:}
      part=${part#"${part%%[![:space:]]*}"}
      printf '%s\n' "$part"
      return 0
    fi
  done <<EOF
$(printf '%s\n' "$fields" | tr ';' '\n')
EOF
  return 1
}

# line_problem <line>: prints why a registry line is unusable, or nothing.
line_problem() {
  local line=$1 id role cadence model
  if ! [[ "$line" =~ $OFFICER_LINE_RE ]]; then
    printf 'malformed registry line: %s\n' "$(printf '%s' "$line" | cut -c1-80)"
    return
  fi
  id=${BASH_REMATCH[1]}
  officer_id_valid "$id" || { printf 'officer %s: invalid id\n' "$id"; return; }
  role=$(line_field "$line" role || true)
  case " $OFFICER_ROLES " in
    *" $role "*) ;;
    *) printf 'officer %s: unknown role "%s" (known: %s)\n' "$id" "$role" "$OFFICER_ROLES"; return ;;
  esac
  cadence=$(line_field "$line" cadence || true)
  [[ "$cadence" =~ $CADENCE_RE ]] \
    || { printf 'officer %s: cadence must be "daily HH:MM" or "every Nh" (N from 1 to 24), got "%s"\n' "$id" "$cadence"; return; }
  model=$(line_field "$line" model || true)
  [ "$model" = none ] \
    || { printf 'officer %s: model "%s" is not available yet; slice 1 officers use model: none\n' "$id" "$model"; return; }
  case "$role" in
    progress)
      [ -n "$(line_field "$line" repos || true)" ] \
        || { printf 'officer %s: a progress officer needs repos: <owner/repo,...>\n' "$id"; return; }
      if line_field "$line" captains-log >/dev/null; then
        [[ "$(line_field "$line" captains-log)" == https://*/api/captains-log ]] \
          || { printf 'officer %s: captains-log must be an https URL ending /api/captains-log\n' "$id"; return; }
      fi
      ;;
    triage|friction)
      line_field "$line" archive >/dev/null \
        || { printf 'officer %s: a %s officer needs archive: <dir> or <host>:<dir>\n' "$id" "$role"; return; }
      case "$(line_field "$line" ask-days || echo 7)" in
        ''|*[!0-9]*|0) printf 'officer %s: ask-days must be a whole number of days, at least 1\n' "$id"; return ;;
      esac
      if line_field "$line" captains-log >/dev/null; then
        [ "$role" = friction ] && [[ "$(line_field "$line" captains-log)" == https://* ]] \
          || { printf 'officer %s: captains-log must be an https URL on a friction officer\n' "$id"; return; }
      fi
      ;;
    pagecheck)
      [[ "$(line_field "$line" app || true)" == https://* ]] \
        || { printf 'officer %s: a pagecheck officer needs app: <https URL of the fleet app>\n' "$id"; return; }
      case "$(line_field "$line" stale-days || echo 7)$(line_field "$line" remind-hours || echo 24)" in
        ''|*[!0-9]*) printf 'officer %s: stale-days and remind-hours must be whole numbers\n' "$id"; return ;;
      esac
      ;;
    landing)
      line_field "$line" facts >/dev/null \
        || { printf 'officer %s: a landing officer needs facts: <path>, <host>:<path>, or an https URL\n' "$id"; return; }
      case "$(line_field "$line" writes || echo corrections)" in
        none|corrections) ;;
        *) printf 'officer %s: writes must be corrections or none\n' "$id"; return ;;
      esac
      case "$(line_field "$line" max-corrections || echo 10)$(line_field "$line" done-window || echo 100)$(line_field "$line" max-facts-age || echo 36)" in
        ''|*[!0-9]*) printf 'officer %s: max-corrections, done-window, and max-facts-age must be whole numbers\n' "$id"; return ;;
      esac
      case "$(line_field "$line" reopen-state || echo 'In Progress')" in
        'In Staging'|Done) printf 'officer %s: reopen-state may not be In Staging or Done\n' "$id"; return ;;
      esac
      ;;
  esac
}

# load_officer <id>: sets OFFICER_LINE and OFFICER_LANE or dies.
load_officer() {
  local problem
  officer_id_valid "$1" || die "invalid officer id: $1" 2
  OFFICER_LINE=$(officer_line "$1") || die "officer $1 is not in $REGISTRY" 2
  problem=$(line_problem "$OFFICER_LINE")
  [ -z "$problem" ] || die "$problem" 2
  OFFICER_ID=$1
  OFFICER_LANE="$DATA/officers/$1"
  OFFICER_SHIM="$STATE/officer-$1.check.sh"
}

shim_content() {
  local home
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "# Auto-generated by fm-officer.sh register $OFFICER_ID - officer check; retire with fm-officer.sh retire $OFFICER_ID." \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-officer.sh") check $OFFICER_ID"
}

action_list() {
  local line id
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [[ "$line" =~ $OFFICER_LINE_RE ]]; then
      id=${BASH_REMATCH[1]}
      printf '%s role=%s cadence="%s" check=%s\n' "$id" "$(line_field "$line" role || true)" \
        "$(line_field "$line" cadence || true)" \
        "$(fm_custom_check_registered "$STATE" "officer-$id" && echo registered || echo absent)"
    fi
  done <<EOF
$(registry_lines)
EOF
}

action_register() {
  local want device tmp
  require_primary
  load_officer "$1"
  mkdir -p "$STATE" "$OFFICER_LANE" || die "cannot create $OFFICER_LANE"
  want=$(shim_content) || die "cannot resolve FM_HOME $FM_HOME"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  device=$(fm_pr_file_device "$STATE") || die "state directory is unavailable"
  fm_pr_regular_destination_on_device_or_absent "$OFFICER_SHIM" "$device" \
    || die "refusing to replace $OFFICER_SHIM"
  tmp=$(umask 077; mktemp "$STATE/.fm-officer-check.XXXXXX") || die "cannot write $OFFICER_SHIM"
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$OFFICER_SHIM"; then
    rm -f -- "$tmp"
    die "cannot write $OFFICER_SHIM"
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "officer-$OFFICER_ID" >/dev/null \
    || die "could not register $OFFICER_SHIM"
  [ -f "$OFFICER_LANE/registered" ] || now_epoch > "$OFFICER_LANE/registered"
  printf 'registered: officer %s (state/officer-%s.check.sh)\n' "$OFFICER_ID" "$OFFICER_ID"
}

action_retire() {
  local id=$1 tmp
  officer_id_valid "$id" || die "invalid officer id: $id" 2
  if [ -e "$STATE/officer-$id.check.sh" ] || [ -e "$STATE/officer-$id.check-trust" ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "officer-$id" >/dev/null \
      || die "could not unregister state/officer-$id.check.sh"
  fi
  if [ -f "$REGISTRY" ] && officer_line "$id" >/dev/null; then
    tmp=$(mktemp "$REGISTRY.XXXXXX") || die "cannot rewrite $REGISTRY"
    if ! awk -v id="$id" 'index($0, "- " id " - ") != 1' "$REGISTRY" > "$tmp" \
      || ! mv -f -- "$tmp" "$REGISTRY"; then
      rm -f -- "$tmp"
      die "cannot rewrite $REGISTRY"
    fi
  fi
  rm -f -- "$DATA/officers/$id/registered"
  printf 'retired: officer %s (findings kept in data/officers/%s/)\n' "$id" "$id"
}

# The homes whose records the officer reads: this home, then each local
# second mate home in data/secondmates.md that exists here. Read-only.
readable_homes() {
  local line home
  CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P
  [ -f "$DATA/secondmates.md" ] || return 0
  while IFS= read -r line; do
    secondmate_registry_parse_line "$line" || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] && continue
    home=${SECONDMATE_REGISTRY_HOME/#\~/$HOME}
    [ -d "$home/state" ] && (CDPATH='' cd -- "$home" && pwd -P)
  done < "$DATA/secondmates.md"
}

lock_acquire() {
  local lock="$OFFICER_LANE/.run.lock" pid
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid"
    return 0
  fi
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  rm -rf -- "$lock"
  mkdir "$lock" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$lock/pid"
}

lock_release() { rm -rf -- "$OFFICER_LANE/.run.lock"; }

lock_held() {
  local pid
  pid=$(cat "$OFFICER_LANE/.run.lock/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

run_log() {  # <date> <ok|failed> <detail>
  printf '%s %s %s %s\n' "$(now_epoch)" "$1" "$2" "$3" >> "$OFFICER_LANE/runs.log"
}

# role_archive <script> <date> [args...]: a pass that reads the session
# archive and every readable home: triage and friction.
role_archive() {
  local -a args
  local script=$1 home hosts
  shift
  args=(run --archive "$(line_field "$OFFICER_LINE" archive)" --date "$1" --out "$OFFICER_LANE"
    --model "$(line_field "$OFFICER_LINE" model)")
  shift
  hosts=$(line_field "$OFFICER_LINE" hosts || true)
  [ -z "$hosts" ] || args+=(--hosts "$hosts")
  while IFS= read -r home; do
    [ -n "$home" ] && args+=(--home "$home")
  done <<EOF
$(readable_homes)
EOF
  python3 -I "$SCRIPT_DIR/$script" "${args[@]}" "$@"
}

role_triage() { role_archive fm-officer-triage.py "$1"; }  # <date>

# role_friction <date>: each registered second mate's id names its parent
# channel log, state/<mate-id>.status, in this home.
role_friction() {
  local -a args=(--now "$(now_epoch)")
  local log line
  log=$(line_field "$OFFICER_LINE" captains-log || true)
  [ -z "$log" ] || args+=(--captains-log "$log")
  if [ -f "$DATA/secondmates.md" ]; then
    while IFS= read -r line; do
      secondmate_registry_parse_line "$line" && args+=(--channel "$SECONDMATE_REGISTRY_ID")
    done < "$DATA/secondmates.md"
  fi
  args+=(--days "$(line_field "$OFFICER_LINE" ask-days || echo 7)")
  role_archive fm-officer-friction.py "$1" "${args[@]}"
}

# role_pagecheck <key>: reads the fleet app's pages (GET only) and this home's records; the standing
# rules default to this home's data/captain-shared.md.
role_pagecheck() {
  local home
  local -a args=(run --key "$1" --out "$OFFICER_LANE" --now "$(now_epoch)"
    --app "$(line_field "$OFFICER_LINE" app)"
    --rules "$(line_field "$OFFICER_LINE" rules || echo "$DATA/captain-shared.md")"
    --stale-days "$(line_field "$OFFICER_LINE" stale-days || echo 7)"
    --remind-hours "$(line_field "$OFFICER_LINE" remind-hours || echo 24)")
  while IFS= read -r home; do
    [ -n "$home" ] && args+=(--home "$home")
  done <<EOF
$(readable_homes)
EOF
  python3 -I "$SCRIPT_DIR/fm-officer-page-check.py" "${args[@]}"
}

role_landing() {  # <date>
  python3 -I "$SCRIPT_DIR/fm-officer-landing.py" run --facts "$(line_field "$OFFICER_LINE" facts)" \
    --date "$1" --out "$OFFICER_LANE" --team "$(line_field "$OFFICER_LINE" team || echo PC)" \
    --writes "$(line_field "$OFFICER_LINE" writes || echo corrections)" \
    --done-window "$(line_field "$OFFICER_LINE" done-window || echo 100)" \
    --max-corrections "$(line_field "$OFFICER_LINE" max-corrections || echo 10)" \
    --reopen-state "$(line_field "$OFFICER_LINE" reopen-state || echo 'In Progress')" \
    --max-facts-age "$(line_field "$OFFICER_LINE" max-facts-age || echo 36)" --now "$(now_epoch)"
}

role_progress() {  # <date>: current records, dated with the common cadence's run date.
  local home line
  local -a args=(run --date "$1" --out "$OFFICER_LANE" --now "$(now_epoch)"
    --team "$(line_field "$OFFICER_LINE" team || echo PC)"
    --repos "$(line_field "$OFFICER_LINE" repos || true)"
    --officer "$OFFICER_ID" --captains-log "$(line_field "$OFFICER_LINE" captains-log || true)"
    --requested "$(line_field "$OFFICER_LINE" requested || true)")
  args+=(--home "$FM_HOME")
  if [ -f "$DATA/secondmates.md" ]; then
    while IFS= read -r line; do
      secondmate_registry_parse_line "$line" || continue
      if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ]; then
        args+=(--home "$SECONDMATE_REGISTRY_HOST:$SECONDMATE_REGISTRY_HOME")
      else
        home=${SECONDMATE_REGISTRY_HOME/#\~/$HOME}
        args+=(--home "$home")
      fi
    done < "$DATA/secondmates.md"
  fi
  python3 -I "$SCRIPT_DIR/fm-officer-progress.py" "${args[@]}"
}

action_run() {
  local id=$1 date='' out rc digest n reason
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --date) date=${2:-}; shift 2 ;;
      --scheduled) shift ;;
      *) die "unknown run option: $1" 2 ;;
    esac
  done
  require_primary
  load_officer "$id"
  if [ -z "$date" ]; then
    if [[ "$(line_field "$OFFICER_LINE" cadence)" == every* ]]; then
      slot_of "$(line_field "$OFFICER_LINE" cadence)" "$(now_epoch)"
      date=$SLOT_KEY
    else
      date=$(epoch_fmt "$(( $(now_epoch) - 86400 ))" %Y-%m-%d)
    fi
  fi
  [[ "$date" =~ $RUN_KEY_RE ]] || die "--date must be YYYY-MM-DD, or YYYY-MM-DDTHH for an interval officer" 2
  mkdir -p "$OFFICER_LANE" || die "cannot create $OFFICER_LANE"
  lock_acquire || die "officer $id already has a run in progress"
  trap lock_release EXIT
  rc=0
  out=$("role_$(line_field "$OFFICER_LINE" role)" "$date" 2>"$OFFICER_LANE/.run.err") || rc=$?
  digest=$(printf '%s\n' "$out" | grep -E '^DIGEST [0-9T-]{10,13} [0-9]+ ' | tail -n 1)
  if [ "$rc" -ne 0 ] || [ -z "$digest" ]; then
    reason=$(grep -v '^[[:space:]]*$' "$OFFICER_LANE/.run.err" 2>/dev/null | tail -n 1 | cut -c1-200)
    run_log "$date" failed "${reason:-role pass exited $rc}"
    die "officer $id run for $date failed: ${reason:-exit $rc}"
  fi
  n=$(printf '%s\n' "$digest" | awk '{print $3}')
  printf 'DIGEST %s %s data/officers/%s/%s.md\n' "$date" "$n" "$id" "$date" > "$OFFICER_LANE/digest"
  run_log "$date" ok "$n"
  printf '%s\n' "$out" | grep -E '^(Linear coverage:|Coverage gap:)' || true
  cat "$OFFICER_LANE/digest"
}

# detach <log> <command...>: start the command in a new session so the
# watcher's process-group stop cannot reach it, returning once it has detached.
detach() {
  local log=$1
  shift
  python3 -I -c '
import os, sys
log = sys.argv[1]
r, w = os.pipe()
if os.fork() == 0:
    os.close(r)
    os.setsid()
    fd = os.open(log, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    os.dup2(fd, 1); os.dup2(fd, 2)
    null = os.open(os.devnull, os.O_RDONLY); os.dup2(null, 0)
    os.write(w, b"1"); os.close(w)
    os.execvp(sys.argv[2], sys.argv[2:])
os.close(w)
os.read(r, 1)
' "$log" "$@"
}

# attempts <date> <since> / finished <date> <since> / last_attempt <date>: from the lane's runs.log.
# Both count only lines logged at or after <since>, the epoch of the cadence
# time that made the date due, so a run logged before it (a same-day manual run)
# never satisfies or exhausts the next scheduled run.
attempts() { awk -v d="$1" -v s="$2" '$2 == d && $3 == "failed" && $1 >= s {n++} END {print n + 0}' "$OFFICER_LANE/runs.log" 2>/dev/null || echo 0; }
finished() { awk -v d="$1" -v s="$2" '$2 == d && $3 == "ok" && $1 >= s {f=1} END {exit !f}' "$OFFICER_LANE/runs.log" 2>/dev/null; }
last_attempt() { awk -v d="$1" '$2 == d {t=$1} END {print t + 0}' "$OFFICER_LANE/runs.log" 2>/dev/null || echo 0; }

runs_for() { cat "$OFFICER_LANE/runs.log" 2>/dev/null | awk -v d="$1" '$2 == d {n++} END {print n + 0}'; }

report_once() {  # <digest|failure> <line>
  [ "$(cat "$OFFICER_LANE/check-record.$1" 2>/dev/null)" = "$2" ] && return 0
  printf '%s\n' "$2" > "$OFFICER_LANE/check-record.$1" || return 0
  printf '%s\n' "$2"
}

action_check() {
  local id=$1 now cadence at date since tries max retry digest n path reason hms
  secondmate_home && return 0
  ( load_officer "$id" ) >/dev/null 2>&1 || return 0
  load_officer "$id"
  mkdir -p "$OFFICER_LANE" 2>/dev/null || return 0
  now=$(now_epoch)
  cadence=$(line_field "$OFFICER_LINE" cadence)
  if [[ "$cadence" == every* ]]; then
    slot_of "$cadence" "$now"
    date=$SLOT_KEY
    since=$SLOT_SINCE
    at=00:00
  else
    at=${cadence#daily }
    date=$(epoch_fmt "$((now - 86400))" %Y-%m-%d)
    # shortcut: today's cadence time is taken as now minus the seconds since midnight, an hour off when a DST change falls between the cadence time and now.
    hms=$(epoch_fmt "$now" '%H %M %S')
    since=$(awk -v n="$now" -v a="$at" -v t="$hms" 'BEGIN {split(t, h, " "); split(a, c, ":"); print n - (h[1] * 3600 + h[2] * 60 + h[3]) + c[1] * 3600 + c[2] * 60}')
  fi
  max=${FM_OFFICER_ATTEMPTS:-3}
  retry=${FM_OFFICER_RETRY_SECS:-3600}
  tries=$(attempts "$date" "$since")
  if ! [ "$(epoch_fmt "$now" %H:%M)" \< "$at" ] && ! finished "$date" "$since" && ! lock_held \
    && [ "$tries" -lt "$max" ] && [ $((now - $(last_attempt "$date"))) -ge "$retry" ]; then
    detach "$OFFICER_LANE/run-output.log" \
      bash "$SCRIPT_DIR/fm-officer.sh" __timed-run "$id" "$date" >/dev/null 2>&1 || true
  fi
  digest=$(cat "$OFFICER_LANE/digest" 2>/dev/null || true)
  if [[ "$digest" =~ ^DIGEST\ ([0-9T-]{10,13})\ ([0-9]+)\ (.+)$ ]]; then
    n=${BASH_REMATCH[2]}
    path=${BASH_REMATCH[3]}
    if [ "$n" -gt 0 ]; then
      report_once digest "officer $id: ${BASH_REMATCH[1]}: $n actionable finding(s) in $path"
    fi
  fi
  tries=$(attempts "$date" "$since")
  if ! finished "$date" "$since" && ! lock_held && [ "$tries" -ge "$max" ]; then
    reason=$(awk -v d="$date" '$2 == d && $3 == "failed" {$1=$2=$3=""; r=$0} END {print r}' \
      "$OFFICER_LANE/runs.log" 2>/dev/null | sed 's/^ *//')
    report_once failure "officer $id: $date: run failed $tries time(s): $reason"
  fi
  return 0
}

action_timed_run() {  # <id> <date>: the detached scheduled run, bounded.
  local before rc=0
  load_officer "$1"
  before=$(runs_for "$2")
  fm_run_timed "${FM_OFFICER_RUN_TIMEOUT:-3600}" bash "$SCRIPT_DIR/fm-officer.sh" run "$1" --date "$2" --scheduled || rc=$?
  if [ "$rc" -ne 0 ] && [ "$(runs_for "$2")" -eq "$before" ]; then
    if fm_timed_out "$rc"; then run_log "$2" failed "timed out"; else run_log "$2" failed "exited $rc"; fi
  fi
  return "$rc"
}

action_ensure() {
  local line problem id registered last_ok now span shim_want cadence
  [ -f "$REGISTRY" ] || return 0
  if secondmate_home; then
    if [ -n "$(registry_lines)" ]; then
      echo "OFFICER: data/officers.md lists officers in a second mate home; officers run only in the primary home - retire them here with bin/fm-officer.sh retire <id>"
    fi
    return 0
  fi
  now=$(now_epoch)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    problem=$(line_problem "$line")
    if [ -n "$problem" ]; then
      echo "OFFICER: $problem"
      continue
    fi
    [[ "$line" =~ $OFFICER_LINE_RE ]]
    id=${BASH_REMATCH[1]}
    OFFICER_ID=$id
    OFFICER_LANE="$DATA/officers/$id"
    if ! fm_custom_check_registered "$STATE" "officer-$id"; then
      echo "OFFICER: officer $id: its watcher check is not registered - run bin/fm-officer.sh register $id"
      continue
    fi
    shim_want=$(shim_content 2>/dev/null || true)
    if [ "$(cat "$STATE/officer-$id.check.sh" 2>/dev/null)" != "$shim_want" ]; then
      echo "OFFICER: officer $id: its watcher check points at another firstmate copy or home - run bin/fm-officer.sh register $id"
      continue
    fi
    registered=$(cat "$OFFICER_LANE/registered" 2>/dev/null || echo "$now")
    last_ok=$(awk '$3 == "ok" {t=$1} END {print t + 0}' "$OFFICER_LANE/runs.log" 2>/dev/null || echo 0)
    [ "$last_ok" -gt "$registered" ] && span=$last_ok || span=$registered
    case "$span" in ''|*[!0-9]*) span=$now ;; esac
    cadence=$(line_field "$line" cadence)
    if [ $((now - span)) -gt $((2 * $(cadence_period "$cadence"))) ]; then
      if [ "$last_ok" -gt 0 ]; then
        echo "OFFICER: officer $id: no finished run since $(epoch_fmt "$last_ok" '%Y-%m-%d %H:%M') (cadence $cadence) - see data/officers/$id/runs.log"
      else
        echo "OFFICER: officer $id: no finished run since it was registered $(epoch_fmt "$registered" '%Y-%m-%d') - see data/officers/$id/runs.log"
      fi
    fi
  done <<EOF
$(registry_lines)
EOF
  return 0
}

cmd=${1:-}
case "$cmd" in
  list) action_list ;;
  register) [ "$#" -eq 2 ] || die "usage: fm-officer.sh register <id>" 2; action_register "$2" ;;
  retire) [ "$#" -eq 2 ] || die "usage: fm-officer.sh retire <id>" 2; action_retire "$2" ;;
  run) [ "$#" -ge 2 ] || die "usage: fm-officer.sh run <id> [--date YYYY-MM-DD]" 2; shift; action_run "$@" ;;
  check) [ "$#" -eq 2 ] || die "usage: fm-officer.sh check <id>" 2; action_check "$2" ;;
  __timed-run) [ "$#" -eq 3 ] || die "usage: internal" 2; action_timed_run "$2" "$3" ;;
  ensure) action_ensure ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
