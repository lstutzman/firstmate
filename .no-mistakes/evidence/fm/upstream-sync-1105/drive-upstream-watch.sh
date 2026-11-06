#!/usr/bin/env bash
# Live driver: a disposable office home whose registry line lists the `upstream`
# source, a real fork code root and a real upstream git repo with commits the
# fork lacks. Runs the real bin/fm-watch.sh for one check sweep and shows the
# office upstream wake it queues, then repeats the same day (expect no wake) and
# a simulated next day after a new upstream commit (expect a wake).
set -u
EV=$(cd "$(dirname "$0")" && pwd)
. "$EV/office-fixtures.sh"
set -u
WATCH="$ROOT/bin/fm-watch.sh"
g="git -c user.email=t@t -c user.name=t"
w=$(upstream_world live)
# A fork code root that is a real clone of this firstmate tree, so the watcher's
# FM_ROOT has the product scripts; upstream = the fork's main plus 2 new commits.
rm -rf "$w/fork-root" "$w/fork-origin.git" "$w/up-work"
git clone -q --bare "$ROOT" "$w/fork-origin.git"; git -C "$w/fork-origin.git" branch -f main HEAD; git -C "$w/fork-origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$w/fork-origin.git" "$w/fork-root"
git clone -q "$w/fork-origin.git" "$w/up-work"
$g -C "$w/up-work" commit -q --allow-empty -m "upstream: add feature A"
$g -C "$w/up-work" commit -q --allow-empty -m "upstream: fix bug B"
printf '%s main origin/main\n' "$w/up-work" > "$w/navigator/config/firstmate-upstream"
echo "== office registry line:"; grep '^- navigator' "$w/data/offices.md"
echo "== registered shims:"; ls "$w/navigator/state" | grep check
echo "== shim body:"; cat "$w/navigator/state/office-upstream.check.sh"
sweep() {  # <label> [FM_OFFICE_NOW]
  local out rc=0
  rm -f "$w/navigator/state/.last-check"
  out=$(perl -e 'alarm 25; exec @ARGV' env -u FM_CHECK_TIMEOUT ${2:+FM_OFFICE_NOW=$2} FM_HOME="$w/navigator" \
    FM_ROOT_OVERRIDE="$w/fork-root" FM_CHECK_INTERVAL=0 FM_POLL=0.05 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    bash "$WATCH" 2>"$EV/watch-$1.err") || rc=$?
  echo "== sweep $1 (rc=$rc) watcher stdout:"; printf '%s\n' "$out"
  echo "-- upstream records: day=$(cat "$w/navigator/data/office/upstream.day" 2>/dev/null) seen=$(cut -c1-9 "$w/navigator/data/office/upstream.seen" 2>/dev/null)"
}
drain() {  # handle the queued wakes the way firstmate does: present, then acknowledge
  local err ack
  err=$(FM_HOME="$w/navigator" FM_ROOT_OVERRIDE="$w/fork-root" bash "$ROOT/bin/fm-wake-drain.sh" 2>&1 >/dev/null)
  ack=$(printf '%s
' "$err" | sed -n 's/.*run bin\/fm-wake-drain.sh \(--ack-through [0-9]* --recovery-generation [^ ]*\).*//p' | tail -n 1)
  echo "-- drained and acknowledged (${ack:-presented; no ack line})"
  # shellcheck disable=SC2086
  [ -z "$ack" ] || FM_HOME="$w/navigator" FM_ROOT_OVERRIDE="$w/fork-root" bash "$ROOT/bin/fm-wake-drain.sh" $ack >/dev/null 2>&1
}
NOW=$(date +%s)
sweep 1-first-today
drain
$g -C "$w/up-work" commit -q --allow-empty -m "upstream: add feature C"
echo "== (new upstream commit 'add feature C' landed; same UTC day, two hours later is not needed: the day guard applies)"
sweep 2-same-day
drain
echo "== (simulating the next UTC day)"
sweep 3-next-day $((NOW + 90000))
