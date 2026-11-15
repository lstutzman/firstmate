#!/usr/bin/env bash
# fm-external-wait-recheck.sh - re-check declared external waits so a task is not held on them.
#
# Usage: FM_HOME=<home> fm-external-wait-recheck.sh [--apply]
#
# A worker that cannot reach a service, machine or agent declares the wait with
#   paused [at=<epoch>] [cause=external] [dep=<kind>/<ref>]: <dependency> unreachable, expected back <when>; until <YYYY-MM-DDTHH:MMZ>
# (or the same tags on a `blocked` line). bin/fm-classify-lib.sh owns the line
# grammar: status_line_cause reads [cause=external] and status_line_dep reads
# [dep=...]. This sweep reads each state/*.status in FM_HOME whose current wait
# (its latest event, or the pause that no later event or resolved line retracted)
# is an external wait, and reports one verdict per wait:
#   cleared     the dependency answers a read-only re-check, so the wait is over;
#   overdue     the line's `until` time passed and the dependency did not clear
#               (or names no re-check firstmate can run);
#   waiting     a re-check ran and the dependency is still down, or the stated
#               recovery time has not passed yet;
#   unchecked   no re-check was run this pass (the per-pass cap was reached, or an
#               https host was refused before any request, see below).
# Only these dependency kinds are re-checked, each one read-only and bounded in
# time, because a status line is worker text and is never run as a command:
#   ssh/<host>                  `ssh -o BatchMode=yes <host> true` succeeds, through the
#                               user's ssh config (so Host aliases and their keys
#                               work), with no forwarding and a known host key
#   https/<host>[/<path>]       a GET of https://<host>/<path> answers without an error status;
#                               <host> must be a dotted DNS name, never a literal IP,
#                               localhost or a single label. The host is resolved first and
#                               refused (verdict unchecked, no request) when resolution fails
#                               or any address is not globally routable. IPv4 refuses 0/8,
#                               10/8, 100.64/10 (carrier-grade NAT), 127/8, 169.254/16
#                               (link-local, so cloud metadata), 172.16/12, 192.0.0/24,
#                               192.0.2/24, 192.168/16, 198.18/15, 198.51.100/24,
#                               203.0.113/24 and 224/3. IPv6 accepts only global unicast
#                               2000::/3 and inside it refuses 2001::/32 (Teredo),
#                               2001:db8::/32 and 2002::/16 (6to4), so loopback, link-local,
#                               unique-local, site-local and 64:ff9b::/96 are refused; an
#                               IPv4-mapped ::ffff:a.b.c.d is judged as its IPv4. curl is
#                               pinned to every vetted address with --resolve, ignores any
#                               curlrc (-q) and proxy (--noproxy), so a second lookup or a
#                               proxy cannot change the target; redirects are not followed
#   pr/<owner>/<repo>/<number>  that GitHub pull request is no longer open (a paused wait only;
#                               a blocked or needs-decision wait on a PR is closed by bin/fm-decision-sweep.sh)
#   task/<id>                   state/<id>.status ends in a `done` line
# Any other dependency name is kept for the repeat count but never re-checked.
# Each cleared and each overdue verdict is reported once per wait line, kept in
# state/.external-wait-recheck.seen (only with --apply) for as long as that line
# stays the task's current wait, whatever later passes find; the sweep never writes
# to a task's status log, so whoever waited is told to go on by the wake
# bin/fm-watch.sh sends, and resolves its own line as the brief says.
#
# Repeat count: every external-wait declaration that names a machine or service
# dependency (any kind but task/ and pr/, which are fan-in waits on another
# owner, not outages), across every state/*.status in FM_HOME, is counted per
# dependency (identical lines in one log count once). A dependency named by 3 or
# more declarations is reported on one `repeat` line naming it and the
# tasks, and reported again only when its count grows
# (state/.external-wait-recheck.repeat, only with --apply). Fix the outage at
# source; do not re-hold the next task on it.
#
# Output, one line per finding, then a totals line:
#   home=<home> file=<status> dep=<dep> verdict=<verdict> [until=<epoch>] [detail=<text>]
#   repeat dep=<dep> count=<n> tasks=<id>,<id>,...
#   totals mode=<dry-run|apply> waits=<n> cleared=<n> overdue=<n> waiting=<n> unchecked=<n> repeats=<n> ...
# A verdict line carries `new=1` when this run is the first to report it, which
# is the only kind the watcher wakes on.
#
# bin/fm-watch.sh runs it with --apply on its own cadence
# (FM_EXTERNAL_WAIT_RECHECK_INTERVAL_SECS, default 300 seconds, 0 turns it off).
# One pass runs at most 12 re-checks of at most 15 seconds each (an https
# re-check spends at most 5 of them resolving the host and 10 on the request),
# so it ends well inside the watcher's 300-second bound.
# Environment: FM_HOME (required), FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE.
# Exit: 0 done, 2 usage or setup error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: FM_HOME=<home> fm-external-wait-recheck.sh [--apply]" >&2; exit 2; }
APPLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    -h | --help) sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) usage ;;
  esac
  shift
