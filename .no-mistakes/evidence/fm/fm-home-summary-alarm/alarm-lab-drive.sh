#!/usr/bin/env bash
# Drive the real bin/fm-fleet-alarm.py (base 9ad08e81 vs fix 592f97bb) in a
# disposable marked lab home. Only the SSH boundary (fm-on.sh) and the quota
# CLI (cpa-usage-axi) are stubbed; everything else is the committed bin tree.
# Usage: alarm-lab-drive.sh <worktree> <real-partial-summary.json>
set -u
WT=$1 PARTIAL=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap '/usr/bin/trash "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB/home" >/dev/null
H=$LAB/home
for rev in base:9ad08e81 head:592f97bb; do
  d=$LAB/${rev%%:*}; mkdir -p "$d"
  git -C "$WT" archive "${rev#*:}" bin | tar -x -C "$d"
  cat > "$d/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
# SSH boundary stub: per-host mode file decides reachability.
mode=$(cat "$FM_HOME/remote/$1.mode" 2>/dev/null || echo offline)
case "$mode" in
  offline) exit 255 ;;   # ssh: connection refused / host down
  refused) exit 1 ;;     # reachable host, command failed
  ok) cat "$FM_HOME/remote/$1.json" ;;
esac
SH
  chmod +x "$d/bin/fm-on.sh"
done
mkdir -p "$LAB/path" "$H/remote"
cat > "$LAB/path/cpa-usage-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = models ]; then cat "$FM_HOME/models"; else cat "$FM_HOME/accounts"; fi
SH
chmod +x "$LAB/path/cpa-usage-axi"
printf 'models[1]{account,model,requests,failed}:\n  member@example.invalid,claude-opus-5-5,5,0\n' > "$H/models"
quota() { printf 'accounts[1]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:\n  member@example.invalid,claude,0.2,,%s,window1,,1,0\n' "$1" > "$H/accounts"; }
quota 0.2
cat > "$H/data/secondmates.md" <<'REG'
- slarti - releases (host: slartibartfast.invalid; root: /remote/code; home: /remote/slarti; scope: test; projects: alpha; added 2026-10-26)
- deepthought - build (host: deepthought.invalid; root: /remote/code; home: /remote/deepthought; scope: test; projects: alpha; added 2026-10-26)
- gilligan - laptop (host: macbook.invalid; root: /remote/code; home: /remote/gilligan; scope: test; projects: alpha; added 2026-10-26)
REG
# Real Deep Thought published partial summary, re-homed and freshened.
publish() {  # <name> <jq-filter>
  jq --arg h "/remote/$1" --argjson now "$(date +%s)" "$2"' | .home=$h | .generated_epoch=$now' "$PARTIAL" > "$H/remote/$1.json"
  echo ok > "$H/remote/$1.mode"
}
now=$(date +%s)
for n in slarti deepthought gilligan; do printf 'working [at=%s]: agent event\n' "$now" > "$H/state/$n.status"; done
alarm() {  # <rev> <action>
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$H" \
    PATH="$LAB/path:$PATH" python3 "$LAB/$1/bin/fm-fleet-alarm.py" "$2" 2>&1
}
reset() { local o; o=$(mktemp -d "$LAB/old.XXXX"); mv "$H/state/.fleet-alarm.json" "$H/state/fleet-ledger.jsonl" "$o/" 2>/dev/null || true; }
show() { printf '\n### %s\n' "$1"; }

show 'S1 relayed fault: slarti+deepthought publish real child_current_unavailable partial summary; gilligan offline (ssh exit 255), no cache'
publish slarti . ; publish deepthought . ; echo offline > "$H/remote/gilligan.mode"
for rev in base head; do reset; echo "--- $rev check:"; alarm $rev check; echo "--- $rev record not_collected:"; jq -c '.not_collected // "absent"' "$H/state/.fleet-alarm.json"; done

show 'S2 adversarial: gilligan reachable but remote command fails (exit 1)'
echo refused > "$H/remote/gilligan.mode"; reset; alarm head check
show 'S3 adversarial: gilligan reachable, malformed document'
echo '{}' > "$H/remote/gilligan.json"; echo ok > "$H/remote/gilligan.mode"; reset; alarm head check
show 'S4 adversarial: slarti publishes legacy incomplete inventory (valid:false, no in_flight, other invalidity)'
echo offline > "$H/remote/gilligan.mode"
publish slarti 'del(.counts.in_flight) | .invalidity={kind:"orphan_in_flight"} | .reason="in-flight backlog item has no child metadata: x"'
reset; alarm head check
show 'S4b adversarial: partial kind but counts.in_flight missing (legacy) -> still alerts'
publish slarti 'del(.counts.in_flight)'; reset; alarm head check
show 'S4c adversarial: stale partial summary (generated 3h ago) -> alerts'
publish slarti '.'; jq '.generated_epoch -= 10800' "$H/remote/slarti.json" > "$H/x" && mv "$H/x" "$H/remote/slarti.json"
reset; alarm head check
show 'S4d partial summary still feeds silence: deepthought holds 25 in-flight with agent silent 2h'
publish slarti '.'; printf 'working [at=%s]: agent event\n' "$((now-7200))" > "$H/state/deepthought.status"
reset; alarm head check
printf 'working [at=%s]: agent event\n' "$now" > "$H/state/deepthought.status"

: > "$H/config/fleet-ledger"  # opt in to Captain's Log delivery
show 'S5 timer: quota opens card, quota recovers while gilligan offline with no receipt of its own -> card resolves'
reset; quota 0.95; alarm head timer; echo "ledger last: $(tail -n1 "$H/state/fleet-ledger.jsonl" | jq -c '{kind:(.kind // .type // null), text:((.text // .detail // .message // tostring)|.[0:160])}')"
quota 0.2; alarm head timer; echo "ledger last: $(tail -n1 "$H/state/fleet-ledger.jsonl" | jq -c '{kind:(.kind // .type // null), text:((.text // .detail // .message // tostring)|.[0:160])}')"
jq -c '{timer_open, conditions:(.conditions|keys), not_collected:(.not_collected|keys)}' "$H/state/.fleet-alarm.json"

show 'S6 timer: gilligan has its own open mate-read receipt then goes offline -> card stays open, receipt kept, no re-alert on return'
reset; echo '{}' > "$H/remote/gilligan.json"; echo ok > "$H/remote/gilligan.mode"
alarm head timer; lines=$(wc -l < "$H/state/fleet-ledger.jsonl"); echo "opened: $(tail -n1 "$H/state/fleet-ledger.jsonl" | jq -c 'tostring|.[0:200]')"
echo offline > "$H/remote/gilligan.mode"; alarm head timer
echo "ledger lines before/after offline run: $lines/$(wc -l < "$H/state/fleet-ledger.jsonl")"
jq -c '{timer_open, conditions:(.conditions|keys), not_collected:(.not_collected|keys)}' "$H/state/.fleet-alarm.json"
echo ok > "$H/remote/gilligan.mode"; alarm head timer
echo "ledger lines after returning still malformed (no duplicate re-alert expected): $(wc -l < "$H/state/fleet-ledger.jsonl")"
publish gilligan '.'; alarm head timer
echo "after gilligan healthy: $(tail -n1 "$H/state/fleet-ledger.jsonl" | jq -c 'tostring|.[0:200]')"
