#!/usr/bin/env bash
# fm-office.sh - the office registry, wake sources and status: list offices,
# report gaps, run an office's own wake-source checks, and project an office
# home's work onto its status file.
#
# An office is a second mate that runs a standing role mandate (navigator,
# quartermaster, alchemist or librarian) instead of idling. docs/configuration.md "Offices
# (data/offices.md)" owns the registry schema; this header owns the mechanics.
#
# Usage:
#   fm-office.sh list
#   fm-office.sh ensure
#   fm-office.sh unprovisioned
#   fm-office.sh publish <id>
#   fm-office.sh feed <id>
#   fm-office.sh feed-sweep
#   fm-office.sh arm-feed
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
# ensure also prints one "OFFICE: pool: <gap>" line per project whose clones on
# this host differ on treehouse max_trees (bin/fm-treehouse-toml-lib.sh).
#
# ensure (run by bin/fm-bootstrap.sh) prints one "OFFICE: office <id>: <gap>"
# line per mismatch between data/offices.md and the fleet, and nothing when
# they agree. An absent data/offices.md means no offices. A gap is a malformed
# line, an unknown role, a bad value for a key, a runs-on host that is not
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
# skipped; for it ensure reports only a feed-sweep check that is not registered,
# and a feed or lane over its size limit (bin/fm-office-feed-lib.sh).
#
# unprovisioned (also the last step of ensure) is the check that an approved office
# cannot go unbuilt unnoticed. In a primary home only (it keeps data/offices.md and has no
# .fm-secondmate-home or .fm-office marker), every role in FM_OFFICE_ROLES needs a data/offices.md line whose
# role is it, or a valid deferral line in data/office-deferrals.md; a role with neither
# prints "OFFICE: approved office <role> not provisioned (...)". A deferral is a registry
# line `- <role> - "<Lee's words>" (said: <where and when>; until: YYYY-MM-DD; added
# YYYY-MM-DD)` with until optional and no parentheses inside the fields (write a relay
# citation as "relayed by main, corr <id>"); one that is malformed or past its until date (UTC) is
# reported as "OFFICE: deferral ..." and defers nothing. The heartbeat in the watcher
# wakes firstmate with these lines at most once a day until they are gone.
#
# publish <id> (run in the main home) pushes that one office's authority record
# into its home now: config/office-authority and its receipt
# config/.fm-inherit-office-authority.generation, through the same
# inherited-config propagation and per-home lock that bin/fm-config-push.sh
# uses, restricted to that item. bin/fm-office-authority-lib.sh owns what the
# record holds and when a home receives an absence instead. <id> must be a
# second mate registered in data/secondmates.md on a local route, whose home's
# .fm-secondmate-home names it, or a remote route. A remote office's record and
# its feed (below) are sent through the ordinary remote inherit push
# (bin/fm-remote-inherit-push.sh) restricted to those two items, under the route's
# transaction lock and with the next generation; the remote home's gates then
# trust the record exactly as a local office's do. publish also arms feed-sweep
# in this home (arm-feed). publish refuses in a second-mate home. It prints one
# line, "office <id>: <pushed|unchanged|error> [reason]", and exits non-zero on
# an error. When a remote office's feed or one of its lanes is over its size
# limit, publish sends the record alone, keeps the remote office's last feed,
# prints "office <id>: feed not pushed: <why>" and exits non-zero. Every convergence point (secondmate spawn, the bootstrap secondmate
# sweep, bin/fm-config-push.sh) publishes the same record, and the feed too.
#
# feed <id> (run in the main home) sends only a remote office's feed now:
# config/office-feed, the copy of its own line in data/offices.md and of each
# lane officer's digest, its .json and the start requests addressed to that
# office, which a home on another host cannot read from the parent
# (bin/fm-office-feed-lib.sh owns the format). It prints the same one line as
# publish, including the "feed not pushed" line, after which it sends nothing. feed-sweep is the watcher check that keeps the copy current: for each
# remote office it sends the feed when the copy's content changed since the last
# send, or the last send is over FM_OFFICE_FEED_REFRESH_SECS (default 21600)
# old, never more often than every FM_OFFICE_FEED_RETRY_SECS (default 120) for one
# office, within one 25 second bound for the whole sweep. It prints nothing,
# except one "OFFICE: office <id>: feed not pushed: <why>" line the first time
# that office's feed or a given lane goes over its size limit (record:
# state/office-feed.<id>.over, cleared once the feed fits; FM_OFFICE_FEED_SWEEP_REPORT=0
# neither prints nor records it); the oversized feed is not sent. arm-feed (run once in the main home)
# writes state/office-feed.check.sh, a shim that execs "fm-office.sh feed-sweep",
# and binds it with bin/fm-check-register.sh; running it again rewrites the same
# bytes. A new digest therefore reaches a remote office within one parent
# watcher sweep plus the push.
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
# (tick -> office-tick, upstream -> office-upstream, ratchet -> office-ratchet, research -> office-research,
# lane:progress -> office-lane-progress, lane:surgeon:high -> office-lane-surgeon-high),
# and binds each with fm-check-register.sh. Each shim exports FM_HOME for the
# office home and execs "fm-office.sh check <source>". It is idempotent, and it
# unregisters an office-tick, office-upstream, office-ratchet, office-research or office-lane-*
# shim whose source is no longer listed. The office's own watcher sweeps state/*.check.sh, so a source wakes the office and never main.
#
# check <source> is the body of a source check. It is fast, contacts no other
# host (except the upstream source, below), always exits 0, and prints one line at most:
#   tick             "office <id>: tick <YYYY-MM-DDTHH>: <n> of <wip> places free, <q> queued"
#                    (then ", <d> unread digest(s)" and ", <l> landing" when not 0)
#                    once per slot of the registry line's tick: cadence, when a
#                    place is free (fm_office_live_tasks in
#                    bin/fm-office-authority-lib.sh counts fewer than wip) and
#                    work could start: an unheld, unblocked Queued item in
#                    data/backlog.md, or an unread lane digest. Silent otherwise.
#   lane:<officer>   "office <id>: <officer> digest <key>: <n> finding(s) in <path>"
#                    once per new digest with n > 0, read from the parent's
#                    data/officers/<officer>/digest (a local parent route), or,
#                    on a remote office home, from the copy in config/office-feed,
#                    whose files it writes under data/office/feed/ and names in
#                    its line.
#   lane:<officer>:high
#                    "office <id>: <officer> digest <key>: <n> high-severity finding(s) in <path>"
#                    once per new count of findings in the digest's .json whose
#                    severity is "high" or "critical", or a number of 4 or more.
# Either lane form, reading a progress, surgeon, friction, corpus, library or page-check digest (.json source
# "progress-officer", "surgeon-officer", "friction-officer", "corpus-officer", "library-officer" or "page-check-officer"),
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
# in the office home. An unreadable file, an unregistered
# source or a home that is not an office is silent, and so is a remote office
# whose config/office-feed is missing, malformed, for another office, or older
# than FM_OFFICE_FEED_MAX_AGE (default 36 hours); on a remote office home that
# copy supplies the office's line too, so every source reads it and never the
# parent. Start delivery runs
# fm-inbox.sh in this home only; nothing in the parent is written.
#
#   upstream         "office <id>: upstream <old>..<new>: <n> new commit(s) not in <fork-ref>; newest: <subject> | ..."
#                    once per new upstream head, read from config/firstmate-upstream
#                    (one line: <remote-or-url> [<branch>] [<fork-ref>]; branch defaults to
#                    main, fork-ref to origin/main; absent file: silent). It tries at most
#                    once an hour and, after a success, once per UTC day. It is the one
#                    source that contacts another host (git ls-remote, then a bounded fetch
#                    into refs/fm-upstream-check/head of this code root, only for a head not
#                    yet reported; the network calls together stay under the watcher's 30s
#                    check limit). It is silent when upstream has nothing the fork lacks,
#                    and on a failed attempt until failures span 24 hours, when it reports
#                    "upstream check of <src> against <fork-ref> failing since <date>; ..."
#                    once per failure streak. An attempt counts as failed until it succeeds,
#                    so a killed attempt or a fork-ref that does not resolve counts too; a
#                    gap of more than 2 hours since the last attempt starts a new streak.
#                    <old> is the merge base. Records: data/office/upstream.seen (last
#                    head reported or found empty), upstream.day (last successful UTC
#                    day), upstream.try (last attempt) and upstream.fail (first failure
#                    epoch, with a "reported" suffix once reported).
#   ratchet          "office <id>: ratchet <YYYY-MM-DD>: next file <path> (<n> left on bin/fm-lint-ratchet.exceptions); if no ratchet PR for <path> is open, ..."
#                    once per UTC day while this code root's lint ratchet list
#                    (bin/fm-lint-ratchet.sh next) names a file; silent when the list is
#                    empty. Record: data/office/ratchet.seen (last day reported). The
#                    office skips the day while a ratchet PR for that file is still open,
#                    and otherwise dispatches one ordinary ship worker for it, which fixes
#                    it, retires it from the list and opens one pull request.
#   research         "office <id>: research <YYYY-MM-DD>: <n> proposal(s), <k> knowledge line(s) appended; digest <path>"
#                    once per complete weekly tooling-research run directory (report.md,
#                    suggestions.json and result.json present), oldest unseen first, one per
#                    check. Runs root: config/tooling-research-runs (one line; default
#                    /home/lee/fm-homes/slarti/data/tooling-research/runs). It appends the run's
#                    "Lines for knowledge.md" to config/tooling-research-knowledge (default
#                    data/tooling-research/knowledge.md) and writes data/office/research/<run>.md
#                    with each proposal's id and text, plus once per ISO week the follow-through of
#                    the data/*/report.md reports of the parent and office homes. A malformed
#                    suggestions.json is named in the line, never guessed. The first check, before
#                    data/office/research.seen exists, records the runs already there and
#                    delivers none. A helper failure or timeout is silent until failures span an
#                    hour, then "office <id>: research check failing since <time> (exit <n>): <last
#                    line>" once per streak (record data/office/research.fail). It starts and files
#                    nothing; bin/fm-office-research.py owns the mechanics and
#                    data/office/research.seen the delivered runs.
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
FEED_CHECK_ID=office-feed
FEED_CHECK="$STATE/$FEED_CHECK_ID.check.sh"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-registry-line-lib.sh
. "$SCRIPT_DIR/fm-registry-line-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-treehouse-toml-lib.sh
. "$SCRIPT_DIR/fm-treehouse-toml-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-office-authority-lib.sh
. "$SCRIPT_DIR/fm-office-authority-lib.sh"
# shellcheck source=bin/fm-office-feed-lib.sh
. "$SCRIPT_DIR/fm-office-feed-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-office.sh list      list registered offices and their state
  fm-office.sh ensure    session-start health: one OFFICE: line per gap
  fm-office.sh unprovisioned    OFFICE: lines for approved roles with no office line or valid deferral
  fm-office.sh publish <id>   push that office's authority record into its home now
  fm-office.sh feed <id>      send a remote office its copy of its line and lane digests now
  fm-office.sh feed-sweep     (watcher check) keep every remote office's copy current
  fm-office.sh arm-feed       register feed-sweep as this home's silent watcher check
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
    printf 'sources must list tick, upstream, ratchet, research or lane:<officer-id>[:high]\n'
  else
    for p in ${v//,/ }; do
      case "$p" in
        tick|upstream|ratchet|research) ;;
        lane:*)
          p=${p#lane:}; p=${p%:high}
          grep -Eq "^- $p - " "$DATA/officers.md" 2>/dev/null \
            || printf 'source lane:%s is not a registered officer\n' "$p"
          ;;
        *) printf 'source "%s" must be tick, upstream, ratchet, research, lane:<officer-id> or lane:<officer-id>:high\n' "$p" ;;
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
    fm_custom_check_registered "$STATE" "$FEED_CHECK_ID" \
      || printf 'it is on a remote route and %s is not registered in %s (run bin/fm-office.sh arm-feed, or publish %s)\n' "$FEED_CHECK_ID" "$STATE" "$id"
    feed_stage "$id"
    [ -z "$FEED_OVER" ] || printf '%s\n' "$FEED_REASON"
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
  cmd_unprovisioned
  fm_th_mismatches | while IFS= read -r gap; do printf 'OFFICE: pool: %s\n' "$gap"; done
  return 0
}

