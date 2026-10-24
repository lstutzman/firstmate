#!/usr/bin/env bash
# Live driver: real bin/fm-captain-hold.sh + real tasks-axi, two disposable lab homes.
set -u
ROOT=${ROOT:?}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
P=$("$ROOT/bin/fm-lab-home.sh" create "$LAB/parent") ; M=$("$ROOT/bin/fm-lab-home.sh" create "$LAB/gilligan")
for h in "$P" "$M"; do
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$h/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$h/data/backlog.md"
done
printf 'gilligan\n' > "$M/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$M/.fm-secondmate-parent"
CH="$P/state/gilligan.status"
cap() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$M" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
openset() { bash -c '. "$1"; status_open_decisions "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$CH"; }
echo "### 21 Oct: worker raises the original key on the parent channel"
printf '%s\n' 'needs-decision [at=1] [key=ux-beautify-pillow-calls]: three Pillow card calls' >> "$CH"
echo "### hold the calls as backlog task ux-beautify-pillow-calls"
cap hold ux-beautify-pillow-calls --title "Pillow card calls" --reason "three Pillow card calls" --repo sample
echo "--- channel after hold:"; cat "$CH"
echo "--- OPEN DECISIONS after hold:"; openset
printf 'Call 1: yes. Call 2: no. Call 3: ship.\n' > "$LAB/decision.txt"
echo "### Lee answers all three calls"
cap answer ux-beautify-pillow-calls --decision-file "$LAB/decision.txt"; echo "rc=$?"
echo "--- channel after answer:"; cat "$CH"
echo "--- OPEN DECISIONS after answer (empty = nothing re-asked):"; openset; echo "[end]"
echo
echo "### adversarial: call raised under key pillow-x, held as task ux-beautify with --origin-key, released"
printf '%s\n' 'needs-decision [at=2] [key=pillow-x]: call under a different id' 'needs-decision [at=3] [key=bystander]: unrelated call' >> "$CH"
cap hold ux-beautify --title "UX beautify" --reason "gated by pillow-x" --repo sample --origin-key pillow-x
cap answer ux-beautify --decision-file "$LAB/decision.txt" --release; echo "rc=$?"
echo "--- OPEN DECISIONS (expect only bystander):"; openset; echo "[end]"
echo "### adversarial: invalid origin key is refused"
cap hold bad-task --title t --reason r --repo sample --origin-key 'Bad Key!'; echo "rc=$?"
echo "### adversarial: re-answering does not duplicate the origin close"
cap answer ux-beautify-pillow-calls --decision-file "$LAB/decision.txt" >/dev/null; echo "rc=$?"
echo "resolved [key=ux-beautify-pillow-calls] lines: $(grep -c '^resolved \[at=[0-9]*\] \[key=ux-beautify-pillow-calls\]\|^resolved \[key=ux-beautify-pillow-calls\]' "$CH")"
echo "--- final channel:"; cat "$CH"
