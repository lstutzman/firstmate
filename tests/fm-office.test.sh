#!/usr/bin/env bash
# Behavior tests for bin/fm-office.sh: list and ensure over data/offices.md,
# status over an office home's backlog, and arm-status / disarm-status for its
# silent watcher check, against a fixture primary home and local office homes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OFFICE="$ROOT/bin/fm-office.sh"
TMP_ROOT=$(fm_test_tmproot fm-office)
export FM_OFFICE_HOST=slartibartfast

NAV='- navigator - Drive progress (role: navigator; runs-on: slartibartfast; dispatch: PropertyCompass2; merge: none; merge-via: PropertyCompass2=slarti; auto-merge-classes: none; wip: 2; tick: every 2h; sources: tick,lane:progress; added 2026-11-04)'
QM='- quartermaster - Drive fleet self-improvement (role: quartermaster; runs-on: slartibartfast; dispatch: firstmate,skills; merge: firstmate,skills; merge-via: none; auto-merge-classes: none; wip: 2; tick: every 4h; sources: tick,lane:friction; added 2026-11-04)'

# make_world <name>: a primary home with both offices registered, their
# admission configs copied from the main home's master copies, and each
# office's authority record published.
make_world() {
  local w="$TMP_ROOT/$1" id name
  mkdir -p "$w/data" "$w/config/admission"
  for id in navigator quartermaster; do
    mkdir -p "$w/$id/data" "$w/$id/config/admission"
    printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
    printf '%s\n' "$id" > "$w/$id/.fm-office"
    printf '# Charter\n\n# Office authority\n' > "$w/$id/data/charter.md"
    printf -- '- %s - office (home: %s/%s; scope: office; projects: none; added 2026-11-04)\n' "$id" "$w" "$id" >> "$w/data/secondmates.md"
  done
  printf -- '- PropertyCompass2 [direct-PR merger=slarti] - app (added 2026-10-02)\n' > "$w/navigator/data/projects.md"
  printf -- '- firstmate [no-mistakes admission=fm] - fm (added 2026-10-02)\n- skills [no-mistakes admission=sk] - skills (added 2026-10-02)\n' > "$w/quartermaster/data/projects.md"
  printf -- '- progress - x (role: progress; cadence: daily 07:00; added 2026-10-26)\n- friction - y (role: friction; cadence: daily 06:15; added 2026-10-24)\n' > "$w/data/officers.md"
  printf '# Offices\n\n%s\n%s\n' "$NAV" "$QM" > "$w/data/offices.md"
  for name in fm sk; do
    printf 'command=fm-reserved-classify.sh\nclasses=authority\nclear=none\n' > "$w/config/admission/$name"
    printf 'AGENTS.md authority\n' > "$w/config/admission/$name.rules"
    cp "$w/config/admission/$name" "$w/config/admission/$name.rules" "$w/quartermaster/config/admission/"
  done
  for id in navigator quartermaster; do
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$w" > "$w/$id/.fm-secondmate-parent"
    FM_HOME="$w/$id" bash "$OFFICE" register-sources >/dev/null || fail "register-sources must succeed in $id"
    publish "$w" "$id" >/dev/null || fail "make_world $1: could not publish $id"
  done
  printf '%s\n' "$w"
}

publish() {  # <world> <id>
  FM_HOME="$1" FM_DATA_OVERRIDE="$1/data" FM_CONFIG_OVERRIDE="$1/config" FM_STATE_OVERRIDE="$1/state" \
    bash "$OFFICE" publish "$2"
}

# resolve <office-home>: "<rc>|<office-id>|<error>" from the gate's own resolver.
resolve() {
  bash -c '. "$1"; rc=0; fm_office_resolve "$2" "$2/data" "$2/config" || rc=$?; printf "%s|%s|%s\n" "$rc" "$FM_OFFICE_ID" "$FM_OFFICE_ERROR"' \
    _ "$ROOT/bin/fm-office-authority-lib.sh" "$1"
}

ensure() { FM_HOME="$1" FM_DATA_OVERRIDE="$1/data" bash "$OFFICE" ensure; }

test_healthy_registry_prints_nothing() {
  local w out
  w=$(make_world healthy)
  out=$(ensure "$w")
  assert_equals "" "$out" "ensure output"
  out=$(FM_HOME="$w" FM_DATA_OVERRIDE="$w/data" bash "$OFFICE" list)
  assert_equals "navigator navigator ok
quartermaster quartermaster ok" "$out" "list output"
  pass 'a healthy registry prints nothing from ensure and ok from list'
}

test_absent_registry_means_no_offices() {
  local w
  w=$(make_world absent)
  rm "$w/data/offices.md"
  assert_equals "" "$(ensure "$w")" "ensure output"
  assert_equals "" "$(FM_HOME="$w" FM_DATA_OVERRIDE="$w/data" bash "$OFFICE" list)" "list output"
  pass 'an absent data/offices.md means no offices'
}

# edit_file <file> <cmd...>: rewrite <file> through <cmd>, portable across GNU and BSD.
edit_file() {
  local f=$1
  shift
  "$@" "$f" > "$f.new" && mv "$f.new" "$f"
}

# gap_case <name> <expected substring> <mutation command run in $w>
gap_case() {
  local name=$1 expect=$2 w out
  w=$(make_world "$name")
  (cd "$w" && eval "$3")
  out=$(ensure "$w")
  assert_contains "$out" "OFFICE: office " "$name prefix"
  assert_contains "$out" "$expect" "$name gap"
  pass "ensure reports: $expect"
}

test_gaps() {
  gap_case macbook 'host not allowed: macbook' "edit_file data/offices.md sed 's/runs-on: slartibartfast; dispatch: Property/runs-on: macbook; dispatch: Property/'"
  gap_case role 'unknown role "wizard"' "edit_file data/offices.md sed 's/role: navigator/role: wizard/'"
  gap_case reserved 'unknown role "bosun"' "edit_file data/offices.md sed 's/role: navigator/role: bosun/'"
  gap_case emptyrole 'unknown role ""' "edit_file data/offices.md sed 's/role: navigator; //'"
  gap_case wip 'wip must be' "edit_file data/offices.md sed 's/wip: 2; tick: every 2h/wip: 0; tick: every 2h/'"
  gap_case tick 'tick must be' "edit_file data/offices.md sed 's/tick: every 2h/tick: hourly/'"
  gap_case auto 'auto-merge-classes must be none' "edit_file data/offices.md awk '!d && sub(/auto-merge-classes: none/, \"auto-merge-classes: docs\") { d = 1 } 1'"
  gap_case lane 'lane:nope is not a registered officer' "edit_file data/offices.md sed 's/lane:progress/lane:nope/'"
  gap_case notmate 'not a registered second mate' ": > data/secondmates.md"
  gap_case hostmismatch 'does not include the second mate host' "edit_file data/secondmates.md sed 's/(home:/(host: deepthought; root: \\/r; home:/'"
  gap_case unregistered 'source lane:progress is not registered in' "rm navigator/state/office-lane-progress.check.sh"
  gap_case untrusted 'source tick is not registered in' "printf 'echo x\n' >> navigator/state/office-tick.check.sh"
  gap_case marker '.fm-office marker missing' "rm navigator/.fm-office"
  gap_case charter 'lacks the "# Office authority" heading' "printf '# Charter\n' > navigator/data/charter.md"
  gap_case project 'dispatch project PropertyCompass2 is not in' ": > navigator/data/projects.md"
  gap_case admission 'merge project firstmate has no admission=' "edit_file quartermaster/data/projects.md sed 's/ admission=fm//'"
  gap_case merger 'merge-via project PropertyCompass2 lacks merger=slarti' "edit_file navigator/data/projects.md sed 's/ merger=slarti//'"
  gap_case subset 'merge project skills is not in dispatch' "edit_file data/offices.md sed 's/dispatch: firstmate,skills/dispatch: firstmate/'"
  gap_case overlap 'merge-via project firstmate overlaps merge' "edit_file data/offices.md sed 's/merge-via: none/merge-via: firstmate=slarti/'"
  gap_case malformed 'malformed registry line' "printf -- '- broken line\n' >> data/offices.md"
}

