#!/usr/bin/env bash
set -u
ROOT=$PWD
. tests/lib.sh 2>/dev/null || true
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
MATE="$LAB/mate"; MAIN="$LAB/main"; FB="$LAB/fakebin"
bin/fm-lab-home.sh create "$MATE" >/dev/null; bin/fm-lab-home.sh create "$MAIN" >/dev/null
mkdir -p "$FB" "$MATE/projects/waiting" "$MAIN/data" "$MAIN/state" "$MAIN/config"
# external-boundary stubs only: tmux (no default server), gh (forge), quota CLI
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta;; display-message) printf 'claude\n';; capture-pane) printf 'all quiet\n> \n';; esac; exit 0
SH
PR=https://github.com/example/alpha/pull/4619; HEAD=0123456789abcdef0123456789abcdef01234567
cat > "$FB/gh" <<SH
#!/usr/bin/env bash
case "\$*" in *headRefOid*) printf '%s\n' "$HEAD";; *isDraft*) printf '{"isDraft":false}\n';; *) exit 1;; esac
SH
cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FB/cpa-usage-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = models ]; then printf 'models[1]{account,model,requests,failed}:\n  m@example.invalid,claude-opus-5-5,5,0\n'; else printf 'accounts[1]{account,provider,used_5h,reset_5h,used_7d,reset_7d,observed,age_min,tokens_this_5h}:\n  m@example.invalid,claude,0.2,,0.2,w1,,1,0\n'; fi
SH
chmod +x "$FB"/*
export PATH="$FB:$PATH"
cat > "$MATE/data/backlog.md" <<'B'
## In flight
- [ ] dependabot-4619 - Dependabot bump awaiting merge (repo: alpha) (kind: ship) (since 2026-11-05)

## Queued

## Done
B
cat > "$MATE/state/dependabot-4619.meta" <<M
window=firstmate:fm-dependabot-4619
worktree=$MATE/projects/waiting
project=alpha
harness=claude
kind=ship
mode=no-mistakes
M
g=$(FM_HOME=$MATE bin/fm-busy-event.sh arm "$MATE/state" dependabot-4619); FM_HOME=$MATE bin/fm-busy-event.sh apply "$MATE/state" dependabot-4619 idle --gen "$g" --source claude-hook --event stop
printf 'done: PR %s ready, checks green\n' "$PR" > "$MATE/state/dependabot-4619.status"
printf -- '- mate - test domain (home: %s; scope: test; projects: alpha; added 2026-10-26)\n' "$MATE" > "$MAIN/data/secondmates.md"
printf '{"persist_polls":1}\n' > "$MAIN/config/fleet-alarm.json"
mate_line(){ printf 'done [at=%s]: agent event\n' "$(( $(date +%s) - 9000 ))" > "$MAIN/state/mate.status"; : > "$MAIN/state/mate.meta"; }
step(){
  echo "=== $1"
  FM_HOME=$MATE bin/fm-home-summary-refresh.sh; echo "refresh exit $?"
  jq -c '{valid,invalidity,counts:{in_flight:.counts.in_flight,waiting_on_merge:.counts.waiting_on_merge},waiting_on_merge}' "$MATE/state/home-summary.json"
  mate_line; rm -f "$MAIN/state/.fleet-alarm.json"
  out=$(ROOT=$ROOT FM_HOME=$MAIN TMPDIR=$LAB python3 bin/fm-fleet-alarm.py check 2>&1); echo "alarm exit $?"
  echo "alarm output: ${out:-<none>}"
}
step "BEFORE arming (done child, PR only in status line; the old false-positive state)"
printf 'pr=%s\npr_head=%s\n' "$PR" "$HEAD" >> "$MATE/state/dependabot-4619.meta"
step "meta pr= recorded, merge poll NOT armed (adversarial)"
echo "--- arming via real bin/fm-pr-check.sh"; FM_HOME=$MATE bin/fm-pr-check.sh dependabot-4619 "$PR" 2>&1 | tail -n 3; ls "$MATE/state" | grep -E 'pr-poll|check.sh'
step "AFTER fm-pr-check.sh armed the merge poll (intent: healthy waiting, no alarm)"
cp "$MATE/state/dependabot-4619.check.sh" "$LAB/keep"; printf '\n' >> "$MATE/state/dependabot-4619.check.sh"
step "tampered poll check (adversarial: watcher would refuse it)"
cp "$LAB/keep" "$MATE/state/dependabot-4619.check.sh"
printf 'failed: crashed\n' > "$MATE/state/dependabot-4619.status"
step "failed child with meta PR + armed poll (adversarial)"
printf 'done: PR ready\n' > "$MATE/state/dependabot-4619.status"
cat >> "$MATE/data/backlog.md" <<'B'
B
sed -i 's/^## Queued/- [ ] other-work - Second item (repo: alpha) (kind: ship) (since 2026-11-05)\n\n## Queued/' "$MATE/data/backlog.md"
step "waiting child plus another in-flight item with no child (other drift still surfaces)"
