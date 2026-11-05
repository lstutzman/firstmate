# Live driver: the real bin/fm-officer.sh progress run, two start-home offices, REAL local-jev (FM_LOCAL_JEV unset -> ~/.claude/skills/local-jev/jev.py).
# Linear, GitHub and the Top of Mind fetch are fixture boundaries from the repo's test harness.
. "$HARNESS"
make_world live
: > "$WORLD_HOME/data/secondmates.md"; : > "$WORLD_HOME/data/offices.md"
for office in navigator:PropertyCompass2 quartermaster:firstmate,skills,fleet-app; do
  dir="$WORLD/${office%%:*}"; officer_home "$dir"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  printf '%s\n' "${office%%:*}" > "$dir/.fm-office"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$WORLD_HOME" > "$dir/.fm-secondmate-parent"
  printf -- '- %s - office (home: %s; scope: office; projects: %s; added 2026-11-04)\n' "${office%%:*}" "$dir" "${office#*:}" >> "$WORLD_HOME/data/secondmates.md"
  printf -- '- %s - Works the %s mandate (role: %s; dispatch: %s; sources: tick,lane:progress; added 2026-11-04)\n' "${office%%:*}" "${office%%:*}" "${office%%:*}" "${office#*:}" >> "$WORLD_HOME/data/offices.md"
  FM_HOME="$dir" "$ROOT/bin/fm-office.sh" register-sources >/dev/null || fail register
done
sed -i 's/model: none;/start-home: navigator,quartermaster; model: none;/' "$WORLD_HOME/data/officers.md"
cat > "$WORLD/top-of-mind.json" <<'JSON'
{"rows":[
 {"id":"calc","words":"The BRR calculator rounds the refinance fee twice; fix it","status":"not-started","work":[],"links":[]},
 {"id":"photos","words":"Listing photos load slowly on the deal page","status":"not-started","work":[],"links":[]},
 {"id":"officers","words":"Make the officers start work on their own without me kicking them","status":"not-started","work":[],"links":[]},
 {"id":"sessionlogs","words":"Check that every agent session log reaches the transcript archive","status":"not-started","work":[],"links":[]},
 {"id":"holiday","words":"Research holiday flights for March","status":"not-started","work":[],"links":[]},
 {"id":"tea","words":"Make the tea better","status":"not-started","work":[],"links":[]},
 {"id":"price","words":"Change the premium membership price to £12","status":"not-started","work":[],"links":[]},
 {"id":"constraint","words":"Pillow Partners is not ready yet, do not start on it","status":"not-started","work":[],"links":[]},
 {"id":"pclink","words":"Tidy this up","status":"not-started","work":[],"links":[{"url":"https://github.com/lstutzman/PropertyCompass2/issues/12"}]},
 {"id":"fmword","words":"The firstmate wake queue needs a tidy","status":"not-started","work":[],"links":[]}
]}
JSON
FM_LOCAL_JEV= PROGRESS_WORLD="$WORLD" PATH="$FAKEBIN:$PATH" FM_HOME="$WORLD_HOME" FM_OFFICER_NOW="$NOW" bash "$OFFICER" run progress --date "$DATE" >/dev/null || { echo RUN FAILED; exit 1; }
file="$WORLD_HOME/data/officers/progress/$DATE.json"
echo "== routing (real local-jev) =="
jq -r --arg w "$WORLD/" --arg h "$WORLD_HOME" '.start_requests[] | [.id, (.execute.env.FM_HOME | if . == $h then "main" else ltrimstr($w) end), (.unrouted // "-")] | @tsv' "$file"
echo "== excluded: $(jq '.excluded|length' "$file")  total requests: $(jq '.start_requests|length' "$file")"
echo "== digest unrouted lines =="; grep -i unrouted "$WORLD_HOME/data/officers/progress/$DATE.md"
echo "== handoff FM_HOME lines =="; grep -c 'FM_HOME=' "$WORLD_HOME/data/officers/progress/$DATE.start-requests.sh"