# One deferral line is valid when it is a registry line for a known role whose words
# are quoted, with a said: field and an until: date (when present) that is a real date
# not before today. Prints "valid" or the reason; today comes from FM_OFFICE_TODAY or UTC.
deferral_state() {  # <line>
  local line=$1 words said until today=${FM_OFFICE_TODAY:-$(date -u +%Y-%m-%d)}
  if ! [[ "$line" =~ $REGISTRY_LINE_RE ]]; then echo "malformed deferral line"; return; fi
  words=${BASH_REMATCH[2]}
  fm_office_role_check "${BASH_REMATCH[1]}" || { echo "$FM_OFFICE_ERROR"; return; }
  [[ "$words" =~ ^\"[^\"]*\"\ \( ]] && { echo "its fields contain parentheses, which a deferral line must not"; return; }
  [[ "$words" =~ ^\".+\"$ ]] || { echo "its words are not Lee's quoted words"; return; }
  said=$(line_field "$line" said || true)
  [ -n "$said" ] || { echo "no said: field naming where and when Lee said it"; return; }
  until=$(line_field "$line" until || true)
  if [ -n "$until" ]; then
    if ! [[ "$until" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]; then
      echo "until: is not a YYYY-MM-DD date"; return
    fi
    if [[ "$until" < "$today" ]]; then echo "expired on $until"; return; fi
  fi
  echo valid
}

cmd_unprovisioned() {
  local role line deferrals="$DATA/office-deferrals.md" deferred=' ' id state have
  [ -f "$REGISTRY" ] && [ ! -e "$FM_HOME/.fm-secondmate-home" ] && [ ! -e "$FM_HOME/.fm-office" ] || return 0
  if [ -f "$deferrals" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      state=$(deferral_state "$line")
      id=$(printf '%s' "$line" | cut -d' ' -f2)
      if [ "$state" = valid ]; then deferred="$deferred$id "
      else printf 'OFFICE: deferral %s in %s defers nothing: %s\n' "$id" "$deferrals" "$state"; fi
    done <<EOF
$(grep -E '^- ' "$deferrals" || true)
EOF
  fi
  have=' '
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    have="$have$(line_field "$line" role || true) "
  done <<EOF
$(registry_lines)
EOF
  for role in $FM_OFFICE_ROLES; do
    case "$have$deferred" in *" $role "*) continue ;; esac
    printf 'OFFICE: approved office %s not provisioned (no %s line for it, and no valid deferral in %s)\n' \
      "$role" "$REGISTRY" "$deferrals"
  done
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

# remote_push <id> <items>: one remote inherit push of just those inherited items, under the route's
# transaction lock and with the next generation, as a convergence push runs it; it sends no reread
# nudge, because the office's checks and gates read these files when they run. Sets PUSH_STATUS
# (pushed, unchanged or error) and PUSH_REASON; returns 1 on an error.
remote_push() {
  local id=$1 items=$2 lock gen out rc=0
  PUSH_STATUS=error
  PUSH_REASON=
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-secondmate-nudge-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"
  lock=$(fm_remote_inherit_transaction_lock_path "$STATE" "$id") || lock=
  if [ -z "$lock" ] || ! fm_lock_acquire_wait "$lock"; then
    PUSH_REASON="cannot lock $id's remote inheritance"
    return 1
  fi
  gen=$(fm_remote_inherit_generation_next "$STATE" "$id" 2>/dev/null) || gen=
  if [ -z "$gen" ]; then
    fm_lock_release "$lock" || true
    PUSH_REASON="cannot publish the next inheritance generation"
    return 1
  fi
  out=$(FM_INHERITABLE_CONFIG="$items" "$SCRIPT_DIR/fm-remote-inherit-push.sh" "$id" "$gen" 2>&1) || rc=$?
  fm_lock_release "$lock" || true
  if [ "$rc" -ne 0 ]; then
    PUSH_REASON=$(printf '%s\n' "$out" | sed -n 's/^error: //p' | head -n 1)
    [ -n "$PUSH_REASON" ] || PUSH_REASON="the remote push exited $rc"
    return 1
  fi
  PUSH_STATUS=unchanged
  if printf '%s\n' "$out" | grep -Eq '^(pushed|removed):'; then PUSH_STATUS=pushed; fi
  return 0
}

# feed_stage <id>: sets FEED_FP to the fingerprint of the feed the parent would send now, or empty;
# when the copy or a lane is over its size limit, FEED_OVER (feed or lane:<officer>) and FEED_REASON
# ("feed not pushed: ...") say so.
feed_stage() {
  local id=$1 stage rc=0
  FEED_FP=
  FEED_OVER=
  FEED_REASON=
  stage=$(mktemp "${TMPDIR:-/tmp}/fm-office-feed.XXXXXX") || return 0
  if secondmate_registry_line_for_id "$DATA/secondmates.md" "$id"; then
    fm_office_feed_payload "$FM_HOME" "$DATA" "$id" "$SECONDMATE_REGISTRY_HOME" "$stage" "$(now_epoch)" || rc=$?
    if [ "$rc" -eq 2 ]; then
      FEED_OVER=$FM_OFFICE_FEED_OVER
      FEED_REASON=$FM_OFFICE_ERROR
    elif [ "$rc" -eq 0 ] && [ -f "$stage" ]; then
      FEED_FP=$(fm_office_feed_fingerprint "$stage")
    fi
  fi
  rm -f "$stage"
}

record_feed_push() {  # <id> <fingerprint>
  mkdir -p "$STATE" 2>/dev/null && printf '%s %s\n' "$2" "$(now_epoch)" > "$STATE/$FEED_CHECK_ID.$1.pushed" 2>/dev/null || true
}

cmd_feed() {
  local id=${1:-}
  [ "$#" -eq 1 ] && [[ "$id" =~ ^[a-z0-9-]+$ ]] || publish_die "usage: fm-office.sh feed <id>"
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] || publish_die "only the main home sends office feeds, and $FM_HOME is a second-mate home"
  secondmate_registry_line_for_id "$DATA/secondmates.md" "$id" \
    || publish_die "$id is not a registered second mate in $DATA/secondmates.md"
  [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] || publish_die "second mate $id is on a local route, which reads the parent directly"
  feed_stage "$id"
  if [ -n "$FEED_OVER" ]; then
    printf 'office %s: %s\n' "$id" "$FEED_REASON"
    return 1
  fi
  if remote_push "$id" office-feed; then
    [ -z "$FEED_FP" ] || record_feed_push "$id" "$FEED_FP"
    printf 'office %s: %s\n' "$id" "$PUSH_STATUS"
  else
    printf 'office %s: error - %s\n' "$id" "$PUSH_REASON"
    return 1
  fi
}

cmd_feed_sweep() {
  local line id fp last_fp last_at now try deadline left over_rec
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] || return 0
  now=$(now_epoch)
  deadline=$(( $(date +%s) + 25 ))
  while IFS= read -r line; do
    [[ "$line" =~ $REGISTRY_LINE_RE ]] || continue
    id=${BASH_REMATCH[1]}
    secondmate_registry_line_for_id "$DATA/secondmates.md" "$id" && [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] || continue
    feed_stage "$id"
    fp=$FEED_FP
    over_rec="$STATE/$FEED_CHECK_ID.$id.over"
    if [ -n "$FEED_OVER" ]; then
      if [ "${FM_OFFICE_FEED_SWEEP_REPORT:-1}" != 0 ] && [ "$(cat "$over_rec" 2>/dev/null)" != "$FEED_OVER" ]; then
        printf 'OFFICE: office %s: %s\n' "$id" "$FEED_REASON"
        mkdir -p "$STATE" 2>/dev/null && printf '%s\n' "$FEED_OVER" > "$over_rec" 2>/dev/null || true
      fi
      continue
    fi
    rm -f "$over_rec" 2>/dev/null || true
    [ -n "$fp" ] || continue
    read -r last_fp last_at < "$STATE/$FEED_CHECK_ID.$id.pushed" 2>/dev/null || { last_fp=; last_at=0; }
    case "$last_at" in ''|*[!0-9]*) last_at=0 ;; esac
    if [ "$last_fp" = "$fp" ] && [ $((now - last_at)) -lt "${FM_OFFICE_FEED_REFRESH_SECS:-21600}" ]; then continue; fi
    try=$(cat "$STATE/$FEED_CHECK_ID.$id.try" 2>/dev/null || echo 0)
    case "$try" in ''|*[!0-9]*) try=0 ;; esac
    [ $((now - try)) -ge "${FM_OFFICE_FEED_RETRY_SECS:-120}" ] || continue
    left=$(( deadline - $(date +%s) ))
    [ "$left" -ge 1 ] || break
    printf '%s\n' "$now" > "$STATE/$FEED_CHECK_ID.$id.try" 2>/dev/null || continue
    bounded "$left" "$SCRIPT_DIR/fm-office.sh" feed "$id" >/dev/null 2>&1 || true
  done <<EOF
$(registry_lines)
EOF
  return 0
}

cmd_arm_feed() {
  local home want device tmp
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] || publish_die "only the main home arms the office feed, and $FM_HOME is a second-mate home"
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || publish_die "cannot resolve FM_HOME $FM_HOME"
  want=$(printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-office.sh arm-feed - keeps remote office feeds current; silent.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-office.sh") feed-sweep")
  mkdir -p "$STATE" || publish_die "cannot create $STATE"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || publish_die "state directory is unavailable"
  device=$(fm_pr_file_device "$STATE") || publish_die "state directory is unavailable"
  fm_pr_regular_destination_on_device_or_absent "$FEED_CHECK" "$device" || publish_die "refusing to replace $FEED_CHECK"
  tmp=$(umask 077; mktemp "$STATE/.fm-office-check.XXXXXX") || publish_die "cannot write $FEED_CHECK"
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$FEED_CHECK"; then
    rm -f -- "$tmp"
    publish_die "cannot write $FEED_CHECK"
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$FEED_CHECK_ID" >/dev/null \
    || publish_die "could not register $FEED_CHECK"
}

cmd_publish() {
  local id=${1:-} home lock report status reason rc=0
  [ "$#" -eq 1 ] && [[ "$id" =~ ^[a-z0-9-]+$ ]] || publish_die "usage: fm-office.sh publish <id>"
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] \
    || publish_die "only the main home publishes office authority, and $FM_HOME is a second-mate home"
  secondmate_registry_line_for_id "$DATA/secondmates.md" "$id" \
    || publish_die "$id is not a registered second mate in $DATA/secondmates.md"
  if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ]; then
    cmd_arm_feed
    feed_stage "$id"
    if [ -n "$FEED_OVER" ]; then
      if remote_push "$id" office-authority; then
        printf 'office %s: %s\n' "$id" "$FEED_REASON"
        return 1
      fi
    elif remote_push "$id" "office-authority office-feed"; then
      [ -z "$FEED_FP" ] || record_feed_push "$id" "$FEED_FP"
      printf 'office %s: %s\n' "$id" "$PUSH_STATUS"
      return 0
    fi
    printf 'office %s: error - %s\n' "$id" "$PUSH_REASON"
    return 1
  fi
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