# add_corpus_offices <world>: seed an alchemist and a librarian office home, each
# with its officer, admission config and published authority record, beside
# the two make_world offices.
add_corpus_offices() {
  local w=$1 id
  printf -- '- corpus - c (role: corpus; cadence: daily 05:00; added 2026-11-05)\n- library - l (role: library; cadence: daily 11:30; added 2026-11-05)\n' >> "$w/data/officers.md"
  printf 'command=fm-reserved-classify.sh\nclasses=scan-gate\nclear=none\n' > "$w/config/admission/ta"
  printf 'scrub.py scan-gate\n' > "$w/config/admission/ta.rules"
  for id in alchemist librarian; do
    mkdir -p "$w/$id/data" "$w/$id/config/admission"
    printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
    printf '%s\n' "$id" > "$w/$id/.fm-office"
    printf '# Charter\n\n# Office authority\n' > "$w/$id/data/charter.md"
    printf -- '- %s - office (home: %s/%s; scope: office; projects: none; added 2026-11-06)\n' "$id" "$w" "$id" >> "$w/data/secondmates.md"
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$w" > "$w/$id/.fm-secondmate-parent"
  done
  printf -- '- transcript-archive [no-mistakes admission=ta] - ta (added 2026-11-05)\n' > "$w/alchemist/data/projects.md"
  printf -- '- firstmate [no-mistakes] - fm (added 2026-10-02)\n' > "$w/librarian/data/projects.md"
  cp "$w/config/admission/ta" "$w/config/admission/ta.rules" "$w/alchemist/config/admission/"
  printf -- '- alchemist - Keep the corpus (role: alchemist; runs-on: slartibartfast; dispatch: transcript-archive; merge: transcript-archive; merge-via: none; auto-merge-classes: none; wip: 1; tick: every 6h; sources: tick,lane:corpus; added 2026-11-06)\n' >> "$w/data/offices.md"
  printf -- '- librarian - Keep the documents (role: librarian; runs-on: slartibartfast; dispatch: firstmate; merge: none; merge-via: none; auto-merge-classes: none; wip: 1; tick: every 6h; sources: tick,lane:library; added 2026-11-06)\n' >> "$w/data/offices.md"
  for id in alchemist librarian; do
    FM_HOME="$w/$id" bash "$OFFICE" register-sources >/dev/null || fail "register-sources must succeed in $id"
    publish "$w" "$id" >/dev/null || fail "add_corpus_offices: could not publish $id"
  done
}

test_alchemist_and_librarian_are_accepted_offices() {
  local w out
  w=$(make_world corpus-roles)
  add_corpus_offices "$w"
  assert_equals "" "$(ensure "$w")" "ensure output with both new offices"
  out=$(FM_HOME="$w" FM_DATA_OVERRIDE="$w/data" bash "$OFFICE" list)
  assert_contains "$out" "alchemist alchemist ok" "alchemist listed ok"
  assert_contains "$out" "librarian librarian ok" "librarian listed ok"
  assert_equals "0|alchemist|" "$(resolve "$w/alchemist")" "alchemist's gate"
  assert_equals "0|librarian|" "$(resolve "$w/librarian")" "librarian's gate"
  pass 'ensure is silent and the gate loads for a seeded alchemist and librarian office'
}

test_list_counts_gaps() {
  local w out
  w=$(make_world listgaps)
  rm "$w/navigator/.fm-office"
  out=$(FM_HOME="$w" FM_DATA_OVERRIDE="$w/data" bash "$OFFICE" list)
  assert_contains "$out" "navigator navigator gaps:1" "navigator gaps"
  assert_contains "$out" "quartermaster quartermaster ok" "quartermaster ok"
  pass 'list shows the gap count per office'
}

test_ensure_changes_nothing() {
  local w before after
  w=$(make_world readonly)
  rm "$w/navigator/.fm-office"
  before=$(find "$w" -type f -exec cksum {} + | sort)
  ensure "$w" >/dev/null
  after=$(find "$w" -type f -exec cksum {} + | sort)
  assert_equals "$before" "$after" "files after ensure"
  pass 'ensure is read-only'
}

# --- publish: each office's authority record ----------------------------------

# add_plain_mate <world>: register slarti, a plain second mate, with its home.
add_plain_mate() {
  mkdir -p "$1/slarti/data" "$1/slarti/config"
  printf 'slarti\n' > "$1/slarti/.fm-secondmate-home"
  printf -- '- slarti - plain (home: %s/slarti; scope: plain; projects: none; added 2026-11-04)\n' "$1" >> "$1/data/secondmates.md"
}

test_publish_reaches_only_the_named_office() {
  local w out
  w=$(make_world pub-each)
  assert_equals "fm-office-authority-v1
id=navigator
dispatch=PropertyCompass2
merge=none
merge-via=PropertyCompass2=slarti
auto-merge-classes=none
wip=2
admission-sha256=" "$(cat "$w/navigator/config/office-authority")" "navigator's record"
  assert_contains "$(cat "$w/quartermaster/config/office-authority")" "id=quartermaster" "quartermaster's record names it"
  assert_contains "$(cat "$w/quartermaster/config/office-authority")" "admission-sha256=firstmate:" "quartermaster pins its admission"
  assert_equals "0|navigator|" "$(resolve "$w/navigator")" "navigator's gate"
  assert_equals "0|quartermaster|" "$(resolve "$w/quartermaster")" "quartermaster's gate"
  add_plain_mate "$w"
  out=$(publish "$w" slarti)
  assert_equals "office slarti: unchanged" "$out" "a plain second mate receives nothing"
  assert_absent "$w/slarti/config/office-authority"
  assert_absent "$w/slarti/config/.fm-inherit-office-authority.generation"
  pass 'publish writes each office only its own line, and a plain second mate gets no file and no receipt'
}

test_record_copied_to_another_office_refuses() {
  local w
  w=$(make_world pub-copy)
  cp "$w/navigator/config/office-authority" "$w/navigator/config/.fm-inherit-office-authority.generation" "$w/quartermaster/config/"
  assert_contains "$(resolve "$w/quartermaster")" "id=navigator is not this office (quartermaster)" "a copied record"
  rm "$w/quartermaster/config/.fm-inherit-office-authority.generation"
  assert_contains "$(resolve "$w/quartermaster")" "no published authority record" "a record with no receipt"
  pass "an office refuses another office's record, and a record with no receipt"
}

test_publish_follows_registry_changes() {
  local w out
  w=$(make_world pub-change)
  edit_file "$w/data/offices.md" sed 's/wip: 2; tick: every 2h/wip: 3; tick: every 2h/'
  out=$(ensure "$w")
  assert_contains "$out" "OFFICE: office navigator: authority record is stale" "ensure sees a changed line"
  assert_contains "$out" "run bin/fm-office.sh publish navigator" "ensure names the repair"
  assert_equals "office navigator: pushed" "$(publish "$w" navigator)" "republish"
  assert_contains "$(cat "$w/navigator/config/office-authority")" "wip=3" "republished record"
  assert_equals "" "$(ensure "$w")" "ensure after republish"
  assert_equals "office navigator: unchanged" "$(publish "$w" navigator)" "publish again"
  edit_file "$w/data/offices.md" grep -v '^- navigator '
  assert_equals "office navigator: pushed - mirrored primary absence" "$(publish "$w" navigator)" "revoke"
  assert_absent "$w/navigator/config/office-authority"
  assert_contains "$(resolve "$w/navigator")" "published no authority" "the gate after revocation"
  pass 'publish follows an edited line, ensure reports the stale record, and a removed line revokes'
}

test_local_edits_refuse_until_republished() {
  local w out
  w=$(make_world pub-tamper)
  edit_file "$w/navigator/config/office-authority" sed 's/^wip=2$/wip=9/'
  assert_contains "$(ensure "$w")" "OFFICE: office navigator: authority record is unproven" "ensure sees the edit"
  assert_contains "$(resolve "$w/navigator")" "diverges from the receipt" "the gate refuses the edit"
  publish "$w" navigator >/dev/null
  assert_equals "0|navigator|" "$(resolve "$w/navigator")" "the gate after republish"
  printf 'bin/** none\n' >> "$w/quartermaster/config/admission/fm.rules"
  out=$(ensure "$w")
  assert_contains "$out" "admission config fm in $w/quartermaster/config differs from the master copy" "ensure sees an office-local admission edit"
  publish "$w" quartermaster >/dev/null
  assert_contains "$(ensure "$w")" "admission config fm in" "republishing does not bless an office-local admission edit"
  pass 'a local record edit refuses until republished, and an office-local admission edit stays reported'
}

test_publish_errors_leave_no_authority() {
  local w out
  w=$(make_world pub-error)
  mv "$w/config/admission/sk" "$w/config/admission/sk.gone"
  if out=$(publish "$w" quartermaster 2>&1); then fail "publish succeeded without the master admission config"; fi
  assert_contains "$out" "office quartermaster: error - cannot publish office quartermaster's authority record: the main home's master admission config" "publish error"
  assert_absent "$w/quartermaster/config/.fm-inherit-office-authority.generation"
  assert_contains "$(resolve "$w/quartermaster")" "no published authority record" "the gate after a failed publish"
  assert_contains "$(ensure "$w")" "OFFICE: office quartermaster: cannot publish" "ensure reports it"
  pass 'a publish that cannot pin admission writes nothing and leaves the office with no authority'
}

test_publish_refusals() {
  local w err
  w=$(make_world pub-refuse)
  if err=$(publish "$w" nobody 2>&1); then fail "publish accepted an unregistered id"; fi
  assert_contains "$err" "nobody is not a registered second mate" "unregistered id"
  printf 'quartermaster\n' > "$w/navigator/.fm-secondmate-home"
  if err=$(publish "$w" navigator 2>&1); then fail "publish accepted a home seeded for another mate"; fi
  assert_contains "$err" "is not the seeded home of second mate navigator" "home mismatch"
  if err=$(FM_HOME="$w/quartermaster" FM_DATA_OVERRIDE="$w/data" bash "$OFFICE" publish quartermaster 2>&1); then
    fail "publish ran in a second-mate home"
  fi
  assert_contains "$err" "only the main home publishes office authority" "second-mate home"
  edit_file "$w/data/secondmates.md" sed 's/^- quartermaster - office (home:/- quartermaster - office (host: deepthought; root: \/r; home:/'
  if err=$(publish "$w" quartermaster 2>&1); then fail "publish accepted a remote route"; fi
  assert_contains "$err" "is on a remote route" "remote route"
  pass 'publish refuses an unregistered id, a mismatched home, a second-mate home, and a remote route'
}

