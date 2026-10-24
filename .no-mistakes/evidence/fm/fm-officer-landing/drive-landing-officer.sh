#!/usr/bin/env bash
# Drives the landing officer live in a disposable lab home.
set -u
WT=/home/lee/.no-mistakes/worktrees/4e1bb7649f99/01M5Q8SP4VYDP8SQXT6VHA5E8C
EV=/home/lee/.no-mistakes/evidence/01M5Q8SP4VYDP8SQXT6VHA5E8C
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
run() { echo "\$ $*"; env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; echo "[exit $?]"; }
reg() { printf -- '- landing - Reconciles Linear against landing evidence (role: landing; cadence: daily 06:30; facts: %s; team: PC; %smodel: none; added 2026-10-24)\n' "$1" "$2" > "$LAB/data/officers.md"; }
NOW=$(date -u +%s); GEN=$(date -u -d @$((NOW-3600)) +%Y-%m-%dT%H:%M:%SZ); D=$(date -u -d @$((NOW-86400)) +%F)
LANE="$LAB/data/officers/landing"

echo "=== S1: Slarti's verbatim FINAL v2 example is accepted; real Linear read-only (writes: none, done-window 5)"
cat > "$LAB/slarti-example.json" <<'J'
{"schema_version":2,"generated_at":"2026-10-24T18:00:00Z","staging_sha":"9d6dc13de01f10c1ac4692702ab0c479dba9a5d5","production_sha":"af76eb3e...","records":{"lstutzman/PropertyCompass2#4045":{"repo":"lstutzman/PropertyCompass2","pr":4045,"head_sha":"849500a8bccf0f9e06b98211be0ac15a3e73c8ce","merged_sha":"c438109b2c0cea83f498db4048cbc29ee9e46d8e","merged_at":"2026-10-24T16:22:19Z","on_staging":true,"staging_deployed":true,"on_main":false,"main_promoted_at":null,"in_production":false,"production_release":null,"linear_ids":["PC-3594"],"linear_state":{"PC-3594":"In Staging"},"landed_via":"pile-1024a"}},"items":{"PC-3594":["lstutzman/PropertyCompass2#4045"]}}
J
reg "$LAB/slarti-example.json" "writes: none; done-window: 5; "
run bin/fm-officer.sh list
run bin/fm-officer.sh register landing
run bin/fm-officer.sh run landing --date "$D"
cat "$LANE/$D.md"; tail -1 "$LANE/runs.log"
jq -c '.items[] | {item,linear_state,class,correction}' "$LANE/$D.json"

echo; echo "=== S2: write path with a stateful fake linear-axi (Linear boundary stub)"
FB="$LAB/fakebin"; mkdir -p "$FB" "$LAB/linear"
cat > "$FB/linear-axi" <<SH
#!/usr/bin/env bash
L="$LAB/linear"; printf '%s\n' "\$*" >> "\$L/calls"
case "\$1 \$2" in
  "issue list") echo '{"ok":true,"data":{"issues":[{"identifier":"PC-2"},{"identifier":"PC-7"},{"identifier":"PC-99"}]}}' ;;
  "issue view") s=\$(cat "\$L/\$3" 2>/dev/null || echo Todo); sub='[]'; [ "\$3" = PC-5 ] && sub='[{"identifier":"PC-6"}]'
     echo '{"ok":true,"data":{"issue":{"identifier":"'"\$3"'","state":"'"\$s"'"},"subIssues":'"\$sub"'}}' ;;
  "issue update") case " \$* " in *" --verify "*) echo "\$5" > "\$L/\$3" ;; esac; echo '{"ok":true,"data":{}}' ;;
  "issue comment") case " \$* " in *" --verify "*) { echo "--- \$3"; cat "\$5"; } >> "\$L/comments" ;; esac; echo '{"ok":true,"data":{}}' ;;
  *) echo '{"ok":true,"data":{}}' ;;
