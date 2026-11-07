#!/usr/bin/env bash
# Manual drive: real bin/fm-officer.sh run library in a disposable home, fake linear-axi on PATH.
set -u
ROOT=$1; W=$2
. "$ROOT/tests/officer-helpers.sh"
# reuse the test's fixture builders (fake linear-axi, audit run writer)
eval "$(sed -n '/^fake_linear()/,/^}/p;/^finding()/,/^}/p;/^write_run()/,/^}/p' "$ROOT/tests/fm-officer-library.test.sh")"
mkdir -p "$W/bin" "$W/linear"; fake_linear "$W/bin"; export PATH="$W/bin:$PATH" FAKE_LINEAR_DIR="$W/linear"
printf '%s\n' Bug Chore scheduled-review documentation triage > "$W/linear/labels.txt"
H=$W/home; officer_home "$H"; write_run "$W/runs/2026-10-31" ok 5
printf -- '- library - Judges the weekly librarian audit (role: library; cadence: daily 11:30; audit: %s; writes: linear; max-creates: 10; jev: /nonexistent/jev.py; model: none; added 2026-11-05)\n' "$W/runs" > "$H/data/officers.md"
echo "== run 1 (2026-11-01), registry max-creates: 10 =="
FM_OFFICER_NOW=1793871000 FM_HOME="$H" "$ROOT/bin/fm-officer.sh" run library --date 2026-11-01; echo "rc=$?"
echo "== creates sent to Linear (verify) =="; grep '^issue create' "$W/linear/log" | grep -- '--verify' | sed 's/--body-file [^ ]*/--body-file <f>/'
echo "== bodies =="; cat "$W/linear/bodies"
echo "== digest md =="; cat "$H/data/officers/library/2026-11-01.md"
echo "== start_requests / asks_for_lee =="; jq -c '{start_requests: [.start_requests[] | {title, issue, score, home: .execute.env.FM_HOME}], asks: [.asks_for_lee[].key]}' "$H/data/officers/library/2026-11-01.json"
echo "== next day run (same audit run) =="
FM_OFFICER_NOW=$((1793871000+86400)) FM_HOME="$H" "$ROOT/bin/fm-officer.sh" run library --date 2026-11-02; echo "rc=$?"
echo "total verify creates now: $(grep '^issue create' "$W/linear/log" | grep -c -- '--verify')"
echo "== adversarial registry lines =="
for bad in "max-creates: 0" "team: ENG" "writes: maybe"; do
  printf -- '- library - J (role: library; cadence: daily 11:30; audit: %s; writes: linear; %s; model: none; added 2026-11-05)\n' "$W/runs" "$bad" > "$H/data/officers.md"
  echo "-- $bad"; FM_OFFICER_NOW=1793871000 FM_HOME="$H" "$ROOT/bin/fm-officer.sh" run library --date 2026-11-03 2>&1 | head -3; echo "rc=${PIPESTATUS[0]}"
done