test_remote_push_carries_the_record() {
  local w dest fake out gen=1
  w=$(make_world pub-remote)
  dest="$w/remote-nav"
  fake="$w/fakebin"
  mkdir -p "$dest/config" "$dest/state" "$fake"
  printf -- '- navigator - office (host: inherit-host; root: %s; home: %s; scope: office; projects: none; added 2026-11-04)\n' "$ROOT" "$dest" > "$w/data/secondmates.md"
  cat > "$fake/inherit-ssh" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
remote_root=$(printf '%s' "$4" | base64 --decode)
remote_home=$(printf '%s' "$5" | base64 --decode)
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | base64 --decode)
[ "${args[0]}" = fm-remote-inherit.sh ] || exit 92
FM_HOME="$remote_home" FM_STATE_OVERRIDE="$remote_home/state" exec "$remote_root/bin/${args[0]}" "${args[@]:1}"
SH
  chmod +x "$fake/inherit-ssh"
  out=$(FM_HOME="$w" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$w/config" FM_DATA_OVERRIDE="$w/data" \
    FM_INHERITABLE_CONFIG=office-authority FM_SSH_BIN="$fake/inherit-ssh" \
    "$ROOT/bin/fm-remote-inherit-push.sh" navigator "$gen" 2>&1) || fail "remote push failed: $out"
  assert_equals "$(cat "$w/navigator/config/office-authority")" "$(cat "$dest/config/office-authority")" "the remote record"
  printf 'navigator\n' > "$dest/.fm-secondmate-home"
  printf 'navigator\n' > "$dest/.fm-office"
  mkdir -p "$dest/data"
  printf '# Office authority\n' > "$dest/data/charter.md"
  assert_equals "0|navigator|" "$(resolve "$dest")" "the remote office's gate"
  edit_file "$w/data/secondmates.md" sed 's/^- navigator /- quartermaster /'
  if out=$(FM_HOME="$w" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$w/config" FM_DATA_OVERRIDE="$w/data" \
    FM_INHERITABLE_CONFIG=office-authority FM_SSH_BIN="$fake/inherit-ssh" \
    "$ROOT/bin/fm-remote-inherit-push.sh" quartermaster 2 2>&1); then
    fail "a remote office that merges was published"
  fi
  assert_contains "$out" "error: config/office-authority: " "remote merge office error line"
  assert_contains "$out" "cannot be pinned on a remote route" "remote merge office"
  assert_contains "$out" "data/captain-shared.md" "the items after the record still go"
  assert_absent "$dest/config/office-authority"
  edit_file "$w/data/secondmates.md" sed 's/host: inherit-host/host: slartibartfast/'
  assert_contains "$(ensure "$w")" "OFFICE: office quartermaster: it merges" "ensure names the unpublishable remote record"
  pass 'the remote push carries an office its record with a receipt, and sends a remote office that merges an absence'
}

# --- status: the office-status.json projection --------------------------------
NOW=1793786700 # 2026-11-04T10:05:00Z

status() { FM_HOME="$1/navigator" FM_OFFICE_NOW="${2:-$NOW}" bash "$OFFICE" status; }
card() { jq -c --arg id "$2" '.cards[] | select(.id == $id)' "$1/navigator/data/office-status.json"; }

# status_world <name>: the healthy world plus a navigator backlog with two in-flight,
# twelve queued (one held for Lee) and three done items.
status_world() {
  local w i
  w=$(make_world "$1")
  mkdir -p "$w/navigator/state"
  {
    printf '## In flight\n'
    printf -- '- [ ] pc-4701-fix - Fix the thing (repo: PropertyCompass2) (kind: ship) (since 2026-11-03)\n  Main corr abc.\n'
    printf -- '- [ ] pc-4702-body - Body link (repo: PropertyCompass2) (kind: ship) (since 2026-11-04)\n  PR https://github.com/lstutzman/PropertyCompass2/pull/4702 is open.\n'
    printf '\n## Queued\n'
    printf -- '- [ ] q-held - Needs Lee (repo: PropertyCompass2) (kind: task) (since 2026-11-01) (hold: fm-hold-v1:abc) (hold-kind: captain)\n'
    for i in 1 2 3 4 5 6 7 8 9 10 11; do
      printf -- '- [ ] q-%s - Queued item %s https://linear.app/x/issue/PC-47%s (repo: PropertyCompass2) (kind: task) (since 2026-11-01)\n' "$i" "$i" "$i"
    done
    printf '\n## Done\n'
    printf -- '- [x] d-today - Finished today https://github.com/lstutzman/PropertyCompass2/pull/4690 (repo: PropertyCompass2) (kind: ship) (merged 2026-11-04)\n'
    printf -- '- [x] d-old - Finished long ago (repo: PropertyCompass2) (kind: ship) (merged 2026-11-01)\n'
    printf -- '- [x] d-yesterday - Finished yesterday (repo: PropertyCompass2) (kind: ship) (done 2026-11-03)\n'
  } > "$w/navigator/data/backlog.md"
  printf 'pr=https://github.com/lstutzman/PropertyCompass2/pull/4701\nkind=ship\n' > "$w/navigator/state/pc-4701-fix.meta"
  printf '%s\n' "$w"
}

test_status_working_lane() {
  local w out
  w=$(status_world st-working)
  out=$(status "$w" 2>&1)
  assert_equals "" "$out" "status output"
  assert_equals "navigator Navigator 1" "$(jq -r '[.office, .title, .schema_version] | join(" ")' "$w/navigator/data/office-status.json")" "header"
  assert_equals "2026-11-04T10:05:00Z" "$(jq -r .written_at "$w/navigator/data/office-status.json")" "written_at"
  assert_equals '{"id":"pc-4701-fix","title":"Fix the thing","state":"working","link":"https://github.com/lstutzman/PropertyCompass2/pull/4701","since":"2026-11-03T00:00:00Z"}' "$(card "$w" pc-4701-fix)" "meta pr= link wins"
  assert_contains "$(card "$w" pc-4702-body)" '"link":"https://github.com/lstutzman/PropertyCompass2/pull/4702"' "body link"
  pass 'status lists every in-flight item as working, linking the task pr= or the row URL'
}

test_status_next_lane() {
  local w
  w=$(status_world st-next)
  status "$w"
  assert_equals "10" "$(jq '[.cards[] | select(.state == "next")] | length' "$w/navigator/data/office-status.json")" "next cap"
  assert_equals "q-held q-1 q-2" "$(jq -r '[.cards[] | select(.state == "next") | .id][:3] | join(" ")' "$w/navigator/data/office-status.json")" "next order"
  assert_equals '{"id":"q-held","title":"Needs Lee","state":"next","link":"","waiting":"Lee"}' "$(card "$w" q-held)" "held for Lee"
  assert_equals '{"id":"q-1","title":"Queued item 1","state":"next","link":"https://linear.app/x/issue/PC-471","waiting":""}' "$(card "$w" q-1)" "url stripped from title and kept as link"
  assert_equals "" "$(card "$w" q-10)" "eleventh queued item left out"
  pass 'status lists the first 10 queued items in order and marks a captain hold as waiting on Lee'
}

seen() { jq -c . "$1/navigator/state/office-status.seen.json"; }

test_status_done_window() {
  local w
  w=$(status_world st-done)
  status "$w"
  assert_equals '{"id":"d-today","title":"Finished today","state":"done","link":"https://github.com/lstutzman/PropertyCompass2/pull/4690","done_at":"2026-11-04T10:05:00Z"}' "$(card "$w" d-today)" "done today, stamped at first sight"
  assert_equals '{"id":"d-yesterday","title":"Finished yesterday","state":"done","link":"","done_at":"2026-11-04T10:05:00Z"}' "$(card "$w" d-yesterday)" "dated yesterday, first seen now"
  assert_equals "" "$(card "$w" d-old)" "dated before yesterday"
  assert_equals '{"d-today":"2026-11-04T10:05:00Z","d-yesterday":"2026-11-04T10:05:00Z"}' "$(seen "$w")" "seen stamps"
  pass 'status stamps done items dated today or yesterday at first sight and never shows older ones'
}

test_status_done_shows_24_hours_from_first_sight() {
  local w first last gone want
  for first in 1793782800 1793835600; do # 2026-11-04T09:00:00Z, 2026-11-04T23:40:00Z
    case $first in
      1793782800) want=2026-11-04T09:00:00Z last=1793869140 gone=1793869260 ;; # 2026-11-05T08:59Z, 09:01Z
      *) want=2026-11-04T23:40:00Z last=1793921940 gone=1793922060 ;;           # 2026-11-05T23:39Z, 23:41Z
    esac
    w=$(status_world "st-24h-$first")
    status "$w" "$first"
    assert_contains "$(card "$w" d-today)" "\"done_at\":\"$want\"" "first sight at $want"
    status "$w" "$last"
    assert_contains "$(card "$w" d-today)" "\"done_at\":\"$want\"" "23h59m after $want"
    status "$w" "$gone"
    assert_equals "" "$(card "$w" d-today)" "24h01m after $want"
    status "$w" $((gone + 600))
    assert_equals "" "$(card "$w" d-today)" "a later run after $want"
    rm "$w/navigator/data/office-status.json"
    status "$w" $((gone + 1200))
    assert_equals "" "$(card "$w" d-today)" "a run after the projection was deleted ($want)"
  done
  pass 'a done card shows for 24 hours from its own first sight and never comes back'
}

