#!/usr/bin/env bash
# fm-registry-line-lib.sh - the shared grammar of the registry line family.
#
# data/officers.md and data/offices.md hold lines of the form
#   - <id> - <sentence> (<key>: <value>; ...; added YYYY-MM-DD)
# This library owns that line's regex, the field reader, and the cadence and
# slot helpers ("daily HH:MM" or "every Nh") that registered agents run on.
# shellcheck disable=SC2034 # the variables are read by the scripts that source this library
# Source it; it defines functions and variables only and changes no shell options.

# epoch_fmt <epoch> <format>: local-time strftime on GNU and BSD date.
epoch_fmt() {
  date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2"
}

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

# Registry lines: "- <id> - <role sentence> (<key>: <value>; ...; added YYYY-MM-DD)".
REGISTRY_LINE_RE='^- ([a-z0-9-]+) - (.+) \((.*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'

registry_lines() {
  [ -f "$REGISTRY" ] || return 0
  grep -E '^- ' "$REGISTRY" || true
}

# line_field <line> <key>: the value of one "key: value" field.
line_field() {
  local fields part key
  [[ "$1" =~ $REGISTRY_LINE_RE ]] || return 1
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
