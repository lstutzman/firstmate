#!/usr/bin/env bash
# fm-office-feed-lib.sh - the copy of the parent's office data that a remote office reads.
#
# Sourced, never executed. An office's source checks (bin/fm-office.sh check)
# read its own line in the parent's data/offices.md and each lane officer's
# digest in the parent's data/officers/. A home on another host cannot read
# those files, so the parent carries a copy to it as one more inherited config
# item, config/office-feed, through the ordinary remote inherit push
# (bin/fm-remote-inherit-push.sh); this library builds it and reads it back.
# A local office never receives one (it reads the parent directly).
#
# Grammar, one record per line:
#   fm-office-feed-v1
#   generated=<epoch seconds the parent built it>
#   id=<office id>
#   line=<base64 of the office's line in data/offices.md>
#   lane=<officer> <base64 digest file> <base64 digest .md> <base64 digest .json>
# The digest file is the officer's "DIGEST <key> <n> <path>" pointer. The .json
# holds only what the checks read: the start_requests whose execute.env.FM_HOME
# is the office's own registered home, and everything else untouched. A lane
# whose files cannot be read or are over FM_OFFICE_FEED_LANE_MAX bytes is left
# out, and the whole copy is left out over FM_OFFICE_FEED_MAX bytes, so the
# remote check stays silent for it, as it is for a missing digest.
#
# Public functions:
#   fm_office_feed_payload <src-home> <src-data> <dest-id> <remote-home> <out-file> <now>
#       writes <dest-id>'s copy to <out-file>, or leaves it absent when the
#       registry names no such office line; returns 1 with FM_OFFICE_ERROR
#       when the line is malformed or the copy cannot be staged.
#   fm_office_feed_fingerprint <file>
#       prints a digest of the copy without its generated= line, so an
#       unchanged copy has an unchanged fingerprint.
#   fm_office_feed_load <file> <office-id> <now>
#       0 with FM_OFFICE_FEED_LINE set from a well-formed copy for that office
#       that is at most FM_OFFICE_FEED_MAX_AGE seconds old, otherwise 1.
#   fm_office_feed_lane <file> <officer> <out-dir>
#       0 after writing <out-dir>/<officer>.md and .json and setting
#       FM_OFFICE_FEED_DIGEST to the pointer file's content; 1 when the copy
#       carries no such lane.

# shellcheck disable=SC2034 # FM_OFFICE_* results are read by the caller
# shellcheck source=bin/fm-registry-line-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-registry-line-lib.sh"

FM_OFFICE_FEED_MAX=${FM_OFFICE_FEED_MAX:-900000}
FM_OFFICE_FEED_LANE_MAX=${FM_OFFICE_FEED_LANE_MAX:-200000}
# The 36 hours an office already allows a digest before it will deliver its start requests.
FM_OFFICE_FEED_MAX_AGE=${FM_OFFICE_FEED_MAX_AGE:-129600}

fm_office_feed_b64() { base64 | tr -d '\n'; }

fm_office_feed_b64_decode() {
  base64 --decode 2>/dev/null || base64 -D 2>/dev/null
}

fm_office_feed_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
}

