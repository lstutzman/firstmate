#!/usr/bin/env bash
# fm-office.sh - the office registry, wake sources and status: list offices,
# report gaps, run an office's own wake-source checks, and project an office
# home's work onto its status file.
#
# An office is a second mate that runs a standing role mandate (navigator or
# quartermaster) instead of idling. docs/configuration.md "Offices
# (data/offices.md)" owns the registry schema; this header owns the mechanics.
#
# Usage:
#   fm-office.sh list
#   fm-office.sh ensure
#   fm-office.sh publish <id>
#   fm-office.sh status
#   fm-office.sh arm-status
#   fm-office.sh disarm-status
#   fm-office.sh register-sources
#   fm-office.sh check <source>
#
# list and ensure only read. publish writes only one office's authority record
# and its receipt. status writes data/office-status.json; arm-status and
# disarm-status write only the status check and its trust binding.
#
# list prints one line per registry entry: "<id> <role> <state>", where state
# is "ok" or "gaps:<n>".
#
# ensure (run by bin/fm-bootstrap.sh) prints one "OFFICE: office <id>: <gap>"
# line per mismatch between data/offices.md and the fleet, and nothing when
# they agree. An absent data/offices.md means no offices. A gap is a malformed
# line, an unknown or reserved role, a bad value for a key, a runs-on host that is not
# allowed or not the registered second mate's host, an id that is not a
# registered second mate, a missing .fm-office marker or "# Office authority"
# charter heading in a local office home, a dispatch project missing from the
# office home's data/projects.md, a merge project without admission=, a source
# lane that is not a registered officer, a listed source whose check is not
# registered and trusted in a local office home's state/, or a merge-via
# project that does not carry merger=<home> in the office home's
# data/projects.md. For a local office it also reports an authority record
# that cannot be built, is unpublished or unproven, or is stale against
# data/offices.md and the main home's master admission configs, and an
# office-local admission config that differs from the master its record pins.
# A remote office's home is not readable from here, so its file checks are
# skipped.
#
# publish <id> (run in the main home) pushes that one office's authority record
# into its home now: config/office-authority and its receipt
# config/.fm-inherit-office-authority.generation, through the same
# inherited-config propagation and per-home lock that bin/fm-config-push.sh
# uses, restricted to that item. bin/fm-office-authority-lib.sh owns what the
# record holds and when a home receives an absence instead. <id> must be a
# second mate registered in data/secondmates.md on a local route, whose home's
# .fm-secondmate-home names it; a remote office receives its record from the
# ordinary remote inheritance push. publish refuses in a second-mate home. It
# prints one line, "office <id>: <pushed|unchanged|error> [reason]", and exits
# non-zero on an error. Every convergence point (secondmate spawn, the
# bootstrap secondmate sweep, bin/fm-config-push.sh) publishes the same record.
#
# status (run inside an office home, as its silent watcher check) projects that
# home's backlog and in-flight task records onto data/office-status.json for the
# fleet app's Status page; docs/configuration.md "Office status
# (data/office-status.json)" owns the schema and lane rules, and
# bin/fm-office-status.py owns the mechanics. It reads only data/backlog.md and
# state/*.meta, writes only data/office-status.json and
# state/office-status.seen.json (each atomically), prints nothing on success,
# and does nothing outside an office home (no .fm-office marker).
#
# arm-status (run once in an office home) writes state/office-status.check.sh,
# a shim that exports this home as FM_HOME and execs "fm-office.sh status", and
# binds it with bin/fm-check-register.sh so every watcher sweep runs it; running
# it again rewrites the same bytes. disarm-status retires the check through
# bin/fm-check-unregister.sh. Both refuse outside an office home.
#
# register-sources runs in an office home (one carrying .fm-office). It reads
# the office's registry line from the parent's data/offices.md, writes one
# shim state/office-<source>.check.sh for each source in its sources: field
# (tick -> office-tick, upstream -> office-upstream, lane:progress -> office-lane-progress,
# lane:surgeon:high -> office-lane-surgeon-high), and binds each with
# fm-check-register.sh. Each shim exports FM_HOME for the office home and
# execs "fm-office.sh check <source>". It is idempotent, and it unregisters an
# office-tick or office-lane-* shim whose source is no longer listed. The office's own
# watcher sweeps state/*.check.sh, so a source wakes the office and never main.
#
# check <source> is the body of a source check. It is fast, contacts no other
# host (except the upstream source, below), always exits 0, and prints one line at most:
#   tick             "office <id>: tick <YYYY-MM-DDTHH>: <n> of <wip> places free, <q> queued"
#                    once per slot of the registry line's tick: cadence, when a
#                    place is free (live ship and scout task records < wip) and
#                    work could start: an unheld, unblocked Queued item in
#                    data/backlog.md, or an unread lane digest. Silent otherwise.
#   lane:<officer>   "office <id>: <officer> digest <key>: <n> finding(s) in <path>"
#                    once per new digest with n > 0, read from the parent's
#                    data/officers/<officer>/digest (a local parent route only).
#   lane:<officer>:high
#                    "office <id>: <officer> digest <key>: <n> high-severity finding(s) in <path>"
#                    once per new count of findings in the digest's .json whose
#                    severity is "high" or "critical", or a number of 4 or more.
# Either lane form, reading a progress or surgeon digest (.json source "progress-officer"
# or "surgeon-officer"),
# first delivers the start requests whose execute.env.FM_HOME is this office home:
# in rank order, by running this code root's fm-inbox.sh with the request's
# recorded note arguments (never the program the file names), with FM_HOME set to
# this home. It delivers nothing from a digest whose generated_at is over 36 hours
# old, stops at the first request it will not run or that fails, and retries on
# later checks; request-id replay keeps each request one note. The outcome is
# appended to the line as "; <n> start request(s) delivered to this office's
# inbox", "; digest older than 36 hours, ...", or "; start request <r> of <n>
# could not be delivered; ...", once per digest content, recorded in
# data/office/lane-<officer>-starts.seen.
# The seen-records are data/office/tick.seen and data/office/lane-<officer>[-high].seen
# in the office home. A remote parent, an unreadable file, an unregistered
# source or a home that is not an office is silent. Start delivery runs
# fm-inbox.sh in this home only; nothing in the parent is written.
#
#   upstream         "office <id>: upstream <old>..<new>: <n> new commit(s) not in <fork-ref>; newest: <subject> | ..."
#                    once per new upstream head, read from config/firstmate-upstream
#                    (one line: <remote-or-url> [<branch>] [<fork-ref>]; branch defaults to
#                    main, fork-ref to origin/main; absent file: silent). It tries at most
#                    once an hour and, after a success, once per UTC day. It is the one
#                    source that contacts another host (git ls-remote, then a bounded fetch
#                    into refs/fm-upstream-check/head of this code root, only for a head not
#                    yet reported). It is silent when upstream has nothing the fork lacks,
#                    and on a failed attempt until failures span 24 hours, when it reports
#                    "upstream <src> unreachable since <date>" once per failure streak.
#                    <old> is the merge base. Records: data/office/upstream.seen (last
#                    head reported or found empty), upstream.day (last successful UTC
#                    day), upstream.try (last attempt) and upstream.fail (first failure
#                    epoch, with a "reported" suffix once reported).
#
# Environment: FM_HOME, FM_DATA_OVERRIDE, FM_STATE_OVERRIDE as the other bin/ scripts do.
# FM_OFFICE_HOST names this host for tests (default: hostname -s).
# FM_OFFICE_NOW (epoch seconds) pins the clock for tests.
# FM_OFFICE_STATUS_REFRESH_SECS (default 900) tunes status.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
REGISTRY="$DATA/offices.md"
STATUS_CHECK_ID=office-status
STATUS_CHECK="$STATE/$STATUS_CHECK_ID.check.sh"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-registry-line-lib.sh
. "$SCRIPT_DIR/fm-registry-line-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-office-authority-lib.sh
. "$SCRIPT_DIR/fm-office-authority-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-office.sh list      list registered offices and their state
  fm-office.sh ensure    session-start health: one OFFICE: line per gap
  fm-office.sh publish <id>   push that office's authority record into its home now
  fm-office.sh status    write data/office-status.json for this office home (silent)
  fm-office.sh arm-status     register status as this office home's silent watcher check
  fm-office.sh disarm-status  retire that check
  fm-office.sh register-sources    (office home) install and trust the office's wake-source checks
  fm-office.sh check <source>      (watcher check) report a new tick or lane digest
