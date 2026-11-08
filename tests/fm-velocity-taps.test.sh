#!/usr/bin/env bash
# Behavior tests for firstmate's handling of the fleet app's velocity-card taps (bin/fm-velocity-taps.py),
# driven through the friction officer's run (bin/fm-officer-friction.py) against fake Captain's Log replies, a fake
# velocity audit document, a fake linear-axi, a fake fleet-axi and fake inboxes.
#
# Covers: each of the five choices (Create item for later, Create and fix now, Let's discuss, Not for us, Object) and
# the older words Accept and Reject; the Linear item (Improvement, agent, area:fleet, Fleet project, the suggestion
# id as its key) and the answer "Filed as PC-n" after the acknowledgement; the start note reaching the owning office
# (and main for main, slarti, Lee or an unknown owner, or a reserved class); a repeat tap filing nothing twice; a
# rerun of the day changing nothing; a reply that already has an answer or an acknowledgement, a tap older than the
# app's reply window and Defer left alone; writes: none leaving the taps waiting; and a run with no velocity reply
# calling nothing.
set -u

# shellcheck source=tests/officer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/officer-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-velocity-taps)
DATE=2026-10-23
NOW=1792818000    # 2026-10-24T05:00:00Z
FRICTION="$ROOT/bin/fm-officer-friction.py"
export TZ=UTC

# fake_linear <bindir>: linear-axi over $FAKE_LINEAR_DIR; an issue is a file issue.<n> holding its body, searched by substring.
fake_linear() {
  cat > "$1/linear-axi" <<'SH'
#!/usr/bin/env bash
d=${FAKE_LINEAR_DIR:-}
[ -n "$d" ] || { echo '{"ok":false,"error":{"code":"UNKNOWN","message":"no fake linear dir"}}'; exit 1; }
printf '%s\n' "$*" >> "$d/log"
case "$1 $2" in
  "label list")
    printf '{"ok":true,"data":{"labels":['
    sep=''; while IFS= read -r l; do printf '%s{"name":"%s"}' "$sep" "$l"; sep=','; done < "$d/labels.txt"
    echo ']}}' ;;
  "issue search")
    out=''; sep=''
    for f in "$d"/issue.*; do
      [ -e "$f" ] || continue
      if grep -qF -- "$3" "$f"; then out="$out$sep{\"identifier\":\"PC-${f##*.}\"}"; sep=','; fi
    done
    echo '{"ok":true,"data":{"issues":['"$out"']}}' ;;
  "issue view")
    n=${3#PC-}
    desc=$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$d/issue.$n" 2>/dev/null || echo '""')
    echo '{"ok":true,"data":{"issue":{"identifier":"'"$3"'","state":"Todo","stateType":"unstarted","description":'"$desc"'}}}' ;;
  "issue create")
    case " $* " in
      *" --verify "*)
        n=$(( $(cat "$d/created" 2>/dev/null || echo 100) + 1 )); echo "$n" > "$d/created"
        prev=''
        for a in "$@"; do
          [ "$prev" = "--body-file" ] && cp "$a" "$d/issue.$n"
          [ "$prev" = "--label" ] && echo "$n $a" >> "$d/labels.used"
          [ "$prev" = "--project" ] && echo "$n $a" >> "$d/projects.used"
          [ "$prev" = "--title" ] && echo "$n $a" >> "$d/titles.used"
          prev=$a
        done
        echo '{"ok":true,"data":{"issue":{"identifier":"PC-'"$n"'"}}}' ;;
      *) echo '{"ok":true,"data":{"dryRun":true}}' ;;
    esac ;;
  *) echo '{"ok":false,"error":{"code":"UNKNOWN","message":"unexpected call"}}'; exit 1 ;;
esac
SH
  chmod +x "$1/linear-axi"
}

