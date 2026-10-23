#!/usr/bin/env bash
# Drives real bin/ entrypoints against the lab. usage: lab-run.sh <root> <lab> <cmd...>
ROOT=$1; LAB=$2; shift 2
exec env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" PATH="$LAB/fakebin:$PATH" FAKE_GH_LOG="$LAB/gh.log" FAKE_HEAD="${FAKE_HEAD:-$(git -C "$LAB/wt" rev-parse HEAD)}" \
  FAKE_BODY="${FAKE_BODY:-/dev/null}" TMUX_TMPDIR="$LAB/tmux" "$@"