test_status_seen_file_loss_keeps_old_items_out() {
  local w
  w=$(status_world st-seen-lost)
  mkdir -p "$w/navigator/state"
  printf 'not json\n' > "$w/navigator/state/office-status.seen.json"
  status "$w"
  assert_equals "" "$(card "$w" d-old)" "corrupt seen file"
  rm "$w/navigator/state/office-status.seen.json"
  status "$w" $((NOW + 60))
  assert_equals "" "$(card "$w" d-old)" "deleted seen file"
  assert_equals "null" "$(jq '."d-old"' "$w/navigator/state/office-status.seen.json")" "old item never stamped"
  pass 'a corrupt or missing seen file does not bring back an item dated before yesterday'
}

test_status_prunes_old_stamps() {
  local w
  w=$(status_world st-prune)
  status "$w"
  status "$w" 1794305100 # 2026-11-10T10:05:00Z, six days later
  assert_equals '{"d-today":"2026-11-04T10:05:00Z","d-yesterday":"2026-11-04T10:05:00Z"}' "$(seen "$w")" "stamps within 7 days kept"
  status "$w" 1794391560 # 2026-11-11T10:06:00Z, seven days and a minute later
  assert_equals '{}' "$(seen "$w")" "stamps older than 7 days pruned"
  assert_equals "" "$(card "$w" d-today)" "pruned item not shown again"
  pass 'status prunes seen stamps older than 7 days'
}

test_status_skips_unchanged_write() {
  local w ino
  w=$(status_world st-same)
  status "$w"
  ino=$(ls -i "$w/navigator/data/office-status.json")
  status "$w" $((NOW + 300))
  assert_equals "$ino" "$(ls -i "$w/navigator/data/office-status.json")" "file replaced although nothing changed"
  assert_equals "2026-11-04T10:05:00Z" "$(jq -r .written_at "$w/navigator/data/office-status.json")" "written_at untouched"
  status "$w" $((NOW + 1000))
  assert_equals "2026-11-04T10:21:40Z" "$(jq -r .written_at "$w/navigator/data/office-status.json")" "heartbeat refresh"
  printf -- '- [ ] q-new - New item (repo: PropertyCompass2) (kind: task) (since 2026-11-04)\n' >> "$w/navigator/data/backlog.md"
  status "$w" $((NOW + 1060))
  assert_equals "2026-11-04T10:22:40Z" "$(jq -r .written_at "$w/navigator/data/office-status.json")" "rewrite on change"
  pass 'status rewrites only on a change or after the refresh interval'
}

test_status_writes_only_its_file() {
  local w before after
  w=$(status_world st-only)
  before=$(find "$w" -type f ! -name office-status.json ! -name office-status.seen.json -exec cksum {} + | sort)
  status "$w"
  after=$(find "$w" -type f ! -name office-status.json ! -name office-status.seen.json -exec cksum {} + | sort)
  assert_equals "$before" "$after" "files other than office-status.json and office-status.seen.json"
  [ -f "$w/navigator/state/office-status.seen.json" ] || fail "seen file not written"
  assert_equals "" "$(find "$w/navigator" -name '.office-status.*')" "temp files left behind"
  pass 'status writes only data/office-status.json and state/office-status.seen.json'
}

test_status_outside_an_office_does_nothing() {
  local w
  w=$(status_world st-plain)
  rm "$w/navigator/.fm-office"
  assert_equals "" "$(status "$w" 2>&1)" "output"
  assert_absent "$w/navigator/data/office-status.json"
  pass 'status does nothing in a home with no .fm-office marker'
}

test_status_without_a_backlog_is_empty() {
  local w
  w=$(make_world st-empty)
  status "$w"
  assert_equals "[]" "$(jq -c .cards "$w/navigator/data/office-status.json")" "cards"
  pass 'status writes an empty card list when the office has no backlog'
}

test_status_projects_decisions() {
  local w f
  w=$(make_world st-decisions)
  f="$w/navigator/data/office-decisions.md"
  {
    printf '# Decisions\n\n| Date | Source | Finding | Call | Action |\n|---|---|---|---|---|\n'
    printf '| 2026-11-03 | older | Old finding | Adopt | Done: [x](https://e.test/1) |\n'
    printf '| 2026-11-05 | first | Same day first | Trial | Queued |\n'
    printf '| 2026-11-05 | second | Same day second | Needs Lee | Asked |\n'
    printf '| 2026-11-05 | short | only four | cells |\n'
    printf '| not a date | s | f | c | a |\n'
    printf '| 2026-11-04 | s | | c | a |\n'
    # shellcheck disable=SC2016 # literal backticks in the markdown row
    printf '%s\n' '| 2026-11-02 | piped | Use `a \| b` | Adopt | Done |'
  } > "$f"
  status "$w"
  assert_equals "second first older piped" "$(jq -r '[.decisions[].source] | join(" ")' "$w/navigator/data/office-status.json")" "newest first, malformed skipped"
  # shellcheck disable=SC2016 # literal backticks in the expected cell
  assert_equals 'Use `a | b`' "$(jq -r '.decisions[3].finding' "$w/navigator/data/office-status.json")" "escaped pipe stays in its cell"
  assert_equals "Done: [x](https://e.test/1)" "$(jq -r '.decisions[2].action' "$w/navigator/data/office-status.json")" "link stays text"
  assert_equals "date source finding call action" "$(jq -r '.decisions[0] | keys_unsorted | join(" ")' "$w/navigator/data/office-status.json")" "keys"
  pass 'status projects office-decisions.md newest first and skips malformed rows'
}

test_status_decisions_cap_and_absence() {
  local w i
  w=$(make_world st-decisions-cap)
  status "$w"
  assert_equals "[]" "$(jq -c .decisions "$w/navigator/data/office-status.json")" "absent file"
  {
    printf '| Date | Source | Finding | Call | Action |\n|---|---|---|---|---|\n'
    for i in $(seq 1 25); do printf '| 2026-10-%02d | s%s | f | c | a |\n' "$i" "$i"; done
  } > "$w/navigator/data/office-decisions.md"
  status "$w" $((NOW + 1000))
  assert_equals "20 s25 s6" "$(jq -r '[(.decisions | length), .decisions[0].source, .decisions[-1].source] | join(" ")' "$w/navigator/data/office-status.json")" "cap"
  pass 'status caps decisions at 20 and writes an empty list when the file is absent'
}

# --- arm-status / disarm-status: the silent status check -----------------------
arm() { FM_HOME="$1/navigator" bash "$OFFICE" "${2:-arm-status}"; }
check_registered() {
  (. "$ROOT/bin/fm-pr-lib.sh" && . "$ROOT/bin/fm-check-lib.sh" && fm_custom_check_registered "$1/navigator/state" office-status)
}

test_arm_status_registers_a_silent_check() {
  local w shim out before
  w=$(status_world arm)
  out=$(arm "$w" 2>&1)
  assert_equals "" "$out" "arm output"
  shim="$w/navigator/state/office-status.check.sh"
  [ -x "$shim" ] || fail "check is not executable"
  assert_equals "700" "$(stat -c %a "$shim" 2>/dev/null || stat -f %Lp "$shim")" "check mode"
  check_registered "$w" || fail "check is not bound by its trust file"
  before=$(cksum "$shim" "$w/navigator/state/office-status.check-trust")
  arm "$w"
  assert_equals "$before" "$(cksum "$shim" "$w/navigator/state/office-status.check-trust")" "second arm"
  out=$(cd / && env -u FM_HOME "$shim" 2>&1)
  assert_equals "" "$out" "check output"
  assert_equals "navigator" "$(jq -r .office "$w/navigator/data/office-status.json")" "check wrote the projection"
  pass 'arm-status writes and binds a check that runs status silently, and arming twice changes nothing'
}

test_disarm_status_retires_the_check() {
  local w
  w=$(status_world disarm)
  arm "$w"
  arm "$w" disarm-status
  assert_absent "$w/navigator/state/office-status.check.sh"
  assert_absent "$w/navigator/state/office-status.check-trust"
  arm "$w" disarm-status || fail "disarming an unarmed office failed"
  pass 'disarm-status removes the check and its trust file'
}

test_arm_status_refuses_outside_an_office() {
  local w err cmd
  w=$(status_world arm-plain)
  rm "$w/navigator/.fm-office"
  for cmd in arm-status disarm-status; do
    if err=$(arm "$w" "$cmd" 2>&1 >/dev/null); then fail "$cmd succeeded outside an office home"; fi
    assert_contains "$err" "no .fm-office marker" "$cmd stderr"
  done
  assert_absent "$w/navigator/state/office-status.check.sh"
  pass 'arm-status and disarm-status refuse in a home with no .fm-office marker'
}

# ---- wake sources: register-sources and check ----

