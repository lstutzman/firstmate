#!/usr/bin/env bash
# fm-host-observe.sh - a read-only live view of what this home's supervision
# host does (docs/supervision-host.md "The observer pane").
#
# Usage:
#   fm-host-observe.sh follow [--once]
#   fm-host-observe.sh ensure
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
#
# ensure keeps exactly one herdr pane running `follow` for this home, and is
# the only writer of the observer's own state. The host runs it in the
# background at every start (bin/fm-supervision-host.sh). It does nothing
# unless the local config/supervision-host-observer exists. On the herdr
# backend (bin/fm-backend.sh fm_backend_name) it opens the pane in its own
# workspace labeled <home workspace label>-host-observer
# (firstmate-host-observer on a primary) in the selected herdr session, records
# the session, workspace, and pane in state/.supervision-host-observer, and on
# later calls reuses that pane while herdr reports it present and not visibly
# idle. It opens a new one when herdr reports the pane gone, or present with
# the follower no longer in its foreground (a pane herdr restored as a bare
# shell), and closes and forgets a pane whose follower could not be started,
# so the next ensure reopens. It never starts a herdr server. Any other
# backend, or a herdr that is missing, outdated, not running, or not
# answering, gets one "observer: ..." diagnostic line on stdout, printed again
# only when the problem changes, and nothing else. One ensure runs at a time
# (state/.supervision-host-observer.lock). It always exits 0.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

HOST_LOG="$STATE/.supervision-host.log"
OUTCOME_TAIL="$STATE/.branch-outcomes-tail.jsonl"
ENGINE_RECORD="$STATE/.supervision-host-engine"
TURN_FILE="$STATE/.supervision-host-turn"
OBSERVER_RECORD="$STATE/.supervision-host-observer"
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

