#!/usr/bin/env bash
# fm-office.sh - the office registry: list offices and report gaps. Read-only.
#
# An office is a second mate that runs a standing role mandate (navigator or
# quartermaster) instead of idling. docs/configuration.md "Offices
# (data/offices.md)" owns the registry schema; this header owns the mechanics.
#
# Usage:
#   fm-office.sh list
#   fm-office.sh ensure
#
# list prints one line per registry entry: "<id> <role> <state>", where state
# is "ok" or "gaps:<n>".
#
# ensure (run by bin/fm-bootstrap.sh) prints one "OFFICE: office <id>: <gap>"
# line per mismatch between data/offices.md and the fleet, and nothing when
# they agree. An absent data/offices.md means no offices. A gap is a malformed
# line, an unknown role, a bad value for a key, a runs-on host that is not
# allowed or not the registered second mate's host, an id that is not a
# registered second mate, a missing .fm-office marker or "# Office authority"
# charter heading in a local office home, a dispatch project missing from the
# office home's data/projects.md, a merge project without admission=, a source
# lane that is not a registered officer, or a merge-via project that does not
# carry merger=<home> in the office home's data/projects.md. A remote
# office's home is not readable from here, so its file checks are skipped.
# The authority record, wake-source checks and status file belong to later
# changes and are not checked here.
#
# Environment: FM_HOME, FM_DATA_OVERRIDE as the other bin/ scripts do.
# FM_OFFICE_HOST names this host for tests (default: hostname -s).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REGISTRY="$DATA/offices.md"
OFFICE_ROLES="navigator quartermaster"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-registry-line-lib.sh
. "$SCRIPT_DIR/fm-registry-line-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-office.sh list      list registered offices and their state
  fm-office.sh ensure    session-start health: one OFFICE: line per gap
See docs/configuration.md "Offices (data/offices.md)" for the registry schema.
EOF
}

in_list() {  # <item> <comma list>
  case ",$2," in *",$1,"*) return 0 ;; esac
  return 1
}

# project_token <projects.md> <project> <key>: the value of a key=value token, or nothing.
project_token() {
  local line tok
  [ -f "$1" ] || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^-\ ([^\ ]+)\ \[([^]]*)\] ]] || continue
    [ "${BASH_REMATCH[1]}" = "$2" ] || continue
    for tok in ${BASH_REMATCH[2]}; do
      case "$tok" in "$3="*) printf '%s\n' "${tok#*=}"; return 0 ;; esac
    done
    return 0
  done < "$1"
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
  case " $OFFICE_ROLES " in
    *" $role "*) ;;
    *) printf 'unknown role "%s" (known: %s)\n' "$role" "$OFFICE_ROLES" ;;
  esac
  v=$(line_field "$line" wip || true)
  [[ "$v" =~ ^[1-9]$ ]] || printf 'wip must be a number from 1 to 9, got "%s"\n' "$v"
  v=$(line_field "$line" tick || true)
  [[ "$v" =~ ^every\ ([1-9]|1[0-9]|2[0-4])h$ ]] || printf 'tick must be "every Nh" (N from 1 to 24), got "%s"\n' "$v"
  v=$(line_field "$line" auto-merge-classes || true)
  [ "$v" = none ] || printf 'auto-merge-classes must be none, got "%s"\n' "$v"
  v=$(line_field "$line" sources || true)
  if [ -z "$v" ]; then
    printf 'sources must list tick or lane:<officer-id>[:high]\n'
  else
    for p in ${v//,/ }; do
      case "$p" in
        tick) ;;
        lane:*)
          p=${p#lane:}; p=${p%:high}
          grep -Eq "^- $p - " "$DATA/officers.md" 2>/dev/null \
            || printf 'source lane:%s is not a registered officer\n' "$p"
          ;;
        *) printf 'source "%s" must be tick, lane:<officer-id> or lane:<officer-id>:high\n' "$p" ;;
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
  [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] && return
  home=${SECONDMATE_REGISTRY_HOME/#\~/$HOME}
  [ -d "$home" ] || { printf 'office home %s is missing\n' "$home"; return; }
  [ "$(cat "$home/.fm-office" 2>/dev/null)" = "$id" ] || printf '.fm-office marker missing or not "%s" in %s\n' "$id" "$home"
  grep -q '^# Office authority' "$home/data/charter.md" 2>/dev/null \
    || printf 'charter lacks the "# Office authority" heading (%s/data/charter.md)\n' "$home"
  projects_md="$home/data/projects.md"
  for p in ${dispatch//,/ }; do
    project_listed "$projects_md" "$p" || printf 'dispatch project %s is not in %s\n' "$p" "$projects_md"
  done
  if [ -n "$merge" ] && [ "$merge" != none ]; then
    for p in ${merge//,/ }; do
      [ -n "$(project_token "$projects_md" "$p" admission)" ] || printf 'merge project %s has no admission= in %s\n' "$p" "$projects_md"
    done
  fi
  if [ -n "$via" ] && [ "$via" != none ]; then
    for pair in ${via//,/ }; do
      p=${pair%%=*}
      [ "$(project_token "$projects_md" "$p" merger)" = "${pair#*=}" ] \
        || printf 'merge-via project %s lacks merger=%s in %s\n' "$p" "${pair#*=}" "$projects_md"
    done
  fi
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

case "${1:-}" in
  list) cmd_list ;;
  ensure) cmd_ensure ;;
  -h|--help|help|'') usage ;;
  *) usage >&2; exit 2 ;;
esac