# office_context: sets OFFICE_ID, OFFICE_PARENT (the local parent home, empty on a remote route),
# OFFICE_FEED (the pushed copy's path on a remote route) and OFFICE_LINE (this office's line in the
# parent's data/offices.md); returns 1 when any is unavailable.
office_context() {
  local line
  OFFICE_ID=$(cat "$FM_HOME/.fm-office" 2>/dev/null) || return 1
  [[ "$OFFICE_ID" =~ ^[a-z0-9-]+$ ]] || return 1
  fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" || return 1
  OFFICE_LINE=
  OFFICE_FEED=
  if [ "$FM_SECONDMATE_PARENT_ROUTE" = remote ]; then
    # A home on another host reads the copy its parent pushed (bin/fm-office-feed-lib.sh), or nothing.
    fm_office_feed_load "$CONFIG/office-feed" "$OFFICE_ID" "$(now_epoch)" || return 1
    OFFICE_PARENT=
    OFFICE_FEED="$CONFIG/office-feed"
    OFFICE_LINE=$FM_OFFICE_FEED_LINE
    return 0
  fi
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || return 1
  OFFICE_PARENT=$FM_SECONDMATE_PARENT_HOME
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
      tick|upstream|ratchet|research|lane:*) ;;
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
  for f in "$STATE"/office-tick.check.sh "$STATE"/office-upstream.check.sh "$STATE"/office-ratchet.check.sh "$STATE"/office-research.check.sh "$STATE"/office-lane-*.check.sh; do
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
  if [ -n "$OFFICE_FEED" ]; then
    fm_office_feed_lane "$OFFICE_FEED" "$1" "$DATA/office/feed" || return 1
    digest=$FM_OFFICE_FEED_DIGEST
    [[ "$digest" =~ ^DIGEST\ ([0-9T-]{10,13})\ ([0-9]+)\ (.+)$ ]] || return 1
    LANE_KEY=${BASH_REMATCH[1]}
    LANE_N=${BASH_REMATCH[2]}
    LANE_PATH="$DATA/office/feed/$1.md"
    return 0
  fi
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