# fake_fleet_axi <bindir>: records every call; FAKE_FLEET_FAIL=ack or answer makes that step exit 1.
fake_fleet_axi() {
  cat > "$1/fleet-axi" <<'SH'
#!/usr/bin/env bash
d=${FAKE_WORLD:-}
[ -n "$d" ] || exit 9
printf '%s\n' "$*" >> "$d/fleet.log"
[ "${FAKE_FLEET_FAIL:-}" = "$4" ] && { echo "fake failure" >&2; exit 1; }
exit 0
SH
  chmod +x "$1/fleet-axi"
}

# fake_curl <bindir>: serves $FAKE_WORLD/replies.json, audit.json and cards.json; logs every URL.
fake_curl() {
  cat > "$1/curl" <<'SH'
#!/usr/bin/env bash
d=${FAKE_WORLD:-}
printf '%s\n' "$*" >> "$d/curl.log"
case "$*" in
  */replies\?since=20*) cat "$d/replies.json" ;;
  */api/velocity-audit*) cat "$d/audit.json" ;;
  *) printf '%s\n' '{"value":{"cards":[]}}' ;;
esac
SH
  chmod +x "$1/curl"
}

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
fake_linear "$BIN"
fake_fleet_axi "$BIN"
fake_curl "$BIN"
export PATH="$BIN:$PATH"
export FM_FLEET_AXI="$BIN/fleet-axi"

# reply <n> <card suffix> <text> [at] [extra json]: one captain reply, request id cl-<n padded>.
reply() {
  local id
  id=$(printf 'cl-00000000-0000-0000-0000-%012d' "$1")
  jq -nc --arg id "$id" --arg card "velocity-vs-20261022-$2" --arg text "$3" --arg at "${4:-2026-10-23T10:00:00Z}" \
    --argjson extra "${5:-{\}}" '{requestId: $id, card: $card, text: $text, at: $at, acknowledged: null, answer: null} + $extra'
}

# make_world <name>: a main home, a quartermaster office home, an archive and the fakes' folders.
make_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/main/data" "$w/main/state" "$w/office/data" "$w/office/state" "$w/linear" "$w/out"
  chmod 700 "$w/main/state" "$w/office/state"
  printf '{"sessions": []}\n' > "$w/spec.json"
  officer_archive "$w/archive" "$DATE" "$w/spec.json"
  printf '%s\n' Bug Improvement agent area:fleet > "$w/linear/labels.txt"
  jq -n '{value: {suggestions: [
    {id: "vs-20261022-1", title: "Agents wait on the staging queue", tldr: "Five waits of ten minutes each.", severity: 4, confidence: 4,
     effort: "S", improvement: "Raise the staging queue concurrency to two.", impact: "Saves an hour a day.", owner: "quartermaster",
     time_saved: "1 hour a day", evidence: [{machine: "Slartibartfast", text: "5 waits, 52 minutes in all"}]},
    {id: "vs-20261022-2", title: "A hook refuses a harmless cd", tldr: "Seven refusals.", severity: 3, confidence: 4, effort: "S",
     improvement: "Say so in the shell guide.", impact: "Saves retries.", owner: "Lee", time_saved: "10 minutes a day", evidence: []},
    {id: "vs-20261022-3", title: "A script waits on slartibartfast", tldr: "Slow disk.", severity: 3, confidence: 3, effort: "M",
     improvement: "Move the scratch folder.", impact: "Saves minutes.", owner: "slarti", time_saved: "5 minutes a day", evidence: []},
    {id: "vs-20261022-4", title: "Odd owner", tldr: "No owner we know.", severity: 3, confidence: 3, effort: "S",
     improvement: "Tidy the log.", impact: "Small.", owner: "the sweeper service", time_saved: "1 minute a day", evidence: []},
    {id: "vs-20261022-5", title: "Token needs care", tldr: "A token step is slow.", severity: 3, confidence: 3, effort: "S",
     improvement: "Rotate the staging token on a schedule.", impact: "Fewer expiries.", owner: "quartermaster", time_saved: "5 minutes a day", evidence: []}
  ]}}' > "$w/audit.json"
  printf '{"value":{"replies":[]}}\n' > "$w/replies.json"
  printf '%s\n' "$w"
}