# The engine transcript: complete lines past the byte offset already rendered
# in that conversation, restarting at the top of a shrunken file. A running
# turn's record names its conversation before the engine record does, which a
# new conversation's turn updates only once it succeeds, so the follower can
# move back to an earlier conversation; each keeps its own offset, and a
# conversation newly followed starts with its newest BACKLOG events.
TR_SESSION=
TR_OFFSETS=
pass_transcript() {  # <first-pass>
  local session file size data offset cap=$1
  session=$(turn_field session)
  [ -n "$session" ] || session=$(sed -n 's/^session=//p' "$ENGINE_RECORD" 2>/dev/null | head -n 1)
  [ -n "$session" ] || return 0
  if [ "$session" != "$TR_SESSION" ]; then
    TR_SESSION=$session
    cap=1
  fi
  offset=$(printf '%s\n' "$TR_OFFSETS" | awk -v s="$session" '$1 == s { o = $2 } END { print o + 0 }')
  file=
  for file in "$CLAUDE_STORE"/projects/*/"$session".jsonl; do
    [ -f "$file" ] && break
    file=
  done
  [ -n "$file" ] || return 0
  size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -ge "$offset" ] || offset=0
  [ "$size" -gt "$offset" ] || return 0
  data=$(tail -c +"$((offset + 1))" "$file" 2>/dev/null | head -c "$((size - offset))"; printf .)
  data=${data%.}
  case "$data" in *$'\n'*) ;; *) return 0 ;; esac
  data=${data%"${data##*$'\n'}"}
  offset=$((offset + ${#data}))
  TR_OFFSETS=$(printf '%s\n' "$TR_OFFSETS" | awk -v s="$session" 'NF && $1 != s'; printf '%s %s\n' "$session" "$offset")
  printf '%s' "$data" | render_transcript | backlog "$cap"
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

record_field() {  # <key>
  sed -n "s/^$1=//p" "$OBSERVER_RECORD" 2>/dev/null | head -n 1
}

write_record() {  # <session> <workspace> <pane> <note>
  local tmp
  tmp=$(mktemp "$OBSERVER_RECORD.tmp.XXXXXX" 2>/dev/null) || return 0
  printf 'session=%s\nworkspace=%s\npane=%s\nnote=%s\n' "$1" "$2" "$3" "$4" > "$tmp" \
    && mv -f "$tmp" "$OBSERVER_RECORD"
  rm -f "$tmp" 2>/dev/null || true
}

# One diagnostic per distinct problem: repeated parks with the same problem
# stay quiet until it changes or clears.
diagnose() {  # <text>
  [ "$(record_field note)" = "$1" ] || printf 'observer: %s; the host continues headless\n' "$1"
  write_record "$(record_field session)" "$(record_field workspace)" "$(record_field pane)" "$1"
}

# Parks can follow each other faster than herdr answers, so one ensure runs at
# a time; another finds the lock held and leaves the pane to it. A lock whose
# holder died is taken over.
ensure_lock() {
  local lock="$OBSERVER_RECORD.lock" holder
  if ! mkdir "$lock" 2>/dev/null; then
    holder=$(cat "$lock/pid" 2>/dev/null)
    case "$holder" in
      ''|*[!0-9]*)
        # A holder that has not written its pid yet, unless it never will.
        [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 1
        ;;
      *) ! kill -0 "$holder" 2>/dev/null || return 1 ;;
    esac
    rm -rf "$lock" 2>/dev/null
    mkdir "$lock" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" > "$lock/pid"
  trap 'rm -rf "$OBSERVER_RECORD.lock" 2>/dev/null' EXIT
}

# observer_in_pane <session> <pane>: whether herdr's process-info shows the
# follower in the pane's foreground, as running|idle|unknown.
observer_in_pane() {
  fm_backend_herdr_cli "$1" pane process-info --pane "$2" 2>/dev/null | jq -r --arg pane "$2" '
    .result.process_info
    | if .pane_id != $pane or (.foreground_processes | type) != "array" then "unknown"
      elif any(.foreground_processes[]; (.cmdline // ((.argv // []) | join(" ")))
        | test("fm-host-observe\\.sh follow")) then "running"
      else "idle" end' 2>/dev/null || printf 'unknown'
}

ensure() {
  local backend session pane presence out workspace label cmd prior
  [ -e "$CONFIG/supervision-host-observer" ] || return 0
  [ -d "$STATE" ] || return 0
  ensure_lock || return 0
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" || { diagnose "the backend library could not be loaded"; return 0; }
  backend=$(fm_backend_name 2>/dev/null)
  if [ "$backend" != herdr ]; then
    diagnose "the observer pane needs the herdr backend, and this home runs ${backend:-no known backend}"
    return 0
  fi
  if ! fm_backend_source herdr 2>/dev/null; then
    diagnose "the herdr backend could not be loaded"
    return 0
  fi
  if ! out=$(fm_backend_herdr_version_check 2>&1); then
    diagnose "herdr is unavailable (${out:-no usable herdr client})"
    return 0
  fi
  session=$(fm_backend_herdr_session)
  if [ "$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)" != true ]; then
    diagnose "herdr session '$session' has no running server"
    return 0
  fi
  pane=$(record_field pane)
  if [ -n "$pane" ] && [ "$(record_field session)" = "$session" ]; then
    presence=$(fm_backend_herdr_pane_presence_state "$session" "$pane")
    case "$presence" in
      present)
        # herdr restores a pane across a server restart as a bare shell, so a
        # present pane counts only while the observer still runs in it.
        if [ "$(observer_in_pane "$session" "$pane")" != idle ]; then
          write_record "$session" "$(record_field workspace)" "$pane" ""
          return 0
        fi
        fm_backend_herdr_cli "$session" pane close "$pane" >/dev/null 2>&1
        ;;
      dead) ;;
      *) diagnose "herdr could not say whether observer pane $pane still exists"; return 0 ;;
    esac
  fi
  label="$(fm_backend_herdr_workspace_label)-host-observer"
  if ! out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$FM_HOME" --label "$label" --no-focus 2>/dev/null); then
    diagnose "herdr could not open the '$label' workspace in session '$session'"
    return 0
  fi
  workspace=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$workspace" ] || [ -z "$pane" ]; then
    diagnose "herdr opened the '$label' workspace without naming its pane"
    return 0
  fi
  # Recorded before the observer starts, so a later ensure never opens a
  # second pane beside this one.
  prior=$(record_field note)
  write_record "$session" "$workspace" "$pane" ""
  cmd="FM_HOME=$(printf '%q' "$FM_HOME")"
  [ -z "${CLAUDE_CONFIG_DIR:-}" ] || cmd="$cmd CLAUDE_CONFIG_DIR=$(printf '%q' "$CLAUDE_CONFIG_DIR")"
  cmd="$cmd $(printf '%q' "$SCRIPT_DIR/fm-host-observe.sh") follow"
  if ! fm_backend_herdr_cli "$session" pane run "$pane" "$cmd" >/dev/null 2>&1; then
    fm_backend_herdr_cli "$session" pane close "$pane" >/dev/null 2>&1
    write_record "" "" "" "$prior"
    diagnose "herdr opened an observer pane but could not start the observer in it"
    return 0
  fi
  printf "observer: opened observer pane %s in herdr workspace '%s' (session %s)\n" "$pane" "$label" "$session"
}

case "${1:-}" in
  follow)
    shift
    follow "$@"
    ;;
  ensure) ensure ;;
  *) printf 'usage: fm-host-observe.sh follow [--once] | ensure\n' >&2; exit 2 ;;
esac
