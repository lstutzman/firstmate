#!/usr/bin/env bash
# fm-host-observe.sh - a read-only live view of what this home's supervision
# host does (docs/supervision-host.md "The observer pane").
#
# Usage:
#   fm-host-observe.sh follow [--once]
#
# follow renders the host's own durable files as readable lines on stdout, one
# per event, each led by its local HH:MM:SS time and its source:
#   [host]     state/.supervision-host.log, the host ledger: every close's
#              route, each engine turn's result and usage, latch and recovery.
#   [wake]     state/.supervision-host-turn, the running turn's record: its
#              posture, turn id, task scope, and wake reason, once per turn.
#   [engine]   the engine conversation's transcript in Claude's own project
#              store (${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*/<session>.jsonl),
#              found from the session the running turn's record names, else
#              the one state/.supervision-host-engine records:
#              assistant text, each tool call, and the first line of each
#              tool result, condensed to one line.
#   [outcome]  state/.branch-outcomes-tail.jsonl, the outcome store's display
#              tail: each verdict (CAPTAIN or routine, silent marked) and summary.
# It starts with the newest FM_HOST_OBSERVE_BACKLOG (20) events of each source,
# then polls every FM_HOST_OBSERVE_POLL (1) seconds and renders each new event
# once. A file that does not exist yet, a ledger the host rotated or truncated,
# a tail copy replaced whole, and a host that restarted are all followed
# without a restart. --once renders the backlog and exits.
#
# READ-ONLY: it only reads those files. It takes no lock, acknowledges no wake,
# moves no outcome cursor, and writes nothing under state/, so it can never
# change what the host or main does.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

HOST_LOG="$STATE/.supervision-host.log"
OUTCOME_TAIL="$STATE/.branch-outcomes-tail.jsonl"
ENGINE_RECORD="$STATE/.supervision-host-engine"
TURN_FILE="$STATE/.supervision-host-turn"
CLAUDE_STORE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

POLL=${FM_HOST_OBSERVE_POLL:-1}
case "$POLL" in ''|*[!0-9.]*) POLL=1 ;; esac
BACKLOG=${FM_HOST_OBSERVE_BACKLOG:-20}
case "$BACKLOG" in ''|*[!0-9]*) BACKLOG=20 ;; esac

render_ledger() {  # stdin: ledger lines
  jq -Rr 'split("\t") as $f
    | try "\($f[0] | tonumber | strflocaltime("%H:%M:%S")) [host] \($f[1]): \($f[2:] | join(" | "))"
      catch empty' 2>/dev/null
}

render_outcomes() {  # <after-seq>; stdin: outcome rows
  jq -Rr --argjson after "$1" 'try fromjson catch empty
    | select((.seq | type) == "number" and .seq > $after)
    | "\(.epoch | strflocaltime("%H:%M:%S")) [outcome] \(if .verdict == "captain" then "CAPTAIN" else .verdict end)\(if .silent == true then " (silent)" else "" end) \(.task): \(.summary)"' \
    2>/dev/null
}

render_transcript() {  # stdin: transcript lines
  jq -Rr '
    def one: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
    def cut($n): if length > $n then .[0:$n] + "..." else . end;
    try fromjson catch empty
    | select((.type == "assistant" or .type == "user") and (.message.content | type) == "array")
    | (try (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | strflocaltime("%H:%M:%S")) catch "--:--:--") as $t
    | .message.content[]
    | if .type == "text" then "\($t) [engine] \(.text | one | cut(400))"
      elif .type == "tool_use" then
        "\($t) [engine] > \(.name): \(if .name == "Bash" then .input.command
          elif .name == "Read" then .input.file_path else (.input | tojson) end | tostring | one | cut(300))"
      elif .type == "tool_result" then
        "\($t) [engine] < \(if .is_error == true then "error: " else "" end)\(.content
          | if type == "array" then map(.text? // "") | join("\n") else tostring end
          | split("\n")[0] | one | cut(200))"
      else empty end' 2>/dev/null
}

# Keep only the newest BACKLOG lines on the first pass.
backlog() {  # <first-pass 0|1>
  if [ "$1" -eq 1 ]; then tail -n "$BACKLOG"; else cat; fi
}

