#!/usr/bin/env bash
# Drive the real bin/fm-home-summary-refresh.sh publisher (base 9ad08e81 vs fix
# 592f97bb) in a disposable lab home whose local tmux runtime stalls on endpoint
# probes. Only the tmux and no-mistakes binaries are stubbed.
# Usage: publish-lab-drive.sh <worktree>
set -u
WT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap '/usr/bin/trash "$LAB"' EXIT
mkdir -p "$LAB/path"
cat > "$LAB/path/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) sleep 120; printf '%%1\n' ;;   # stalled local runtime
  capture-pane) printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/path/no-mistakes"
chmod +x "$LAB/path/"*
for rev in base:9ad08e81 head:592f97bb; do
  name=${rev%%:*}
  mkdir -p "$LAB/$name-tree"; git -C "$WT" archive "${rev#*:}" | tar -x -C "$LAB/$name-tree"
done
drive() {  # <rev> <label> <ntasks> [env...]
  local rev=$1 label=$2 n=$3; shift 3
  local H="$LAB/$rev-$label" i start rc
  "$WT/bin/fm-lab-home.sh" create "$H" >/dev/null
  { printf '## In flight\n'
    for i in $(seq 1 "$n"); do printf -- '- [ ] task%s - Observe a stalled endpoint (repo: firstmate) (kind: ship)\n' "$i"; done
    printf '\n## Queued\n\n## Done\n'; } > "$H/data/backlog.md"
  for i in $(seq 1 "$n"); do
    mkdir -p "$H/projects/task$i"
    printf 'window=fmtest:fm-task%s\nworktree=%s\nproject=firstmate\nharness=claude\nkind=ship\nmode=direct-PR\n' \
      "$i" "$H/projects/task$i" > "$H/state/task$i.meta"
  done
  start=$(date +%s.%N)
  env -u TMUX -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$LAB/path:$PATH" FM_ROOT_OVERRIDE="$LAB/$rev-tree" FM_HOME="$H" "$@" \
    "$LAB/$rev-tree/bin/fm-home-summary-refresh.sh"
  rc=$?
  printf -- '--- %s %s: exit=%s elapsed=%.1fs\n' "$rev" "$label" "$rc" "$(echo "$(date +%s.%N) - $start" | bc)"
  if [ -f "$H/state/home-summary.json" ]; then
    jq -c '{valid, invalidity:.invalidity.kind, counts:{in_flight:.counts.in_flight}, endpoints:[.endpoints[]|{id, exists:.endpoint.exists}]}' "$H/state/home-summary.json"
  else
    echo "no state/home-summary.json published"
  fi
}
echo '### P1 fixture bounds (FM_SNAPSHOT_CREW_STATE_TIMEOUT=2, FM_HOME_SUMMARY_TIMEOUT=8), 1 stalled task'
for rev in base head; do drive "$rev" small 1 FM_SNAPSHOT_CREW_STATE_TIMEOUT=2 FM_HOME_SUMMARY_TIMEOUT=8 2>&1 | tail -n 4; done
echo '### P2 unchanged production defaults (child bound 10s, publication deadline 60s), 3 stalled tasks'
for rev in base head; do drive "$rev" prod 3 2>&1 | tail -n 4; done