# fm_office_feed_lane_record <src-home> <src-data> <officer> <remote-home>: prints the lane record, or nothing.
fm_office_feed_lane_record() {
  local home=$1 data=$2 officer=$3 remote=$4 pointer path md json
  pointer=$(cat "$data/officers/$officer/digest" 2>/dev/null) || return 0
  [[ "$pointer" =~ ^DIGEST\ ([0-9T-]{10,13})\ ([0-9]+)\ (.+)$ ]] || return 0
  path=${BASH_REMATCH[3]}
  case "$path" in /*) ;; *) path="$home/$path" ;; esac
  case "$path" in *..*) return 0 ;; *.md) ;; *) return 0 ;; esac
  [ -f "$path" ] && [ ! -L "$path" ] && [ -f "${path%.md}.json" ] && [ ! -L "${path%.md}.json" ] || return 0
  [ "$(LC_ALL=C wc -c < "$path" | tr -d ' ')" -le "$FM_OFFICE_FEED_LANE_MAX" ] || return 0
  [ "$(LC_ALL=C wc -c < "${path%.md}.json" | tr -d ' ')" -le "$FM_OFFICE_FEED_LANE_MAX" ] || return 0
  json=$(python3 -I -c '
import json, sys
home = sys.argv[2]
try:
    doc = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(1)
if isinstance(doc, dict) and isinstance(doc.get("start_requests"), list):
    doc["start_requests"] = [r for r in doc["start_requests"] if isinstance(r, dict)
        and isinstance(r.get("execute"), dict) and isinstance(r["execute"].get("env"), dict)
        and r["execute"]["env"].get("FM_HOME") == home]
sys.stdout.write(json.dumps(doc, sort_keys=True, separators=(",", ":")))
' "${path%.md}.json" "$remote" | fm_office_feed_b64) || return 0
  [ -n "$json" ] || return 0
  printf 'lane=%s %s %s %s\n' "$officer" "$(printf '%s\n' "$pointer" | fm_office_feed_b64)" \
    "$(fm_office_feed_b64 < "$path")" "$json"
}

fm_office_feed_payload() {  # <src-home> <src-data> <dest-id> <remote-home> <out-file> <now>
  local home=$1 data=$2 want=$3 remote=$4 out=$5 now=$6 REGISTRY="$2/offices.md" line match='' n=0 src officer seen=' ' tmp rec sources
  FM_OFFICE_ERROR=
  rm -f "$out" || { FM_OFFICE_ERROR="cannot clear the staged office feed $out"; return 1; }
  [ -n "$want" ] && [ -f "$REGISTRY" ] && [ -r "$REGISTRY" ] || return 0
  while IFS= read -r line; do
    case "$line" in "- $want "*) n=$((n + 1)); match=$line ;; esac
  done <<EOF
$(registry_lines)
EOF
  [ "$n" -gt 0 ] || return 0
  if [ "$n" -ne 1 ] || ! [[ "$match" =~ $REGISTRY_LINE_RE ]]; then
    FM_OFFICE_ERROR="its line in $REGISTRY is missing, repeated or malformed, so no office feed can be built"
    return 1
  fi
  sources=$(line_field "$match" sources || true)
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-office-feed.XXXXXX") || { FM_OFFICE_ERROR="cannot stage the office feed"; return 1; }
  {
    printf '%s\n' fm-office-feed-v1 "generated=$now" "id=$want" "line=$(printf '%s\n' "$match" | fm_office_feed_b64)"
    for src in ${sources//,/ }; do
      case "$src" in lane:*) ;; *) continue ;; esac
      officer=${src#lane:}; officer=${officer%:high}
      [[ "$officer" =~ ^[a-z0-9-]+$ ]] || continue
      case "$seen" in *" $officer "*) continue ;; esac
      seen="$seen$officer "
      rec=$(fm_office_feed_lane_record "$home" "$data" "$officer" "$remote") || rec=
      [ -z "$rec" ] || printf '%s\n' "$rec"
    done
  } > "$tmp" || { rm -f "$tmp"; FM_OFFICE_ERROR="cannot stage the office feed"; return 1; }
  if [ "$(LC_ALL=C wc -c < "$tmp" | tr -d ' ')" -gt "$FM_OFFICE_FEED_MAX" ]; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$out" || { rm -f "$tmp"; FM_OFFICE_ERROR="cannot stage the office feed"; return 1; }
}

fm_office_feed_fingerprint() {  # <file>
  grep -v '^generated=' "$1" 2>/dev/null | fm_office_feed_sha256
}

fm_office_feed_load() {  # <file> <office-id> <now>
  local file=$1 want=$2 now=$3 magic gen id enc
  FM_OFFICE_FEED_LINE=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  { IFS= read -r magic && IFS= read -r gen && IFS= read -r id && IFS= read -r enc; } < "$file" || return 1
  [ "$magic" = fm-office-feed-v1 ] && [ "$id" = "id=$want" ] || return 1
  gen=${gen#generated=}
  case "$gen" in ''|*[!0-9]*) return 1 ;; esac
  [ "$now" -ge "$gen" ] && [ $((now - gen)) -le "$FM_OFFICE_FEED_MAX_AGE" ] || return 1
  enc=${enc#line=}
  FM_OFFICE_FEED_LINE=$(printf '%s' "$enc" | fm_office_feed_b64_decode) || return 1
  [[ "$FM_OFFICE_FEED_LINE" =~ $REGISTRY_LINE_RE ]] && [ "${BASH_REMATCH[1]}" = "$want" ]
}

fm_office_feed_lane() {  # <file> <officer> <out-dir>
  local file=$1 officer=$2 dir=$3 rec _ digest md json
  rec=$(grep -m 1 "^lane=$officer " "$file" 2>/dev/null) || return 1
  read -r _ digest md json <<EOF
$rec
EOF
  [ -n "$digest" ] && [ -n "$md" ] && [ -n "$json" ] || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  FM_OFFICE_FEED_DIGEST=$(printf '%s' "$digest" | fm_office_feed_b64_decode) || return 1
  printf '%s' "$md" | fm_office_feed_b64_decode > "$dir/$officer.md.tmp" \
    && printf '%s' "$json" | fm_office_feed_b64_decode > "$dir/$officer.json.tmp" \
    && mv -f "$dir/$officer.md.tmp" "$dir/$officer.md" && mv -f "$dir/$officer.json.tmp" "$dir/$officer.json" || return 1
}