done

if [ -z "${FM_HOME:-}" ] || [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME must name an existing firstmate home" >&2
  exit 2
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 2; }

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

num_or() {  # <value> <default>
  case "$1" in '' | *[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
MAX_CHECKS=12
CHECK_TIMEOUT=15
RESOLVE_TIMEOUT=5
REQUEST_TIMEOUT=$((CHECK_TIMEOUT - RESOLVE_TIMEOUT))
REPEAT_MIN=3
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
SEEN="$STATE/.external-wait-recheck.seen"
REPEATED="$STATE/.external-wait-recheck.repeat"
NOW=$(date +%s)

# Cleared dependencies are cached per run: "<dep>\t<result>" with result up,
# down or skipped. Several tasks waiting on one host cost one probe.
CACHE=''
checks=0

part_ok() {  # <text>: a non-empty host, id or path piece with no shell or option surprises
  case "$1" in '' | -* | *[!A-Za-z0-9._/-]*) return 1 ;; esac
}

dns_name_ok() {  # <host>: a dotted DNS name whose last label starts with a letter, not localhost
  case "$1" in *.*) ;; *) return 1 ;; esac
  case "$1" in *..* | .* | localhost.* | *.localhost) return 1 ;; esac
  case "${1##*.}" in [A-Za-z]*) ;; *) return 1 ;; esac
}

# Print the addresses <host> resolves to, one per line with any %zone removed,
# or fail. getent where the host has it, else python3 (macOS has no getent).
resolve_host() {  # <host>
  if command -v getent >/dev/null 2>&1; then
    fm_run_timed "$RESOLVE_TIMEOUT" getent ahosts "$1" </dev/null 2>/dev/null | awk '{ print $1 }'
  elif command -v python3 >/dev/null 2>&1; then
    fm_run_timed "$RESOLVE_TIMEOUT" python3 -I -c 'import socket, sys
for r in socket.getaddrinfo(sys.argv[1], 443, proto=socket.IPPROTO_TCP):
    print(r[4][0])' "$1" </dev/null 2>/dev/null
  else
    return 1
  fi | sed 's/%.*//' | sort -u
}

# Succeeds only for a globally routable address; every other shape fails closed.
addr_public_ok() {  # <address>
  local a o o1 o2 o3 o4 h1 h2
  a=$(printf '%s' "$1" | tr 'A-F' 'a-f')
  case "$a" in ::ffff:*.*) a=${a#::ffff:} ;; esac
  case "$a" in
    *:*)
      case "$a" in *[!0-9a-f:]* | *:::*) return 1 ;; esac
      h1=${a%%:*}
      h2=${a#*:}
      h2=${h2%%:*}
      [ -n "$h2" ] || h2=0
      for o in "$h1" "$h2"; do
        case "$o" in '' | ?????*) return 1 ;; esac
      done
      h1=$((16#$h1)) h2=$((16#$h2))
      [ "$h1" -ge 8192 ] && [ "$h1" -le 16383 ] || return 1
      [ "$h1" -ne 8194 ] || return 1
      { [ "$h1" -ne 8193 ] || { [ "$h2" -ne 0 ] && [ "$h2" -ne 3512 ]; }; } || return 1
      ;;
    *.*.*.*)
      IFS=. read -r o1 o2 o3 o4 <<<"$a"
      for o in "$o1" "$o2" "$o3" "$o4"; do
        case "$o" in '' | *[!0-9]*) return 1 ;; esac
        [ "${#o}" -le 3 ] && [ "$((10#$o))" -le 255 ] || return 1
      done
      o1=$((10#$o1)) o2=$((10#$o2)) o3=$((10#$o3))
      case "$o1" in 0 | 10 | 127) return 1 ;; esac
      [ "$o1" -lt 224 ] || return 1
      case "$o1.$o2" in 169.254 | 192.168 | 198.18 | 198.19) return 1 ;; esac
      case "$o1.$o2.$o3" in 192.0.0 | 192.0.2 | 198.51.100 | 203.0.113) return 1 ;; esac
      { [ "$o1" -ne 172 ] || [ "$o2" -lt 16 ] || [ "$o2" -gt 31 ]; } || return 1
      { [ "$o1" -ne 100 ] || [ "$o2" -lt 64 ] || [ "$o2" -gt 127 ]; } || return 1
      ;;
    *) return 1 ;;
  esac
}

