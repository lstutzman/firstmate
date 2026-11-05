#!/usr/bin/env bash
# Live drive: a disposable main home plus Navigator and Quartermaster office homes.
# Real bin/fm-officer.sh run progress, then each office's real registered lane:progress check.
# External boundaries only (Linear, GitHub, Top of Mind HTTPS fetch) are fixtures, borrowed from the test suite.
set -u
ROOT=$1
cd "$ROOT"
# Reuse the suite's fixture builders without running its tests.
eval "$(sed -n '/^make_world()/,/^}/p;/^stub_python()/,/^}/p;/^run_progress()/,/^}/p' tests/fm-officer-progress.test.sh)"
. tests/officer-helpers.sh
OFFICER="$ROOT/bin/fm-officer.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-progress.XXXXXX")
DATE=2026-11-05; NOW=$(date -u +%s); export TZ=UTC
make_world fleet
nav="$WORLD/navigator"; qm="$WORLD/quartermaster"
for o in navigator quartermaster; do
  h="$WORLD/$o"; officer_home "$h"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$h/data/backlog.md"
  printf '%s\n' "$o" > "$h/.fm-office"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$WORLD_HOME" > "$h/.fm-secondmate-parent"
done
printf -- '- navigator - nav (home: %s; scope: office; projects: PropertyCompass2; added 2026-11-04)\n- quartermaster - qm (home: %s; scope: office; projects: firstmate,fleet-app,skills; added 2026-11-04)\n' "$nav" "$qm" > "$WORLD_HOME/data/secondmates.md"
printf -- '- navigator - nav (role: navigator; dispatch: PropertyCompass2; sources: tick,lane:progress; added 2026-11-04)\n- quartermaster - qm (role: quartermaster; dispatch: firstmate,fleet-app,skills; sources: tick,lane:progress; added 2026-11-04)\n' > "$WORLD_HOME/data/offices.md"
for h in "$nav" "$qm"; do FM_HOME="$h" bash "$ROOT/bin/fm-office.sh" register-sources || echo "register-sources FAILED in $h"; done
sed -i 's/model: none;/start-home: navigator,quartermaster; model: none;/' "$WORLD_HOME/data/officers.md"
echo "== officers.md"; cat "$WORLD_HOME/data/officers.md"
echo "== offices.md"; cat "$WORLD_HOME/data/offices.md"
cat > "$WORLD_HOME/data/backlog.md" <<'MD'
## In flight

- [ ] flying - Repair the cache (kind: ship) (repo: firstmate)

## Queued

- [ ] pc-crash - Fix a PropertyCompass crash (kind: bug) (repo: PropertyCompass2)
- [ ] pc-refactor - Refactor the deal importer (kind: code-review) (repo: PropertyCompass2)
- [ ] fm-crash - Fix a firstmate crash (kind: bug) (repo: firstmate)
- [ ] fa-cve - Patch the CVE in fleet-app (kind: security) (repo: fleet-app)
- [ ] pricing - Change the subscription pricing (kind: feature) (repo: PropertyCompass2)
- [ ] misc - Fix a crash in an unregistered repo (kind: bug) (repo: Nuggets)

## Done
MD
cat > "$WORLD/top-of-mind.json" <<'JSON'
{"rows":[
 {"id":"release","words":"same release as PR 4593","status":"not-started","work":[],"links":[]},
 {"id":"stamp","words":"Last updated: November 2026","status":"not-started","work":[],"links":[]},
 {"id":"shell","words":"sudo lvextend -r -L +300g ubuntu-vg/ubuntu-lv","status":"not-started","work":[],"links":[]},
 {"id":"dup","words":"Fix a firstmate crash.","status":"not-started","work":[],"links":[]},
 {"id":"cache","words":"Repair the cache","status":"not-started","work":[],"links":[]},
 {"id":"price-ask","words":"Raise the subscription pricing to 20 pounds","status":"not-started","work":[],"links":[]},
 {"id":"lee-ask","words":"Add CSV export to the fleet app","status":"not-started","work":[],"links":[]}
]}
JSON
echo "== progress officer run"
run_progress; echo "exit=$?"
lane="$WORLD_HOME/data/officers/progress"
echo "== start_requests (id, class, addressed FM_HOME)"
jq -r '.start_requests[] | "\(.rank) \(.id) \(.authorising_class) -> \(.execute.env.FM_HOME|sub(".*/";""))"' "$lane/$DATE.json"
echo "== excluded (id: reason)"; jq -r '.excluded[] | "\(.id): \(.reason)"' "$lane/$DATE.json"
echo "== asks_for_lee"; jq -r '.asks_for_lee[] | "\(.id): \(.reason)"' "$lane/$DATE.json"
echo "== main shell handoff FM_HOME targets"; grep '^FM_HOME=' "$lane/$DATE.start-requests.sh" | awk '{print $1}' | sed 's#.*/##' | sort | uniq -c
for o in navigator quartermaster; do
  h="$WORLD/$o"
  echo "== $o registered lane:progress watcher check (state/office-lane-progress.check.sh)"
  ls "$h/state" | grep office- 
  (cd "$h" && FM_HOME="$h" bash "$h/state/office-lane-progress.check.sh"); echo "exit=$?"
  echo "-- $o second check (must be silent)"
  (cd "$h" && FM_HOME="$h" bash "$h/state/office-lane-progress.check.sh"); echo "exit=$?"
  echo "-- $o inbox"
  FM_HOME="$h" bash "$ROOT/bin/fm-inbox.sh" receipts --all-pending | jq -r '.pending[] | .body | sub("(?s)^.*quotation from Lee:\n";"") | fromjson | "  note: \(.id) - \(.title)"' | sort
done
echo "== main runs its own handoff"
FM_HOME="$WORLD_HOME" bash "$lane/$DATE.start-requests.sh" >/dev/null; echo "exit=$?"
FM_HOME="$WORLD_HOME" bash "$ROOT/bin/fm-inbox.sh" receipts --all-pending | jq -r '.pending[] | .body | sub("(?s)^.*quotation from Lee:\n";"") | fromjson | "  note: \(.id) - \(.title)"' | sort
echo "== raw receipt sample (navigator)"; FM_HOME="$nav" bash "$ROOT/bin/fm-inbox.sh" receipts --all-pending | head -c 600; echo
echo "== digest markdown"; cat "$lane/$DATE.md"
rm -rf "$TMP_ROOT"
