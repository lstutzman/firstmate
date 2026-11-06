LAB=$1; SH=$2
PATH="$SH:$PATH" env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" bin/fm-brief.sh live-fields alpha --mode no-mistakes --linear PC-9001; echo rc=$?
sed -n '/^# Task/,/^## Firstmate spec/p' "$LAB/data/live-fields/brief.md"