SRC_NOW=1793700000   # a fixed instant; TZ=UTC below
export TZ=UTC
SLOT=$(date -u -d "@$SRC_NOW" +%Y-%m-%dT%H 2>/dev/null || date -u -r "$SRC_NOW" +%Y-%m-%dT%H)

# source_world <name>: make_world plus the parent binding every office home carries.
source_world() {
  local w
  w=$(make_world "src-$1")
  mkdir -p "$w/navigator/state" "$w/data/officers/progress" "$w/data/officers/surgeon"
  sed -i.bak 's/sources: tick,lane:progress;/sources: tick,lane:progress,lane:surgeon:high;/' "$w/data/offices.md" && rm -f "$w/data/offices.md.bak"
  printf -- '- surgeon - z (role: triage; cadence: daily 06:00; added 2026-10-24)\n' >> "$w/data/officers.md"
  printf '%s\n' "$w"
}

# nav_check <world> <source>: the office's check, run as its shim would.
nav_check() { FM_OFFICE_NOW=$SRC_NOW FM_HOME="$1/navigator" bash "$OFFICE" check "$2"; }

put_backlog() {  # <world> <queued lines...>
  local w=$1
  shift
  { printf '## In flight\n\n## Queued\n'; printf '%s\n' "$@"; printf '\n## Done\n'; } > "$w/navigator/data/backlog.md"
}

put_digest() {  # <world> <officer> <key> <n>
  printf 'DIGEST %s %s data/officers/%s/%s.md\n' "$3" "$4" "$2" "$3" > "$1/data/officers/$2/digest"
}

# upstream_world <name>: an upstream repo with 3 commits, a fork (bare origin plus a code root) that has the first, and a
# quartermaster-style office home whose config names the upstream by path.
upstream_world() {
  local w up fork g
  w=$(source_world "$1")
  up="$w/up-work"; fork="$w/fork-root"
  g="git -c user.email=t@t -c user.name=t"
  mkdir -p "$up" && git -C "$up" init -q -b main && $g -C "$up" commit -q --allow-empty -m "base"
  git clone -q --bare "$up" "$w/fork-origin.git"
  git clone -q "$w/fork-origin.git" "$fork"
  $g -C "$up" commit -q --allow-empty -m "up one" && $g -C "$up" commit -q --allow-empty -m "up two"
  sed -i.bak 's/sources: tick,lane:progress,lane:surgeon:high;/sources: tick,upstream;/' "$w/data/offices.md" && rm -f "$w/data/offices.md.bak"
  mkdir -p "$w/navigator/config"
  printf '# the upstream\n%s main origin/main\n' "$up" > "$w/navigator/config/firstmate-upstream"
  FM_HOME="$w/navigator" bash "$OFFICE" register-sources >/dev/null || fail "register-sources must accept upstream"
  printf '%s\n' "$w"
}

up_hourly() {  # <world> <start-epoch> <hours> <label>: hourly failing attempts, all silent
  local i
  for ((i = 0; i <= $3; i++)); do
    assert_equals "" "$(up_check "$1" $(($2 + i * 3600)))" "$4: silent at hour $i"
  done
}

up_check() {  # <world> <epoch>
  FM_OFFICE_NOW=$2 FM_ROOT_OVERRIDE="$1/fork-root" FM_HOME="$1/navigator" bash "$OFFICE" check upstream
}

test_upstream_wakes_once_per_new_head() {
  local w out g="git -c user.email=t@t -c user.name=t"
  w=$(upstream_world upnew)
  out=$(up_check "$w" "$SRC_NOW")
  assert_contains "$out" "office navigator: upstream " "a new upstream head wakes the office"
  assert_contains "$out" "2 new commit(s) not in origin/main; newest: up two | up one" "digest counts and names the commits"
  assert_equals "" "$(up_check "$w" $((SRC_NOW + 90000)))" "the same head the next day: silent"
  $g -C "$w/up-work" commit -q --allow-empty -m "up three"
  assert_contains "$(up_check "$w" $((SRC_NOW + 180000)))" "3 new commit(s)" "a newer head wakes again"
  pass 'the upstream source wakes once per new upstream head'
}

test_upstream_is_daily_and_silent_when_nothing_new() {
  local w g="git -c user.email=t@t -c user.name=t"
  w=$(upstream_world upday)
  git -C "$w/fork-origin.git" fetch -q "$w/up-work" main:main
  assert_equals "" "$(up_check "$w" "$SRC_NOW")" "nothing new for the fork: silent"
  $g -C "$w/up-work" commit -q --allow-empty -m "later"
  assert_equals "" "$(up_check "$w" $((SRC_NOW + 7200)))" "already checked today: no second fetch"
  assert_contains "$(up_check "$w" $((SRC_NOW + 90000)))" "1 new commit(s)" "the next day looks again"
  pass 'the upstream source checks once a day and stays silent when the fork has everything'
}

ratchet_check() {  # <world> <list> <epoch>
  FM_LINT_RATCHET_LIST=$2 FM_OFFICE_NOW=$3 FM_HOME="$1/navigator" bash "$OFFICE" check ratchet
}

test_ratchet_names_the_next_file_once_a_day() {
  local w list
  w=$(source_world ratchetday)
  sed -i.bak 's/sources: tick,lane:progress,lane:surgeon:high;/sources: tick,ratchet;/' "$w/data/offices.md" && rm -f "$w/data/offices.md.bak"
  FM_HOME="$w/navigator" bash "$OFFICE" register-sources >/dev/null || fail "register-sources must accept ratchet"
  [ -x "$w/navigator/state/office-ratchet.check.sh" ] || fail "register-sources did not install the ratchet shim"
  list="$w/ratchet.list"
  printf '# header\nbin/a.sh\nbin/b.sh\n' > "$list"
  assert_equals "office navigator: ratchet 2026-11-07: next file bin/a.sh (2 left on bin/fm-lint-ratchet.exceptions); if no ratchet PR for bin/a.sh is open, dispatch one ship worker to fix it until bin/fm-lint-ratchet.sh check bin/a.sh passes, retire it with bin/fm-lint-ratchet.sh retire bin/a.sh, and open one PR" \
    "$(ratchet_check "$w" "$list" 1794009600)" "the first check of a day names the next file"
  assert_equals "" "$(ratchet_check "$w" "$list" $((1794009600 + 3600)))" "the same day again: silent"
  printf '# header\n' > "$list"
  assert_equals "" "$(ratchet_check "$w" "$list" $((1794009600 + 90000)))" "an empty list: silent"
  printf 'bin/b.sh\n' > "$list"
  assert_contains "$(ratchet_check "$w" "$list" $((1794009600 + 180000)))" "ratchet 2026-11-09: next file bin/b.sh (1 left" "the next day wakes again"
  pass 'the ratchet source names the next listed file once per UTC day'
}

test_upstream_failure_reports_only_when_persistent() {
  local w
  w=$(upstream_world upfail)
  printf '%s/nowhere main origin/main\n' "$w" > "$w/navigator/config/firstmate-upstream"
  up_hourly "$w" "$SRC_NOW" 23 "a failure inside 24 hours"
  assert_contains "$(up_check "$w" $((SRC_NOW + 86400)))" "failing since" "a failure spanning a day reports"
  assert_equals "" "$(up_check "$w" $((SRC_NOW + 90000)))" "reported once per streak"
  pass 'the upstream source reports a persistent fetch failure once'
}

test_upstream_unresolved_fork_ref_reports_when_persistent() {
  local w up
  w=$(upstream_world upforkref)
  up="$w/up-work"
  printf '%s main nosuch/main\n' "$up" > "$w/navigator/config/firstmate-upstream"
  up_hourly "$w" "$SRC_NOW" 23 "an unresolved fork-ref inside 24 hours"
  assert_contains "$(up_check "$w" $((SRC_NOW + 86400)))" "against nosuch/main failing since" "an unresolved fork-ref spanning a day reports"
  printf '%s main origin/main\n' "$up" > "$w/navigator/config/firstmate-upstream"
  assert_contains "$(up_check "$w" $((SRC_NOW + 90000)))" "2 new commit(s)" "a fixed fork-ref checks normally"
  [ ! -e "$w/navigator/data/office/upstream.fail" ] || fail "a success must clear the failure streak"
  pass 'the upstream source reports an unresolved fork-ref once failures span a day'
}

test_upstream_gap_in_attempts_starts_a_new_streak() {
  local w
  w=$(upstream_world upgap)
  printf '%s/nowhere main origin/main\n' "$w" > "$w/navigator/config/firstmate-upstream"
  assert_equals "" "$(up_check "$w" "$SRC_NOW")" "first failure: silent"
  up_hourly "$w" $((SRC_NOW + 108000)) 23 "after a 30-hour pause, a new streak"
  assert_contains "$(up_check "$w" $((SRC_NOW + 108000 + 86400)))" "failing since" "the new streak reports once it spans a day"
  pass 'a pause in upstream attempts starts a new failure streak instead of reporting at once'
}

test_upstream_without_config_is_silent() {
  local w
  w=$(upstream_world upnone)
  rm -f "$w/navigator/config/firstmate-upstream"
  assert_equals "" "$(up_check "$w" "$SRC_NOW")" "no config: silent"
  pass 'the upstream source is silent without config/firstmate-upstream'
}