# count_live: this home's task records that hold a place under wip=, from the
# one count bin/fm-office-authority-lib.sh owns (fm_office_live_tasks); sets
# LIVE and LANDING, and returns 1 when a record cannot be read.
count_live() {
  fm_office_live_tasks "$STATE" '' "$OFFICE_ID" || return 1
  LIVE=$FM_OFFICE_LIVE
  LANDING=$FM_OFFICE_LANDING
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
  local cadence wip free queued unread sources line
  cadence=$(line_field "$OFFICE_LINE" tick || true)
  wip=$(line_field "$OFFICE_LINE" wip || true)
  [[ "$cadence" =~ ^every\ ([1-9]|1[0-9]|2[0-4])h$ ]] && [[ "$wip" =~ ^[1-9]$ ]] || return 0
  slot_of "$cadence" "$(now_epoch)"
  count_live || return 0
  free=$((wip - LIVE))
  [ "$free" -gt 0 ] || return 0
  queued=$(count_queued)
  sources=$(line_field "$OFFICE_LINE" sources || true)
  unread=$(unread_lanes "$sources")
  [ "$queued" -gt 0 ] || [ "$unread" -gt 0 ] || return 0
  line="office $OFFICE_ID: tick $SLOT_KEY: $free of $wip places free, $queued queued"
  [ "$unread" -eq 0 ] || line="$line, $unread unread digest(s)"
  [ "$LANDING" -eq 0 ] || line="$line, $LANDING landing"
  seen_once tick "$SLOT_KEY" "$line"
}