# Run one bounded read-only re-check. Prints up, down or skip (no re-check this
# dependency kind has, or the pass cap was reached) or refuse (the https host
# resolves to a non-public address or not at all) plus a detail after a tab.
probe() {  # <dep>
  local dep=$1 kind rest host path url state f addrs addr pin
  kind=${dep%%/*}
  rest=${dep#*/}
  case "$kind" in
    ssh)
      part_ok "$rest" && [ "$rest" = "${rest%%/*}" ] || { printf 'skip\tmalformed'; return 0; }
      fm_run_timed "$CHECK_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes \
        -o StrictHostKeyChecking=yes -- "$rest" true \
        </dev/null >/dev/null 2>&1 && printf 'up\treachable over ssh' || printf 'down\tssh failed'
      ;;
    https)
      host=${rest%%/*}
      part_ok "$host" || { printf 'skip\tmalformed'; return 0; }
      dns_name_ok "$host" || { printf 'skip\tnot a public DNS name'; return 0; }
      path=
      [ "$rest" = "$host" ] || path=${rest#*/}
      url="https://$host/$path"
      addrs=$(resolve_host "$host") && [ -n "$addrs" ] || { printf 'refuse\tdoes not resolve'; return 0; }
      pin=
      while IFS= read -r addr; do
        addr_public_ok "$addr" || { printf 'refuse\tresolves to a non-public address'; return 0; }
        case "$addr" in *:*) addr="[$addr]" ;; esac
        pin="$pin${pin:+,}$addr"
      done <<<"$addrs"
      fm_run_timed "$REQUEST_TIMEOUT" curl -q -fsS --noproxy '*' --max-time "$REQUEST_TIMEOUT" --max-redirs 0 \
        --resolve "$host:443:$pin" -o /dev/null -- "$url" \
        </dev/null >/dev/null 2>&1 && printf 'up\tanswers' || printf 'down\tno answer'
      ;;
    pr)
      url=$(status_dep_pr_url "$dep") || { printf 'skip\tmalformed'; return 0; }
      if state=$(fm_run_timed "$CHECK_TIMEOUT" gh pr view "$url" --json state --jq .state </dev/null 2>/dev/null) \
        && case "$state" in MERGED | CLOSED | OPEN) true ;; *) false ;; esac; then
        if [ "$state" = OPEN ]; then printf 'down\topen'; else printf 'up\t%s' "$state"; fi
      else
        printf 'down\tunreadable'
      fi
      ;;
    task)
      part_ok "$rest" && [ "$rest" = "${rest%%/*}" ] || { printf 'skip\tmalformed'; return 0; }
      f="$STATE/$rest.status"
      [ -f "$f" ] || { printf 'down\tno such task'; return 0; }
      if [ "$(status_line_verb "$(last_status_line "$f")")" = "done" ]; then
        printf 'up\tdone'
      else
        printf 'down\tnot done'
      fi
      ;;
    *) printf 'skip\tno re-check for this kind' ;;
  esac
}

# Probe <dep> once per run into RESULT ("up|down|skip|capped<TAB>detail"). Not
# a command substitution, so the cache and the per-pass counter persist.
RESULT=''
result_for() {  # <dep>
  local dep=$1 hit
  hit=$(printf '%s' "$CACHE" | awk -F'\t' -v d="$dep" '$1 == d { sub(/^[^\t]*\t/, ""); print; exit }')
  if [ -z "$hit" ]; then
    if [ "$checks" -ge "$MAX_CHECKS" ]; then
      hit="capped	pass cap reached"
    else
      case "${dep%%/*}" in ssh | https | pr | task) checks=$((checks + 1)) ;; esac
      hit=$(probe "$dep")
    fi
    CACHE="$CACHE$dep	$hit"$'\n'
  fi
  RESULT=$hit
}

line_id() {  # <status-line> -> short stable id
  printf '%s' "$1" | cksum | awk '{ print $1 "-" $2 }'
}

seen_has() {  # <task> <line-id> <event>
  [ -f "$SEEN" ] && grep -qxF -- "$1	$2	$3" "$SEEN"
}

# The external wait a status file currently holds, or nothing: the latest event
# when it is a blocked or needs-decision line, else the declared pause.
current_external_wait() {  # <status-file>
  local last verb wait
  last=$(last_status_line "$1")
  status_line_verb "$last" verb
  case "$verb" in
    blocked | needs-decision) wait=$last ;;
    *) wait=$(status_declared_wait_line "$1") && status_is_paused "$wait" || wait='' ;;
  esac
  [ -n "$wait" ] && [ "$(status_line_cause "$wait")" = external ] || return 0
  printf '%s\n' "$wait"
}

waits=0 cleared=0 overdue=0 waiting=0 unchecked=0 repeats=0
LIVE_WAITS=''
NEW_SEEN=''

