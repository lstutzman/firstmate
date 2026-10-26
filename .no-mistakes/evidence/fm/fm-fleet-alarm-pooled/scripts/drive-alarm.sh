#!/usr/bin/env bash
# Drives the real bin/fm-fleet-alarm.py against a disposable lab home.
# Only the external quota CLI (cpa-usage-axi) is replaced with a fixture on PATH.
set -u
WT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/fakebin" "$LAB/mate/state"
trap 'rm -rf "$LAB"' EXIT
cat > "$LAB/fakebin/cpa-usage-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = models ]; then cat "$FM_HOME/fx-models"; else cat "$FM_HOME/fx-accounts"; fi
SH
chmod +x "$LAB/fakebin/cpa-usage-axi"
alarm() {
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$LAB" PATH="$LAB/fakebin:$PATH" python3 "$WT/bin/fm-fleet-alarm.py" "$@"
}
reset() { rm -f "$LAB/state/.fleet-alarm.json" "$LAB/data/secondmates.md" "$LAB/state/mate.status" "$LAB/state/mate.meta"; rm -rf "$LAB/state/secondmate-summary-cache"; }
accounts() { { echo "accounts[$#]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:"; for r in "$@"; do echo "  $r"; done; } > "$LAB/fx-accounts"; }
models() { { echo "models[$#]{account,model,requests,failed}:"; for r in "$@"; do echo "  $r"; done; } > "$LAB/fx-models"; }
show() { echo "== $1"; out=$(alarm check 2>&1); echo "rc=$? output: ${out:-<silent>}"; echo; }
summary() { # home in_flight decisions epoch_offset
  python3 -c 'import json,sys,time;print(json.dumps(dict(schema="fm-secondmate-home-summary.v1",hold_classifier_schema="fm-captain-hold-buckets.v1",home=sys.argv[1],generated_epoch=int(time.time())+int(sys.argv[4]),valid=True,counts=dict(in_flight=int(sys.argv[2]),active_children=0,decisions_open=int(sys.argv[3]),holds=0))))' "$@"
}
now=$(date +%s)

reset; accounts "idle@x,claude,0.0,,1.0,2026-10-30T10:01:00Z,,1,0" "busy@x,claude,0.1,,0.3,2026-10-30T10:01:00Z,,1,0" "codex@x,codex,0,,1.0,,,1,0"
models "busy@x,claude-opus-5-5,40,1" "idle@x,gpt-5,10,0"
show "S1 idle Claude account at 100% weekly, carrying account at 30%, pool mean remaining 35%"

reset; accounts "a@x,claude,0.1,,0.95,2026-10-30T10:01:00Z,,1,0" "b@x,claude,0.1,,0.2,2026-10-30T10:01:00Z,,1,0"
models "a@x,claude-opus-5-5,40,0" "b@x,claude-sonnet-5-5,3,0"
show "S2 carrying account a@x at 95% (b@x also carrying at 20%) -> carrying alarm names a@x"
echo "-- S2b same reading, reset time drifted one minute -> same condition, no repeat"
accounts "a@x,claude,0.1,,0.95,2026-10-30T10:02:00Z,,1,0" "b@x,claude,0.1,,0.2,2026-10-30T10:02:00Z,,1,0"
show "S2b repeat"

reset; accounts "a@x,claude,0.1,,0.95,2026-10-30T10:01:00Z,,1,0" "b@x,claude,0.1,,0.2,2026-10-30T10:01:00Z,,1,0"
models "a@x,claude-opus-5-5,7,7" "b@x,claude-sonnet-5-5,3,0"
show "S3 a@x at 95% but only failed traffic -> not carrying, no alarm"
models "a@x,claude-opus-5-5,7,7"
reset
accounts "a@x,claude,0.1,,0.95,2026-10-30T10:01:00Z,,1,0" "b@x,claude,0.1,,0.2,2026-10-30T10:01:00Z,,1,0" "c@x,claude,0.1,,0.5,2026-10-30T10:01:00Z,,500,0"
show "S3b no successful Claude traffic, one stale reading (forces a card) -> card says none carrying"

