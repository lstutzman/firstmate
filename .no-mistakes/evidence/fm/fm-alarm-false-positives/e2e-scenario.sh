#!/usr/bin/env bash
# E2E: real fm-fleet-snapshot.sh producer -> real fm-fleet-alarm.py timer, disposable lab, stub quota reader.
# Usage: e2e-scenario.sh <worktree> <alarm-script-to-test> <label>
set -eu
WT=$1 ALARM=$2 LABEL=$3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); trap 'rm -rf "$LAB"' EXIT
MAIN=$LAB/main; GIL=$LAB/gilligan; BIN=$LAB/bin; FAKE=$LAB/fake
mkdir -p $MAIN/{state,config,data} $GIL/{state,config,data} $BIN $FAKE
cp "$ALARM" $BIN/fm-fleet-alarm.py
for f in fm-timeout-lib.sh fm-env-lib.sh fm-classify-lib.sh fm-secondmate-registry-lib.sh; do cp $WT/bin/$f $BIN/; done
printf '#!/usr/bin/env bash\nexec "%s/bin/fm-fleet-ledger.sh" "$@"\n' "$WT" > $BIN/fm-fleet-ledger.sh
printf '#!/usr/bin/env bash\nexit 99\n' > $BIN/fm-fleet-snapshot.sh
cat > $BIN/cpa-usage-axi <<'SH'
#!/usr/bin/env bash
if [ "$1" = models ]; then cat "$FM_HOME/models"; else cat "$FM_HOME/accounts"; fi
SH
printf '#!/usr/bin/env bash\ncase "$1" in display-message) printf "%%%%1\\n";; esac\nexit 0\n' > $FAKE/tmux
printf '#!/usr/bin/env bash\nexit 0\n' > $FAKE/no-mistakes
chmod +x $BIN/* $FAKE/*
reset=$(date -u -d '+3 hours' +%Y-%m-%dT%H:%M:%SZ)
accounts() { printf '%s\n' 'accounts[2]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:' \
  "  marleycrittendom@gmail.com,claude,0.2,,0.91,$reset,,1,0" \
  "  misterrobot@propertycompass.co.uk,claude,0.0,,$1,$reset,,1,0" > $MAIN/accounts; }
printf '%s\n' 'models[1]{account,model,requests,failed}:' '  marleycrittendom@gmail.com,claude-opus-5-5,5,0' > $MAIN/models
accounts 0.0
touch $MAIN/config/fleet-ledger
printf -- '- gilligan - laptop (home: %s; scope: test; projects: firstmate; added 2026-10-26)\n' $GIL > $MAIN/data/secondmates.md
backlog() { cat > $GIL/data/backlog.md; 
  PATH="$FAKE:$PATH" FM_ROOT_OVERRIDE="$WT" FM_HOME="$GIL" "$WT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > $GIL/state/home-summary.json
  echo "  [producer] counts: $(jq -c .counts $GIL/state/home-summary.json) valid=$(jq .valid $GIL/state/home-summary.json)"; }
now=$(date +%s)
printf 'working [at=%s]: agent event\n' $((now-5400)) > $MAIN/state/gilligan.status
printf 'spawn_gen=\n' > $MAIN/state/gilligan.meta
timer() { ROOT=$WT FM_HOME=$MAIN PATH="$BIN:$PATH" TMPDIR=$LAB python3 $BIN/fm-fleet-alarm.py timer; }
lines() { [ -f $MAIN/state/fleet-alarm.status ] && wc -l < $MAIN/state/fleet-alarm.status || echo 0; }
echo "=== $LABEL ==="
echo "--- S1/S2: gilligan parked only on captain holds (silent 90 min), marley 91% resets in 3h, misterrobot 0% ---"
backlog <<'B'
## In flight
- [ ] pick-route - Decide the route (repo: firstmate) (kind: ship) (since 2026-11-01) (hold: choose route) (hold-kind: captain)
- [ ] pick-copy - Decide the copy (repo: firstmate) (kind: ship) (since 2026-11-01) (hold: approve copy) (hold-kind: captain)

## Queued

## Done
B
for i in 1 2 3 4; do timer; echo "  poll $i: status lines=$(lines)"; done
echo "  status file:"; sed 's/^/    | /' $MAIN/state/fleet-alarm.status 2>/dev/null || true
echo "--- S3 adversarial: pool tightens (misterrobot 85%) -> must re-alert ---"
before=$(lines); accounts 0.85; timer; echo "  lines $before -> $(lines)"; tail -n 1 $MAIN/state/fleet-alarm.status | sed 's/^/    | /'
accounts 0.0; timer
echo "--- S4 adversarial: gilligan gains an un-held in-flight item while silent -> must alarm ---"
backlog <<'B'
## In flight
- [ ] pick-route - Decide the route (repo: firstmate) (kind: ship) (since 2026-11-01) (hold: choose route) (hold-kind: captain)
- [ ] drive-program - Drive the program (repo: firstmate) (kind: program) (since 2026-11-01)

## Queued

## Done
B
before=$(lines); timer; timer; echo "  lines $before -> $(lines)"; tail -n 1 $MAIN/state/fleet-alarm.status | sed 's/^/    | /'
