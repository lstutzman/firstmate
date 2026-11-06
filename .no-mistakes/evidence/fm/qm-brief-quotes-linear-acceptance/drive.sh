#!/usr/bin/env bash
LAB=$1; shift
run() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" bin/fm-brief.sh "$@"; }
for i in PC-4308 PC-4279; do echo "### $i (real linear-axi)"; run live-$i alpha --scout --linear $i 2>&1; sed -n '/Quoted from Linear/,/^$/p' "$LAB/data/live-$i/brief.md"; done
echo "### nonexistent PC-99999999 (real linear-axi)"; run live-missing alpha --mode no-mistakes --linear PC-99999999; echo rc=$?; ls "$LAB/data/live-missing" 2>&1
echo "### bad id ENG-5"; run live-eng alpha --mode no-mistakes --linear ENG-5; echo rc=$?
echo "### secondmate + --linear"; run live-sm --secondmate --no-projects --linear PC-2246; echo rc=$?
echo "### no --linear"; run live-plain alpha --mode no-mistakes; echo rc=$?; echo "quote lines: $(grep -c 'Quoted from Linear' "$LAB/data/live-plain/brief.md")"