# set_replies <world> <reply json>...
set_replies() {
  local w=$1
  shift
  printf '%s\n' "$@" | jq -s '{value: {replies: .}}' > "$w/replies.json"
}

# tap_run <world> [extra friction args]: one friction run for $DATE with the world's fakes.
tap_run() {
  local w=$1
  shift
  FAKE_WORLD="$w" FAKE_LINEAR_DIR="$w/linear" python3 -I "$FRICTION" run --archive "$w/archive" --date "$DATE" --out "$w/out" \
    --home "$w/main" --captains-log https://fleet.test/api/captains-log --writes linear --team PC --max-creates 20 \
    --max-linear-calls 200 --jev /nonexistent/jev.py --fm-home "$w/main" --start-home "$w/office=firstmate,skills,fleet-app=quartermaster=" \
    --now "$NOW" "$@" > "$w/run.out" 2> "$w/run.err" || { cat "$w/run.err" >&2; fail "friction run failed in $w"; }
}

digest() { printf '%s\n' "$1/out/$DATE.json"; }
taps() { jq -r "$2" "$(digest "$1")"; }
rows() { jq -r '[.start_requests[] | select(.kind | startswith("velocity-tap"))]' "$(digest "$1")"; }
fleet_calls() { cat "$1/fleet.log" 2>/dev/null || true; }
rid() { printf 'cl-00000000-0000-0000-0000-%012d' "$1"; }
body_of() { jq -r --arg k "$2" '[.start_requests[] | select(.key == $k)][0].execute.argv[6]' "$(digest "$1")"; }
home_of() { jq -r --arg k "$2" '[.start_requests[] | select(.key == $k)][0].execute.env.FM_HOME' "$(digest "$1")"; }

test_create_for_later_files_and_answers() {
  local w
  w=$(make_world later)
  set_replies "$w" "$(reply 1 1 "Create item for later: Agents wait on the staging queue")"
  tap_run "$w"
  assert_equals "PC-101" "$(cat "$w/linear/created" | sed 's/^/PC-/')" "one Linear item was created"
  assert_equals "Improvement agent area:fleet" "$(awk '{print $2}' "$w/linear/labels.used" | paste -sd' ')" \
    "the item carries Improvement, agent and area:fleet"
  assert_equals "101 Fleet" "$(cat "$w/linear/projects.used")" "a fleet item is filed in the Fleet project"
  assert_grep "velocity-taps-fp:" "$w/linear/issue.101" "the item carries the suggestion's fingerprint as its key"
  assert_grep "Raise the staging queue concurrency to two." "$w/linear/issue.101" "the item holds the card's what-to-change text"
  assert_grep "Epic: PC-3576" "$w/linear/issue.101" "the item names its epic"
  assert_equals "captains-log ack $(rid 1)
captains-log answer $(rid 1) Filed as PC-101" "$(fleet_calls "$w" | sed 's/^--as [^ ]* //')" "the reply is acknowledged, then answered with the Linear id"
  assert_equals "0" "$(rows "$w" | jq length)" "Create item for later starts nothing"
  assert_equals "1" "$(taps "$w" '.velocity_taps.handled | length')" "the digest names the handled tap"
  pass "fm-velocity-taps: Create item for later files the issue and answers the reply with its id"
}

test_older_accept_reads_as_create_for_later() {
  local w
  w=$(make_world accept)
  set_replies "$w" "$(reply 2 1 "Accept: Agents wait on the staging queue")"
  tap_run "$w"
  assert_equals "101" "$(cat "$w/linear/created")" "an Accept tap files the issue"
  assert_contains "$(fleet_calls "$w")" "Filed as PC-101" "an Accept tap is answered with the id"
  assert_equals "0" "$(rows "$w" | jq length)" "an Accept tap starts nothing"
  pass "fm-velocity-taps: the older Accept reads as Create item for later"
}