# check_weight: the Quartermaster's daily session-weight note (bin/fm-session-weight.sh); one line, at most once per UTC day, silent when no session is flagged. Reports only; never stops a session.
check_weight() {
  [ "$(line_field "$OFFICE_LINE" role || true)" = quartermaster ] || return 0
  local day
  day=$(date -u -d "@$(now_epoch)" +%Y-%m-%d 2>/dev/null || date -u -r "$(now_epoch)" +%Y-%m-%d)
  [ ! -e "$DATA/session-weight/$day.txt" ] || return 0
  bounded 20 "$SCRIPT_DIR/fm-session-weight.sh" --now "$(now_epoch)" --note-dir "$DATA/session-weight" --summary 2>/dev/null || true
}

# deliver_starts <officer>: delivers the progress, surgeon, friction, corpus, library or page-check digest's start requests addressed to this
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
if not isinstance(doc, dict) or doc.get("source") not in ("progress-officer", "surgeon-officer", "friction-officer", "corpus-officer", "library-officer", "page-check-officer"):
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
          and re.fullmatch(r"(?:progress|surgeon|friction|corpus|library|page-check)-\d{4}-\d{2}-\d{2}-[0-9a-f]{16}", rid) and isinstance(argv, list)
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

# upstream_fail <src> <fork-ref>: marks an attempt as failed until it succeeds; reports once when failures span 24 hours.
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
  printf 'office %s: upstream check of %s against %s failing since %s; check the remote and fork-ref in config/firstmate-upstream\n' \
    "$OFFICE_ID" "$1" "$2" "$(date -u -d "@$first" +%Y-%m-%d 2>/dev/null || date -u -r "$first" +%Y-%m-%d)"
}

