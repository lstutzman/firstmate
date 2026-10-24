#!/usr/bin/env bash
# Live driver: real fm-pr-check.sh + fm-crew-state.sh in a disposable lab home.
set -u
ROOT=$1
cd "$ROOT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/fakebin" "$LAB/config/ready-evidence"
SOCKDIR="$LAB/tmux"
cleanup() { TMUX_TMPDIR="$SOCKDIR" tmux -L fm-lab kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
export FM_HOME="$LAB"
G() { git -c user.name=lab -c user.email=lab@example.invalid "$@"; }
# Real project clone with bare origin, worker worktree pushed to origin.
G init -q --bare "$LAB/origin.git"
G clone -q "$LAB/origin.git" "$LAB/projects/pc2" 2>/dev/null
G -C "$LAB/projects/pc2" commit -q --allow-empty -m init
G -C "$LAB/projects/pc2" push -q origin HEAD:main
G -C "$LAB/projects/pc2" worktree add -q -b fm/evid "$LAB/wt" main
G -C "$LAB/wt" commit -q --allow-empty -m 'the fix'
G -C "$LAB/wt" push -q origin fm/evid
G -C "$LAB/projects/pc2" fetch -q origin
HEAD1=$(git -C "$LAB/wt" rev-parse HEAD)
# Project's own review marker (stands in for verify-pr-review.py's evidence).
mkdir -p "$LAB/projects/pc2/.review"
printf '%s\n' '- pc2 [direct-PR ready-evidence=pc-ready] - lab fixture (added 2026-10-24)' > "$LAB/data/projects.md"
# PC-style command set from docs/configuration.md, with a marker check in place of the python hook.
cat > "$LAB/config/ready-evidence/pc-ready" <<'SH'
echo "$1 $2" >> "$FM_HOME/evidence-runs.log"
[ -f ".review/$2" ] || { echo "no pc-review-evidence marker for $2"; exit 1; }
body=$(gh pr view "$1" --json body -q .body | tr -d '\r')
for heading in Testing Risk 'How to revert'; do
  grep -Eq "^#+ $heading\$" <<<"$body" || { echo "PR body has no $heading heading"; exit 1; }
done
SH
# gh is the forge boundary: answers PR view queries for the one lab PR.
cat > "$LAB/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$FM_HOME/gh.log"
case " $* " in
  *" --json body "*) printf '## Summary\r\nfix\r\n## Testing\r\nran\r\n## Risk\r\nlow\r\n%s\r\n' "${LAB_BODY_TAIL-## How to revert}"; exit 0 ;;
  *statusCheckRollup*|*headRefOid*|*isDraft*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s","headRefName":"fm/evid","baseRefName":"main","url":"https://github.com/lab/pc2/pull/7","statusCheckRollup":[]}\n' "$(git -C "$FM_HOME/wt" rev-parse HEAD)"; exit 0 ;;
esac
exit 1
SH
chmod +x "$LAB/fakebin/gh"
export PATH="$LAB/fakebin:$PATH"
URL=https://github.com/lab/pc2/pull/7
write_meta() { local f=$1; shift; ( umask 077; printf '%s\n' "$@" > "$f" ); }
: > "$FM_HOME/evidence-runs.log"
bin/fm-wake-lib.sh >/dev/null 2>&1 || true
. bin/fm-dod-lib.sh 2>/dev/null || true
. bin/fm-tmux-lib.sh 2>/dev/null || true
write_meta "$LAB/state/evid.meta" "window=fm:fm-evid" "worktree=$LAB/wt" "project=$LAB/projects/pc2" \
  "kind=ship" "mode=direct-PR" "harness=claude" "backend=tmux"