test_create_and_fix_now_hands_a_start_note_to_the_owning_office() {
  local w
  w=$(make_world fix)
  set_replies "$w" "$(reply 3 1 "Create and fix now: Agents wait on the staging queue")"
  tap_run "$w"
  assert_equals "101" "$(cat "$w/linear/created")" "the issue is filed first"
  assert_contains "$(fleet_calls "$w")" "Filed as PC-101" "the reply is answered with the id"
  assert_equals "1" "$(rows "$w" | jq length)" "one start note is handed on"
  assert_equals "$w/office" "$(home_of "$w" "$(rid 3)")" "the note is addressed to the quartermaster office, the card's owner"
  assert_contains "$(body_of "$w" "$(rid 3)")" "Linear PC-101" "the note names the Linear item"
  assert_contains "$(body_of "$w" "$(rid 3)")" "velocity-vs-20261022-1" "the note names the card"
  assert_contains "$(jq -r '[.start_requests[] | select(.key == "'"$(rid 3)"'")][0].execute.request_id' "$(digest "$w")")" "friction-$DATE-" \
    "the request id has the shape the office delivers"
  # The office's delivery runs the recorded fm-inbox.sh call in its own home; here the same call lands the note in the fake inbox.
  local argv
  mapfile -t argv < <(jq -r '[.start_requests[] | select(.key == "'"$(rid 3)"'")][0].execute.argv[]' "$(digest "$w")")
  FM_HOME="$w/office" "${argv[@]}" >/dev/null 2>&1 || fail "the recorded note call must run"
  assert_equals "1" "$(find "$w/office/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" "the note reached the office's inbox"
  assert_equals "1" "$(jq -r '.start_requests | map(select(.kind == "velocity-tap-fix")) | length' "$(digest "$w")")" "exactly one fix note"
  pass "fm-velocity-taps: Create and fix now files, answers and hands one start note to the owning office"
}

test_owners_that_are_not_an_office_go_to_main() {
  local w
  w=$(make_world owners)
  set_replies "$w" \
    "$(reply 4 2 "Create and fix now: A hook refuses a harmless cd")" \
    "$(reply 5 3 "Create and fix now: A script waits on slartibartfast")" \
    "$(reply 6 4 "Create and fix now: Odd owner")"
  tap_run "$w"
  for n in 4 5 6; do
    assert_equals "$w/main" "$(home_of "$w" "$(rid $n)")" "owner Lee, slarti and an unknown owner send the note to main (reply $n)"
  done
  assert_contains "$(body_of "$w" "$(rid 5)")" "Owner named on the card: slarti" "the note names the owner it could not address"
  assert_contains "$(body_of "$w" "$(rid 6)")" "the sweeper service" "an unknown owner is named in the note"
  assert_equals "3" "$(grep -c 'fm-inbox.sh' "$w/out/$DATE.start-requests.sh")" "main's start-requests handoff carries the three notes"
  pass "fm-velocity-taps: an owner that is main, slarti, Lee or unknown sends the start note to main"
}

test_a_reserved_class_is_held_for_main() {
  local w
  w=$(make_world reserved)
  set_replies "$w" "$(reply 7 5 "Create and fix now: Token needs care")"
  tap_run "$w"
  assert_equals "101" "$(cat "$w/linear/created")" "the issue is still filed"
  assert_equals "$w/main" "$(home_of "$w" "$(rid 7)")" "a reserved-class card is never handed to an office"
  assert_equals "velocity-tap-held" "$(jq -r '[.start_requests[] | select(.key == "'"$(rid 7)"'")][0].kind' "$(digest "$w")")" "the note is a hold"
  assert_contains "$(body_of "$w" "$(rid 7)")" "credentials" "the note names the reserved class"
  pass "fm-velocity-taps: a reserved-class suggestion is filed and held for main"
}

test_lets_discuss_notes_main_and_files_nothing() {
  local w
  w=$(make_world discuss)
  set_replies "$w" "$(reply 8 1 "Let's discuss: Agents wait on the staging queue")"
  tap_run "$w"
  assert_absent "$w/linear/created" "Let's discuss files nothing"
  assert_equals "captains-log ack $(rid 8)" "$(fleet_calls "$w" | sed 's/^--as [^ ]* //')" "the reply is acknowledged and never answered"
  assert_equals "$w/main" "$(home_of "$w" "$(rid 8)")" "the discussion note is for main"
  assert_contains "$(body_of "$w" "$(rid 8)")" "talk it through" "the note asks main to talk it through"
  pass "fm-velocity-taps: Let's discuss leaves one note for main and files nothing"
}