test_register_sources_installs_trusted_shims() {
  local w out
  w=$(source_world reg)
  out=$(FM_HOME="$w/navigator" bash "$OFFICE" register-sources) || fail "register-sources must succeed: $out"
  assert_contains "$out" "registered: office source tick (state/office-tick.check.sh)" "tick registered"
  assert_contains "$out" "state/office-lane-progress.check.sh" "lane registered"
  assert_contains "$out" "state/office-lane-surgeon-high.check.sh" "high lane registered"
  assert_present "$w/navigator/state/office-tick.check-trust" "the shim is trusted"
  assert_contains "$(cat "$w/navigator/state/office-lane-progress.check.sh")" "fm-office.sh check lane:progress" "the shim runs the lane check"
  assert_contains "$(cat "$w/navigator/state/office-lane-surgeon-high.check.sh")" "fm-office.sh check lane:surgeon:high" "the shim runs the high check"
  assert_contains "$(cat "$w/navigator/state/office-tick.check.sh")" "FM_HOME=$(cd "$w/navigator" && pwd -P)" "the shim points at the office's own home"
  assert_absent "$w/state/office-tick.check.sh" "nothing is registered in the parent"
  before=$(find "$w/navigator/state" -type f -exec cksum {} + | sort)
  FM_HOME="$w/navigator" bash "$OFFICE" register-sources >/dev/null || fail "second register-sources must succeed"
  assert_equals "$before" "$(find "$w/navigator/state" -type f -exec cksum {} + | sort)" "re-registering is idempotent"
  # a source dropped from the registry line is unregistered
  sed -i.bak 's/sources: tick,lane:progress,lane:surgeon:high;/sources: tick;/' "$w/data/offices.md" && rm -f "$w/data/offices.md.bak"
  out=$(FM_HOME="$w/navigator" bash "$OFFICE" register-sources) || fail "register-sources after edit must succeed"
  assert_contains "$out" "unregistered: state/office-lane-progress.check.sh" "a dropped source is unregistered"
  assert_absent "$w/navigator/state/office-lane-progress.check.sh" "its shim is gone"
  assert_absent "$w/navigator/state/office-lane-progress.check-trust" "its trust is gone"
  assert_present "$w/navigator/state/office-tick.check.sh" "listed sources stay"
  out=$(FM_HOME="$w" FM_DATA_OVERRIDE="$w/data" bash "$OFFICE" register-sources 2>&1) && fail "register-sources must refuse a non-office home"
  assert_contains "$out" "only in an office home" "the refusal says why"
  pass 'register-sources installs trusted per-source shims, idempotently, and drops unlisted ones'
}

test_register_sources_keeps_the_status_check() {
  local w
  w=$(source_world keepstatus)
  arm "$w" || fail "arm-status must succeed"
  FM_HOME="$w/navigator" bash "$OFFICE" register-sources >/dev/null || fail "register-sources must succeed"
  check_registered "$w" || fail "register-sources unregistered the status check"
  assert_present "$w/navigator/state/office-status.check.sh" "the status check stays"
  pass 'register-sources leaves the armed status check registered'
}

test_shim_runs_through_the_watcher_trust_path() {
  local w out
  w=$(source_world shim)
  FM_HOME="$w/navigator" bash "$OFFICE" register-sources >/dev/null || fail "register-sources must succeed"
  put_backlog "$w" '- [ ] job-a - Do a thing (repo: PropertyCompass2) (kind: ship)'
  out=$(FM_OFFICE_NOW=$SRC_NOW bash "$w/navigator/state/office-tick.check.sh") || fail "shim must exit 0"
  assert_contains "$out" "office navigator: tick $SLOT: 2 of 2 places free, 1 queued" "the shim prints the tick line"
  pass 'a registered shim runs the check with the office home'
}

test_tick_prints_once_per_slot_and_only_when_work_could_start() {
  local w out
  w=$(source_world tick)
  assert_equals "" "$(nav_check "$w" tick)" "nothing queued and no digest: silent"
  put_backlog "$w" '- [ ] held-1 - Held (repo: x) (kind: captain) (hold: captain choice) (hold-kind: captain)' '- [ ] blocked-1 - Blocked blocked-by: other - why (repo: x)'
  assert_equals "" "$(nav_check "$w" tick)" "held and blocked items do not count as queued"
  put_backlog "$w" '- [ ] job-a - A (repo: x) (kind: ship)' '- [ ] job-b - B (repo: x) (kind: ship)' '- [ ] held-1 - Held (repo: x) (hold: c)'
  out=$(nav_check "$w" tick)
  assert_equals "office navigator: tick $SLOT: 2 of 2 places free, 2 queued" "$out" "tick line"
  assert_equals "" "$(nav_check "$w" tick)" "the slot was already reported"
  out=$(FM_OFFICE_NOW=$((SRC_NOW + 7200)) FM_HOME="$w/navigator" bash "$OFFICE" check tick)
  assert_contains "$out" "tick " "the next slot reports again"
  assert_contains "$out" "2 queued" "next slot count"
  pass 'tick prints once per slot, counts only unheld unblocked queued items, and is silent with nothing to start'
}

test_tick_is_silent_when_places_are_full() {
  local w
  w=$(source_world full)
  put_backlog "$w" '- [ ] job-a - A (repo: x) (kind: ship)'
  printf 'kind=ship\nproject=x\n' > "$w/navigator/state/t1.meta"
  printf 'kind=scout\nproject=x\n' > "$w/navigator/state/t2.meta"
  assert_equals "" "$(nav_check "$w" tick)" "both places taken: silent"
  rm "$w/navigator/state/t2.meta"
  assert_contains "$(nav_check "$w" tick)" "1 of 2 places free, 1 queued" "one place free"
  printf 'kind=secondmate\n' > "$w/navigator/state/m1.meta"
  rm -f "$w/navigator/data/office/tick.seen"
  assert_contains "$(nav_check "$w" tick)" "1 of 2 places free" "a second mate record holds no place"
  pass 'tick counts live ship and scout records against wip and is silent when none is free'
}

# put_landing <world> <id> <project> [handoff]: a ship whose ready PR was handed
# to its merger and whose worker reported done; with handoff "record" (the
# default) state/<id>.merge-handoff names the PR, with "none" nothing does.
put_landing() {
  local s="$1/navigator/state" id=$2 url="https://github.com/o/r/pull/7$2"
  printf 'kind=ship\nproject=%s\nyolo=on\npr=%s\n' "$3" "$url" > "$s/$id.meta"
  printf 'done [at=%s]: PR %s checks green\n' "$((SRC_NOW - 600))" "$url" > "$s/$id.status"
  [ "${4:-record}" = none ] || printf '%s abc123\n' "$url" > "$s/$id.merge-handoff"
}

test_tick_leaves_landing_tasks_out_of_wip() {
  local w s
  w=$(source_world landing)
  s="$w/navigator/state"
  put_backlog "$w" '- [ ] job-a - A (repo: x) (kind: ship)'
  put_landing "$w" t1 x
  printf 'kind=scout\nproject=x\n' > "$s/t2.meta"
  assert_contains "$(nav_check "$w" tick)" "1 of 2 places free, 1 queued, 1 landing" "a landing task holds no place"

  rm -f "$w/navigator/data/office/tick.seen"
  printf 'needs-decision [at=%s] [cause=decision] [key=nm-r1-review]: ask-user findings=f1\n' "$((SRC_NOW - 300))" >> "$s/t1.status"
  assert_equals "" "$(nav_check "$w" tick)" "a task with an open finding still holds its place"
  printf 'resolved [at=%s] [key=nm-r1-review]: answered\n' "$((SRC_NOW - 200))" >> "$s/t1.status"
  assert_equals "" "$(nav_check "$w" tick)" "a worker resumed after its answer still holds its place"
  printf 'done [at=%s]: PR checks green again\n' "$((SRC_NOW - 100))" >> "$s/t1.status"
  assert_contains "$(nav_check "$w" tick)" "1 landing" "a fresh done frees the place again"

  rm -f "$w/navigator/data/office/tick.seen"
  mkdir -p "$s/t1.inbox/handled"
  printf 'schema=fm-task-inbox.v1\nat=%s\n--\nfix the review comment\n' "$(date -u -d "@$((SRC_NOW - 50))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$((SRC_NOW - 50))" +%Y-%m-%dT%H:%M:%SZ)" > "$s/t1.inbox/handled/001.msg"
  assert_equals "" "$(nav_check "$w" tick)" "a worker steered back into fix work after its done holds its place"
  printf 'done [at=%s]: fix pushed, checks green\n' "$SRC_NOW" >> "$s/t1.status"
  assert_contains "$(nav_check "$w" tick)" "1 landing" "the done after the fix frees the place"
  rm -f "$w/navigator/data/office/tick.seen"
  printf 'schema=fm-task-inbox.v1\nat=2026-01-01T00:00:00Z\n--\nnew steer\n' > "$s/t1.inbox/002.msg"
  assert_equals "" "$(nav_check "$w" tick)" "an unhandled steer holds the place"
  pass 'tick leaves a ready, handed-off ship out of wip, and counts one with an open finding, a later event or a steer'
}

