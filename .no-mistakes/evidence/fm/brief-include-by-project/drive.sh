#!/usr/bin/env bash
set -u
S=$1; WT=$2; EV=$3
NEW=$WT/bin/fm-brief.sh; OLD=$S/base/bin/fm-brief.sh
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
mk(){ mkdir -p "$S/$1/config" "$S/$1/data"; echo "$S/$1"; }
# realistic include: shared rules, a ~2.7KB PC block, more shared
PCBLOCK=$(for i in $(seq 1 30); do echo "- PC rule $i: run the PropertyCompass2 gate (scripts/pc-gate.sh) before push; quote Lee's word for payments/legal."; done)
{ echo '# Standing worker rules'; echo; echo '- Shared rule A: never print secrets.'; echo; echo '<!-- project: PropertyCompass2 -->'; echo "$PCBLOCK"; echo '<!-- /project -->'; echo; echo '- Shared rule B: report as done/working lines.'; } > $S/tagged.md
grep -v '^<!-- /\{0,1\}project' $S/tagged.md > $S/untagged.md
echo "== include sizes (bytes): tagged=$(wc -c <$S/tagged.md) untagged=$(wc -c <$S/untagged.md) pcblock=$(printf '%s\n' "$PCBLOCK"|wc -c)"
for mode in "--scout" "--mode no-mistakes"; do
  tag=$(echo $mode|tr -dc a-z)
  H1=$(mk old-$tag); cp $S/untagged.md $H1/config/brief-include.md
  H2=$(mk new-$tag); cp $S/tagged.md $H2/config/brief-include.md
  FM_HOME=$H1 $OLD t-pc PropertyCompass2 $mode >/dev/null || echo "OLD pc $mode FAILED"
  FM_HOME=$H2 $NEW t-pc PropertyCompass2 $mode >/dev/null || echo "NEW pc $mode FAILED"
  FM_HOME=$H1 $OLD t-fm firstmate $mode >/dev/null || echo "OLD fm $mode FAILED"
  FM_HOME=$H2 $NEW t-fm firstmate $mode >/dev/null || echo "NEW fm $mode FAILED"
  echo "== [$mode] PC brief: base-commit script+untagged vs new script+tagged (home path normalised)"
  if diff <(sed "s#$H1#HOME#g" $H1/data/t-pc/brief.md) <(sed "s#$H2#HOME#g" $H2/data/t-pc/brief.md); then echo "BYTE-IDENTICAL: yes ($(wc -c <$H2/data/t-pc/brief.md) bytes)"; else echo "BYTE-IDENTICAL: NO"; fi
  echo "== [$mode] firstmate brief: old=$(wc -c <$H1/data/t-fm/brief.md) new=$(wc -c <$H2/data/t-fm/brief.md) bytes; PC rule lines old=$(grep -c 'PC rule' $H1/data/t-fm/brief.md) new=$(grep -c 'PC rule' $H2/data/t-fm/brief.md); shared A/B present: $(grep -c 'Shared rule [AB]' $H2/data/t-fm/brief.md)"
  echo "== [$mode] diff old->new firstmate brief:"; diff <(sed "s#$H1#HOME#g" $H1/data/t-fm/brief.md) <(sed "s#$H2#HOME#g" $H2/data/t-fm/brief.md) | head -8; echo "   ..."
  cp $H2/data/t-fm/brief.md $EV/firstmate-brief-$tag.md; cp $H2/data/t-pc/brief.md $EV/pc-brief-$tag.md
done
echo "== untagged include, new script: identical to base script for firstmate too?"
H3=$(mk new-untag); cp $S/untagged.md $H3/config/brief-include.md
FM_HOME=$H3 $NEW t-fm firstmate --scout >/dev/null
diff <(sed "s#$S/old-scout#HOME#g" $S/old-scout/data/t-fm/brief.md) <(sed "s#$H3#HOME#g" $H3/data/t-fm/brief.md) >/dev/null && echo "untagged firstmate brief unchanged: yes" || echo "untagged firstmate brief unchanged: NO"
echo "== adversarial: secondmate composition, base ends inside open PC block, home adds own lines"
. $WT/bin/fm-config-inherit-lib.sh
printf '%s\n' 'Base rule.' '<!-- project: PropertyCompass2 -->' 'PC-only base rule.' > $S/base-open.md
printf '%s\n' 'Base rule.' '<!-- project: PropertyCompass2 -->' 'PC-only base rule.' 'QM own rule.' > $S/dest.md
H4=$(mk qm-open); fm_brief_include_compose $S/base-open.md $S/dest.md 0 - $H4/config/brief-include.md; echo "composed:"; sed 's/^/   | /' $H4/config/brief-include.md
FM_HOME=$H4 $NEW t-open firstmate --scout >/dev/null 2>$S/err; echo "exit=$? stderr: $(cat $S/err | sed "s#$S#S#g")"; [ -e $H4/data/t-open ] && echo "partial scaffold LEFT" || echo "no partial scaffold"
echo "== secondmate composition with closed base block + own lines"
printf '%s\n' 'Base rule.' '<!-- project: PropertyCompass2 -->' 'PC-only base rule.' '<!-- /project -->' > $S/base-closed.md
cp $S/base-closed.md $S/dest2.md; echo 'QM own rule.' >> $S/dest2.md
H5=$(mk qm-closed); fm_brief_include_compose $S/base-closed.md $S/dest2.md 0 - $H5/config/brief-include.md
FM_HOME=$H5 $NEW t-fm firstmate --scout >/dev/null && FM_HOME=$H5 $NEW t-pc PropertyCompass2 --scout >/dev/null
echo "firstmate brief: own=$(grep -c 'QM own rule' $H5/data/t-fm/brief.md) base=$(grep -c '^Base rule' $H5/data/t-fm/brief.md) pc=$(grep -c 'PC-only' $H5/data/t-fm/brief.md)"
echo "PC brief:        own=$(grep -c 'QM own rule' $H5/data/t-pc/brief.md) base=$(grep -c '^Base rule' $H5/data/t-pc/brief.md) pc=$(grep -c 'PC-only' $H5/data/t-pc/brief.md)"
echo "== multi-name tag and near-miss repo name"
printf '%s\n' 'S.' '<!-- project: PropertyCompass2, fleet-app -->' 'MULTI.' '<!-- /project -->' > $S/multi.md
H6=$(mk multi); cp $S/multi.md $H6/config/brief-include.md
for r in fleet-app PropertyCompass2 PropertyCompass firstmate; do FM_HOME=$H6 $NEW m-$r $r --scout >/dev/null; echo "  repo=$r MULTI-present=$(grep -c '^MULTI\.' $H6/data/m-$r/brief.md) tags-leaked=$(grep -c '<!-- /\{0,1\}project' $H6/data/m-$r/brief.md)"; done
