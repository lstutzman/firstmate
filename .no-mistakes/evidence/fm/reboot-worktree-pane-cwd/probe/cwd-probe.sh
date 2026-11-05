#!/usr/bin/env bash
# Live probe: real fm-spawn.sh -> real Herdr lab session (via bin/fm-herdr-lab.sh) + real Treehouse.
set -u
ROOT=$1
HELPER=$ROOT/bin/fm-herdr-lab.sh
REAL_HERDR=$(command -v herdr); REAL_TREEHOUSE=$(command -v treehouse); ORIG_PATH=$PATH
T=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-cwdprobe.XXXXXX")
FB=$T/fakebin; mkdir -p $FB
export HLOG=$T/herdr.log TLOG=$T/treehouse.log REAL_HERDR REAL_TREEHOUSE ORIG_PATH HELPER
: >$HLOG; : >$TLOG
cat > $FB/herdr <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$HLOG"
args=("$@"); n=${#args[@]}
if [ $n -ge 2 ] && [ "${args[$((n-2))]}" = --session ] && [ "${args[$((n-1))]}" = "$HERDR_LAB_SESSION" ]; then unset "args[$((n-1))]" "args[$((n-2))]"; fi
set -- "${args[@]}"
[ "${1:-}" = --version ] && exec env PATH="$ORIG_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
exec env PATH="$ORIG_PATH" "$HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
cat > $FB/treehouse <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TLOG"
"$REAL_TREEHOUSE" "$@"; st=$?
# Abort fixture: once the lease is granted, break origin so the later base fetch fails AFTER the pane exists.
if [ -n "${BREAK_ORIGIN_AFTER_GET:-}" ] && [ "$1" = get ] && [ $st -eq 0 ]; then git -C "$BREAK_ORIGIN_AFTER_GET" remote set-url origin "file:///nonexistent/missing.git"; fi
exit $st
SH
chmod +x $FB/*
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
S=$(PATH=$ORIG_PATH $HELPER name fm-cwdprobe); export HERDR_LAB_SESSION=$S HERDR_SESSION=$S
export PATH=$FB:$PATH FM_GATE_REFUSE_BYPASS=1
lab() { PATH=$ORIG_PATH $HELPER run $S "$@"; }
WTS=""
cleanup() { for w in $WTS; do [ -d "$w" ] && $REAL_TREEHOUSE return --force "$w" >/dev/null 2>&1; done; PATH=$ORIG_PATH $HELPER teardown $S >/dev/null 2>&1 && echo "teardown: lab session $S removed, tripwire intact"; rm -rf $T; }
trap cleanup EXIT
PATH=$ORIG_PATH $HELPER provision $S || { echo "provision failed"; exit 1; }
echo "lab session: $S (herdr $($REAL_HERDR --version))"
H=$T/home; P=$T/project
mkdir -p $H/state $H/config; touch $H/state/.last-watcher-beat
mkproj() { mkdir -p $1; git -C $1 init -q; echo x > $1/README.md; git -C $1 add .; git -C $1 -c user.name=t -c user.email=t@x commit -qm i; git clone -q --bare $1 $1.origin.git; git -C $1 remote add origin file://$1.origin.git; }
brief() { mkdir -p $H/data/$1; printf '# Task\n## Captain'"'"'s intent\nprobe %s\n\n## Firstmate spec\nprobe.\n' $1 > $H/data/$1/brief.md; }
mkproj $P
spawn() { local id=$1; shift; FM_SPAWN_NO_GUARD=1 FM_HOME=$H FM_ROOT_OVERRIDE=$ROOT timeout 180 $ROOT/bin/fm-spawn.sh $id "$P" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr "$@"; }
pane_cwd() { lab pane get "$1" | jq -r '.result.pane.cwd // .result.pane.foreground_cwd'; }
RESULT=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; else echo "  FAIL: $3 (got '$1' want '$2')"; RESULT=1; fi; }

for mode in off on; do
  id=probe-$mode; brief $id; printf '%s\n' $mode > $H/config/herdr-presentation-spaces
  echo "== S: fresh Herdr ship spawn, presentation spaces=$mode =="
  : > $TLOG; L0=$(wc -l < $HLOG)
  spawn $id > $T/$id.out 2> $T/$id.err || { echo "  FAIL: spawn exited nonzero"; tail -5 $T/$id.err; RESULT=1; continue; }
  wt=$(grep '^worktree=' $H/state/$id.meta | cut -d= -f2-); WTS="$WTS $wt"
  pane=$(grep '^herdr_pane_id=' $H/state/$id.meta | cut -d= -f2-)
  echo "  meta worktree=$wt pane=$pane"
  echo "  treehouse calls:"; sed 's/^/    /' $TLOG
  grep -q -- "get .*--lease.*--lease-holder $id\|get --lease --lease-holder $id" $TLOG && echo "  PASS: spawn process leased the slot itself (treehouse get --lease --lease-holder $id)" || { echo "  FAIL: no lease call"; RESULT=1; }
  create=$(sed -n "$((L0+1)),\$p" $HLOG | grep -E '^(tab|workspace) create' | head -3); echo "  herdr create calls:"; printf '%s\n' "$create" | sed 's/^/    /'
  printf '%s\n' "$create" | grep -qF -- "--cwd $wt" && echo "  PASS: pane created with --cwd = leased worktree" || { echo "  FAIL: create not in worktree"; RESULT=1; }
  if sed -n "$((L0+1)),\$p" $HLOG | grep -E '^pane (run|send)' | grep -q 'treehouse get'; then echo "  FAIL: treehouse get typed into pane"; RESULT=1; else echo "  PASS: no 'treehouse get' typed into the pane"; fi
  check "$(pane_cwd $pane)" "$wt" "live pane get reports cwd = leased worktree"
  echo "  treehouse status line:"; (cd $P && $REAL_TREEHOUSE status 2>&1 | grep -F "$(basename $(dirname $wt))" | sed 's/^/    /' || true)
done

echo "== S: lab Herdr restart restores each worker pane in its own worktree =="
PATH=$ORIG_PATH $HELPER stop $S >/dev/null; sleep 1
PATH=$ORIG_PATH $HELPER provision $S || { echo "  FAIL: re-provision after stop"; RESULT=1; }
sleep 3
for mode in off on; do
  id=probe-$mode; wt=$(grep '^worktree=' $H/state/$id.meta | cut -d= -f2-); pane=$(grep '^herdr_pane_id=' $H/state/$id.meta | cut -d= -f2-)
  check "$(pane_cwd $pane)" "$wt" "restored pane $pane for $id resumes in its leased worktree"
done
lab pane list 2>/dev/null | jq -c '.result.panes[]? | {pane_id, cwd, foreground_cwd}' | sed 's/^/    /'

echo "== S: teardown returns the lease =="
for mode in off on; do
  id=probe-$mode; wt=$(grep '^worktree=' $H/state/$id.meta | cut -d= -f2-)
  FM_HOME=$H FM_ROOT_OVERRIDE=$ROOT FM_STATE_OVERRIDE=$H/state FM_DATA_OVERRIDE=$H/data FM_CONFIG_OVERRIDE=$H/config timeout 120 $ROOT/bin/fm-teardown.sh $id --force > $T/td.out 2>&1 && echo "  PASS: teardown $id ok" || { echo "  FAIL: teardown $id"; tail -5 $T/td.out; RESULT=1; }
done
(cd $P && $REAL_TREEHOUSE status 2>&1 | sed 's/^/    /')

echo "== S(adversarial): spawn that fails after its pane exists, before its record, closes the pane and returns the lease =="
id=probe-abort; brief $id; printf 'off\n' > $H/config/herdr-presentation-spaces
: > $TLOG; L0=$(wc -l < $HLOG)
git -C $P remote set-url origin file://$P.origin.git
BREAK_ORIGIN_AFTER_GET=$P spawn $id > $T/$id.out 2> $T/$id.err && { echo "  FAIL: abort fixture unexpectedly succeeded"; RESULT=1; } || echo "  spawn exited nonzero as expected; last stderr:"; tail -4 $T/$id.err | sed 's/^/    /'
echo "  treehouse calls:"; sed 's/^/    /' $TLOG
created=$(sed -n "$((L0+1)),\$p" $HLOG | grep -E '^tab create' | head -1)
echo "  herdr create: ${created:-<none>}"
[ -e $H/state/$id.meta ] && { echo "  FAIL: record left behind"; RESULT=1; } || echo "  PASS: no task record published"
if [ -n "$created" ]; then
  closes=$(sed -n "$((L0+1)),\$p" $HLOG | grep -cE '^pane close|^tab close'); echo "  herdr close calls: $closes"
  [ "$closes" -ge 1 ] && echo "  PASS: abort closed its own pane" || { echo "  FAIL: pane not closed"; RESULT=1; }
  grep -q '^return' $TLOG && echo "  PASS: abort returned its lease" || { echo "  FAIL: lease not returned"; RESULT=1; }
  lab tab list 2>/dev/null | jq -r '.result.tabs[]?.label' | grep -qx "fm-$id" && { echo "  FAIL: fm-$id tab still live"; RESULT=1; } || echo "  PASS: no fm-$id tab remains in the lab session"
else
  echo "  NOTE: failure occurred before pane creation"
fi
(cd $P && $REAL_TREEHOUSE status 2>&1 | sed 's/^/    /')
echo "RESULT=$RESULT"
exit $RESULT
