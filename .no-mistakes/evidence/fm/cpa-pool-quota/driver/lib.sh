# shared helpers for the cpa-pool lab; source me. No deletions: fresh log dirs per run, moves instead of removes.
LAB=$LAB
EVID=/Users/leestutzman/.no-mistakes/evidence/01M4XF4KKYP2V0C09JNWQY4MMT
WT=/Users/leestutzman/.no-mistakes/worktrees/c050d9982933/01M4XF4KKYP2V0C09JNWQY4MMT
RULES="$LAB/home/config/crew-dispatch.json"
HOSTFILE="$LAB/home/config/cpa-usage-host"
REAL_PATH=$PATH
reset_log() {
  local n; n=$(( $(cat "$LAB/log/.n" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$n" > "$LAB/log/.n"
  FAKE_LOG="$LAB/log/$n"; mkdir -p "$FAKE_LOG"; export FAKE_LOG
}
use_rules() { cp "$LAB/fixtures/$1" "$RULES"; }
set_host() { printf '%s\n' "$@" > "$HOSTFILE"; }
drop_host() { [ ! -e "$HOSTFILE" ] || mv "$HOSTFILE" "$LAB/out/cpa-usage-host.removed.$RANDOM.$RANDOM"; }
# mkresp <rule-count> <choice> <confidence>: canned Jev answer the local server returns
mkresp() { jq -n --argjson n "$1" --arg c "$2" --argjson conf "$3" '
  ([range(1; $n+1) | "rule_\(.)"] + ["default"]) as $keys |
  (($keys | length) - 1) as $others |
  {model: "jev-1.13.0",
   answers: {rule: {type: "choice", choice: $c, confidence: $conf,
     probabilities: ($keys | map({key: ., value: (if . == $c then $conf else ((1 - $conf) / $others) end)}) | from_entries)}},
   usage: {input_tokens: 812, output_tokens: 60}}' > "$LAB/jev/response.json"; }
# write_cpa <path> <row>...: an accounts table in cpa-usage-axi's TOON shape
write_cpa() {
  local path=$1; shift
  { printf 'accounts[%s]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:\n' "$#"
    [ $# -eq 0 ] || printf '  %s\n' "$@"
    printf 'help[1]:\n  Run cpa-usage-axi ration for windows used this week\n'; } > "$path"
}
# run <evidence-file> <label> [NAME=value ...]: the real resolver against the lab home; appends a transcript block
run() {
  local ev=$1 label=$2; shift 2
  local out="$LAB/out/last" start end rc
  mkdir -p "$out"
  start=$(python3 -c 'import time;print(int(time.time()*1000))')
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB/home" "$@" "$WT/bin/fm-dispatch-resolve.sh" "$LAB/brief.md" --project pager > "$out/stdout" 2> "$out/stderr"
  rc=$?
  end=$(python3 -c 'import time;print(int(time.time()*1000))')
  OUT=$(cat "$out/stdout"); ERR=$(cat "$out/stderr"); RC=$rc; MS=$((end - start))
  { printf '\n### %s\n' "$label"
    printf '$ FM_HOME=$LAB/home %sbin/fm-dispatch-resolve.sh brief.md --project pager\n' "$(printf '%s ' "$@" | sed -E 's#'"$LAB"'#$LAB#g; s#'"$REAL_PATH"'#$PATH#g')"
    printf '# config/cpa-usage-host: %s\n' "$( [ -e "$HOSTFILE" ] && sed 's/^/| /' "$HOSTFILE" | tr '\n' ' ' || echo '<absent>')"
    printf -- '--- stdout ---\n%s\n--- stderr ---\n%s\n--- exit %s after %s ms ---\n' "$OUT" "$ERR" "$RC" "$MS"; } | tee -a "$ev"
}
# check <evidence-file> <description> <command...>: records PASS/FAIL of an assertion
check() {
  local ev=$1 desc=$2; shift 2
  if "$@"; then printf 'PASS: %s\n' "$desc" | tee -a "$ev"; else printf 'FAIL: %s\n' "$desc" | tee -a "$ev"; printf '%s: %s\n' "$ev" "$desc" >> "$LAB/out/failures"; fi
}
contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
not_contains() { ! contains "$1" "$2"; }