check_upstream() {
  local cfg="$CONFIG/firstmate-upstream" src branch fork now day last fail head forkref base n subjects
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
  case "$last" in
    ''|*[!0-9]*) rm -f "$rec/upstream.fail" ;;
    *) [ $((now - last)) -ge 3600 ] || return 0
       [ $((now - last)) -le 7200 ] || rm -f "$rec/upstream.fail" ;;
  esac
  printf '%s\n' "$now" > "$rec/upstream.try" 2>/dev/null || return 0
  fail=$(upstream_fail "$src" "$forkref")
  [ -z "$fail" ] || { printf '%s\n' "$fail"; return 0; }
  head=$(bounded 8 git -C "$FM_ROOT" ls-remote "$src" "refs/heads/$branch" 2>/dev/null | awk 'NR==1{print $1}')
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 0
  case "$forkref" in */*) bounded 5 git -C "$FM_ROOT" fetch --quiet --no-tags "${forkref%%/*}" "${forkref#*/}" >/dev/null 2>&1 || true ;; esac
  if [ "$(cat "$rec/upstream.seen" 2>/dev/null)" = "$head" ]; then
    rm -f "$rec/upstream.fail"; printf '%s\n' "$day" > "$rec/upstream.day" 2>/dev/null; return 0
  fi
  git -C "$FM_ROOT" rev-parse -q --verify "$forkref^{commit}" >/dev/null 2>&1 || return 0
  bounded 12 git -C "$FM_ROOT" fetch --quiet --no-tags "$src" "+refs/heads/$branch:$ref" >/dev/null 2>&1 || return 0
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