for f in "$STATE"/*.status; do
  [ -f "$f" ] || continue
  base=${f##*/}
  task=${base%.status}
  wait=$(current_external_wait "$f")
  [ -n "$wait" ] || continue
  waits=$((waits + 1))
  id=$(line_id "$wait")
  status_line_verb "$wait" verb
  dep=none
  dep=$(status_line_dep "$wait") || dep=none
  until_epoch=''
  until_epoch=$(_fm_status_until_epoch "$wait") || until_epoch=''
  verdict=waiting detail=''
  if [ "$dep" != none ]; then
    # A pull request wait on a decision or blocker belongs to fm-decision-sweep.sh.
    if [ "${dep%%/*}" = pr ] && [ "$verb" != "$PAUSED_VERB" ]; then
      detail='pull request wait on a decision, closed by fm-decision-sweep.sh'
    else
      result_for "$dep"
      detail=${RESULT#*	}
      case "${RESULT%%	*}" in
        up) verdict=cleared ;;
        capped | refuse) verdict=unchecked ;;
      esac
    fi
  fi
  if [ "$verdict" != cleared ] && [ -n "$until_epoch" ] && [ "$NOW" -gt "$until_epoch" ]; then
    verdict=overdue
  fi
  LIVE_WAITS="$LIVE_WAITS$task	$id"$'\n'
  new=0
  case "$verdict" in
    cleared | overdue)
      if ! seen_has "$task" "$id" "$verdict"; then
        new=1
        NEW_SEEN="$NEW_SEEN$task	$id	$verdict"$'\n'
      fi
      ;;
  esac
  case "$verdict" in
    cleared) cleared=$((cleared + 1)) ;;
    overdue) overdue=$((overdue + 1)) ;;
    unchecked) unchecked=$((unchecked + 1)) ;;
    *) waiting=$((waiting + 1)) ;;
  esac
  out="home=$FM_HOME file=$base dep=$dep verdict=$verdict new=$new"
  [ -z "$until_epoch" ] || out="$out until=$until_epoch"
  [ -z "$detail" ] || out="$out detail=$detail"
  echo "$out"
done

# Repeat count over every log: one declaration per distinct line per log.
REPEAT_OUT=$(
  for f in "$STATE"/*.status; do
    [ -f "$f" ] || continue
    grep -aF -- 'cause=external' "$f" 2>/dev/null | sort -u | while IFS= read -r line; do
      rverb=
      status_line_verb "$line" rverb
      [ "$rverb" = "$PAUSED_VERB" ] || [ "$rverb" = blocked ] || [ "$rverb" = needs-decision ] || continue
      [ "$(status_line_cause "$line")" = external ] || continue
      d=$(status_line_dep "$line") || continue
      [ "${d%%/*}" != task ] || continue
      [ "${d%%/*}" != pr ] || continue
      printf '%s\t%s\n' "$d" "${f##*/}"
    done
  done | awk -F'\t' '
    { n[$1]++; sub(/\.status$/, "", $2); t[$1] = t[$1] (index("," t[$1] ",", "," $2 ",") ? "" : (t[$1] == "" ? "" : ",") $2) }
    END { for (d in n) printf "%s\t%d\t%s\n", d, n[d], t[d] }' | sort
)
NEW_REPEAT=''
while IFS=$'\t' read -r d n tasks; do
  [ -n "$d" ] || continue
  [ "$n" -ge "$REPEAT_MIN" ] || continue
  repeats=$((repeats + 1))
  prev=0
  [ ! -f "$REPEATED" ] || prev=$(awk -F'\t' -v d="$d" '$1 == d { print $2; exit }' "$REPEATED")
  prev=$(num_or "$prev" 0)
  new=0
  if [ "$n" -gt "$prev" ]; then new=1; NEW_REPEAT="$NEW_REPEAT$d	$n"$'\n'; else NEW_REPEAT="$NEW_REPEAT$d	$prev"$'\n'; fi
  echo "repeat dep=$d count=$n tasks=$tasks new=$new"
done <<EOF
$REPEAT_OUT
EOF

mode=dry-run
if [ "$APPLY" -eq 1 ]; then
  mode=apply
  # Keep only markers for waits that still stand, so the file stays bounded.
  {
    [ ! -f "$SEEN" ] || printf '%s' "$LIVE_WAITS" | awk -F'\t' 'NR == FNR { live[$1 FS $2] = 1; next } ($1 FS $2) in live' - "$SEEN"
    printf '%s' "$NEW_SEEN"
  } > "$SEEN.tmp" && mv -f "$SEEN.tmp" "$SEEN"
  printf '%s' "$NEW_REPEAT" > "$REPEATED.tmp" && mv -f "$REPEATED.tmp" "$REPEATED"
fi
echo "totals mode=$mode waits=$waits cleared=$cleared overdue=$overdue waiting=$waiting unchecked=$unchecked repeats=$repeats checks-run=$checks"
