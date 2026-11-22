#!/usr/bin/env bash
# Behavior tests for the improvement officer, driven through bin/fm-officer.sh
# run with fixtures only: a landing-truth facts file, the fleet ledger and a
# status log of a home, gate-usage records, a session-archive manifest and a
# fake gh-axi that answers from files and logs every call.
#
# Covers: per-stage times for each PR that reached production on the run date,
# every one of the 11 stages named in every record as measured or unmeasured
# with the missing source, cost per PR where a source exists, the fallback to
# GitHub merge and git ancestry when facts are absent or stale, the GitHub
# lookup cap, a byte-identical rerun, the weekly digest (median, worst five,
# per-stage medians against the week before, the stage that grew most), the
# daily run raising nothing, GET-only GitHub calls, and refusal of writes: linear.
set -u

# shellcheck source=tests/officer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/officer-helpers.sh"

OFFICER="$ROOT/bin/fm-officer.sh"
TMP_ROOT=$(fm_test_tmproot fm-officer-improvement)
REPO=lstutzman/PropertyCompass2
STAGES="work pr_ready review gate_queue gate_run pile_wait merge staging_deploy staging_checks release_cut production"

epoch() { date -u -d "$1" +%s; }

# build_world <dir> <spec.json> <visible-until-iso>: writes the fixtures for the PRs in the spec.
# A PR is in production in the facts when its promoted time is not after <visible-until>.
build_world() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import json, os, sys
root, spec_path, until = sys.argv[1:4]
spec = json.load(open(spec_path))
prs = spec["prs"]
fix = os.path.join(root, "fix"); os.makedirs(fix, exist_ok=True)
home = os.path.join(root, "home"); os.makedirs(os.path.join(home, "state"), exist_ok=True)
gate = open(os.path.join(root, "gate.jsonl"), "w")
def ts(iso):
    import datetime
    return int(datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp())
records, items = {}, {}
ledger = open(os.path.join(home, "state", "fleet-ledger.jsonl"), "w")
archive = {}
for p in prs:
    key = "%s#%d" % (p["repo"], p["n"])
    url = "https://github.com/%s/pull/%d" % (p["repo"], p["n"])
    head = "h%d" % p["n"]
    prod = p["promoted"] <= until
    records[key] = {"repo": p["repo"], "pr": p["n"], "head_sha": head, "merged_sha": "m%d" % p["n"], "merged_at": p["merged"],
                    "on_staging": True, "staging_deployed": True, "on_main": prod, "main_promoted_at": p["promoted"] if prod else None,
                    "in_production": prod, "production_release": "v1.80.0" if prod else None,
                    "linear_ids": [], "linear_state": {}, "landed_via": "lone"}
    if p.get("start"):
        if p.get("via") == "status":
            with open(os.path.join(home, "state", "s%d.status" % p["n"]), "w") as fh:
                fh.write("working [at=%d]: begin\n" % ts(p["start"]))
                fh.write("done [at=%d]: PR %s checks green\n" % (ts(p["ready"]), url))
        else:
            ledger.write(json.dumps({"v": 1, "ts": ts(p["start"]), "event": "task.dispatched", "task": "t%d" % p["n"], "kind": "ship"}) + "\n")
            ledger.write(json.dumps({"v": 1, "ts": ts(p["ready"]), "event": "task.pr_ready", "task": "t%d" % p["n"], "pr": url}) + "\n")
    if p.get("ready") and not p.get("start"):
        ledger.write(json.dumps({"v": 1, "ts": ts(p["ready"]), "event": "task.pr_ready", "task": "orphan%d" % p["n"], "pr": url}) + "\n")
    with open(os.path.join(fix, "pull-%d.txt" % p["n"]), "w") as fh:
        fh.write("PRJSON " + json.dumps({"number": p["n"], "created_at": p["created"], "merged_at": p["merged"], "head": head,
                                         "merge_sha": "m%d" % p["n"], "base": "staging", "draft": False}) + "\n")
    with open(os.path.join(fix, "timeline-%d.txt" % p["n"]), "w") as fh:
        if p.get("review"):
            fh.write("EVJSON " + json.dumps({"kind": p.get("review_kind", "reviewed"), "at": p["review"]}) + "\n")
    for run in p.get("gate", []):
        gate.write(json.dumps({"schema_version": 2, "run_id": "d-%d-%s" % (p["n"], run[0]), "mode": run[4] if len(run) > 4 else "gate", "sha": head,
                               "guest_started_at": run[0], "guest_ended_at": run[1], "guest_seconds": run[3], "run_seconds": run[2],
                               "run_started_at": run[0], "run_finished_at": run[1], "run_matched": True}) + "\n")
    for sess in p.get("sessions", []):
        archive.setdefault(sess["day"], []).append({"machine": "alpha", "harness": "claude-code", "name": sess["id"], "session_id": sess["id"],
                                                    "started": sess["day"] + "T10:00:00Z", "cost_usd": sess["usd"],
                                                    "tokens": {"input": sess["tok"], "output": 1}, "pr_urls": [url]})