test_landing_needs_a_handoff_to_another_merger() {
  local w s
  w=$(source_world handoff)
  s="$w/navigator/state"
  put_backlog "$w" '- [ ] job-a - A (repo: x) (kind: ship)'
  printf 'kind=scout\nproject=x\n' > "$s/t2.meta"
  put_landing "$w" t1 "$w/projects/x" none
  assert_equals "" "$(nav_check "$w" tick)" "a ready PR handed to nobody still holds its place"
  printf 'needs-decision [at=%s] [key=merge-handoff-7t1] [cause=external]: [handoff=slarti] https://github.com/o/r/pull/7t1 is ready to merge\n' "$((SRC_NOW - 900))" >> "$s/t1.status"
  assert_contains "$(nav_check "$w" tick)" "1 landing" "an open merge-handoff decision for the PR is a handoff"
  put_landing "$w" t1 "$w/projects/PropertyCompass2" none
  rm -f "$w/navigator/data/office/tick.seen"
  if command -v tasks-axi >/dev/null 2>&1; then
    assert_contains "$(nav_check "$w" tick)" "1 landing" "a project merged by another home is a handoff"
  else
    assert_equals "" "$(nav_check "$w" tick)" "without tasks-axi the captain-hold read fails, so the merger binding alone frees no place"
  fi
  put_landing "$w" t1 "$w/projects/x"
  printf 'x\n' > "$s/t1.merge-handoff"
  rm -f "$w/navigator/data/office/tick.seen"
  assert_equals "" "$(nav_check "$w" tick)" "a handoff record for another PR is no handoff"
  pass 'a landing task needs its PR handed to another merger: a handoff record, an open handoff decision, or the merger binding'
}

test_tick_counts_unread_lane_digests() {
  local w out
  w=$(source_world tickdigest)
  put_digest "$w" progress 2026-11-04 3
  out=$(nav_check "$w" tick)
  assert_equals "office navigator: tick $SLOT: 2 of 2 places free, 0 queued, 1 unread digest(s)" "$out" "an unread digest lets the tick fire"
  nav_check "$w" lane:progress >/dev/null
  rm -f "$w/navigator/data/office/tick.seen"
  assert_equals "" "$(nav_check "$w" tick)" "a reported digest no longer counts as unread"
  pass 'tick fires for an unread lane digest even with nothing queued'
}

test_lane_check_reports_each_new_digest_once() {
  local w out
  w=$(source_world lane)
  assert_equals "" "$(nav_check "$w" lane:progress)" "no digest file: silent"
  put_digest "$w" progress 2026-11-04 0
  assert_equals "" "$(nav_check "$w" lane:progress)" "an empty digest: silent"
  put_digest "$w" progress 2026-11-04 4
  out=$(nav_check "$w" lane:progress)
  assert_equals "office navigator: progress digest 2026-11-04: 4 finding(s) in $w/data/officers/progress/2026-11-04.md" "$out" "lane line"
  assert_equals "" "$(nav_check "$w" lane:progress)" "a repeat: silent"
  put_digest "$w" progress 2026-11-05 1
  assert_contains "$(nav_check "$w" lane:progress)" "digest 2026-11-05: 1 finding(s)" "a new digest reports"
  pass 'a lane check prints once per new digest and ignores repeats and empty digests'
}

test_lane_check_reads_a_spaced_sources_list() {
  local w
  w=$(source_world spaced)
  sed -i.bak 's/sources: tick,lane:progress,/sources: tick, lane:progress, /' "$w/data/offices.md" && rm -f "$w/data/offices.md.bak"
  put_digest "$w" progress 2026-11-04 2
  assert_contains "$(nav_check "$w" lane:progress)" "progress digest 2026-11-04: 2 finding(s)" "a source listed after a comma and space still reports"
  pass 'a lane check finds its source in a sources list with spaces after the commas'
}

test_lane_check_is_silent_when_it_cannot_read() {
  local w
  w=$(source_world unreadable)
  put_digest "$w" progress 2026-11-04 4
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=elsewhere\n' > "$w/navigator/.fm-secondmate-parent"
  assert_equals "" "$(nav_check "$w" lane:progress)" "a remote parent: silent"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$w" > "$w/navigator/.fm-secondmate-parent"
  chmod 000 "$w/data/officers/progress/digest"
  [ -r "$w/data/officers/progress/digest" ] || assert_equals "" "$(nav_check "$w" lane:progress)" "an unreadable file: silent"
  chmod 644 "$w/data/officers/progress/digest"
  assert_equals "" "$(nav_check "$w" lane:nope)" "an unregistered source: silent"
  rm "$w/navigator/.fm-secondmate-parent"
  assert_equals "" "$(nav_check "$w" lane:progress)" "no parent binding: silent"
  assert_equals "" "$(FM_OFFICE_NOW=$SRC_NOW FM_HOME="$w" bash "$OFFICE" check lane:progress)" "a non-office home: silent"
  pass 'checks are silent for a remote parent, an unreadable file, an unregistered source and a non-office home'
}

test_high_lane_counts_only_high_severity() {
  local w out
  w=$(source_world high)
  put_digest "$w" surgeon 2026-11-04 3
  printf '{"findings": [{"severity": "low"}, {"severity": 2}, {"severity": 3}]}\n' > "$w/data/officers/surgeon/2026-11-04.json"
  assert_equals "" "$(nav_check "$w" lane:surgeon:high)" "no high finding: silent"
  printf '{"findings": [{"severity": "high"}, {"severity": 5}, {"severity": "low"}]}\n' > "$w/data/officers/surgeon/2026-11-04.json"
  out=$(nav_check "$w" lane:surgeon:high)
  assert_equals "office navigator: surgeon digest 2026-11-04: 2 high-severity finding(s) in $w/data/officers/surgeon/2026-11-04.md" "$out" "high line"
  assert_equals "" "$(nav_check "$w" lane:surgeon:high)" "no new high finding: silent"
  printf '{"findings": [{"severity": "critical"}, {"severity": 4}, {"severity": "high"}]}\n' > "$w/data/officers/surgeon/2026-11-04.json"
  assert_contains "$(nav_check "$w" lane:surgeon:high)" "3 high-severity finding(s)" "a larger count reports again"
  printf 'not json\n' > "$w/data/officers/surgeon/2026-11-04.json"
  assert_equals "" "$(nav_check "$w" lane:surgeon:high)" "an unparseable json: silent"
  pass 'the high lane counts only high or critical findings and reports a new count once'
}

test_sources_changes_nothing_in_the_parent() {
  local w before after
  w=$(source_world parentro)
  put_digest "$w" progress 2026-11-04 4
  before=$(find "$w" -path "$w/navigator" -prune -o -type f -exec cksum {} + | sort)
  nav_check "$w" lane:progress >/dev/null
  nav_check "$w" tick >/dev/null
  after=$(find "$w" -path "$w/navigator" -prune -o -type f -exec cksum {} + | sort)
  assert_equals "$before" "$after" "parent files after the checks"
  pass 'source checks read the parent and write only in the office home'
}

# put_starts <world> <generated-epoch> <rank>:<home>:<shape>...: a progress digest whose start requests are
# addressed to <home> (navigator, quartermaster or main); shape bad names another program.
put_starts() {
  local w=$1 at=$2
  shift 2
  put_digest "$w" progress 2026-11-05 "$#"
  python3 -I - "$w" "$at" "$ROOT" "$@" > "$w/data/officers/progress/2026-11-05.json" <<'PY'
import datetime, json, sys
w, at, root, specs = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4:]
rows = []
for spec in specs:
    rank, home, shape = spec.split(":")
    rid = "progress-2026-11-05-%016x" % int(rank)
    program = "/tmp/evil.sh" if shape == "bad" else root + "/bin/fm-inbox.sh"
    rows.append({"id": "item-" + rank, "rank": int(rank), "execute": {
        "action": "start", "request_id": rid, "env": {"FM_HOME": w if home == "main" else w + "/" + home},
        "argv": [program, "note", "--request-id", rid, "--json", "--", "Start item " + rank + " for " + home]}})
print(json.dumps({"source": "progress-officer", "generated_at": datetime.datetime.fromtimestamp(
    at, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "start_requests": rows[::-1]}))
PY
}