# check_ratchet: once per UTC day, names the next file on this code root's lint ratchet list.
check_ratchet() {
  local now day file n
  file=$("$SCRIPT_DIR/fm-lint-ratchet.sh" next 2>/dev/null) || return 0
  n=$("$SCRIPT_DIR/fm-lint-ratchet.sh" count 2>/dev/null) || return 0
  now=$(now_epoch)
  day=$(date -u -d "@$now" +%Y-%m-%d 2>/dev/null || date -u -r "$now" +%Y-%m-%d)
  seen_once ratchet "$day" "office $OFFICE_ID: ratchet $day: next file $file ($n left on bin/fm-lint-ratchet.exceptions); if no ratchet PR for $file is open, dispatch one ship worker to fix it until bin/fm-lint-ratchet.sh check $file passes, retire it with bin/fm-lint-ratchet.sh retire $file, and open one PR"
}

# check_research: hands the next tooling-research run to bin/fm-office-research.py with this office's paths.
check_research() {
  local runs knowledge homes=() id line home h args out rc
  runs=$(grep -Ev '^[[:space:]]*(#|$)' "$CONFIG/tooling-research-runs" 2>/dev/null | head -n 1)
  knowledge=$(grep -Ev '^[[:space:]]*(#|$)' "$CONFIG/tooling-research-knowledge" 2>/dev/null | head -n 1)
  args=(--office "$OFFICE_ID" --runs "${runs:-/home/lee/fm-homes/slarti/data/tooling-research/runs}"
    --knowledge "${knowledge:-$DATA/tooling-research/knowledge.md}" --record "$DATA/office"
    --code-root "$FM_ROOT" --now "$(now_epoch)")
  homes=("$OFFICE_PARENT" "$FM_HOME")
  while IFS= read -r id; do
    secondmate_registry_line_for_id "$OFFICE_PARENT/data/secondmates.md" "$id" || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] && continue
    home=${SECONDMATE_REGISTRY_HOME/#\~/$HOME}
    for h in "${homes[@]}"; do [ "$h" = "$home" ] && continue 2; done
    homes+=("$home")
  done < <(sed -n 's/^- \([^ ]*\) - .*/\1/p' "$OFFICE_PARENT/data/offices.md" 2>/dev/null)
  for h in "${homes[@]}"; do args+=(--home "$h"); done
  out=$(bounded 20 python3 -I "$SCRIPT_DIR/fm-office-research.py" "${args[@]}" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = 0 ]; then
    rm -f "$DATA/office/research.fail"
    [ -z "$out" ] || printf '%s\n' "$out"
    return 0
  fi
  research_fail "$rc" "$(printf '%s\n' "$out" | tail -n 1)"
}