esac
SH
chmod +x "$FB/linear-axi"
echo Done > "$LAB/linear/PC-2"; echo Done > "$LAB/linear/PC-7"; echo "In Staging" > "$LAB/linear/PC-1"; echo "In Progress" > "$LAB/linear/PC-5"
python3 - "$LAB/facts.json" "$GEN" <<'PY'
import json,sys
def r(pr,ids,st,**kw):
    d={"repo":"lstutzman/PropertyCompass2","pr":pr,"head_sha":"h%d"%pr,"merged_sha":"m%d"%pr,"merged_at":"2026-10-20T10:00:00Z","on_staging":True,"staging_deployed":True,"on_main":True,"main_promoted_at":"2026-10-21T10:00:00Z","in_production":True,"production_release":"v1.71.0","linear_ids":ids,"linear_state":st,"landed_via":"lone"}
    d.update(kw); return d
recs=[r(101,["PC-1"],{"PC-1":"In Staging"}),
      r(102,["PC-2"],{"PC-2":"Done"},on_main=False,main_promoted_at=None,in_production=False,production_release=None),
      r(105,["PC-5"],{"PC-5":"In Progress"}),
      r(106,["PC-7"],{"PC-7":"Done"},in_production=False,production_release=None)]
doc={"schema_version":2,"generated_at":sys.argv[2],"staging_sha":"aaaa","production_sha":"bbbb",
     "records":{"%s#%d"%(x["repo"],x["pr"]):x for x in recs},
     "items":{i:["%s#%d"%(x["repo"],x["pr"])] for x in recs for i in x["linear_ids"]}}
json.dump(doc,open(sys.argv[1],"w"))
PY
reg "$LAB/facts.json" ""
export PATH="$FB:$PATH"
run bin/fm-officer.sh run landing --date "$D"
cat "$LANE/$D.md"
echo "--- linear-axi calls"; cat "$LAB/linear/calls"
echo "--- Linear state after"; for i in PC-1 PC-2 PC-5 PC-7; do echo "$i: $(cat $LAB/linear/$i)"; done
echo "--- evidence comments posted"; cat "$LAB/linear/comments"
echo "--- check line (watcher body)"; run bin/fm-officer.sh check landing

echo; echo "=== S3: re-run same date is idempotent (no second comment or write)"
: > "$LAB/linear/calls"; before=$(wc -l < "$LAB/linear/comments")
run bin/fm-officer.sh run landing --date "$D"
cat "$LAB/linear/calls"; echo "comment lines before=$before after=$(wc -l < "$LAB/linear/comments")"

echo; echo "=== S4 adversarial: stale facts (generated 3 days ago) make no Linear write"
jq --arg g "$(date -u -d @$((NOW-259200)) +%Y-%m-%dT%H:%M:%SZ)" '.generated_at=$g' "$LAB/facts.json" > "$LAB/stale.json"
echo Done > "$LAB/linear/PC-2"; echo "In Staging" > "$LAB/linear/PC-1"; : > "$LAB/linear/calls"
reg "$LAB/stale.json" ""
run bin/fm-officer.sh run landing --date "$D"
grep -E 'stale|writes' "$LANE/$D.md"; echo "--- calls:"; cat "$LAB/linear/calls"

echo; echo "=== S5 adversarial: schema v1 / extra top-level key refused"
jq '.schema_version=1' "$LAB/facts.json" > "$LAB/v1.json"; reg "$LAB/v1.json" ""
run bin/fm-officer.sh run landing --date "$D"; tail -1 "$LANE/runs.log"
jq '. + {prs: []}' "$LAB/facts.json" > "$LAB/extra.json"; reg "$LAB/extra.json" ""
run bin/fm-officer.sh run landing --date "$D"; tail -1 "$LANE/runs.log"

echo; echo "=== S6 adversarial: registry reopen-state In Staging and bad writes refused"
reg "$LAB/facts.json" "reopen-state: In Staging; "; run bin/fm-officer.sh run landing --date "$D"; run bin/fm-officer.sh ensure
reg "$LAB/facts.json" "writes: all; "; run bin/fm-officer.sh run landing --date "$D"

echo; echo "=== S7: real host:path read of the not-yet-shipped facts on slartibartfast fails cleanly"
reg "slartibartfast:/home/lee/services/landing-truth/latest.json" "writes: none; done-window: 0; "
run bin/fm-officer.sh run landing --date "$D"; tail -1 "$LANE/runs.log"