gate.close(); ledger.close()
facts = {"schema_version": 2, "generated_at": spec.get("generated_at", until), "staging_sha": "aaaa", "production_sha": "bbbb",
         "records": records, "items": items}
json.dump(facts, open(os.path.join(root, "facts.json"), "w"))
for day, sessions in archive.items():
    d = os.path.join(root, "archive", "by-date", day); os.makedirs(d, exist_ok=True)
    json.dump({"date": day, "sessions": sessions}, open(os.path.join(d, "manifest.json"), "w"))
os.makedirs(os.path.join(root, "archive"), exist_ok=True)
# the list endpoint answers merged PRs, newest first
with open(os.path.join(fix, "list-%s.txt" % spec.get("list_repo", "PropertyCompass2")), "w") as fh:
    for p in sorted(prs, key=lambda q: q["merged"], reverse=True):
        fh.write("PRJSON " + json.dumps({"number": p["n"], "created_at": p["created"], "merged_at": p["merged"], "head": "h%d" % p["n"],
                                         "merge_sha": "m%d" % p["n"], "base": "staging", "draft": False}) + "\n")
PY
}

fake_gh() {  # <fakebin> <fixdir> <log>: a gh-axi that answers GET from fixture files and logs every call.
  cat > "$1/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$3"
[ "\$1 \$2" = "api GET" ] || { echo "unexpected gh-axi call" >&2; exit 2; }
path=\$3
case "\$path" in
  /repos/*/pulls\?*) cat "$2/list-\$(basename "\${path%%/pulls*}").txt" 2>/dev/null ;;
  /repos/*/pulls/*) f="$2/pull-\${path##*/}.txt"; [ -f "\$f" ] && cat "\$f" || exit 1 ;;
  /repos/*/issues/*/timeline*) n=\${path#*/issues/}; n=\${n%%/*}; cat "$2/timeline-\$n.txt" 2>/dev/null ;;
  /repos/*/compare/*) echo "CMP \"ahead\"" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$1/gh-axi"
}

# make_world <name> <spec.json> <visible-until> [extra registry fields]: sets WORLD, WORLD_HOME, FAKEBIN, GH_LOG.
make_world() {
  local name=$1 spec=$2 until=$3 extra=${4-}
  WORLD="$TMP_ROOT/$name"
  WORLD_HOME="$WORLD/home"
  mkdir -p "$WORLD"
  build_world "$WORLD" "$spec" "$until"
  officer_home "$WORLD_HOME"
  FAKEBIN=$(fm_fakebin "$WORLD")
  GH_LOG="$WORLD/gh.calls"
  fake_gh "$FAKEBIN" "$WORLD/fix" "$GH_LOG"
  printf -- '- improvement - Measures per-PR time and cost from start to production (role: improvement; cadence: daily 07:30; repos: %s; facts: %s; gate: %s; archive: %s; model: none; writes: none;%s added 2026-11-22)\n' \
    "$REPO" "$WORLD/facts.json" "$WORLD/gate.jsonl" "$WORLD/archive" "${extra:+ $extra;}" > "$WORLD_HOME/data/officers.md"
}

run_improvement() {  # <date> <now-iso>
  PATH="$FAKEBIN:$PATH" FM_OFFICER_NOW="$(epoch "$2")" FM_HOME="$WORLD_HOME" "$OFFICER" run improvement --date "$1"
}

lane_json() { printf '%s/data/officers/improvement/%s.json' "$WORLD_HOME" "$1"; }
pr_field() {  # <json> <pr> <jq path on the record>
  jq -r --argjson n "$2" ".prs[] | select(.pr == \$n) | $3" "$1"
}

# One day's cohort: three PRs with every source, one with the facts but no task, no review and no gate record.
cat > "$TMP_ROOT/daily.json" <<JSON
{"prs": [
 {"n": 201, "repo": "$REPO", "start": "2026-11-16T08:00:00Z", "created": "2026-11-16T11:00:00Z", "ready": "2026-11-16T11:30:00Z",
  "review": "2026-11-16T11:45:00Z", "review_kind": "marker", "merged": "2026-11-16T12:00:00Z", "promoted": "2026-11-16T15:00:00Z",
  "gate": [["2026-11-16T11:40:00Z", "2026-11-16T11:50:00Z", 590, 600], ["2026-11-16T11:53:00Z", "2026-11-16T11:58:00Z", 290, 300]],
  "sessions": [{"day": "2026-11-16", "id": "s1", "usd": 1.25, "tok": 1000}, {"day": "2026-11-15", "id": "s2", "usd": 0.75, "tok": 500}]},
 {"n": 202, "repo": "$REPO", "start": "2026-11-16T09:00:00Z", "created": "2026-11-16T12:00:00Z", "ready": "2026-11-16T12:30:00Z",
  "merged": "2026-11-16T13:00:00Z", "promoted": "2026-11-16T15:00:00Z", "gate": [["2026-11-16T12:35:00Z", "2026-11-16T12:40:00Z", 300, 300, "test"]]},
 {"n": 203, "repo": "$REPO", "start": "2026-11-16T10:00:00Z", "ready": "2026-11-16T13:00:00Z", "via": "status", "created": "2026-11-16T12:50:00Z",
  "review": "2026-11-16T13:20:00Z", "merged": "2026-11-16T14:00:00Z", "promoted": "2026-11-16T15:00:00Z"},
 {"n": 204, "repo": "$REPO", "created": "2026-11-16T12:00:00Z", "merged": "2026-11-16T13:30:00Z", "promoted": "2026-11-18T15:00:00Z"}
]}
JSON
DAILY_DATE=2026-11-16
DAILY_NOW=2026-11-17T07:30:00Z
DAILY_UNTIL=2026-11-16T23:40:00Z

test_stage_times_and_costs() {
  local json stage
  make_world daily "$TMP_ROOT/daily.json" "$DAILY_UNTIL"
  run_improvement "$DAILY_DATE" "$DAILY_NOW" >/dev/null || fail "improvement run must succeed"
  json=$(lane_json "$DAILY_DATE")
  assert_equals 3 "$(jq '.prs | length' "$json")" "only PRs in production on the run date are measured (204 is not)"
  assert_equals 10800 "$(pr_field "$json" 201 .stages.work.seconds)" "work: task dispatch to PR open"
  assert_equals 1800 "$(pr_field "$json" 201 .stages.pr_ready.seconds)" "pr_ready: PR open to the ready record"
  assert_equals 900 "$(pr_field "$json" 201 .stages.review.seconds)" "review: ready to the review-evidence marker"
  assert_equals 880 "$(pr_field "$json" 201 .stages.gate_run.seconds)" "gate_run: the head sha's gate wall seconds, summed over its runs"
  assert_equals 120 "$(pr_field "$json" 201 .stages.merge.seconds)" "merge: last gate end to merge"
  assert_equals 10800 "$(pr_field "$json" 201 .stages.release_cut.seconds)" "release_cut: merge to promotion to main"
  assert_equals 25200 "$(pr_field "$json" 201 .end_to_end.seconds)" "end to end: work start to promotion to main"
  assert_equals 14400 "$(pr_field "$json" 201 .open_to_end.seconds)" "open to end: PR open to promotion to main"
  assert_equals 1800 "$(pr_field "$json" 201 .ready_to_merge.seconds)" "ready to merge is reported as a subtotal"
  for stage in $STAGES; do
    for pr in 201 202 203; do
      assert_equals object "$(jq -r --argjson n "$pr" ".prs[] | select(.pr == \$n) | .stages.$stage | type" "$json")" "PR $pr names stage $stage"
    done
  done
  for stage in gate_queue pile_wait staging_deploy staging_checks production; do
    assert_equals null "$(pr_field "$json" 201 ".stages.$stage.seconds")" "$stage is never guessed"
    assert_not_equals null "$(pr_field "$json" 201 ".stages.$stage.unmeasured")" "$stage names its missing source"
  done
  assert_contains "$(pr_field "$json" 201 .stages.gate_queue.unmeasured)" "gate request" "gate_queue names the gate request time"
  assert_contains "$(pr_field "$json" 201 .stages.production.unmeasured)" "production" "production names the deploy timestamp"
  assert_contains "$(pr_field "$json" 201 .stages.staging_deploy.unmeasured)" "staging" "staging_deploy names its source"
  assert_equals 200 "$(pr_field "$json" 201 "(.cost.model_usd.value * 100 | round)")" "cost (in cents) sums the archived sessions that name the PR, across days"
  assert_equals 2 "$(pr_field "$json" 201 .cost.model_usd.sessions)" "and counts them"
  assert_equals 1500 "$(pr_field "$json" 201 "(.cost.gate_minutes.value * 100 | round)")" "gate machine minutes (in hundredths) sum guest seconds of gate-mode runs (900 s)"
  assert_equals null "$(pr_field "$json" 201 .cost.lee_minutes.value)" "Lee minutes are unmeasured"
  assert_contains "$(pr_field "$json" 201 .cost.lee_minutes.unmeasured)" "Lee" "and say why"
  assert_equals 10800 "$(pr_field "$json" 202 .stages.work.seconds)" "a second task's work stage comes from the ledger"
  assert_equals null "$(pr_field "$json" 202 .stages.review.seconds)" "no review event: review is unmeasured"
  assert_contains "$(pr_field "$json" 202 .stages.review.unmeasured)" "review" "and names the missing event"
  assert_equals null "$(pr_field "$json" 202 .stages.gate_run.seconds)" "a non-gate run is not gate time"
  assert_contains "$(pr_field "$json" 202 .stages.gate_run.unmeasured)" "gate-usage" "gate_run names its source"
  assert_equals null "$(pr_field "$json" 202 .cost.model_usd.value)" "no archived session names the PR: cost is unmeasured, not zero"
  assert_equals 10200 "$(pr_field "$json" 203 .stages.work.seconds)" "a status log with a PR line supplies work start and ready (PR 203)"
  assert_equals 1200 "$(pr_field "$json" 203 .stages.review.seconds)" "a reviewed event is review evidence"
  pass "fm-officer improvement: per-stage times and costs come from named sources, never guessed"
}

test_daily_run_raises_nothing() {
  local digest
  make_world quiet "$TMP_ROOT/daily.json" "$DAILY_UNTIL"
  run_improvement "$DAILY_DATE" "$DAILY_NOW" >/dev/null || fail "improvement run must succeed"
  digest=$(cat "$WORLD_HOME/data/officers/improvement/digest")
  assert_equals "DIGEST $DAILY_DATE 0 data/officers/improvement/$DAILY_DATE.md" "$digest" "a daily run wakes nobody"
  assert_not_equals 0 "$(grep -c 'api GET' "$GH_LOG")" "GitHub was read"
  assert_no_grep 'POST\|PATCH\|PUT\|DELETE\|-X' "$GH_LOG" "GitHub is only ever read"
  assert_equals "" "$(find "$WORLD_HOME/data/officers/improvement" -maxdepth 1 -type f ! -name '2026-*' ! -name digest ! -name runs.log ! -name prs.json ! -name 'check-record*' ! -name '.*' -printf '%f ')" "the lane holds only the officer's own files"
  pass "fm-officer improvement: a daily run is read-only and raises nothing"
}

test_rerun_is_byte_identical() {
  local json first
  make_world rerun "$TMP_ROOT/daily.json" "$DAILY_UNTIL"
  run_improvement "$DAILY_DATE" "$DAILY_NOW" >/dev/null || fail "first run must succeed"
  json=$(lane_json "$DAILY_DATE")
  first=$(cat "$json" "$WORLD_HOME/data/officers/improvement/$DAILY_DATE.md" | cksum)
  run_improvement "$DAILY_DATE" "$DAILY_NOW" >/dev/null || fail "rerun must succeed"
  assert_equals "$first" "$(cat "$json" "$WORLD_HOME/data/officers/improvement/$DAILY_DATE.md" | cksum)" "a rerun of the same date rewrites the same bytes"
  pass "fm-officer improvement: rerunning a date is byte-identical"
}

test_absent_and_stale_facts_fall_back_to_github() {
  local json
  make_world nofacts "$TMP_ROOT/daily.json" "$DAILY_UNTIL"
  sed -i "s#facts: [^;]*; ##" "$WORLD_HOME/data/officers.md"
  run_improvement "$DAILY_DATE" "$DAILY_NOW" >/dev/null || fail "a run without facts must succeed"
  json=$(lane_json "$DAILY_DATE")
  assert_equals 4 "$(jq '.prs | length' "$json")" "without facts the PRs merged on the date are measured (production is unconfirmed)"
  assert_equals merged "$(pr_field "$json" 201 .cohort)" "the cohort basis is merge, not production"
  assert_equals null "$(pr_field "$json" 201 .stages.release_cut.seconds)" "no promotion time without facts"
  assert_contains "$(pr_field "$json" 201 .stages.release_cut.unmeasured)" "landing" "and the missing source is named"
  assert_equals true "$(pr_field "$json" 201 .on_main)" "git ancestry against main is read through the compare API"
  assert_equals 14400 "$(pr_field "$json" 201 .end_to_end.seconds)" "end to end then runs to the merge"
  assert_equals merged "$(pr_field "$json" 201 .end_event)" "and says so"
  assert_equals absent "$(jq -r .sources.facts.state "$json")" "the digest names the facts as absent"
  make_world stale "$TMP_ROOT/daily.json" "$DAILY_UNTIL"
  python3 -I - "$WORLD/facts.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["generated_at"] = "2026-11-10T00:00:00Z"; json.dump(d, open(sys.argv[1], "w"))
PY
  run_improvement "$DAILY_DATE" "$DAILY_NOW" >/dev/null || fail "a run with stale facts must succeed"
  json=$(lane_json "$DAILY_DATE")
  assert_equals stale "$(jq -r .sources.facts.state "$json")" "stale facts are named stale"
  assert_equals merged "$(pr_field "$json" 201 .cohort)" "and the run falls back to GitHub merge"
  pass "fm-officer improvement: absent or stale facts fall back to GitHub merge and name the gap"
}

test_lookup_cap_and_missing_sources_are_named() {
  local json
  make_world cap "$TMP_ROOT/daily.json" "$DAILY_UNTIL" "max-pr-lookups: 2"
  sed -i "s#gate: [^;]*; ##; s#archive: [^;]*; ##" "$WORLD_HOME/data/officers.md"
  run_improvement "$DAILY_DATE" "$DAILY_NOW" >/dev/null || fail "a capped run must succeed"
  json=$(lane_json "$DAILY_DATE")
  assert_equals 2 "$(grep -c 'pulls/\|timeline' "$GH_LOG")" "the per-PR lookup cap is honoured"
  assert_contains "$(pr_field "$json" 203 .stages.work.unmeasured)" "lookup cap" "a PR the cap leaves out names the cap"
  assert_contains "$(pr_field "$json" 201 .stages.gate_run.unmeasured)" "gate-usage" "no gate source: gate_run names the registry field"
  assert_contains "$(pr_field "$json" 201 .cost.model_usd.unmeasured)" "archive" "no archive source: cost names the registry field"
  pass "fm-officer improvement: the lookup cap and missing sources are named, never silent"
}

# The weekly world: one PR cohort the week before (review waits short), six the week of the run (review waits long).
make_weekly_spec() {
  python3 -I - "$1" "$REPO" <<'PY'
import json, sys, datetime
out, repo = sys.argv[1:3]
prs = []
def pr(n, day, review_wait, work_h):
    d = datetime.datetime.fromisoformat(day + "T00:00:00+00:00")
    t = lambda h, m=0: (d + datetime.timedelta(hours=h, minutes=m)).strftime("%Y-%m-%dT%H:%M:%SZ")
    start = t(0)
    created = t(work_h)
    ready = t(work_h, 10)
    review = (d + datetime.timedelta(hours=work_h, minutes=10, seconds=review_wait)).strftime("%Y-%m-%dT%H:%M:%SZ")
    merged = (d + datetime.timedelta(hours=work_h + 1, seconds=review_wait)).strftime("%Y-%m-%dT%H:%M:%SZ")
    promoted = (d + datetime.timedelta(hours=work_h + 2, seconds=review_wait)).strftime("%Y-%m-%dT%H:%M:%SZ")
    prs.append({"n": n, "repo": repo, "start": start, "created": created, "ready": ready, "review": review, "review_kind": "reviewed",
                "merged": merged, "promoted": promoted})
# the week before: cohort date 2026-11-12 (promoted on that day)
pr(191, "2026-11-12", 600, 2)
pr(192, "2026-11-12", 600, 2)
# this week: seen by the runs for 2026-11-17 and 2026-11-22
pr(211, "2026-11-16", 3600, 2)
pr(212, "2026-11-16", 7200, 2)
pr(213, "2026-11-16", 1800, 2)
pr(214, "2026-11-21", 10800, 2)
pr(215, "2026-11-21", 5400, 2)
pr(216, "2026-11-21", 900, 2)
json.dump({"prs": prs}, open(out, "w"))
PY
}

run_weekly_world() {  # <name>: three runs on one lane; sets WORLD_HOME for the last.
  make_weekly_spec "$TMP_ROOT/weekly.json"
  make_world "$1" "$TMP_ROOT/weekly.json" 2026-11-12T23:40:00Z
  run_improvement 2026-11-12 2026-11-13T07:30:00Z >/dev/null || fail "run 1 must succeed"
  build_world "$WORLD" "$TMP_ROOT/weekly.json" 2026-11-16T23:40:00Z
  run_improvement 2026-11-16 2026-11-17T07:30:00Z >/dev/null || fail "run 2 must succeed"
  build_world "$WORLD" "$TMP_ROOT/weekly.json" 2026-11-21T23:40:00Z
  run_improvement 2026-11-21 2026-11-22T07:30:00Z >/dev/null || fail "run 3 must succeed"
  build_world "$WORLD" "$TMP_ROOT/weekly.json" 2026-11-22T23:40:00Z
  run_improvement 2026-11-22 2026-11-23T07:30:00Z >/dev/null || fail "weekly run must succeed"
}

test_weekly_digest() {
  local json
  run_weekly_world weekly
  json=$(lane_json 2026-11-22)
  assert_equals null "$(jq '.weekly' "$(lane_json 2026-11-16)")" "a mid-week run carries no weekly section"
  assert_equals 6 "$(jq '.weekly.prs' "$json")" "the week counts the cohorts dated Monday to Sunday"
  assert_equals 18900 "$(jq '.weekly.median_end_to_end.seconds' "$json")" "median end to end this week (6 PRs)"
  assert_equals 15000 "$(jq '.weekly.prior_median_end_to_end.seconds' "$json")" "and the week before's"
  assert_equals 5 "$(jq '.weekly.worst_five | length' "$json")" "the worst five are listed"
  assert_equals "lstutzman/PropertyCompass2#214" "$(jq -r '.weekly.worst_five[0].key' "$json")" "the longest end to end comes first"
  assert_equals "lstutzman/PropertyCompass2#213" "$(jq -r '.weekly.worst_five[4].key' "$json")" "the fifth worst comes last; the shortest is left out"
  assert_equals 600 "$(jq '.weekly.stages.review.prior_median' "$json")" "the week before's review median"
  assert_equals 4500 "$(jq '.weekly.stages.review.median' "$json")" "this week's review median"
  assert_equals 3900 "$(jq '.weekly.stages.review.delta' "$json")" "and the change"
  assert_equals review "$(jq -r '.weekly.grew_most' "$json")" "the stage that grew most is named"
  assert_equals null "$(jq '.weekly.stages.gate_queue.median' "$json")" "an unmeasured stage has no median"
  assert_equals "DIGEST 2026-11-22 1 data/officers/improvement/2026-11-22.md" "$(cat "$WORLD_HOME/data/officers/improvement/digest")" "only the weekly run raises one digest"
  assert_contains "$(cat "$WORLD_HOME/data/officers/improvement/2026-11-22.md")" "Stage that grew most: review" "the markdown names it"
  assert_no_grep 'POST\|PATCH\|PUT\|DELETE\|-X' "$GH_LOG" "GitHub is only ever read"
  pass "fm-officer improvement: the weekly digest gives the median, the worst five and the stage that grew most"
}

test_first_run_seeds_only_the_window_and_facts_upgrade_a_merge() {
  local json
  python3 -I - "$TMP_ROOT/daily.json" "$TMP_ROOT/seed.json" "$REPO" <<'PYEOF'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["prs"].append({"n": 301, "repo": sys.argv[3], "created": "2026-09-30T10:00:00Z", "merged": "2026-10-01T10:00:00Z", "promoted": "2026-10-02T10:00:00Z"})
json.dump(spec, open(sys.argv[2], "w"))
PYEOF
  make_world seed "$TMP_ROOT/seed.json" "$DAILY_UNTIL"
  run_improvement "$DAILY_DATE" "$DAILY_NOW" >/dev/null || fail "first run must succeed"
  json=$(lane_json "$DAILY_DATE")
  assert_equals "" "$(pr_field "$json" 301 .key)" "a first run leaves out a PR merged before the window"
  assert_equals 3 "$(jq '.prs | length' "$json")" "and keeps the PRs inside it"
  make_world upgrade "$TMP_ROOT/daily.json" "$DAILY_UNTIL"
  cp "$WORLD_HOME/data/officers.md" "$WORLD/with-facts.md"
  sed -i "s#facts: [^;]*; ##" "$WORLD_HOME/data/officers.md"
  run_improvement "$DAILY_DATE" "$DAILY_NOW" >/dev/null || fail "run without facts must succeed"
  assert_equals merged "$(pr_field "$(lane_json "$DAILY_DATE")" 201 .cohort)" "first seen as a merge"
  cp "$WORLD/with-facts.md" "$WORLD_HOME/data/officers.md"
  run_improvement 2026-11-17 2026-11-18T07:30:00Z >/dev/null || fail "run with facts must succeed"
  assert_equals production "$(pr_field "$(lane_json 2026-11-17)" 201 .cohort)" "fresh facts upgrade a merged record to production"
  pass "fm-officer improvement: a first run is windowed and fresh facts upgrade a merge-only record"
}

test_refuses_linear_writes() {
  local out
  make_world writes "$TMP_ROOT/daily.json" "$DAILY_UNTIL"
  sed -i "s/writes: none/writes: linear/" "$WORLD_HOME/data/officers.md"
  out=$(run_improvement "$DAILY_DATE" "$DAILY_NOW" 2>&1) && fail "writes: linear must be refused"
  assert_contains "$out" "writes" "the refusal names the field"
  assert_absent "$GH_LOG" "nothing was read before the refusal"
  pass "fm-officer improvement: writes: linear is refused"
}

test_stage_times_and_costs
test_daily_run_raises_nothing
test_rerun_is_byte_identical
test_absent_and_stale_facts_fall_back_to_github
test_lookup_cap_and_missing_sources_are_named
test_weekly_digest
test_first_run_seeds_only_the_window_and_facts_upgrade_a_merge
test_refuses_linear_writes