# The ledger: lines after the last one rendered. When that line is gone, the
# ledger was truncated or reset, so every line is new.
LEDGER_LAST=
pass_ledger() {  # <first-pass>
  local lines
  [ -f "$HOST_LOG" ] || return 0
  lines=$(LAST=$LEDGER_LAST awk '
    BEGIN { last = ENVIRON["LAST"] }
    { line[NR] = $0; if (last != "" && $0 == last) from = NR }
    END { for (i = from + 1; i <= NR; i++) print line[i] }' "$HOST_LOG" 2>/dev/null)
  [ -n "$lines" ] || return 0
  LEDGER_LAST=${lines##*$'\n'}
  printf '%s\n' "$lines" | backlog "$1" | render_ledger
}

turn_field() {  # <key>
  sed -n "s/^$1=//p" "$TURN_FILE" 2>/dev/null | head -n 1
}

# The running turn: one [wake] line per turn the host starts, timed by its
# turn record.
TURN_LAST=
pass_turn() {
  local turn epoch
  turn=$(turn_field turn)
  [ -n "$turn" ] && [ "$turn" != "$TURN_LAST" ] || return 0
  TURN_LAST=$turn
  epoch=$(stat -c %Y "$TURN_FILE" 2>/dev/null || stat -f %m "$TURN_FILE" 2>/dev/null)
  case "$epoch" in ''|*[!0-9]*) epoch=$(date +%s) ;; esac
  printf '%s [wake] %s turn=%s tasks=%s: %s\n' \
    "$(jq -nr --argjson e "$epoch" '$e | strflocaltime("%H:%M:%S")')" \
    "$(turn_field posture)" "$turn" "$(turn_field tasks)" "$(turn_field wake)"
}

# The engine transcript: complete lines past the byte offset already rendered,
# restarting at the top for a new conversation or a shrunken file. A running
# turn's record names its conversation before the engine record does, which a
# new conversation's turn updates only once it succeeds.
TR_SESSION=
TR_OFFSET=0
pass_transcript() {  # <first-pass>
  local session file size data
  session=$(turn_field session)
  [ -n "$session" ] || session=$(sed -n 's/^session=//p' "$ENGINE_RECORD" 2>/dev/null | head -n 1)
  [ -n "$session" ] || return 0
  if [ "$session" != "$TR_SESSION" ]; then
    TR_SESSION=$session
    TR_OFFSET=0
  fi
  file=
  for file in "$CLAUDE_STORE"/projects/*/"$session".jsonl; do
    [ -f "$file" ] && break
    file=
  done
  [ -n "$file" ] || return 0
  size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -ge "$TR_OFFSET" ] || TR_OFFSET=0
  [ "$size" -gt "$TR_OFFSET" ] || return 0
  data=$(tail -c +"$((TR_OFFSET + 1))" "$file" 2>/dev/null | head -c "$((size - TR_OFFSET))"; printf .)
  data=${data%.}
  case "$data" in *$'\n'*) ;; *) return 0 ;; esac
  data=${data%"${data##*$'\n'}"}
  TR_OFFSET=$((TR_OFFSET + ${#data}))
  printf '%s' "$data" | render_transcript | backlog "$1"
}

# The outcome tail: rows above the highest sequence rendered. A tail whose
# newest row is below it belongs to a reset store, so it starts over.
OUT_SEQ=0
pass_outcomes() {  # <first-pass>
  local newest
  [ -f "$OUTCOME_TAIL" ] || return 0
  newest=$(jq -Rr 'try (fromjson | .seq | numbers) catch empty' "$OUTCOME_TAIL" 2>/dev/null | sort -n | tail -n 1)
  case "$newest" in ''|*[!0-9]*) return 0 ;; esac
  [ "$newest" -ge "$OUT_SEQ" ] || OUT_SEQ=0
  [ "$newest" -gt "$OUT_SEQ" ] || return 0
  render_outcomes "$OUT_SEQ" < "$OUTCOME_TAIL" | backlog "$1"
  OUT_SEQ=$newest
}

observe_pass() {  # <first-pass>
  pass_ledger "$1"
  pass_turn
  pass_transcript "$1"
  pass_outcomes "$1"
}

follow() {  # [--once]
  if [ "${1:-}" = --once ]; then
    observe_pass 1
    return 0
  fi
  printf 'observing the supervision host of %s (read-only; Ctrl-C stops only this view)\n' "$FM_HOME"
  observe_pass 1
  while :; do
    sleep "$POLL"
    observe_pass 0
  done
}

case "${1:-}" in
  follow)
    shift
    follow "$@"
    ;;
  *) printf 'usage: fm-host-observe.sh follow [--once]\n' >&2; exit 2 ;;
esac
