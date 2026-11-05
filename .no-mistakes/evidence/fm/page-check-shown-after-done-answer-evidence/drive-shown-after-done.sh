#!/usr/bin/env bash
# Drives the real page-check officer (bin/fm-officer.sh run page-check) on a disposable
# lab home against fixture fleet-app pages served by a fake curl. Usage: <bin-dir> <label>
set -u
BIN=$1; LABEL=$2
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-pc-lab.XXXXXX"); home="$T/home"; pages="$T/pages"; fb="$T/fakebin"
mkdir -p "$home/data" "$home/state" "$pages" "$fb"; chmod 700 "$home/state"
export TZ=UTC
NOW=1793457000; E=1793437200   # now 2026-10-31T14:30Z; resolve at 09:01Z
id() { printf 'task-r-%s-%s' "$1" "$(printf 'task-r\0%s' "$1" | sha256sum | cut -c1-10)"; }
cards='[]'
add() { # key asked [answer]
  local c; c=$(jq -n --arg id "$(id "$1")" --arg a "$2" --arg q "Question $1?" '{id:$id,band:"now",question:$q,advice:"a",replies:["a"],asked:$a,state:"asked"}')
  [ -n "${3:-}" ] && c=$(jq --arg t "$3" '. + {answer:{text:$t,at:"2026-10-31T09:30:00Z"}}' <<<"$c")
  cards=$(jq --argjson c "$c" '. + [$c]' <<<"$cards")
}
for k in sweep holdrec pending ans holdans holdrel; do add $k 2026-10-31T10:00:00Z; done
add cardans 2026-10-31T10:00:00Z "yes"
add sweepbefore 2026-10-31T08:00:00Z
add ansbefore 2026-10-31T08:00:00Z
jq -n --argjson cards "$cards" '{at:"2026-10-31T14:00:00Z",value:{updated:"2026-10-31T14:00:00Z",cards:$cards}}' > "$pages/_api_captains-log"
{
for k in sweep holdrec pending ans holdans holdrel cardans sweepbefore ansbefore; do
  echo "needs-decision [at=$((E - 600))] [key=$k]: decide $k"
done
echo "resolved [key=sweep] [at=$((E + 60))]: decision-sweep"
echo "resolved [key=holdrec] [at=$((E + 60))]: captain hold holdrec: reconciled"
echo "resolved [key=pending] [at=$((E + 60))]: pending-reply"
echo "resolved [key=ans] [at=$((E + 60))]: answered: Lee chose a"
echo "resolved [key=holdans] [at=$((E + 60))]: captain hold holdans: answered"
echo "resolved [key=holdrel] [at=$((E + 60))]: captain hold holdrel: released"
echo "resolved [key=cardans] [at=$((E + 60))]: decision-sweep"
echo "resolved [key=sweepbefore] [at=$((E + 60))]: decision-sweep"
echo "resolved [key=ansbefore] [at=$((E + 60))]: answered: Lee chose b"
} > "$home/state/task-r.status"
printf -- '- page-check - Checks the fleet app pages (role: pagecheck; cadence: every 2h; app: https://app.test; model: none; added 2026-10-31)\n' > "$home/data/officers.md"
cat > "$fb/curl" <<EOF
#!/usr/bin/env bash
url=\${@: -1}
f="$pages/\$(printf '%s' "\${url#https://app.test}" | tr '/?=' '___')"
if [ -f "\$f" ]; then cat "\$f"; printf '\n200'; else printf '\n404'; fi
EOF
printf '#!/usr/bin/env bash\nexit 1\n' > "$fb/gh-axi"; chmod +x "$fb/curl" "$fb/gh-axi"
echo "=== $LABEL: fm-officer.sh run page-check ==="
PATH="$fb:$PATH" FM_OFFICER_NOW=$NOW FM_HOME="$home" "$BIN/fm-officer.sh" run page-check --date 2026-10-31T14; echo "exit=$?"
echo "--- Captain's Log card findings ---"
jq -r '.findings[] | select(.page=="Captain'"'"'s Log") | "\(.kind)\t\(.id)\t\(.detail // .why // "")"' "$home/data/officers/page-check/2026-10-31T14.json" | sed -E 's/task-r-([a-z]+)-[0-9a-f]{10}/<\1>/' | sort
/usr/bin/trash "$T"