See docs/configuration.md "Offices (data/offices.md)" for the registry schema.
EOF
}

in_list() {  # <item> <comma list>
  case ",$2," in *",$1,"*) return 0 ;; esac
  return 1
}

project_listed() {  # <projects.md> <project>
  grep -Eq "^- $2( |\\[)" "$1" 2>/dev/null
}

# office_problems <line>: prints one gap per line.
office_problems() {
  local line=$1 id role v home projects_md host p pair runs_on dispatch merge via
  if ! [[ "$line" =~ $REGISTRY_LINE_RE ]]; then
    printf 'malformed registry line: %s\n' "$(printf '%s' "$line" | cut -c1-80)"
    return
  fi
  id=${BASH_REMATCH[1]}

  role=$(line_field "$line" role || true)
  fm_office_role_check "$role" || printf '%s\n' "$FM_OFFICE_ERROR"
  v=$(line_field "$line" wip || true)
  [[ "$v" =~ ^[1-9]$ ]] || printf 'wip must be a number from 1 to 9, got "%s"\n' "$v"
  v=$(line_field "$line" tick || true)
  [[ "$v" =~ ^every\ ([1-9]|1[0-9]|2[0-4])h$ ]] || printf 'tick must be "every Nh" (N from 1 to 24), got "%s"\n' "$v"
  v=$(line_field "$line" auto-merge-classes || true)
  [ "$v" = none ] || printf 'auto-merge-classes must be none, got "%s"\n' "$v"
  v=$(line_field "$line" sources || true)
  if [ -z "$v" ]; then
    printf 'sources must list tick, upstream or lane:<officer-id>[:high]\n'
  else
    for p in ${v//,/ }; do
      case "$p" in
        tick|upstream) ;;
        lane:*)
          p=${p#lane:}; p=${p%:high}
          grep -Eq "^- $p - " "$DATA/officers.md" 2>/dev/null \
            || printf 'source lane:%s is not a registered officer\n' "$p"
          ;;
        *) printf 'source "%s" must be tick, upstream, lane:<officer-id> or lane:<officer-id>:high\n' "$p" ;;
      esac
    done
  fi

  runs_on=$(line_field "$line" runs-on || true)
  dispatch=$(line_field "$line" dispatch || true)
  merge=$(line_field "$line" merge || true)
  via=$(line_field "$line" merge-via || true)
  [ -n "$runs_on" ] || printf 'runs-on must list at least one host\n'
  [ -n "$dispatch" ] || printf 'dispatch must list at least one project\n'
  in_list macbook "$runs_on" && printf 'host not allowed: macbook (new scheduled roles run on slartibartfast or deepthought only)\n'
  if [ -n "$merge" ] && [ "$merge" != none ]; then
    for p in ${merge//,/ }; do
      in_list "$p" "$dispatch" || printf 'merge project %s is not in dispatch\n' "$p"
    done
  fi
  if [ -n "$via" ] && [ "$via" != none ]; then
    for pair in ${via//,/ }; do
      p=${pair%%=*}
      [[ "$pair" == *=?* ]] || printf 'merge-via entry "%s" must be <project>=<home>\n' "$pair"
      in_list "$p" "$dispatch" || printf 'merge-via project %s is not in dispatch\n' "$p"
      in_list "$p" "$merge" && printf 'merge-via project %s overlaps merge\n' "$p"
    done
  fi

  secondmate_registry_line_for_id "$DATA/secondmates.md" "$id" \
    || { printf 'not a registered second mate in data/secondmates.md\n'; return; }
  host=${SECONDMATE_REGISTRY_HOST:-${FM_OFFICE_HOST:-$(hostname -s)}}
  in_list "$host" "$runs_on" || printf 'runs-on %s does not include the second mate host %s\n' "$runs_on" "$host"
  if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ]; then
    [ -z "$merge" ] || [ "$merge" = none ] \
      || printf 'it merges %s, and its admission config cannot be pinned on a remote route, so its authority record cannot be published\n' "$merge"
    return
  fi
  home=${SECONDMATE_REGISTRY_HOME/#\~/$HOME}
  [ -d "$home" ] || { printf 'office home %s is missing\n' "$home"; return; }
  [ "$(cat "$home/.fm-office" 2>/dev/null)" = "$id" ] || printf '.fm-office marker missing or not "%s" in %s\n' "$id" "$home"
  grep -q '^# Office authority' "$home/data/charter.md" 2>/dev/null \
    || printf 'charter lacks the "# Office authority" heading (%s/data/charter.md)\n' "$home"
  for p in ${v//,/ }; do
    fm_custom_check_registered "$home/state" "$(source_check_id "$p")" \
      || printf 'source %s is not registered in %s/state (run bin/fm-office.sh register-sources there)\n' "$p" "$home"
  done
  projects_md="$home/data/projects.md"
  for p in ${dispatch//,/ }; do
    project_listed "$projects_md" "$p" || printf 'dispatch project %s is not in %s\n' "$p" "$projects_md"
  done
  if [ -n "$merge" ] && [ "$merge" != none ]; then
    for p in ${merge//,/ }; do
      [ -n "$(fm_office_project_token "$projects_md" "$p" admission)" ] || printf 'merge project %s has no admission= in %s\n' "$p" "$projects_md"
    done
  fi
  if [ -n "$via" ] && [ "$via" != none ]; then
    for pair in ${via//,/ }; do
      p=${pair%%=*}
      [ "$(fm_office_project_token "$projects_md" "$p" merger)" = "${pair#*=}" ] \
        || printf 'merge-via project %s lacks merger=%s in %s\n' "$p" "${pair#*=}" "$projects_md"
    done
  fi
  authority_problems "$id" "$home"
}

# authority_problems <id> <home>: the authority-record gaps of one local office.
authority_problems() {
  local id=$1 home=$2 stage rec=$2/config/office-authority receipt=$2/config/.fm-inherit-office-authority.generation
  local sha entry p name digest
  stage=$(mktemp -d "${TMPDIR:-/tmp}/fm-office-ensure.XXXXXX") || { printf 'cannot stage its authority record to compare\n'; return; }
  if ! fm_office_inherit_payload "$CONFIG" "$DATA" "$id" "$home" "$stage/record"; then
    printf '%s\n' "$FM_OFFICE_ERROR"
  elif [ ! -f "$stage/record" ]; then
    :
  elif ! fm_role_inherit_check "$rec" "$receipt" "office authority record" "authority record"; then
    printf 'authority record is unproven (%s); run bin/fm-office.sh publish %s\n' "$FM_ROLE_DIAG" "$id"
  elif [ "$(sed -n 4p "$receipt")" = absent ]; then
    printf 'authority record is not published; run bin/fm-office.sh publish %s\n' "$id"
  elif ! cmp -s "$stage/record" "$rec"; then
    printf 'authority record is stale against data/offices.md or the master admission config; run bin/fm-office.sh publish %s\n' "$id"
  else
    sha=$(sed -n 's/^admission-sha256=//p' "$rec")
    for entry in ${sha//,/ }; do
      p=${entry%%:*}
      name=$(fm_office_project_token "$home/data/projects.md" "$p" admission)
      digest=$(fm_office_admission_digest "$home/config" "$name") || digest=
      [ "$entry" = "$p:$digest" ] \
        || printf 'admission config %s in %s/config differs from the master copy its record pins, so its merges of %s are refused; copy it again from %s/admission\n' "$name" "$home" "$p" "$CONFIG"
    done
  fi
  rm -rf "$stage"
}

cmd_list() {
  local line id n
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [[ "$line" =~ $REGISTRY_LINE_RE ]]; then id=${BASH_REMATCH[1]}; else id='?'; fi
    n=$(office_problems "$line" | grep -c .)
    printf '%s %s %s\n' "$id" "$(line_field "$line" role || echo '?')" "$([ "$n" -eq 0 ] && echo ok || echo "gaps:$n")"
  done <<EOF
$(registry_lines)
EOF
}

cmd_ensure() {
  local line id gap
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [[ "$line" =~ $REGISTRY_LINE_RE ]]; then id=${BASH_REMATCH[1]}; else id='?'; fi
    while IFS= read -r gap; do
      [ -n "$gap" ] && printf 'OFFICE: office %s: %s\n' "$id" "$gap"
    done <<EOF
$(office_problems "$line")
EOF
  done <<EOF
$(registry_lines)
EOF
  return 0
}

cmd_status() {
  local id args
  id=$(cat "$FM_HOME/.fm-office" 2>/dev/null) || return 0
  [[ "$id" =~ ^[a-z0-9-]+$ ]] || { echo "office-status: .fm-office in $FM_HOME is not an office id" >&2; return 1; }
  args=(--office "$id" --data "$DATA" --state "$STATE"
    --refresh-secs "${FM_OFFICE_STATUS_REFRESH_SECS:-900}")
  [ -n "${FM_OFFICE_NOW:-}" ] && args+=(--now "$FM_OFFICE_NOW")
  python3 -I "$SCRIPT_DIR/fm-office-status.py" "${args[@]}"
}

publish_die() { echo "office-publish: $1" >&2; exit 1; }

cmd_publish() {
  local id=${1:-} home lock report status reason rc=0
  [ "$#" -eq 1 ] && [[ "$id" =~ ^[a-z0-9-]+$ ]] || publish_die "usage: fm-office.sh publish <id>"
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] \
    || publish_die "only the main home publishes office authority, and $FM_HOME is a second-mate home"
  secondmate_registry_line_for_id "$DATA/secondmates.md" "$id" \
    || publish_die "$id is not a registered second mate in $DATA/secondmates.md"
  [ "$SECONDMATE_REGISTRY_REMOTE" != 1 ] \
    || publish_die "second mate $id is on a remote route; bin/fm-config-push.sh publishes its record with the rest of its inherited config"
  home=${SECONDMATE_REGISTRY_HOME/#\~/$HOME}
  home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || publish_die "second mate $id's home $SECONDMATE_REGISTRY_HOME is missing"
  [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] \
    && [ "$(tr -d '[:space:]' < "$home/.fm-secondmate-home")" = "$id" ] \
    || publish_die "$home is not the seeded home of second mate $id (its .fm-secondmate-home does not name $id)"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$SCRIPT_DIR/fm-config-inherit-lib.sh"
  lock=$(fm_config_inherit_lock_path "$home") || publish_die "cannot resolve $home's inheritance lock"
  mkdir -p "$home/state" || publish_die "cannot create $home/state"
  fm_lock_acquire_wait "$lock" || publish_die "cannot acquire $home's inheritance lock"
  report=$(mktemp "${TMPDIR:-/tmp}/fm-office-publish.XXXXXX") || { fm_lock_release "$lock"; publish_die "cannot create a report file"; }
  FM_INHERITABLE_CONFIG=office-authority FM_CONFIG_INHERIT_REPORT=$report \
    propagate_inheritable_config "$CONFIG" "$home/config" "$FM_HOME" "$id" "$DATA" 2>/dev/null || rc=1
  fm_lock_release "$lock" || true
  IFS=$'\t' read -r _ status reason < "$report" || status=error
  rm -f "$report"
  printf 'office %s: %s%s\n' "$id" "${status:-error}" "${reason:+ - $reason}"
  [ "$rc" -eq 0 ] && [ "$status" != error ]
}

status_die() { echo "office-status: $1" >&2; exit 1; }

require_office_home() {
  [ -f "$FM_HOME/.fm-office" ] || status_die "$FM_HOME is not an office home (no .fm-office marker)"
}

cmd_arm_status() {
  local home want device tmp
  require_office_home
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || status_die "cannot resolve FM_HOME $FM_HOME"
  want=$(printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-office.sh arm-status - office status check; retire with fm-office.sh disarm-status.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-office.sh") status")
  mkdir -p "$STATE" || status_die "cannot create $STATE"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || status_die "state directory is unavailable"
  device=$(fm_pr_file_device "$STATE") || status_die "state directory is unavailable"
  fm_pr_regular_destination_on_device_or_absent "$STATUS_CHECK" "$device" \
    || status_die "refusing to replace $STATUS_CHECK"
  tmp=$(umask 077; mktemp "$STATE/.fm-office-check.XXXXXX") || status_die "cannot write $STATUS_CHECK"
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$STATUS_CHECK"; then
    rm -f -- "$tmp"
    status_die "cannot write $STATUS_CHECK"
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$STATUS_CHECK_ID" >/dev/null \
    || status_die "could not register $STATUS_CHECK"
}

cmd_disarm_status() {
  require_office_home
  if [ -e "$STATUS_CHECK" ] || [ -e "$STATE/$STATUS_CHECK_ID.check-trust" ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$STATUS_CHECK_ID" >/dev/null \
      || status_die "could not unregister $STATUS_CHECK"
  fi
}

die() {
  printf 'fm-office: %s\n' "$1" >&2
  exit "${2:-1}"
}

now_epoch() {
  case "${FM_OFFICE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_OFFICE_NOW" ;;
  esac
}

# source_check_id <source>: the watcher check id of a source, e.g. lane:surgeon:high -> office-lane-surgeon-high.
source_check_id() {
  printf 'office-%s\n' "${1//:/-}"
}

# office_context: sets OFFICE_ID, OFFICE_PARENT (the local parent home) and OFFICE_LINE
# (this office's line in the parent's data/offices.md); returns 1 when any is unavailable.
office_context() {
  local line
  OFFICE_ID=$(cat "$FM_HOME/.fm-office" 2>/dev/null) || return 1
  [[ "$OFFICE_ID" =~ ^[a-z0-9-]+$ ]] || return 1
  fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" || return 1
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || return 1
  OFFICE_PARENT=$FM_SECONDMATE_PARENT_HOME
  OFFICE_LINE=
  while IFS= read -r line; do
    [[ "$line" =~ $REGISTRY_LINE_RE ]] || continue
    [ "${BASH_REMATCH[1]}" = "$OFFICE_ID" ] && { OFFICE_LINE=$line; break; }
  done <<EOF
$(REGISTRY="$OFFICE_PARENT/data/offices.md" registry_lines)
EOF
  [ -n "$OFFICE_LINE" ]
}

cmd_register_sources() {
  local sources src id shim want tmp device home keep=' ' f
  [ -e "$FM_HOME/.fm-office" ] || die "register-sources runs only in an office home (no .fm-office marker in $FM_HOME)" 3
  office_context || die "cannot read this office's line in the parent's data/offices.md" 3
  sources=$(line_field "$OFFICE_LINE" sources || true)
  [ -n "$sources" ] || die "the office line lists no sources" 3
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "cannot resolve FM_HOME $FM_HOME"
  mkdir -p "$STATE" || die "cannot create $STATE"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  device=$(fm_pr_file_device "$STATE") || die "state directory is unavailable"
  for src in ${sources//,/ }; do
    case "$src" in
      tick|upstream|lane:*) ;;
      *) die "unknown source $src" 3 ;;
    esac
    id=$(source_check_id "$src")
    fm_pr_task_id_valid "$id" || die "invalid source $src"
    shim="$STATE/$id.check.sh"
    want=$(printf '%s\n' \
      '#!/usr/bin/env bash' \
      "# Auto-generated by fm-office.sh register-sources - office source check; re-run register-sources to repair." \
      "export FM_HOME=$(printf '%q' "$home")" \
      "exec $(printf '%q' "$SCRIPT_DIR/fm-office.sh") check $(printf '%q' "$src")")
    fm_pr_regular_destination_on_device_or_absent "$shim" "$device" || die "refusing to replace $shim"
    tmp=$(umask 077; mktemp "$STATE/.fm-office-check.XXXXXX") || die "cannot write $shim"
    if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$shim"; then
      rm -f -- "$tmp"
      die "cannot write $shim"
    fi
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$id" >/dev/null \
      || die "could not register $shim"
    keep="$keep$id "
    printf 'registered: office source %s (state/%s.check.sh)\n' "$src" "$id"
  done
  for f in "$STATE"/office-tick.check.sh "$STATE"/office-upstream.check.sh "$STATE"/office-lane-*.check.sh; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .check.sh)
    case "$keep" in *" $id "*) continue ;; esac
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$id" >/dev/null \
      || die "could not unregister state/$id.check.sh"
    printf 'unregistered: state/%s.check.sh (no longer a listed source)\n' "$id"
  done
}

# seen_once <name> <stamp> <line>: prints the line unless the stamp is the last one reported.
seen_once() {
  local rec="$DATA/office/$1.seen"
  [ "$(cat "$rec" 2>/dev/null)" = "$2" ] && return 0
  mkdir -p "$DATA/office" 2>/dev/null && printf '%s\n' "$2" > "$rec" 2>/dev/null || return 0
  printf '%s\n' "$3"
}

# lane_digest <officer>: sets LANE_KEY, LANE_N and LANE_PATH (an absolute path) from the parent's digest file.
lane_digest() {
  local digest
  digest=$(cat "$OFFICE_PARENT/data/officers/$1/digest" 2>/dev/null) || return 1
  [[ "$digest" =~ ^DIGEST\ ([0-9T-]{10,13})\ ([0-9]+)\ (.+)$ ]] || return 1
  LANE_KEY=${BASH_REMATCH[1]}
  LANE_N=${BASH_REMATCH[2]}
  LANE_PATH=${BASH_REMATCH[3]}
  case "$LANE_PATH" in /*) ;; *) LANE_PATH="$OFFICE_PARENT/$LANE_PATH" ;; esac
  case "$LANE_PATH" in *..*) return 1 ;; esac
  return 0
}

# high_findings <digest .md path>: the number of high or critical findings in the sibling .json.
high_findings() {
  python3 -I -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        doc = json.load(f)
    items = doc.get("findings", []) if isinstance(doc, dict) else doc
    n = 0
    for it in items:
        sev = it.get("severity") if isinstance(it, dict) else None
        if isinstance(sev, str) and sev.strip().lower() in ("high", "critical"):
            n += 1
        elif isinstance(sev, int) and not isinstance(sev, bool) and sev >= 4:
            n += 1
    print(n)
except Exception:
    print(0)
' "${1%.md}.json" 2>/dev/null || echo 0
}

# count_live: this home's ship and scout task records.
count_live() {
  local meta kind n=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    kind=$(sed -n 's/^kind=//p' "$meta" 2>/dev/null | tail -n 1)
    case "$kind" in ship|scout) n=$((n + 1)) ;; esac
  done
  printf '%s\n' "$n"
}

# count_queued: unheld, unblocked items in the backlog's Queued section.
count_queued() {
  awk '
    /^## / { inq = ($0 == "## Queued"); next }
    inq && /^- \[ \] / && $0 !~ /\(hold: / && $0 !~ /blocked-by:/ { n++ }
    END { print n + 0 }
  ' "$DATA/backlog.md" 2>/dev/null || echo 0
}

# unread_lanes: how many of the office's lane sources have a digest it has not yet reported.
unread_lanes() {
  local src officer n=0 seen
  for src in ${1//,/ }; do
    case "$src" in lane:*:high) continue ;; lane:*) ;; *) continue ;; esac
    officer=${src#lane:}
    lane_digest "$officer" || continue
    [ "$LANE_N" -gt 0 ] || continue
    seen=$(cat "$DATA/office/lane-$officer.seen" 2>/dev/null || true)
    [ "$seen" = "$LANE_KEY $LANE_N $LANE_PATH" ] || n=$((n + 1))
  done
  printf '%s\n' "$n"
}

check_tick() {
  local cadence wip live free queued unread sources line
  cadence=$(line_field "$OFFICE_LINE" tick || true)
  wip=$(line_field "$OFFICE_LINE" wip || true)
  [[ "$cadence" =~ ^every\ ([1-9]|1[0-9]|2[0-4])h$ ]] && [[ "$wip" =~ ^[1-9]$ ]] || return 0
  slot_of "$cadence" "$(now_epoch)"
  live=$(count_live)
  free=$((wip - live))
  [ "$free" -gt 0 ] || return 0
  queued=$(count_queued)
  sources=$(line_field "$OFFICE_LINE" sources || true)
  unread=$(unread_lanes "$sources")
  [ "$queued" -gt 0 ] || [ "$unread" -gt 0 ] || return 0
  line="office $OFFICE_ID: tick $SLOT_KEY: $free of $wip places free, $queued queued"
  [ "$unread" -eq 0 ] || line="$line, $unread unread digest(s)"
  seen_once tick "$SLOT_KEY" "$line"
}

# deliver_starts <officer>: delivers the progress digest's start requests addressed to this
# office home into its own inbox, in rank order, and prints one phrase when there is news.
deliver_starts() {
  mkdir -p "$DATA/office" 2>/dev/null || return 0
  python3 -I - "${LANE_PATH%.md}.json" "$FM_HOME" "$SCRIPT_DIR/fm-inbox.sh" \
    "$DATA/office/lane-$1-starts.seen" "$LANE_KEY" "$(now_epoch)" <<'PY' 2>/dev/null || true
import datetime, hashlib, json, os, re, subprocess, sys
path, home, inbox, seen_path, key, now = sys.argv[1:7]
try:
    raw = open(path, "rb").read()
    doc = json.loads(raw)
except (OSError, ValueError):
    sys.exit()
if not isinstance(doc, dict) or doc.get("source") not in ("progress-officer", "surgeon-officer"):
    sys.exit()
home = os.path.realpath(home)
requests = sorted((r for r in doc.get("start_requests") or [] if isinstance(r, dict)),
                  key=lambda r: r.get("rank") if isinstance(r.get("rank"), int) else 1 << 30)
mine = [r.get("execute") for r in requests if isinstance(r.get("execute"), dict)
        and isinstance((r["execute"].get("env") or {}).get("FM_HOME"), str)
        and os.path.realpath(r["execute"]["env"]["FM_HOME"]) == home]
if not mine:
    sys.exit()
stamp = key + " " + hashlib.sha256(raw).hexdigest()
try:
    last = open(seen_path).read().strip()
except OSError:
    last = ""
if last in ("delivered " + stamp, "stale " + stamp):
    sys.exit()
def record(state, phrase):
    with open(seen_path + ".tmp", "w") as fh:
        fh.write(state + " " + stamp + "\n")
    os.replace(seen_path + ".tmp", seen_path)
    print(phrase)
try:
    generated = datetime.datetime.fromisoformat(doc["generated_at"].replace("Z", "+00:00")).timestamp()
except (KeyError, AttributeError, ValueError):
    generated = None
if generated is None or int(now) - generated > 36 * 3600:
    record("stale", "digest older than 36 hours, %d start request(s) for this office not delivered" % len(mine))
    sys.exit()
for n, execute in enumerate(mine, 1):
    rid, argv = execute.get("request_id"), execute.get("argv")
    # Run this office's own intake with the recorded arguments, never a program named in the file.
    ok = (execute.get("action") == "start" and isinstance(rid, str)
          and re.fullmatch(r"(?:progress|surgeon)-\d{4}-\d{2}-\d{2}-[0-9a-f]{16}", rid) and isinstance(argv, list)
          and len(argv) == 7 and all(isinstance(a, str) for a in argv)
          and os.path.basename(argv[0]) == "fm-inbox.sh" and argv[1:6] == ["note", "--request-id", rid, "--json", "--"])
    if ok:
        ok = subprocess.run([inbox] + argv[1:], env=dict(os.environ, FM_HOME=home),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if not ok:
        if last != "failed " + stamp:
            record("failed", "start request %d of %d could not be delivered; the next check retries it" % (n, len(mine)))
        sys.exit()
record("delivered", "%d start request(s) delivered to this office's inbox" % len(mine))
PY
}

check_lane() {  # <officer> <high:0|1>
  local officer=$1 high=$2 n line='' starts
  lane_digest "$officer" || return 0
  starts=$(deliver_starts "$officer")
  if [ "$high" = 1 ]; then
    n=$(high_findings "$LANE_PATH")
    [ "$n" -gt 0 ] && line=$(seen_once "lane-$officer-high" "$LANE_KEY $n" \
      "office $OFFICE_ID: $officer digest $LANE_KEY: $n high-severity finding(s) in $LANE_PATH")
  else
    [ "$LANE_N" -gt 0 ] && line=$(seen_once "lane-$officer" "$LANE_KEY $LANE_N $LANE_PATH" \
      "office $OFFICE_ID: $officer digest $LANE_KEY: $LANE_N finding(s) in $LANE_PATH")
  fi
  [ -z "$starts" ] || line="${line:-office $OFFICE_ID: $officer digest $LANE_KEY}; $starts"
  [ -z "$line" ] || printf '%s\n' "$line"
}

# bounded <seconds> <command...>: runs the command under timeout when the host has it.
bounded() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

# upstream_fail <src>: records a failed attempt; reports once when failures span 24 hours.
upstream_fail() {
  local rec="$DATA/office/upstream.fail" first now
  now=$(now_epoch)
  first=$(cat "$rec" 2>/dev/null || true)
  case "$first" in
    *reported*) return 0 ;;
    ''|*[!0-9]*) printf '%s\n' "$now" > "$rec" 2>/dev/null; return 0 ;;
  esac
  [ $((now - first)) -ge 86400 ] || return 0
  printf '%s reported\n' "$first" > "$rec" 2>/dev/null || return 0
  printf 'office %s: upstream %s unreachable since %s\n' "$OFFICE_ID" "$1" \
    "$(date -u -d "@$first" +%Y-%m-%d 2>/dev/null || date -u -r "$first" +%Y-%m-%d)"
}

check_upstream() {
  local cfg="$CONFIG/firstmate-upstream" src branch fork now day last head forkref base n subjects
  local rec="$DATA/office" ref=refs/fm-upstream-check/head
  [ -r "$cfg" ] || return 0
  read -r src branch fork < <(grep -Ev '^[[:space:]]*(#|$)' "$cfg" | head -n 1) || true
  [ -n "${src:-}" ] || return 0
  branch=${branch:-main}
  forkref=${fork:-origin/main}
  now=$(now_epoch)
  day=$(date -u -d "@$now" +%Y-%m-%d 2>/dev/null || date -u -r "$now" +%Y-%m-%d)
  [ "$(cat "$rec/upstream.day" 2>/dev/null)" = "$day" ] && return 0
  mkdir -p "$rec" 2>/dev/null || return 0
  last=$(cat "$rec/upstream.try" 2>/dev/null || true)
  case "$last" in ''|*[!0-9]*) ;; *) [ $((now - last)) -ge 3600 ] || return 0 ;; esac
  printf '%s\n' "$now" > "$rec/upstream.try" 2>/dev/null || return 0
  head=$(bounded 30 git -C "$FM_ROOT" ls-remote "$src" "refs/heads/$branch" 2>/dev/null | awk 'NR==1{print $1}')
  if ! [[ "$head" =~ ^[0-9a-f]{40}$ ]]; then upstream_fail "$src"; return 0; fi
  case "$forkref" in */*) bounded 60 git -C "$FM_ROOT" fetch --quiet --no-tags "${forkref%%/*}" "${forkref#*/}" >/dev/null 2>&1 || true ;; esac
  if [ "$(cat "$rec/upstream.seen" 2>/dev/null)" = "$head" ]; then
    rm -f "$rec/upstream.fail"; printf '%s\n' "$day" > "$rec/upstream.day" 2>/dev/null; return 0
  fi
  git -C "$FM_ROOT" rev-parse -q --verify "$forkref^{commit}" >/dev/null 2>&1 || return 0
  bounded 120 git -C "$FM_ROOT" fetch --quiet --no-tags "$src" "+refs/heads/$branch:$ref" >/dev/null 2>&1 \
    || { upstream_fail "$src"; return 0; }
  rm -f "$rec/upstream.fail"
  printf '%s\n' "$day" > "$rec/upstream.day" 2>/dev/null
  printf '%s\n' "$head" > "$rec/upstream.seen" 2>/dev/null
  n=$(git -C "$FM_ROOT" rev-list --count "$forkref..$ref" 2>/dev/null) || return 0
  [ "${n:-0}" -gt 0 ] || return 0
  base=$(git -C "$FM_ROOT" merge-base "$forkref" "$ref" 2>/dev/null | cut -c1-9)
  subjects=$(git -C "$FM_ROOT" log -n 3 --format=%s "$forkref..$ref" 2>/dev/null | cut -c1-80 | paste -sd'|' - | sed 's/|/ | /g')
  printf 'office %s: upstream %s..%s: %s new commit(s) not in %s; newest: %s\n' \
    "$OFFICE_ID" "${base:-none}" "$(printf '%s' "$head" | cut -c1-9)" "$n" "$forkref" "$subjects"
}

cmd_check() {
  local src=$1 sources officer
  [ -e "$FM_HOME/.fm-office" ] || return 0
  office_context || return 0
  sources=$(line_field "$OFFICE_LINE" sources || true)
  case ",${sources// /}," in *",$src,"*) ;; *) return 0 ;; esac
  case "$src" in
    tick) check_tick ;;
    upstream) check_upstream ;;
    lane:*:high) officer=${src#lane:}; check_lane "${officer%:high}" 1 ;;
    lane:*) check_lane "${src#lane:}" 0 ;;
  esac
  return 0
}

case "${1:-}" in
  list) cmd_list ;;
  ensure) cmd_ensure ;;
  publish) shift; cmd_publish "$@" ;;
  status) cmd_status ;;
  arm-status) cmd_arm_status ;;
  disarm-status) cmd_disarm_status ;;
  register-sources) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_register_sources ;;
  check) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; cmd_check "$2" ;;
  -h|--help|help|'') usage ;;
  *) usage >&2; exit 2 ;;
esac