notes() {  # <home>: the bodies of its pending inbox notes, one per line, sorted
  cat "$1"/state/inbox/*.note 2>/dev/null | grep -o 'Start item [0-9]* for [a-z]*' | sort
}

test_lane_check_delivers_a_surgeon_digests_start_requests() {
  local w out rid=surgeon-2026-11-05-00000000000000a1
  w=$(source_world surgeonstarts)
  put_digest "$w" surgeon 2026-11-05 1
  python3 -I - "$w" "$SRC_NOW" "$ROOT" "$rid" > "$w/data/officers/surgeon/2026-11-05.json" <<'PY'
import datetime, json, sys
w, at, root, rid = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
row = {"kind": "surgeon-finding", "rank": 1, "execute": {"action": "start", "request_id": rid, "env": {"FM_HOME": w + "/navigator"},
       "argv": [root + "/bin/fm-inbox.sh", "note", "--request-id", rid, "--json", "--", "Start item 1 for navigator"]}}
print(json.dumps({"source": "surgeon-officer", "generated_at": datetime.datetime.fromtimestamp(
    at - 3600, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "start_requests": [row],
    "findings": [{"severity": "high"}]}))
PY
  out=$(nav_check "$w" lane:surgeon:high)
  assert_contains "$out" "1 start request(s) delivered to this office's inbox" "the high lane delivers the surgeon's start request"
  assert_equals "Start item 1 for navigator" "$(notes "$w/navigator")" "into the office's own inbox"
  pass "a lane check delivers a surgeon digest's start requests like a progress digest's"
}

test_lane_check_delivers_a_friction_digests_start_requests() {
  local w out rid=friction-2026-11-05-00000000000000f1
  w=$(source_world frictionstarts)
  mkdir -p "$w/data/officers/friction"
  sed -i.bak 's/lane:surgeon:high;/lane:surgeon:high,lane:friction;/' "$w/data/offices.md" && rm -f "$w/data/offices.md.bak"
  printf -- '- friction - z (role: triage; cadence: daily 06:00; added 2026-10-24)\n' >> "$w/data/officers.md"
  put_digest "$w" friction 2026-11-05 1
  python3 -I - "$w" "$SRC_NOW" "$ROOT" "$rid" > "$w/data/officers/friction/2026-11-05.json" <<'PY'
import datetime, json, sys
w, at, root, rid = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
row = {"id": "missing-tool-tool-jq", "kind": "friction-finding", "rank": 1, "execute": {"action": "start", "request_id": rid,
       "env": {"FM_HOME": w + "/navigator"},
       "argv": [root + "/bin/fm-inbox.sh", "note", "--request-id", rid, "--json", "--", "Start item 1 for navigator"]}}
print(json.dumps({"source": "friction-officer", "generated_at": datetime.datetime.fromtimestamp(
    at - 3600, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "start_requests": [row], "findings": []}))
PY
  out=$(nav_check "$w" lane:friction)
  assert_contains "$out" "1 start request(s) delivered to this office's inbox" "the lane delivers the friction officer's start request"
  assert_equals "Start item 1 for navigator" "$(notes "$w/navigator")" "into the office's own inbox"
  pass "a lane check delivers a friction digest's start requests like a progress digest's"
}

test_lane_check_delivers_a_page_check_digests_start_requests() {
  local w out rid=page-check-2026-11-05-00000000000000f1
  w=$(source_world page-checkstarts)
  mkdir -p "$w/data/officers/page-check"
  sed -i.bak 's/lane:surgeon:high;/lane:surgeon:high,lane:page-check;/' "$w/data/offices.md" && rm -f "$w/data/offices.md.bak"
  printf -- '- page-check - z (role: pagecheck; cadence: every 2h; app: https://app.test; added 2026-10-24)\n' >> "$w/data/officers.md"
  put_digest "$w" page-check 2026-11-05 1
  python3 -I - "$w" "$SRC_NOW" "$ROOT" "$rid" > "$w/data/officers/page-check/2026-11-05.json" <<'PY'
import datetime, json, sys
w, at, root, rid = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
row = {"id": "page-old:Velocity audit:velocity-audit", "kind": "page-check-finding", "rank": 1, "execute": {"action": "start", "request_id": rid,
       "env": {"FM_HOME": w + "/navigator"},
       "argv": [root + "/bin/fm-inbox.sh", "note", "--request-id", rid, "--json", "--", "Start item 1 for navigator"]}}
print(json.dumps({"source": "page-check-officer", "generated_at": datetime.datetime.fromtimestamp(
    at - 3600, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "start_requests": [row], "findings": []}))
PY
  out=$(nav_check "$w" lane:page-check)
  assert_contains "$out" "1 start request(s) delivered to this office's inbox" "the lane delivers the page-check officer's start request"
  assert_equals "Start item 1 for navigator" "$(notes "$w/navigator")" "into the office's own inbox"
  pass "a lane check delivers a page-check digest's start requests like a progress digest's"
}

test_lane_check_delivers_its_own_start_requests_once() {
  local w out
  w=$(source_world starts)
  put_starts "$w" $((SRC_NOW - 3600)) 1:navigator:ok 2:main:ok 3:navigator:ok 4:quartermaster:ok
  out=$(nav_check "$w" lane:progress)
  assert_equals "office navigator: progress digest 2026-11-05: 4 finding(s) in $w/data/officers/progress/2026-11-05.md; 2 start request(s) delivered to this office's inbox" "$out" "lane line names the delivery"
  assert_equals "$(printf 'Start item 1 for navigator\nStart item 3 for navigator')" "$(notes "$w/navigator")" "only this office's requests reach its inbox"
  assert_equals "" "$(notes "$w")" "main's request stays for main"
  assert_equals "" "$(notes "$w/quartermaster")" "another office's request is not delivered by this one"
  assert_equals "" "$(nav_check "$w" lane:progress)" "a repeat check delivers nothing again"
  rm "$w/navigator/data/office/lane-progress-starts.seen" "$w/navigator/data/office/lane-progress.seen"
  nav_check "$w" lane:progress >/dev/null
  assert_equals 2 "$(find "$w/navigator/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" "a lost seen record replays the same request ids, adding no note"
  pass 'a lane check delivers only the start requests addressed to its own home, once'
}

test_lane_check_delivers_in_rank_order_and_stops_at_a_bad_request() {
  local w out
  w=$(source_world startorder)
  put_starts "$w" $((SRC_NOW - 3600)) 1:navigator:ok 2:navigator:bad 3:navigator:ok
  out=$(nav_check "$w" lane:progress)
  assert_contains "$out" "start request 2 of 3 could not be delivered; the next check retries it" "the failure is reported"
  assert_equals "Start item 1 for navigator" "$(notes "$w/navigator")" "rank 1 went first and nothing after the bad request ran"
  assert_equals "" "$(nav_check "$w" lane:progress)" "the same failure is reported once"
  put_starts "$w" $((SRC_NOW - 3600)) 1:navigator:ok 2:navigator:ok 3:navigator:ok
  assert_contains "$(nav_check "$w" lane:progress)" "3 start request(s) delivered" "a corrected digest is retried"
  assert_equals "$(printf 'Start item 1 for navigator\nStart item 2 for navigator\nStart item 3 for navigator')" "$(notes "$w/navigator")" "the retry replays rank 1 and adds the rest"
  pass 'a lane check delivers in rank order and stops, reporting once, at a request it will not run'
}

test_lane_check_never_delivers_a_stale_digest() {
  local w out
  w=$(source_world startstale)
  put_starts "$w" $((SRC_NOW - 37 * 3600)) 1:navigator:ok
  out=$(nav_check "$w" lane:progress)
  assert_contains "$out" "digest older than 36 hours, 1 start request(s) for this office not delivered" "a stale digest is reported"
  assert_equals "" "$(notes "$w/navigator")" "nothing from a stale digest is delivered"
  assert_equals "" "$(nav_check "$w" lane:progress)" "the stale digest is reported once"
  pass 'a lane check never delivers start requests from a digest older than 36 hours'
}

test_healthy_registry_prints_nothing
test_absent_registry_means_no_offices
test_gaps
test_alchemist_and_librarian_are_accepted_offices
test_list_counts_gaps
test_ensure_changes_nothing
test_publish_reaches_only_the_named_office
test_record_copied_to_another_office_refuses
test_publish_follows_registry_changes
test_local_edits_refuse_until_republished
test_publish_errors_leave_no_authority
test_publish_refusals
test_remote_push_carries_the_record
test_status_working_lane
test_status_next_lane
test_status_done_window
test_status_done_shows_24_hours_from_first_sight
test_status_seen_file_loss_keeps_old_items_out
test_status_prunes_old_stamps
test_status_skips_unchanged_write
test_status_writes_only_its_file
test_status_outside_an_office_does_nothing
test_status_without_a_backlog_is_empty
test_status_projects_decisions
test_status_decisions_cap_and_absence
test_arm_status_registers_a_silent_check
test_disarm_status_retires_the_check
test_arm_status_refuses_outside_an_office
test_upstream_wakes_once_per_new_head
test_upstream_is_daily_and_silent_when_nothing_new
test_ratchet_names_the_next_file_once_a_day
test_upstream_failure_reports_only_when_persistent
test_upstream_unresolved_fork_ref_reports_when_persistent
test_upstream_gap_in_attempts_starts_a_new_streak
test_upstream_without_config_is_silent
test_register_sources_installs_trusted_shims
test_register_sources_keeps_the_status_check
test_shim_runs_through_the_watcher_trust_path
test_tick_prints_once_per_slot_and_only_when_work_could_start
test_tick_is_silent_when_places_are_full
test_tick_leaves_landing_tasks_out_of_wip
test_landing_needs_a_handoff_to_another_merger
test_tick_counts_unread_lane_digests
test_lane_check_reports_each_new_digest_once
test_lane_check_reads_a_spaced_sources_list
test_lane_check_is_silent_when_it_cannot_read
test_high_lane_counts_only_high_severity
test_sources_changes_nothing_in_the_parent
test_lane_check_delivers_a_surgeon_digests_start_requests
test_lane_check_delivers_a_friction_digests_start_requests
test_lane_check_delivers_a_page_check_digests_start_requests
test_lane_check_delivers_its_own_start_requests_once
test_lane_check_delivers_in_rank_order_and_stops_at_a_bad_request
test_lane_check_never_delivers_a_stale_digest
