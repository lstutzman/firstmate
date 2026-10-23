#!/usr/bin/env bash
# Live drive: bin/fm-config-push.sh pushes the primary's config/brief-include.md
# into a real (cloned) secondmate home as a base, keeping the home's own lines.
set -u
WT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
SM=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-sm.XXXXXX")/deepthought
git clone -q --shared "$WT" "$SM"
mkdir -p "$SM/config" "$SM/state" "$SM/data"
printf 'deepthought\n' > "$SM/.fm-secondmate-home"
printf 'kind=secondmate\nhome=%s\n' "$SM" > "$LAB/state/deepthought.meta"
push() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$LAB" "$WT/bin/fm-config-push.sh" 2>&1 | grep -E 'config-push|secondmate|brief-include'; }
show() { echo "--- $SM/config/brief-include.md:"; cat "$SM/config/brief-include.md" 2>/dev/null || echo "(absent)"; echo "---"; }

echo "## 1. Deep Thought has no brief-include.md; primary has fleet rules"
printf '%s\n' "Fleet rule: never merge a red PR." > "$LAB/config/brief-include.md"
show; push; show

echo "## 2. Deep Thought adds its own line below the base; primary unchanged, push again"
printf '%s\n' "Home rule: deepthought builds PC2 features." >> "$SM/config/brief-include.md"
push; show

echo "## 3. Primary revises the base; push replaces only the base, own line kept"
printf '%s\n' "Fleet rule v2: never merge a red PR." "Fleet rule v2: additive migrations need no word." > "$LAB/config/brief-include.md"
push; show

echo "## 4. Primary removes its file; the home keeps exactly its own lines"
rm "$LAB/config/brief-include.md"
push; show

echo "## 5. Composed file reaches a worker brief scaffolded in the secondmate home"
printf '%s\n' "Fleet rule v3: test on staging with flag on." > "$LAB/config/brief-include.md"
push >/dev/null; show
rm -rf "$LAB" "$(dirname "$SM")"
echo "lab torn down"
