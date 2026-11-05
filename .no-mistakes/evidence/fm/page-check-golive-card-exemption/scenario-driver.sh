#!/usr/bin/env bash
# Drives the real bin/fm-officer.sh page-check run against fixture fleet-app
# pages (fake curl) and a fake forge (gh-axi): PR 9 merged, PR 10 closed unmerged.
set -u
WT=${1:?worktree}
. "$WT/tests/officer-helpers.sh"
OFFICER="$WT/bin/fm-officer.sh"
T=$(mktemp -d); export TZ=UTC
home="$T/home"; dir="$T/pages"; officer_home "$home"; home=$(cd "$home" && pwd -P); mkdir -p "$dir"
P9=https://github.com/ex/repo/pull/9; P10=https://github.com/ex/repo/pull/10
jq -n --arg p9 $P9 --arg p10 $P10 '{at:"2026-10-31T14:00:00Z",value:{updated:"2026-10-31T14:00:00Z",cards:[
 {id:"mem-infra-v4-install",question:("Go for memory backend v4? " + $p9)},
 {id:"skills-118-token-scope-probe-golive",question:("Go for the token-scope probe? " + $p9)},
 {id:"run-steps",question:("Run these on deepthought after " + $p9 + "?")},
 {id:"cron-card",title:"Activate the nightly cron",question:("Ready? " + $p9)},
 {id:"enable-flag",question:("Enable the flag from " + $p9 + " on staging?")},
 {id:"pc-504",question:("Approve the pc-504 fix " + $p9 + "?")},
 {id:"approve-mentions-run",question:("Approve " + $p9 + "? Run the tests after it installs")},
 {id:"merge-then-install",question:("Merge " + $p9 + " then install it?")},
 {id:"pc-reinstall",question:("Approve " + $p9 + "?")},
 {id:"x-installer",question:("Approve " + $p9 + "?")},
 {id:"closed-golive",question:("Go live with " + $p10 + "?")}
] | map(. + {band:"now",advice:"a",replies:["a"],asked:"2026-10-31T12:00:00Z",state:"asked"})}}' > "$dir/_api_captains-log"
printf -- '- page-check - Checks pages (role: pagecheck; cadence: every 2h; app: https://app.test; model: none; added 2026-10-31)\n' > "$home/data/officers.md"
printf '# Shared\n' > "$home/data/captain-shared.md"
fb=$(fm_fakebin "$T")
cat > "$fb/curl" <<SH
#!/usr/bin/env bash
url=\${@: -1}; f="$dir/\$(printf '%s' "\${url#https://app.test}" | tr '/?=' '___')"
if [ -f "\$f" ]; then cat "\$f"; printf '\n200'; else printf '\n404'; fi
SH
cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$2 $3" in
 "GET /repos/ex/repo/pulls/9") echo 'PRSTATE {"state":"closed","merged":true}';;
 "GET /repos/ex/repo/pulls/10") echo 'PRSTATE {"state":"closed","merged":false}';;
 *) exit 1;; esac
SH
chmod +x "$fb/curl" "$fb/gh-axi"
PATH="$fb:$PATH" FM_OFFICER_NOW=1793457000 FM_HOME="$home" "$OFFICER" run page-check --date 2026-10-31T14 >/dev/null || { echo RUN-FAILED; exit 1; }
jq -r '.findings[] | select(.kind=="stale-card") | .id' "$home/data/officers/page-check/2026-10-31T14.json" | sort
rm -rf "$T"