# research_fail <exit> <last output line>: marks the lane failed until a check succeeds; reports once when failures span an hour.
research_fail() {
  local rec="$DATA/office/research.fail" first now
  now=$(now_epoch)
  first=$(cat "$rec" 2>/dev/null || true)
  case "$first" in
    *reported*) return 0 ;;
    ''|*[!0-9]*) mkdir -p "$DATA/office" 2>/dev/null; printf '%s\n' "$now" > "$rec" 2>/dev/null; return 0 ;;
  esac
  [ $((now - first)) -ge 3600 ] || return 0
  printf '%s reported\n' "$first" > "$rec" 2>/dev/null || return 0
  printf 'office %s: research check failing since %s (exit %s%s): %s; nothing is delivered until it succeeds\n' \
    "$OFFICE_ID" "$(date -u -d "@$first" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$first" +%Y-%m-%dT%H:%MZ)" "$1" \
    "$([ "$1" = 124 ] && printf ', timed out after 20s')" "${2:-no output}"
}

cmd_check() {
  local src=$1 sources officer
  [ -e "$FM_HOME/.fm-office" ] || return 0
  office_context || return 0
  sources=$(line_field "$OFFICE_LINE" sources || true)
  case ",${sources// /}," in *",$src,"*) ;; *) return 0 ;; esac
  case "$src" in
    tick) check_tick; check_weight ;;
    upstream) check_upstream ;;
    ratchet) check_ratchet ;;
    research) check_research ;;
    lane:*:high) officer=${src#lane:}; check_lane "${officer%:high}" 1 ;;
    lane:*) check_lane "${src#lane:}" 0 ;;
  esac
  return 0
}

case "${1:-}" in
  list) cmd_list ;;
  ensure) cmd_ensure ;;
  unprovisioned) cmd_unprovisioned ;;
  publish) shift; cmd_publish "$@" ;;
  feed) shift; cmd_feed "$@" ;;
  feed-sweep) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_feed_sweep ;;
  arm-feed) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_arm_feed ;;
  status) cmd_status ;;
  arm-status) cmd_arm_status ;;
  disarm-status) cmd_disarm_status ;;
  register-sources) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_register_sources ;;
  check) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; cmd_check "$2" ;;
  -h|--help|help|'') usage ;;
  *) usage >&2; exit 2 ;;
esac