printf 'done: PR %s\n' "$URL" > "$LAB/state/evid.status"
TMUX_TMPDIR="$SOCKDIR" tmux -L fm-lab new-session -d -s fm -n fm-evid -c "$LAB/wt" "sleep 900"
export TMUX="$(TMUX_TMPDIR="$SOCKDIR" tmux -L fm-lab display-message -p '#{socket_path},#{pid},0')"
gen=$(bin/fm-busy-event.sh arm "$LAB/state" evid) && bin/fm-busy-event.sh apply "$LAB/state" evid idle --gen "$gen" --source claude-hook --event stop >/dev/null
state() { bin/fm-crew-state.sh evid 2>&1 | grep -E '^(state|reason|detail|why)|ready evidence' | head -5; }
runs() { wc -l < "$FM_HOME/evidence-runs.log" 2>/dev/null | tr -d ' ' || echo 0; }

echo "### S1 crew-state on a fresh done (no registration yet); evidence runs so far: $(runs)"
state; echo "evidence runs after state read: $(runs)"
echo; echo "### S2 fm-pr-check.sh registration, no review marker -> refuse"
bin/fm-pr-check.sh evid "$URL"; echo "rc=$?"
grep '^ready_evidence=\|^pr=' "$LAB/state/evid.meta"; ls "$LAB/state" | grep -c check.sh || true
echo "--- crew-state reads recorded fail (runs before: $(runs))"; state; echo "runs after: $(runs)"
echo; echo "### S3 marker present but PR body missing 'How to revert' (CRLF body) -> refuse"
touch "$LAB/projects/pc2/.review/$HEAD1"
LAB_BODY_TAIL='' bin/fm-pr-check.sh evid "$URL"; echo "rc=$?"
grep '^ready_evidence=' "$LAB/state/evid.meta"
echo; echo "### S4 marker + all headings (CRLF body) -> registration passes and arms"
bin/fm-pr-check.sh evid "$URL"; echo "rc=$?"
grep '^ready_evidence=\|^pr=\|^pr_head=' "$LAB/state/evid.meta"; ls "$LAB/state" | grep check || true
echo "--- crew-state reads recorded pass (runs before: $(runs))"; state; echo "runs after: $(runs)"
echo; echo "### S5 worker pushes a new head -> record no longer matches"
G -C "$LAB/wt" commit -q --allow-empty -m 'follow-up'; G -C "$LAB/wt" push -q origin fm/evid; G -C "$LAB/projects/pc2" fetch -q origin
sed -i '' "s|^pr_head=.*|pr_head=$(git -C "$LAB/wt" rev-parse HEAD)|" "$LAB/state/evid.meta"
state; echo "runs after: $(runs)"
echo; echo "### S6 tampered command set path: delete config file -> registration refuses"
mv "$LAB/config/ready-evidence/pc-ready" "$LAB/pc-ready.bak"
bin/fm-pr-check.sh evid "$URL"; echo "rc=$?"; grep '^ready_evidence=' "$LAB/state/evid.meta"
mv "$LAB/pc-ready.bak" "$LAB/config/ready-evidence/pc-ready"
echo; echo "### S7 timeout: slow command set -> fail"
printf 'sleep 5\n' > "$LAB/config/ready-evidence/pc-ready"
FM_READY_EVIDENCE_TIMEOUT=1 bin/fm-pr-check.sh evid "$URL"; echo "rc=$?"; grep '^ready_evidence=' "$LAB/state/evid.meta"
echo; echo "### S8 project with no token: registry line without ready-evidence -> no record, unchanged gate"
printf '%s\n' '- pc2 [direct-PR] - lab fixture (added 2026-10-24)' > "$LAB/data/projects.md"
sed -i '' '/^ready_evidence=/d' "$LAB/state/evid.meta"
: > "$FM_HOME/evidence-runs.log"
bin/fm-pr-check.sh evid "$URL"; echo "rc=$?"; grep -c '^ready_evidence=' "$LAB/state/evid.meta"; state; echo "runs: $(runs)"
echo; echo "gh calls:"; sort "$FM_HOME/gh.log" | uniq -c