test_not_for_us_and_reject_do_nothing() {
  local w
  w=$(make_world notfor)
  set_replies "$w" "$(reply 9 1 "Not for us: Agents wait on the staging queue")" "$(reply 10 2 "Reject: A hook refuses a harmless cd")"
  tap_run "$w"
  assert_absent "$w/linear/created" "Not for us and Reject file nothing"
  assert_absent "$w/linear/log" "Not for us and Reject call Linear not at all"
  assert_equals "0" "$(rows "$w" | jq length)" "Not for us and Reject send no note"
  assert_equals "2" "$(grep -c ' ack ' "$w/fleet.log")" "both replies are acknowledged"
  assert_equals "0" "$(grep -c ' answer ' "$w/fleet.log")" "neither reply is answered"
  pass "fm-velocity-taps: Not for us and the older Reject do nothing but acknowledge"
}

test_object_notes_the_owning_office_once() {
  local w
  w=$(make_world object)
  set_replies "$w" "$(reply 11 1 "Object: Agents wait on the staging queue")" "$(reply 12 1 "Object: Agents wait on the staging queue")"
  tap_run "$w"
  assert_absent "$w/linear/log" "Object calls Linear not at all"
  assert_equals "$w/office" "$(home_of "$w" "object:vs-20261022-1")" "the Object note goes to the owning office"
  assert_equals "1" "$(jq -r '[.start_requests[] | select(.key == "object:vs-20261022-1") | .execute.request_id] | unique | length' "$(digest "$w")")" \
    "a second Object on the card carries the same request id, so the inbox replays it as one note"
  assert_contains "$(body_of "$w" "object:vs-20261022-1")" "stop the work" "the note tells the office to stop"
  pass "fm-velocity-taps: Object sends the owning office one keyed note naming the card"
}

test_a_repeat_tap_never_files_twice() {
  local w
  w=$(make_world repeat)
  set_replies "$w" "$(reply 13 1 "Create item for later: Agents wait on the staging queue")"
  tap_run "$w"
  set_replies "$w" "$(reply 13 1 "Create item for later: Agents wait on the staging queue")" "$(reply 14 1 "Create and fix now: Agents wait on the staging queue")"
  tap_run "$w"
  assert_equals "101" "$(cat "$w/linear/created")" "a second tap on the same card files no second item"
  assert_contains "$(fleet_calls "$w")" "answer $(rid 14) Already filed as PC-101" "the repeat tap is answered with the existing id"
  assert_equals "1" "$(grep -c "answer $(rid 13) " "$w/fleet.log")" "the first reply is answered once"
  assert_equals "$w/office" "$(home_of "$w" "$(rid 14)")" "the repeat tap's Create and fix now still starts the work"
  pass "fm-velocity-taps: a repeat tap on a card files nothing twice and answers with the same id"
}

test_a_rerun_changes_nothing() {
  local w before after calls
  w=$(make_world rerun)
  set_replies "$w" "$(reply 15 1 "Create and fix now: Agents wait on the staging queue")" "$(reply 16 2 "Let's discuss: A hook refuses a harmless cd")"
  tap_run "$w"
  before=$(cat "$(digest "$w")")
  calls=$(wc -l < "$w/fleet.log" | tr -d ' ')
  tap_run "$w"
  after=$(cat "$(digest "$w")")
  assert_equals "$calls" "$(wc -l < "$w/fleet.log" | tr -d ' ')" "a rerun makes no fleet-axi call"
  assert_equals "101" "$(cat "$w/linear/created")" "a rerun files nothing"
  assert_equals "$(printf '%s' "$before" | jq -S '.start_requests')" "$(printf '%s' "$after" | jq -S '.start_requests')" \
    "a rerun of the same date keeps the same start notes, byte for byte"
  pass "fm-velocity-taps: a reply already handled is never handled twice and a rerun is stable"
}

