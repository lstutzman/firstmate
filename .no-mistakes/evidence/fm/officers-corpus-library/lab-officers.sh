#!/usr/bin/env bash
set -u
ROOT={run-worktree}
O=$ROOT/bin/fm-officer.sh
LAB=$(mktemp -d /tmp/fm-lab-officers.XXXXXX)
H=$LAB/home; mkdir -p $H/data $H/state; chmod 700 $H/state
step(){ printf '\n=== %s\n' "$*"; }
run(){ printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' $?; }
# ---- corpus fixtures (plain local paths, plus one unreachable real-ssh host)
C=$LAB/corpus; mkdir -p $C/transcript-archive $C/memory-harvest
J=$LAB/local-jev; mkdir -p $J/data/prep $J/results/weekly $J/results/judge
echo '{"outcome":"ok","counts":{"archived":3,"unchanged":9,"withheld":0,"errors":0,"sources_ok":4,"sources_not_collected":1,"hosts_offline":1}}' > $C/transcript-archive/last-result.json
line(){ echo "{\"finished\":\"2026-11-05T07:08:54+00:00\",\"errors\":[{\"error\":\"SECRET-SESSION-TEXT\"}],\"sources\":{\"a/codex\":\"$1\",\"macbook/claude-code\":\"not collected: host offline\"}}"; }
{ line ok; line "not collected: ssh exited 1"; line "not collected: ssh exited 1"; } > $C/transcript-archive/runs.jsonl
echo '{"outcome":"ok","counts":{"listed":0,"total":0,"written":0}}' > $C/memory-harvest/last-result.json
echo '{"finished":"2026-11-03T06:00:00+00:00","rows":12}' > $J/data/prep/ready.json
echo '{"run":"20261017","started":"2026-10-17T21:00:00+00:00","status":"promoted"}' > $J/results/weekly/history.jsonl
echo '{}' > $J/results/judge/eval-judge-20261017-r1.json
echo "- corpus - Checks the corpus (role: corpus; cadence: daily 08:15; archive: $C; hosts: localhost; prep: $J/data/prep/ready.json; local-jev: $J; model: none; added 2026-11-05)" > $H/data/officers.md
step "corpus: registry without archive is refused"
cp $H/data/officers.md $LAB/good.md
echo "- corpus - x (role: corpus; cadence: daily 08:15; model: none; added 2026-11-05)" > $H/data/officers.md
FM_HOME=$H run $O register corpus
cp $LAB/good.md $H/data/officers.md
step "corpus: register + run day 1"
FM_HOME=$H run $O register corpus
FM_HOME=$H FM_OFFICER_NOW=1793866500 run $O run corpus --date 2026-11-04
cat $H/data/officers/corpus/2026-11-04.md
step "corpus: watcher check output"
ls $H/state; [ -x $H/state/officer-corpus.check.sh ] && FM_HOME=$H FM_OFFICER_NOW=1793866500 bash $H/state/officer-corpus.check.sh; echo "[check exit $?]"
step "corpus: session text never in lane"
grep -rl SECRET-SESSION-TEXT $H/data/officers/corpus && echo LEAK || echo "no session text in lane"
step "corpus: day 2 same findings -> 0 new (reported once)"
FM_HOME=$H FM_OFFICER_NOW=1793952900 run $O run corpus --date 2026-11-05
step "corpus: day 3 prep file unreadable (gap) -> prep-stale kept, not re-reported on day 4"
mv $J/data/prep/ready.json $LAB/ready.bak
FM_HOME=$H FM_OFFICER_NOW=1794039300 run $O run corpus --date 2026-11-06
jq -c 'keys' $H/data/officers/corpus/reported.json
mv $LAB/ready.bak $J/data/prep/ready.json
FM_HOME=$H FM_OFFICER_NOW=1794125700 run $O run corpus --date 2026-11-07
step "corpus: fix prep then break again -> new again"
echo '{"finished":"2026-11-08T06:00:00+00:00","rows":12}' > $J/data/prep/ready.json
FM_HOME=$H FM_OFFICER_NOW=1794212100 run $O run corpus --date 2026-11-08
echo '{"finished":"2026-11-03T06:00:00+00:00","rows":12}' > $J/data/prep/ready.json
FM_HOME=$H FM_OFFICER_NOW=1794298500 run $O run corpus --date 2026-11-09 | grep -E 'DIGEST'
step "corpus: rerun same key byte-identical"
a=$(cksum $H/data/officers/corpus/2026-11-09.*); FM_HOME=$H FM_OFFICER_NOW=1794298999 $O run corpus --date 2026-11-09 >/dev/null; b=$(cksum $H/data/officers/corpus/2026-11-09.*); [ "$a" = "$b" ] && echo IDENTICAL || echo DIFFERENT
# ---- library
R=$LAB/runs; mkdir -p $R/2026-10-31 $R/2026-11-01.stale-x
f(){ printf '{"kind":"%s","severity":"low","title":"%s","path":"%s","evidence":"e","disposition":"%s"}' "$1" "$3" "$2" "$4"; }
echo '{"outcome":"ok","counts":{"findings":4,"decisions":2}}' > $R/2026-10-31/result.json
echo "[$(f readme README.md 'Count stale' 'Correct the README count.'),$(f cruft old.sh 'Old script' 'Propose deletion.'),$(f unneeded-code a.py 'Dup' 'Merge them.'),$(f misplaced docs/b.md 'Loose doc' 'Unresolved. Read both next run.')]" > $R/2026-10-31/findings.json
echo "- library - Judges the audit (role: library; cadence: daily 11:30; audit: $R; model: none; added 2026-11-05)" >> $H/data/officers.md
step "library: register + run"
FM_HOME=$H run $O register library
FM_HOME=$H FM_OFFICER_NOW=1793871000 run $O run library --date 2026-11-01
cat $H/data/officers/library/2026-11-01.md
step "library: watcher check"
FM_HOME=$H FM_OFFICER_NOW=1793871000 bash $H/state/officer-library.check.sh; echo "[check exit $?]"
step "library: next week hold item becomes safe -> counted as new"
mkdir -p $R/2026-11-07; cp $R/2026-10-31/result.json $R/2026-11-07/
echo "[$(f readme README.md 'Count stale' 'Correct the README count.'),$(f misplaced docs/b.md 'Loose doc' 'Move it to docs/guides and link it.')]" > $R/2026-11-07/findings.json
FM_HOME=$H FM_OFFICER_NOW=1794393000 run $O run library --date 2026-11-08
jq -c '[.items[]|{path,bucket,new}]' $H/data/officers/library/2026-11-08.json
step "library: audit folder unreadable -> ledger kept, no re-report"
cp $H/data/officers/library/reported.json $LAB/rep.before
chmod 000 $R; FM_HOME=$H FM_OFFICER_NOW=1794479400 run $O run library --date 2026-11-09; chmod 755 $R
cmp $LAB/rep.before $H/data/officers/library/reported.json && echo "ledger unchanged"
FM_HOME=$H FM_OFFICER_NOW=1794565800 run $O run library --date 2026-11-10
step "lane-only writes"
find $LAB -newer $LAB/good.md -type f | sed "s#$LAB#LAB#" | sort
rm -rf $LAB; echo "lab removed"