reset; accounts "a@x,claude,0.1,,0.92,2026-10-30T10:01:00Z,,1,0" "b@x,claude,0.1,,0.88,2026-10-30T10:01:00Z,,1,0"
models "b@x,claude-opus-5-5,0,0"
show "S4 pool mean remaining 10% exactly, no carrying (boundary) -> silent"
accounts "a@x,claude,0.1,,0.95,2026-10-30T10:01:00Z,,1,0" "b@x,claude,0.1,,0.88,2026-10-30T10:01:00Z,,1,0"
show "S4b pool mean remaining 8.5% -> pool alarm"
reset; accounts "a@x,claude,0.1,,0.9,2026-10-30T10:01:00Z,,1,0" "b@x,claude,0.1,,0.9,2026-10-30T10:01:00Z,,1,0"
models "a@x,claude-opus-5-5,5,0"
show "S4c carrying exactly 90%, pool exactly 10% remaining -> silent"

reset; accounts "a@x,claude,0.1,,0.3,2026-10-30T10:01:00Z,,1,0" "b@x,claude,0.1,,,,,,0"
models "a@x,claude-opus-5-5,5,0"
show "S5 unknown reading for b@x -> stale/unknown alarm retained"

# Secondmate: local mate home
reg() { printf -- '- mate - test domain (home: %s; scope: test; projects: alpha; added 2026-10-26)\n' "$LAB/mate" > "$LAB/data/secondmates.md"; }
reset; accounts "a@x,claude,0.1,,0.3,2026-10-30T10:01:00Z,,1,0"; models "a@x,claude-opus-5-5,5,0"; reg
summary "$LAB/mate" 0 0 0 > "$LAB/mate/state/home-summary.json"
printf 'working [at=%s]: old\n' $((now-9000)) > "$LAB/state/mate.status"
show "S6 idle mate silent 150 min -> no alarm"
summary "$LAB/mate" 2 0 0 > "$LAB/mate/state/home-summary.json"
show "S6b same mate with 2 in-flight -> silent-mate alarm"
printf 'working [at=%s]: fresh\n' "$(date +%s)" >> "$LAB/state/mate.status"
rm -f "$LAB/state/.fleet-alarm.json"; show "S6c mate holding work but spoke just now -> no alarm"

reset; reg; summary "$LAB/mate" 0 0 0 > "$LAB/mate/state/home-summary.json"
printf 'needs-decision [key=pick-db] [at=%s]: which db?\n' $((now-9000)) > "$LAB/state/mate.status"
show "S7 zero home counts but unresolved needs-decision in main's status -> silent-mate alarm"
printf 'resolved [key=pick-db] [at=%s]: answered\n' $((now-8000)) >> "$LAB/state/mate.status"
rm -f "$LAB/state/.fleet-alarm.json"; show "S7b same decision resolved -> no alarm"

reset; reg; summary "$LAB/mate" 1 0 -9000 > "$LAB/mate/state/home-summary.json"
printf 'working [at=%s]: x\n' "$now" > "$LAB/state/mate.status"
show "S8 mate summary 150 min old -> inventory unavailable (stale)"

# Remote mate on unreachable host -> real fm-on.sh fails -> parent cache fallback
reset; printf -- '- rmate - test domain (host: unreachable.invalid; root: /remote/code; home: /remote/rmate; scope: test; projects: alpha; added 2026-10-26)\n' > "$LAB/data/secondmates.md"
mkdir -p "$LAB/state/secondmate-summary-cache"
key=$(printf 'rmate\nunreachable.invalid\n/remote/rmate\n' | sha256sum | cut -d' ' -f1)
summary /remote/rmate 0 0 5 > "$LAB/state/secondmate-summary-cache/$key.json"
show "S9 remote cached summary from a clock 5 s ahead -> fresh, no inventory error"
summary /remote/rmate 1 0 5 > "$LAB/state/secondmate-summary-cache/$key.json"
show "S9b same skewed summary holding work, no events -> silent alarm (not inventory error)"