test_replies_someone_else_took_and_old_taps_are_left_alone() {
  local w
  w=$(make_world leftalone)
  set_replies "$w" \
    "$(reply 17 1 "Create item for later: x" 2026-10-23T10:00:00Z '{"answer":{"text":"Filed as PC-9","at":"2026-10-23T11:00:00Z","by":"main"}}')" \
    "$(reply 18 2 "Create item for later: x" 2026-10-23T10:00:00Z '{"acknowledged":{"at":"2026-10-23T11:00:00Z","by":"main"}}')" \
    "$(reply 19 3 "Create item for later: x" 2026-10-01T10:00:00Z)" \
    "$(reply 20 4 "Defer: x")" \
    "$(reply 21 4 "Some other words")"
  tap_run "$w"
  assert_absent "$w/linear/log" "an answered, an acknowledged, an old, a Defer and an unrecognised reply touch nothing"
  assert_absent "$w/fleet.log" "none of them is acknowledged or answered by this pass"
  assert_equals "0" "$(rows "$w" | jq length)" "none of them sends a note"
  pass "fm-velocity-taps: replies main already took, old taps, Defer and unknown words are left alone"
}

test_failed_answers_are_retried_and_writes_none_waits() {
  local w
  w=$(make_world retry)
  set_replies "$w" "$(reply 22 1 "Create item for later: Agents wait on the staging queue")"
  FAKE_FLEET_FAIL=answer tap_run "$w"
  assert_equals "1" "$(taps "$w" '.velocity_taps.waiting | length')" "a reply whose answer failed is left waiting"
  assert_equals "0" "$(taps "$w" '.velocity_taps.handled | length')" "and not counted as handled"
  tap_run "$w"
  assert_equals "101" "$(cat "$w/linear/created")" "the retry reuses the item filed before the failure"
  assert_equals "1" "$(taps "$w" '.velocity_taps.handled | length')" "the next run handles it"
  w=$(make_world nowrites)
  set_replies "$w" "$(reply 23 1 "Create item for later: Agents wait on the staging queue")"
  tap_run "$w" --writes none
  assert_absent "$w/fleet.log" "with writes: none the reply is neither acknowledged nor answered"
  assert_contains "$(taps "$w" '.coverage.notes | join(" ")')" "writes: linear" "the digest says why the tap waits"
  pass "fm-velocity-taps: a failed answer is retried; writes: none leaves the tap to main"
}

test_no_velocity_reply_calls_nothing() {
  local w
  w=$(make_world none)
  set_replies "$w" "$(jq -nc '{requestId: "cl-00000000-0000-0000-0000-000000000099", card: "friction-x", text: "Start fix: x", at: "2026-10-23T10:00:00Z"}')"
  tap_run "$w"
  assert_absent "$w/fleet.log" "a run with no velocity reply calls fleet-axi not at all"
  assert_absent "$w/linear/log" "and Linear not at all"
  assert_no_grep "velocity-audit" "$w/curl.log" "and does not read the velocity audit"
  assert_equals "null" "$(taps "$w" '.velocity_taps')" "the digest has no velocity tap section"
  pass "fm-velocity-taps: a run with no velocity reply calls nothing"
}

fm_test_run \
  test_create_for_later_files_and_answers \
  test_older_accept_reads_as_create_for_later \
  test_create_and_fix_now_hands_a_start_note_to_the_owning_office \
  test_owners_that_are_not_an_office_go_to_main \
  test_a_reserved_class_is_held_for_main \
  test_lets_discuss_notes_main_and_files_nothing \
  test_not_for_us_and_reject_do_nothing \
  test_object_notes_the_owning_office_once \
  test_a_repeat_tap_never_files_twice \
  test_a_rerun_changes_nothing \
  test_replies_someone_else_took_and_old_taps_are_left_alone \
  test_failed_answers_are_retried_and_writes_none_waits \
  test_no_velocity_reply_calls_nothing
